package fairy

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

func TestReplyerQualificationRequiresEveryCandidateAndTracksModelConfiguration(t *testing.T) {
	cfg := modelRouterTestConfig(t, "https://model.example.test/v1", 1)
	cfg.AIEnabled = false
	if required, missing := replyerQualificationState(cfg); !reflect.DeepEqual(required, []string{"primary", "fallback"}) || !reflect.DeepEqual(missing, required) || cfg.ProductionReady() {
		t.Fatalf("initial qualification state required=%v missing=%v ready=%v", required, missing, cfg.ProductionReady())
	}

	cfg = qualifyModelsForTest(t, cfg, "primary")
	if _, missing := replyerQualificationState(cfg); !reflect.DeepEqual(missing, []string{"fallback"}) || cfg.ProductionReady() {
		t.Fatalf("partial qualification state missing=%v ready=%v", missing, cfg.ProductionReady())
	}
	cfg = qualifyModelsForTest(t, cfg, "fallback")
	if _, missing := replyerQualificationState(cfg); len(missing) != 0 || !cfg.ProductionReady() {
		t.Fatalf("complete qualification state missing=%v ready=%v", missing, cfg.ProductionReady())
	}

	tests := []struct {
		name   string
		mutate func(*Config)
		want   []string
	}{
		{name: "provider URL", mutate: func(value *Config) { value.ModelProviders[0].BaseURL = "https://other.example.test/v1" }, want: []string{"primary", "fallback"}},
		{name: "provider protocol", mutate: func(value *Config) { value.ModelProviders[0].Protocol = AnthropicCompatibleProtocol }, want: []string{"primary", "fallback"}},
		{name: "provider API key", mutate: func(value *Config) { value.ModelProviders[0].APIKey = "replacement-key" }, want: []string{"primary", "fallback"}},
		{name: "provider timeout", mutate: func(value *Config) { value.ModelProviders[0].Timeout++ }, want: []string{"primary", "fallback"}},
		{name: "provider retries", mutate: func(value *Config) { value.ModelProviders[0].MaxRetries++ }, want: []string{"primary", "fallback"}},
		{name: "remote model", mutate: func(value *Config) { value.ModelDefinitions[0].RemoteName = "primary-v2" }, want: []string{"primary"}},
		{name: "context window", mutate: func(value *Config) { value.ModelDefinitions[1].ContextWindow++ }, want: []string{"fallback"}},
		{name: "token price", mutate: func(value *Config) { value.ModelDefinitions[1].OutputPriceMicrosPerMillionTokens++ }, want: []string{"fallback"}},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			changed := cloneConfig(cfg)
			test.mutate(&changed)
			_, missing := replyerQualificationState(changed)
			if !reflect.DeepEqual(missing, test.want) || changed.ProductionReady() {
				t.Fatalf("changed qualification state missing=%v ready=%v", missing, changed.ProductionReady())
			}
		})
	}
}

func TestManagedConfigQualificationCollectionsUseEmptyArrays(t *testing.T) {
	view := managedConfigView(testConfig(t))
	if view.ModelQualifications == nil || view.UnqualifiedReplyerModels == nil ||
		len(view.ModelQualifications) != 0 || len(view.UnqualifiedReplyerModels) != 0 {
		t.Fatalf("empty qualification view = qualifications %#v missing %#v",
			view.ModelQualifications, view.UnqualifiedReplyerModels)
	}
}

func TestConfigManagerPersistsQualificationsAndRedactsManagementAPI(t *testing.T) {
	cfg := modelRouterTestConfig(t, "https://model.example.test/v1", 0)
	cfg.AIEnabled = false
	cfg.ConfigFile = filepath.Join(t.TempDir(), "managed.json")
	manager := NewConfigManager(cfg)
	fixedNow := time.Date(2026, time.September, 3, 9, 0, 0, 0, time.UTC)
	manager.now = func() time.Time { return fixedNow }

	fingerprints := make([]string, 0, 2)
	for _, modelID := range []string{"primary", "fallback"} {
		fingerprint, err := modelQualificationFingerprint(manager.Current(), modelID)
		if err != nil {
			t.Fatal(err)
		}
		fingerprints = append(fingerprints, fingerprint)
		if err := manager.RecordModelQualification(modelID, fingerprint, QualityEvalCorpusVersion); err != nil {
			t.Fatal(err)
		}
	}

	response := manager.Response(true)
	if !response.Config.ProductionReady || len(response.Config.ModelQualifications) != 2 ||
		len(response.Config.UnqualifiedReplyerModels) != 0 || response.ConfigStatus.Revision != "2" ||
		response.ConfigStatus.ActiveRevision != "2" || response.ConfigStatus.State != "active" ||
		!reflect.DeepEqual(response.ConfigStatus.RecentChanges[0].Sections, []string{"model_validation"}) {
		t.Fatalf("qualification response = %#v", response)
	}
	encoded, err := json.Marshal(response)
	if err != nil {
		t.Fatal(err)
	}
	for _, forbidden := range append(fingerprints, cfg.ModelProviders[0].APIKey) {
		if bytes.Contains(encoded, []byte(forbidden)) {
			t.Fatalf("management API leaked private qualification material")
		}
	}
	stored, err := os.ReadFile(cfg.ConfigFile)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Contains(stored, []byte(`"version": 9`)) || !bytes.Contains(stored, []byte(`"model_qualifications"`)) {
		t.Fatalf("qualifications were not persisted: %s", stored)
	}
	reloaded, err := loadManagedConfig(cfg)
	if err != nil {
		t.Fatal(err)
	}
	if !reloaded.ProductionReady() || len(reloaded.ModelQualifications) != 2 || reloaded.managedConfigRevision != 2 {
		t.Fatalf("reloaded qualifications = %#v", reloaded.ModelQualifications)
	}
}

