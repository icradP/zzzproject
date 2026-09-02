package fairy

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	managedConfigVersion         = 9
	maxManagedConfigAuditEntries = 50
)

type ManagedModelProviderUpdate struct {
	ID                 string  `json:"id"`
	Protocol           string  `json:"protocol"`
	BaseURL            string  `json:"base_url"`
	APIKey             *string `json:"api_key,omitempty"`
	ClearAPIKey        bool    `json:"clear_api_key,omitempty"`
	TimeoutSeconds     int64   `json:"timeout_seconds"`
	MaxRetries         int     `json:"max_retries"`
	RetryBackoffMillis int64   `json:"retry_backoff_millis"`
}

type ManagedModelProviderView struct {
	ID                 string `json:"id"`
	Protocol           string `json:"protocol"`
	BaseURL            string `json:"base_url"`
	APIKeyConfigured   bool   `json:"api_key_configured"`
	TimeoutSeconds     int64  `json:"timeout_seconds"`
	MaxRetries         int    `json:"max_retries"`
	RetryBackoffMillis int64  `json:"retry_backoff_millis"`
}

type ManagedModelDefinition struct {
	ID                                string `json:"id"`
	ProviderID                        string `json:"provider_id"`
	RemoteName                        string `json:"remote_name"`
	ContextWindow                     int    `json:"context_window"`
	InputPriceMicrosPerMillionTokens  int64  `json:"input_price_micros_per_million_tokens"`
	OutputPriceMicrosPerMillionTokens int64  `json:"output_price_micros_per_million_tokens"`
}

type ManagedModelTask struct {
	ID              string   `json:"id"`
	Strategy        string   `json:"strategy"`
	CandidateModels []string `json:"candidate_models"`
	MaxOutputTokens int      `json:"max_output_tokens"`
	TimeoutSeconds  int64    `json:"timeout_seconds"`
	DailyLimit      int      `json:"daily_limit"`
}

type ManagedExternalToolProvider struct {
	ID                    string   `json:"id"`
	Enabled               bool     `json:"enabled"`
	Protocol              string   `json:"protocol"`
	Command               string   `json:"command"`
	Args                  []string `json:"args"`
	WorkingDirectory      string   `json:"working_directory"`
	EnvironmentAllowlist  []string `json:"environment_allowlist"`
	AllowedTools          []string `json:"allowed_tools"`
	StartupTimeoutSeconds int64    `json:"startup_timeout_seconds"`
	CallTimeoutSeconds    int64    `json:"call_timeout_seconds"`
	FailureThreshold      int      `json:"failure_threshold"`
	ResetTimeoutSeconds   int64    `json:"reset_timeout_seconds"`
	MaxOutputBytes        int      `json:"max_output_bytes"`
}

type ManagedBehaviorExperience struct {
	ID       string   `json:"id"`
	Enabled  bool     `json:"enabled"`
	Scope    string   `json:"scope"`
	Keywords []string `json:"keywords"`
	Scene    string   `json:"scene"`
	Action   string   `json:"action"`
	Outcome  string   `json:"outcome"`
}

type ManagedConfigUpdate struct {
	// Legacy fields remain accepted so existing admin clients can migrate to v3.
	ModelBaseURL     string  `json:"model_base_url,omitempty"`
	ModelName        string  `json:"model_name,omitempty"`
	ModelAPIKey      *string `json:"model_api_key,omitempty"`
	ClearModelAPIKey bool    `json:"clear_model_api_key,omitempty"`
	AIEnabled        *bool   `json:"ai_enabled,omitempty"`

	Providers             []ManagedModelProviderUpdate  `json:"providers,omitempty"`
	Models                []ManagedModelDefinition      `json:"models,omitempty"`
	Tasks                 []ManagedModelTask            `json:"tasks,omitempty"`
	ExternalToolProviders []ManagedExternalToolProvider `json:"external_tool_providers,omitempty"`
	BehaviorExperiences   []ManagedBehaviorExperience   `json:"behavior_experiences,omitempty"`
	ModelDailyLimit       int                           `json:"model_daily_limit"`
	ModelMaxTokens        int                           `json:"model_max_tokens"`
	SystemPrompt          string                        `json:"system_prompt"`
	GroupDefault          bool                          `json:"group_default_enabled"`
	GroupSoftDefault      string                        `json:"group_soft_trigger,omitempty"`
	FocusTTLSeconds       *int64                        `json:"focus_ttl_seconds,omitempty"`
	SoftCooldownSeconds   *int64                        `json:"soft_cooldown_seconds,omitempty"`
	ExpressionStyle       string                        `json:"expression_style,omitempty"`
	RateLimitSeconds      int64                         `json:"rate_limit_seconds"`
	ContextTTLSeconds     int64                         `json:"context_ttl_seconds"`
	ContextMessages       int                           `json:"context_messages"`
	MaxConcurrent         int                           `json:"max_concurrent"`
	ZZZAPIURL             string                        `json:"zzz_api_url"`
	ZZZRequestTimeoutSecs int64                         `json:"zzz_request_timeout_seconds"`
	PluginEnabled         map[string]bool               `json:"plugin_enabled"`
}

