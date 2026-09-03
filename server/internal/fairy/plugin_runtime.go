package fairy

import (
	"context"
	"errors"
	"fmt"
	"sort"
	"strings"
	"sync"
)

// PluginComponent identifies a contribution a plugin may register. Keeping
// this explicit prevents a package from silently gaining access to a new
// runtime surface when the host evolves.
type PluginComponent string

const (
	PluginComponentCommand PluginComponent = "command"
	PluginComponentTool    PluginComponent = "tool"
	PluginComponentMemory  PluginComponent = "memory"
	PluginComponentPrompt  PluginComponent = "prompt"
	PluginComponentHook    PluginComponent = "hook"
	PluginComponentService PluginComponent = "service"
)

type PluginIsolation string

const (
	PluginIsolationInProcess PluginIsolation = "in_process"
	PluginIsolationProcess   PluginIsolation = "isolated_process"
)

type PluginDependency struct {
	ID         string `json:"id"`
	MinVersion string `json:"min_version,omitempty"`
}

// PluginManifest is the stable package contract. The host validates it before
// loading any code, and uses it for dependency ordering and admin inspection.
type PluginManifest struct {
	ID             string             `json:"id"`
	Name           string             `json:"name"`
	Version        string             `json:"version"`
	Description    string             `json:"description,omitempty"`
	APIVersion     int                `json:"api_version"`
	Components     []PluginComponent  `json:"components"`
	Requires       []string           `json:"requires,omitempty"`
	Provides       []string           `json:"provides,omitempty"`
	Dependencies   []PluginDependency `json:"dependencies,omitempty"`
	Isolation      PluginIsolation    `json:"isolation"`
	Reloadable     bool               `json:"reloadable"`
	DefaultEnabled bool               `json:"default_enabled"`
}

func (m PluginManifest) Validate() error {
	if !validPluginID(m.ID) || strings.TrimSpace(m.Name) == "" || strings.TrimSpace(m.Version) == "" {
		return fmt.Errorf("plugin manifest requires valid id, name, and version")
	}
	if m.APIVersion != 1 {
		return fmt.Errorf("plugin %s uses unsupported API version %d", m.ID, m.APIVersion)
	}
	if m.Isolation == "" {
		m.Isolation = PluginIsolationInProcess
	}
	if m.Isolation != PluginIsolationInProcess && m.Isolation != PluginIsolationProcess {
		return fmt.Errorf("plugin %s uses unsupported isolation %q", m.ID, m.Isolation)
	}
	seenComponents := make(map[PluginComponent]struct{}, len(m.Components))
	for _, component := range m.Components {
		switch component {
		case PluginComponentCommand, PluginComponentTool, PluginComponentMemory, PluginComponentPrompt, PluginComponentHook, PluginComponentService:
		default:
			return fmt.Errorf("plugin %s declares unknown component %q", m.ID, component)
		}
		if _, exists := seenComponents[component]; exists {
			return fmt.Errorf("plugin %s declares component %q more than once", m.ID, component)
		}
		seenComponents[component] = struct{}{}
	}
	for _, capability := range append(append([]string(nil), m.Requires...), m.Provides...) {
		if !validPluginID(capability) {
			return fmt.Errorf("plugin %s declares invalid capability %q", m.ID, capability)
		}
	}
	seenDependencies := make(map[string]struct{}, len(m.Dependencies))
	for _, dependency := range m.Dependencies {
		if !validPluginID(dependency.ID) || dependency.ID == m.ID {
			return fmt.Errorf("plugin %s declares invalid dependency %q", m.ID, dependency.ID)
		}
		if _, exists := seenDependencies[dependency.ID]; exists {
			return fmt.Errorf("plugin %s declares dependency %q more than once", m.ID, dependency.ID)
		}
		seenDependencies[dependency.ID] = struct{}{}
	}
	return nil
}

func validPluginID(value string) bool {
	value = strings.TrimSpace(value)
	if len(value) == 0 || len(value) > 64 {
		return false
	}
	for index, r := range value {
		if (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9') || r == '-' || r == '_' || r == '.' && index > 0 {
			continue
		}
		return false
	}
	return true
}

type PluginFactory func() PluginModule

// PluginModule is implemented by a package, not by a single command or
// tool. Register must only add contributions through PluginContext.
type PluginModule interface {
	Manifest() PluginManifest
	Register(context.Context, *PluginContext) error
}

type PluginLifecycle interface {
	Start(context.Context) error
	Stop(context.Context) error
}

type PluginHandle interface {
	Stop(context.Context) error
}

