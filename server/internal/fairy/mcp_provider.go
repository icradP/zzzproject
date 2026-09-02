package fairy

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

const (
	MCPStdioProtocol                = "mcp-stdio"
	defaultMCPStartupTimeout        = 10 * time.Second
	defaultMCPCallTimeout           = 15 * time.Second
	defaultMCPFailureThreshold      = 3
	defaultMCPResetTimeout          = 30 * time.Second
	defaultMCPMaxOutputBytes        = 64 * 1024
	maxMCPProviders                 = 8
	maxMCPToolsPerProvider          = 64
	maxMCPListPages                 = 64
	maxMCPEnvironmentValueBytes     = 8 * 1024
	maxMCPNormalizedContentRunes    = 32 * 1024
	maxMCPNormalizedStructuredRunes = 32 * 1024
)

type ExternalToolProviderConfig struct {
	ID                   string
	Enabled              bool
	Protocol             string
	Command              string
	Args                 []string
	WorkingDirectory     string
	EnvironmentAllowlist []string
	AllowedTools         []string
	StartupTimeout       time.Duration
	CallTimeout          time.Duration
	FailureThreshold     int
	ResetTimeout         time.Duration
	MaxOutputBytes       int
}

type ExternalToolProviderStatus struct {
	ID               string `json:"id"`
	Status           string `json:"status"`
	Tools            int    `json:"tools"`
	ConsecutiveFails int    `json:"consecutive_failures"`
	CircuitOpenUntil string `json:"circuit_open_until,omitempty"`
}

type ExternalToolManager struct {
	providers []*mcpProvider
	tools     []Tool
}

func StartExternalToolManager(ctx context.Context, configs []ExternalToolProviderConfig) *ExternalToolManager {
	manager := &ExternalToolManager{
		providers: make([]*mcpProvider, 0, len(configs)),
		tools:     make([]Tool, 0),
	}
	for _, cfg := range configs {
		provider := newMCPProvider(cfg)
		manager.providers = append(manager.providers, provider)
		if !cfg.Enabled {
			continue
		}
		startupCtx, cancel := context.WithTimeout(ctx, cfg.StartupTimeout)
		tools, err := provider.start(startupCtx)
		cancel()
		if err != nil {
			provider.markStartupFailed()
			continue
		}
		manager.tools = append(manager.tools, tools...)
	}
	sort.Slice(manager.tools, func(left, right int) bool {
		return manager.tools[left].Spec().Name < manager.tools[right].Spec().Name
	})
	return manager
}

func (m *ExternalToolManager) Tools() []Tool {
	if m == nil {
		return nil
	}
	return append([]Tool(nil), m.tools...)
}

func (m *ExternalToolManager) Status() []ExternalToolProviderStatus {
	if m == nil {
		return nil
	}
	statuses := make([]ExternalToolProviderStatus, 0, len(m.providers))
	for _, provider := range m.providers {
		statuses = append(statuses, provider.status())
	}
	return statuses
}

func (m *ExternalToolManager) Close() error {
	if m == nil {
		return nil
	}
	var result error
	for _, provider := range m.providers {
		result = errors.Join(result, provider.close())
	}
	return result
}

type mcpProvider struct {
	cfg ExternalToolProviderConfig

	callMu           sync.Mutex
	mu               sync.Mutex
	session          *mcp.ClientSession
	toolCount        int
	failures         int
	circuitOpenUntil time.Time
	startupFailed    bool
	closed           bool
	now              func() time.Time
}

func newMCPProvider(cfg ExternalToolProviderConfig) *mcpProvider {
	return &mcpProvider{cfg: cfg, now: time.Now}
}

func (p *mcpProvider) start(ctx context.Context) ([]Tool, error) {
	p.callMu.Lock()
	defer p.callMu.Unlock()
	session, err := p.connect(ctx)
	if err != nil {
		return nil, err
	}
	remoteTools, err := listMCPTools(ctx, session)
	if err != nil {
		p.dropSession()
		return nil, err
	}
	allowed := make(map[string]bool, len(p.cfg.AllowedTools))
	for _, name := range p.cfg.AllowedTools {
		allowed[name] = true
	}
	tools := make([]Tool, 0, len(allowed))
	seen := make(map[string]bool, len(remoteTools))
	for _, remote := range remoteTools {
		if remote == nil || !allowed[remote.Name] || seen[remote.Name] {
			continue
		}
		seen[remote.Name] = true
		tool, err := newMCPTool(p, remote)
		if err != nil {
			continue
		}
		tools = append(tools, tool)
	}
	sort.Slice(tools, func(left, right int) bool {
		return tools[left].Spec().Name < tools[right].Spec().Name
	})
	p.mu.Lock()
	p.toolCount = len(tools)
	p.startupFailed = false
	p.mu.Unlock()
	return tools, nil
}