type ManagedConfigView struct {
	// Legacy projection keeps older admin clients read-compatible.
	ModelBaseURL          string `json:"model_base_url"`
	ModelName             string `json:"model_name"`
	AIEnabled             bool   `json:"ai_enabled"`
	ModelConfigured       bool   `json:"model_configured"`
	ModelEnabled          bool   `json:"model_enabled"`
	ProductionReady       bool   `json:"production_ready"`
	QualityCorpusVersion  int    `json:"quality_corpus_version"`
	AgentEnabled          bool   `json:"agent_enabled"`
	VisionEnabled         bool   `json:"vision_enabled"`
	TranscriberEnabled    bool   `json:"transcriber_enabled"`
	ModelAPIKeyConfigured bool   `json:"model_api_key_configured"`

	Providers                []ManagedModelProviderView      `json:"providers"`
	Models                   []ManagedModelDefinition        `json:"models"`
	Tasks                    []ManagedModelTask              `json:"tasks"`
	ModelQualifications      []ManagedModelQualificationView `json:"model_qualifications"`
	UnqualifiedReplyerModels []string                        `json:"unqualified_replyer_models"`
	ExternalToolProviders    []ManagedExternalToolProvider   `json:"external_tool_providers"`
	BehaviorExperiences      []ManagedBehaviorExperience     `json:"behavior_experiences"`
	BehaviorAutoLearning     bool                            `json:"behavior_auto_learning"`
	ModelDailyLimit          int                             `json:"model_daily_limit"`
	ModelMaxTokens           int                             `json:"model_max_tokens"`
	TurnTimeoutSeconds       int64                           `json:"turn_timeout_seconds"`
	SystemPrompt             string                          `json:"system_prompt"`
	GroupDefault             bool                            `json:"group_default_enabled"`
	GroupSoftDefault         string                          `json:"group_soft_trigger"`
	FocusTTLSeconds          int64                           `json:"focus_ttl_seconds"`
	SoftCooldownSeconds      int64                           `json:"soft_cooldown_seconds"`
	ExpressionStyle          string                          `json:"expression_style"`
	RateLimitSeconds         int64                           `json:"rate_limit_seconds"`
	ContextTTLSeconds        int64                           `json:"context_ttl_seconds"`
	ContextMessages          int                             `json:"context_messages"`
	MaxConcurrent            int                             `json:"max_concurrent"`
	ZZZAPIURL                string                          `json:"zzz_api_url"`
	ZZZRequestTimeoutSecs    int64                           `json:"zzz_request_timeout_seconds"`
	PluginEnabled            map[string]bool                 `json:"plugin_enabled"`
}

type ManagedConfigResponse struct {
	Connected    bool                `json:"connected"`
	Config       ManagedConfigView   `json:"config"`
	ConfigStatus ManagedConfigStatus `json:"config_status"`
	Plugins      []PluginStatus      `json:"plugins"`
}

type ManagedConfigStatus struct {
	SchemaVersion  int                      `json:"schema_version"`
	Revision       string                   `json:"revision"`
	ActiveRevision string                   `json:"active_revision"`
	State          string                   `json:"state"`
	RestartPending bool                     `json:"restart_pending"`
	UpdatedAt      string                   `json:"updated_at,omitempty"`
	RecentChanges  []ManagedConfigAuditView `json:"recent_changes"`
}

type ManagedConfigAuditView struct {
	Revision  string   `json:"revision"`
	UpdatedAt string   `json:"updated_at"`
	Sections  []string `json:"sections"`
}

type managedConfigAuditEntry struct {
	Revision    uint64   `json:"revision"`
	UpdatedAtMS int64    `json:"updated_at_ms"`
	Sections    []string `json:"sections"`
}

type storedModelProvider struct {
	ID                 string `json:"id"`
	Protocol           string `json:"protocol"`
	BaseURL            string `json:"base_url"`
	APIKey             string `json:"api_key"`
	TimeoutSeconds     int64  `json:"timeout_seconds"`
	MaxRetries         int    `json:"max_retries"`
	RetryBackoffMillis int64  `json:"retry_backoff_millis"`
}

type storedModelQualification struct {
	ModelID       string `json:"model_id"`
	Fingerprint   string `json:"config_fingerprint"`
	CorpusVersion int    `json:"corpus_version"`
	QualifiedAtMS int64  `json:"qualified_at_ms"`
}

type managedConfigFile struct {
	Version     int                       `json:"version"`
	Revision    uint64                    `json:"revision,omitempty"`
	UpdatedAtMS int64                     `json:"updated_at_ms,omitempty"`
	Audit       []managedConfigAuditEntry `json:"audit,omitempty"`

	// Version 1 model fields.
	ModelBaseURL string `json:"model_base_url,omitempty"`
	ModelName    string `json:"model_name,omitempty"`
	ModelAPIKey  string `json:"model_api_key,omitempty"`

	Providers             []storedModelProvider         `json:"providers,omitempty"`
	Models                []ManagedModelDefinition      `json:"models,omitempty"`
	Tasks                 []ManagedModelTask            `json:"tasks,omitempty"`
	ModelQualifications   []storedModelQualification    `json:"model_qualifications,omitempty"`
	ExternalToolProviders []ManagedExternalToolProvider `json:"external_tool_providers,omitempty"`
	BehaviorExperiences   []ManagedBehaviorExperience   `json:"behavior_experiences,omitempty"`
	AIEnabled             bool                          `json:"ai_enabled"`

	ModelDailyLimit          int             `json:"model_daily_limit"`
	ModelMaxTokens           int             `json:"model_max_tokens"`
	SystemPrompt             string          `json:"system_prompt"`
	GroupDefault             bool            `json:"group_default_enabled"`
	GroupSoftDefault         string          `json:"group_soft_trigger,omitempty"`
	FocusTTLSeconds          int64           `json:"focus_ttl_seconds,omitempty"`
	SoftCooldownSeconds      int64           `json:"soft_cooldown_seconds,omitempty"`
	ExpressionStyle          string          `json:"expression_style,omitempty"`
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
	active  Config
	now     func() time.Time
}

type ConfigUpdateResult struct {
	Config          Config
	Revision        uint64
	ChangedSections []string
	BehaviorChanged bool
	RestartRequired bool
}

func NewConfigManager(cfg Config) *ConfigManager {
	_ = normalizeModelConfiguration(&cfg)
	_ = normalizeExternalToolConfiguration(&cfg)
	_ = normalizeBehaviorExperienceConfiguration(&cfg)
	current := cloneConfig(cfg)
	return &ConfigManager{current: current, active: cloneConfig(current), now: time.Now}
}

func (m *ConfigManager) Response(connected bool) ManagedConfigResponse {
	m.mu.RLock()
	defer m.mu.RUnlock()
	cfg := cloneConfig(m.current)
	return ManagedConfigResponse{
		Connected:    connected,
		Config:       managedConfigView(cfg),
		ConfigStatus: managedConfigStatus(cfg, m.active),
		Plugins:      BuiltinPluginStatuses(cfg),
	}
}

func (m *ConfigManager) Current() Config {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return cloneConfig(m.current)
}

func (m *ConfigManager) Update(update ManagedConfigUpdate) (Config, error) {
	result, err := m.UpdateWithResult(update)
	return result.Config, err
}

