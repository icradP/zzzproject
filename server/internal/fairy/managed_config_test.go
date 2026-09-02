package fairy

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
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
	if authorized.Code != http.StatusOK || strings.Contains(authorized.Body.String(), cfg.ModelAPIKey) {
		t.Fatalf("GET status=%d body=%s", authorized.Code, authorized.Body.String())
	}

	update := managedUpdateForConfig(cfg)
	update.ModelDailyLimit = 321
	body, _ := json.Marshal(update)
	patchRequest := httptest.NewRequest(http.MethodPatch, "/admin/config", bytes.NewReader(body))
	patchRequest.Header.Set("Authorization", "Bearer local-admin-token")
	patched := httptest.NewRecorder()
	handler.ServeHTTP(patched, patchRequest)
	if patched.Code != http.StatusOK || !strings.Contains(patched.Body.String(), `"restart_scheduled":true`) {
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

func managedUpdateForConfig(cfg Config) ManagedConfigUpdate {
	return ManagedConfigUpdate{
		ModelBaseURL:          cfg.ModelBaseURL,
		ModelName:             cfg.ModelName,
		ModelDailyLimit:       cfg.ModelDailyLimit,
		ModelMaxTokens:        cfg.ModelMaxTokens,
		SystemPrompt:          cfg.SystemPrompt,
		GroupDefault:          cfg.GroupDefault,
		RateLimitSeconds:      int64(cfg.RateLimit / time.Second),
		ContextTTLSeconds:     int64(cfg.ContextTTL / time.Second),
		ContextMessages:       cfg.ContextMessages,
		MaxConcurrent:         cfg.MaxConcurrent,
		ZZZAPIURL:             cfg.ZZZAPIURL,
		ZZZRequestTimeoutSecs: int64(cfg.ZZZRequestTimeout / time.Second),
		PluginEnabled:         clonePluginSettings(cfg.PluginEnabled),
	}
}