type PluginRunner interface {
	Start(context.Context, PluginModule, *PluginContext) (PluginHandle, error)
}

// InProcessPluginRunner is for trusted, compiled Fairy packages. It still
// enforces lifecycle cleanup; it is not a security sandbox.
type InProcessPluginRunner struct{}

func (InProcessPluginRunner) Start(ctx context.Context, module PluginModule, scope *PluginContext) (PluginHandle, error) {
	if err := module.Register(ctx, scope); err != nil {
		_ = scope.Close(context.Background())
		return nil, err
	}
	if lifecycle, ok := module.(PluginLifecycle); ok {
		if err := lifecycle.Start(ctx); err != nil {
			_ = scope.Close(context.Background())
			return nil, err
		}
		return &inProcessPluginHandle{lifecycle: lifecycle, scope: scope}, nil
	}
	return &inProcessPluginHandle{scope: scope}, nil
}

type inProcessPluginHandle struct {
	lifecycle PluginLifecycle
	scope     *PluginContext
}

func (h *inProcessPluginHandle) Stop(ctx context.Context) error {
	var stopErr error
	if h.lifecycle != nil {
		stopErr = h.lifecycle.Stop(ctx)
	}
	closeErr := h.scope.Close(ctx)
	return errors.Join(stopErr, closeErr)
}

type PluginHookName string

const (
	PluginHookBeforeGate          PluginHookName = "before_gate"
	PluginHookBeforePrompt        PluginHookName = "before_prompt"
	PluginHookBeforeToolExecution PluginHookName = "before_tool_execution"
	PluginHookAfterToolExecution  PluginHookName = "after_tool_execution"
	PluginHookAfterReply          PluginHookName = "after_reply"
)

type PluginEvent struct {
	Name           PluginHookName
	TraceID        string
	TurnID         string
	ConversationID string
	Data           any
}

type PluginHook func(context.Context, *PluginEvent) error

type pluginHookBus struct {
	mu       sync.RWMutex
	handlers map[PluginHookName]map[uint64]PluginHook
	nextID   uint64
}

func newPluginHookBus() *pluginHookBus {
	return &pluginHookBus{handlers: make(map[PluginHookName]map[uint64]PluginHook)}
}

func (b *pluginHookBus) on(name PluginHookName, handler PluginHook) func() {
	b.mu.Lock()
	b.nextID++
	id := b.nextID
	if b.handlers[name] == nil {
		b.handlers[name] = make(map[uint64]PluginHook)
	}
	b.handlers[name][id] = handler
	b.mu.Unlock()
	return func() {
		b.mu.Lock()
		delete(b.handlers[name], id)
		b.mu.Unlock()
	}
}

func (b *pluginHookBus) emit(ctx context.Context, event *PluginEvent) error {
	b.mu.RLock()
	handlers := make([]PluginHook, 0, len(b.handlers[event.Name]))
	for _, handler := range b.handlers[event.Name] {
		handlers = append(handlers, handler)
	}
	b.mu.RUnlock()
	for _, handler := range handlers {
		if err := callPluginHook(ctx, handler, event); err != nil {
			return err
		}
	}
	return nil
}

func callPluginHook(ctx context.Context, handler PluginHook, event *PluginEvent) (err error) {
	defer func() {
		if recovered := recover(); recovered != nil {
			err = fmt.Errorf("plugin hook panicked: %v", recovered)
		}
	}()
	return handler(ctx, event)
}

type PluginCommandRegistration struct {
	ID      string
	Handler Plugin
}

type PluginToolRegistration struct {
	ID   string
	Tool Tool
}

type PluginMemoryRegistration struct {
	ID       string
	Provider any
}

type PluginPromptRegistration struct {
	ID       string
	Provider PluginPromptProvider
}

type PluginPromptProvider interface {
	PromptSections(context.Context) []promptSection
}

type PluginRegistrationSnapshot struct {
	Commands []PluginCommandRegistration
	Tools    []PluginToolRegistration
	Memory   []PluginMemoryRegistration
	Prompts  []PluginPromptRegistration
}

// PluginContext is a per-plugin capability and cleanup scope. A module cannot
// read a capability unless it declared it in its manifest Requires list.
type PluginContext struct {
	ctx          context.Context
	manifest     PluginManifest
	capabilities *pluginCapabilityRegistry
	bus          *pluginHookBus
	mu           sync.Mutex
	commands     []PluginCommandRegistration
	tools        []PluginToolRegistration
	memory       []PluginMemoryRegistration
	prompts      []PluginPromptRegistration
	effects      []func(context.Context) error
	closed       bool
}

func (p *PluginContext) Context() context.Context { return p.ctx }

