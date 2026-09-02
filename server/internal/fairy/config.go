package fairy

import (
	"fmt"
	"net"
	"net/url"
	"os"
	"strconv"
	"strings"
	"time"
)

const (
	defaultSystemPrompt = "你是 Fairy，ZZZ IM 中友善、简洁的智能助手。使用与用户相同的语言回答；不编造查询结果；不索取密码、令牌或 Cookie；不泄露其他会话内容。"
	defaultZZZAPIURL    = "https://enka.network/api/zzz/uid/{uid}"
)

type GroupSoftMode string

const (
	GroupSoftOff    GroupSoftMode = "off"
	GroupSoftShadow GroupSoftMode = "shadow"
	GroupSoftOn     GroupSoftMode = "on"
)

type ExpressionStyle string

const (
	ExpressionBrief    ExpressionStyle = "brief"
	ExpressionNormal   ExpressionStyle = "normal"
	ExpressionDetailed ExpressionStyle = "detailed"
)

type AIRolloutMode string

const (
	AIRolloutOff       AIRolloutMode = "off"
	AIRolloutAllowlist AIRolloutMode = "allowlist"
	AIRolloutAll       AIRolloutMode = "all"
	maxAIAllowedUsers                = 128
)

// Config contains only Fairy process settings. The IM server remains unaware
// of model credentials and plugin upstreams.
type Config struct {
	ServerURL              string
	UserID                 string
	Password               string
	InviteCode             string
	Nickname               string
	AvatarURL              string
	Bio                    string
	DeviceID               string
	StateFile              string
	ConfigFile             string
	TraceDB                string
	TraceKeyFile           string
	FactDB                 string
	HealthAddr             string
	AdminToken             string
	GroupDefault           bool
	GroupSoftDefault       GroupSoftMode
	FocusTTL               time.Duration
	SoftCooldown           time.Duration
	ExpressionStyle        ExpressionStyle
	RateLimit              time.Duration
	ContextTTL             time.Duration
	ContextMessages        int
	MaxConcurrent          int
	MaxPending             int
	MaxConversationPending int
	TurnTimeout            time.Duration
	DrainTimeout           time.Duration
	AIEnabled              bool
	AIRolloutMode          AIRolloutMode
	AIAllowedUsers         []string
	ModelBaseURL           string
	ModelProtocol          string
	ModelAPIKey            string
	ModelName              string
	ModelDailyLimit        int
	ModelMaxTokens         int
	SystemPrompt           string
	ModelProviders         []ModelProviderConfig
	ModelDefinitions       []ModelDefinitionConfig
	ModelTasks             []ModelTaskConfig
	ModelQualifications    []ModelQualification
	ExternalToolProviders  []ExternalToolProviderConfig
	BehaviorExperiences    []BehaviorExperienceConfig
	ZZZAPIURL              string
	ZZZRequestTimeout      time.Duration
	PluginEnabled          map[string]bool
	ReconnectMin           time.Duration
	ReconnectMax           time.Duration
	managedConfigRevision  uint64
	managedConfigUpdatedAt time.Time
	managedConfigAudit     []managedConfigAuditEntry
}

