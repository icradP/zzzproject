package fairy

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"
)

const (
	defaultToolMaxCalls       = 6
	defaultToolTimeout        = 15 * time.Second
	defaultToolInputBytes     = 32 * 1024
	defaultToolOutputBytes    = 64 * 1024
	defaultToolProjectionRune = 4000
)

type RiskLevel string

const (
	RiskLow    RiskLevel = "low"
	RiskMedium RiskLevel = "medium"
	RiskHigh   RiskLevel = "high"
)

type ToolConcurrency string

const (
	ToolSerial    ToolConcurrency = "serial"
	ToolParallel  ToolConcurrency = "parallel"
	ToolExclusive ToolConcurrency = "exclusive"
)

type ToolIdempotency string

const (
	ToolReadOnly      ToolIdempotency = "read_only"
	ToolIdempotent    ToolIdempotency = "idempotent"
	ToolNonIdempotent ToolIdempotency = "non_idempotent"
)

// ToolReplyMode controls whether a projected tool result is returned as-is or
// passed back through the model. Model-mediated results are still retained as
// a safe fallback if the remaining agent loop fails.
type ToolReplyMode string

const (
	ToolReplyViaModel ToolReplyMode = "model"
	ToolReplyDirect   ToolReplyMode = "direct"
)

type ToolSpec struct {
	Name           string          `json:"name"`
	Description    string          `json:"description"`
	InputSchema    json.RawMessage `json:"input_schema"`
	OutputSchema   json.RawMessage `json:"output_schema"`
	Risk           RiskLevel       `json:"risk"`
	Concurrency    ToolConcurrency `json:"concurrency"`
	Idempotency    ToolIdempotency `json:"idempotency"`
	ReplyMode      ToolReplyMode   `json:"reply_mode"`
	Timeout        time.Duration   `json:"timeout"`
	MaxInputBytes  int             `json:"max_input_bytes"`
	MaxOutputBytes int             `json:"max_output_bytes"`
}

type ToolProjection struct {
	ModelText string
	UserText  string
}

type Tool interface {
	Spec() ToolSpec
	Execute(ctx context.Context, arguments json.RawMessage) (json.RawMessage, error)
	Project(output json.RawMessage) (ToolProjection, error)
}

// ScopedTool receives identity established by the IM gateway. The scope is
// never sourced from model arguments, so account-bound tools cannot impersonate
// another sender.
type ScopedTool interface {
	Tool
	ExecuteScoped(ctx context.Context, scope ToolScope, arguments json.RawMessage) (json.RawMessage, error)
}

type ToolCall struct {
	Name      string
	Arguments json.RawMessage
	Step      int
}

type ToolFailureCode string

const (
	ToolFailureNotFound         ToolFailureCode = "tool_not_found"
	ToolFailureInvalidArguments ToolFailureCode = "invalid_arguments"
	ToolFailureNotVisible       ToolFailureCode = "not_visible"
	ToolFailureUnauthorized     ToolFailureCode = "unauthorized"
	ToolFailurePolicyDenied     ToolFailureCode = "policy_denied"
	ToolFailureLimitExceeded    ToolFailureCode = "call_limit_exceeded"
	ToolFailureTimeout          ToolFailureCode = "timeout"
	ToolFailureCancelled        ToolFailureCode = "cancelled"
	ToolFailureExecution        ToolFailureCode = "execution_failed"
	ToolFailureInvalidOutput    ToolFailureCode = "invalid_output"
	ToolFailureOutputTooLarge   ToolFailureCode = "output_too_large"
)

type ToolFailure struct {
	Code ToolFailureCode
	err  error
}

func (f *ToolFailure) Error() string {
	if f == nil {
		return ""
	}
	if f.err != nil {
		return fmt.Sprintf("Fairy tool %s: %v", f.Code, f.err)
	}
	return "Fairy tool " + string(f.Code)
}

func (f *ToolFailure) Unwrap() error {
	if f == nil {
		return nil
	}
	return f.err
}

type ToolResult struct {
	CallID      string
	ToolName    string
	ReplyMode   ToolReplyMode
	Output      json.RawMessage
	Projection  ToolProjection
	ResultBytes int
	Duration    time.Duration
	Failure     *ToolFailure
}

func (r ToolResult) OK() bool { return r.Failure == nil }

