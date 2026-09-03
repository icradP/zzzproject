package fairy

import (
	"context"
	"encoding/json"
	"os"
	"strings"
	"testing"
	"time"
)

func TestSQLiteTraceStorePersistsDedupeAndRedactsConversation(t *testing.T) {
	cfg := testConfig(t)
	store, err := OpenSQLiteTraceStore(cfg.TraceDB, cfg.TraceKeyFile)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Date(2026, 9, 2, 8, 0, 0, 0, time.UTC)
	claimed, err := store.ClaimIngress(context.Background(), "zzz-message", "message-1", now)
	if err != nil || !claimed {
		t.Fatalf("first ingress claim: claimed=%v err=%v", claimed, err)
	}
	claimed, err = store.ClaimIngress(context.Background(), "zzz-message", "message-1", now)
	if err != nil || claimed {
		t.Fatalf("duplicate ingress claim: claimed=%v err=%v", claimed, err)
	}
	conversationID := "private_alice_fairy"
	if err := store.Append(context.Background(), TraceEvent{
		Time:           now,
		Type:           TraceTurnCompleted,
		TraceID:        "trace-test",
		TurnID:         "turn-test",
		ConversationID: conversationID,
		Source:         "zzz-message",
		Status:         "completed",
	}); err != nil {
		t.Fatal(err)
	}
	if err := store.Append(context.Background(), TraceEvent{
		Time: now, Type: TraceTurnCompleted, TraceID: "trace-invalid", TurnID: "turn-invalid",
		ConversationID: conversationID, Source: "zzz-message", Status: "secret message",
	}); err == nil {
		t.Fatal("trace accepted an unrestricted status payload")
	}
	var conversationRef string
	var payload string
	if err := store.db.QueryRow(`SELECT conversation_ref, payload_json FROM fairy_trace_events LIMIT 1`).Scan(&conversationRef, &payload); err != nil {
		t.Fatal(err)
	}
	if conversationRef == conversationID || !strings.HasPrefix(conversationRef, "hmac-sha256:") {
		t.Fatalf("conversation reference = %q", conversationRef)
	}
	for _, forbidden := range []string{conversationID, "alice", "secret message", "api-key"} {
		if strings.Contains(conversationRef+payload, forbidden) {
			t.Fatalf("trace contains forbidden plaintext %q: ref=%q payload=%q", forbidden, conversationRef, payload)
		}
	}
	if err := store.Close(); err != nil {
		t.Fatal(err)
	}

	reopened, err := OpenSQLiteTraceStore(cfg.TraceDB, cfg.TraceKeyFile)
	if err != nil {
		t.Fatal(err)
	}
	defer reopened.Close()
	claimed, err = reopened.ClaimIngress(context.Background(), "zzz-message", "message-1", now.Add(time.Minute))
	if err != nil || claimed {
		t.Fatalf("reopened duplicate claim: claimed=%v err=%v", claimed, err)
	}
	info, err := os.Stat(cfg.TraceKeyFile)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("trace key mode = %#o", info.Mode().Perm())
	}
	databaseInfo, err := os.Stat(cfg.TraceDB)
	if err != nil {
		t.Fatal(err)
	}
	if databaseInfo.Mode().Perm() != 0o600 {
		t.Fatalf("trace database mode = %#o", databaseInfo.Mode().Perm())
	}
}

