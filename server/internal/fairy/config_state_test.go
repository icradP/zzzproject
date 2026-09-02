package fairy

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestConfigValidation(t *testing.T) {
	cfg := testConfig(t)
	if err := cfg.Validate(); err != nil {
		t.Fatalf("valid config rejected: %v", err)
	}

	invalid := cfg
	invalid.ServerURL = "https://example.test/ws"
	if err := invalid.Validate(); err == nil {
		t.Fatal("HTTP server URL was accepted")
	}
	invalid = cfg
	invalid.ZZZAPIURL = "http://example.test/{uid}"
	if err := invalid.Validate(); err == nil {
		t.Fatal("insecure public ZZZ API URL was accepted")
	}
	invalid = cfg
	invalid.ModelBaseURL = "https://model.example.test/v1"
	if err := invalid.Validate(); err == nil {
		t.Fatal("partial model configuration was accepted")
	}
	invalid = cfg
	invalid.ReconnectMin = 0
	if err := invalid.Validate(); err == nil {
		t.Fatal("zero reconnect delay was accepted")
	}
	invalid = cfg
	invalid.GroupSoftDefault = "automatic"
	if err := invalid.Validate(); err == nil {
		t.Fatal("unknown soft-trigger mode was accepted")
	}
	invalid = cfg
	invalid.FocusTTL = time.Second
	if err := invalid.Validate(); err == nil {
		t.Fatal("invalid focus TTL was accepted")
	}
	invalid = cfg
	invalid.ExpressionStyle = "verbose"
	if err := invalid.Validate(); err == nil {
		t.Fatal("unknown expression style was accepted")
	}
	invalid = cfg
	invalid.ExternalToolProviders = []ExternalToolProviderConfig{{
		ID: "provider", Enabled: true, Protocol: MCPStdioProtocol, Command: "/usr/bin/true",
		AllowedTools: []string{"BadTool"},
	}}
	if err := invalid.Validate(); err == nil {
		t.Fatal("invalid external tool name was accepted")
	}
}

func TestStateStorePersistsSwitchesAndDailyQuota(t *testing.T) {
	path := filepath.Join(t.TempDir(), "state.json")
	state, err := OpenStateStore(path, true)
	if err != nil {
		t.Fatal(err)
	}
	if !state.GroupEnabled("group_a") {
		t.Fatal("default-enabled group was disabled")
	}
	if err := state.SetGroupEnabled("group_a", false); err != nil {
		t.Fatal(err)
	}
	if state.GroupSoftMode("group_a") != GroupSoftShadow {
		t.Fatal("group soft-trigger default was not shadow")
	}
	if err := state.SetGroupSoftMode("group_a", GroupSoftOn); err != nil {
		t.Fatal(err)
	}
	if err := state.SetGroupEnabled("group_a", true); err != nil {
		t.Fatal(err)
	}
	if state.GroupSoftMode("group_a") != GroupSoftOn {
		t.Fatal("group enable update overwrote soft-trigger mode")
	}
	if err := state.SetGroupEnabled("group_a", false); err != nil {
		t.Fatal(err)
	}
	if !state.ContextEnabled("private_alice_fairy") {
		t.Fatal("memory was disabled by default")
	}
	if err := state.SetContextEnabled("private_alice_fairy", false); err != nil {
		t.Fatal(err)
	}
	factScope := FactScope{Type: FactScopePrivate, ID: "private_alice_fairy", OwnerUserID: "alice"}
	if state.FactMemoryEnabled(factScope) {
		t.Fatal("fact memory was enabled by default")
	}
	if err := state.SetFactMemoryEnabled(factScope, true); err != nil {
		t.Fatal(err)
	}
	now := time.Date(2026, 9, 1, 12, 0, 0, 0, time.UTC)
	for expected := 1; expected <= 2; expected++ {
		used, allowed, err := state.TakeModelCall(now, 2)
		if err != nil || !allowed || used != expected {
			t.Fatalf("quota call %d = used %d allowed %v err %v", expected, used, allowed, err)
		}
	}
	if used, allowed, err := state.TakeModelCall(now, 2); err != nil || allowed || used != 2 {
		t.Fatalf("exhausted quota = used %d allowed %v err %v", used, allowed, err)
	}
	if used, remaining := state.ModelQuotaStatus(now, 2); used != 2 || remaining != 0 {
		t.Fatalf("quota status = used %d remaining %d", used, remaining)
	}
	if used, remaining := state.ModelQuotaStatus(now.Add(24*time.Hour), 2); used != 0 || remaining != 2 {
		t.Fatalf("next-day quota status = used %d remaining %d", used, remaining)
	}

	reopened, err := OpenStateStore(path, true)
	if err != nil {
		t.Fatal(err)
	}
	if reopened.GroupEnabled("group_a") {
		t.Fatal("group switch was not persisted")
	}
	if reopened.GroupSoftMode("group_a") != GroupSoftOn {
		t.Fatal("group soft-trigger mode was not persisted")
	}
	if reopened.ContextEnabled("private_alice_fairy") {
		t.Fatal("memory switch was not persisted")
	}
	if !reopened.FactMemoryEnabled(factScope) || reopened.FactMemoryEnabledScopeCount() != 1 {
		t.Fatal("fact-memory opt-in was not persisted")
	}
	if err := reopened.SetFactMemoryEnabled(factScope, false); err != nil || reopened.FactMemoryEnabled(factScope) {
		t.Fatalf("fact-memory opt-out failed: %v", err)
	}
	if err := reopened.SetContextEnabled("private_alice_fairy", true); err != nil {
		t.Fatal(err)
	}
	if !reopened.ContextEnabled("private_alice_fairy") {
		t.Fatal("memory switch was not re-enabled")
	}
	if used, allowed, err := reopened.TakeModelCall(now.Add(24*time.Hour), 2); err != nil || !allowed || used != 1 {
		t.Fatalf("next-day quota = used %d allowed %v err %v", used, allowed, err)
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("state mode = %o, want 600", info.Mode().Perm())
	}
}