func (p *PluginContext) Capability(name string) (any, bool) {
	if !containsString(p.manifest.Requires, name) {
		return nil, false
	}
	return p.capabilities.get(name)
}

func (p *PluginContext) ProvideCapability(name string, value any) error {
	if !containsString(p.manifest.Provides, name) || value == nil {
		return fmt.Errorf("plugin %s cannot provide undeclared capability %q", p.manifest.ID, name)
	}
	if err := p.capabilities.provide(p.manifest.ID, name, value); err != nil {
		return err
	}
	return p.Effect(func(context.Context) error {
		p.capabilities.remove(p.manifest.ID, name)
		return nil
	})
}

func (p *PluginContext) RegisterCommand(id string, command Plugin) error {
	if !p.hasComponent(PluginComponentCommand) || command == nil || !validPluginID(id) {
		return fmt.Errorf("plugin %s cannot register command %q", p.manifest.ID, id)
	}
	p.mu.Lock()
	for _, registration := range p.commands {
		if registration.ID == id {
			p.mu.Unlock()
			return fmt.Errorf("plugin %s already registered command %q", p.manifest.ID, id)
		}
	}
	p.commands = append(p.commands, PluginCommandRegistration{ID: id, Handler: command})
	p.mu.Unlock()
	return nil
}

func (p *PluginContext) RegisterTool(id string, tool Tool) error {
	if !p.hasComponent(PluginComponentTool) || tool == nil || !validPluginID(id) {
		return fmt.Errorf("plugin %s cannot register tool %q", p.manifest.ID, id)
	}
	p.mu.Lock()
	for _, registration := range p.tools {
		if registration.ID == id {
			p.mu.Unlock()
			return fmt.Errorf("plugin %s already registered tool %q", p.manifest.ID, id)
		}
	}
	p.tools = append(p.tools, PluginToolRegistration{ID: id, Tool: tool})
	p.mu.Unlock()
	return nil
}

func (p *PluginContext) RegisterMemory(id string, provider any) error {
	if !p.hasComponent(PluginComponentMemory) || provider == nil || !validPluginID(id) {
		return fmt.Errorf("plugin %s cannot register memory provider %q", p.manifest.ID, id)
	}
	p.mu.Lock()
	for _, registration := range p.memory {
		if registration.ID == id {
			p.mu.Unlock()
			return fmt.Errorf("plugin %s already registered memory provider %q", p.manifest.ID, id)
		}
	}
	p.memory = append(p.memory, PluginMemoryRegistration{ID: id, Provider: provider})
	p.mu.Unlock()
	return nil
}

func (p *PluginContext) RegisterPrompt(id string, provider PluginPromptProvider) error {
	if !p.hasComponent(PluginComponentPrompt) || provider == nil || !validPluginID(id) {
		return fmt.Errorf("plugin %s cannot register prompt provider %q", p.manifest.ID, id)
	}
	p.mu.Lock()
	for _, registration := range p.prompts {
		if registration.ID == id {
			p.mu.Unlock()
			return fmt.Errorf("plugin %s already registered prompt provider %q", p.manifest.ID, id)
		}
	}
	p.prompts = append(p.prompts, PluginPromptRegistration{ID: id, Provider: provider})
	p.mu.Unlock()
	return nil
}

func (p *PluginContext) On(name PluginHookName, handler PluginHook) error {
	if !p.hasComponent(PluginComponentHook) || handler == nil {
		return fmt.Errorf("plugin %s cannot register hook %q", p.manifest.ID, name)
	}
	dispose := p.bus.on(name, handler)
	p.Effect(func(context.Context) error { dispose(); return nil })
	return nil
}

