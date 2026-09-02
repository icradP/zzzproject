package fairy

import (
	"context"
	"fmt"
	"strings"
	"time"
)

const (
	modelProbeTaskID    = "model-probe"
	modelProbeMaxTokens = 256
	modelProbeTimeout   = 30 * time.Second
)

type ModelProbeResult struct {
	OK                    bool             `json:"ok"`
	ModelID               string           `json:"model_id"`
	ProviderID            string           `json:"provider_id"`
	Protocol              string           `json:"protocol"`
	LatencyMillis         int64            `json:"latency_millis"`
	InputTokens           int              `json:"input_tokens"`
	OutputTokens          int              `json:"output_tokens"`
	EstimatedCostMicroUSD int64            `json:"estimated_cost_microusd"`
	FailureCode           ModelFailureCode `json:"failure_code,omitempty"`
	HTTPStatus            int              `json:"http_status,omitempty"`
}

// ProbeConfiguredModel sends one fixed, content-free diagnostic request to a
// saved model. It intentionally bypasses chat quota and Trace because it does
// not contain user data; the caller must provide its own admin authorization
// and concurrency control.
func ProbeConfiguredModel(ctx context.Context, cfg Config, modelID string) (ModelProbeResult, error) {
	modelID = strings.TrimSpace(modelID)
	if !validModelConfigID(modelID) {
		return ModelProbeResult{}, fmt.Errorf("invalid Fairy model ID")
	}
	router, err := NewModelRouter(cfg, nil)
	if err != nil {
		return ModelProbeResult{}, fmt.Errorf("initialize Fairy model probe: %w", err)
	}
	model, exists := router.snapshot.Model(modelID)
	if !exists {
		return ModelProbeResult{}, fmt.Errorf("Fairy model %q is not configured", modelID)
	}
	provider, exists := router.snapshot.Provider(model.ProviderID)
	if !exists {
		return ModelProbeResult{}, fmt.Errorf("Fairy model provider is not configured")
	}
	result := ModelProbeResult{
		ModelID: model.ID, ProviderID: provider.ID, Protocol: provider.Protocol,
	}
	task := TaskSnapshot{
		ID: modelProbeTaskID, Strategy: SequentialModelStrategy,
		CandidateModels: []string{model.ID}, MaxOutputTokens: modelProbeMaxTokens,
		Timeout: modelProbeTimeout,
	}
	request := ModelRequest{
		TaskID: modelProbeTaskID,
		Messages: []ChatMessage{
			{Role: "system", Content: "This is a connectivity diagnostic. Reply with only OK."},
			{Role: "user", Content: "Reply now."},
		},
	}
	probeContext, cancel := context.WithTimeout(ctx, modelProbeTimeout)
	defer cancel()
	startedAt := time.Now()
	completion, failure := router.completeAttempt(probeContext, provider, model, task, request)
	result.LatencyMillis = time.Since(startedAt).Milliseconds()
	if failure != nil {
		result.FailureCode = failure.Code
		result.HTTPStatus = failure.HTTPStatus
		return result, nil
	}
	if strings.TrimSpace(completion.Response.Text) == "" || len(completion.Response.ToolCalls) != 0 {
		result.FailureCode = ModelFailureInvalidResponse
		return result, nil
	}
	result.OK = true
	result.InputTokens = validUsageTokens(completion.Usage.InputTokens)
	result.OutputTokens = validUsageTokens(completion.Usage.OutputTokens)
	result.EstimatedCostMicroUSD = modelCostMicroUSD(model, completion.Usage)
	return result, nil
}
