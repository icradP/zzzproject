package fairy

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestEngineAgentDiagnosticRunsPlannerAndReplyerWithoutToolsOrQuota(t *testing.T) {
	cfg := testConfig(t)
	state, err := OpenStateStoreWithDefaults(cfg.StateFile, cfg.GroupDefault, cfg.GroupSoftDefault)
	if err != nil {
		t.Fatal(err)
	}
	model := &scriptedToolAwareModel{responses: map[string][]ModelResponse{
		PlannerTaskID: {{Text: `{"action":"respond","reply_intent":"Confirm the diagnostic chain."}`}},
		ReplyerTaskID: {{Text: agentDiagnosticExpectedReply}},
	}}
	engine := NewEngine(cfg, state, model)
	result, err := engine.RunAgentDiagnostic(context.Background(), AgentDiagnosticCasePipeline)
	if err != nil {
		t.Fatal(err)
	}
	if result.CaseID != AgentDiagnosticCasePipeline || result.Status != AgentDiagnosticPassed ||
		result.Reply != agentDiagnosticExpectedReply || result.DurationMillis < 0 {
		t.Fatalf("diagnostic result = %#v", result)
	}
	requests := model.snapshotRequests()
	if len(requests) != 2 || requests[0].TaskID != PlannerTaskID || requests[1].TaskID != ReplyerTaskID {
		t.Fatalf("diagnostic request sequence = %#v", requests)
	}
	if len(requests[0].Tools) != 0 || len(requests[1].Tools) != 0 {
		t.Fatalf("diagnostic exposed tools: %#v", requests)
	}
	if !containsModelText(requests[0].Messages, agentDiagnosticPlannerPrompt) ||
		containsModelText(requests[1].Messages, agentDiagnosticPlannerPrompt) ||
		!containsModelText(requests[1].Messages, agentDiagnosticReplyPrompt) {
		t.Fatalf("diagnostic prompt isolation failed: %#v", requests)
	}
	used, remaining := state.ModelQuotaStatus(engine.now(), cfg.ModelDailyLimit)
	if used != 0 || remaining != cfg.ModelDailyLimit {
		t.Fatalf("diagnostic consumed model quota: used=%d remaining=%d", used, remaining)
	}
	encoded, err := json.Marshal(result)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(encoded), "admin:fairy-diagnostic") || strings.Contains(string(encoded), agentDiagnosticPlannerPrompt) || strings.Contains(string(encoded), agentDiagnosticReplyPrompt) {
		t.Fatalf("diagnostic response leaked internal context: %s", encoded)
	}
}

func TestEngineAgentDiagnosticRejectsInvalidOrUnavailableCases(t *testing.T) {
	engine := &Engine{}
	if _, err := engine.RunAgentDiagnostic(context.Background(), "custom-prompt"); !errors.Is(err, ErrAgentDiagnosticInvalidCase) {
		t.Fatalf("invalid case error = %v", err)
	}
	if _, err := engine.RunAgentDiagnostic(context.Background(), AgentDiagnosticCasePipeline); !errors.Is(err, ErrAgentDiagnosticUnavailable) {
		t.Fatalf("unavailable error = %v", err)
	}
}

func TestEngineAgentDiagnosticBuildsIsolatedRouterWhenProductionAIIsOff(t *testing.T) {
	provider := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		var payload map[string]interface{}
		if err := json.NewDecoder(request.Body).Decode(&payload); err != nil {
			t.Errorf("decode model request: %v", err)
			return
		}
		body := `{"choices":[{"message":{"content":"Fairy Agent diagnostic passed."},"finish_reason":"stop"}],"usage":{"prompt_tokens":4,"completion_tokens":3}}`
		if _, planner := payload["response_format"]; planner {
			body = `{"choices":[{"message":{"content":"{\"action\":\"respond\",\"reply_intent\":\"Confirm the diagnostic chain.\"}"},"finish_reason":"stop"}],"usage":{"prompt_tokens":4,"completion_tokens":3}}`
		}
		response.Header().Set("Content-Type", "application/json")
		_, _ = response.Write([]byte(body))
	}))
	defer provider.Close()

	cfg := testConfig(t)
	cfg.AIEnabled = false
	cfg.AIRolloutMode = AIRolloutOff
	cfg.ModelProviders = []ModelProviderConfig{{
		ID: "diagnostic-provider", Protocol: OpenAICompatibleProtocol, BaseURL: provider.URL,
		Timeout: 5 * time.Second, MaxRetries: 0, RetryBackoff: 50 * time.Millisecond,
	}}
	cfg.ModelDefinitions = []ModelDefinitionConfig{{
		ID: "diagnostic-model", ProviderID: "diagnostic-provider", RemoteName: "diagnostic-remote", ContextWindow: 4096,
	}}
	cfg.ModelTasks = []ModelTaskConfig{
		{ID: ReplyerTaskID, Strategy: SequentialModelStrategy, CandidateModels: []string{"diagnostic-model"}, MaxOutputTokens: 128, Timeout: 5 * time.Second, DailyLimit: 2},
	}
	state, err := OpenStateStoreWithDefaults(cfg.StateFile, cfg.GroupDefault, cfg.GroupSoftDefault)
	if err != nil {
		t.Fatal(err)
	}
	engine := NewEngine(cfg, state, nil)
	result, err := engine.RunAgentDiagnostic(context.Background(), AgentDiagnosticCasePipeline)
	if err != nil {
		t.Fatal(err)
	}
	if result.Status != AgentDiagnosticPassed || result.Reply != agentDiagnosticExpectedReply {
		t.Fatalf("isolated diagnostic result = %#v", result)
	}
}

