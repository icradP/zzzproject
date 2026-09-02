package fairy

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"
)

func TestRuntimeInspectorReportsActualRuntimeAndAppliesBehavior(t *testing.T) {
	cfg := testConfig(t)
	cfg.ModelTasks = []ModelTaskConfig{
		{ID: ReplyerTaskID, DailyLimit: 2},
		{ID: VisionTaskID, DailyLimit: 1},
	}
	cfg.BehaviorExperiences = []BehaviorExperienceConfig{
		{ID: "enabled", Enabled: true, Scope: BehaviorExperienceScopeAll, Keywords: []string{"hello"}, Scene: "greeting", Action: "reply", Outcome: "helped"},
		{ID: "disabled", Enabled: false, Scope: BehaviorExperienceScopeAll, Keywords: []string{"bye"}, Scene: "farewell", Action: "reply", Outcome: "helped"},
	}
	state, err := OpenStateStoreWithDefaults(cfg.StateFile, cfg.GroupDefault, cfg.GroupSoftDefault)
	if err != nil {
		t.Fatal(err)
	}
	trace, err := OpenSQLiteTraceStore(cfg.TraceDB, cfg.TraceKeyFile)
	if err != nil {
		t.Fatal(err)
	}
	defer trace.Close()
	if err := trace.Append(context.Background(), TraceEvent{
		Time: time.Now(), Type: TraceModelAttempt, TraceID: "trace-runtime-model", TurnID: "turn-runtime-model",
		ConversationID: "private_runtime_health", Source: "model-router", Status: "completed",
		TaskID: ReplyerTaskID, ProviderID: "provider-runtime", ModelID: "model-runtime",
		SnapshotID: "snapshot-runtime", Attempt: 1, DurationMS: 125, InputTokens: 20, OutputTokens: 8,
	}); err != nil {
		t.Fatal(err)
	}
	feedbackMessageID := "runtime-private-message"
	feedbackActorID := "runtime-private-user"
	if err := trace.RegisterFeedbackOutput(context.Background(), feedbackMessageID, "turn-runtime-feedback", time.Now()); err != nil {
		t.Fatal(err)
	}
	if changed, err := trace.ApplyFeedback(context.Background(), feedbackMessageID, feedbackActorID, FeedbackPositive, false, time.Now()); err != nil || !changed {
		t.Fatalf("seed runtime feedback: changed=%v err=%v", changed, err)
	}
	facts, err := OpenSQLiteFactMemoryStore(cfg.FactDB)
	if err != nil {
		t.Fatal(err)
	}
	defer facts.Close()
	factScope := FactScope{Type: FactScopePrivate, ID: "private_alice_fairy", OwnerUserID: "alice"}
	if _, err := facts.Remember(context.Background(), factScope, "private fact body", "message_fact", time.Now()); err != nil {
		t.Fatal(err)
	}
	if err := state.SetFactMemoryEnabled(factScope, true); err != nil {
		t.Fatal(err)
	}
	if _, _, allowed, err := state.TakeTaskModelCall(time.Now(), cfg.ModelDailyLimit, ReplyerTaskID, 2); err != nil || !allowed {
		t.Fatalf("reserve runtime quota: allowed=%v err=%v", allowed, err)
	}
	engine := NewEngineWithFactMemory(cfg, state, nil, trace, facts, NewZZZPlugin(cfg))
	runner := NewRunner(cfg, engine, trace)
	runner.messenger.delivered.Store(3)
	runner.messenger.retryAttempts.Store(1)
	runner.messenger.failed.Store(2)
	runner.messenger.outcomeUnknown.Store(1)
	inspector := NewRuntimeInspector(engine, runner, trace, facts)

	status := inspector.Snapshot(context.Background())
	if status.Behavior.GroupSoftTrigger != "shadow" || status.Behavior.ExpressionStyle != "normal" ||
		!status.Scheduler.Accepting || status.Scheduler.MaxConcurrent != cfg.MaxConcurrent ||
		!status.TraceAvailable || len(status.Tools) != 1 || status.Tools[0].Name != ZZZProfilePluginID ||
		!status.Tools[0].Enabled || !status.Tools[0].PolicyAllowed || !status.FactMemory.Available ||
		status.FactMemory.Facts != 1 || status.FactMemory.StoredScopes != 1 || status.FactMemory.EnabledScopes != 1 ||
		status.BehaviorExperiences.Configured != 2 || status.BehaviorExperiences.Enabled != 1 || status.BehaviorExperiences.AutoLearning {
		t.Fatalf("runtime status = %#v", status)
	}
	if status.ModelQuota.Used != 1 || status.ModelQuota.Remaining != 1 || len(status.TaskModelQuotas) != 2 ||
		status.TaskModelQuotas[0].TaskID != ReplyerTaskID || status.TaskModelQuotas[0].Used != 1 || status.TaskModelQuotas[0].Remaining != 1 ||
		status.TaskModelQuotas[1].TaskID != VisionTaskID || status.TaskModelQuotas[1].Used != 0 || status.TaskModelQuotas[1].Remaining != 1 {
		t.Fatalf("runtime quota status = global %#v tasks %#v", status.ModelQuota, status.TaskModelQuotas)
	}
	if status.OutboundDelivery.Delivered != 3 || status.OutboundDelivery.RetryAttempts != 1 ||
		status.OutboundDelivery.Failed != 2 || status.OutboundDelivery.OutcomeUnknown != 1 {
		t.Fatalf("runtime outbound status = %#v", status.OutboundDelivery)
	}
	if !status.Feedback.Available || status.Feedback.WindowHours != 24 || status.Feedback.RatedOutputs != 1 ||
		status.Feedback.Positive != 1 || status.Feedback.Negative != 0 || status.Feedback.PositiveRate != 1 {
		t.Fatalf("runtime feedback status = %#v", status.Feedback)
	}
	if len(status.Trace.ModelHealth) != 1 || status.Trace.ModelHealth[0].TaskID != ReplyerTaskID ||
		status.Trace.ModelHealth[0].ProviderID != "provider-runtime" || status.Trace.ModelHealth[0].ModelID != "model-runtime" ||
		status.Trace.ModelHealth[0].Completed != 1 || status.Trace.ModelHealth[0].P50Millis != 125 ||
		status.Trace.ModelHealth[0].P95Millis != 125 {
		t.Fatalf("runtime model health = %#v", status.Trace.ModelHealth)
	}
	encodedStatus, err := json.Marshal(status)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(encodedStatus), "private fact body") || strings.Contains(string(encodedStatus), "private_alice_fairy") ||
		strings.Contains(string(encodedStatus), feedbackMessageID) || strings.Contains(string(encodedStatus), feedbackActorID) ||
		strings.Contains(string(encodedStatus), "turn-runtime-feedback") || strings.Contains(string(encodedStatus), "private_runtime_health") ||
		strings.Contains(string(encodedStatus), "trace-runtime-model") || strings.Contains(string(encodedStatus), "turn-runtime-model") ||
		strings.Contains(string(encodedStatus), "snapshot-runtime") {
		t.Fatalf("runtime status leaked fact content or scope: %s", encodedStatus)
	}

	updated := cfg
	updated.GroupSoftDefault = GroupSoftOn
	updated.FocusTTL = 3 * time.Minute
	updated.SoftCooldown = 45 * time.Second
	updated.ExpressionStyle = ExpressionDetailed
	inspector.ApplyBehaviorConfig(updated)
	status = inspector.Snapshot(context.Background())
	if status.Behavior.GroupSoftTrigger != "on" || status.Behavior.FocusTTLSeconds != 180 ||
		status.Behavior.CooldownSeconds != 45 || status.Behavior.ExpressionStyle != "detailed" ||
		state.GroupSoftMode("new_group") != GroupSoftOn {
		t.Fatalf("live behavior status = %#v", status.Behavior)
	}
}

func TestRuntimeInspectorKeepsEmptyModelHealthAsJSONArray(t *testing.T) {
	status := (*RuntimeInspector)(nil).Snapshot(context.Background())
	encoded, err := json.Marshal(status)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(encoded), `"model_health":[]`) {
		t.Fatalf("empty runtime model health is not an array: %s", encoded)
	}
	if !strings.Contains(string(encoded), `"recent_failures":[]`) {
		t.Fatalf("empty runtime recent failures is not an array: %s", encoded)
	}
}
