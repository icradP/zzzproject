package fairy

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestSQLiteTraceStoreListsCompleteDecisionChains(t *testing.T) {
	cfg := testConfig(t)
	store, err := OpenSQLiteTraceStore(cfg.TraceDB, cfg.TraceKeyFile)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()

	startedAt := time.Date(2026, 9, 3, 3, 0, 0, 0, time.UTC)
	detail := json.RawMessage(`{"arguments":{"uid":"123456789"},"model_result":"lookup complete"}`)
	events := []TraceEvent{
		{Time: startedAt, Type: TraceAdmissionAccepted, TraceID: "trace-chain", TurnID: "turn-chain", ConversationID: "private-alice-fairy", Source: "zzz-message", Status: "admitted", QueueDepth: 1, Pending: 1},
		{Time: startedAt.Add(time.Millisecond), Type: TraceTurnStarted, TraceID: "trace-chain", TurnID: "turn-chain", ConversationID: "private-alice-fairy", Source: "zzz-message", Status: "running"},
		{Time: startedAt.Add(2 * time.Millisecond), Type: TraceModelReasoning, TraceID: "trace-chain", TurnID: "turn-chain", ConversationID: "private-alice-fairy", Source: "zzz-message", Status: "completed", TaskID: PlannerTaskID, ProviderID: "provider-a", ModelID: "model-a", SnapshotID: "snapshot-chain", Attempt: 1, Step: 1, Content: "inspect the request", Signature: "provider-signature"},
		{Time: startedAt.Add(3 * time.Millisecond), Type: TracePlannerDecision, TraceID: "trace-chain", TurnID: "turn-chain", ConversationID: "private-alice-fairy", Source: "zzz-message", Status: "completed", TaskID: PlannerTaskID, Step: 1, Content: `{"action":"tool","tool":"zzz-profile"}`, Detail: json.RawMessage(`{"action":"tool","tool":"zzz-profile"}`)},
		{Time: startedAt.Add(4 * time.Millisecond), Type: TraceToolCall, TraceID: "trace-chain", TurnID: "turn-chain", ConversationID: "private-alice-fairy", Source: "zzz-message", Status: "completed", Step: 1, ToolCallID: "call-chain", ToolName: ZZZProfilePluginID, ToolRisk: string(RiskLow), ToolPolicy: "allowed", ToolStatus: "completed", ToolResultBytes: len(detail), Detail: detail},
		{Time: startedAt.Add(5 * time.Millisecond), Type: TraceModelReasoning, TraceID: "trace-chain", TurnID: "turn-chain", ConversationID: "private-alice-fairy", Source: "zzz-message", Status: "completed", TaskID: ReplyerTaskID, ProviderID: "provider-a", ModelID: "model-a", SnapshotID: "snapshot-chain", Attempt: 1, Step: 2, Signature: "sha256:provider-redacted-digest", Redacted: true},
		{Time: startedAt.Add(6 * time.Millisecond), Type: TraceReplyerResult, TraceID: "trace-chain", TurnID: "turn-chain", ConversationID: "private-alice-fairy", Source: "zzz-message", Status: "completed", TaskID: ReplyerTaskID, Step: 2, Content: "final reply"},
		{Time: startedAt.Add(7 * time.Millisecond), Type: TraceTurnCompleted, TraceID: "trace-chain", TurnID: "turn-chain", ConversationID: "private-alice-fairy", Source: "zzz-message", Status: "completed"},
	}
	for _, event := range events {
		if err := store.Append(context.Background(), event); err != nil {
			t.Fatalf("append %s: %v", event.Type, err)
		}
	}

	chains, err := store.ListDecisionChains(context.Background(), 10)
	if err != nil {
		t.Fatal(err)
	}
	if len(chains) != 1 {
		t.Fatalf("decision chains = %#v", chains)
	}
	chain := chains[0]
	if chain.TurnID != "turn-chain" || chain.TraceID != "trace-chain" || chain.Status != "completed" ||
		!strings.HasPrefix(chain.ConversationRef, "hmac-sha256:") || chain.ConversationRef == "private-alice-fairy" ||
		len(chain.Events) != len(events) {
		t.Fatalf("decision chain = %#v", chain)
	}
	for index, event := range chain.Events {
		if event.Type != events[index].Type || event.Sequence <= 0 {
			t.Fatalf("event %d = %#v", index, event)
		}
	}
	redacted := chain.Events[5]
	if !redacted.Redacted || redacted.Content != "" || redacted.Signature != "sha256:provider-redacted-digest" {
		t.Fatalf("redacted reasoning = %#v", redacted)
	}
	encoded, err := json.Marshal(chains)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(encoded), "private-alice-fairy") || strings.Contains(string(encoded), "provider-encrypted-reasoning") {
		t.Fatalf("decision-chain projection leaked private data: %s", encoded)
	}
}

type decisionChainAdminRuntime struct {
	chains []DecisionChain
}

func (*decisionChainAdminRuntime) ApplyBehaviorConfig(Config) {}

func (*decisionChainAdminRuntime) Snapshot(context.Context) RuntimeStatus { return RuntimeStatus{} }

func (r *decisionChainAdminRuntime) DecisionChains(context.Context, int) ([]DecisionChain, error) {
	return r.chains, nil
}

func TestFairyAdminAPIDecisionChains(t *testing.T) {
	cfg := testConfig(t)
	cfg.ConfigFile = ""
	runtime := &decisionChainAdminRuntime{chains: []DecisionChain{{TurnID: "turn-one", TraceID: "trace-one", Status: "running", Events: []DecisionChainEvent{}}}}
	handler := NewAdminAPIWithRuntime(NewConfigManager(cfg), "local-admin-token", nil, nil, runtime)

	request := httptest.NewRequest(http.MethodGet, "/admin/decision-chains?limit=20", nil)
	request.Header.Set("Authorization", "Bearer local-admin-token")
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if response.Code != http.StatusOK || !strings.Contains(response.Body.String(), `"turn_id":"turn-one"`) {
		t.Fatalf("decision-chain response status=%d body=%s", response.Code, response.Body.String())
	}

	invalid := httptest.NewRequest(http.MethodGet, "/admin/decision-chains?limit=0", nil)
	invalid.Header.Set("Authorization", "Bearer local-admin-token")
	invalidResponse := httptest.NewRecorder()
	handler.ServeHTTP(invalidResponse, invalid)
	if invalidResponse.Code != http.StatusBadRequest {
		t.Fatalf("invalid decision-chain limit status=%d", invalidResponse.Code)
	}
}
