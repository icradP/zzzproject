package fairy

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

type scriptedToolAwareModel struct {
	mu        sync.Mutex
	responses map[string][]ModelResponse
	errors    map[string][]error
	requests  []ModelRequest
}

type blockingToolAwareModel struct {
	started chan struct{}
}

func (m *blockingToolAwareModel) Complete(context.Context, []ChatMessage) (string, error) {
	return "", errors.New("legacy completion path must not be used")
}

func (m *blockingToolAwareModel) CompleteRequest(ctx context.Context, request ModelRequest) (ModelResponse, error) {
	if request.TaskID != PlannerTaskID {
		return ModelResponse{}, errors.New("unexpected non-planner request")
	}
	close(m.started)
	<-ctx.Done()
	return ModelResponse{}, ctx.Err()
}

func (m *blockingToolAwareModel) HasTask(taskID string) bool {
	return taskID == PlannerTaskID || taskID == ReplyerTaskID
}

func (m *scriptedToolAwareModel) Complete(context.Context, []ChatMessage) (string, error) {
	return "", errors.New("legacy completion path must not be used")
}

func (m *scriptedToolAwareModel) CompleteRequest(ctx context.Context, request ModelRequest) (ModelResponse, error) {
	if err := ctx.Err(); err != nil {
		return ModelResponse{}, err
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	m.requests = append(m.requests, cloneModelRequest(request))
	if queue := m.errors[request.TaskID]; len(queue) > 0 {
		err := queue[0]
		m.errors[request.TaskID] = queue[1:]
		return ModelResponse{}, err
	}
	queue := m.responses[request.TaskID]
	if len(queue) == 0 {
		return ModelResponse{}, errors.New("unexpected model request for task " + request.TaskID)
	}
	response := queue[0]
	m.responses[request.TaskID] = queue[1:]
	response.ToolCalls = cloneModelToolCalls(response.ToolCalls)
	return response, nil
}

func (m *scriptedToolAwareModel) HasTask(taskID string) bool {
	return taskID == PlannerTaskID || taskID == ReplyerTaskID
}

func (m *scriptedToolAwareModel) snapshotRequests() []ModelRequest {
	m.mu.Lock()
	defer m.mu.Unlock()
	requests := make([]ModelRequest, len(m.requests))
	for index, request := range m.requests {
		requests[index] = cloneModelRequest(request)
	}
	return requests
}

type agentTestPlugin struct {
	tool        *fakeTool
	matchIntent bool
}

func (p *agentTestPlugin) Name() string { return p.tool.Spec().Name }

func (p *agentTestPlugin) Match(PluginRequest) bool { return false }

func (p *agentTestPlugin) Handle(context.Context, PluginRequest) (string, error) { return "", nil }

func (p *agentTestPlugin) Spec() ToolSpec { return p.tool.Spec() }

func (p *agentTestPlugin) Execute(ctx context.Context, arguments json.RawMessage) (json.RawMessage, error) {
	return p.tool.Execute(ctx, arguments)
}

func (p *agentTestPlugin) Project(output json.RawMessage) (ToolProjection, error) {
	return p.tool.Project(output)
}

func (p *agentTestPlugin) BuildToolCall(PluginRequest) (ToolCall, bool) { return ToolCall{}, false }

func (p *agentTestPlugin) MatchToolIntent(PluginRequest) bool { return p.matchIntent }

func nativeToolCall(id, name, arguments string) ModelToolCall {
	return ModelToolCall{
		ID: id, Type: modelToolFunctionType,
		Function: ModelToolFunction{Name: name, Arguments: arguments},
	}
}

func TestAgentRuntimeGoldenToolLoop(t *testing.T) {
	tool := newFakeTool("lookup")
	tool.project = func(json.RawMessage) (ToolProjection, error) {
		return ToolProjection{ModelText: "record=golden-result", UserText: "golden-result"}, nil
	}
	registry := registerFakeTool(t, tool)
	trace := newMemoryTraceStore()
	runtime := NewToolRuntime(registry, DefaultToolPolicy(registry.Names()), nil, trace)
	model := &scriptedToolAwareModel{responses: map[string][]ModelResponse{
		PlannerTaskID: {
			{ToolCalls: []ModelToolCall{nativeToolCall("call_1", "lookup", `{"value":"okay"}`)}},
			{Text: `{"action":"respond","reply_intent":"Summarize the successful lookup without inventing fields."}`},
		},
		ReplyerTaskID: {{Text: "最终结果：golden-result"}},
	}}
	agent := NewAgentRuntime(testConfig(t), model, runtime)
	var reservations atomic.Int32
	outcome, err := agent.Run(context.Background(), AgentInput{
		ConversationID: "private_alice_fairy", MessageType: "private", SenderID: "alice",
		Text: "look it up", History: []ChatMessage{{Role: "user", Content: "look it up", SourceID: "message_1"}},
		VisibleTools: map[string]bool{"lookup": true}, Now: time.Date(2026, 9, 2, 12, 0, 0, 0, time.UTC),
		ReserveModel: func(string) error { reservations.Add(1); return nil },
	})
	if err != nil {
		t.Fatal(err)
	}
	if outcome.Reply != "最终结果：golden-result" || outcome.Stopped || tool.executions.Load() != 1 || reservations.Load() != 3 {
		t.Fatalf("outcome=%#v executions=%d reservations=%d", outcome, tool.executions.Load(), reservations.Load())
	}
	requests := model.snapshotRequests()
	if len(requests) != 3 || requests[0].TaskID != PlannerTaskID || requests[0].Step != 1 ||
		requests[1].TaskID != PlannerTaskID || requests[1].Step != 2 || requests[2].TaskID != ReplyerTaskID || requests[2].Step != 2 {
		t.Fatalf("model request sequence = %#v", requests)
	}
	if !requests[0].RequireJSON || len(requests[0].Tools) != 1 || requests[0].Tools[0].Name != "lookup" {
		t.Fatalf("planner tool projection = %#v", requests[0])
	}
	if roles := modelMessageRoles(requests[1].Messages); strings.Join(roles, ",") != "system,user,assistant,tool" {
		t.Fatalf("second planner roles = %v", roles)
	}
	toolMessage := requests[1].Messages[len(requests[1].Messages)-1]
	if toolMessage.ToolCallID != "call_1" || !strings.Contains(toolMessage.Content, "UNTRUSTED TOOL RESULT") || !strings.Contains(toolMessage.Content, "golden-result") {
		t.Fatalf("tool result message = %#v", toolMessage)
	}
	if len(requests[2].Tools) != 0 || !strings.Contains(requests[2].Messages[1].Content, "reply_context:v1") ||
		!strings.Contains(requests[2].Messages[1].Content, "golden-result") {
		t.Fatalf("replyer context = %#v", requests[2])
	}
	if len(trace.events) != 1 || trace.events[0].Type != TraceToolCall || trace.events[0].Step != 1 || trace.events[0].ToolStatus != "completed" {
		t.Fatalf("tool trace = %#v", trace.events)
	}
}

func TestAgentRuntimeDirectToolResultSkipsRemainingModelLoop(t *testing.T) {
	modelTool := newFakeTool("context-lookup")
	modelTool.project = func(json.RawMessage) (ToolProjection, error) {
		return ToolProjection{ModelText: "record=model-result", UserText: "model-result"}, nil
	}
	directTool := newFakeTool("direct-lookup")
	directTool.spec.ReplyMode = ToolReplyDirect
	directTool.project = func(json.RawMessage) (ToolProjection, error) {
		return ToolProjection{ModelText: "record=direct-result", UserText: "direct-result"}, nil
	}
	registry := NewToolRegistry()
	for _, tool := range []Tool{modelTool, directTool} {
		if err := registry.Register(tool); err != nil {
			t.Fatal(err)
		}
	}
	model := &scriptedToolAwareModel{responses: map[string][]ModelResponse{
		PlannerTaskID: {{ToolCalls: []ModelToolCall{
			nativeToolCall("call_1", "context-lookup", `{"value":"okay"}`),
			nativeToolCall("call_2", "direct-lookup", `{"value":"okay"}`),
		}}},
	}}
	agent := NewAgentRuntime(testConfig(t), model, NewToolRuntime(registry, DefaultToolPolicy(registry.Names()), nil, nil))
	outcome, err := agent.Run(context.Background(), AgentInput{
		ConversationID: "private_alice_fairy", MessageType: "private", SenderID: "alice",
		History:      []ChatMessage{{Role: "user", Content: "look it up"}},
		VisibleTools: map[string]bool{"context-lookup": true, "direct-lookup": true},
	})
	if err != nil || outcome.Reply != "model-result\n\ndirect-result" {
		t.Fatalf("direct outcome=%#v err=%v", outcome, err)
	}
	requests := model.snapshotRequests()
	if len(requests) != 1 || requests[0].TaskID != PlannerTaskID || modelTool.executions.Load() != 1 || directTool.executions.Load() != 1 {
		t.Fatalf("direct requests=%#v model_executions=%d direct_executions=%d", requests, modelTool.executions.Load(), directTool.executions.Load())
	}
}

func TestAgentRuntimeFallsBackToToolResultWhenPlannerFails(t *testing.T) {
	tool := newFakeTool("lookup")
	tool.spec.ReplyMode = ToolReplyViaModel
	tool.project = func(json.RawMessage) (ToolProjection, error) {
		return ToolProjection{ModelText: "record=safe-result", UserText: "safe-result"}, nil
	}
	registry := registerFakeTool(t, tool)
	model := &scriptedToolAwareModel{responses: map[string][]ModelResponse{
		PlannerTaskID: {
			{ToolCalls: []ModelToolCall{nativeToolCall("call_1", "lookup", `{"value":"okay"}`)}},
			{Text: `not valid planner json`},
			{Text: `still not valid planner json`},
		},
	}}
	agent := NewAgentRuntime(testConfig(t), model, NewToolRuntime(registry, DefaultToolPolicy(registry.Names()), nil, nil))
	outcome, err := agent.Run(context.Background(), AgentInput{
		ConversationID: "private_alice_fairy", MessageType: "private", SenderID: "alice",
		History: []ChatMessage{{Role: "user", Content: "look it up"}}, VisibleTools: map[string]bool{"lookup": true},
	})
	if err != nil || outcome.Reply != "safe-result" {
		t.Fatalf("fallback outcome=%#v err=%v", outcome, err)
	}
	requests := model.snapshotRequests()
	if len(requests) != 3 || !requests[2].Repair || tool.executions.Load() != 1 {
		t.Fatalf("fallback requests=%#v executions=%d", requests, tool.executions.Load())
	}
}

func TestAgentRuntimeRepairsPlannerInvalidResponse(t *testing.T) {
	tool := newFakeTool("lookup")
	registry := registerFakeTool(t, tool)
	trace, err := OpenSQLiteTraceStore(t.TempDir()+"/trace.db", t.TempDir()+"/trace.key")
	if err != nil {
		t.Fatal(err)
	}
	defer trace.Close()
	runtime := NewToolRuntime(registry, DefaultToolPolicy(registry.Names()), nil, trace)
	model := &scriptedToolAwareModel{
		errors: map[string][]error{
			PlannerTaskID: {&ModelFailure{Code: ModelFailureInvalidResponse}},
		},
		responses: map[string][]ModelResponse{
			PlannerTaskID: {{Text: `{"action":"respond","reply_intent":"Answer after repair."}`}},
			ReplyerTaskID: {{Text: "repaired reply"}},
		},
	}
	agent := NewAgentRuntime(testConfig(t), model, runtime)
	var reservations atomic.Int32
	outcome, err := agent.Run(context.Background(), AgentInput{
		ConversationID: "private_alice_fairy", MessageType: "private", SenderID: "alice",
		History: []ChatMessage{{Role: "user", Content: "answer me"}}, VisibleTools: map[string]bool{},
		ReserveModel: func(string) error { reservations.Add(1); return nil },
	})
	if err != nil || outcome.Reply != "repaired reply" {
		t.Fatalf("repair outcome=%#v err=%v", outcome, err)
	}
	requests := model.snapshotRequests()
	if len(requests) != 3 || requests[0].Repair || !requests[1].Repair || requests[2].Repair ||
		requests[0].TaskID != PlannerTaskID || requests[1].TaskID != PlannerTaskID || requests[2].TaskID != ReplyerTaskID ||
		reservations.Load() != 3 {
		t.Fatalf("repair requests=%#v reservations=%d", requests, reservations.Load())
	}
	if containsModelText(requests[0].Messages, plannerRepairPrompt) || !containsModelText(requests[1].Messages, plannerRepairPrompt) {
		t.Fatalf("planner repair prompt placement = %#v", requests)
	}
	if requests[0].PromptVersion != "planner-v1" || requests[1].PromptVersion != plannerRepairPromptVersion ||
		!validPromptDigest(requests[0].PromptDigest) || !validPromptDigest(requests[1].PromptDigest) ||
		requests[0].PromptDigest == requests[1].PromptDigest || containsModelText(requests[2].Messages, plannerRepairPrompt) {
		t.Fatalf("planner repair trace metadata or isolation = %#v", requests)
	}
}

func TestAgentRuntimeRepairsPlannerDecisionWithoutReplayingTools(t *testing.T) {
	tool := newFakeTool("lookup")
	registry := registerFakeTool(t, tool)
	runtime := NewToolRuntime(registry, DefaultToolPolicy(registry.Names()), nil, nil)
	model := &scriptedToolAwareModel{responses: map[string][]ModelResponse{
		PlannerTaskID: {
			{ToolCalls: []ModelToolCall{nativeToolCall("call_before_repair", "lookup", `{"value":"okay"}`)}},
			{Text: `{"action":"respond"}`},
			{Text: `{"action":"respond","reply_intent":"Use the existing tool result."}`},
		},
		ReplyerTaskID: {{Text: "single final reply"}},
	}}
	agent := NewAgentRuntime(testConfig(t), model, runtime)
	var reservations atomic.Int32
	outcome, err := agent.Run(context.Background(), AgentInput{
		ConversationID: "private_alice_fairy", MessageType: "private", SenderID: "alice",
		History: []ChatMessage{{Role: "user", Content: "look it up"}}, VisibleTools: map[string]bool{"lookup": true},
		ReserveModel: func(string) error { reservations.Add(1); return nil },
	})
	if err != nil || outcome.Reply != "single final reply" {
		t.Fatalf("repair outcome=%#v err=%v", outcome, err)
	}
	requests := model.snapshotRequests()
	if len(requests) != 4 || requests[0].Step != 1 || requests[1].Step != 2 || requests[1].Repair ||
		requests[2].Step != 2 || !requests[2].Repair || requests[3].TaskID != ReplyerTaskID || requests[3].Step != 2 {
		t.Fatalf("repair sequence = %#v", requests)
	}
	if tool.executions.Load() != 1 || reservations.Load() != 4 {
		t.Fatalf("repair executions=%d reservations=%d", tool.executions.Load(), reservations.Load())
	}
	if containsModelText(requests[3].Messages, plannerRepairPrompt) {
		t.Fatalf("planner repair prompt leaked to Replyer: %#v", requests[3].Messages)
	}
}

func TestAgentRuntimePlannerRepairIsBoundedAndSelective(t *testing.T) {
	t.Run("bounded invalid decisions", func(t *testing.T) {
		tool := newFakeTool("lookup")
		registry := registerFakeTool(t, tool)
		model := &scriptedToolAwareModel{responses: map[string][]ModelResponse{
			PlannerTaskID: {{Text: `{"action":"respond"}`}, {Text: `{"action":"respond"}`}},
		}}
		agent := NewAgentRuntime(testConfig(t), model, NewToolRuntime(registry, DefaultToolPolicy(registry.Names()), nil, nil))
		var reservations atomic.Int32
		_, err := agent.Run(context.Background(), AgentInput{
			ConversationID: "private_alice_fairy", MessageType: "private", SenderID: "alice",
			History:      []ChatMessage{{Role: "user", Content: "answer"}},
			ReserveModel: func(string) error { reservations.Add(1); return nil },
		})
		var failure *AgentFailure
		requests := model.snapshotRequests()
		if !errors.As(err, &failure) || failure.Code != AgentFailureInvalidDecision || len(requests) != 2 ||
			requests[0].Repair || !requests[1].Repair || reservations.Load() != 2 || tool.executions.Load() != 0 {
			t.Fatalf("bounded repair err=%#v requests=%#v reservations=%d executions=%d", err, requests, reservations.Load(), tool.executions.Load())
		}
	})

	t.Run("permanent model failure", func(t *testing.T) {
		tool := newFakeTool("lookup")
		registry := registerFakeTool(t, tool)
		model := &scriptedToolAwareModel{errors: map[string][]error{
			PlannerTaskID: {&ModelFailure{Code: ModelFailureAuthentication}},
		}}
		agent := NewAgentRuntime(testConfig(t), model, NewToolRuntime(registry, DefaultToolPolicy(registry.Names()), nil, nil))
		_, err := agent.Run(context.Background(), AgentInput{
			ConversationID: "private_alice_fairy", MessageType: "private", SenderID: "alice",
			History: []ChatMessage{{Role: "user", Content: "answer"}}, ReserveModel: func(string) error { return nil },
		})
		var failure *ModelFailure
		requests := model.snapshotRequests()
		if !errors.As(err, &failure) || failure.Code != ModelFailureAuthentication || len(requests) != 1 || requests[0].Repair {
			t.Fatalf("permanent failure err=%#v requests=%#v", err, requests)
		}
	})

	t.Run("repair quota", func(t *testing.T) {
		tool := newFakeTool("lookup")
		registry := registerFakeTool(t, tool)
		model := &scriptedToolAwareModel{responses: map[string][]ModelResponse{
			PlannerTaskID: {{Text: `{"action":"respond"}`}, {Text: `{"action":"respond","reply_intent":"must not run"}`}},
		}}
		agent := NewAgentRuntime(testConfig(t), model, NewToolRuntime(registry, DefaultToolPolicy(registry.Names()), nil, nil))
		quotaErr := errors.New("repair quota exhausted")
		var reservations atomic.Int32
		_, err := agent.Run(context.Background(), AgentInput{
			ConversationID: "private_alice_fairy", MessageType: "private", SenderID: "alice",
			History: []ChatMessage{{Role: "user", Content: "answer"}},
			ReserveModel: func(string) error {
				if reservations.Add(1) == 2 {
					return quotaErr
				}
				return nil
			},
		})
		requests := model.snapshotRequests()
		if !errors.Is(err, quotaErr) || len(requests) != 1 || reservations.Load() != 2 || tool.executions.Load() != 0 {
			t.Fatalf("quota repair err=%#v requests=%#v reservations=%d executions=%d", err, requests, reservations.Load(), tool.executions.Load())
		}
	})
}

func TestAgentRuntimeCannotBypassToolPipeline(t *testing.T) {
	tool := newFakeTool("lookup")
	registry := registerFakeTool(t, tool)
	trace := newMemoryTraceStore()
	runtime := NewToolRuntime(registry, DefaultToolPolicy(registry.Names()), nil, trace)
	model := &scriptedToolAwareModel{responses: map[string][]ModelResponse{
		PlannerTaskID: {
			{ToolCalls: []ModelToolCall{nativeToolCall("call_hidden", "lookup", `{"value":"okay"}`)}},
			{Text: `{"action":"respond","reply_intent":"Explain that the requested capability is unavailable."}`},
		},
		ReplyerTaskID: {{Text: "当前会话无法使用该工具。"}},
	}}
	agent := NewAgentRuntime(testConfig(t), model, runtime)
	outcome, err := agent.Run(context.Background(), AgentInput{
		ConversationID: "private_alice_fairy", MessageType: "private", SenderID: "alice",
		History: []ChatMessage{{Role: "user", Content: "use the hidden tool"}}, VisibleTools: map[string]bool{},
		ReserveModel: func(string) error { return nil },
	})
	if err != nil || outcome.Reply == "" {
		t.Fatalf("outcome=%#v err=%v", outcome, err)
	}
	if tool.executions.Load() != 0 {
		t.Fatalf("hidden tool executed %d times", tool.executions.Load())
	}
	requests := model.snapshotRequests()
	toolResult := requests[1].Messages[len(requests[1].Messages)-1].Content
	if !strings.Contains(toolResult, "code=not_visible") || strings.Contains(toolResult, "okay") {
		t.Fatalf("denied tool projection = %q", toolResult)
	}
	if len(trace.events) != 1 || trace.events[0].ToolPolicy != "denied" || trace.events[0].FailureCode != string(ToolFailureNotVisible) {
		t.Fatalf("denied tool trace = %#v", trace.events)
	}
}

func TestAgentRuntimeReturnsToolResultsAtPlannerStepLimit(t *testing.T) {
	tool := newFakeTool("lookup")
	registry := registerFakeTool(t, tool)
	runtime := NewToolRuntime(registry, DefaultToolPolicy(registry.Names()), nil, nil)
	plans := make([]ModelResponse, maxPlannerSteps)
	for index := range plans {
		plans[index] = ModelResponse{ToolCalls: []ModelToolCall{
			nativeToolCall("call_"+string(rune('a'+index)), "lookup", `{"value":"okay"}`),
		}}
	}
	model := &scriptedToolAwareModel{responses: map[string][]ModelResponse{PlannerTaskID: plans}}
	agent := NewAgentRuntime(testConfig(t), model, runtime)
	var reservations atomic.Int32
	outcome, err := agent.Run(context.Background(), AgentInput{
		ConversationID: "private_alice_fairy", MessageType: "private", SenderID: "alice",
		History: []ChatMessage{{Role: "user", Content: "loop forever"}}, VisibleTools: map[string]bool{"lookup": true},
		ReserveModel: func(string) error { reservations.Add(1); return nil },
	})
	if err != nil || outcome.Reply != strings.Join([]string{"ok", "ok", "ok", "ok"}, "\n\n") {
		t.Fatalf("step limit fallback outcome=%#v err=%v", outcome, err)
	}
	if tool.executions.Load() != maxPlannerSteps || reservations.Load() != maxPlannerSteps {
		t.Fatalf("executions=%d reservations=%d", tool.executions.Load(), reservations.Load())
	}
}

func TestPlannerDecisionRequiresStrictJSON(t *testing.T) {
	tests := []string{
		"```json\n{\"action\":\"stop\"}\n```",
		`{"action":"respond","reply_intent":"ok","extra":"not allowed"}`,
		`{"action":"respond"}`,
		`{"action":"stop"}{"action":"stop"}`,
		`{"action":"call_tools","tool_calls":[{"name":"lookup","arguments":[]}]}`,
	}
	for _, value := range tests {
		if _, err := decodePlannerDecision(value); err == nil {
			t.Fatalf("invalid planner decision accepted: %s", value)
		}
	}
	valid, err := decodePlannerDecision(`{"action":"wait","reply_intent":"Ask for the UID."}`)
	if err != nil || valid.Action != PlannerWait {
		t.Fatalf("valid planner decision = %#v err=%v", valid, err)
	}
}

func TestOutputPolicyRejectsCredentialsAndDangerousLinks(t *testing.T) {
	for _, value := range []string{
		"api_key=sk-1234567890abcdef",
		"打开 javascript:alert(1)",
		"访问 http://127.0.0.1/admin",
		"访问 https://user:pass@example.com/path",
		"伪装链接\u202ehttps://example.com",
	} {
		if _, err := ApplyOutputPolicy(value, 100); err == nil {
			t.Fatalf("unsafe output accepted: %q", value)
		}
	}
	safe, err := ApplyOutputPolicy("  查看 https://example.com/docs 获取说明。  ", 8)
	if err != nil || safe != "查看 https..." {
		t.Fatalf("safe output = %q err=%v", safe, err)
	}
}

func TestEngineAgentModeSendsOneFinalReplyAndKeepsContextsIsolated(t *testing.T) {
	cfg := testConfig(t)
	cfg.ModelDailyLimit = 20
	state, err := OpenStateStore(cfg.StateFile, true)
	if err != nil {
		t.Fatal(err)
	}
	tool := newFakeTool("lookup")
	plugin := &agentTestPlugin{tool: tool, matchIntent: true}
	model := &scriptedToolAwareModel{responses: map[string][]ModelResponse{
		PlannerTaskID: {
			{ToolCalls: []ModelToolCall{nativeToolCall("call_engine", "lookup", `{"value":"okay"}`)}},
			{Text: `{"action":"respond","reply_intent":"Answer with the lookup result."}`},
		},
		ReplyerTaskID: {{Text: "只发送这一条最终回复"}},
	}}
	engine := NewEngineWithTrace(cfg, state, model, newMemoryTraceStore(), plugin)
	messenger := &fakeMessenger{}
	engine.HandleMessage(context.Background(), messenger, testMessage("private_alice_fairy", "private", "alice", "please use a tool"))
	if messenger.replyCount() != 1 || messenger.lastReply().text != "只发送这一条最终回复" {
		t.Fatalf("agent replies = %#v", messenger.replies)
	}
	if used, _ := state.ModelQuotaStatus(time.Now(), cfg.ModelDailyLimit); used != 3 {
		t.Fatalf("model quota calls = %d, want 3", used)
	}

	isolatedModel := &scriptedToolAwareModel{responses: map[string][]ModelResponse{
		ReplyerTaskID: {{Text: "first"}, {Text: "second"}, {Text: "third"}},
	}}
	engine = NewEngine(cfg, state, isolatedModel)
	engine.HandleMessage(context.Background(), messenger, testMessage("private_a_fairy", "private", "a", "marker-alpha"))
	engine.HandleMessage(context.Background(), messenger, testMessage("private_b_fairy", "private", "b", "marker-beta"))
	third := testMessage("private_a_fairy", "private", "a", "alpha-again")
	third.MessageID = "message_3"
	engine.HandleMessage(context.Background(), messenger, third)
	requests := isolatedModel.snapshotRequests()
	if len(requests) != 3 {
		t.Fatalf("isolated request count = %d", len(requests))
	}
	if containsModelText(requests[1].Messages, "marker-alpha") || !containsModelText(requests[1].Messages, "marker-beta") {
		t.Fatalf("conversation B context leaked or missing: %#v", requests[1].Messages)
	}
	if !containsModelText(requests[2].Messages, "marker-alpha") || containsModelText(requests[2].Messages, "marker-beta") {
		t.Fatalf("conversation A context leaked or missing: %#v", requests[2].Messages)
	}
}

func TestEngineMakesExternalToolsVisibleAndRoutesOrdinaryRequestsToPlanner(t *testing.T) {
	cfg := testConfig(t)
	state, err := OpenStateStore(cfg.StateFile, true)
	if err != nil {
		t.Fatal(err)
	}
	tool := newFakeTool("provider.lookup")
	engine := NewEngineWithExternalTools(cfg, state, nil, nil, nil, []Tool{tool})
	visible := engine.visibleTools()
	if !visible["provider.lookup"] || len(visible) != 1 {
		t.Fatalf("visible external tools = %#v", visible)
	}
	if !engine.matchesToolIntent(PluginRequest{Text: "ordinary question"}) {
		t.Fatal("ordinary request did not route to Planner with external tools")
	}
}

func TestEngineAgentModeCancellationSendsNoReply(t *testing.T) {
	cfg := testConfig(t)
	cfg.ModelDailyLimit = 10
	state, err := OpenStateStore(cfg.StateFile, true)
	if err != nil {
		t.Fatal(err)
	}
	model := &blockingToolAwareModel{started: make(chan struct{})}
	engine := NewEngine(cfg, state, model)
	messenger := &fakeMessenger{}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		engine.HandleMessage(ctx, messenger, testMessage("private_alice_fairy", "private", "alice", "/fairy agent wait here"))
		close(done)
	}()
	waitForSignal(t, model.started, time.Second, "planner request")
	cancel()
	waitForSignal(t, done, time.Second, "cancelled agent")
	if messenger.replyCount() != 0 {
		t.Fatalf("cancelled agent sent replies: %#v", messenger.replies)
	}
}