type ToolScope struct {
	ConversationID string
	MessageType    string
	SenderID       string
	VisibleTools   map[string]bool
}

func (s ToolScope) visible(name string) bool {
	return s.VisibleTools != nil && s.VisibleTools[name]
}

type ToolPolicy struct {
	Allowlist          map[string]bool
	AllowedRisks       map[RiskLevel]bool
	AllowSideEffects   bool
	MaxCalls           int
	MaxTimeout         time.Duration
	MaxInputBytes      int
	MaxOutputBytes     int
	MaxProjectionRunes int
}

func DefaultToolPolicy(toolNames []string) ToolPolicy {
	allowlist := make(map[string]bool, len(toolNames))
	for _, name := range toolNames {
		allowlist[name] = true
	}
	return ToolPolicy{
		Allowlist:          allowlist,
		AllowedRisks:       map[RiskLevel]bool{RiskLow: true},
		MaxCalls:           defaultToolMaxCalls,
		MaxTimeout:         defaultToolTimeout,
		MaxInputBytes:      defaultToolInputBytes,
		MaxOutputBytes:     defaultToolOutputBytes,
		MaxProjectionRunes: defaultToolProjectionRune,
	}
}

type ToolAuthorizer interface {
	AuthorizeTool(ctx context.Context, scope ToolScope, spec ToolSpec, arguments json.RawMessage) error
}

type registeredTool struct {
	tool         Tool
	spec         ToolSpec
	inputSchema  *toolSchema
	outputSchema *toolSchema
	dynamic      bool
}

type ToolRegistry struct {
	mu              sync.RWMutex
	tools           map[string]registeredTool
	dynamicProvider func() []Tool
}

func NewToolRegistry() *ToolRegistry {
	return &ToolRegistry{tools: make(map[string]registeredTool)}
}