func (m *ConfigManager) UpdateWithResult(update ManagedConfigUpdate) (ConfigUpdateResult, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	next, err := applyManagedUpdate(m.current, update)
	if err != nil {
		return ConfigUpdateResult{}, err
	}
	if m.current.managedConfigRevision == ^uint64(0) {
		return ConfigUpdateResult{}, fmt.Errorf("Fairy managed config revision is exhausted")
	}
	changedSections := managedConfigChangedSections(m.current, next)
	updatedAt := m.now().UTC().Truncate(time.Millisecond)
	if !updatedAt.After(m.current.managedConfigUpdatedAt) {
		updatedAt = m.current.managedConfigUpdatedAt.Add(time.Millisecond)
	}
	next.managedConfigRevision = m.current.managedConfigRevision + 1
	next.managedConfigUpdatedAt = updatedAt
	next.managedConfigAudit = appendManagedConfigAudit(m.current.managedConfigAudit, managedConfigAuditEntry{
		Revision: next.managedConfigRevision, UpdatedAtMS: updatedAt.UnixMilli(), Sections: changedSections,
	})
	behaviorChanged := behaviorConfigChanged(m.active, next)
	restartRequired := restartConfigChanged(m.active, next)
	if err := persistManagedConfig(next); err != nil {
		return ConfigUpdateResult{}, err
	}
	result := ConfigUpdateResult{
		Config:          cloneConfig(next),
		Revision:        next.managedConfigRevision,
		ChangedSections: append([]string(nil), changedSections...),
		BehaviorChanged: behaviorChanged,
		RestartRequired: restartRequired,
	}
	m.current = cloneConfig(next)
	return result, nil
}

func (m *ConfigManager) RecordModelQualification(modelID, fingerprint string, corpusVersion int) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if corpusVersion != QualityEvalCorpusVersion {
		return fmt.Errorf("Fairy model qualification uses an outdated corpus")
	}
	currentFingerprint, err := modelQualificationFingerprint(m.current, modelID)
	if err != nil || currentFingerprint != fingerprint {
		return ErrModelQualificationStale
	}
	if m.current.managedConfigRevision == ^uint64(0) {
		return fmt.Errorf("Fairy managed config revision is exhausted")
	}

	next := cloneConfig(m.current)
	qualifiedAt := m.now().UTC().Truncate(time.Millisecond)
	if !qualifiedAt.After(m.current.managedConfigUpdatedAt) {
		qualifiedAt = m.current.managedConfigUpdatedAt.Add(time.Millisecond)
	}
	replacement := ModelQualification{
		ModelID: modelID, Fingerprint: fingerprint,
		CorpusVersion: corpusVersion, QualifiedAt: qualifiedAt,
	}
	found := false
	for index := range next.ModelQualifications {
		if next.ModelQualifications[index].ModelID == modelID {
			next.ModelQualifications[index] = replacement
			found = true
			break
		}
	}
	if !found {
		next.ModelQualifications = append(next.ModelQualifications, replacement)
	}
	pruneModelQualifications(&next)
	next.managedConfigRevision = m.current.managedConfigRevision + 1
	next.managedConfigUpdatedAt = qualifiedAt
	next.managedConfigAudit = appendManagedConfigAudit(m.current.managedConfigAudit, managedConfigAuditEntry{
		Revision: next.managedConfigRevision, UpdatedAtMS: qualifiedAt.UnixMilli(), Sections: []string{"model_validation"},
	})
	wasFullyApplied := m.active.managedConfigRevision == m.current.managedConfigRevision
	if err := persistManagedConfig(next); err != nil {
		return err
	}
	m.current = cloneConfig(next)
	if wasFullyApplied {
		m.active = cloneConfig(next)
	}
	return nil
}

func (m *ConfigManager) MarkApplied(revision uint64) bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	if revision > m.current.managedConfigRevision || restartConfigChanged(m.active, m.current) {
		return false
	}
	if revision != m.current.managedConfigRevision &&
		!onlyModelValidationChangesAfter(m.current.managedConfigAudit, revision, m.current.managedConfigRevision) {
		return false
	}
	m.active = cloneConfig(m.current)
	return true
}

