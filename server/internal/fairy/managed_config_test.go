package fairy

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

func TestManagedConfigPersistsAndKeepsAPIKeyWriteOnly(t *testing.T) {
	cfg := testConfig(t)
	cfg.ConfigFile = filepath.Join(t.TempDir(), "managed.json")
	cfg.ModelAPIKey = "existing-secret"
	manager := NewConfigManager(cfg)
	replacement := "replacement-secret"
	update := managedUpdateForConfig(cfg)
	update.ModelBaseURL = "https://model.example.test/v1"
	update.ModelName = "fairy-model"
	update.ModelAPIKey = &replacement
	update.SystemPrompt = "A managed Fairy prompt."
	update.PluginEnabled = map[string]bool{ZZZProfilePluginID: false}

	updated, err := manager.Update(update)
	if err != nil {
		t.Fatal(err)
	}
	if updated.ModelAPIKey != replacement || updated.IsPluginEnabled(ZZZProfilePluginID) {
		t.Fatalf("managed config was not applied: %#v", updated)
	}
	info, err := os.Stat(cfg.ConfigFile)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("managed config mode = %o, want 600", info.Mode().Perm())
	}
	encoded, err := json.Marshal(manager.Response(true))
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(encoded, []byte(replacement)) || !bytes.Contains(encoded, []byte(`"model_api_key_configured":true`)) {
		t.Fatalf("API key leaked or configured state missing: %s", encoded)
	}

	reloaded, err := loadManagedConfig(cfg)
	if err != nil {
		t.Fatal(err)
	}
	if reloaded.ModelName != "fairy-model" || reloaded.ModelAPIKey != replacement || reloaded.SystemPrompt != update.SystemPrompt {
		t.Fatalf("managed config did not survive reload: %#v", reloaded)
	}
}