func TestEngineAgentOutputPolicyAndQuotaFailuresSendOnce(t *testing.T) {
	t.Run("unsafe reply", func(t *testing.T) {
		cfg := testConfig(t)
		cfg.ModelDailyLimit = 10
		state, err := OpenStateStore(cfg.StateFile, true)
		if err != nil {
			t.Fatal(err)
		}
		model := &scriptedToolAwareModel{responses: map[string][]ModelResponse{
			PlannerTaskID: {{Text: `{"action":"respond","reply_intent":"Answer the user."}`}},
			ReplyerTaskID: {{Text: "api_key=sk-1234567890abcdef"}},
		}}
		engine := NewEngine(cfg, state, model)
		messenger := &fakeMessenger{}
		engine.HandleMessage(context.Background(), messenger, testMessage("private_alice_fairy", "private", "alice", "/fairy agent answer"))
		if messenger.replyCount() != 1 || !strings.Contains(messenger.lastReply().text, "安全检查") ||
			strings.Contains(messenger.lastReply().text, "sk-") {
			t.Fatalf("unsafe output replies = %#v", messenger.replies)
		}
	})

	t.Run("quota between planner and replyer", func(t *testing.T) {
		cfg := testConfig(t)
		cfg.ModelDailyLimit = 1
		state, err := OpenStateStore(cfg.StateFile, true)
		if err != nil {
			t.Fatal(err)
		}
		model := &scriptedToolAwareModel{responses: map[string][]ModelResponse{
			PlannerTaskID: {{Text: `{"action":"respond","reply_intent":"Answer the user."}`}},
			ReplyerTaskID: {{Text: "must not be called"}},
		}}
		engine := NewEngine(cfg, state, model)
		messenger := &fakeMessenger{}
		engine.HandleMessage(context.Background(), messenger, testMessage("private_alice_fairy", "private", "alice", "/fairy agent answer"))
		if messenger.replyCount() != 1 || !strings.Contains(messenger.lastReply().text, "额度") {
			t.Fatalf("quota replies = %#v", messenger.replies)
		}
		requests := model.snapshotRequests()
		if len(requests) != 1 || requests[0].TaskID != PlannerTaskID {
			t.Fatalf("requests after quota exhaustion = %#v", requests)
		}
	})
}