func (r *ToolRegistry) Register(tool Tool) error {
	registered, err := prepareRegisteredTool(tool, false)
	if err != nil {
		return err
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	if _, exists := r.tools[registered.spec.Name]; exists {
		return fmt.Errorf("Fairy tool %s is already registered", registered.spec.Name)
	}
	r.tools[registered.spec.Name] = registered
	return nil
}

// SetDynamicProvider attaches tools owned by the plugin host. The provider is
// evaluated for every lookup, so unload and reload never leave stale plugin
// instances inside ToolRuntime.
func (r *ToolRegistry) SetDynamicProvider(provider func() []Tool) error {
	if provider == nil {
		return errors.New("dynamic Fairy tool provider is required")
	}
	tools := provider()
	seen := make(map[string]struct{}, len(tools))
	for _, tool := range tools {
		registered, err := prepareRegisteredTool(tool, true)
		if err != nil {
			return err
		}
		if _, exists := seen[registered.spec.Name]; exists {
			return fmt.Errorf("Fairy tool %s is provided more than once", registered.spec.Name)
		}
		seen[registered.spec.Name] = struct{}{}
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	for name := range seen {
		if _, exists := r.tools[name]; exists {
			return fmt.Errorf("Fairy tool %s conflicts with a static tool", name)
		}
	}
	r.dynamicProvider = provider
	return nil
}

func (r *ToolRegistry) Resolve(name string) (ToolSpec, bool) {
	registered, ok := r.registered(name)
	return cloneToolSpec(registered.spec), ok
}

func (r *ToolRegistry) Names() []string {
	r.mu.RLock()
	provider := r.dynamicProvider
	names := make([]string, 0, len(r.tools))
	seen := make(map[string]struct{}, len(r.tools))
	for name := range r.tools {
		names = append(names, name)
		seen[name] = struct{}{}
	}
	r.mu.RUnlock()
	if provider != nil {
		for _, tool := range provider() {
			registered, err := prepareRegisteredTool(tool, true)
			if err != nil {
				continue
			}
			if _, exists := seen[registered.spec.Name]; exists {
				continue
			}
			seen[registered.spec.Name] = struct{}{}
			names = append(names, registered.spec.Name)
		}
	}
	sort.Strings(names)
	return names
}

func (r *ToolRegistry) List() []ToolSpec {
	names := r.Names()
	tools := make([]ToolSpec, 0, len(names))
	for _, name := range names {
		if spec, ok := r.Resolve(name); ok {
			tools = append(tools, spec)
		}
	}
	return tools
}

func (r *ToolRegistry) PolicyAllows(name string, policy ToolPolicy) bool {
	registered, ok := r.registered(name)
	return ok && toolPolicyAllows(registered, policy)
}

func (r *ToolRegistry) registered(name string) (registeredTool, bool) {
	r.mu.RLock()
	tool, ok := r.tools[name]
	provider := r.dynamicProvider
	r.mu.RUnlock()
	if ok || provider == nil {
		return tool, ok
	}
	for _, candidate := range provider() {
		registered, err := prepareRegisteredTool(candidate, true)
		if err == nil && registered.spec.Name == name {
			return registered, true
		}
	}
	return registeredTool{}, false
}

func prepareRegisteredTool(tool Tool, dynamic bool) (registeredTool, error) {
	if tool == nil {
		return registeredTool{}, fmt.Errorf("register nil Fairy tool")
	}
	spec := cloneToolSpec(tool.Spec())
	if spec.ReplyMode == "" {
		spec.ReplyMode = ToolReplyViaModel
	}
	if err := validateToolSpec(spec); err != nil {
		return registeredTool{}, err
	}
	inputSchema, err := compileToolSchema(spec.InputSchema)
	if err != nil {
		return registeredTool{}, fmt.Errorf("compile input schema for Fairy tool %s: %w", spec.Name, err)
	}
	outputSchema, err := compileToolSchema(spec.OutputSchema)
	if err != nil {
		return registeredTool{}, fmt.Errorf("compile output schema for Fairy tool %s: %w", spec.Name, err)
	}
	return registeredTool{tool: tool, spec: spec, inputSchema: inputSchema, outputSchema: outputSchema, dynamic: dynamic}, nil
}

type ToolRuntime struct {
	registry   *ToolRegistry
	policy     ToolPolicy
	authorizer ToolAuthorizer
	trace      TraceStore
	exclusive  chan struct{}
}

func NewToolRuntime(registry *ToolRegistry, policy ToolPolicy, authorizer ToolAuthorizer, trace TraceStore) *ToolRuntime {
	return &ToolRuntime{
		registry: registry, policy: normalizeToolPolicy(policy), authorizer: authorizer,
		trace: trace, exclusive: make(chan struct{}, 1),
	}
}

type ToolSession struct {
	runtime *ToolRuntime
	scope   ToolScope
	mu      sync.Mutex
	calls   int
}

func (r *ToolRuntime) NewSession(scope ToolScope) *ToolSession {
	return &ToolSession{runtime: r, scope: scope}
}

func (s *ToolSession) Execute(ctx context.Context, call ToolCall) ToolResult {
	s.mu.Lock()
	defer s.mu.Unlock()

	started := time.Now()
	callID, err := newRuntimeID("tool")
	if err != nil {
		return ToolResult{ToolName: call.Name, Duration: time.Since(started), Failure: &ToolFailure{Code: ToolFailureExecution, err: err}}
	}
	result := ToolResult{CallID: callID, ToolName: call.Name}
	policyResult := "not_evaluated"
	finish := func(failure *ToolFailure) ToolResult {
		result.Duration = time.Since(started)
		result.Failure = failure
		if failure != nil && (failure.Code == ToolFailureNotVisible || failure.Code == ToolFailureUnauthorized || failure.Code == ToolFailurePolicyDenied || failure.Code == ToolFailureLimitExceeded) {
			policyResult = "denied"
		}
		s.runtime.appendTrace(ctx, s.scope, call, result, policyResult)
		return result
	}

	if s.runtime == nil {
		result.Duration = time.Since(started)
		result.Failure = &ToolFailure{Code: ToolFailureNotFound}
		return result
	}
	if s.runtime.registry == nil {
		return finish(&ToolFailure{Code: ToolFailureNotFound})
	}
	registered, ok := s.runtime.registry.registered(call.Name)
	if !ok {
		return finish(&ToolFailure{Code: ToolFailureNotFound})
	}
	result.ReplyMode = registered.spec.ReplyMode
	policy := s.runtime.policy
	inputLimit := minPositive(registered.spec.MaxInputBytes, policy.MaxInputBytes)
	if len(call.Arguments) == 0 || len(call.Arguments) > inputLimit {
		return finish(&ToolFailure{Code: ToolFailureInvalidArguments})
	}
	if err := registered.inputSchema.Validate(call.Arguments); err != nil {
		return finish(&ToolFailure{Code: ToolFailureInvalidArguments, err: err})
	}
	if !s.scope.visible(call.Name) {
		return finish(&ToolFailure{Code: ToolFailureNotVisible})
	}
	if s.runtime.authorizer != nil {
		if err := s.runtime.authorizer.AuthorizeTool(ctx, s.scope, registered.spec, append(json.RawMessage(nil), call.Arguments...)); err != nil {
			return finish(&ToolFailure{Code: ToolFailureUnauthorized})
		}
	}
	if !toolPolicyAllows(registered, policy) {
		return finish(&ToolFailure{Code: ToolFailurePolicyDenied})
	}
	if s.calls >= policy.MaxCalls {
		return finish(&ToolFailure{Code: ToolFailureLimitExceeded})
	}
	s.calls++
	policyResult = "allowed"

	timeout := minDuration(registered.spec.Timeout, policy.MaxTimeout)
	toolCtx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	if registered.spec.Concurrency == ToolExclusive {
		select {
		case s.runtime.exclusive <- struct{}{}:
			defer func() { <-s.runtime.exclusive }()
		case <-toolCtx.Done():
			if errors.Is(toolCtx.Err(), context.DeadlineExceeded) {
				return finish(&ToolFailure{Code: ToolFailureTimeout})
			}
			return finish(&ToolFailure{Code: ToolFailureCancelled})
		}
	}
	arguments := append(json.RawMessage(nil), call.Arguments...)
	var output json.RawMessage
	var executeErr error
	if scoped, ok := registered.tool.(ScopedTool); ok {
		output, executeErr = scoped.ExecuteScoped(toolCtx, s.scope, arguments)
	} else {
		output, executeErr = registered.tool.Execute(toolCtx, arguments)
	}
	contextErr := toolCtx.Err()
	if contextErr != nil {
		if errors.Is(contextErr, context.DeadlineExceeded) {
			return finish(&ToolFailure{Code: ToolFailureTimeout})
		}
		return finish(&ToolFailure{Code: ToolFailureCancelled})
	}
	if executeErr != nil {
		switch {
		case errors.Is(contextErr, context.DeadlineExceeded) || errors.Is(executeErr, context.DeadlineExceeded):
			return finish(&ToolFailure{Code: ToolFailureTimeout})
		case errors.Is(contextErr, context.Canceled) || errors.Is(executeErr, context.Canceled):
			return finish(&ToolFailure{Code: ToolFailureCancelled})
		default:
			return finish(&ToolFailure{Code: ToolFailureExecution, err: executeErr})
		}
	}
	result.ResultBytes = len(output)
	outputLimit := minPositive(registered.spec.MaxOutputBytes, policy.MaxOutputBytes)
	if len(output) == 0 {
		return finish(&ToolFailure{Code: ToolFailureInvalidOutput})
	}
	if len(output) > outputLimit {
		return finish(&ToolFailure{Code: ToolFailureOutputTooLarge})
	}
	if err := registered.outputSchema.Validate(output); err != nil {
		return finish(&ToolFailure{Code: ToolFailureInvalidOutput, err: err})
	}
	projection, err := registered.tool.Project(append(json.RawMessage(nil), output...))
	if err != nil {
		return finish(&ToolFailure{Code: ToolFailureInvalidOutput, err: err})
	}
	if containsSensitiveCredential(projection.ModelText) {
		projection.ModelText = "[sensitive tool content redacted]"
	}
	if containsSensitiveCredential(projection.UserText) {
		projection.UserText = "工具结果包含疑似敏感凭据，已隐藏。"
	}
	projection.ModelText = strings.TrimSpace(limitRunes(projection.ModelText, policy.MaxProjectionRunes))
	projection.UserText = strings.TrimSpace(limitRunes(projection.UserText, policy.MaxProjectionRunes))
	if registered.spec.ReplyMode == ToolReplyDirect && projection.UserText == "" {
		return finish(&ToolFailure{Code: ToolFailureInvalidOutput, err: errors.New("direct reply tool requires a user projection")})
	}
	if projection.ModelText == "" && projection.UserText == "" {
		return finish(&ToolFailure{Code: ToolFailureInvalidOutput})
	}
	result.Output = append(json.RawMessage(nil), output...)
	result.Projection = projection
	return finish(nil)
}

func toolPolicyAllows(registered registeredTool, policy ToolPolicy) bool {
	return (registered.dynamic || policy.Allowlist[registered.spec.Name]) &&
		policy.AllowedRisks[registered.spec.Risk] &&
		(registered.spec.Idempotency == ToolReadOnly || policy.AllowSideEffects)
}

func (r *ToolRuntime) appendTrace(ctx context.Context, scope ToolScope, call ToolCall, result ToolResult, policyResult string) {
	if r == nil || r.trace == nil || result.CallID == "" {
		return
	}
	traceScope, ok := turnTraceScopeFromContext(ctx)
	if !ok {
		traceID, traceErr := newRuntimeID("trace")
		turnID, turnErr := newRuntimeID("turn")
		if traceErr != nil || turnErr != nil {
			return
		}
		traceScope = TurnTraceScope{TraceID: traceID, TurnID: turnID, ConversationID: scope.ConversationID, Source: "tool-runtime"}
	}
	status := "completed"
	toolStatus := "completed"
	failureCode := ""
	if result.Failure != nil {
		status = "failed"
		failureCode = string(result.Failure.Code)
		switch result.Failure.Code {
		case ToolFailureTimeout:
			toolStatus = "timed_out"
		case ToolFailureCancelled:
			toolStatus = "cancelled"
		case ToolFailureNotVisible, ToolFailureUnauthorized, ToolFailurePolicyDenied, ToolFailureLimitExceeded:
			toolStatus = "rejected"
		default:
			toolStatus = "failed"
		}
	}
	toolRisk := "unknown"
	if r.registry != nil {
		if spec, found := r.registry.Resolve(call.Name); found {
			toolRisk = string(spec.Risk)
		}
	}
	event := TraceEvent{
		Time: time.Now(), Type: TraceToolCall,
		TraceID: traceScope.TraceID, TurnID: traceScope.TurnID, ConversationID: traceScope.ConversationID,
		Source: traceScope.Source, Status: status, Step: call.Step,
		ToolCallID: result.CallID, ToolName: call.Name, ToolRisk: toolRisk,
		ToolPolicy: policyResult, ToolStatus: toolStatus, DurationMS: result.Duration.Milliseconds(),
		ToolResultBytes: result.ResultBytes, FailureCode: failureCode,
		Detail: toolTraceDetail(call, result),
	}
	traceCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := r.trace.Append(traceCtx, event); err != nil {
		log.Printf("[fairy] append tool trace: %v", err)
	}
}

func toolTraceDetail(call ToolCall, result ToolResult) json.RawMessage {
	detail := struct {
		Arguments         json.RawMessage `json:"arguments,omitempty"`
		ArgumentsRedacted bool            `json:"arguments_redacted,omitempty"`
		ModelResult       string          `json:"model_result,omitempty"`
		UserResult        string          `json:"user_result,omitempty"`
	}{
		ModelResult: result.Projection.ModelText,
		UserResult:  result.Projection.UserText,
	}
	if containsSensitiveCredential(string(call.Arguments)) {
		detail.ArgumentsRedacted = true
	} else {
		detail.Arguments = append(json.RawMessage(nil), call.Arguments...)
	}
	encoded, err := json.Marshal(detail)
	if err != nil {
		return nil
	}
	return encoded
}

func normalizeToolPolicy(policy ToolPolicy) ToolPolicy {
	policy.Allowlist = cloneBoolMap(policy.Allowlist)
	policy.AllowedRisks = cloneRiskMap(policy.AllowedRisks)
	if policy.AllowedRisks == nil {
		policy.AllowedRisks = map[RiskLevel]bool{RiskLow: true}
	}
	if policy.MaxCalls <= 0 {
		policy.MaxCalls = defaultToolMaxCalls
	}
	if policy.MaxTimeout <= 0 {
		policy.MaxTimeout = defaultToolTimeout
	}
	if policy.MaxInputBytes <= 0 {
		policy.MaxInputBytes = defaultToolInputBytes
	}
	if policy.MaxOutputBytes <= 0 {
		policy.MaxOutputBytes = defaultToolOutputBytes
	}
	if policy.MaxProjectionRunes <= 0 {
		policy.MaxProjectionRunes = defaultToolProjectionRune
	}
	return policy
}

func cloneToolSpec(spec ToolSpec) ToolSpec {
	spec.InputSchema = append(json.RawMessage(nil), spec.InputSchema...)
	spec.OutputSchema = append(json.RawMessage(nil), spec.OutputSchema...)
	return spec
}

func cloneBoolMap(source map[string]bool) map[string]bool {
	clone := make(map[string]bool, len(source))
	for key, value := range source {
		clone[key] = value
	}
	return clone
}

func cloneRiskMap(source map[RiskLevel]bool) map[RiskLevel]bool {
	if source == nil {
		return nil
	}
	clone := make(map[RiskLevel]bool, len(source))
	for key, value := range source {
		clone[key] = value
	}
	return clone
}

func validateToolSpec(spec ToolSpec) error {
	if !validTraceLabel(spec.Name) {
		return fmt.Errorf("invalid Fairy tool name %q", spec.Name)
	}
	if strings.TrimSpace(spec.Description) == "" || len([]rune(spec.Description)) > 500 {
		return fmt.Errorf("Fairy tool %s description must contain 1-500 characters", spec.Name)
	}
	switch spec.Risk {
	case RiskLow, RiskMedium, RiskHigh:
	default:
		return fmt.Errorf("Fairy tool %s has invalid risk", spec.Name)
	}
	switch spec.Concurrency {
	case ToolSerial, ToolParallel, ToolExclusive:
	default:
		return fmt.Errorf("Fairy tool %s has invalid concurrency", spec.Name)
	}
	switch spec.Idempotency {
	case ToolReadOnly, ToolIdempotent, ToolNonIdempotent:
	default:
		return fmt.Errorf("Fairy tool %s has invalid idempotency", spec.Name)
	}
	switch spec.ReplyMode {
	case ToolReplyViaModel, ToolReplyDirect:
	default:
		return fmt.Errorf("Fairy tool %s has invalid reply mode", spec.Name)
	}
	if spec.Timeout <= 0 || spec.Timeout > 2*time.Minute || spec.MaxInputBytes <= 0 || spec.MaxInputBytes > 1024*1024 || spec.MaxOutputBytes <= 0 || spec.MaxOutputBytes > 1024*1024 {
		return fmt.Errorf("Fairy tool %s has invalid runtime limits", spec.Name)
	}
	return nil
}

type toolSchema struct {
	Type                 string                 `json:"type"`
	Properties           map[string]*toolSchema `json:"properties,omitempty"`
	Required             []string               `json:"required,omitempty"`
	AdditionalProperties *bool                  `json:"additionalProperties,omitempty"`
	Items                *toolSchema            `json:"items,omitempty"`
	MinLength            *int                   `json:"minLength,omitempty"`
	MaxLength            *int                   `json:"maxLength,omitempty"`
	Pattern              string                 `json:"pattern,omitempty"`
	Minimum              *float64               `json:"minimum,omitempty"`
	Maximum              *float64               `json:"maximum,omitempty"`
	pattern              *regexp.Regexp
}

func compileToolSchema(raw json.RawMessage) (*toolSchema, error) {
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	var schema toolSchema
	if err := decoder.Decode(&schema); err != nil {
		return nil, err
	}
	if err := ensureJSONEOF(decoder); err != nil {
		return nil, err
	}
	if schema.Type != "object" {
		return nil, fmt.Errorf("root schema type must be object")
	}
	if err := schema.compile("$"); err != nil {
		return nil, err
	}
	return &schema, nil
}

func (s *toolSchema) compile(path string) error {
	switch s.Type {
	case "object":
		required := make(map[string]bool, len(s.Required))
		for _, name := range s.Required {
			if required[name] || s.Properties[name] == nil {
				return fmt.Errorf("%s has invalid required property %q", path, name)
			}
			required[name] = true
		}
		for name, property := range s.Properties {
			if property == nil || !validSchemaPropertyName(name) {
				return fmt.Errorf("%s has invalid property %q", path, name)
			}
			if err := property.compile(path + "." + name); err != nil {
				return err
			}
		}
	case "array":
		if s.Items == nil {
			return fmt.Errorf("%s array schema requires items", path)
		}
		if err := s.Items.compile(path + "[]"); err != nil {
			return err
		}
	case "string":
		if s.MinLength != nil && *s.MinLength < 0 || s.MaxLength != nil && *s.MaxLength < 0 || s.MinLength != nil && s.MaxLength != nil && *s.MinLength > *s.MaxLength {
			return fmt.Errorf("%s has invalid string length limits", path)
		}
		if s.Pattern != "" {
			pattern, err := regexp.Compile(s.Pattern)
			if err != nil {
				return fmt.Errorf("%s has invalid pattern: %w", path, err)
			}
			s.pattern = pattern
		}
	case "integer", "number", "boolean", "null":
	default:
		return fmt.Errorf("%s has unsupported type %q", path, s.Type)
	}
	if s.Minimum != nil && s.Maximum != nil && *s.Minimum > *s.Maximum {
		return fmt.Errorf("%s has invalid numeric limits", path)
	}
	return nil
}

func (s *toolSchema) Validate(raw json.RawMessage) error {
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.UseNumber()
	var value interface{}
	if err := decoder.Decode(&value); err != nil {
		return err
	}
	if err := ensureJSONEOF(decoder); err != nil {
		return err
	}
	return s.validateValue(value, "$")
}

func (s *toolSchema) validateValue(value interface{}, path string) error {
	switch s.Type {
	case "object":
		object, ok := value.(map[string]interface{})
		if !ok {
			return fmt.Errorf("%s must be an object", path)
		}
		for _, name := range s.Required {
			if _, exists := object[name]; !exists {
				return fmt.Errorf("%s.%s is required", path, name)
			}
		}
		allowAdditional := s.AdditionalProperties == nil || *s.AdditionalProperties
		for name, child := range object {
			property, exists := s.Properties[name]
			if !exists {
				if !allowAdditional {
					return fmt.Errorf("%s.%s is not allowed", path, name)
				}
				continue
			}
			if err := property.validateValue(child, path+"."+name); err != nil {
				return err
			}
		}
	case "array":
		array, ok := value.([]interface{})
		if !ok {
			return fmt.Errorf("%s must be an array", path)
		}
		for index, child := range array {
			if err := s.Items.validateValue(child, fmt.Sprintf("%s[%d]", path, index)); err != nil {
				return err
			}
		}
	case "string":
		text, ok := value.(string)
		if !ok {
			return fmt.Errorf("%s must be a string", path)
		}
		length := len([]rune(text))
		if s.MinLength != nil && length < *s.MinLength || s.MaxLength != nil && length > *s.MaxLength || s.pattern != nil && !s.pattern.MatchString(text) {
			return fmt.Errorf("%s does not satisfy its string constraints", path)
		}
	case "integer", "number":
		number, ok := value.(json.Number)
		if !ok {
			return fmt.Errorf("%s must be a number", path)
		}
		if s.Type == "integer" {
			if _, err := number.Int64(); err != nil {
				return fmt.Errorf("%s must be an integer", path)
			}
		}
		numeric, err := number.Float64()
		if err != nil || s.Minimum != nil && numeric < *s.Minimum || s.Maximum != nil && numeric > *s.Maximum {
			return fmt.Errorf("%s does not satisfy its numeric constraints", path)
		}
	case "boolean":
		if _, ok := value.(bool); !ok {
			return fmt.Errorf("%s must be a boolean", path)
		}
	case "null":
		if value != nil {
			return fmt.Errorf("%s must be null", path)
		}
	}
	return nil
}

func ensureJSONEOF(decoder *json.Decoder) error {
	var extra interface{}
	if err := decoder.Decode(&extra); err == nil {
		return fmt.Errorf("JSON contains trailing data")
	} else if !errors.Is(err, io.EOF) {
		return err
	}
	return nil
}

func validSchemaPropertyName(value string) bool {
	if value == "" || len(value) > 64 {
		return false
	}
	for _, character := range value {
		if character >= 'a' && character <= 'z' || character >= 'A' && character <= 'Z' || character >= '0' && character <= '9' || character == '_' || character == '-' {
			continue
		}
		return false
	}
	return true
}

func minPositive(left, right int) int {
	if left <= 0 {
		return right
	}
	if right <= 0 || left < right {
		return left
	}
	return right
}

func minDuration(left, right time.Duration) time.Duration {
	if left <= 0 {
		return right
	}
	if right <= 0 || left < right {
		return left
	}
	return right
}