func TestSQLiteTraceStoreValidatesModelAttemptMetadata(t *testing.T) {
	cfg := testConfig(t)
	store, err := OpenSQLiteTraceStore(cfg.TraceDB, cfg.TraceKeyFile)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()

	valid := TraceEvent{
		Type: TraceModelAttempt, TraceID: "trace-model", TurnID: "turn-model",
		Source: "model-router", Status: "failed", TaskID: ReplyerTaskID,
		ProviderID: "provider-a", ModelID: "model-a", SnapshotID: "snapshot-test",
		Attempt: 1, Step: 2, PromptVersion: "replyer-v1", PromptDigest: store.DigestPrompt([]byte("private prompt text")),
		DurationMS: 25, FailureCode: string(ModelFailureRateLimited), Fallback: true,
	}
	if err := store.Append(context.Background(), valid); err != nil {
		t.Fatalf("valid model trace rejected: %v", err)
	}
	var payload string
	if err := store.db.QueryRow(`SELECT payload_json FROM fairy_trace_events WHERE type = 'model_attempt'`).Scan(&payload); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(payload, "replyer-v1") || !strings.Contains(payload, valid.PromptDigest) || strings.Contains(payload, "private prompt text") {
		t.Fatalf("prompt trace metadata = %s", payload)
	}

	invalidEvents := []TraceEvent{
		func() TraceEvent { event := valid; event.TaskID = "prompt text"; return event }(),
		func() TraceEvent { event := valid; event.FailureCode = "provider said secret"; return event }(),
		func() TraceEvent { event := valid; event.InputTokens = -1; return event }(),
		func() TraceEvent { event := valid; event.Step = 65; return event }(),
		func() TraceEvent { event := valid; event.PromptDigest = "sha256:not-an-hmac"; return event }(),
		func() TraceEvent { event := valid; event.PromptVersion = ""; return event }(),
		func() TraceEvent { event := valid; event.Status = "completed"; return event }(),
		func() TraceEvent { event := valid; event.TaskID = VisionTaskID; event.Repair = true; return event }(),
		{
			Type: TraceTurnCompleted, TraceID: "trace-extra", TurnID: "turn-extra",
			Source: "zzz-message", Status: "completed", ModelID: "model-a",
		},
	}
	for index, event := range invalidEvents {
		if err := store.Append(context.Background(), event); err == nil {
			t.Fatalf("invalid model trace %d was accepted: %#v", index, event)
		}
	}
}

func TestSQLiteTraceStoreValidatesToolCallMetadata(t *testing.T) {
	cfg := testConfig(t)
	store, err := OpenSQLiteTraceStore(cfg.TraceDB, cfg.TraceKeyFile)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()

	valid := TraceEvent{
		Type: TraceToolCall, TraceID: "trace-tool", TurnID: "turn-tool",
		Source: "zzz-message", Status: "completed", Step: 1,
		ToolCallID: "tool-call", ToolName: ZZZProfilePluginID, ToolRisk: "low",
		ToolPolicy: "allowed", ToolStatus: "completed", DurationMS: 20, ToolResultBytes: 128,
	}
	if err := store.Append(context.Background(), valid); err != nil {
		t.Fatalf("valid tool trace rejected: %v", err)
	}
	invalidEvents := []TraceEvent{
		func() TraceEvent { event := valid; event.ToolName = "user prompt"; return event }(),
		func() TraceEvent { event := valid; event.ToolPolicy = "bypassed"; return event }(),
		func() TraceEvent {
			event := valid
			event.ToolStatus = "completed"
			event.FailureCode = string(ToolFailureExecution)
			return event
		}(),
		func() TraceEvent { event := valid; event.ModelID = "model-a"; return event }(),
	}
	for index, event := range invalidEvents {
		if err := store.Append(context.Background(), event); err == nil {
			t.Fatalf("invalid tool trace %d was accepted: %#v", index, event)
		}
	}
}

func TestSQLiteTraceStoreAggregatesSanitizedRuntimeStats(t *testing.T) {
	cfg := testConfig(t)
	store, err := OpenSQLiteTraceStore(cfg.TraceDB, cfg.TraceKeyFile)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	now := time.Now()
	events := []TraceEvent{
		{
			Time: now, Type: TraceGateDecision, TraceID: "trace-gate", Source: "zzz-gate", Status: "wait",
			GateAction: GateWait, GateReason: GateReasonSoftShadow, GateShadow: true,
		},
		{
			Time: now, Type: TraceModelAttempt, TraceID: "trace-model", TurnID: "turn-model", Source: "model-router",
			Status: "completed", TaskID: ReplyerTaskID, ProviderID: "provider-a", ModelID: "model-a",
			SnapshotID: "snapshot-test", Attempt: 1, InputTokens: 120, OutputTokens: 40, CostMicroUSD: 350,
		},
		{
			Time: now, Type: TraceToolCall, TraceID: "trace-tool", TurnID: "turn-tool", Source: "zzz-message",
			Status: "failed", ToolCallID: "tool-call", ToolName: ZZZProfilePluginID, ToolRisk: "low",
			ToolPolicy: "allowed", ToolStatus: "failed", FailureCode: string(ToolFailureExecution),
		},
	}
	for _, event := range events {
		if err := store.Append(context.Background(), event); err != nil {
			t.Fatalf("append %#v: %v", event, err)
		}
	}
	stats, err := store.RuntimeStats(context.Background(), now.Add(-time.Minute))
	if err != nil {
		t.Fatal(err)
	}
	if stats.GateDecisions != 1 || stats.GateActions["wait"] != 1 || stats.GateReasons[GateReasonSoftShadow] != 1 ||
		stats.ModelAttempts != 1 || stats.ModelCompleted != 1 || stats.InputTokens != 120 || stats.OutputTokens != 40 ||
		stats.CostMicroUSD != 350 || stats.ToolCalls != 1 || stats.ToolFailed != 1 {
		t.Fatalf("runtime stats = %#v", stats)
	}
}