func (p *PluginContext) Effect(dispose func(context.Context) error) error {
	if dispose == nil {
		return errors.New("plugin disposer is required")
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.closed {
		return errors.New("plugin scope is closed")
	}
	p.effects = append(p.effects, dispose)
	return nil
}

func (p *PluginContext) hasComponent(component PluginComponent) bool {
	return containsComponent(p.manifest.Components, component)
}

func (p *PluginContext) snapshot() PluginRegistrationSnapshot {
	p.mu.Lock()
	defer p.mu.Unlock()
	return PluginRegistrationSnapshot{
		Commands: append([]PluginCommandRegistration(nil), p.commands...),
		Tools:    append([]PluginToolRegistration(nil), p.tools...),
		Memory:   append([]PluginMemoryRegistration(nil), p.memory...),
		Prompts:  append([]PluginPromptRegistration(nil), p.prompts...),
	}
}

func (p *PluginContext) Close(ctx context.Context) error {
	p.mu.Lock()
	if p.closed {
		p.mu.Unlock()
		return nil
	}
	p.closed = true
	effects := append([]func(context.Context) error(nil), p.effects...)
	p.mu.Unlock()
	var joined error
	for index := len(effects) - 1; index >= 0; index-- {
		joined = errors.Join(joined, effects[index](ctx))
	}
	return joined
}

type PluginRuntimeStatus struct {
	PluginManifest
	Enabled bool   `json:"enabled"`
	State   string `json:"state"`
	Error   string `json:"error,omitempty"`
}

type pluginRuntime struct {
	factory  PluginFactory
	module   PluginModule
	manifest PluginManifest
	context  *PluginContext
	handle   PluginHandle
	status   PluginRuntimeStatus
}

type PluginHost struct {
	mu           sync.RWMutex
	lifecycleMu  sync.Mutex
	ctx          context.Context
	capabilities *pluginCapabilityRegistry
	runners      map[PluginIsolation]PluginRunner
	bus          *pluginHookBus
	factories    map[string]PluginFactory
	runtimes     map[string]*pluginRuntime
	order        []string
}

func NewPluginHost(ctx context.Context, cfg Config, capabilities map[string]any, factories ...PluginFactory) (*PluginHost, error) {
	return NewPluginHostWithRunners(ctx, cfg, capabilities, nil, factories...)
}

// NewPluginHostWithRunners installs isolation runners before any module is
// started. This is required for process-isolated packages, because SetRunner
// is intentionally only useful for modules loaded after host construction.
func NewPluginHostWithRunners(ctx context.Context, cfg Config, capabilities map[string]any, runners map[PluginIsolation]PluginRunner, factories ...PluginFactory) (*PluginHost, error) {
	if ctx == nil {
		ctx = context.Background()
	}
	host := &PluginHost{
		ctx: ctx, capabilities: newPluginCapabilityRegistry(capabilities), runners: map[PluginIsolation]PluginRunner{
			PluginIsolationInProcess: InProcessPluginRunner{},
		}, bus: newPluginHookBus(), factories: make(map[string]PluginFactory), runtimes: make(map[string]*pluginRuntime),
	}
	for isolation, runner := range runners {
		if err := host.setRunner(isolation, runner); err != nil {
			return nil, err
		}
	}
	for _, factory := range factories {
		if factory == nil {
			return nil, errors.New("nil Fairy plugin factory")
		}
		module := factory()
		if module == nil {
			return nil, errors.New("Fairy plugin factory returned nil module")
		}
		manifest := normalizePluginManifest(module.Manifest())
		if err := manifest.Validate(); err != nil {
			return nil, err
		}
		if _, exists := host.factories[manifest.ID]; exists {
			return nil, fmt.Errorf("duplicate Fairy plugin %q", manifest.ID)
		}
		host.factories[manifest.ID] = factory
	}
	if err := host.startAll(cfg); err != nil {
		return host, err
	}
	return host, nil
}

type pluginCapabilityEntry struct {
	owner string
	value any
}

type pluginCapabilityRegistry struct {
	mu     sync.RWMutex
	values map[string]pluginCapabilityEntry
}

func newPluginCapabilityRegistry(core map[string]any) *pluginCapabilityRegistry {
	registry := &pluginCapabilityRegistry{values: make(map[string]pluginCapabilityEntry, len(core))}
	for name, value := range core {
		registry.values[name] = pluginCapabilityEntry{owner: "core", value: value}
	}
	return registry
}

func (r *pluginCapabilityRegistry) get(name string) (any, bool) {
	r.mu.RLock()
	entry, ok := r.values[name]
	r.mu.RUnlock()
	return entry.value, ok
}

func (r *pluginCapabilityRegistry) provide(owner, name string, value any) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if existing, exists := r.values[name]; exists && existing.owner != owner {
		return fmt.Errorf("capability %s is already provided by %s", name, existing.owner)
	}
	r.values[name] = pluginCapabilityEntry{owner: owner, value: value}
	return nil
}

func (r *pluginCapabilityRegistry) remove(owner, name string) {
	r.mu.Lock()
	if existing, exists := r.values[name]; exists && existing.owner == owner {
		delete(r.values, name)
	}
	r.mu.Unlock()
}

func (h *PluginHost) SetRunner(isolation PluginIsolation, runner PluginRunner) error {
	h.lifecycleMu.Lock()
	defer h.lifecycleMu.Unlock()
	return h.setRunner(isolation, runner)
}