func TestEngineAgentDiagnosticRejectsReplyThatExposesProtocol(t *testing.T) {
	cfg := testConfig(t)
	state, err := OpenStateStoreWithDefaults(cfg.StateFile, cfg.GroupDefault, cfg.GroupSoftDefault)
	if err != nil {
		t.Fatal(err)
	}
	model := &scriptedToolAwareModel{responses: map[string][]ModelResponse{
		PlannerTaskID: {{Text: `{"action":"respond","reply_intent":"Confirm the diagnostic chain."}`}},
		ReplyerTaskID: {{Text: `I cannot return the JSON object requested.`}},
	}}
	engine := NewEngine(cfg, state, model)
	if _, err := engine.RunAgentDiagnostic(context.Background(), AgentDiagnosticCasePipeline); err == nil {
		t.Fatal("diagnostic accepted a protocol-exposing reply")
	} else {
		var failure *AgentFailure
		if !errors.As(err, &failure) || failure.Code != AgentFailureInvalidReply {
			t.Fatalf("diagnostic protocol failure = %v", err)
		}
	}
}

type diagnosticAdminRuntime struct {
	result AgentDiagnosticResult
	err    error
}

func (*diagnosticAdminRuntime) ApplyBehaviorConfig(Config) {}

func (*diagnosticAdminRuntime) Snapshot(context.Context) RuntimeStatus { return RuntimeStatus{} }

func (r *diagnosticAdminRuntime) RunAgentDiagnostic(context.Context, string) (AgentDiagnosticResult, error) {
	return r.result, r.err
}

func TestFairyAdminAPIAgentDiagnosticValidationAndConcurrency(t *testing.T) {
	cfg := testConfig(t)
	cfg.ConfigFile = ""
	runtime := &diagnosticAdminRuntime{result: AgentDiagnosticResult{
		CaseID: AgentDiagnosticCasePipeline, Status: AgentDiagnosticPassed, Reply: "ready", DurationMillis: 12,
	}}
	handler := NewAdminAPIWithRuntime(NewConfigManager(cfg), "local-admin-token", nil, nil, runtime)

	unauthorized := httptest.NewRecorder()
	handler.ServeHTTP(unauthorized, httptest.NewRequest(http.MethodPost, "/admin/agent-diagnostic", strings.NewReader(`{"case_id":"pipeline-basic"}`)))
	if unauthorized.Code != http.StatusUnauthorized {
		t.Fatalf("unauthorized diagnostic status = %d", unauthorized.Code)
	}
	for name, body := range map[string]string{
		"unknown field": `{"case_id":"pipeline-basic","prompt":"private"}`,
		"trailing JSON": `{"case_id":"pipeline-basic"}{}`,
		"invalid case":  `{"case_id":"custom"}`,
	} {
		t.Run(name, func(t *testing.T) {
			request := httptest.NewRequest(http.MethodPost, "/admin/agent-diagnostic", strings.NewReader(body))
			request.Header.Set("Authorization", "Bearer local-admin-token")
			response := httptest.NewRecorder()
			handler.ServeHTTP(response, request)
			if response.Code != http.StatusBadRequest {
				t.Fatalf("diagnostic %s status=%d body=%s", name, response.Code, response.Body.String())
			}
		})
	}

	request := httptest.NewRequest(http.MethodPost, "/admin/agent-diagnostic", strings.NewReader(`{"case_id":"pipeline-basic"}`))
	request.Header.Set("Authorization", "Bearer local-admin-token")
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if response.Code != http.StatusOK || !strings.Contains(response.Body.String(), `"status":"passed"`) ||
		strings.Contains(response.Body.String(), "admin:fairy-diagnostic") {
		t.Fatalf("diagnostic response status=%d body=%s", response.Code, response.Body.String())
	}

	handler.modelTestSlot <- struct{}{}
	busyRequest := httptest.NewRequest(http.MethodPost, "/admin/agent-diagnostic", strings.NewReader(`{"case_id":"pipeline-basic"}`))
	busyRequest.Header.Set("Authorization", "Bearer local-admin-token")
	busy := httptest.NewRecorder()
	handler.ServeHTTP(busy, busyRequest)
	<-handler.modelTestSlot
	if busy.Code != http.StatusTooManyRequests || busy.Header().Get("Retry-After") != "1" {
		t.Fatalf("busy diagnostic status=%d retry=%q", busy.Code, busy.Header().Get("Retry-After"))
	}
}