// ConfigFromEnv loads and validates Fairy configuration from environment
// variables. Secrets never need to be passed through command-line flags.
func ConfigFromEnv() (Config, error) {
	cfg := Config{
		ServerURL:    envOrDefault("FAIRY_SERVER_URL", "ws://127.0.0.1:18080/ws"),
		UserID:       envOrDefault("FAIRY_USER_ID", "fairy"),
		Password:     os.Getenv("FAIRY_PASSWORD"),
		InviteCode:   os.Getenv("FAIRY_INVITE_CODE"),
		Nickname:     envOrDefault("FAIRY_NICKNAME", "Fairy"),
		AvatarURL:    envOrDefault("FAIRY_AVATAR_URL", "https://icrad.ltd/assets/assets/characters/temp/Fairy.png"),
		Bio:          envOrDefault("FAIRY_BIO", "ZZZ IM 智能助手。私聊直接提问，群聊请先 @Fairy。"),
		DeviceID:     envOrDefault("FAIRY_DEVICE_ID", "fairy-service"),
		StateFile:    envOrDefault("FAIRY_STATE_FILE", "/var/lib/zzz-fairy/state.json"),
		ConfigFile:   envOrDefault("FAIRY_CONFIG_FILE", "/var/lib/zzz-fairy/config.json"),
		TraceDB:      envOrDefault("FAIRY_TRACE_DB", "/var/lib/zzz-fairy/fairy.db"),
		TraceKeyFile: envOrDefault("FAIRY_TRACE_KEY_FILE", "/var/lib/zzz-fairy/trace.key"),
		FactDB:       envOrDefault("FAIRY_FACT_DB", "/var/lib/zzz-fairy/facts.db"),
		HealthAddr:   envOrDefault("FAIRY_HEALTH_ADDR", "127.0.0.1:18081"),
		AdminToken:   strings.TrimSpace(os.Getenv("FAIRY_ADMIN_TOKEN")),
		GroupSoftDefault: GroupSoftMode(strings.ToLower(envOrDefault(
			"FAIRY_GROUP_SOFT_TRIGGER", string(GroupSoftShadow),
		))),
		ExpressionStyle: ExpressionStyle(strings.ToLower(envOrDefault(
			"FAIRY_EXPRESSION_STYLE", string(ExpressionNormal),
		))),
		ModelBaseURL: strings.TrimSpace(os.Getenv("FAIRY_MODEL_BASE_URL")),
		ModelProtocol: strings.ToLower(strings.TrimSpace(envOrDefault(
			"FAIRY_MODEL_PROTOCOL", OpenAICompatibleProtocol,
		))),
		ModelAPIKey: os.Getenv("FAIRY_MODEL_API_KEY"),
		ModelName:   strings.TrimSpace(os.Getenv("FAIRY_MODEL_NAME")),
		AIRolloutMode: AIRolloutMode(strings.ToLower(strings.TrimSpace(
			os.Getenv("FAIRY_AI_ROLLOUT_MODE"),
		))),
		AIAllowedUsers: envAccountIDs("FAIRY_AI_ALLOWED_USERS"),
		SystemPrompt:   envOrDefault("FAIRY_SYSTEM_PROMPT", defaultSystemPrompt),
		ZZZAPIURL:      envOrDefault("FAIRY_ZZZ_API_URL", defaultZZZAPIURL),
		PluginEnabled: map[string]bool{
			ZZZProfilePluginID: true,
		},
		ReconnectMin: 2 * time.Second,
		ReconnectMax: 30 * time.Second,
	}
	var err error
	if cfg.AIEnabled, err = envBool("FAIRY_AI_ENABLED", false); err != nil {
		return Config{}, err
	}
	if cfg.GroupDefault, err = envBool("FAIRY_GROUP_DEFAULT_ENABLED", true); err != nil {
		return Config{}, err
	}
	if cfg.RateLimit, err = envDuration("FAIRY_RATE_LIMIT", 8*time.Second); err != nil {
		return Config{}, err
	}
	if cfg.FocusTTL, err = envDuration("FAIRY_FOCUS_TTL", 2*time.Minute); err != nil {
		return Config{}, err
	}
	if cfg.SoftCooldown, err = envDuration("FAIRY_SOFT_COOLDOWN", 30*time.Second); err != nil {
		return Config{}, err
	}
	if cfg.ContextTTL, err = envDuration("FAIRY_CONTEXT_TTL", 30*time.Minute); err != nil {
		return Config{}, err
	}
	if cfg.ZZZRequestTimeout, err = envDuration("FAIRY_ZZZ_TIMEOUT", 15*time.Second); err != nil {
		return Config{}, err
	}
	if cfg.ContextMessages, err = envInt("FAIRY_CONTEXT_MESSAGES", 12); err != nil {
		return Config{}, err
	}
	if cfg.MaxConcurrent, err = envInt("FAIRY_MAX_CONCURRENT", 4); err != nil {
		return Config{}, err
	}
	if cfg.MaxPending, err = envInt("FAIRY_MAX_PENDING", 256); err != nil {
		return Config{}, err
	}
	if cfg.MaxConversationPending, err = envInt("FAIRY_MAX_CONVERSATION_PENDING", 16); err != nil {
		return Config{}, err
	}
	if cfg.TurnTimeout, err = envDuration("FAIRY_TURN_TIMEOUT", 60*time.Second); err != nil {
		return Config{}, err
	}
	if cfg.DrainTimeout, err = envDuration("FAIRY_DRAIN_TIMEOUT", 10*time.Second); err != nil {
		return Config{}, err
	}
	if cfg.ModelDailyLimit, err = envInt("FAIRY_MODEL_DAILY_LIMIT", 200); err != nil {
		return Config{}, err
	}
	if cfg.ModelMaxTokens, err = envInt("FAIRY_MODEL_MAX_TOKENS", 600); err != nil {
		return Config{}, err
	}
	if cfg.PluginEnabled[ZZZProfilePluginID], err = envBool("FAIRY_ZZZ_PLUGIN_ENABLED", true); err != nil {
		return Config{}, err
	}
	cfg, err = loadManagedConfig(cfg)
	if err != nil {
		return Config{}, err
	}
	if err := normalizeAIRolloutConfiguration(&cfg); err != nil {
		return Config{}, err
	}
	if err := normalizeModelConfiguration(&cfg); err != nil {
		return Config{}, err
	}
	if err := normalizeExternalToolConfiguration(&cfg); err != nil {
		return Config{}, err
	}
	if err := normalizeBehaviorExperienceConfiguration(&cfg); err != nil {
		return Config{}, err
	}
	if err := cfg.Validate(); err != nil {
		return Config{}, err
	}
	return cfg, nil
}