func TestStateStorePersistsIndependentTaskQuotas(t *testing.T) {
	path := filepath.Join(t.TempDir(), "state.json")
	state, err := OpenStateStore(path, true)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Date(2026, 9, 2, 12, 0, 0, 0, time.UTC)
	if global, task, allowed, err := state.TakeTaskModelCall(now, 3, VisionTaskID, 1); err != nil || !allowed || global != 1 || task != 1 {
		t.Fatalf("first vision reservation = global %d task %d allowed %v err %v", global, task, allowed, err)
	}
	if global, task, allowed, err := state.TakeTaskModelCall(now, 3, VisionTaskID, 1); err != nil || allowed || global != 1 || task != 1 {
		t.Fatalf("exhausted vision reservation = global %d task %d allowed %v err %v", global, task, allowed, err)
	}
	for expected := 1; expected <= 2; expected++ {
		global, task, allowed, err := state.TakeTaskModelCall(now, 3, ReplyerTaskID, 3)
		if err != nil || !allowed || global != expected+1 || task != expected {
			t.Fatalf("replyer reservation %d = global %d task %d allowed %v err %v", expected, global, task, allowed, err)
		}
	}
	if global, task, allowed, err := state.TakeTaskModelCall(now, 3, PlannerTaskID, 3); err != nil || allowed || global != 3 || task != 0 {
		t.Fatalf("global exhaustion = global %d task %d allowed %v err %v", global, task, allowed, err)
	}
	if used, remaining := state.TaskModelQuotaStatus(now, VisionTaskID, 1); used != 1 || remaining != 0 {
		t.Fatalf("vision status = used %d remaining %d", used, remaining)
	}

	reopened, err := OpenStateStore(path, true)
	if err != nil {
		t.Fatal(err)
	}
	if used, remaining := reopened.TaskModelQuotaStatus(now, ReplyerTaskID, 3); used != 2 || remaining != 1 {
		t.Fatalf("persisted replyer status = used %d remaining %d", used, remaining)
	}
	if used, remaining := reopened.TaskModelQuotaStatus(now.Add(24*time.Hour), VisionTaskID, 1); used != 0 || remaining != 1 {
		t.Fatalf("next-day vision status = used %d remaining %d", used, remaining)
	}
}

