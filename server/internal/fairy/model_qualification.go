package fairy

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"sort"
	"time"
)

var ErrModelQualificationStale = errors.New("Fairy model configuration changed during evaluation")

type ModelQualification struct {
	ModelID       string
	Fingerprint   string
	CorpusVersion int
	QualifiedAt   time.Time
}

type ManagedModelQualificationView struct {
	ModelID       string `json:"model_id"`
	CorpusVersion int    `json:"corpus_version"`
	QualifiedAt   string `json:"qualified_at"`
}

type modelQualificationFingerprintPayload struct {
	SchemaVersion                     string `json:"schema_version"`
	CorpusVersion                     int    `json:"corpus_version"`
	ModelID                           string `json:"model_id"`
	ProviderID                        string `json:"provider_id"`
	Protocol                          string `json:"protocol"`
	BaseURL                           string `json:"base_url"`
	APIKey                            string `json:"api_key"`
	ProviderTimeoutNanos              int64  `json:"provider_timeout_nanos"`
	ProviderMaxRetries                int    `json:"provider_max_retries"`
	ProviderRetryBackoffNanos         int64  `json:"provider_retry_backoff_nanos"`
	RemoteName                        string `json:"remote_name"`
	ContextWindow                     int    `json:"context_window"`
	InputPriceMicrosPerMillionTokens  int64  `json:"input_price_micros_per_million_tokens"`
	OutputPriceMicrosPerMillionTokens int64  `json:"output_price_micros_per_million_tokens"`
}

func modelQualificationFingerprint(cfg Config, modelID string) (string, error) {
	if err := normalizeModelConfiguration(&cfg); err != nil {
		return "", fmt.Errorf("normalize Fairy model qualification: %w", err)
	}
	var model *ModelDefinitionConfig
	for index := range cfg.ModelDefinitions {
		if cfg.ModelDefinitions[index].ID == modelID {
			model = &cfg.ModelDefinitions[index]
			break
		}
	}
	if model == nil {
		return "", fmt.Errorf("Fairy model %q is not configured", modelID)
	}
	var provider *ModelProviderConfig
	for index := range cfg.ModelProviders {
		if cfg.ModelProviders[index].ID == model.ProviderID {
			provider = &cfg.ModelProviders[index]
			break
		}
	}
	if provider == nil {
		return "", fmt.Errorf("Fairy model provider is not configured")
	}
	payload, err := json.Marshal(modelQualificationFingerprintPayload{
		SchemaVersion: QualityEvalSchemaVersion, CorpusVersion: QualityEvalCorpusVersion,
		ModelID: model.ID, ProviderID: provider.ID, Protocol: provider.Protocol,
		BaseURL: provider.BaseURL, APIKey: provider.APIKey,
		ProviderTimeoutNanos: provider.Timeout.Nanoseconds(), ProviderMaxRetries: provider.MaxRetries,
		ProviderRetryBackoffNanos: provider.RetryBackoff.Nanoseconds(), RemoteName: model.RemoteName,
		ContextWindow:                     model.ContextWindow,
		InputPriceMicrosPerMillionTokens:  model.InputPriceMicrosPerMillionTokens,
		OutputPriceMicrosPerMillionTokens: model.OutputPriceMicrosPerMillionTokens,
	})
	if err != nil {
		return "", fmt.Errorf("encode Fairy model qualification: %w", err)
	}
	digest := sha256.Sum256(payload)
	return hex.EncodeToString(digest[:]), nil
}

func validateModelQualifications(qualifications []ModelQualification) error {
	seen := make(map[string]struct{}, len(qualifications))
	for _, qualification := range qualifications {
		if !validModelConfigID(qualification.ModelID) || qualification.CorpusVersion < 1 ||
			qualification.QualifiedAt.IsZero() || len(qualification.Fingerprint) != sha256.Size*2 {
			return fmt.Errorf("invalid Fairy model qualification")
		}
		decoded, err := hex.DecodeString(qualification.Fingerprint)
		if err != nil || len(decoded) != sha256.Size {
			return fmt.Errorf("invalid Fairy model qualification")
		}
		if _, exists := seen[qualification.ModelID]; exists {
			return fmt.Errorf("duplicate Fairy model qualification")
		}
		seen[qualification.ModelID] = struct{}{}
	}
	return nil
}

func modelQualificationCurrent(cfg Config, qualification ModelQualification) bool {
	if qualification.CorpusVersion != QualityEvalCorpusVersion {
		return false
	}
	fingerprint, err := modelQualificationFingerprint(cfg, qualification.ModelID)
	return err == nil && fingerprint == qualification.Fingerprint
}

func pruneModelQualifications(cfg *Config) {
	current := make([]ModelQualification, 0, len(cfg.ModelQualifications))
	for _, qualification := range cfg.ModelQualifications {
		if modelQualificationCurrent(*cfg, qualification) {
			current = append(current, qualification)
		}
	}
	sort.Slice(current, func(left, right int) bool { return current[left].ModelID < current[right].ModelID })
	cfg.ModelQualifications = current
}

func modelQualificationViews(cfg Config) []ManagedModelQualificationView {
	pruneModelQualifications(&cfg)
	views := make([]ManagedModelQualificationView, 0, len(cfg.ModelQualifications))
	for _, qualification := range cfg.ModelQualifications {
		views = append(views, ManagedModelQualificationView{
			ModelID: qualification.ModelID, CorpusVersion: qualification.CorpusVersion,
			QualifiedAt: qualification.QualifiedAt.UTC().Format(time.RFC3339Nano),
		})
	}
	return views
}

func replyerQualificationState(cfg Config) (required, missing []string) {
	return taskQualificationState(cfg, ReplyerTaskID)
}

func productionQualificationState(cfg Config) (required, missing []string) {
	return taskQualificationState(cfg, ReplyerTaskID, PlannerTaskID)
}

func taskQualificationState(cfg Config, taskIDs ...string) (required, missing []string) {
	required = make([]string, 0)
	missing = make([]string, 0)
	_ = normalizeModelConfiguration(&cfg)
	seen := make(map[string]bool)
	for _, taskID := range taskIDs {
		for _, task := range cfg.ModelTasks {
			if task.ID != taskID {
				continue
			}
			for _, modelID := range task.CandidateModels {
				if !seen[modelID] {
					required = append(required, modelID)
					seen[modelID] = true
				}
			}
			break
		}
	}
	qualified := make(map[string]bool, len(cfg.ModelQualifications))
	for _, qualification := range cfg.ModelQualifications {
		if modelQualificationCurrent(cfg, qualification) {
			qualified[qualification.ModelID] = true
		}
	}
	for _, modelID := range required {
		if !qualified[modelID] {
			missing = append(missing, modelID)
		}
	}
	return required, missing
}

func (c Config) ProductionReady() bool {
	required, missing := productionQualificationState(c)
	return len(required) > 0 && len(missing) == 0
}
