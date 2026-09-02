package fairy

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

const managedConfigVersion = 1

type ManagedConfigUpdate struct {
	ModelBaseURL          string          `json:"model_base_url"`
	ModelName             string          `json:"model_name"`
	ModelAPIKey           *string         `json:"model_api_key,omitempty"`
	ClearModelAPIKey      bool            `json:"clear_model_api_key,omitempty"`
	ModelDailyLimit       int             `json:"model_daily_limit"`
	ModelMaxTokens        int             `json:"model_max_tokens"`
	SystemPrompt          string          `json:"system_prompt"`
	GroupDefault          bool            `json:"group_default_enabled"`
	RateLimitSeconds      int64           `json:"rate_limit_seconds"`
	ContextTTLSeconds     int64           `json:"context_ttl_seconds"`
	ContextMessages       int             `json:"context_messages"`
	MaxConcurrent         int             `json:"max_concurrent"`
	ZZZAPIURL             string          `json:"zzz_api_url"`
	ZZZRequestTimeoutSecs int64           `json:"zzz_request_timeout_seconds"`
	PluginEnabled         map[string]bool `json:"plugin_enabled"`
}

type ManagedConfigView struct {
	ModelBaseURL          string          `json:"model_base_url"`
	ModelName             string          `json:"model_name"`
	ModelEnabled          bool            `json:"model_enabled"`
	ModelAPIKeyConfigured bool            `json:"model_api_key_configured"`
	ModelDailyLimit       int             `json:"model_daily_limit"`
	ModelMaxTokens        int             `json:"model_max_tokens"`
	SystemPrompt          string          `json:"system_prompt"`
	GroupDefault          bool            `json:"group_default_enabled"`
	RateLimitSeconds      int64           `json:"rate_limit_seconds"`
	ContextTTLSeconds     int64           `json:"context_ttl_seconds"`
	ContextMessages       int             `json:"context_messages"`
	MaxConcurrent         int             `json:"max_concurrent"`
	ZZZAPIURL             string          `json:"zzz_api_url"`
	ZZZRequestTimeoutSecs int64           `json:"zzz_request_timeout_seconds"`
	PluginEnabled         map[string]bool `json:"plugin_enabled"`
}

type ManagedConfigResponse struct {
	Connected bool              `json:"connected"`
	Config    ManagedConfigView `json:"config"`
	Plugins   []PluginStatus    `json:"plugins"`
}

type managedConfigFile struct {
	Version                  int             `json:"version"`
	ModelBaseURL             string          `json:"model_base_url"`
	ModelName                string          `json:"model_name"`
	ModelAPIKey              string          `json:"model_api_key"`
	ModelDailyLimit          int             `json:"model_daily_limit"`
	ModelMaxTokens           int             `json:"model_max_tokens"`
	SystemPrompt             string          `json:"system_prompt"`
	GroupDefault             bool            `json:"group_default_enabled"`
	RateLimitSeconds         int64           `json:"rate_limit_seconds"`
	ContextTTLSeconds        int64           `json:"context_ttl_seconds"`
	ContextMessages          int             `json:"context_messages"`
	MaxConcurrent            int             `json:"max_concurrent"`
	ZZZAPIURL                string          `json:"zzz_api_url"`
	ZZZRequestTimeoutSeconds int64           `json:"zzz_request_timeout_seconds"`
	PluginEnabled            map[string]bool `json:"plugin_enabled"`
}

type ConfigManager struct {
	mu      sync.RWMutex
	current Config
}

func NewConfigManager(cfg Config) *ConfigManager {
	return &ConfigManager{current: cloneConfig(cfg)}
}

func (m *ConfigManager) Response(connected bool) ManagedConfigResponse {
	cfg := m.Current()
	return ManagedConfigResponse{
		Connected: connected,
		Config:    managedConfigView(cfg),
		Plugins:   BuiltinPluginStatuses(cfg),
	}
}

func (m *ConfigManager) Current() Config {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return cloneConfig(m.current)
}