func (p *mcpProvider) connect(ctx context.Context) (*mcp.ClientSession, error) {
	p.mu.Lock()
	if p.closed {
		p.mu.Unlock()
		return nil, fmt.Errorf("MCP provider is closed")
	}
	if p.session != nil {
		session := p.session
		p.mu.Unlock()
		return session, nil
	}
	now := p.now()
	if now.Before(p.circuitOpenUntil) {
		p.mu.Unlock()
		return nil, fmt.Errorf("MCP provider circuit is open")
	}
	p.circuitOpenUntil = time.Time{}
	p.mu.Unlock()

	command := exec.Command(p.cfg.Command, p.cfg.Args...)
	command.Dir = p.cfg.WorkingDirectory
	command.Env = allowedMCPEnvironment(p.cfg.EnvironmentAllowlist)
	command.Stderr = io.Discard
	client := mcp.NewClient(
		&mcp.Implementation{Name: "zzz-im-fairy", Version: "v1"},
		&mcp.ClientOptions{
			Logger:       slog.New(slog.NewTextHandler(io.Discard, nil)),
			Capabilities: &mcp.ClientCapabilities{},
		},
	)
	session, err := client.Connect(ctx, &mcp.CommandTransport{
		Command: command, TerminateDuration: time.Second,
	}, nil)
	if err != nil {
		return nil, err
	}
	p.mu.Lock()
	if p.closed {
		p.mu.Unlock()
		_ = closeMCPSession(session)
		return nil, fmt.Errorf("MCP provider is closed")
	}
	p.session = session
	p.mu.Unlock()
	return session, nil
}

func (p *mcpProvider) execute(ctx context.Context, name string, arguments json.RawMessage) (json.RawMessage, error) {
	p.callMu.Lock()
	defer p.callMu.Unlock()

	callCtx, cancel := context.WithTimeout(ctx, p.cfg.CallTimeout)
	defer cancel()
	session, err := p.connect(callCtx)
	if err != nil {
		p.recordFailure(false)
		return nil, err
	}
	var input map[string]interface{}
	decoder := json.NewDecoder(strings.NewReader(string(arguments)))
	decoder.UseNumber()
	if err := decoder.Decode(&input); err != nil {
		return nil, err
	}
	result, err := session.CallTool(callCtx, &mcp.CallToolParams{Name: name, Arguments: input})
	if err != nil {
		p.dropSession()
		p.recordFailure(true)
		if callCtx.Err() != nil {
			return nil, callCtx.Err()
		}
		return nil, err
	}
	if result == nil || result.IsError || result.NeedsInput() {
		p.recordFailure(false)
		return nil, fmt.Errorf("MCP tool did not return a successful final result")
	}
	output, err := normalizeMCPToolResult(p.cfg.ID, name, result, p.cfg.MaxOutputBytes)
	if err != nil {
		p.recordFailure(false)
		return nil, err
	}
	p.recordSuccess()
	return output, nil
}

func (p *mcpProvider) recordFailure(forceOpen bool) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.failures++
	if forceOpen || p.failures >= p.cfg.FailureThreshold {
		p.circuitOpenUntil = p.now().Add(p.cfg.ResetTimeout)
	}
}

func (p *mcpProvider) recordSuccess() {
	p.mu.Lock()
	p.failures = 0
	p.circuitOpenUntil = time.Time{}
	p.startupFailed = false
	p.mu.Unlock()
}

func (p *mcpProvider) markStartupFailed() {
	p.mu.Lock()
	p.startupFailed = true
	p.failures++
	p.mu.Unlock()
}

func (p *mcpProvider) dropSession() {
	p.mu.Lock()
	session := p.session
	p.session = nil
	p.mu.Unlock()
	if session != nil {
		_ = closeMCPSession(session)
	}
}

func (p *mcpProvider) close() error {
	p.callMu.Lock()
	defer p.callMu.Unlock()
	p.mu.Lock()
	p.closed = true
	session := p.session
	p.session = nil
	p.mu.Unlock()
	if session == nil {
		return nil
	}
	return closeMCPSession(session)
}