func TestManagedConfigLoadsVersionOneIntoStructuredModelConfig(t *testing.T) {
	cfg := testConfig(t)
	cfg.ConfigFile = filepath.Join(t.TempDir(), "managed-v1.json")
	stored := managedConfigFile{
		Version: 1, ModelBaseURL: "https://legacy.example.test/v1", ModelName: "legacy-model",
		ModelAPIKey: "legacy-secret", ModelDailyLimit: cfg.ModelDailyLimit, ModelMaxTokens: 700,
		SystemPrompt: cfg.SystemPrompt, GroupDefault: cfg.GroupDefault,
		RateLimitSeconds: int64(cfg.RateLimit / time.Second), ContextTTLSeconds: int64(cfg.ContextTTL / time.Second),
		ContextMessages: cfg.ContextMessages, MaxConcurrent: cfg.MaxConcurrent, ZZZAPIURL: cfg.ZZZAPIURL,
		ZZZRequestTimeoutSeconds: int64(cfg.ZZZRequestTimeout / time.Second),
		PluginEnabled:            clonePluginSettings(cfg.PluginEnabled),
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
	if len(loaded.ModelProviders) != 1 || len(loaded.ModelDefinitions) != 1 || len(loaded.ModelTasks) != 1 {
		t.Fatalf("version 1 config was not migrated: %#v", loaded)
	}
	if loaded.ModelProviders[0].APIKey != stored.ModelAPIKey || loaded.ModelDefinitions[0].RemoteName != stored.ModelName ||
		loaded.ModelTasks[0].ID != ReplyerTaskID || loaded.ModelTasks[0].MaxOutputTokens != stored.ModelMaxTokens {
		t.Fatalf("migrated model config = %#v / %#v / %#v", loaded.ModelProviders, loaded.ModelDefinitions, loaded.ModelTasks)
	}
	if !loaded.AIEnabled || !loaded.ModelEnabled() {
		t.Fatal("version 1 model configuration did not preserve production AI behavior")
	}
	if loaded.ModelBaseURL != stored.ModelBaseURL || loaded.ModelName != stored.ModelName || loaded.ModelAPIKey != stored.ModelAPIKey {
		t.Fatalf("legacy projection changed during migration: %#v", loaded)
	}
}

func TestManagedConfigPersistsStructuredModelsAndProviderSecretOperations(t *testing.T) {
	cfg := testConfig(t)
	cfg.ConfigFile = filepath.Join(t.TempDir(), "managed-v2.json")
	manager := NewConfigManager(cfg)
	primarySecret := "primary-secret"
	fallbackSecret := "fallback-secret"
	update := managedUpdateForConfig(cfg)
	update.Providers = []ManagedModelProviderUpdate{
		{
			ID: "primary", Protocol: OpenAICompatibleProtocol, BaseURL: "https://primary.example.test/v1",
			APIKey: &primarySecret, TimeoutSeconds: 30, MaxRetries: 2, RetryBackoffMillis: 250,
		},
		{
			ID: "fallback", Protocol: OpenAICompatibleProtocol, BaseURL: "https://fallback.example.test/v1",
			APIKey: &fallbackSecret, TimeoutSeconds: 20, MaxRetries: 1, RetryBackoffMillis: 500,
		},
	}
	update.Models = []ManagedModelDefinition{
		{ID: "primary-chat", ProviderID: "primary", RemoteName: "primary-v1", ContextWindow: 128000, InputPriceMicrosPerMillionTokens: 2_000_000, OutputPriceMicrosPerMillionTokens: 8_000_000},
		{ID: "fallback-chat", ProviderID: "fallback", RemoteName: "fallback-v1", ContextWindow: 64000},
	}
	update.Tasks = []ManagedModelTask{
		{ID: ReplyerTaskID, Strategy: SequentialModelStrategy, CandidateModels: []string{"primary-chat", "fallback-chat"}, MaxOutputTokens: 800, TimeoutSeconds: 45, DailyLimit: 150},
		{ID: PlannerTaskID, Strategy: SequentialModelStrategy, CandidateModels: []string{"primary-chat"}, MaxOutputTokens: 400, TimeoutSeconds: 30, DailyLimit: 50},
	}

	updated, err := manager.Update(update)
	if err != nil {
		t.Fatal(err)
	}
	if len(updated.ModelProviders) != 2 || len(updated.ModelDefinitions) != 2 || len(updated.ModelTasks) != 2 {
		t.Fatalf("structured config not applied: %#v", updated)
	}
	if updated.ModelTasks[0].DailyLimit != 150 || updated.ModelTasks[1].DailyLimit != 50 {
		t.Fatalf("task quotas not applied: %#v", updated.ModelTasks)
	}
	responseJSON, err := json.Marshal(manager.Response(true))
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(responseJSON, []byte(primarySecret)) || bytes.Contains(responseJSON, []byte(fallbackSecret)) ||
		bytes.Contains(responseJSON, []byte(`"api_key":`)) {
		t.Fatalf("provider key leaked from managed API: %s", responseJSON)
	}
	if bytes.Count(responseJSON, []byte(`"api_key_configured":true`)) != 2 {
		t.Fatalf("provider key state missing: %s", responseJSON)
	}

	reloaded, err := loadManagedConfig(cfg)
	if err != nil {
		t.Fatal(err)
	}
	if reloaded.ModelProviders[0].APIKey != primarySecret || reloaded.ModelProviders[1].APIKey != fallbackSecret {
		t.Fatalf("provider secrets did not survive reload: %#v", reloaded.ModelProviders)
	}
	if reloaded.ModelTasks[0].DailyLimit != 150 || reloaded.ModelTasks[1].DailyLimit != 50 {
		t.Fatalf("task quotas did not survive reload: %#v", reloaded.ModelTasks)
	}

	update.Providers[0].APIKey = nil
	update.Providers[1].APIKey = nil
	if _, err := manager.Update(update); err != nil {
		t.Fatal(err)
	}
	if current := manager.Current(); current.ModelProviders[0].APIKey != primarySecret || current.ModelProviders[1].APIKey != fallbackSecret {
		t.Fatalf("omitted keys were not preserved: %#v", current.ModelProviders)
	}

	replacement := "replacement-secret"
	update.Providers[0].APIKey = &replacement
	update.Providers[1].ClearAPIKey = true
	if _, err := manager.Update(update); err != nil {
		t.Fatal(err)
	}
	current := manager.Current()
	if current.ModelProviders[0].APIKey != replacement || current.ModelProviders[1].APIKey != "" {
		t.Fatalf("provider replace/clear failed: %#v", current.ModelProviders)
	}

	update.Providers = []ManagedModelProviderUpdate{}
	update.Models = []ManagedModelDefinition{}
	update.Tasks = []ManagedModelTask{}
	update.ModelMaxTokens = 600
	cleared, err := manager.Update(update)
	if err != nil {
		t.Fatal(err)
	}
	if cleared.ModelEnabled() || len(cleared.ModelProviders) != 0 || cleared.ModelBaseURL != "" || cleared.ModelAPIKey != "" {
		t.Fatalf("structured model config was not cleared: %#v", cleared)
	}
}

func TestManagedConfigSavesDiagnosticCandidatesWithoutProductionTasks(t *testing.T) {
	cfg := testConfig(t)
	cfg.ConfigFile = filepath.Join(t.TempDir(), "managed-candidate.json")
	manager := NewConfigManager(cfg)
	secret := "candidate-only-secret"
	update := managedUpdateForConfig(cfg)
	update.Providers = []ManagedModelProviderUpdate{{
		ID: "candidate", Protocol: AnthropicCompatibleProtocol, BaseURL: "https://candidate.example.test/anthropic",
		APIKey: &secret, TimeoutSeconds: 30, MaxRetries: 1, RetryBackoffMillis: 250,
	}}
	update.Models = []ManagedModelDefinition{{
		ID: "candidate-model", ProviderID: "candidate", RemoteName: "candidate-v1", ContextWindow: 128000,
	}}
	update.Tasks = []ManagedModelTask{}

	updated, err := manager.Update(update)
	if err != nil {
		t.Fatal(err)
	}
	if updated.AIEnabled || !updated.ModelConfigured() || updated.ModelEnabled() || len(updated.ModelTasks) != 0 {
		t.Fatalf("candidate-only config = %#v", updated)
	}
	response, err := json.Marshal(manager.Response(true))
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(response, []byte(secret)) || !bytes.Contains(response, []byte(`"model_configured":true`)) ||
		!bytes.Contains(response, []byte(`"model_enabled":false`)) {
		t.Fatalf("candidate-only response = %s", response)
	}
}

func TestManagedConfigRejectsInvalidUpdateWithoutChangingCurrentConfig(t *testing.T) {
	cfg := testConfig(t)
	cfg.ConfigFile = filepath.Join(t.TempDir(), "managed.json")
	manager := NewConfigManager(cfg)
	update := managedUpdateForConfig(cfg)
	update.ModelBaseURL = "http://public.example.test/v1"
	update.ModelName = "unsafe"
	if _, err := manager.Update(update); err == nil {
		t.Fatal("insecure model URL was accepted")
	}
	if current := manager.Current(); current.ModelBaseURL != cfg.ModelBaseURL || current.ModelName != cfg.ModelName {
		t.Fatalf("failed update changed current config: %#v", current)
	}
	if _, err := os.Stat(cfg.ConfigFile); !os.IsNotExist(err) {
		t.Fatalf("failed update wrote a config file: %v", err)
	}
}

func TestManagedConfigWriteFailureKeepsCurrentConfig(t *testing.T) {
	cfg := testConfig(t)
	root := t.TempDir()
	cfg.ConfigFile = filepath.Join(root, "managed.json")
	if err := os.Mkdir(cfg.ConfigFile, 0o700); err != nil {
		t.Fatal(err)
	}
	manager := NewConfigManager(cfg)
	update := managedUpdateForConfig(cfg)
	update.ModelDailyLimit = cfg.ModelDailyLimit + 1

	if _, err := manager.Update(update); err == nil {
		t.Fatal("config update succeeded despite an unwritable target")
	}
	if current := manager.Current(); current.ModelDailyLimit != cfg.ModelDailyLimit {
		t.Fatalf("failed write changed current config: %#v", current)
	}
	info, err := os.Stat(cfg.ConfigFile)
	if err != nil {
		t.Fatal(err)
	}
	if !info.IsDir() {
		t.Fatal("failed write replaced the target")
	}
	temporaryFiles, err := filepath.Glob(filepath.Join(root, ".fairy-config-*"))
	if err != nil {
		t.Fatal(err)
	}
	if len(temporaryFiles) != 0 {
		t.Fatalf("failed write left temporary files: %v", temporaryFiles)
	}
}

func TestFairyAdminAPIAuthenticationUpdateAndRestart(t *testing.T) {
	cfg := testConfig(t)
	cfg.ConfigFile = filepath.Join(t.TempDir(), "managed.json")
	cfg.ModelAPIKey = "never-return-this-key"
	manager := NewConfigManager(cfg)
	restarted := make(chan struct{}, 1)
	handler := NewAdminAPI(manager, "local-admin-token", func() bool { return true }, func() {
		restarted <- struct{}{}
	})

	unauthorized := httptest.NewRecorder()
	handler.ServeHTTP(unauthorized, httptest.NewRequest(http.MethodGet, "/admin/config", nil))
	if unauthorized.Code != http.StatusUnauthorized {
		t.Fatalf("unauthorized status = %d", unauthorized.Code)
	}

	authorizedRequest := httptest.NewRequest(http.MethodGet, "/admin/config", nil)
	authorizedRequest.Header.Set("Authorization", "Bearer local-admin-token")
	authorized := httptest.NewRecorder()
	handler.ServeHTTP(authorized, authorizedRequest)
	if authorized.Code != http.StatusOK || strings.Contains(authorized.Body.String(), cfg.ModelAPIKey) ||
		!strings.Contains(authorized.Body.String(), `"config_status":{"schema_version":9,"revision":"0","active_revision":"0","state":"active","restart_pending":false,"recent_changes":[]}`) {
		t.Fatalf("GET status=%d body=%s", authorized.Code, authorized.Body.String())
	}

	update := managedUpdateForConfig(cfg)
	update.ModelDailyLimit = 321
	body, _ := json.Marshal(update)
	patchRequest := httptest.NewRequest(http.MethodPatch, "/admin/config", bytes.NewReader(body))
	patchRequest.Header.Set("Authorization", "Bearer local-admin-token")
	patched := httptest.NewRecorder()
	handler.ServeHTTP(patched, patchRequest)
	if patched.Code != http.StatusOK || !strings.Contains(patched.Body.String(), `"restart_scheduled":true`) ||
		!strings.Contains(patched.Body.String(), `"revision":"1","active_revision":"0","state":"restart_pending","restart_pending":true`) {
		t.Fatalf("PATCH status=%d body=%s", patched.Code, patched.Body.String())
	}
	select {
	case <-restarted:
	case <-time.After(time.Second):
		t.Fatal("successful update did not schedule restart")
	}
	if manager.Current().ModelDailyLimit != 321 {
		t.Fatal("admin update was not applied")
	}
}

type fakeAdminRuntime struct {
	applied []Config
	status  RuntimeStatus
}

func (r *fakeAdminRuntime) ApplyBehaviorConfig(cfg Config) {
	r.applied = append(r.applied, cfg)
}

func (r *fakeAdminRuntime) Snapshot(context.Context) RuntimeStatus {
	return r.status
}

func TestFairyAdminAPIAppliesBehaviorOnlyUpdateWithoutRestart(t *testing.T) {
	cfg := testConfig(t)
	cfg.ConfigFile = filepath.Join(t.TempDir(), "managed.json")
	manager := NewConfigManager(cfg)
	restarted := make(chan struct{}, 1)
	runtime := &fakeAdminRuntime{status: RuntimeStatus{TraceAvailable: true}}
	handler := NewAdminAPIWithRuntime(manager, "local-admin-token", func() bool { return true }, func() {
		restarted <- struct{}{}
	}, runtime)

	update := managedUpdateForConfig(cfg)
	update.ExpressionStyle = string(ExpressionBrief)
	body, _ := json.Marshal(update)
	request := httptest.NewRequest(http.MethodPatch, "/admin/config", bytes.NewReader(body))
	request.Header.Set("Authorization", "Bearer local-admin-token")
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if response.Code != http.StatusOK || !strings.Contains(response.Body.String(), `"applied_live":true`) ||
		!strings.Contains(response.Body.String(), `"restart_scheduled":false`) || !strings.Contains(response.Body.String(), `"runtime"`) ||
		!strings.Contains(response.Body.String(), `"revision":"1","active_revision":"1","state":"active","restart_pending":false`) {
		t.Fatalf("PATCH status=%d body=%s", response.Code, response.Body.String())
	}
	if len(runtime.applied) != 1 || runtime.applied[0].ExpressionStyle != ExpressionBrief {
		t.Fatalf("runtime updates = %#v", runtime.applied)
	}
	select {
	case <-restarted:
		t.Fatal("behavior-only update scheduled a restart")
	case <-time.After(50 * time.Millisecond):
	}
}

func TestManagedConfigVersionTwoKeepsEnvironmentBehaviorDefaults(t *testing.T) {
	cfg := testConfig(t)
	cfg.GroupSoftDefault = GroupSoftOn
	cfg.ExpressionStyle = ExpressionDetailed
	cfg.ConfigFile = filepath.Join(t.TempDir(), "managed-v2.json")
	stored := managedConfigFile{
		Version: 2, ModelDailyLimit: cfg.ModelDailyLimit, ModelMaxTokens: cfg.ModelMaxTokens,
		SystemPrompt: cfg.SystemPrompt, GroupDefault: cfg.GroupDefault,
		RateLimitSeconds: int64(cfg.RateLimit / time.Second), ContextTTLSeconds: int64(cfg.ContextTTL / time.Second),
		ContextMessages: cfg.ContextMessages, MaxConcurrent: cfg.MaxConcurrent, ZZZAPIURL: cfg.ZZZAPIURL,
		ZZZRequestTimeoutSeconds: int64(cfg.ZZZRequestTimeout / time.Second),
		PluginEnabled:            clonePluginSettings(cfg.PluginEnabled),
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
	if loaded.GroupSoftDefault != GroupSoftOn || loaded.FocusTTL != cfg.FocusTTL ||
		loaded.SoftCooldown != cfg.SoftCooldown || loaded.ExpressionStyle != ExpressionDetailed {
		t.Fatalf("version 2 changed behavior defaults: %#v", loaded)
	}
}

func TestManagedConfigVersionFourPersistsExternalProvidersWithoutEnvironmentValues(t *testing.T) {
	cfg := testConfig(t)
	cfg.ConfigFile = filepath.Join(t.TempDir(), "managed-v4.json")
	manager := NewConfigManager(cfg)
	secret := "must-never-enter-managed-config"
	t.Setenv("FAIRY_MCP_TEST_SECRET", secret)
	update := managedUpdateForConfig(cfg)
	update.ExternalToolProviders = []ManagedExternalToolProvider{{
		ID: "knowledge", Enabled: true, Protocol: MCPStdioProtocol,
		Command: "/usr/bin/true", Args: []string{"--stdio"}, WorkingDirectory: "/tmp",
		EnvironmentAllowlist: []string{"FAIRY_MCP_TEST_SECRET"}, AllowedTools: []string{"lookup"},
		StartupTimeoutSeconds: 10, CallTimeoutSeconds: 15, FailureThreshold: 3,
		ResetTimeoutSeconds: 30, MaxOutputBytes: 65536,
	}}
	updated, err := manager.Update(update)
	if err != nil {
		t.Fatal(err)
	}
	if len(updated.ExternalToolProviders) != 1 || updated.ExternalToolProviders[0].AllowedTools[0] != "lookup" {
		t.Fatalf("external provider update = %#v", updated.ExternalToolProviders)
	}
	response, err := json.Marshal(manager.Response(true))
	if err != nil {
		t.Fatal(err)
	}
	stored, err := os.ReadFile(cfg.ConfigFile)
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(response, []byte(secret)) || bytes.Contains(stored, []byte(secret)) ||
		!bytes.Contains(response, []byte("FAIRY_MCP_TEST_SECRET")) || !bytes.Contains(stored, []byte(`"version": 9`)) {
		t.Fatalf("external provider leaked a value or was not persisted: response=%s stored=%s", response, stored)
	}
	reloaded, err := loadManagedConfig(cfg)
	if err != nil {
		t.Fatal(err)
	}
	if len(reloaded.ExternalToolProviders) != 1 || reloaded.ExternalToolProviders[0].Command != "/usr/bin/true" ||
		reloaded.ExternalToolProviders[0].CallTimeout != 15*time.Second {
		t.Fatalf("reloaded external providers = %#v", reloaded.ExternalToolProviders)
	}
}

func TestManagedConfigVersionFourTasksInheritGlobalQuota(t *testing.T) {
	cfg := modelRouterTestConfig(t, "https://model.example.test/v1", 0)
	cfg.ModelDailyLimit = 37
	cfg.ConfigFile = filepath.Join(t.TempDir(), "managed-v4.json")
	stored := managedConfigFile{
		Version: 4, Providers: storedProviders(cfg.ModelProviders),
		Models: managedModelDefinitions(cfg.ModelDefinitions), Tasks: managedModelTasks(cfg.ModelTasks),
		ModelDailyLimit: cfg.ModelDailyLimit, ModelMaxTokens: cfg.ModelMaxTokens,
		SystemPrompt: cfg.SystemPrompt, GroupDefault: cfg.GroupDefault,
		GroupSoftDefault: string(cfg.GroupSoftDefault), FocusTTLSeconds: int64(cfg.FocusTTL / time.Second),
		SoftCooldownSeconds: int64(cfg.SoftCooldown / time.Second), ExpressionStyle: string(cfg.ExpressionStyle),
		RateLimitSeconds: int64(cfg.RateLimit / time.Second), ContextTTLSeconds: int64(cfg.ContextTTL / time.Second),
		ContextMessages: cfg.ContextMessages, MaxConcurrent: cfg.MaxConcurrent, ZZZAPIURL: cfg.ZZZAPIURL,
		ZZZRequestTimeoutSeconds: int64(cfg.ZZZRequestTimeout / time.Second),
		PluginEnabled:            clonePluginSettings(cfg.PluginEnabled),
	}
	for index := range stored.Tasks {
		stored.Tasks[index].DailyLimit = 0
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
	if len(loaded.ModelTasks) != 1 || loaded.ModelTasks[0].DailyLimit != cfg.ModelDailyLimit {
		t.Fatalf("version 4 task quota migration = %#v", loaded.ModelTasks)
	}
}

func TestManagedConfigVersionThreeRemainsReadable(t *testing.T) {
	cfg := testConfig(t)
	cfg.ConfigFile = filepath.Join(t.TempDir(), "managed-v3.json")
	stored := managedConfigFile{
		Version: 3, ModelDailyLimit: cfg.ModelDailyLimit, ModelMaxTokens: cfg.ModelMaxTokens,
		SystemPrompt: cfg.SystemPrompt, GroupDefault: cfg.GroupDefault,
		GroupSoftDefault: string(cfg.GroupSoftDefault), FocusTTLSeconds: int64(cfg.FocusTTL / time.Second),
		SoftCooldownSeconds: int64(cfg.SoftCooldown / time.Second), ExpressionStyle: string(cfg.ExpressionStyle),
		RateLimitSeconds: int64(cfg.RateLimit / time.Second), ContextTTLSeconds: int64(cfg.ContextTTL / time.Second),
		ContextMessages: cfg.ContextMessages, MaxConcurrent: cfg.MaxConcurrent, ZZZAPIURL: cfg.ZZZAPIURL,
		ZZZRequestTimeoutSeconds: int64(cfg.ZZZRequestTimeout / time.Second),
		PluginEnabled:            clonePluginSettings(cfg.PluginEnabled),
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
	if loaded.GroupSoftDefault != cfg.GroupSoftDefault || len(loaded.ExternalToolProviders) != 0 {
		t.Fatalf("version 3 config changed during load: %#v", loaded)
	}
}

func TestManagedConfigRejectsUnsafeExternalProvider(t *testing.T) {
	cfg := testConfig(t)
	cfg.ConfigFile = filepath.Join(t.TempDir(), "managed.json")
	manager := NewConfigManager(cfg)
	update := managedUpdateForConfig(cfg)
	update.ExternalToolProviders = []ManagedExternalToolProvider{{
		ID: "unsafe", Enabled: true, Protocol: MCPStdioProtocol, Command: "sh",
		AllowedTools: []string{"lookup"}, StartupTimeoutSeconds: 10, CallTimeoutSeconds: 15,
		FailureThreshold: 3, ResetTimeoutSeconds: 30, MaxOutputBytes: 65536,
	}}
	if _, err := manager.Update(update); err == nil {
		t.Fatal("relative external provider command was accepted")
	}
	if len(manager.Current().ExternalToolProviders) != 0 {
		t.Fatal("rejected external provider changed current config")
	}
}

func TestManagedBehaviorExperiencesPersistMigrateAndRequireRestart(t *testing.T) {
	cfg := testConfig(t)
	cfg.ConfigFile = filepath.Join(t.TempDir(), "managed-v6.json")
	manager := NewConfigManager(cfg)
	update := managedUpdateForConfig(cfg)
	update.BehaviorExperiences = []ManagedBehaviorExperience{{
		ID: "support-refund", Enabled: true, Scope: BehaviorExperienceScopePrivate,
		Keywords: []string{"退款", "账单"}, Scene: "用户询问退款", Action: "先确认订单状态", Outcome: "减少重复沟通",
	}}

	result, err := manager.UpdateWithResult(update)
	if err != nil {
		t.Fatal(err)
	}
	if result.BehaviorChanged || !result.RestartRequired || len(result.Config.BehaviorExperiences) != 1 {
		t.Fatalf("behavior experience update result = %#v", result)
	}
	result.Config.BehaviorExperiences[0].Keywords[0] = "mutated"
	if current := manager.Current(); current.BehaviorExperiences[0].Keywords[0] != "退款" {
		t.Fatal("managed config shared behavior experience keyword storage")
	}

	stored, err := os.ReadFile(cfg.ConfigFile)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Contains(stored, []byte(`"version": 9`)) || !bytes.Contains(stored, []byte(`"behavior_experiences"`)) {
		t.Fatalf("behavior experiences were not persisted in v9: %s", stored)
	}
	reloaded, err := loadManagedConfig(cfg)
	if err != nil {
		t.Fatal(err)
	}
	if len(reloaded.BehaviorExperiences) != 1 || reloaded.BehaviorExperiences[0].Action != "先确认订单状态" {
		t.Fatalf("reloaded behavior experiences = %#v", reloaded.BehaviorExperiences)
	}

	var legacy managedConfigFile
	if err := json.Unmarshal(stored, &legacy); err != nil {
		t.Fatal(err)
	}
	legacy.Version = 6
	legacy.Revision = 0
	legacy.UpdatedAtMS = 0
	legacy.Audit = nil
	legacyContent, err := json.Marshal(legacy)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(cfg.ConfigFile, legacyContent, 0o600); err != nil {
		t.Fatal(err)
	}
	migrated, err := loadManagedConfig(cfg)
	if err != nil {
		t.Fatal(err)
	}
	if len(migrated.BehaviorExperiences) != 1 || migrated.managedConfigRevision != 0 || len(migrated.managedConfigAudit) != 0 {
		t.Fatalf("v6 config did not migrate without revision metadata: %#v", migrated)
	}

	legacy.Version = 5
	legacyContent, err = json.Marshal(legacy)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(cfg.ConfigFile, legacyContent, 0o600); err != nil {
		t.Fatal(err)
	}
	migrated, err = loadManagedConfig(cfg)
	if err != nil {
		t.Fatal(err)
	}
	if len(migrated.BehaviorExperiences) != 0 {
		t.Fatalf("v5 config unexpectedly loaded v6 behavior experiences: %#v", migrated.BehaviorExperiences)
	}
}

func TestManagedConfigTracksRevisionAuditAndApplyState(t *testing.T) {
	cfg := testConfig(t)
	cfg.ConfigFile = filepath.Join(t.TempDir(), "managed-v7.json")
	manager := NewConfigManager(cfg)
	fixedNow := time.Date(2026, time.September, 3, 4, 5, 6, 0, time.UTC)
	manager.now = func() time.Time { return fixedNow }

	initial := manager.Response(true).ConfigStatus
	if initial.SchemaVersion != managedConfigVersion || initial.Revision != "0" || initial.ActiveRevision != "0" ||
		initial.State != "active" || initial.RestartPending || initial.UpdatedAt != "" || initial.RecentChanges == nil || len(initial.RecentChanges) != 0 {
		t.Fatalf("initial config status = %#v", initial)
	}

	behaviorUpdate := managedUpdateForConfig(cfg)
	behaviorUpdate.ExpressionStyle = string(ExpressionBrief)
	behaviorResult, err := manager.UpdateWithResult(behaviorUpdate)
	if err != nil {
		t.Fatal(err)
	}
	if behaviorResult.Revision != 1 || !behaviorResult.BehaviorChanged || behaviorResult.RestartRequired ||
		!reflect.DeepEqual(behaviorResult.ChangedSections, []string{"behavior"}) {
		t.Fatalf("behavior update result = %#v", behaviorResult)
	}
	applying := manager.Response(true).ConfigStatus
	if applying.State != "applying" || applying.Revision != "1" || applying.ActiveRevision != "0" || applying.RestartPending {
		t.Fatalf("applying config status = %#v", applying)
	}
	if !manager.MarkApplied(behaviorResult.Revision) {
		t.Fatal("behavior-only revision was not marked active")
	}
	active := manager.Response(true).ConfigStatus
	if active.State != "active" || active.Revision != "1" || active.ActiveRevision != "1" ||
		active.UpdatedAt != fixedNow.Format(time.RFC3339Nano) || len(active.RecentChanges) != 1 ||
		!reflect.DeepEqual(active.RecentChanges[0].Sections, []string{"behavior"}) {
		t.Fatalf("active config status = %#v", active)
	}

	restartUpdate := managedUpdateForConfig(behaviorResult.Config)
	restartUpdate.ModelDailyLimit++
	restartResult, err := manager.UpdateWithResult(restartUpdate)
	if err != nil {
		t.Fatal(err)
	}
	if restartResult.Revision != 2 || restartResult.BehaviorChanged || !restartResult.RestartRequired ||
		!reflect.DeepEqual(restartResult.ChangedSections, []string{"model"}) {
		t.Fatalf("restart update result = %#v", restartResult)
	}
	pending := manager.Response(true).ConfigStatus
	if pending.State != "restart_pending" || pending.Revision != "2" || pending.ActiveRevision != "1" ||
		!pending.RestartPending || len(pending.RecentChanges) != 2 || pending.RecentChanges[0].Revision != "2" ||
		pending.RecentChanges[0].UpdatedAt != fixedNow.Add(time.Millisecond).Format(time.RFC3339Nano) {
		t.Fatalf("pending config status = %#v", pending)
	}
	if manager.MarkApplied(restartResult.Revision) {
		t.Fatal("restart-required revision was marked active before restart")
	}

	reloaded, err := loadManagedConfig(cfg)
	if err != nil {
		t.Fatal(err)
	}
	reloadedStatus := NewConfigManager(reloaded).Response(true).ConfigStatus
	if reloadedStatus.State != "active" || reloadedStatus.Revision != "2" || reloadedStatus.ActiveRevision != "2" ||
		len(reloadedStatus.RecentChanges) != 2 {
		t.Fatalf("reloaded config status = %#v", reloadedStatus)
	}
}

func TestManagedConfigAIActivationIsExplicitAuditedAndRestarted(t *testing.T) {
	cfg := modelRouterTestConfig(t, "https://model.example.test/v1", 0)
	cfg.AIEnabled = false
	syncLegacyModelProjection(&cfg)
	cfg.ConfigFile = filepath.Join(t.TempDir(), "managed-v9.json")
	qualifiedAt := time.Date(2026, time.September, 3, 7, 0, 0, 0, time.UTC)
	for _, modelID := range []string{"primary", "fallback"} {
		fingerprint, err := modelQualificationFingerprint(cfg, modelID)
		if err != nil {
			t.Fatal(err)
		}
		cfg.ModelQualifications = append(cfg.ModelQualifications, ModelQualification{
			ModelID: modelID, Fingerprint: fingerprint,
			CorpusVersion: QualityEvalCorpusVersion, QualifiedAt: qualifiedAt,
		})
	}
	manager := NewConfigManager(cfg)
	update := managedUpdateForConfig(cfg)
	update.Providers = []ManagedModelProviderUpdate{{
		ID: "provider", Protocol: OpenAICompatibleProtocol, BaseURL: "https://model.example.test/v1",
		TimeoutSeconds: 5, MaxRetries: 0, RetryBackoffMillis: 50,
	}}
	update.Models = managedModelDefinitions(cfg.ModelDefinitions)
	update.Tasks = managedModelTasks(cfg.ModelTasks)
	enabled := true
	update.AIEnabled = &enabled

	result, err := manager.UpdateWithResult(update)
	if err != nil {
		t.Fatal(err)
	}
	if !result.Config.AIEnabled || !result.Config.ModelEnabled() || !result.RestartRequired || result.BehaviorChanged ||
		!reflect.DeepEqual(result.ChangedSections, []string{"ai_activation"}) {
		t.Fatalf("AI activation result = %#v", result)
	}
	response, err := json.Marshal(manager.Response(true))
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Contains(response, []byte(`"ai_enabled":true`)) || !bytes.Contains(response, []byte(`"model_enabled":true`)) ||
		bytes.Contains(response, []byte("router-secret")) {
		t.Fatalf("AI activation response = %s", response)
	}
	stored, err := os.ReadFile(cfg.ConfigFile)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Contains(stored, []byte(`"version": 9`)) || !bytes.Contains(stored, []byte(`"ai_enabled": true`)) {
		t.Fatalf("AI activation was not persisted as v9: %s", stored)
	}
}

func TestManagedConfigVersionSevenPreservesConfiguredAIActivation(t *testing.T) {
	cfg := modelRouterTestConfig(t, "https://model.example.test/v1", 0)
	cfg.ConfigFile = filepath.Join(t.TempDir(), "managed-v7.json")
	updatedAt := time.Date(2026, time.September, 3, 8, 0, 0, 0, time.UTC)
	stored := managedConfigFile{
		Version: 7, Revision: 1, UpdatedAtMS: updatedAt.UnixMilli(),
		Audit:     []managedConfigAuditEntry{{Revision: 1, UpdatedAtMS: updatedAt.UnixMilli(), Sections: []string{"model"}}},
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
	if !loaded.AIEnabled || !loaded.ModelEnabled() || loaded.managedConfigRevision != 1 {
		t.Fatalf("version 7 activation migration = %#v", loaded)
	}
}

func TestManagedConfigAuditIsBoundedAndRejectsTampering(t *testing.T) {
	cfg := testConfig(t)
	cfg.ConfigFile = filepath.Join(t.TempDir(), "managed-v7.json")
	manager := NewConfigManager(cfg)
	manager.now = func() time.Time { return time.Date(2026, time.September, 3, 5, 0, 0, 0, time.UTC) }
	current := cfg
	for revision := 1; revision <= maxManagedConfigAuditEntries+5; revision++ {
		update := managedUpdateForConfig(current)
		update.ModelDailyLimit = cfg.ModelDailyLimit + revision
		result, err := manager.UpdateWithResult(update)
		if err != nil {
			t.Fatalf("update revision %d: %v", revision, err)
		}
		current = result.Config
	}
	status := manager.Response(true).ConfigStatus
	if status.Revision != "55" || len(status.RecentChanges) != maxManagedConfigAuditEntries ||
		status.RecentChanges[0].Revision != "55" || status.RecentChanges[maxManagedConfigAuditEntries-1].Revision != "6" {
		t.Fatalf("bounded config audit = %#v", status)
	}

	content, err := os.ReadFile(cfg.ConfigFile)
	if err != nil {
		t.Fatal(err)
	}
	var stored managedConfigFile
	if err := json.Unmarshal(content, &stored); err != nil {
		t.Fatal(err)
	}
	stored.Audit[len(stored.Audit)-1].Sections = []string{"private prompt contents"}
	tampered, err := json.Marshal(stored)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(cfg.ConfigFile, tampered, 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := loadManagedConfig(cfg); err == nil || !strings.Contains(err.Error(), "managed config metadata") {
		t.Fatalf("tampered v7 audit was not rejected: %v", err)
	}
}

func TestManagedConfigChangedSectionsUseFixedCategories(t *testing.T) {
	base := testConfig(t)
	_ = normalizeModelConfiguration(&base)
	_ = normalizeExternalToolConfiguration(&base)
	_ = normalizeBehaviorExperienceConfiguration(&base)
	tests := []struct {
		name   string
		change func(*Config)
		want   string
	}{
		{name: "none", change: func(*Config) {}, want: "none"},
		{name: "AI activation", change: func(cfg *Config) { cfg.AIEnabled = !cfg.AIEnabled }, want: "ai_activation"},
		{name: "model", change: func(cfg *Config) { cfg.ModelDailyLimit++ }, want: "model"},
		{name: "prompt", change: func(cfg *Config) { cfg.SystemPrompt = "private prompt text" }, want: "prompt"},
		{name: "behavior", change: func(cfg *Config) { cfg.GroupSoftDefault = GroupSoftOn }, want: "behavior"},
		{name: "runtime limits", change: func(cfg *Config) { cfg.ContextMessages++ }, want: "runtime_limits"},
		{name: "plugins", change: func(cfg *Config) { cfg.ZZZAPIURL = "https://private.example.test/value" }, want: "plugins"},
		{name: "external tools", change: func(cfg *Config) {
			cfg.ExternalToolProviders = []ExternalToolProviderConfig{{ID: "private-provider"}}
		}, want: "external_tools"},
		{name: "behavior experiences", change: func(cfg *Config) {
			cfg.BehaviorExperiences = []BehaviorExperienceConfig{{ID: "private-experience"}}
		}, want: "behavior_experiences"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			next := cloneConfig(base)
			test.change(&next)
			sections := managedConfigChangedSections(base, next)
			if !reflect.DeepEqual(sections, []string{test.want}) {
				t.Fatalf("changed sections = %#v, want %q", sections, test.want)
			}
			encoded, err := json.Marshal(sections)
			if err != nil {
				t.Fatal(err)
			}
			for _, forbidden := range []string{"private prompt text", "private.example.test", "private-provider", "private-experience"} {
				if bytes.Contains(encoded, []byte(forbidden)) {
					t.Fatalf("changed sections exposed config value %q: %s", forbidden, encoded)
				}
			}
		})
	}
}

func TestManagedConfigRejectsStaleApplyAcknowledgment(t *testing.T) {
	cfg := testConfig(t)
	cfg.ConfigFile = filepath.Join(t.TempDir(), "managed-v7.json")
	manager := NewConfigManager(cfg)
	behaviorUpdate := managedUpdateForConfig(cfg)
	behaviorUpdate.ExpressionStyle = string(ExpressionBrief)
	behaviorResult, err := manager.UpdateWithResult(behaviorUpdate)
	if err != nil {
		t.Fatal(err)
	}
	pendingUpdate := managedUpdateForConfig(behaviorResult.Config)
	pendingUpdate.ModelDailyLimit++
	pendingResult, err := manager.UpdateWithResult(pendingUpdate)
	if err != nil {
		t.Fatal(err)
	}
	if manager.MarkApplied(behaviorResult.Revision) {
		t.Fatal("stale revision acknowledgment changed active config")
	}
	status := manager.Response(true).ConfigStatus
	if pendingResult.Revision != 2 || status.State != "restart_pending" || status.Revision != "2" || status.ActiveRevision != "0" {
		t.Fatalf("status after stale acknowledgment = %#v", status)
	}
}

func TestFairyAdminAPIBehaviorExperienceUpdateSchedulesRestart(t *testing.T) {
	cfg := testConfig(t)
	cfg.ConfigFile = filepath.Join(t.TempDir(), "managed.json")
	manager := NewConfigManager(cfg)
	restarted := make(chan struct{}, 1)
	runtime := &fakeAdminRuntime{}
	handler := NewAdminAPIWithRuntime(manager, "local-admin-token", func() bool { return true }, func() {
		restarted <- struct{}{}
	}, runtime)
	update := managedUpdateForConfig(cfg)
	update.BehaviorExperiences = []ManagedBehaviorExperience{{
		ID: "group-welcome", Enabled: true, Scope: BehaviorExperienceScopeGroup,
		Keywords: []string{"新人"}, Scene: "群内有新成员", Action: "简短欢迎", Outcome: "保持群聊节奏",
	}}
	body, _ := json.Marshal(update)
	request := httptest.NewRequest(http.MethodPatch, "/admin/config", bytes.NewReader(body))
	request.Header.Set("Authorization", "Bearer local-admin-token")
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if response.Code != http.StatusOK || !strings.Contains(response.Body.String(), `"restart_scheduled":true`) ||
		strings.Contains(response.Body.String(), `"applied_live":true`) {
		t.Fatalf("PATCH status=%d body=%s", response.Code, response.Body.String())
	}
	select {
	case <-restarted:
	case <-time.After(time.Second):
		t.Fatal("behavior experience update did not schedule restart")
	}
	if len(runtime.applied) != 0 {
		t.Fatalf("restart-only behavior experiences were applied live: %#v", runtime.applied)
	}
}

func managedUpdateForConfig(cfg Config) ManagedConfigUpdate {
	focusTTLSeconds := int64(cfg.FocusTTL / time.Second)
	softCooldownSeconds := int64(cfg.SoftCooldown / time.Second)
	aiEnabled := cfg.AIEnabled
	return ManagedConfigUpdate{
		AIEnabled:             &aiEnabled,
		ModelBaseURL:          cfg.ModelBaseURL,
		ModelName:             cfg.ModelName,
		ModelDailyLimit:       cfg.ModelDailyLimit,
		ModelMaxTokens:        cfg.ModelMaxTokens,
		SystemPrompt:          cfg.SystemPrompt,
		GroupDefault:          cfg.GroupDefault,
		GroupSoftDefault:      string(cfg.GroupSoftDefault),
		FocusTTLSeconds:       &focusTTLSeconds,
		SoftCooldownSeconds:   &softCooldownSeconds,
		ExpressionStyle:       string(cfg.ExpressionStyle),
		RateLimitSeconds:      int64(cfg.RateLimit / time.Second),
		ContextTTLSeconds:     int64(cfg.ContextTTL / time.Second),
		ContextMessages:       cfg.ContextMessages,
		MaxConcurrent:         cfg.MaxConcurrent,
		ZZZAPIURL:             cfg.ZZZAPIURL,
		ZZZRequestTimeoutSecs: int64(cfg.ZZZRequestTimeout / time.Second),
		PluginEnabled:         clonePluginSettings(cfg.PluginEnabled),
	}
}