func (c Config) Validate() error {
	if err := normalizeAIRolloutConfiguration(&c); err != nil {
		return err
	}
	if err := normalizeModelConfiguration(&c); err != nil {
		return err
	}
	if err := normalizeExternalToolConfiguration(&c); err != nil {
		return err
	}
	if err := normalizeBehaviorExperienceConfiguration(&c); err != nil {
		return err
	}
	serverURL, err := url.Parse(c.ServerURL)
	if err != nil || (serverURL.Scheme != "ws" && serverURL.Scheme != "wss") || serverURL.Host == "" {
		return fmt.Errorf("FAIRY_SERVER_URL must be an absolute ws:// or wss:// URL")
	}
	if !validAccountID(c.UserID) {
		return fmt.Errorf("FAIRY_USER_ID must contain 3-32 letters, digits, dots, dashes, or underscores")
	}
	if len(c.Password) < 8 || len(c.Password) > 72 {
		return fmt.Errorf("FAIRY_PASSWORD must contain 8-72 characters")
	}
	if strings.TrimSpace(c.Nickname) == "" || len([]rune(c.Nickname)) > 64 {
		return fmt.Errorf("FAIRY_NICKNAME must contain 1-64 characters")
	}
	if c.StateFile == "" || c.ConfigFile == "" || c.TraceDB == "" || c.TraceKeyFile == "" || c.FactDB == "" {
		return fmt.Errorf("Fairy state, config, trace, fact-memory, and trace key paths are required")
	}
	if c.HealthAddr != "" {
		if _, _, err := net.SplitHostPort(c.HealthAddr); err != nil {
			return fmt.Errorf("FAIRY_HEALTH_ADDR must use host:port syntax: %w", err)
		}
	}
	if c.RateLimit < 0 || c.ContextTTL < time.Minute || c.ContextMessages < 2 || c.ContextMessages > 50 {
		return fmt.Errorf("Fairy rate/context limits are invalid")
	}
	if !validGroupSoftMode(c.GroupSoftDefault) {
		return fmt.Errorf("FAIRY_GROUP_SOFT_TRIGGER must be off, shadow, or on")
	}
	if c.FocusTTL < 10*time.Second || c.FocusTTL > 30*time.Minute {
		return fmt.Errorf("FAIRY_FOCUS_TTL must be between 10s and 30m")
	}
	if c.SoftCooldown < 0 || c.SoftCooldown > 10*time.Minute {
		return fmt.Errorf("FAIRY_SOFT_COOLDOWN must be between 0 and 10m")
	}
	if !validExpressionStyle(c.ExpressionStyle) {
		return fmt.Errorf("FAIRY_EXPRESSION_STYLE must be brief, normal, or detailed")
	}
	if c.MaxConcurrent < 1 || c.MaxConcurrent > 32 {
		return fmt.Errorf("FAIRY_MAX_CONCURRENT must be between 1 and 32")
	}
	if c.MaxPending < c.MaxConcurrent || c.MaxPending > 10000 {
		return fmt.Errorf("FAIRY_MAX_PENDING must be between FAIRY_MAX_CONCURRENT and 10000")
	}
	if c.MaxConversationPending < 1 || c.MaxConversationPending > c.MaxPending {
		return fmt.Errorf("FAIRY_MAX_CONVERSATION_PENDING must be between 1 and FAIRY_MAX_PENDING")
	}
	if c.TurnTimeout < time.Second || c.TurnTimeout > 10*time.Minute {
		return fmt.Errorf("FAIRY_TURN_TIMEOUT must be between 1s and 10m")
	}
	if c.DrainTimeout < time.Second || c.DrainTimeout > 5*time.Minute {
		return fmt.Errorf("FAIRY_DRAIN_TIMEOUT must be between 1s and 5m")
	}
	if c.ReconnectMin <= 0 || c.ReconnectMax < c.ReconnectMin {
		return fmt.Errorf("Fairy reconnect limits are invalid")
	}
	if c.ModelDailyLimit < 0 || c.ModelMaxTokens < 64 || c.ModelMaxTokens > 4096 {
		return fmt.Errorf("Fairy model limits are invalid")
	}
	if strings.TrimSpace(c.SystemPrompt) == "" || len([]rune(c.SystemPrompt)) > 8000 {
		return fmt.Errorf("FAIRY_SYSTEM_PROMPT must contain 1-8000 characters")
	}
	if err := validateModelConfiguration(c); err != nil {
		return err
	}
	if err := validateModelQualifications(c.ModelQualifications); err != nil {
		return err
	}
	if err := validateTemplateURL(c.ZZZAPIURL); err != nil {
		return err
	}
	for id := range c.PluginEnabled {
		if !knownPlugin(id) {
			return fmt.Errorf("unknown Fairy plugin %q", id)
		}
	}
	return nil
}