func closeMCPSession(session *mcp.ClientSession) error {
	if session == nil {
		return nil
	}
	return normalizeMCPShutdownError(session.Close())
}

func normalizeMCPShutdownError(err error) error {
	if errors.Is(err, os.ErrProcessDone) {
		return nil
	}
	return err
}

func (p *mcpProvider) status() ExternalToolProviderStatus {
	p.mu.Lock()
	defer p.mu.Unlock()
	status := "unavailable"
	switch {
	case !p.cfg.Enabled:
		status = "disabled"
	case p.closed:
		status = "closed"
	case p.now().Before(p.circuitOpenUntil):
		status = "circuit_open"
	case p.session != nil:
		status = "ready"
	case p.startupFailed:
		status = "startup_failed"
	}
	result := ExternalToolProviderStatus{
		ID: p.cfg.ID, Status: status, Tools: p.toolCount, ConsecutiveFails: p.failures,
	}
	if p.now().Before(p.circuitOpenUntil) {
		result.CircuitOpenUntil = p.circuitOpenUntil.UTC().Format(time.RFC3339)
	}
	return result
}

func listMCPTools(ctx context.Context, session *mcp.ClientSession) ([]*mcp.Tool, error) {
	tools := make([]*mcp.Tool, 0)
	cursor := ""
	seenCursors := make(map[string]bool)
	for page := 0; page < maxMCPListPages; page++ {
		result, err := session.ListTools(ctx, &mcp.ListToolsParams{Cursor: cursor})
		if err != nil {
			return nil, err
		}
		if result == nil || len(tools)+len(result.Tools) > maxMCPToolsPerProvider {
			return nil, fmt.Errorf("MCP provider returned too many tools")
		}
		tools = append(tools, result.Tools...)
		if result.NextCursor == "" {
			return tools, nil
		}
		if seenCursors[result.NextCursor] {
			return nil, fmt.Errorf("MCP provider repeated a tools/list cursor")
		}
		seenCursors[result.NextCursor] = true
		cursor = result.NextCursor
	}
	return nil, fmt.Errorf("MCP provider exceeded the tools/list page limit")
}

type mcpTool struct {
	provider   *mcpProvider
	remoteName string
	spec       ToolSpec
}

func newMCPTool(provider *mcpProvider, remote *mcp.Tool) (*mcpTool, error) {
	if provider == nil || remote == nil || !validTraceLabel(remote.Name) {
		return nil, fmt.Errorf("invalid MCP tool")
	}
	if remote.Annotations == nil || !remote.Annotations.ReadOnlyHint ||
		(remote.Annotations.DestructiveHint != nil && *remote.Annotations.DestructiveHint) {
		return nil, fmt.Errorf("MCP tool is not explicitly read-only")
	}
	name := provider.cfg.ID + "." + remote.Name
	if !validTraceLabel(name) {
		return nil, fmt.Errorf("invalid namespaced MCP tool name")
	}
	inputSchema, err := json.Marshal(remote.InputSchema)
	if err != nil {
		return nil, err
	}
	if _, err := compileToolSchema(inputSchema); err != nil {
		return nil, err
	}
	description := strings.TrimSpace(limitRunes(remote.Description, 500))
	if description == "" {
		description = "Read data from the configured external provider."
	}
	outputSchema := json.RawMessage(`{"type":"object","properties":{"provider":{"type":"string"},"tool":{"type":"string"},"text":{"type":"string"},"structured_json":{"type":"string"}},"required":["provider","tool","text","structured_json"],"additionalProperties":false}`)
	return &mcpTool{
		provider:   provider,
		remoteName: remote.Name,
		spec: ToolSpec{
			Name: name, Description: description, InputSchema: inputSchema, OutputSchema: outputSchema,
			Risk: RiskLow, Concurrency: ToolSerial, Idempotency: ToolReadOnly,
			Timeout: provider.cfg.CallTimeout, MaxInputBytes: defaultToolInputBytes,
			MaxOutputBytes: provider.cfg.MaxOutputBytes,
		},
	}, nil
}

func (t *mcpTool) Spec() ToolSpec { return cloneToolSpec(t.spec) }

func (t *mcpTool) Execute(ctx context.Context, arguments json.RawMessage) (json.RawMessage, error) {
	return t.provider.execute(ctx, t.remoteName, arguments)
}