func onlyModelValidationChangesAfter(entries []managedConfigAuditEntry, revision, current uint64) bool {
	expected := revision + 1
	for _, entry := range entries {
		if entry.Revision <= revision {
			continue
		}
		if entry.Revision != expected || len(entry.Sections) != 1 || entry.Sections[0] != "model_validation" {
			return false
		}
		expected++
	}
	return expected == current+1
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
	if stored.Version < 1 || stored.Version > managedConfigVersion {
		return Config{}, fmt.Errorf("unsupported Fairy managed config version %d", stored.Version)
	}
	base.managedConfigRevision = 0
	base.managedConfigUpdatedAt = time.Time{}
	base.managedConfigAudit = nil
	base.ModelQualifications = nil
	if stored.Version >= 7 {
		if err := validateManagedConfigMetadata(stored); err != nil {
			return Config{}, fmt.Errorf("validate Fairy managed config metadata: %w", err)
		}
		base.managedConfigRevision = stored.Revision
		base.managedConfigUpdatedAt = time.UnixMilli(stored.UpdatedAtMS).UTC()
		base.managedConfigAudit = cloneManagedConfigAudit(stored.Audit)
	} else if stored.Revision != 0 || stored.UpdatedAtMS != 0 || len(stored.Audit) != 0 {
		return Config{}, fmt.Errorf("managed config metadata requires version 7")
	}
	base.ModelDailyLimit = stored.ModelDailyLimit
	base.ModelMaxTokens = stored.ModelMaxTokens
	base.SystemPrompt = stored.SystemPrompt
	base.GroupDefault = stored.GroupDefault
	if stored.Version >= 3 {
		base.GroupSoftDefault = GroupSoftMode(stored.GroupSoftDefault)
		base.FocusTTL = time.Duration(stored.FocusTTLSeconds) * time.Second
		base.SoftCooldown = time.Duration(stored.SoftCooldownSeconds) * time.Second
		base.ExpressionStyle = ExpressionStyle(stored.ExpressionStyle)
	}
	base.RateLimit = time.Duration(stored.RateLimitSeconds) * time.Second
	base.ContextTTL = time.Duration(stored.ContextTTLSeconds) * time.Second
	base.ContextMessages = stored.ContextMessages
	base.MaxConcurrent = stored.MaxConcurrent
	base.ZZZAPIURL = stored.ZZZAPIURL
	base.ZZZRequestTimeout = time.Duration(stored.ZZZRequestTimeoutSeconds) * time.Second
	base.PluginEnabled = clonePluginSettings(stored.PluginEnabled)
	if stored.Version == 1 {
		base.ModelBaseURL = stored.ModelBaseURL
		base.ModelName = stored.ModelName
		base.ModelAPIKey = stored.ModelAPIKey
		base.ModelProviders = nil
		base.ModelDefinitions = nil
		base.ModelTasks = nil
	} else {
		base.ModelProviders = make([]ModelProviderConfig, 0, len(stored.Providers))
		for _, provider := range stored.Providers {
			base.ModelProviders = append(base.ModelProviders, ModelProviderConfig{
				ID: provider.ID, Protocol: provider.Protocol, BaseURL: provider.BaseURL, APIKey: provider.APIKey,
				Timeout:    time.Duration(provider.TimeoutSeconds) * time.Second,
				MaxRetries: provider.MaxRetries, RetryBackoff: time.Duration(provider.RetryBackoffMillis) * time.Millisecond,
			})
		}
		base.ModelDefinitions = modelDefinitionsFromManaged(stored.Models)
		base.ModelTasks = modelTasksFromManaged(stored.Tasks)
	}
	if stored.Version >= 8 {
		base.AIEnabled = stored.AIEnabled
	}
	if stored.Version >= 9 {
		base.ModelQualifications = modelQualificationsFromStored(stored.ModelQualifications)
	}
	if stored.Version >= 4 {
		base.ExternalToolProviders = externalToolProvidersFromManaged(stored.ExternalToolProviders)
	}
	if stored.Version >= 6 {
		base.BehaviorExperiences = behaviorExperiencesFromManaged(stored.BehaviorExperiences)
	}
	if err := normalizeModelConfiguration(&base); err != nil {
		return Config{}, fmt.Errorf("normalize Fairy managed model config: %w", err)
	}
	if err := normalizeExternalToolConfiguration(&base); err != nil {
		return Config{}, fmt.Errorf("normalize Fairy managed external tool config: %w", err)
	}
	if err := normalizeBehaviorExperienceConfiguration(&base); err != nil {
		return Config{}, fmt.Errorf("normalize Fairy managed behavior experience config: %w", err)
	}
	if err := validateModelQualifications(base.ModelQualifications); err != nil {
		return Config{}, fmt.Errorf("validate Fairy managed model qualifications: %w", err)
	}
	pruneModelQualifications(&base)
	if stored.Version < 8 {
		base.AIEnabled = base.modelTaskConfigured(ReplyerTaskID)
	}
	syncLegacyModelProjection(&base)
	if err := base.Validate(); err != nil {
		return Config{}, fmt.Errorf("validate Fairy managed config: %w", err)
	}
	return base, nil
}

func applyManagedUpdate(current Config, update ManagedConfigUpdate) (Config, error) {
	focusTTL := current.FocusTTL
	if update.FocusTTLSeconds != nil {
		focusTTL = time.Duration(*update.FocusTTLSeconds) * time.Second
	}
	softCooldown := current.SoftCooldown
	if update.SoftCooldownSeconds != nil {
		softCooldown = time.Duration(*update.SoftCooldownSeconds) * time.Second
	}
	if update.RateLimitSeconds < 0 || update.RateLimitSeconds > 86400 ||
		update.ContextTTLSeconds < 60 || update.ContextTTLSeconds > 604800 ||
		update.ZZZRequestTimeoutSecs < 1 || update.ZZZRequestTimeoutSecs > 120 ||
		focusTTL < 10*time.Second || focusTTL > 30*time.Minute ||
		softCooldown < 0 || softCooldown > 10*time.Minute {
		return Config{}, fmt.Errorf("Fairy duration settings are outside the supported range")
	}
	for id := range update.PluginEnabled {
		if !knownPlugin(id) {
			return Config{}, fmt.Errorf("unknown Fairy plugin %q", id)
		}
	}

	next := cloneConfig(current)
	if update.AIEnabled != nil {
		next.AIEnabled = *update.AIEnabled
	}
	structured := update.Providers != nil || update.Models != nil || update.Tasks != nil
	var err error
	if structured {
		if update.Providers == nil || update.Models == nil || update.Tasks == nil {
			return Config{}, fmt.Errorf("providers, models, and tasks must be updated together")
		}
		next.ModelProviders, err = applyProviderUpdates(current.ModelProviders, update.Providers)
		if err != nil {
			return Config{}, err
		}
		next.ModelDefinitions = modelDefinitionsFromManaged(update.Models)
		next.ModelTasks = modelTasksFromManaged(update.Tasks)
		next.ModelBaseURL = ""
		next.ModelName = ""
		next.ModelAPIKey = ""
	} else {
		if update.ModelAPIKey != nil && update.ClearModelAPIKey {
			return Config{}, fmt.Errorf("choose either a replacement API key or clear_model_api_key")
		}
		if update.ModelAPIKey != nil && !validManagedSecret(*update.ModelAPIKey) {
			return Config{}, fmt.Errorf("model API key is invalid")
		}
		projection := primaryModelProjection(current)
		next.ModelBaseURL = strings.TrimSpace(update.ModelBaseURL)
		next.ModelName = strings.TrimSpace(update.ModelName)
		next.ModelAPIKey = projection.APIKey
		if update.ClearModelAPIKey {
			next.ModelAPIKey = ""
		} else if update.ModelAPIKey != nil {
			next.ModelAPIKey = *update.ModelAPIKey
		}
		next.ModelProviders = nil
		next.ModelDefinitions = nil
		next.ModelTasks = nil
	}
	next.ModelDailyLimit = update.ModelDailyLimit
	next.ModelMaxTokens = update.ModelMaxTokens
	next.SystemPrompt = strings.TrimSpace(update.SystemPrompt)
	next.GroupDefault = update.GroupDefault
	if update.GroupSoftDefault != "" {
		next.GroupSoftDefault = GroupSoftMode(strings.ToLower(strings.TrimSpace(update.GroupSoftDefault)))
	}
	next.FocusTTL = focusTTL
	next.SoftCooldown = softCooldown
	if update.ExpressionStyle != "" {
		next.ExpressionStyle = ExpressionStyle(strings.ToLower(strings.TrimSpace(update.ExpressionStyle)))
	}
	next.RateLimit = time.Duration(update.RateLimitSeconds) * time.Second
	next.ContextTTL = time.Duration(update.ContextTTLSeconds) * time.Second
	next.ContextMessages = update.ContextMessages
	next.MaxConcurrent = update.MaxConcurrent
	next.ZZZAPIURL = strings.TrimSpace(update.ZZZAPIURL)
	next.ZZZRequestTimeout = time.Duration(update.ZZZRequestTimeoutSecs) * time.Second
	if update.PluginEnabled != nil {
		next.PluginEnabled = clonePluginSettings(update.PluginEnabled)
	}
	if update.ExternalToolProviders != nil {
		next.ExternalToolProviders = externalToolProvidersFromManaged(update.ExternalToolProviders)
	}
	if update.BehaviorExperiences != nil {
		next.BehaviorExperiences = behaviorExperiencesFromManaged(update.BehaviorExperiences)
	}
	if err := normalizeModelConfiguration(&next); err != nil {
		return Config{}, err
	}
	if err := normalizeExternalToolConfiguration(&next); err != nil {
		return Config{}, err
	}
	if err := normalizeBehaviorExperienceConfiguration(&next); err != nil {
		return Config{}, err
	}
	pruneModelQualifications(&next)
	syncLegacyModelProjection(&next)
	if err := next.Validate(); err != nil {
		return Config{}, err
	}
	if next.AIEnabled && (!current.AIEnabled || modelRoutingChanged(current, next)) && !next.ProductionReady() {
		_, missing := replyerQualificationState(next)
		return Config{}, fmt.Errorf("Fairy production AI requires current quality qualification for replyer models: %s", strings.Join(missing, ", "))
	}
	return next, nil
}