func (m *ConfigManager) Update(update ManagedConfigUpdate) (Config, error) {
	m.mu.Lock()
	defer m.mu.Unlock()

	next, err := applyManagedUpdate(m.current, update)
	if err != nil {
		return Config{}, err
	}
	if err := persistManagedConfig(next); err != nil {
		return Config{}, err
	}
	m.current = cloneConfig(next)
	return cloneConfig(next), nil
}

func loadManagedConfig(base Config) (Config, error) {
	content, err := os.ReadFile(base.ConfigFile)
	if errors.Is(err, os.ErrNotExist) {
		return base, nil
	}
	if err != nil {
		return Config{}, fmt.Errorf("read Fairy managed config: %w", err)
	}
	var stored managedConfigFile
	decoder := json.NewDecoder(bytes.NewReader(content))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&stored); err != nil {
		return Config{}, fmt.Errorf("decode Fairy managed config: %w", err)
	}
	if err := requireJSONEOF(decoder); err != nil {
		return Config{}, fmt.Errorf("decode Fairy managed config: %w", err)
	}
	if stored.Version != managedConfigVersion {
		return Config{}, fmt.Errorf("unsupported Fairy managed config version %d", stored.Version)
	}
	base.ModelBaseURL = stored.ModelBaseURL
	base.ModelName = stored.ModelName
	base.ModelAPIKey = stored.ModelAPIKey
	base.ModelDailyLimit = stored.ModelDailyLimit
	base.ModelMaxTokens = stored.ModelMaxTokens
	base.SystemPrompt = stored.SystemPrompt
	base.GroupDefault = stored.GroupDefault
	base.RateLimit = time.Duration(stored.RateLimitSeconds) * time.Second
	base.ContextTTL = time.Duration(stored.ContextTTLSeconds) * time.Second
	base.ContextMessages = stored.ContextMessages
	base.MaxConcurrent = stored.MaxConcurrent
	base.ZZZAPIURL = stored.ZZZAPIURL
	base.ZZZRequestTimeout = time.Duration(stored.ZZZRequestTimeoutSeconds) * time.Second
	base.PluginEnabled = clonePluginSettings(stored.PluginEnabled)
	return base, nil
}

func applyManagedUpdate(current Config, update ManagedConfigUpdate) (Config, error) {
	if update.ModelAPIKey != nil && update.ClearModelAPIKey {
		return Config{}, fmt.Errorf("choose either a replacement API key or clear_model_api_key")
	}
	if update.ModelAPIKey != nil {
		if len(*update.ModelAPIKey) > 8192 || strings.ContainsAny(*update.ModelAPIKey, "\r\n\x00") {
			return Config{}, fmt.Errorf("model API key is invalid")
		}
	}
	if update.RateLimitSeconds < 0 || update.RateLimitSeconds > 86400 ||
		update.ContextTTLSeconds < 60 || update.ContextTTLSeconds > 604800 ||
		update.ZZZRequestTimeoutSecs < 1 || update.ZZZRequestTimeoutSecs > 120 {
		return Config{}, fmt.Errorf("Fairy duration settings are outside the supported range")
	}
	for id := range update.PluginEnabled {
		if !knownPlugin(id) {
			return Config{}, fmt.Errorf("unknown Fairy plugin %q", id)
		}
	}

	next := cloneConfig(current)
	next.ModelBaseURL = strings.TrimSpace(update.ModelBaseURL)
	next.ModelName = strings.TrimSpace(update.ModelName)
	if update.ClearModelAPIKey {
		next.ModelAPIKey = ""
	} else if update.ModelAPIKey != nil {
		next.ModelAPIKey = *update.ModelAPIKey
	}
	next.ModelDailyLimit = update.ModelDailyLimit
	next.ModelMaxTokens = update.ModelMaxTokens
	next.SystemPrompt = strings.TrimSpace(update.SystemPrompt)
	next.GroupDefault = update.GroupDefault
	next.RateLimit = time.Duration(update.RateLimitSeconds) * time.Second
	next.ContextTTL = time.Duration(update.ContextTTLSeconds) * time.Second
	next.ContextMessages = update.ContextMessages
	next.MaxConcurrent = update.MaxConcurrent
	next.ZZZAPIURL = strings.TrimSpace(update.ZZZAPIURL)
	next.ZZZRequestTimeout = time.Duration(update.ZZZRequestTimeoutSecs) * time.Second
	if update.PluginEnabled != nil {
		next.PluginEnabled = clonePluginSettings(update.PluginEnabled)
	}
	if err := next.Validate(); err != nil {
		return Config{}, err
	}
	return next, nil
}