func (t *mcpTool) Project(output json.RawMessage) (ToolProjection, error) {
	var value normalizedMCPToolResult
	if err := json.Unmarshal(output, &value); err != nil {
		return ToolProjection{}, err
	}
	return ToolProjection{
		ModelText: string(output),
		UserText:  strings.TrimSpace(value.Text + "\n" + value.StructuredJSON),
	}, nil
}

type normalizedMCPToolResult struct {
	Provider       string `json:"provider"`
	Tool           string `json:"tool"`
	Text           string `json:"text"`
	StructuredJSON string `json:"structured_json"`
}

func normalizeMCPToolResult(providerID, toolName string, result *mcp.CallToolResult, limit int) (json.RawMessage, error) {
	encoded, err := json.Marshal(result)
	if err != nil {
		return nil, err
	}
	if len(encoded) > limit {
		return nil, fmt.Errorf("MCP tool output exceeds %d bytes", limit)
	}
	textParts := make([]string, 0, len(result.Content))
	for _, content := range result.Content {
		switch value := content.(type) {
		case *mcp.TextContent:
			textParts = append(textParts, value.Text)
		case *mcp.ResourceLink:
			link := strings.TrimSpace(value.URI)
			if link == "" || containsDangerousOutputLink(link) {
				return nil, fmt.Errorf("MCP tool returned an unsafe resource link")
			}
			textParts = append(textParts, strings.TrimSpace(value.Name+" "+link))
		default:
			return nil, fmt.Errorf("MCP tool returned unsupported non-text content")
		}
	}
	structured := ""
	if result.StructuredContent != nil {
		content, err := json.Marshal(result.StructuredContent)
		if err != nil {
			return nil, err
		}
		structured = string(content)
	}
	value := normalizedMCPToolResult{
		Provider:       providerID,
		Tool:           toolName,
		Text:           limitRunes(strings.TrimSpace(strings.Join(textParts, "\n")), maxMCPNormalizedContentRunes),
		StructuredJSON: limitRunes(strings.TrimSpace(structured), maxMCPNormalizedStructuredRunes),
	}
	if value.Text == "" && value.StructuredJSON == "" {
		return nil, fmt.Errorf("MCP tool returned no usable content")
	}
	output, err := json.Marshal(value)
	if err != nil {
		return nil, err
	}
	if len(output) > limit {
		return nil, fmt.Errorf("normalized MCP tool output exceeds %d bytes", limit)
	}
	return output, nil
}

func allowedMCPEnvironment(names []string) []string {
	environment := make([]string, 0, len(names))
	for _, name := range names {
		value, ok := os.LookupEnv(name)
		if !ok || len(value) > maxMCPEnvironmentValueBytes || strings.ContainsRune(value, '\x00') {
			continue
		}
		environment = append(environment, name+"="+value)
	}
	sort.Strings(environment)
	return environment
}

func normalizeExternalToolConfiguration(cfg *Config) error {
	if cfg == nil {
		return fmt.Errorf("nil Fairy configuration")
	}
	if len(cfg.ExternalToolProviders) > maxMCPProviders {
		return fmt.Errorf("Fairy supports at most %d external tool providers", maxMCPProviders)
	}
	providers := make([]ExternalToolProviderConfig, len(cfg.ExternalToolProviders))
	seen := make(map[string]bool, len(providers))
	for index, source := range cfg.ExternalToolProviders {
		provider := source
		provider.ID = strings.ToLower(strings.TrimSpace(provider.ID))
		provider.Protocol = strings.ToLower(strings.TrimSpace(provider.Protocol))
		provider.Command = strings.TrimSpace(provider.Command)
		provider.WorkingDirectory = strings.TrimSpace(provider.WorkingDirectory)
		provider.Args = append([]string(nil), provider.Args...)
		provider.EnvironmentAllowlist = append([]string(nil), provider.EnvironmentAllowlist...)
		provider.AllowedTools = append([]string(nil), provider.AllowedTools...)
		if provider.StartupTimeout <= 0 {
			provider.StartupTimeout = defaultMCPStartupTimeout
		}
		if provider.CallTimeout <= 0 {
			provider.CallTimeout = defaultMCPCallTimeout
		}
		if provider.FailureThreshold <= 0 {
			provider.FailureThreshold = defaultMCPFailureThreshold
		}
		if provider.ResetTimeout <= 0 {
			provider.ResetTimeout = defaultMCPResetTimeout
		}
		if provider.MaxOutputBytes <= 0 {
			provider.MaxOutputBytes = defaultMCPMaxOutputBytes
		}
		if err := validateExternalToolProvider(provider); err != nil {
			return fmt.Errorf("external tool provider %q: %w", provider.ID, err)
		}
		if seen[provider.ID] {
			return fmt.Errorf("duplicate external tool provider %q", provider.ID)
		}
		seen[provider.ID] = true
		providers[index] = provider
	}
	cfg.ExternalToolProviders = providers
	return nil
}

