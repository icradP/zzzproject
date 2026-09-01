package fairy

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

type Model interface {
	Complete(ctx context.Context, messages []ChatMessage) (string, error)
}

// CompatibleModel calls the common OpenAI-compatible chat completions shape.
// It intentionally lives in the Fairy process so provider keys never enter
// the IM server or client configuration.
type CompatibleModel struct {
	endpoint  string
	apiKey    string
	model     string
	maxTokens int
	client    *http.Client
}

func NewCompatibleModel(cfg Config) *CompatibleModel {
	return &CompatibleModel{
		endpoint:  strings.TrimRight(cfg.ModelBaseURL, "/") + "/chat/completions",
		apiKey:    cfg.ModelAPIKey,
		model:     cfg.ModelName,
		maxTokens: cfg.ModelMaxTokens,
		client:    &http.Client{Timeout: 45 * time.Second},
	}
}

func (m *CompatibleModel) Complete(ctx context.Context, messages []ChatMessage) (string, error) {
	payload, err := json.Marshal(map[string]interface{}{
		"model":       m.model,
		"messages":    messages,
		"max_tokens":  m.maxTokens,
		"temperature": 0.7,
	})
	if err != nil {
		return "", err
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, m.endpoint, bytes.NewReader(payload))
	if err != nil {
		return "", err
	}
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set("User-Agent", "ZZZ-IM-Fairy/1.0")
	if m.apiKey != "" {
		request.Header.Set("Authorization", "Bearer "+m.apiKey)
	}
	response, err := m.client.Do(request)
	if err != nil {
		return "", fmt.Errorf("model request failed: %w", err)
	}
	defer response.Body.Close()
	body, err := io.ReadAll(io.LimitReader(response.Body, 2*1024*1024))
	if err != nil {
		return "", err
	}
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return "", fmt.Errorf("model returned HTTP %d", response.StatusCode)
	}
	var decoded struct {
		Choices []struct {
			Message ChatMessage `json:"message"`
		} `json:"choices"`
	}
	if err := json.Unmarshal(body, &decoded); err != nil {
		return "", fmt.Errorf("decode model response: %w", err)
	}
	if len(decoded.Choices) == 0 || strings.TrimSpace(decoded.Choices[0].Message.Content) == "" {
		return "", fmt.Errorf("model returned no text")
	}
	return limitRunes(strings.TrimSpace(decoded.Choices[0].Message.Content), 4000), nil
}