func persistManagedConfig(cfg Config) error {
	stored := managedConfigFile{
		Version:                  managedConfigVersion,
		ModelBaseURL:             cfg.ModelBaseURL,
		ModelName:                cfg.ModelName,
		ModelAPIKey:              cfg.ModelAPIKey,
		ModelDailyLimit:          cfg.ModelDailyLimit,
		ModelMaxTokens:           cfg.ModelMaxTokens,
		SystemPrompt:             cfg.SystemPrompt,
		GroupDefault:             cfg.GroupDefault,
		RateLimitSeconds:         int64(cfg.RateLimit / time.Second),
		ContextTTLSeconds:        int64(cfg.ContextTTL / time.Second),
		ContextMessages:          cfg.ContextMessages,
		MaxConcurrent:            cfg.MaxConcurrent,
		ZZZAPIURL:                cfg.ZZZAPIURL,
		ZZZRequestTimeoutSeconds: int64(cfg.ZZZRequestTimeout / time.Second),
		PluginEnabled:            clonePluginSettings(cfg.PluginEnabled),
	}
	directory := filepath.Dir(cfg.ConfigFile)
	if err := os.MkdirAll(directory, 0o700); err != nil {
		return fmt.Errorf("create Fairy config directory: %w", err)
	}
	temporary, err := os.CreateTemp(directory, ".fairy-config-*")
	if err != nil {
		return fmt.Errorf("create temporary Fairy config: %w", err)
	}
	temporaryName := temporary.Name()
	cleanup := func() {
		_ = temporary.Close()
		_ = os.Remove(temporaryName)
	}
	if err := temporary.Chmod(0o600); err != nil {
		cleanup()
		return fmt.Errorf("secure temporary Fairy config: %w", err)
	}
	encoder := json.NewEncoder(temporary)
	encoder.SetIndent("", "  ")
	if err := encoder.Encode(stored); err != nil {
		cleanup()
		return fmt.Errorf("encode Fairy managed config: %w", err)
	}
	if err := temporary.Sync(); err != nil {
		cleanup()
		return fmt.Errorf("sync Fairy managed config: %w", err)
	}
	if err := temporary.Close(); err != nil {
		_ = os.Remove(temporaryName)
		return fmt.Errorf("close Fairy managed config: %w", err)
	}
	if err := os.Rename(temporaryName, cfg.ConfigFile); err != nil {
		_ = os.Remove(temporaryName)
		return fmt.Errorf("replace Fairy managed config: %w", err)
	}
	return nil
}

func managedConfigView(cfg Config) ManagedConfigView {
	return ManagedConfigView{
		ModelBaseURL:          cfg.ModelBaseURL,
		ModelName:             cfg.ModelName,
		ModelEnabled:          cfg.ModelEnabled(),
		ModelAPIKeyConfigured: cfg.ModelAPIKey != "",
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

func cloneConfig(cfg Config) Config {
	clone := cfg
	clone.PluginEnabled = clonePluginSettings(cfg.PluginEnabled)
	return clone
}

func clonePluginSettings(settings map[string]bool) map[string]bool {
	clone := make(map[string]bool, len(settings))
	for id, enabled := range settings {
		clone[id] = enabled
	}
	return clone
}

func requireJSONEOF(decoder *json.Decoder) error {
	var extra interface{}
	if err := decoder.Decode(&extra); errors.Is(err, io.EOF) {
		return nil
	} else if err != nil {
		return err
	}
	return fmt.Errorf("request contains more than one JSON value")
}