func validateExternalToolProvider(provider ExternalToolProviderConfig) error {
	if !validExternalProviderID(provider.ID) {
		return fmt.Errorf("ID must contain 1-32 lowercase letters, digits, dashes, or underscores")
	}
	if provider.Protocol != MCPStdioProtocol {
		return fmt.Errorf("protocol must be %s", MCPStdioProtocol)
	}
	if !filepath.IsAbs(provider.Command) || filepath.Clean(provider.Command) != provider.Command || strings.ContainsAny(provider.Command, "\r\n\x00") {
		return fmt.Errorf("command must be a clean absolute path")
	}
	if provider.WorkingDirectory != "" && (!filepath.IsAbs(provider.WorkingDirectory) || filepath.Clean(provider.WorkingDirectory) != provider.WorkingDirectory || strings.ContainsAny(provider.WorkingDirectory, "\r\n\x00")) {
		return fmt.Errorf("working directory must be a clean absolute path")
	}
	if len(provider.Args) > 64 {
		return fmt.Errorf("arguments exceed the supported limit")
	}
	for _, argument := range provider.Args {
		if len(argument) > 2048 || strings.ContainsAny(argument, "\r\n\x00") || containsSensitiveCredential(argument) {
			return fmt.Errorf("argument is invalid")
		}
	}
	if len(provider.EnvironmentAllowlist) > 64 {
		return fmt.Errorf("environment allowlist exceeds the supported limit")
	}
	seenEnvironment := make(map[string]bool, len(provider.EnvironmentAllowlist))
	for _, name := range provider.EnvironmentAllowlist {
		if !validEnvironmentName(name) || seenEnvironment[name] {
			return fmt.Errorf("environment allowlist contains an invalid or duplicate name")
		}
		seenEnvironment[name] = true
	}
	if len(provider.AllowedTools) == 0 || len(provider.AllowedTools) > maxMCPToolsPerProvider {
		return fmt.Errorf("allowed tools must contain 1-%d entries", maxMCPToolsPerProvider)
	}
	seenTools := make(map[string]bool, len(provider.AllowedTools))
	for _, name := range provider.AllowedTools {
		if !validTraceLabel(name) || !validTraceLabel(provider.ID+"."+name) || seenTools[name] {
			return fmt.Errorf("allowed tools contains an invalid or duplicate name")
		}
		seenTools[name] = true
	}
	if provider.StartupTimeout < time.Second || provider.StartupTimeout > time.Minute ||
		provider.CallTimeout < time.Second || provider.CallTimeout > 2*time.Minute ||
		provider.FailureThreshold < 1 || provider.FailureThreshold > 10 ||
		provider.ResetTimeout < time.Second || provider.ResetTimeout > 10*time.Minute ||
		provider.MaxOutputBytes < 1024 || provider.MaxOutputBytes > 1024*1024 {
		return fmt.Errorf("runtime limits are outside the supported range")
	}
	return nil
}

func validExternalProviderID(value string) bool {
	if value == "" || len(value) > 32 {
		return false
	}
	for _, character := range value {
		if character >= 'a' && character <= 'z' || character >= '0' && character <= '9' || character == '-' || character == '_' {
			continue
		}
		return false
	}
	return true
}

func validEnvironmentName(value string) bool {
	if value == "" || len(value) > 64 || value[0] >= '0' && value[0] <= '9' {
		return false
	}
	for _, character := range value {
		if character >= 'A' && character <= 'Z' || character >= '0' && character <= '9' || character == '_' {
			continue
		}
		return false
	}
	return true
}

func cloneExternalToolProviders(source []ExternalToolProviderConfig) []ExternalToolProviderConfig {
	providers := append([]ExternalToolProviderConfig(nil), source...)
	for index := range providers {
		providers[index].Args = append([]string(nil), source[index].Args...)
		providers[index].EnvironmentAllowlist = append([]string(nil), source[index].EnvironmentAllowlist...)
		providers[index].AllowedTools = append([]string(nil), source[index].AllowedTools...)
	}
	return providers
}