func TestForcedAgentRequiresPlannerWithoutConsumingQuota(t *testing.T) {
	cfg := testConfig(t)
	state, err := OpenStateStore(cfg.StateFile, true)
	if err != nil {
		t.Fatal(err)
	}
	model := &fakeModel{response: "must not run"}
	engine := NewEngine(cfg, state, model)
	messenger := &fakeMessenger{}
	engine.HandleMessage(context.Background(), messenger, testMessage("private_alice_fairy", "private", "alice", "/fairy agent do something"))
	if messenger.replyCount() != 1 || !strings.Contains(messenger.lastReply().text, "Planner 尚未配置") || len(model.requests) != 0 {
		t.Fatalf("missing planner result: replies=%#v calls=%d", messenger.replies, len(model.requests))
	}
	if used, _ := state.ModelQuotaStatus(time.Now(), cfg.ModelDailyLimit); used != 0 {
		t.Fatalf("missing planner consumed %d quota calls", used)
	}
}

func TestConfigAgentEnabledRequiresPlannerAndReplyer(t *testing.T) {
	cfg := modelRouterTestConfig(t, "https://provider.example.test/v1", 0)
	if cfg.AgentEnabled() {
		t.Fatal("replyer-only config enabled Agent mode")
	}
	cfg.ModelTasks = append(cfg.ModelTasks, ModelTaskConfig{
		ID: PlannerTaskID, Strategy: SequentialModelStrategy, CandidateModels: []string{"primary"},
		MaxOutputTokens: 600, Timeout: 5 * time.Second,
	})
	if !cfg.AgentEnabled() {
		t.Fatal("planner and replyer config did not enable Agent mode")
	}
}