func (c Config) ModelEnabled() bool {
	if c.EffectiveAIRolloutMode() == AIRolloutOff {
		return false
	}
	return c.modelTaskConfigured(ReplyerTaskID)
}

func (c Config) ModelConfigured() bool {
	if normalizeModelConfiguration(&c) != nil {
		return false
	}
	return len(c.ModelProviders) > 0 && len(c.ModelDefinitions) > 0
}

func (c Config) modelTaskConfigured(taskID string) bool {
	if normalizeModelConfiguration(&c) != nil {
		return false
	}
	for _, task := range c.ModelTasks {
		if task.ID == taskID && len(task.CandidateModels) > 0 {
			return true
		}
	}
	return false
}

func (c Config) AgentEnabled() bool {
	if !c.ModelEnabled() {
		return false
	}
	for _, task := range c.ModelTasks {
		if task.ID == PlannerTaskID && len(task.CandidateModels) > 0 {
			return true
		}
	}
	return false
}

func (c Config) TaskEnabled(taskID string) bool {
	if c.EffectiveAIRolloutMode() == AIRolloutOff || !c.modelTaskConfigured(ReplyerTaskID) {
		return false
	}
	return c.modelTaskConfigured(taskID)
}

func (c Config) EffectiveAIRolloutMode() AIRolloutMode {
	mode := AIRolloutMode(strings.ToLower(strings.TrimSpace(string(c.AIRolloutMode))))
	if mode != "" {
		return mode
	}
	if c.AIEnabled {
		return AIRolloutAll
	}
	return AIRolloutOff
}

func (c Config) AIUserAllowed(userID string) bool {
	switch c.EffectiveAIRolloutMode() {
	case AIRolloutAll:
		return true
	case AIRolloutAllowlist:
		for _, allowed := range c.AIAllowedUsers {
			if allowed == userID {
				return true
			}
		}
	}
	return false
}

