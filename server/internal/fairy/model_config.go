package fairy

import (
	"fmt"
	"net"
	"net/url"
	"strings"
	"time"
)

const (
	OpenAICompatibleProtocol    = "openai-compatible"
	AnthropicCompatibleProtocol = "anthropic-compatible"
	SequentialModelStrategy     = "sequential"
	ReplyerTaskID               = "replyer"
	PlannerTaskID               = "planner"
	UtilityTaskID               = "utility"
	VisionTaskID                = "vision"
	TranscriberTaskID           = "transcriber"

	defaultProviderID       = "default"
	defaultModelID          = "default"
	defaultProviderTimeout  = 45 * time.Second
	defaultRetryBackoff     = 250 * time.Millisecond
	defaultModelContext     = 128000
	defaultModelTaskTimeout = 45 * time.Second
)

type ModelProviderConfig struct {
	ID           string
	Protocol     string
	BaseURL      string
	APIKey       string
	Timeout      time.Duration
	MaxRetries   int
	RetryBackoff time.Duration
}

type ModelDefinitionConfig struct {
	ID                                string
	ProviderID                        string
	RemoteName                        string
	ContextWindow                     int
	InputPriceMicrosPerMillionTokens  int64
	OutputPriceMicrosPerMillionTokens int64
}

type ModelTaskConfig struct {
	ID              string
	Strategy        string
	CandidateModels []string
	MaxOutputTokens int
	Timeout         time.Duration
	DailyLimit      int
}

func normalizeModelConfiguration(cfg *Config) error {
	structured := len(cfg.ModelProviders) > 0 || len(cfg.ModelDefinitions) > 0 || len(cfg.ModelTasks) > 0
	if !structured {
		baseURL := strings.TrimSpace(cfg.ModelBaseURL)
		remoteName := strings.TrimSpace(cfg.ModelName)
		if baseURL == "" && remoteName == "" {
			return nil
		}
		if baseURL == "" || remoteName == "" {
			return fmt.Errorf("FAIRY_MODEL_BASE_URL and FAIRY_MODEL_NAME must be configured together")
		}
		protocol := strings.TrimSpace(strings.ToLower(cfg.ModelProtocol))
		if protocol == "" {
			protocol = OpenAICompatibleProtocol
		}
		cfg.ModelProtocol = protocol
		cfg.ModelProviders = []ModelProviderConfig{{
			ID:           defaultProviderID,
			Protocol:     protocol,
			BaseURL:      baseURL,
			APIKey:       cfg.ModelAPIKey,
			Timeout:      defaultProviderTimeout,
			MaxRetries:   1,
			RetryBackoff: defaultRetryBackoff,
		}}
		cfg.ModelDefinitions = []ModelDefinitionConfig{{
			ID:            defaultModelID,
			ProviderID:    defaultProviderID,
			RemoteName:    remoteName,
			ContextWindow: defaultModelContext,
		}}
		cfg.ModelTasks = []ModelTaskConfig{{
			ID:              ReplyerTaskID,
			Strategy:        SequentialModelStrategy,
			CandidateModels: []string{defaultModelID},
			MaxOutputTokens: cfg.ModelMaxTokens,
			Timeout:         defaultModelTaskTimeout,
			DailyLimit:      cfg.ModelDailyLimit,
		}}
		return nil
	}

	cfg.ModelProviders = append([]ModelProviderConfig(nil), cfg.ModelProviders...)
	for index := range cfg.ModelProviders {
		provider := &cfg.ModelProviders[index]
		provider.ID = strings.TrimSpace(strings.ToLower(provider.ID))
		provider.Protocol = strings.TrimSpace(strings.ToLower(provider.Protocol))
		provider.BaseURL = strings.TrimSpace(provider.BaseURL)
		if provider.Protocol == "" {
			provider.Protocol = OpenAICompatibleProtocol
		}
		if provider.Timeout == 0 {
			provider.Timeout = defaultProviderTimeout
		}
		if provider.RetryBackoff == 0 {
			provider.RetryBackoff = defaultRetryBackoff
		}
	}
	cfg.ModelDefinitions = append([]ModelDefinitionConfig(nil), cfg.ModelDefinitions...)
	for index := range cfg.ModelDefinitions {
		model := &cfg.ModelDefinitions[index]
		model.ID = strings.TrimSpace(strings.ToLower(model.ID))
		model.ProviderID = strings.TrimSpace(strings.ToLower(model.ProviderID))
		model.RemoteName = strings.TrimSpace(model.RemoteName)
		if model.ContextWindow == 0 {
			model.ContextWindow = defaultModelContext
		}
	}
	cfg.ModelTasks = append([]ModelTaskConfig(nil), cfg.ModelTasks...)
	for index := range cfg.ModelTasks {
		task := &cfg.ModelTasks[index]
		task.ID = strings.TrimSpace(strings.ToLower(task.ID))
		task.Strategy = strings.TrimSpace(strings.ToLower(task.Strategy))
		if task.Strategy == "" {
			task.Strategy = SequentialModelStrategy
		}
		task.CandidateModels = append([]string(nil), task.CandidateModels...)
		for candidateIndex := range task.CandidateModels {
			task.CandidateModels[candidateIndex] = strings.TrimSpace(strings.ToLower(task.CandidateModels[candidateIndex]))
		}
		if task.MaxOutputTokens == 0 {
			task.MaxOutputTokens = cfg.ModelMaxTokens
		}
		if task.Timeout == 0 {
			task.Timeout = defaultModelTaskTimeout
		}
		// A missing value in v1-v4 managed configs inherits the global cap.
		if task.DailyLimit == 0 && cfg.ModelDailyLimit > 0 {
			task.DailyLimit = cfg.ModelDailyLimit
		}
	}
	return nil
}