func TestPromptTraceMetadataUsesHMACAndExcludesUserText(t *testing.T) {
	store, err := OpenSQLiteTraceStore(t.TempDir()+"/trace.db", t.TempDir()+"/trace.key")
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	prompts := NewPromptAssembler("private persona", store)
	messages := prompts.PlannerMessages(AgentInput{
		MessageType: "private", Now: time.Date(2026, 9, 2, 12, 0, 0, 0, time.UTC),
		History: []ChatMessage{{Role: "user", Content: "private user message"}},
	}, nil)
	version, digest := prompts.TraceMetadata(PlannerTaskID, messages)
	if version != "planner-v1" || !validPromptDigest(digest) || strings.Contains(digest, "private persona") {
		t.Fatalf("prompt metadata version=%q digest=%q", version, digest)
	}
	messages[len(messages)-1].Content = "changed user text"
	_, sameDigest := prompts.TraceMetadata(PlannerTaskID, messages)
	if sameDigest != digest {
		t.Fatal("user text changed the system prompt digest")
	}
	messages[0].Content += " changed"
	_, changedDigest := prompts.TraceMetadata(PlannerTaskID, messages)
	if changedDigest == digest {
		t.Fatal("system prompt change did not change the prompt digest")
	}
}

func TestPromptAssemblerIncludesExpressionStyle(t *testing.T) {
	prompts := NewPromptAssembler(defaultSystemPrompt)
	messages := prompts.ReplyerMessages(AgentInput{
		MessageType: "private", Now: time.Now(), ExpressionStyle: ExpressionDetailed,
	}, "", nil)
	if len(messages) != 1 || !strings.Contains(messages[0].Content, `<fairy-section id="expression" version="v1">`) ||
		!strings.Contains(messages[0].Content, "detailed expression style") {
		t.Fatalf("expression prompt = %#v", messages)
	}
}

func modelMessageRoles(messages []ChatMessage) []string {
	roles := make([]string, len(messages))
	for index, message := range messages {
		roles[index] = message.Role
	}
	return roles
}

func containsModelText(messages []ChatMessage, text string) bool {
	for _, message := range messages {
		if strings.Contains(message.Content, text) {
			return true
		}
	}
	return false
}