func applyProviderUpdates(current []ModelProviderConfig, updates []ManagedModelProviderUpdate) ([]ModelProviderConfig, error) {
	currentByID := make(map[string]ModelProviderConfig, len(current))
	for _, provider := range current {
		currentByID[provider.ID] = provider
	}
	providers := make([]ModelProviderConfig, 0, len(updates))
	for _, update := range updates {
		if update.APIKey != nil && update.ClearAPIKey {
			return nil, fmt.Errorf("provider %q cannot replace and clear its API key together", update.ID)
		}
		if update.APIKey != nil && !validManagedSecret(*update.APIKey) {
			return nil, fmt.Errorf("provider %q API key is invalid", update.ID)
		}
		id := strings.TrimSpace(strings.ToLower(update.ID))
		apiKey := currentByID[id].APIKey
		if update.ClearAPIKey {
			apiKey = ""
		} else if update.APIKey != nil {
			apiKey = *update.APIKey
		}
		providers = append(providers, ModelProviderConfig{
			ID: id, Protocol: update.Protocol, BaseURL: update.BaseURL, APIKey: apiKey,
			Timeout:    time.Duration(update.TimeoutSeconds) * time.Second,
			MaxRetries: update.MaxRetries, RetryBackoff: time.Duration(update.RetryBackoffMillis) * time.Millisecond,
		})
	}
	return providers, nil
}