func TestSQLiteTraceStoreAggregatesStableModelHealth(t *testing.T) {
	cfg := testConfig(t)
	store, err := OpenSQLiteTraceStore(cfg.TraceDB, cfg.TraceKeyFile)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	now := time.Now()
	type modelEvent struct {
		task, provider, model, status, failure string
		duration                               int64
		input, output                          int
		cost                                   int64
		fallback                               bool
		repair                                 bool
		time                                   time.Time
	}
	events := []modelEvent{
		{ReplyerTaskID, "provider-a", "model-a", "completed", "", 100, 10, 4, 10, false, false, now},
		{ReplyerTaskID, "provider-a", "model-a", "completed", "", 200, 20, 5, 20, false, false, now},
		{ReplyerTaskID, "provider-a", "model-a", "failed", string(ModelFailureRateLimited), 300, 5, 0, 30, false, false, now},
		{ReplyerTaskID, "provider-a", "model-a", "completed", "", 400, 30, 6, 40, true, false, now},
		{ReplyerTaskID, "provider-a", "model-a", "completed", "", 500, 40, 7, 50, false, true, now},
		{PlannerTaskID, "provider-b", "model-b", "failed", string(ModelFailureNetwork), 1000, 7, 0, 9, true, true, now},
		{ReplyerTaskID, "provider-old", "model-old", "completed", "", 50, 1, 1, 1, false, false, now.Add(-2 * time.Hour)},
	}
	for index, value := range events {
		event := TraceEvent{
			Time: value.time, Type: TraceModelAttempt,
			TraceID: "trace-health-" + string(rune('a'+index)), TurnID: "turn-health-" + string(rune('a'+index)),
			ConversationID: "private-health-secret", Source: "model-router", Status: value.status,
			TaskID: value.task, ProviderID: value.provider, ModelID: value.model, SnapshotID: "snapshot-health",
			Attempt: index + 1, DurationMS: value.duration, InputTokens: value.input, OutputTokens: value.output,
			CostMicroUSD: value.cost, FailureCode: value.failure, Fallback: value.fallback, Repair: value.repair,
		}
		if value.repair {
			event.Step = 1
		}
		if err := store.Append(context.Background(), event); err != nil {
			t.Fatalf("append model health event %d: %v", index, err)
		}
	}
	stats, err := store.RuntimeStats(context.Background(), now.Add(-time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	if len(stats.ModelHealth) != 2 {
		t.Fatalf("model health groups = %#v", stats.ModelHealth)
	}
	planner := stats.ModelHealth[0]
	if planner.TaskID != PlannerTaskID || planner.ProviderID != "provider-b" || planner.ModelID != "model-b" ||
		planner.Attempts != 1 || planner.Completed != 0 || planner.Failed != 1 || planner.FallbackAttempts != 1 ||
		planner.RepairAttempts != 1 || planner.P50Millis != 1000 || planner.P95Millis != 1000 ||
		planner.FailureCodes[string(ModelFailureNetwork)] != 1 {
		t.Fatalf("planner model health = %#v", planner)
	}
	replyer := stats.ModelHealth[1]
	if replyer.TaskID != ReplyerTaskID || replyer.ProviderID != "provider-a" || replyer.ModelID != "model-a" ||
		replyer.Attempts != 5 || replyer.Completed != 4 || replyer.Failed != 1 || replyer.FallbackAttempts != 1 ||
		replyer.RepairAttempts != 1 ||
		replyer.P50Millis != 300 || replyer.P95Millis != 500 || replyer.InputTokens != 105 || replyer.OutputTokens != 22 ||
		replyer.CostMicroUSD != 150 || replyer.FailureCodes[string(ModelFailureRateLimited)] != 1 {
		t.Fatalf("replyer model health = %#v", replyer)
	}
	encoded, err := json.Marshal(stats.ModelHealth)
	if err != nil {
		t.Fatal(err)
	}
	for _, forbidden := range []string{"private-health-secret", "snapshot-health", "trace-health", "turn-health", "provider-old", "model-old"} {
		if strings.Contains(string(encoded), forbidden) {
			t.Fatalf("model health exposed private or expired metadata %q: %s", forbidden, encoded)
		}
	}
}

func TestSQLiteTraceStoreProjectsBoundedRecentFailuresWithoutIdentity(t *testing.T) {
	cfg := testConfig(t)
	store, err := OpenSQLiteTraceStore(cfg.TraceDB, cfg.TraceKeyFile)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	now := time.Now().UTC().Truncate(time.Millisecond)
	events := []TraceEvent{
		{
			Time: now.Add(-4 * time.Minute), Type: TraceModelAttempt,
			TraceID: "trace-recent-model", TurnID: "turn-recent-model", ConversationID: "private-recent-secret",
			Source: "model-router", Status: "failed", TaskID: PlannerTaskID, ProviderID: "provider-a", ModelID: "model-a",
			SnapshotID: "snapshot-recent-secret", Attempt: 2, Step: 1, DurationMS: 450,
			FailureCode: string(ModelFailureNetwork), Fallback: true, Repair: true,
		},
		{
			Time: now.Add(-3 * time.Minute), Type: TraceToolCall,
			TraceID: "trace-recent-tool", TurnID: "turn-recent-tool", ConversationID: "private-recent-secret",
			Source: "zzz-message", Status: "failed", Step: 2, ToolCallID: "call-recent-secret", ToolName: ZZZProfilePluginID,
			ToolRisk: string(RiskLow), ToolPolicy: "allowed", ToolStatus: "timed_out", DurationMS: 900,
			FailureCode: string(ToolFailureTimeout),
		},
		{
			Time: now.Add(-2 * time.Minute), Type: TraceAdmissionRejected,
			TraceID: "trace-recent-admission", ConversationID: "private-recent-secret", Source: "zzz-message",
			Status: "global_pending_limit", QueueDepth: 31, Pending: 20,
		},
		{
			Time: now.Add(-time.Minute), Type: TraceTurnTimedOut,
			TraceID: "trace-recent-turn", TurnID: "turn-recent-timeout", ConversationID: "private-recent-secret",
			Source: "zzz-message", Status: "deadline_exceeded",
		},
		{
			Time: now, Type: TraceModelAttempt,
			TraceID: "trace-recent-success", TurnID: "turn-recent-success", ConversationID: "private-recent-secret",
			Source: "model-router", Status: "completed", TaskID: ReplyerTaskID, ProviderID: "provider-a", ModelID: "model-a",
			SnapshotID: "snapshot-recent-secret", Attempt: 1, DurationMS: 100, InputTokens: 10, OutputTokens: 2,
		},
	}
	for index, event := range events {
		if err := store.Append(context.Background(), event); err != nil {
			t.Fatalf("append recent failure event %d: %v", index, err)
		}
	}
	stats, err := store.RuntimeStats(context.Background(), now.Add(-time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	if len(stats.RecentFailures) != 4 {
		t.Fatalf("recent failures = %#v", stats.RecentFailures)
	}
	turnFailure, admissionFailure, toolFailure, modelFailure := stats.RecentFailures[0], stats.RecentFailures[1], stats.RecentFailures[2], stats.RecentFailures[3]
	if turnFailure.Kind != "turn" || turnFailure.Code != "deadline_exceeded" || !turnFailure.OccurredAt.Equal(now.Add(-time.Minute)) {
		t.Fatalf("turn failure = %#v", turnFailure)
	}
	if admissionFailure.Kind != "admission" || admissionFailure.Code != "global_pending_limit" ||
		admissionFailure.QueueDepth != 31 || admissionFailure.PendingTurns != 20 {
		t.Fatalf("admission failure = %#v", admissionFailure)
	}
	if toolFailure.Kind != "tool" || toolFailure.Code != string(ToolFailureTimeout) ||
		toolFailure.ToolName != ZZZProfilePluginID || toolFailure.ToolStatus != "timed_out" ||
		toolFailure.DurationMS != 900 || toolFailure.Step != 2 {
		t.Fatalf("tool failure = %#v", toolFailure)
	}
	if modelFailure.Kind != "model" || modelFailure.Code != string(ModelFailureNetwork) ||
		modelFailure.TaskID != PlannerTaskID || modelFailure.ProviderID != "provider-a" || modelFailure.ModelID != "model-a" ||
		modelFailure.DurationMS != 450 || modelFailure.Attempt != 2 || modelFailure.Step != 1 || !modelFailure.Fallback || !modelFailure.Repair {
		t.Fatalf("model failure = %#v", modelFailure)
	}
	encoded, err := json.Marshal(stats.RecentFailures)
	if err != nil {
		t.Fatal(err)
	}
	for _, forbidden := range []string{
		"private-recent-secret", "trace-recent", "turn-recent", "snapshot-recent-secret", "call-recent-secret",
	} {
		if strings.Contains(string(encoded), forbidden) {
			t.Fatalf("recent failures exposed private metadata %q: %s", forbidden, encoded)
		}
	}
}

func TestSQLiteTraceStoreLimitsRecentFailuresToNewestTwenty(t *testing.T) {
	cfg := testConfig(t)
	store, err := OpenSQLiteTraceStore(cfg.TraceDB, cfg.TraceKeyFile)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	now := time.Now().UTC().Truncate(time.Millisecond)
	for index := 0; index < maxRecentTraceFailures+5; index++ {
		if err := store.Append(context.Background(), TraceEvent{
			Time: now.Add(time.Duration(index) * time.Millisecond), Type: TraceAdmissionRejected,
			TraceID: "trace-limit-" + string(rune('a'+index)), Source: "zzz-message",
			Status: "conversation_pending_limit", QueueDepth: index, Pending: index,
		}); err != nil {
			t.Fatalf("append bounded failure %d: %v", index, err)
		}
	}
	stats, err := store.RuntimeStats(context.Background(), now.Add(-time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	if len(stats.RecentFailures) != maxRecentTraceFailures || stats.RecentFailures[0].QueueDepth != 24 ||
		stats.RecentFailures[maxRecentTraceFailures-1].QueueDepth != 5 {
		t.Fatalf("bounded recent failures = %#v", stats.RecentFailures)
	}
}

func TestSQLiteTraceStoreRejectsUntrustedRecentFailureMetadata(t *testing.T) {
	cfg := testConfig(t)
	store, err := OpenSQLiteTraceStore(cfg.TraceDB, cfg.TraceKeyFile)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	now := time.Now()
	_, err = store.db.Exec(`
		INSERT INTO fairy_trace_events(time_ms, type, trace_id, turn_id, conversation_ref, payload_json)
		VALUES (?, 'tool_call', 'trace-untrusted', 'turn-untrusted', '', ?)`, now.UnixMilli(),
		`{"status":"failed","gen_ai.tool.name":"zzz-profile","fairy.tool.risk":"low","fairy.tool.policy":"allowed","fairy.tool.status":"failed","error.type":"provider exposed private response"}`)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.RuntimeStats(context.Background(), now.Add(-time.Minute)); err == nil ||
		!strings.Contains(err.Error(), "invalid Fairy tool metadata") {
		t.Fatalf("untrusted failure metadata was not rejected: %v", err)
	}
}

func TestSQLiteTraceStoreRejectsInvalidGateMetadata(t *testing.T) {
	cfg := testConfig(t)
	store, err := OpenSQLiteTraceStore(cfg.TraceDB, cfg.TraceKeyFile)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	valid := TraceEvent{
		Type: TraceGateDecision, TraceID: "trace-gate", Source: "zzz-gate", Status: "ignore",
		GateAction: GateIgnore, GateReason: GateReasonGroupNoTrigger,
	}
	if err := store.Append(context.Background(), valid); err != nil {
		t.Fatal(err)
	}
	invalid := valid
	invalid.GateReason = "user said secret text"
	if err := store.Append(context.Background(), invalid); err == nil {
		t.Fatal("trace accepted unrestricted gate reason")
	}
	invalid = valid
	invalid.GateShadow = true
	if err := store.Append(context.Background(), invalid); err == nil {
		t.Fatal("trace accepted invalid shadow metadata")
	}
}