func TestManagedConfigActivationRequiresCurrentQualificationForEveryFallback(t *testing.T) {
	cfg := modelRouterTestConfig(t, "https://model.example.test/v1", 0)
	cfg.AIEnabled = false
	cfg.ConfigFile = filepath.Join(t.TempDir(), "managed.json")
	manager := NewConfigManager(cfg)
	update := managedRouterUpdateForConfig(manager.Current())
	enabled := true
	update.AIEnabled = &enabled
	if _, err := manager.UpdateWithResult(update); err == nil || !strings.Contains(err.Error(), "primary, fallback") {
		t.Fatalf("unqualified activation error = %v", err)
	}

	fingerprint, err := modelQualificationFingerprint(manager.Current(), "primary")
	if err != nil {
		t.Fatal(err)
	}
	if err := manager.RecordModelQualification("primary", fingerprint, QualityEvalCorpusVersion); err != nil {
		t.Fatal(err)
	}
	if _, err := manager.UpdateWithResult(update); err == nil || !strings.Contains(err.Error(), "fallback") {
		t.Fatalf("partially qualified activation error = %v", err)
	}

	fingerprint, err = modelQualificationFingerprint(manager.Current(), "fallback")
	if err != nil {
		t.Fatal(err)
	}
	if err := manager.RecordModelQualification("fallback", fingerprint, QualityEvalCorpusVersion); err != nil {
		t.Fatal(err)
	}
	result, err := manager.UpdateWithResult(update)
	if err != nil {
		t.Fatal(err)
	}
	if !result.Config.AIEnabled || !result.Config.ProductionReady() {
		t.Fatalf("qualified activation = %#v", result.Config)
	}
}

func TestManagedConfigInvalidatesQualificationsAndGuardsEnabledRouting(t *testing.T) {
	cfg := modelRouterTestConfig(t, "https://model.example.test/v1", 0)
	cfg.AIEnabled = false
	cfg = qualifyModelsForTest(t, cfg, "primary", "fallback")
	cfg.ConfigFile = filepath.Join(t.TempDir(), "managed.json")
	manager := NewConfigManager(cfg)
	update := managedRouterUpdateForConfig(cfg)
	replacement := "replacement-provider-key"
	update.Providers[0].APIKey = &replacement
	result, err := manager.UpdateWithResult(update)
	if err != nil {
		t.Fatal(err)
	}
	if len(result.Config.ModelQualifications) != 0 || result.Config.ProductionReady() {
		t.Fatalf("provider key change retained qualifications: %#v", result.Config.ModelQualifications)
	}

	legacy := modelRouterTestConfig(t, "https://model.example.test/v1", 0)
	legacy.ConfigFile = filepath.Join(t.TempDir(), "managed-v8-compatible.json")
	legacyManager := NewConfigManager(legacy)
	behaviorUpdate := managedRouterUpdateForConfig(legacy)
	behaviorUpdate.ExpressionStyle = string(ExpressionBrief)
	if _, err := legacyManager.UpdateWithResult(behaviorUpdate); err != nil {
		t.Fatalf("legacy enabled behavior update was rejected: %v", err)
	}
	routingUpdate := managedRouterUpdateForConfig(legacyManager.Current())
	routingUpdate.Models[0].RemoteName = "unqualified-replacement"
	if _, err := legacyManager.UpdateWithResult(routingUpdate); err == nil || !strings.Contains(err.Error(), "production AI requires") {
		t.Fatalf("enabled routing change error = %v", err)
	}
}