func (h *PluginHost) setRunner(isolation PluginIsolation, runner PluginRunner) error {
	if runner == nil || (isolation != PluginIsolationInProcess && isolation != PluginIsolationProcess) {
		return errors.New("invalid Fairy plugin runner")
	}
	h.mu.Lock()
	h.runners[isolation] = runner
	h.mu.Unlock()
	return nil
}

func (h *PluginHost) startAll(cfg Config) error {
	h.lifecycleMu.Lock()
	defer h.lifecycleMu.Unlock()
	order, err := h.dependencyOrder()
	if err != nil {
		return err
	}
	h.mu.Lock()
	h.order = order
	h.mu.Unlock()
	var joined error
	for _, id := range order {
		manifest := normalizePluginManifest(h.factories[id]().Manifest())
		enabled := manifest.DefaultEnabled
		if configured, exists := cfg.PluginEnabled[id]; exists {
			enabled = configured
		}
		if !enabled {
			h.mu.Lock()
			h.runtimes[id] = &pluginRuntime{factory: h.factories[id], manifest: manifest, status: PluginRuntimeStatus{PluginManifest: manifest, State: "disabled"}}
			h.mu.Unlock()
			continue
		}
		if err := h.loadLocked(id); err != nil {
			joined = errors.Join(joined, err)
		}
	}
	return joined
}