func persistManagedConfig(cfg Config) error {
	if err := normalizeModelConfiguration(&cfg); err != nil {
		return err
	}
	if err := validateModelQualifications(cfg.ModelQualifications); err != nil {
		return err
	}
	pruneModelQualifications(&cfg)
	if err := normalizeExternalToolConfiguration(&cfg); err != nil {
		return err
	}
	stored := managedConfigFile{
		Version:                  managedConfigVersion,
		Revision:                 cfg.managedConfigRevision,
		UpdatedAtMS:              cfg.managedConfigUpdatedAt.UnixMilli(),
		Audit:                    cloneManagedConfigAudit(cfg.managedConfigAudit),
		Providers:                storedProviders(cfg.ModelProviders),
		Models:                   managedModelDefinitions(cfg.ModelDefinitions),
		Tasks:                    managedModelTasks(cfg.ModelTasks),
		ModelQualifications:      storedModelQualifications(cfg.ModelQualifications),
		ExternalToolProviders:    managedExternalToolProviders(cfg.ExternalToolProviders),
		BehaviorExperiences:      managedBehaviorExperiences(cfg.BehaviorExperiences),
		AIEnabled:                cfg.AIEnabled,
		ModelDailyLimit:          cfg.ModelDailyLimit,
		ModelMaxTokens:           cfg.ModelMaxTokens,
		SystemPrompt:             cfg.SystemPrompt,
		GroupDefault:             cfg.GroupDefault,
		GroupSoftDefault:         string(cfg.GroupSoftDefault),
		FocusTTLSeconds:          int64(cfg.FocusTTL / time.Second),
		SoftCooldownSeconds:      int64(cfg.SoftCooldown / time.Second),
		ExpressionStyle:          string(cfg.ExpressionStyle),
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
	_ = normalizeModelConfiguration(&cfg)
	_ = normalizeExternalToolConfiguration(&cfg)
	pruneModelQualifications(&cfg)
	projection := primaryModelProjection(cfg)
	_, missingQualifications := replyerQualificationState(cfg)
	return ManagedConfigView{
		ModelBaseURL: projection.BaseURL, ModelName: projection.ModelName,
		AIEnabled: cfg.AIEnabled, ModelConfigured: cfg.ModelConfigured(),
		ProductionReady: cfg.ProductionReady(), QualityCorpusVersion: QualityEvalCorpusVersion,
		ModelEnabled: cfg.ModelEnabled(), AgentEnabled: cfg.AgentEnabled(),
		VisionEnabled: cfg.TaskEnabled(VisionTaskID), TranscriberEnabled: cfg.TaskEnabled(TranscriberTaskID),
		ModelAPIKeyConfigured:    projection.APIKey != "",
		Providers:                managedProviderViews(cfg.ModelProviders),
		Models:                   managedModelDefinitions(cfg.ModelDefinitions),
		Tasks:                    managedModelTasks(cfg.ModelTasks),
		ModelQualifications:      modelQualificationViews(cfg),
		UnqualifiedReplyerModels: append([]string{}, missingQualifications...),
		ExternalToolProviders:    managedExternalToolProviders(cfg.ExternalToolProviders),
		BehaviorExperiences:      managedBehaviorExperiences(cfg.BehaviorExperiences),
		BehaviorAutoLearning:     false,
		ModelDailyLimit:          cfg.ModelDailyLimit, ModelMaxTokens: cfg.ModelMaxTokens,
		TurnTimeoutSeconds: int64(cfg.TurnTimeout / time.Second),
		SystemPrompt:       cfg.SystemPrompt, GroupDefault: cfg.GroupDefault,
		GroupSoftDefault: string(cfg.GroupSoftDefault), FocusTTLSeconds: int64(cfg.FocusTTL / time.Second),
		SoftCooldownSeconds: int64(cfg.SoftCooldown / time.Second), ExpressionStyle: string(cfg.ExpressionStyle),
		RateLimitSeconds:  int64(cfg.RateLimit / time.Second),
		ContextTTLSeconds: int64(cfg.ContextTTL / time.Second), ContextMessages: cfg.ContextMessages,
		MaxConcurrent: cfg.MaxConcurrent, ZZZAPIURL: cfg.ZZZAPIURL,
		ZZZRequestTimeoutSecs: int64(cfg.ZZZRequestTimeout / time.Second),
		PluginEnabled:         clonePluginSettings(cfg.PluginEnabled),
	}
}

func behaviorConfigChanged(current, next Config) bool {
	return behaviorConfigFromConfig(current) != behaviorConfigFromConfig(next)
}

func restartConfigChanged(current, next Config) bool {
	left := cloneConfig(current)
	right := cloneConfig(next)
	left.managedConfigRevision = 0
	left.managedConfigUpdatedAt = time.Time{}
	left.managedConfigAudit = nil
	right.managedConfigRevision = 0
	right.managedConfigUpdatedAt = time.Time{}
	right.managedConfigAudit = nil
	left.ModelQualifications = nil
	right.ModelQualifications = nil
	right.GroupSoftDefault = left.GroupSoftDefault
	right.FocusTTL = left.FocusTTL
	right.SoftCooldown = left.SoftCooldown
	right.ExpressionStyle = left.ExpressionStyle
	return !reflect.DeepEqual(left, right)
}

func modelRoutingChanged(current, next Config) bool {
	current = cloneConfig(current)
	next = cloneConfig(next)
	_ = normalizeModelConfiguration(&current)
	_ = normalizeModelConfiguration(&next)
	return !reflect.DeepEqual(current.ModelProviders, next.ModelProviders) ||
		!reflect.DeepEqual(current.ModelDefinitions, next.ModelDefinitions) ||
		!reflect.DeepEqual(current.ModelTasks, next.ModelTasks)
}

func managedConfigChangedSections(current, next Config) []string {
	current = cloneConfig(current)
	next = cloneConfig(next)
	_ = normalizeModelConfiguration(&current)
	_ = normalizeModelConfiguration(&next)
	_ = normalizeExternalToolConfiguration(&current)
	_ = normalizeExternalToolConfiguration(&next)
	_ = normalizeBehaviorExperienceConfiguration(&current)
	_ = normalizeBehaviorExperienceConfiguration(&next)
	sections := make([]string, 0, 9)
	if current.AIEnabled != next.AIEnabled {
		sections = append(sections, "ai_activation")
	}
	if current.ModelBaseURL != next.ModelBaseURL || current.ModelAPIKey != next.ModelAPIKey || current.ModelName != next.ModelName ||
		current.ModelDailyLimit != next.ModelDailyLimit || current.ModelMaxTokens != next.ModelMaxTokens ||
		!reflect.DeepEqual(current.ModelProviders, next.ModelProviders) ||
		!reflect.DeepEqual(current.ModelDefinitions, next.ModelDefinitions) || !reflect.DeepEqual(current.ModelTasks, next.ModelTasks) {
		sections = append(sections, "model")
	}
	if current.SystemPrompt != next.SystemPrompt {
		sections = append(sections, "prompt")
	}
	if current.GroupDefault != next.GroupDefault || behaviorConfigChanged(current, next) {
		sections = append(sections, "behavior")
	}
	if current.RateLimit != next.RateLimit || current.ContextTTL != next.ContextTTL ||
		current.ContextMessages != next.ContextMessages || current.MaxConcurrent != next.MaxConcurrent {
		sections = append(sections, "runtime_limits")
	}
	if current.ZZZAPIURL != next.ZZZAPIURL || current.ZZZRequestTimeout != next.ZZZRequestTimeout ||
		!reflect.DeepEqual(current.PluginEnabled, next.PluginEnabled) {
		sections = append(sections, "plugins")
	}
	if !reflect.DeepEqual(current.ExternalToolProviders, next.ExternalToolProviders) {
		sections = append(sections, "external_tools")
	}
	if !reflect.DeepEqual(current.BehaviorExperiences, next.BehaviorExperiences) {
		sections = append(sections, "behavior_experiences")
	}
	if len(sections) == 0 {
		sections = append(sections, "none")
	}
	return sections
}

func appendManagedConfigAudit(entries []managedConfigAuditEntry, entry managedConfigAuditEntry) []managedConfigAuditEntry {
	start := 0
	if len(entries) >= maxManagedConfigAuditEntries {
		start = len(entries) - maxManagedConfigAuditEntries + 1
	}
	result := make([]managedConfigAuditEntry, 0, len(entries)-start+1)
	result = append(result, cloneManagedConfigAudit(entries[start:])...)
	entry.Sections = append([]string(nil), entry.Sections...)
	return append(result, entry)
}

func cloneManagedConfigAudit(entries []managedConfigAuditEntry) []managedConfigAuditEntry {
	result := make([]managedConfigAuditEntry, len(entries))
	for index, entry := range entries {
		result[index] = entry
		result[index].Sections = append([]string(nil), entry.Sections...)
	}
	return result
}

func validateManagedConfigMetadata(stored managedConfigFile) error {
	if stored.Revision == 0 || stored.UpdatedAtMS <= 0 || len(stored.Audit) == 0 || len(stored.Audit) > maxManagedConfigAuditEntries ||
		stored.Revision < uint64(len(stored.Audit)) {
		return fmt.Errorf("invalid revision metadata")
	}
	firstRevision := stored.Revision - uint64(len(stored.Audit)) + 1
	var previousTime int64
	for index, entry := range stored.Audit {
		if entry.Revision != firstRevision+uint64(index) || entry.UpdatedAtMS <= previousTime || !validManagedConfigAuditSections(entry.Sections) {
			return fmt.Errorf("invalid audit entry")
		}
		previousTime = entry.UpdatedAtMS
	}
	last := stored.Audit[len(stored.Audit)-1]
	if last.Revision != stored.Revision || last.UpdatedAtMS != stored.UpdatedAtMS {
		return fmt.Errorf("audit does not match current revision")
	}
	return nil
}

func validManagedConfigAuditSections(sections []string) bool {
	if len(sections) == 0 || len(sections) > 9 {
		return false
	}
	seen := make(map[string]struct{}, len(sections))
	for _, section := range sections {
		switch section {
		case "ai_activation", "model_validation", "model", "prompt", "behavior", "runtime_limits", "plugins", "external_tools", "behavior_experiences", "none":
		default:
			return false
		}
		if _, exists := seen[section]; exists {
			return false
		}
		seen[section] = struct{}{}
	}
	_, noChanges := seen["none"]
	return !noChanges || len(sections) == 1
}

func managedConfigStatus(current, active Config) ManagedConfigStatus {
	restartPending := restartConfigChanged(active, current)
	state := "active"
	if restartPending {
		state = "restart_pending"
	} else if active.managedConfigRevision != current.managedConfigRevision {
		state = "applying"
	}
	changes := make([]ManagedConfigAuditView, 0, len(current.managedConfigAudit))
	for index := len(current.managedConfigAudit) - 1; index >= 0; index-- {
		entry := current.managedConfigAudit[index]
		changes = append(changes, ManagedConfigAuditView{
			Revision: strconv.FormatUint(entry.Revision, 10), UpdatedAt: time.UnixMilli(entry.UpdatedAtMS).UTC().Format(time.RFC3339Nano),
			Sections: append([]string(nil), entry.Sections...),
		})
	}
	status := ManagedConfigStatus{
		SchemaVersion: managedConfigVersion, Revision: strconv.FormatUint(current.managedConfigRevision, 10),
		ActiveRevision: strconv.FormatUint(active.managedConfigRevision, 10), State: state,
		RestartPending: restartPending, RecentChanges: changes,
	}
	if !current.managedConfigUpdatedAt.IsZero() {
		status.UpdatedAt = current.managedConfigUpdatedAt.UTC().Format(time.RFC3339Nano)
	}
	return status
}

type legacyModelProjection struct {
	BaseURL   string
	ModelName string
	APIKey    string
}

func primaryModelProjection(cfg Config) legacyModelProjection {
	_ = normalizeModelConfiguration(&cfg)
	providers := make(map[string]ModelProviderConfig, len(cfg.ModelProviders))
	models := make(map[string]ModelDefinitionConfig, len(cfg.ModelDefinitions))
	for _, provider := range cfg.ModelProviders {
		providers[provider.ID] = provider
	}
	for _, model := range cfg.ModelDefinitions {
		models[model.ID] = model
	}
	for _, task := range cfg.ModelTasks {
		if task.ID != ReplyerTaskID || len(task.CandidateModels) == 0 {
			continue
		}
		model := models[task.CandidateModels[0]]
		provider := providers[model.ProviderID]
		return legacyModelProjection{BaseURL: provider.BaseURL, ModelName: model.RemoteName, APIKey: provider.APIKey}
	}
	return legacyModelProjection{}
}

func syncLegacyModelProjection(cfg *Config) {
	projection := primaryModelProjection(*cfg)
	cfg.ModelBaseURL = projection.BaseURL
	cfg.ModelName = projection.ModelName
	cfg.ModelAPIKey = projection.APIKey
	for _, task := range cfg.ModelTasks {
		if task.ID == ReplyerTaskID {
			cfg.ModelMaxTokens = task.MaxOutputTokens
			return
		}
	}
}

func managedProviderViews(providers []ModelProviderConfig) []ManagedModelProviderView {
	views := make([]ManagedModelProviderView, 0, len(providers))
	for _, provider := range providers {
		views = append(views, ManagedModelProviderView{
			ID: provider.ID, Protocol: provider.Protocol, BaseURL: provider.BaseURL,
			APIKeyConfigured: provider.APIKey != "", TimeoutSeconds: int64(provider.Timeout / time.Second),
			MaxRetries: provider.MaxRetries, RetryBackoffMillis: int64(provider.RetryBackoff / time.Millisecond),
		})
	}
	return views
}

func storedProviders(providers []ModelProviderConfig) []storedModelProvider {
	stored := make([]storedModelProvider, 0, len(providers))
	for _, provider := range providers {
		stored = append(stored, storedModelProvider{
			ID: provider.ID, Protocol: provider.Protocol, BaseURL: provider.BaseURL, APIKey: provider.APIKey,
			TimeoutSeconds: int64(provider.Timeout / time.Second), MaxRetries: provider.MaxRetries,
			RetryBackoffMillis: int64(provider.RetryBackoff / time.Millisecond),
		})
	}
	return stored
}

func managedModelDefinitions(models []ModelDefinitionConfig) []ManagedModelDefinition {
	managed := make([]ManagedModelDefinition, 0, len(models))
	for _, model := range models {
		managed = append(managed, ManagedModelDefinition{
			ID: model.ID, ProviderID: model.ProviderID, RemoteName: model.RemoteName,
			ContextWindow:                     model.ContextWindow,
			InputPriceMicrosPerMillionTokens:  model.InputPriceMicrosPerMillionTokens,
			OutputPriceMicrosPerMillionTokens: model.OutputPriceMicrosPerMillionTokens,
		})
	}
	return managed
}

func modelDefinitionsFromManaged(models []ManagedModelDefinition) []ModelDefinitionConfig {
	result := make([]ModelDefinitionConfig, 0, len(models))
	for _, model := range models {
		result = append(result, ModelDefinitionConfig{
			ID: model.ID, ProviderID: model.ProviderID, RemoteName: model.RemoteName,
			ContextWindow:                     model.ContextWindow,
			InputPriceMicrosPerMillionTokens:  model.InputPriceMicrosPerMillionTokens,
			OutputPriceMicrosPerMillionTokens: model.OutputPriceMicrosPerMillionTokens,
		})
	}
	return result
}

func managedModelTasks(tasks []ModelTaskConfig) []ManagedModelTask {
	managed := make([]ManagedModelTask, 0, len(tasks))
	for _, task := range tasks {
		managed = append(managed, ManagedModelTask{
			ID: task.ID, Strategy: task.Strategy,
			CandidateModels: append([]string(nil), task.CandidateModels...),
			MaxOutputTokens: task.MaxOutputTokens, TimeoutSeconds: int64(task.Timeout / time.Second),
			DailyLimit: task.DailyLimit,
		})
	}
	return managed
}

func modelTasksFromManaged(tasks []ManagedModelTask) []ModelTaskConfig {
	result := make([]ModelTaskConfig, 0, len(tasks))
	for _, task := range tasks {
		result = append(result, ModelTaskConfig{
			ID: task.ID, Strategy: task.Strategy,
			CandidateModels: append([]string(nil), task.CandidateModels...),
			MaxOutputTokens: task.MaxOutputTokens, Timeout: time.Duration(task.TimeoutSeconds) * time.Second,
			DailyLimit: task.DailyLimit,
		})
	}
	return result
}

func storedModelQualifications(qualifications []ModelQualification) []storedModelQualification {
	stored := make([]storedModelQualification, 0, len(qualifications))
	for _, qualification := range qualifications {
		stored = append(stored, storedModelQualification{
			ModelID: qualification.ModelID, Fingerprint: qualification.Fingerprint,
			CorpusVersion: qualification.CorpusVersion, QualifiedAtMS: qualification.QualifiedAt.UnixMilli(),
		})
	}
	return stored
}

func modelQualificationsFromStored(qualifications []storedModelQualification) []ModelQualification {
	result := make([]ModelQualification, 0, len(qualifications))
	for _, qualification := range qualifications {
		result = append(result, ModelQualification{
			ModelID: qualification.ModelID, Fingerprint: qualification.Fingerprint,
			CorpusVersion: qualification.CorpusVersion,
			QualifiedAt:   time.UnixMilli(qualification.QualifiedAtMS).UTC(),
		})
	}
	return result
}

func managedExternalToolProviders(providers []ExternalToolProviderConfig) []ManagedExternalToolProvider {
	managed := make([]ManagedExternalToolProvider, 0, len(providers))
	for _, provider := range providers {
		managed = append(managed, ManagedExternalToolProvider{
			ID: provider.ID, Enabled: provider.Enabled, Protocol: provider.Protocol,
			Command: provider.Command, Args: append([]string(nil), provider.Args...),
			WorkingDirectory:      provider.WorkingDirectory,
			EnvironmentAllowlist:  append([]string(nil), provider.EnvironmentAllowlist...),
			AllowedTools:          append([]string(nil), provider.AllowedTools...),
			StartupTimeoutSeconds: int64(provider.StartupTimeout / time.Second),
			CallTimeoutSeconds:    int64(provider.CallTimeout / time.Second),
			FailureThreshold:      provider.FailureThreshold,
			ResetTimeoutSeconds:   int64(provider.ResetTimeout / time.Second),
			MaxOutputBytes:        provider.MaxOutputBytes,
		})
	}
	return managed
}

func externalToolProvidersFromManaged(providers []ManagedExternalToolProvider) []ExternalToolProviderConfig {
	result := make([]ExternalToolProviderConfig, 0, len(providers))
	for _, provider := range providers {
		result = append(result, ExternalToolProviderConfig{
			ID: provider.ID, Enabled: provider.Enabled, Protocol: provider.Protocol,
			Command: provider.Command, Args: append([]string(nil), provider.Args...),
			WorkingDirectory:     provider.WorkingDirectory,
			EnvironmentAllowlist: append([]string(nil), provider.EnvironmentAllowlist...),
			AllowedTools:         append([]string(nil), provider.AllowedTools...),
			StartupTimeout:       time.Duration(provider.StartupTimeoutSeconds) * time.Second,
			CallTimeout:          time.Duration(provider.CallTimeoutSeconds) * time.Second,
			FailureThreshold:     provider.FailureThreshold,
			ResetTimeout:         time.Duration(provider.ResetTimeoutSeconds) * time.Second,
			MaxOutputBytes:       provider.MaxOutputBytes,
		})
	}
	return result
}

func managedBehaviorExperiences(experiences []BehaviorExperienceConfig) []ManagedBehaviorExperience {
	managed := make([]ManagedBehaviorExperience, 0, len(experiences))
	for _, experience := range experiences {
		managed = append(managed, ManagedBehaviorExperience{
			ID: experience.ID, Enabled: experience.Enabled, Scope: experience.Scope,
			Keywords: append([]string(nil), experience.Keywords...),
			Scene:    experience.Scene, Action: experience.Action, Outcome: experience.Outcome,
		})
	}
	return managed
}

func behaviorExperiencesFromManaged(experiences []ManagedBehaviorExperience) []BehaviorExperienceConfig {
	result := make([]BehaviorExperienceConfig, 0, len(experiences))
	for _, experience := range experiences {
		result = append(result, BehaviorExperienceConfig{
			ID: experience.ID, Enabled: experience.Enabled, Scope: experience.Scope,
			Keywords: append([]string(nil), experience.Keywords...),
			Scene:    experience.Scene, Action: experience.Action, Outcome: experience.Outcome,
		})
	}
	return result
}

func cloneConfig(cfg Config) Config {
	clone := cfg
	clone.PluginEnabled = clonePluginSettings(cfg.PluginEnabled)
	clone.ModelProviders = append([]ModelProviderConfig(nil), cfg.ModelProviders...)
	clone.ModelDefinitions = append([]ModelDefinitionConfig(nil), cfg.ModelDefinitions...)
	clone.ModelTasks = append([]ModelTaskConfig(nil), cfg.ModelTasks...)
	clone.ModelQualifications = append([]ModelQualification(nil), cfg.ModelQualifications...)
	clone.ExternalToolProviders = cloneExternalToolProviders(cfg.ExternalToolProviders)
	clone.BehaviorExperiences = cloneBehaviorExperiences(cfg.BehaviorExperiences)
	clone.managedConfigAudit = cloneManagedConfigAudit(cfg.managedConfigAudit)
	for index := range clone.ModelTasks {
		clone.ModelTasks[index].CandidateModels = append([]string(nil), clone.ModelTasks[index].CandidateModels...)
	}
	return clone
}

func clonePluginSettings(settings map[string]bool) map[string]bool {
	clone := make(map[string]bool, len(settings))
	for id, enabled := range settings {
		clone[id] = enabled
	}
	return clone
}

func validManagedSecret(value string) bool {
	return len(value) <= 8192 && !strings.ContainsAny(value, "\r\n\x00")
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