func normalizeAIRolloutConfiguration(cfg *Config) error {
	mode := cfg.EffectiveAIRolloutMode()
	if !validAIRolloutMode(mode) {
		return fmt.Errorf("FAIRY_AI_ROLLOUT_MODE must be off, allowlist, or all")
	}
	if len(cfg.AIAllowedUsers) > maxAIAllowedUsers {
		return fmt.Errorf("Fairy AI allowlist supports at most %d accounts", maxAIAllowedUsers)
	}
	allowed := make([]string, 0, len(cfg.AIAllowedUsers))
	seen := make(map[string]struct{}, len(cfg.AIAllowedUsers))
	for _, raw := range cfg.AIAllowedUsers {
		userID := strings.TrimSpace(raw)
		if userID == "" {
			continue
		}
		if !validAccountID(userID) {
			return fmt.Errorf("invalid Fairy AI allowlist account %q", userID)
		}
		if _, exists := seen[userID]; exists {
			continue
		}
		seen[userID] = struct{}{}
		allowed = append(allowed, userID)
	}
	if mode == AIRolloutAllowlist && len(allowed) == 0 {
		return fmt.Errorf("Fairy AI allowlist mode requires at least one account")
	}
	cfg.AIRolloutMode = mode
	cfg.AIAllowedUsers = allowed
	cfg.AIEnabled = mode != AIRolloutOff
	return nil
}

func (c Config) IsPluginEnabled(id string) bool {
	if enabled, ok := c.PluginEnabled[id]; ok {
		return enabled
	}
	if descriptor, ok := pluginDescriptorByID(id); ok {
		return descriptor.DefaultEnabled
	}
	return true
}

func validGroupSoftMode(value GroupSoftMode) bool {
	switch value {
	case GroupSoftOff, GroupSoftShadow, GroupSoftOn:
		return true
	default:
		return false
	}
}

func validExpressionStyle(value ExpressionStyle) bool {
	switch value {
	case ExpressionBrief, ExpressionNormal, ExpressionDetailed:
		return true
	default:
		return false
	}
}

func validAIRolloutMode(value AIRolloutMode) bool {
	switch value {
	case AIRolloutOff, AIRolloutAllowlist, AIRolloutAll:
		return true
	default:
		return false
	}
}

func validateTemplateURL(value string) error {
	if strings.Count(value, "{uid}") != 1 {
		return fmt.Errorf("FAIRY_ZZZ_API_URL must contain exactly one {uid} placeholder")
	}
	parsed, err := url.Parse(strings.Replace(value, "{uid}", "100000001", 1))
	if err != nil || parsed.Host == "" {
		return fmt.Errorf("FAIRY_ZZZ_API_URL is invalid")
	}
	if parsed.Scheme == "https" {
		return nil
	}
	host := parsed.Hostname()
	if parsed.Scheme == "http" && (host == "localhost" || net.ParseIP(host) != nil && net.ParseIP(host).IsLoopback()) {
		return nil
	}
	return fmt.Errorf("FAIRY_ZZZ_API_URL must use HTTPS (HTTP is allowed only for loopback tests)")
}

func validAccountID(value string) bool {
	if len(value) < 3 || len(value) > 32 {
		return false
	}
	for _, character := range value {
		if character >= 'a' && character <= 'z' ||
			character >= 'A' && character <= 'Z' ||
			character >= '0' && character <= '9' ||
			character == '-' || character == '_' || character == '.' {
			continue
		}
		return false
	}
	return true
}

func envOrDefault(key, fallback string) string {
	if value := strings.TrimSpace(os.Getenv(key)); value != "" {
		return value
	}
	return fallback
}

func envBool(key string, fallback bool) (bool, error) {
	value := strings.TrimSpace(os.Getenv(key))
	if value == "" {
		return fallback, nil
	}
	parsed, err := strconv.ParseBool(value)
	if err != nil {
		return false, fmt.Errorf("%s must be true or false", key)
	}
	return parsed, nil
}

func envDuration(key string, fallback time.Duration) (time.Duration, error) {
	value := strings.TrimSpace(os.Getenv(key))
	if value == "" {
		return fallback, nil
	}
	parsed, err := time.ParseDuration(value)
	if err != nil {
		return 0, fmt.Errorf("%s must be a Go duration: %w", key, err)
	}
	return parsed, nil
}

func envInt(key string, fallback int) (int, error) {
	value := strings.TrimSpace(os.Getenv(key))
	if value == "" {
		return fallback, nil
	}
	parsed, err := strconv.Atoi(value)
	if err != nil {
		return 0, fmt.Errorf("%s must be an integer", key)
	}
	return parsed, nil
}

func envAccountIDs(key string) []string {
	return strings.FieldsFunc(os.Getenv(key), func(character rune) bool {
		return character == ',' || character == '\n' || character == '\r'
	})
}
