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

// Config contains only Fairy process settings. The IM server remains unaware
// of model credentials and plugin upstreams.
type Config struct {
	ServerURL         string
	UserID            string
	Password          string
	InviteCode        string
	Nickname          string
	AvatarURL         string
	Bio               string
	DeviceID          string
	StateFile         string
	HealthAddr        string
	GroupDefault      bool
	RateLimit         time.Duration
	ContextTTL        time.Duration
	ContextMessages   int
	MaxConcurrent     int
	ModelBaseURL      string
	ModelAPIKey       string
	ModelName         string
	ModelDailyLimit   int
	ModelMaxTokens    int
	SystemPrompt      string
	ZZZAPIURL         string
	ZZZRequestTimeout time.Duration
	ReconnectMin      time.Duration
	ReconnectMax      time.Duration
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
		HealthAddr:   envOrDefault("FAIRY_HEALTH_ADDR", "127.0.0.1:18081"),
		ModelBaseURL: strings.TrimSpace(os.Getenv("FAIRY_MODEL_BASE_URL")),
		ModelAPIKey:  os.Getenv("FAIRY_MODEL_API_KEY"),
		ModelName:    strings.TrimSpace(os.Getenv("FAIRY_MODEL_NAME")),
		SystemPrompt: envOrDefault("FAIRY_SYSTEM_PROMPT", defaultSystemPrompt),
		ZZZAPIURL:    envOrDefault("FAIRY_ZZZ_API_URL", defaultZZZAPIURL),
		ReconnectMin: 2 * time.Second,
		ReconnectMax: 30 * time.Second,
	}
	var err error
	if cfg.GroupDefault, err = envBool("FAIRY_GROUP_DEFAULT_ENABLED", true); err != nil {
		return Config{}, err
	}
	if cfg.RateLimit, err = envDuration("FAIRY_RATE_LIMIT", 8*time.Second); err != nil {
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
	if cfg.ModelDailyLimit, err = envInt("FAIRY_MODEL_DAILY_LIMIT", 200); err != nil {
		return Config{}, err
	}
	if cfg.ModelMaxTokens, err = envInt("FAIRY_MODEL_MAX_TOKENS", 600); err != nil {
		return Config{}, err
	}
	if err := cfg.Validate(); err != nil {
		return Config{}, err
	}
	return cfg, nil
}

func (c Config) Validate() error {
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
	if c.StateFile == "" {
		return fmt.Errorf("FAIRY_STATE_FILE is required")
	}
	if c.HealthAddr != "" {
		if _, _, err := net.SplitHostPort(c.HealthAddr); err != nil {
			return fmt.Errorf("FAIRY_HEALTH_ADDR must use host:port syntax: %w", err)
		}
	}
	if c.RateLimit < 0 || c.ContextTTL < time.Minute || c.ContextMessages < 2 || c.ContextMessages > 50 {
		return fmt.Errorf("Fairy rate/context limits are invalid")
	}
	if c.MaxConcurrent < 1 || c.MaxConcurrent > 32 {
		return fmt.Errorf("FAIRY_MAX_CONCURRENT must be between 1 and 32")
	}
	if c.ReconnectMin <= 0 || c.ReconnectMax < c.ReconnectMin {
		return fmt.Errorf("Fairy reconnect limits are invalid")
	}
	if c.ModelDailyLimit < 0 || c.ModelMaxTokens < 64 || c.ModelMaxTokens > 4096 {
		return fmt.Errorf("Fairy model limits are invalid")
	}
	if (c.ModelBaseURL == "") != (c.ModelName == "") {
		return fmt.Errorf("FAIRY_MODEL_BASE_URL and FAIRY_MODEL_NAME must be configured together")
	}
	if c.ModelBaseURL != "" {
		modelURL, err := url.Parse(c.ModelBaseURL)
		if err != nil || modelURL.Scheme != "https" || modelURL.Host == "" {
			return fmt.Errorf("FAIRY_MODEL_BASE_URL must be an absolute HTTPS URL")
		}
	}
	if err := validateTemplateURL(c.ZZZAPIURL); err != nil {
		return err
	}
	return nil
}

func (c Config) ModelEnabled() bool {
	return c.ModelBaseURL != "" && c.ModelName != ""
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