func TestStateStoreRollsBackWhenPersistenceFails(t *testing.T) {
	blockingFile := filepath.Join(t.TempDir(), "not-a-directory")
	if err := os.WriteFile(blockingFile, []byte("block"), 0o600); err != nil {
		t.Fatal(err)
	}
	state, err := OpenStateStore(filepath.Join(t.TempDir(), "state.json"), true)
	if err != nil {
		t.Fatal(err)
	}
	state.path = filepath.Join(blockingFile, "state.json")
	if err := state.SetGroupEnabled("group_a", false); err == nil {
		t.Fatal("state write unexpectedly succeeded")
	}
	if !state.GroupEnabled("group_a") {
		t.Fatal("failed group write changed in-memory state")
	}
	if err := state.SetGroupSoftMode("group_a", GroupSoftOn); err == nil {
		t.Fatal("soft-trigger state write unexpectedly succeeded")
	}
	if state.GroupSoftMode("group_a") != GroupSoftShadow {
		t.Fatal("failed soft-trigger write changed in-memory state")
	}
	if err := state.SetContextEnabled("private_alice_fairy", false); err == nil {
		t.Fatal("state write unexpectedly succeeded")
	}
	factScope := FactScope{Type: FactScopePrivate, ID: "private_alice_fairy", OwnerUserID: "alice"}
	if err := state.SetFactMemoryEnabled(factScope, true); err == nil {
		t.Fatal("state write unexpectedly succeeded")
	}
	if state.FactMemoryEnabled(factScope) {
		t.Fatal("failed fact-memory state write changed in-memory state")
	}
	if !state.ContextEnabled("private_alice_fairy") {
		t.Fatal("failed memory write changed in-memory state")
	}
	now := time.Date(2026, 9, 1, 12, 0, 0, 0, time.UTC)
	if _, allowed, err := state.TakeModelCall(now, 2); err == nil || allowed {
		t.Fatalf("failed quota write = allowed %v err %v", allowed, err)
	}
	if state.state.QuotaDate != "" || state.state.QuotaCalls != 0 {
		t.Fatalf("failed quota write changed in-memory state: %#v", state.state)
	}
	if _, _, allowed, err := state.TakeTaskModelCall(now, 2, VisionTaskID, 1); err == nil || allowed {
		t.Fatalf("failed task quota write = allowed %v err %v", allowed, err)
	}
	if len(state.state.TaskQuotaDates) != 0 || len(state.state.TaskQuotaCalls) != 0 {
		t.Fatalf("failed task quota write changed in-memory state: %#v", state.state)
	}
}

func testConfig(t *testing.T) Config {
	t.Helper()
	return Config{
		ServerURL:              "ws://127.0.0.1:18080/ws",
		UserID:                 "fairy",
		Password:               "fairy-test-password",
		InviteCode:             "diaogan",
		Nickname:               "Fairy",
		AvatarURL:              "https://example.test/fairy.png",
		Bio:                    "Test assistant",
		DeviceID:               "fairy-test",
		StateFile:              filepath.Join(t.TempDir(), "state.json"),
		ConfigFile:             filepath.Join(t.TempDir(), "config.json"),
		TraceDB:                filepath.Join(t.TempDir(), "fairy.db"),
		TraceKeyFile:           filepath.Join(t.TempDir(), "trace.key"),
		FactDB:                 filepath.Join(t.TempDir(), "facts.db"),
		HealthAddr:             "127.0.0.1:18081",
		GroupDefault:           true,
		GroupSoftDefault:       GroupSoftShadow,
		FocusTTL:               2 * time.Minute,
		SoftCooldown:           30 * time.Second,
		ExpressionStyle:        ExpressionNormal,
		RateLimit:              0,
		ContextTTL:             30 * time.Minute,
		ContextMessages:        12,
		MaxConcurrent:          4,
		MaxPending:             32,
		MaxConversationPending: 8,
		TurnTimeout:            time.Minute,
		DrainTimeout:           time.Second,
		ModelDailyLimit:        2,
		ModelMaxTokens:         600,
		SystemPrompt:           defaultSystemPrompt,
		ZZZAPIURL:              "https://enka.network/api/zzz/uid/{uid}",
		ZZZRequestTimeout:      time.Second,
		PluginEnabled:          map[string]bool{ZZZProfilePluginID: true},
		ReconnectMin:           10 * time.Millisecond,
		ReconnectMax:           50 * time.Millisecond,
	}
}
