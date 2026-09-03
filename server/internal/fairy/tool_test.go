package fairy

import (
	"context"
	"encoding/json"
	"errors"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

type fakeTool struct {
	spec       ToolSpec
	execute    func(context.Context, json.RawMessage) (json.RawMessage, error)
	project    func(json.RawMessage) (ToolProjection, error)
	executions atomic.Int32
}

func newFakeTool(name string) *fakeTool {
	return &fakeTool{
		spec: ToolSpec{
			Name: name, Description: "A test-only read-only tool.",
			InputSchema:  json.RawMessage(`{"type":"object","properties":{"value":{"type":"string","minLength":2,"maxLength":8,"pattern":"^[a-z]+$"}},"required":["value"],"additionalProperties":false}`),
			OutputSchema: json.RawMessage(`{"type":"object","properties":{"result":{"type":"string","maxLength":32}},"required":["result"],"additionalProperties":false}`),
			Risk:         RiskLow, Concurrency: ToolSerial, Idempotency: ToolReadOnly,
			Timeout: time.Second, MaxInputBytes: 1024, MaxOutputBytes: 1024,
		},
	}
}

func (t *fakeTool) Spec() ToolSpec { return t.spec }

func (t *fakeTool) Execute(ctx context.Context, arguments json.RawMessage) (json.RawMessage, error) {
	t.executions.Add(1)
	if t.execute != nil {
		return t.execute(ctx, arguments)
	}
	return json.RawMessage(`{"result":"ok"}`), nil
}

func (t *fakeTool) Project(output json.RawMessage) (ToolProjection, error) {
	if t.project != nil {
		return t.project(output)
	}
	var decoded struct {
		Result string `json:"result"`
	}
	if err := json.Unmarshal(output, &decoded); err != nil {
		return ToolProjection{}, err
	}
	return ToolProjection{ModelText: decoded.Result, UserText: decoded.Result}, nil
}

func registerFakeTool(t *testing.T, tool Tool) *ToolRegistry {
	t.Helper()
	registry := NewToolRegistry()
	if err := registry.Register(tool); err != nil {
		t.Fatal(err)
	}
	return registry
}

func TestToolRegistryCompilesSchemasAndKeepsImmutableSpecs(t *testing.T) {
	tool := newFakeTool("lookup")
	registry := registerFakeTool(t, tool)
	if err := registry.Register(tool); err == nil {
		t.Fatal("duplicate tool registration succeeded")
	}
	tool.spec.InputSchema[0] = '['
	spec, ok := registry.Resolve("lookup")
	if !ok || spec.Name != "lookup" || spec.InputSchema[0] != '{' {
		t.Fatalf("resolved immutable spec = %#v", spec)
	}
	spec.InputSchema[0] = '['
	again, _ := registry.Resolve("lookup")
	if again.InputSchema[0] != '{' {
		t.Fatal("caller mutated registered tool schema")
	}

	invalid := newFakeTool("invalid")
	invalid.spec.InputSchema = json.RawMessage(`{"type":"object","properties":{"uid":{"type":"string","pattern":"["}}}`)
	if err := registry.Register(invalid); err == nil {
		t.Fatal("invalid schema registration succeeded")
	}
}

func TestToolRegistryResolvesCurrentDynamicPluginTool(t *testing.T) {
	first := newFakeTool("plugin-lookup")
	second := newFakeTool("plugin-lookup")
	current := Tool(first)
	registry := NewToolRegistry()
	if err := registry.SetDynamicProvider(func() []Tool {
		if current == nil {
			return nil
		}
		return []Tool{current}
	}); err != nil {
		t.Fatal(err)
	}
	runtime := NewToolRuntime(registry, DefaultToolPolicy(nil), nil, nil)
	execute := func() ToolResult {
		return runtime.NewSession(ToolScope{VisibleTools: map[string]bool{"plugin-lookup": true}}).Execute(
			context.Background(),
			ToolCall{Name: "plugin-lookup", Arguments: json.RawMessage(`{"value":"okay"}`)},
		)
	}
	if result := execute(); !result.OK() || first.executions.Load() != 1 {
		t.Fatalf("first dynamic tool result=%#v executions=%d", result, first.executions.Load())
	}
	current = second
	if result := execute(); !result.OK() || first.executions.Load() != 1 || second.executions.Load() != 1 {
		t.Fatalf("reloaded dynamic tool result=%#v first=%d second=%d", result, first.executions.Load(), second.executions.Load())
	}
	if !registry.PolicyAllows("plugin-lookup", runtime.policy) {
		t.Fatal("dynamic plugin tool was reported as denied despite executable policy")
	}
	current = nil
	if result := execute(); result.Failure == nil || result.Failure.Code != ToolFailureNotFound {
		t.Fatalf("unloaded dynamic tool result=%#v", result)
	}
}

func TestToolRuntimeValidatesArgumentsVisibilityPolicyAndLimits(t *testing.T) {
	tool := newFakeTool("lookup")
	registry := registerFakeTool(t, tool)
	policy := DefaultToolPolicy(registry.Names())
	policy.MaxCalls = 1
	runtime := NewToolRuntime(registry, policy, nil, nil)

	hidden := runtime.NewSession(ToolScope{VisibleTools: map[string]bool{}}).Execute(context.Background(), ToolCall{Name: "lookup", Arguments: json.RawMessage(`{"value":"okay"}`)})
	if hidden.Failure == nil || hidden.Failure.Code != ToolFailureNotVisible || tool.executions.Load() != 0 {
		t.Fatalf("hidden result = %#v, executions = %d", hidden, tool.executions.Load())
	}

	session := runtime.NewSession(ToolScope{VisibleTools: map[string]bool{"lookup": true}})
	invalid := session.Execute(context.Background(), ToolCall{Name: "lookup", Arguments: json.RawMessage(`{"value":"okay","secret":"must-not-pass"}`)})
	if invalid.Failure == nil || invalid.Failure.Code != ToolFailureInvalidArguments || tool.executions.Load() != 0 {
		t.Fatalf("invalid result = %#v, executions = %d", invalid, tool.executions.Load())
	}
	first := session.Execute(context.Background(), ToolCall{Name: "lookup", Arguments: json.RawMessage(`{"value":"okay"}`)})
	if !first.OK() {
		t.Fatalf("first valid result = %#v", first)
	}
	limited := session.Execute(context.Background(), ToolCall{Name: "lookup", Arguments: json.RawMessage(`{"value":"okay"}`)})
	if limited.Failure == nil || limited.Failure.Code != ToolFailureLimitExceeded {
		t.Fatalf("limit result = %#v", limited)
	}

	successSession := runtime.NewSession(ToolScope{VisibleTools: map[string]bool{"lookup": true}})
	success := successSession.Execute(context.Background(), ToolCall{Name: "lookup", Arguments: json.RawMessage(`{"value":"okay"}`)})
	if !success.OK() || success.Projection.UserText != "ok" || tool.executions.Load() != 2 {
		t.Fatalf("success result = %#v, executions = %d", success, tool.executions.Load())
	}

	unknown := successSession.Execute(context.Background(), ToolCall{Name: "missing", Arguments: json.RawMessage(`{}`)})
	if unknown.Failure == nil || unknown.Failure.Code != ToolFailureNotFound {
		t.Fatalf("unknown result = %#v", unknown)
	}
}

func TestToolRuntimeDeniesRiskAndSideEffects(t *testing.T) {
	tool := newFakeTool("mutate")
	tool.spec.Risk = RiskMedium
	tool.spec.Idempotency = ToolIdempotent
	registry := registerFakeTool(t, tool)
	policy := DefaultToolPolicy(registry.Names())
	scope := ToolScope{VisibleTools: map[string]bool{"mutate": true}}
	result := NewToolRuntime(registry, policy, nil, nil).NewSession(scope).Execute(context.Background(), ToolCall{Name: "mutate", Arguments: json.RawMessage(`{"value":"okay"}`)})
	if result.Failure == nil || result.Failure.Code != ToolFailurePolicyDenied || tool.executions.Load() != 0 {
		t.Fatalf("risk result = %#v", result)
	}

	policy.AllowedRisks[RiskMedium] = true
	result = NewToolRuntime(registry, policy, nil, nil).NewSession(scope).Execute(context.Background(), ToolCall{Name: "mutate", Arguments: json.RawMessage(`{"value":"okay"}`)})
	if result.Failure == nil || result.Failure.Code != ToolFailurePolicyDenied || tool.executions.Load() != 0 {
		t.Fatalf("side-effect result = %#v", result)
	}
}

func TestToolRuntimeTimeoutOutputValidationAndRedaction(t *testing.T) {
	tool := newFakeTool("lookup")
	registry := registerFakeTool(t, tool)
	policy := DefaultToolPolicy(registry.Names())
	policy.MaxTimeout = 20 * time.Millisecond
	scope := ToolScope{VisibleTools: map[string]bool{"lookup": true}}

	tool.execute = func(ctx context.Context, _ json.RawMessage) (json.RawMessage, error) {
		<-ctx.Done()
		return nil, ctx.Err()
	}
	result := NewToolRuntime(registry, policy, nil, nil).NewSession(scope).Execute(context.Background(), ToolCall{Name: "lookup", Arguments: json.RawMessage(`{"value":"okay"}`)})
	if result.Failure == nil || result.Failure.Code != ToolFailureTimeout {
		t.Fatalf("timeout result = %#v", result)
	}

	tool.execute = func(context.Context, json.RawMessage) (json.RawMessage, error) {
		return json.RawMessage(`{"unexpected":true}`), nil
	}
	result = NewToolRuntime(registry, policy, nil, nil).NewSession(scope).Execute(context.Background(), ToolCall{Name: "lookup", Arguments: json.RawMessage(`{"value":"okay"}`)})
	if result.Failure == nil || result.Failure.Code != ToolFailureInvalidOutput {
		t.Fatalf("invalid output result = %#v", result)
	}

	tool.execute = nil
	tool.project = func(json.RawMessage) (ToolProjection, error) {
		return ToolProjection{ModelText: "api_key=sk-1234567890abcdef", UserText: "password=hunter2-secret"}, nil
	}
	result = NewToolRuntime(registry, policy, nil, nil).NewSession(scope).Execute(context.Background(), ToolCall{Name: "lookup", Arguments: json.RawMessage(`{"value":"okay"}`)})
	if !result.OK() || strings.Contains(result.Projection.ModelText+result.Projection.UserText, "sk-123") || !strings.Contains(result.Projection.UserText, "已隐藏") {
		t.Fatalf("redacted result = %#v", result)
	}
}

func TestToolSessionSerializesCalls(t *testing.T) {
	tool := newFakeTool("lookup")
	var active atomic.Int32
	var maximum atomic.Int32
	tool.execute = func(context.Context, json.RawMessage) (json.RawMessage, error) {
		current := active.Add(1)
		for {
			previous := maximum.Load()
			if current <= previous || maximum.CompareAndSwap(previous, current) {
				break
			}
		}
		time.Sleep(20 * time.Millisecond)
		active.Add(-1)
		return json.RawMessage(`{"result":"ok"}`), nil
	}
	registry := registerFakeTool(t, tool)
	runtime := NewToolRuntime(registry, DefaultToolPolicy(registry.Names()), nil, nil)
	session := runtime.NewSession(ToolScope{VisibleTools: map[string]bool{"lookup": true}})
	var wait sync.WaitGroup
	for index := 0; index < 2; index++ {
		wait.Add(1)
		go func() {
			defer wait.Done()
			result := session.Execute(context.Background(), ToolCall{Name: "lookup", Arguments: json.RawMessage(`{"value":"okay"}`)})
			if !result.OK() {
				t.Errorf("serial call failed: %v", result.Failure)
			}
		}()
	}
	wait.Wait()
	if maximum.Load() != 1 {
		t.Fatalf("maximum concurrent executions = %d", maximum.Load())
	}
}

func TestExclusiveToolWaitObservesTimeout(t *testing.T) {
	tool := newFakeTool("mutate")
	tool.spec.Concurrency = ToolExclusive
	tool.spec.Idempotency = ToolIdempotent
	tool.spec.Timeout = 30 * time.Millisecond
	started := make(chan struct{})
	release := make(chan struct{})
	tool.execute = func(context.Context, json.RawMessage) (json.RawMessage, error) {
		if tool.executions.Load() == 1 {
			close(started)
			<-release
		}
		return json.RawMessage(`{"result":"ok"}`), nil
	}
	registry := registerFakeTool(t, tool)
	policy := DefaultToolPolicy(registry.Names())
	policy.AllowedRisks[tool.spec.Risk] = true
	policy.AllowSideEffects = true
	runtime := NewToolRuntime(registry, policy, nil, nil)
	scope := ToolScope{VisibleTools: map[string]bool{"mutate": true}}
	done := make(chan ToolResult, 1)
	go func() {
		done <- runtime.NewSession(scope).Execute(context.Background(), ToolCall{Name: "mutate", Arguments: json.RawMessage(`{"value":"okay"}`)})
	}()
	select {
	case <-started:
	case <-time.After(time.Second):
		t.Fatal("exclusive tool did not start")
	}
	second := runtime.NewSession(scope).Execute(context.Background(), ToolCall{Name: "mutate", Arguments: json.RawMessage(`{"value":"okay"}`)})
	if second.Failure == nil || second.Failure.Code != ToolFailureTimeout {
		t.Fatalf("exclusive wait result = %#v", second)
	}
	if tool.executions.Load() != 1 {
		t.Fatalf("timed-out waiter executed tool; executions = %d", tool.executions.Load())
	}
	close(release)
	<-done
}

func TestToolTraceContainsDecisionChainProjectionWithoutConversationID(t *testing.T) {
	store, err := OpenSQLiteTraceStore(filepath.Join(t.TempDir(), "trace.db"), filepath.Join(t.TempDir(), "trace.key"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	tool := newFakeTool("lookup")
	tool.execute = func(context.Context, json.RawMessage) (json.RawMessage, error) {
		return json.RawMessage(`{"result":"private-result-body"}`), nil
	}
	registry := registerFakeTool(t, tool)
	runtime := NewToolRuntime(registry, DefaultToolPolicy(registry.Names()), nil, store)
	ctx := withTurnTraceScope(context.Background(), TurnTraceScope{
		TraceID: "trace-tool", TurnID: "turn-tool", ConversationID: "private-alice-fairy", Source: "zzz-message",
	})
	result := runtime.NewSession(ToolScope{ConversationID: "private-alice-fairy", VisibleTools: map[string]bool{"lookup": true}}).Execute(ctx, ToolCall{
		Name: "lookup", Arguments: json.RawMessage(`{"value":"secret"}`), Step: 1,
	})
	if !result.OK() || string(result.Output) != `{"result":"private-result-body"}` {
		t.Fatalf("trace test result = %#v", result)
	}
	var payload string
	if err := store.db.QueryRow(`SELECT payload_json FROM fairy_trace_events WHERE type = 'tool_call'`).Scan(&payload); err != nil {
		t.Fatal(err)
	}
	for _, forbidden := range []string{"private-alice-fairy"} {
		if strings.Contains(payload, forbidden) {
			t.Fatalf("tool trace leaked %q: %s", forbidden, payload)
		}
	}
	for _, required := range []string{"lookup", "completed", "allowed", "secret", "private-result-body"} {
		if !strings.Contains(payload, required) {
			t.Fatalf("tool trace lacks %q: %s", required, payload)
		}
	}
}

func TestToolAuthorizerDenialDoesNotExposeError(t *testing.T) {
	tool := newFakeTool("lookup")
	registry := registerFakeTool(t, tool)
	authorizer := rejectingToolAuthorizer{err: errors.New("alice is forbidden")}
	result := NewToolRuntime(registry, DefaultToolPolicy(registry.Names()), authorizer, nil).
		NewSession(ToolScope{VisibleTools: map[string]bool{"lookup": true}}).
		Execute(context.Background(), ToolCall{Name: "lookup", Arguments: json.RawMessage(`{"value":"okay"}`)})
	if result.Failure == nil || result.Failure.Code != ToolFailureUnauthorized || result.Failure.err != nil {
		t.Fatalf("authorization result = %#v", result)
	}
}

type rejectingToolAuthorizer struct{ err error }

func (a rejectingToolAuthorizer) AuthorizeTool(context.Context, ToolScope, ToolSpec, json.RawMessage) error {
	return a.err
}