func (h *PluginHost) dependencyOrder() ([]string, error) {
	state := make(map[string]uint8, len(h.factories))
	order := make([]string, 0, len(h.factories))
	var visit func(string) error
	visit = func(id string) error {
		switch state[id] {
		case 1:
			return fmt.Errorf("Fairy plugin dependency cycle includes %q", id)
		case 2:
			return nil
		}
		factory := h.factories[id]
		if factory == nil {
			return fmt.Errorf("Fairy plugin dependency %q is not registered", id)
		}
		state[id] = 1
		manifest := normalizePluginManifest(factory().Manifest())
		for _, dependency := range manifest.Dependencies {
			if err := visit(dependency.ID); err != nil {
				return err
			}
		}
		state[id] = 2
		order = append(order, id)
		return nil
	}
	ids := make([]string, 0, len(h.factories))
	for id := range h.factories {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	for _, id := range ids {
		if err := visit(id); err != nil {
			return nil, err
		}
	}
	return order, nil
}

func (h *PluginHost) load(id string) error {
	h.lifecycleMu.Lock()
	defer h.lifecycleMu.Unlock()
	return h.loadLocked(id)
}

func (h *PluginHost) loadLocked(id string) error {
	h.mu.RLock()
	factory := h.factories[id]
	h.mu.RUnlock()
	if factory == nil {
		return fmt.Errorf("Fairy plugin %s is not registered", id)
	}
	module := factory()
	if module == nil {
		return h.recordFailure(id, errors.New("plugin factory returned nil module"))
	}
	manifest := normalizePluginManifest(module.Manifest())
	if err := manifest.Validate(); err != nil {
		return h.recordFailure(id, err)
	}
	if manifest.ID != id {
		return h.recordFailure(id, fmt.Errorf("plugin factory changed id to %s", manifest.ID))
	}
	for _, dependency := range manifest.Dependencies {
		h.mu.RLock()
		dependencyRuntime := h.runtimes[dependency.ID]
		h.mu.RUnlock()
		if dependencyRuntime == nil || dependencyRuntime.status.State != "running" {
			return h.recordFailure(id, fmt.Errorf("dependency %s is not running", dependency.ID))
		}
		if dependency.MinVersion != "" && !versionAtLeast(dependencyRuntime.manifest.Version, dependency.MinVersion) {
			return h.recordFailure(id, fmt.Errorf("dependency %s version %s does not satisfy %s", dependency.ID, dependencyRuntime.manifest.Version, dependency.MinVersion))
		}
	}
	h.mu.RLock()
	runner := h.runners[manifest.Isolation]
	h.mu.RUnlock()
	if runner == nil {
		return h.recordFailure(id, fmt.Errorf("no runner registered for isolation %s", manifest.Isolation))
	}
	scope := &PluginContext{ctx: h.ctx, manifest: manifest, capabilities: h.capabilities, bus: h.bus}
	handle, err := runner.Start(h.ctx, module, scope)
	if err != nil {
		return h.recordFailure(id, err)
	}
	if err := h.validateRegistrationSnapshot(id, scope.snapshot()); err != nil {
		_ = handle.Stop(context.Background())
		return h.recordFailure(id, err)
	}
	h.mu.Lock()
	h.runtimes[id] = &pluginRuntime{factory: factory, module: module, manifest: manifest, context: scope, handle: handle, status: PluginRuntimeStatus{PluginManifest: manifest, Enabled: true, State: "running"}}
	h.mu.Unlock()
	return nil
}

func (h *PluginHost) recordFailure(id string, err error) error {
	h.mu.Lock()
	defer h.mu.Unlock()
	factory := h.factories[id]
	manifest := PluginManifest{ID: id}
	if factory != nil {
		manifest = normalizePluginManifest(factory().Manifest())
	}
	h.runtimes[id] = &pluginRuntime{factory: factory, manifest: manifest, status: PluginRuntimeStatus{PluginManifest: manifest, Enabled: true, State: "failed", Error: "startup_failed"}}
	return fmt.Errorf("load Fairy plugin %s: %w", id, err)
}

func (h *PluginHost) validateRegistrationSnapshot(id string, candidate PluginRegistrationSnapshot) error {
	registered := func(kind, registrationID string) error {
		for otherID, runtime := range h.runtimes {
			if otherID == id || runtime == nil || runtime.status.State != "running" || runtime.context == nil {
				continue
			}
			snapshot := runtime.context.snapshot()
			var ids []string
			switch kind {
			case "command":
				for _, item := range snapshot.Commands {
					ids = append(ids, item.ID)
				}
			case "tool":
				for _, item := range snapshot.Tools {
					ids = append(ids, item.ID)
				}
			case "memory":
				for _, item := range snapshot.Memory {
					ids = append(ids, item.ID)
				}
			case "prompt":
				for _, item := range snapshot.Prompts {
					ids = append(ids, item.ID)
				}
			}
			if containsString(ids, registrationID) {
				return fmt.Errorf("plugin %s %s %q conflicts with plugin %s", id, kind, registrationID, otherID)
			}
		}
		return nil
	}
	h.mu.RLock()
	defer h.mu.RUnlock()
	for _, item := range candidate.Commands {
		if err := registered("command", item.ID); err != nil {
			return err
		}
	}
	for _, item := range candidate.Tools {
		prepared, err := prepareRegisteredTool(item.Tool, true)
		if err != nil {
			return fmt.Errorf("plugin %s tool %q is invalid: %w", id, item.ID, err)
		}
		if prepared.spec.Name != item.ID {
			return fmt.Errorf("plugin %s tool registration %q does not match spec name %q", id, item.ID, prepared.spec.Name)
		}
		if err := registered("tool", item.ID); err != nil {
			return err
		}
	}
	for _, item := range candidate.Memory {
		if err := registered("memory", item.ID); err != nil {
			return err
		}
	}
	for _, item := range candidate.Prompts {
		if err := registered("prompt", item.ID); err != nil {
			return err
		}
	}
	return nil
}

func (h *PluginHost) Commands() []Plugin {
	h.mu.RLock()
	defer h.mu.RUnlock()
	commands := make([]Plugin, 0)
	for _, id := range h.order {
		runtime := h.runtimes[id]
		if runtime == nil || runtime.status.State != "running" {
			continue
		}
		for _, registration := range runtime.context.snapshot().Commands {
			commands = append(commands, registration.Handler)
		}
	}
	return commands
}

func (h *PluginHost) Tools() []Tool {
	h.mu.RLock()
	defer h.mu.RUnlock()
	tools := make([]Tool, 0)
	for _, id := range h.order {
		runtime := h.runtimes[id]
		if runtime == nil || runtime.status.State != "running" {
			continue
		}
		for _, registration := range runtime.context.snapshot().Tools {
			tools = append(tools, registration.Tool)
		}
	}
	return tools
}

func (h *PluginHost) PromptSections(ctx context.Context) []promptSection {
	h.mu.RLock()
	providers := make([]PluginPromptProvider, 0)
	for _, id := range h.order {
		runtime := h.runtimes[id]
		if runtime == nil || runtime.status.State != "running" {
			continue
		}
		for _, registration := range runtime.context.snapshot().Prompts {
			providers = append(providers, registration.Provider)
		}
	}
	h.mu.RUnlock()
	sections := make([]promptSection, 0)
	for _, provider := range providers {
		sections = append(sections, provider.PromptSections(ctx)...)
	}
	return sections
}

// Capability returns an active service contribution to Fairy core. Plugin
// code must use PluginContext.Capability so manifest Requires declarations are
// still enforced.
func (h *PluginHost) Capability(name string) (any, bool) {
	if h == nil {
		return nil, false
	}
	return h.capabilities.get(name)
}

func (h *PluginHost) Running(id string) bool {
	if h == nil {
		return false
	}
	h.mu.RLock()
	runtime := h.runtimes[id]
	running := runtime != nil && runtime.status.State == "running"
	h.mu.RUnlock()
	return running
}

func (h *PluginHost) Emit(ctx context.Context, event *PluginEvent) error {
	if event == nil {
		return errors.New("nil Fairy plugin event")
	}
	return h.bus.emit(ctx, event)
}

func (h *PluginHost) Statuses() []PluginRuntimeStatus {
	h.mu.RLock()
	defer h.mu.RUnlock()
	statuses := make([]PluginRuntimeStatus, 0, len(h.order))
	for _, id := range h.order {
		if runtime := h.runtimes[id]; runtime != nil {
			statuses = append(statuses, runtime.status)
		}
	}
	return statuses
}

func (h *PluginHost) Unload(ctx context.Context, id string) error {
	h.lifecycleMu.Lock()
	defer h.lifecycleMu.Unlock()
	return h.unloadLocked(ctx, id)
}

func (h *PluginHost) unloadLocked(ctx context.Context, id string) error {
	h.mu.Lock()
	runtime := h.runtimes[id]
	if runtime == nil || runtime.status.State != "running" {
		h.mu.Unlock()
		return fmt.Errorf("Fairy plugin %s is not running", id)
	}
	for otherID, other := range h.runtimes {
		if otherID == id || other.status.State != "running" {
			continue
		}
		for _, dependency := range other.manifest.Dependencies {
			if dependency.ID == id {
				h.mu.Unlock()
				return fmt.Errorf("Fairy plugin %s is required by %s", id, otherID)
			}
		}
	}
	runtime.status.State = "stopping"
	h.mu.Unlock()
	if err := runtime.handle.Stop(ctx); err != nil {
		h.mu.Lock()
		runtime.status.State = "failed"
		runtime.status.Error = "shutdown_failed"
		runtime.handle = nil
		runtime.context = nil
		h.mu.Unlock()
		return err
	}
	h.mu.Lock()
	runtime.status.State = "unloaded"
	runtime.status.Error = ""
	runtime.handle = nil
	runtime.context = nil
	h.mu.Unlock()
	return nil
}

func (h *PluginHost) Reload(ctx context.Context, id string) error {
	h.lifecycleMu.Lock()
	defer h.lifecycleMu.Unlock()
	h.mu.RLock()
	runtime := h.runtimes[id]
	h.mu.RUnlock()
	if runtime == nil {
		return fmt.Errorf("Fairy plugin %s is not registered", id)
	}
	if !runtime.manifest.Reloadable {
		return fmt.Errorf("Fairy plugin %s does not support reload", id)
	}
	if err := h.unloadLocked(ctx, id); err != nil {
		return err
	}
	return h.loadLocked(id)
}

func (h *PluginHost) Close(ctx context.Context) error {
	h.lifecycleMu.Lock()
	defer h.lifecycleMu.Unlock()
	var joined error
	h.mu.RLock()
	order := append([]string(nil), h.order...)
	h.mu.RUnlock()
	for index := len(order) - 1; index >= 0; index-- {
		id := order[index]
		h.mu.RLock()
		runtime := h.runtimes[id]
		h.mu.RUnlock()
		if runtime == nil || runtime.status.State != "running" {
			continue
		}
		joined = errors.Join(joined, h.unloadLocked(ctx, id))
	}
	return joined
}

func normalizePluginManifest(manifest PluginManifest) PluginManifest {
	if manifest.Isolation == "" {
		manifest.Isolation = PluginIsolationInProcess
	}
	return manifest
}

func containsString(values []string, want string) bool {
	for _, value := range values {
		if value == want {
			return true
		}
	}
	return false
}

func containsComponent(values []PluginComponent, want PluginComponent) bool {
	for _, value := range values {
		if value == want {
			return true
		}
	}
	return false
}

func versionAtLeast(actual, minimum string) bool {
	parse := func(value string) []int {
		value = strings.TrimPrefix(strings.TrimSpace(value), "v")
		parts := strings.Split(value, ".")
		result := make([]int, 3)
		for index := 0; index < len(parts) && index < len(result); index++ {
			for _, character := range parts[index] {
				if character < '0' || character > '9' {
					return nil
				}
			}
			var number int
			for _, character := range parts[index] {
				number = number*10 + int(character-'0')
			}
			result[index] = number
		}
		return result
	}
	left, right := parse(actual), parse(minimum)
	if left == nil || right == nil {
		return actual == minimum
	}
	for index := range left {
		if left[index] != right[index] {
			return left[index] > right[index]
		}
	}
	return true
}

// legacyPluginModule lets existing command plugins participate in the package
// runtime without forcing a flag-day API migration.
type legacyPluginModule struct {
	plugin Plugin
}

func (m *legacyPluginModule) Manifest() PluginManifest {
	components := []PluginComponent{PluginComponentCommand}
	if _, ok := m.plugin.(ToolPlugin); ok {
		components = append(components, PluginComponentTool)
	}
	return PluginManifest{
		ID: m.plugin.Name(), Name: m.plugin.Name(), Version: "1.0.0", APIVersion: 1,
		Components: components, Isolation: PluginIsolationInProcess, Reloadable: false, DefaultEnabled: true,
	}
}

func (m *legacyPluginModule) Register(_ context.Context, scope *PluginContext) error {
	if err := scope.RegisterCommand(m.plugin.Name(), m.plugin); err != nil {
		return err
	}
	if tool, ok := m.plugin.(ToolPlugin); ok {
		return scope.RegisterTool(m.plugin.Name(), tool)
	}
	return nil
}

type contextMemoryModule struct {
	store *ContextStore
}

func (m *contextMemoryModule) Manifest() PluginManifest {
	return PluginManifest{
		ID: ContextMemoryPluginID, Name: "Conversation context memory", Version: "1.0.0", APIVersion: 1,
		Components: []PluginComponent{PluginComponentMemory}, Provides: []string{"memory.context"},
		Isolation: PluginIsolationInProcess, Reloadable: true, DefaultEnabled: true,
	}
}

func (m *contextMemoryModule) Register(_ context.Context, scope *PluginContext) error {
	if err := scope.ProvideCapability("memory.context", m.store); err != nil {
		return err
	}
	return scope.RegisterMemory(ContextMemoryPluginID, m.store)
}

type factMemoryModule struct {
	store FactMemoryStore
}

func (m *factMemoryModule) Manifest() PluginManifest {
	return PluginManifest{
		ID: FactMemoryPluginID, Name: "Fact memory", Version: "1.0.0", APIVersion: 1,
		Components: []PluginComponent{PluginComponentMemory}, Provides: []string{"memory.fact"},
		Isolation: PluginIsolationInProcess, Reloadable: true, DefaultEnabled: true,
	}
}

func (m *factMemoryModule) Register(_ context.Context, scope *PluginContext) error {
	// A non-nil capability wrapper keeps the module observable even in tests or
	// deployments where the optional SQLite fact store is unavailable.
	capability := &factMemoryCapability{store: m.store}
	if err := scope.ProvideCapability("memory.fact", capability); err != nil {
		return err
	}
	return scope.RegisterMemory(FactMemoryPluginID, capability)
}

type factMemoryCapability struct {
	store FactMemoryStore
}

func (c *factMemoryCapability) Store() FactMemoryStore { return c.store }

type selfCognitionModule struct{}

func (selfCognitionModule) Manifest() PluginManifest {
	return PluginManifest{
		ID: SelfCognitionPluginID, Name: "Self cognition", Version: "1.0.0", APIVersion: 1,
		Components: []PluginComponent{PluginComponentPrompt}, Provides: []string{"prompt.self_cognition"},
		Isolation: PluginIsolationInProcess, Reloadable: true, DefaultEnabled: true,
	}
}

func (selfCognitionModule) Register(_ context.Context, scope *PluginContext) error {
	provider := selfCognitionPromptProvider{}
	if err := scope.ProvideCapability("prompt.self_cognition", provider); err != nil {
		return err
	}
	return scope.RegisterPrompt(SelfCognitionPluginID, provider)
}

type selfCognitionPromptProvider struct{}

func (selfCognitionPromptProvider) PromptSections(context.Context) []promptSection {
	return []promptSection{{
		ID: "self_cognition", Version: "v1",
		Content: "You are Fairy: a bounded AI friend in ZZZ IM. You can only use tools and memory explicitly supplied by the current scope. You may explain your limits, but never claim access to hidden system state.",
	}}
}

// BuiltinPluginFactories builds the trusted core modules and adapts legacy
// command plugins. The returned factories are also the reload boundary: a
// reload gets a fresh module instance and a fresh plugin scope.
func BuiltinPluginFactories(contextStore *ContextStore, facts FactMemoryStore, plugins ...Plugin) []PluginFactory {
	factories := []PluginFactory{
		func() PluginModule { return &contextMemoryModule{store: contextStore} },
		func() PluginModule { return &factMemoryModule{store: facts} },
		func() PluginModule { return selfCognitionModule{} },
	}
	for _, plugin := range plugins {
		plugin := plugin
		factories = append(factories, func() PluginModule { return &legacyPluginModule{plugin: plugin} })
	}
	return factories
}