func validateModelConfiguration(cfg Config) error {
	if len(cfg.ModelProviders) == 0 && len(cfg.ModelDefinitions) == 0 && len(cfg.ModelTasks) == 0 {
		return nil
	}
	if len(cfg.ModelProviders) == 0 || len(cfg.ModelDefinitions) == 0 || len(cfg.ModelTasks) == 0 {
		return fmt.Errorf("Fairy model providers, models, and tasks must be configured together")
	}
	providers := make(map[string]ModelProviderConfig, len(cfg.ModelProviders))
	for _, provider := range cfg.ModelProviders {
		if !validModelConfigID(provider.ID) {
			return fmt.Errorf("invalid Fairy model provider ID %q", provider.ID)
		}
		if _, exists := providers[provider.ID]; exists {
			return fmt.Errorf("duplicate Fairy model provider ID %q", provider.ID)
		}
		providers[provider.ID] = provider
		if provider.Protocol != OpenAICompatibleProtocol && provider.Protocol != AnthropicCompatibleProtocol {
			return fmt.Errorf("unsupported Fairy model provider protocol %q", provider.Protocol)
		}
		if err := validateModelProviderURL(provider.BaseURL); err != nil {
			return fmt.Errorf("provider %q: %w", provider.ID, err)
		}
		if len(provider.APIKey) > 8192 || strings.ContainsAny(provider.APIKey, "\r\n\x00") {
			return fmt.Errorf("provider %q API key is invalid", provider.ID)
		}
		if provider.Timeout < time.Second || provider.Timeout > 2*time.Minute {
			return fmt.Errorf("provider %q timeout must be between 1s and 2m", provider.ID)
		}
		if provider.MaxRetries < 0 || provider.MaxRetries > 5 {
			return fmt.Errorf("provider %q max retries must be between 0 and 5", provider.ID)
		}
		if provider.RetryBackoff < 50*time.Millisecond || provider.RetryBackoff > 10*time.Second {
			return fmt.Errorf("provider %q retry backoff must be between 50ms and 10s", provider.ID)
		}
	}

	models := make(map[string]ModelDefinitionConfig, len(cfg.ModelDefinitions))
	for _, model := range cfg.ModelDefinitions {
		if !validModelConfigID(model.ID) {
			return fmt.Errorf("invalid Fairy model ID %q", model.ID)
		}
		if _, exists := models[model.ID]; exists {
			return fmt.Errorf("duplicate Fairy model ID %q", model.ID)
		}
		models[model.ID] = model
		if _, exists := providers[model.ProviderID]; !exists {
			return fmt.Errorf("model %q references unknown provider %q", model.ID, model.ProviderID)
		}
		if model.RemoteName == "" || len(model.RemoteName) > 256 || strings.ContainsAny(model.RemoteName, "\r\n\x00") {
			return fmt.Errorf("model %q remote name is invalid", model.ID)
		}
		if model.ContextWindow < 1024 || model.ContextWindow > 4_000_000 {
			return fmt.Errorf("model %q context window must be between 1024 and 4000000", model.ID)
		}
		if model.InputPriceMicrosPerMillionTokens < 0 || model.InputPriceMicrosPerMillionTokens > 1_000_000_000_000 ||
			model.OutputPriceMicrosPerMillionTokens < 0 || model.OutputPriceMicrosPerMillionTokens > 1_000_000_000_000 {
			return fmt.Errorf("model %q token prices are invalid", model.ID)
		}
	}

	tasks := make(map[string]struct{}, len(cfg.ModelTasks))
	hasReplyer := false
	for _, task := range cfg.ModelTasks {
		if !validModelConfigID(task.ID) {
			return fmt.Errorf("invalid Fairy model task ID %q", task.ID)
		}
		if _, exists := tasks[task.ID]; exists {
			return fmt.Errorf("duplicate Fairy model task ID %q", task.ID)
		}
		tasks[task.ID] = struct{}{}
		hasReplyer = hasReplyer || task.ID == ReplyerTaskID
		if task.Strategy != SequentialModelStrategy {
			return fmt.Errorf("task %q uses unsupported strategy %q", task.ID, task.Strategy)
		}
		if len(task.CandidateModels) == 0 || len(task.CandidateModels) > 8 {
			return fmt.Errorf("task %q must contain 1-8 candidate models", task.ID)
		}
		seenCandidates := make(map[string]struct{}, len(task.CandidateModels))
		for _, modelID := range task.CandidateModels {
			model, exists := models[modelID]
			if !exists {
				return fmt.Errorf("task %q references unknown model %q", task.ID, modelID)
			}
			if task.ID == TranscriberTaskID && providers[model.ProviderID].Protocol != OpenAICompatibleProtocol {
				return fmt.Errorf("task %q requires an OpenAI-compatible provider", task.ID)
			}
			if _, exists := seenCandidates[modelID]; exists {
				return fmt.Errorf("task %q repeats model %q", task.ID, modelID)
			}
			seenCandidates[modelID] = struct{}{}
		}
		if task.MaxOutputTokens < 64 || task.MaxOutputTokens > 4096 {
			return fmt.Errorf("task %q max output tokens must be between 64 and 4096", task.ID)
		}
		if task.Timeout < time.Second || task.Timeout > cfg.TurnTimeout {
			return fmt.Errorf("task %q timeout must be between 1s and the Fairy turn timeout", task.ID)
		}
		if task.DailyLimit < 0 || task.DailyLimit > 1_000_000 {
			return fmt.Errorf("task %q daily limit must be between 0 and 1000000", task.ID)
		}
	}
	if !hasReplyer {
		return fmt.Errorf("Fairy model configuration requires a replyer task")
	}
	return nil
}

func validateModelProviderURL(value string) error {
	parsed, err := url.Parse(value)
	if err != nil || parsed.Host == "" || parsed.User != nil || parsed.RawQuery != "" || parsed.Fragment != "" {
		return fmt.Errorf("base URL must be an absolute HTTPS URL without credentials, query, or fragment")
	}
	if parsed.Scheme == "https" {
		return nil
	}
	host := parsed.Hostname()
	if parsed.Scheme == "http" && (host == "localhost" || net.ParseIP(host) != nil && net.ParseIP(host).IsLoopback()) {
		return nil
	}
	return fmt.Errorf("base URL must use HTTPS (HTTP is allowed only for loopback tests)")
}

func validModelConfigID(value string) bool {
	if value == "" || len(value) > 64 {
		return false
	}
	for _, character := range value {
		if character >= 'a' && character <= 'z' || character >= '0' && character <= '9' ||
			character == '-' || character == '_' || character == '.' {
			continue
		}
		return false
	}
	return true
}