func TestManagedConfigVersionEightKeepsEnabledAIWithoutQualification(t *testing.T) {
	cfg := modelRouterTestConfig(t, "https://model.example.test/v1", 0)
	cfg.ConfigFile = filepath.Join(t.TempDir(), "managed-v8.json")
	updatedAt := time.Date(2026, time.September, 3, 8, 30, 0, 0, time.UTC)
	stored := managedConfigFile{
		Version: 8, Revision: 1, UpdatedAtMS: updatedAt.UnixMilli(), AIEnabled: true,
		Audit:     []managedConfigAuditEntry{{Revision: 1, UpdatedAtMS: updatedAt.UnixMilli(), Sections: []string{"ai_activation"}}},
		Providers: storedProviders(cfg.ModelProviders), Models: managedModelDefinitions(cfg.ModelDefinitions),
		Tasks: managedModelTasks(cfg.ModelTasks), ModelDailyLimit: cfg.ModelDailyLimit, ModelMaxTokens: cfg.ModelMaxTokens,
		SystemPrompt: cfg.SystemPrompt, GroupDefault: cfg.GroupDefault, GroupSoftDefault: string(cfg.GroupSoftDefault),
		FocusTTLSeconds: int64(cfg.FocusTTL / time.Second), SoftCooldownSeconds: int64(cfg.SoftCooldown / time.Second),
		ExpressionStyle: string(cfg.ExpressionStyle), RateLimitSeconds: int64(cfg.RateLimit / time.Second),
		ContextTTLSeconds: int64(cfg.ContextTTL / time.Second), ContextMessages: cfg.ContextMessages,
		MaxConcurrent: cfg.MaxConcurrent, ZZZAPIURL: cfg.ZZZAPIURL,
		ZZZRequestTimeoutSeconds: int64(cfg.ZZZRequestTimeout / time.Second), PluginEnabled: clonePluginSettings(cfg.PluginEnabled),
	}
	content, err := json.Marshal(stored)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(cfg.ConfigFile, content, 0o600); err != nil {
		t.Fatal(err)
	}
	loaded, err := loadManagedConfig(cfg)
	if err != nil {
		t.Fatal(err)
	}
	if !loaded.AIEnabled || !loaded.ModelEnabled() || loaded.ProductionReady() || len(loaded.ModelQualifications) != 0 {
		t.Fatalf("v8 qualification migration = enabled=%v model_enabled=%v ready=%v qualifications=%#v",
			loaded.AIEnabled, loaded.ModelEnabled(), loaded.ProductionReady(), loaded.ModelQualifications)
	}
	manager := NewConfigManager(loaded)
	update := managedRouterUpdateForConfig(loaded)
	update.Models[0].RemoteName = "unqualified-replacement"
	if _, err := manager.UpdateWithResult(update); err == nil || !strings.Contains(err.Error(), "production AI requires") {
		t.Fatalf("v8 enabled routing change error = %v", err)
	}
}

func TestQualificationRevisionDoesNotPreemptPendingLiveApply(t *testing.T) {
	cfg := modelRouterTestConfig(t, "https://model.example.test/v1", 0)
	cfg.AIEnabled = false
	syncLegacyModelProjection(&cfg)
	cfg.ConfigFile = filepath.Join(t.TempDir(), "managed.json")
	manager := NewConfigManager(cfg)
	update := managedRouterUpdateForConfig(cfg)
	update.ExpressionStyle = string(ExpressionBrief)
	result, err := manager.UpdateWithResult(update)
	if err != nil {
		t.Fatal(err)
	}
	if result.RestartRequired || result.Revision != 1 {
		t.Fatalf("live update = %#v", result)
	}
	fingerprint, err := modelQualificationFingerprint(manager.Current(), "primary")
	if err != nil {
		t.Fatal(err)
	}
	if err := manager.RecordModelQualification("primary", fingerprint, QualityEvalCorpusVersion); err != nil {
		t.Fatal(err)
	}
	beforeApply := manager.Response(true).ConfigStatus
	if beforeApply.State != "applying" || beforeApply.Revision != "2" || beforeApply.ActiveRevision != "0" {
		t.Fatalf("qualification preempted live apply: %#v", beforeApply)
	}
	if !manager.MarkApplied(result.Revision) {
		t.Fatal("live apply could not cross a qualification-only revision")
	}
	afterApply := manager.Response(true).ConfigStatus
	if afterApply.State != "active" || afterApply.ActiveRevision != "2" {
		t.Fatalf("live apply status = %#v", afterApply)
	}
}

func qualifyModelsForTest(t *testing.T, cfg Config, modelIDs ...string) Config {
	t.Helper()
	for index, modelID := range modelIDs {
		fingerprint, err := modelQualificationFingerprint(cfg, modelID)
		if err != nil {
			t.Fatal(err)
		}
		cfg.ModelQualifications = append(cfg.ModelQualifications, ModelQualification{
			ModelID: modelID, Fingerprint: fingerprint, CorpusVersion: QualityEvalCorpusVersion,
			QualifiedAt: time.Date(2026, time.September, 3, 8, 0, index, 0, time.UTC),
		})
	}
	return cfg
}

func managedRouterUpdateForConfig(cfg Config) ManagedConfigUpdate {
	update := managedUpdateForConfig(cfg)
	update.Providers = make([]ManagedModelProviderUpdate, 0, len(cfg.ModelProviders))
	for _, provider := range cfg.ModelProviders {
		update.Providers = append(update.Providers, ManagedModelProviderUpdate{
			ID: provider.ID, Protocol: provider.Protocol, BaseURL: provider.BaseURL,
			TimeoutSeconds: int64(provider.Timeout / time.Second), MaxRetries: provider.MaxRetries,
			RetryBackoffMillis: int64(provider.RetryBackoff / time.Millisecond),
		})
	}
	update.Models = managedModelDefinitions(cfg.ModelDefinitions)
	update.Tasks = managedModelTasks(cfg.ModelTasks)
	return update
}
