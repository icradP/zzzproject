package fairy

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestProbeConfiguredModelOpenAICompatible(t *testing.T) {
	const secret = "probe-openai-secret"
	var calls atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		calls.Add(1)
		if request.URL.Path != "/v1/chat/completions" || request.Header.Get("Authorization") != "Bearer "+secret {
			t.Fatalf("probe request path=%q authorization=%q", request.URL.Path, request.Header.Get("Authorization"))
		}
		var payload struct {
			Model     string        `json:"model"`
			Messages  []ChatMessage `json:"messages"`
			MaxTokens int           `json:"max_tokens"`
		}
		if err := json.NewDecoder(request.Body).Decode(&payload); err != nil {
			t.Fatal(err)
		}
		if payload.Model != "probe-remote" || payload.MaxTokens != modelProbeMaxTokens || len(payload.Messages) != 2 ||
			payload.Messages[0].Role != "system" || payload.Messages[0].Content != "This is a connectivity diagnostic. Reply with only OK." ||
			payload.Messages[1].Role != "user" || payload.Messages[1].Content != "Reply now." {
			t.Fatalf("probe payload = %#v", payload)
		}
		_, _ = response.Write([]byte(`{"choices":[{"message":{"role":"assistant","content":"private model reply"},"finish_reason":"stop"}],"usage":{"prompt_tokens":12,"completion_tokens":3}}`))
	}))
	defer server.Close()

	cfg := probeTestConfig(t, server.URL+"/v1", OpenAICompatibleProtocol, secret)
	result, err := ProbeConfiguredModel(context.Background(), cfg, "probe-model")
	if err != nil {
		t.Fatal(err)
	}
	if !result.OK || result.ModelID != "probe-model" || result.ProviderID != "probe-provider" ||
		result.Protocol != OpenAICompatibleProtocol || result.InputTokens != 12 || result.OutputTokens != 3 ||
		result.EstimatedCostMicroUSD != 36 || result.FailureCode != "" || result.HTTPStatus != 0 || calls.Load() != 1 {
		t.Fatalf("probe result = %#v calls=%d", result, calls.Load())
	}
	encoded, err := json.Marshal(result)
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(encoded, []byte("private model reply")) || bytes.Contains(encoded, []byte(secret)) {
		t.Fatalf("probe response leaked private data: %s", encoded)
	}
}

func TestProbeConfiguredModelAnthropicCompatible(t *testing.T) {
	const secret = "probe-anthropic-secret"
	var calls atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		calls.Add(1)
		if request.URL.Path != "/anthropic/v1/messages" || request.Header.Get("x-api-key") != secret ||
			request.Header.Get("anthropic-version") != anthropicVersion || request.Header.Get("Authorization") != "" {
			t.Fatalf("probe request path=%q key=%q version=%q authorization=%q", request.URL.Path,
				request.Header.Get("x-api-key"), request.Header.Get("anthropic-version"), request.Header.Get("Authorization"))
		}
		var payload anthropicRequestPayload
		if err := json.NewDecoder(request.Body).Decode(&payload); err != nil {
			t.Fatal(err)
		}
		if payload.Model != "probe-remote" || payload.MaxTokens != modelProbeMaxTokens ||
			payload.System != "This is a connectivity diagnostic. Reply with only OK." || len(payload.Messages) != 1 ||
			payload.Messages[0].Role != "user" || len(payload.Messages[0].Content) != 1 ||
			payload.Messages[0].Content[0].Text != "Reply now." {
			t.Fatalf("Anthropic probe payload = %#v", payload)
		}
		_, _ = response.Write([]byte(`{"content":[{"type":"text","text":"private model reply"}],"stop_reason":"end_turn","usage":{"input_tokens":8,"output_tokens":2}}`))
	}))
	defer server.Close()

	cfg := probeTestConfig(t, server.URL+"/anthropic", AnthropicCompatibleProtocol, secret)
	result, err := ProbeConfiguredModel(context.Background(), cfg, "probe-model")
	if err != nil {
		t.Fatal(err)
	}
	if !result.OK || result.Protocol != AnthropicCompatibleProtocol || result.InputTokens != 8 ||
		result.OutputTokens != 2 || result.EstimatedCostMicroUSD != 24 || calls.Load() != 1 {
		t.Fatalf("probe result = %#v calls=%d", result, calls.Load())
	}
}

func TestProbeConfiguredModelClassifiesFailureWithoutLeakingUpstreamBody(t *testing.T) {
	tests := []struct {
		name       string
		status     int
		wantCode   ModelFailureCode
		wantStatus int
	}{
		{name: "authentication", status: http.StatusUnauthorized, wantCode: ModelFailureAuthentication, wantStatus: http.StatusUnauthorized},
		{name: "rate limited", status: http.StatusTooManyRequests, wantCode: ModelFailureRateLimited, wantStatus: http.StatusTooManyRequests},
		{name: "server", status: http.StatusServiceUnavailable, wantCode: ModelFailureServer, wantStatus: http.StatusServiceUnavailable},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			var calls atomic.Int32
			server := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, _ *http.Request) {
				calls.Add(1)
				response.WriteHeader(test.status)
				_, _ = response.Write([]byte(`{"error":"upstream-private-detail"}`))
			}))
			defer server.Close()
			cfg := probeTestConfig(t, server.URL, OpenAICompatibleProtocol, "failure-secret")
			result, err := ProbeConfiguredModel(context.Background(), cfg, "probe-model")
			if err != nil {
				t.Fatal(err)
			}
			if result.OK || result.FailureCode != test.wantCode || result.HTTPStatus != test.wantStatus || calls.Load() != 1 {
				t.Fatalf("probe result = %#v calls=%d", result, calls.Load())
			}
			encoded, err := json.Marshal(result)
			if err != nil {
				t.Fatal(err)
			}
			if bytes.Contains(encoded, []byte("upstream-private-detail")) || bytes.Contains(encoded, []byte("failure-secret")) {
				t.Fatalf("failure response leaked private data: %s", encoded)
			}
		})
	}
}

func TestProbeConfiguredModelRejectsUnknownOrInvalidModelID(t *testing.T) {
	cfg := probeTestConfig(t, "https://provider.example.test/v1", OpenAICompatibleProtocol, "secret")
	for _, modelID := range []string{"unknown", "INVALID MODEL"} {
		if _, err := ProbeConfiguredModel(context.Background(), cfg, modelID); err == nil {
			t.Fatalf("model ID %q was accepted", modelID)
		}
	}
}

func TestFairyAdminAPIModelProbeValidationAndConcurrency(t *testing.T) {
	cfg := probeTestConfig(t, "https://provider.example.test/v1", OpenAICompatibleProtocol, "never-return-this-key")
	cfg.ConfigFile = ""
	manager := NewConfigManager(cfg)
	handler := NewAdminAPI(manager, "local-admin-token", nil, nil)

	unauthorized := httptest.NewRecorder()
	handler.ServeHTTP(unauthorized, httptest.NewRequest(http.MethodPost, "/admin/model-probe", strings.NewReader(`{"model_id":"probe-model"}`)))
	if unauthorized.Code != http.StatusUnauthorized {
		t.Fatalf("unauthorized probe status = %d", unauthorized.Code)
	}

	for name, body := range map[string]string{
		"unknown field": `{"model_id":"probe-model","prompt":"leak data"}`,
		"trailing JSON": `{"model_id":"probe-model"}{}`,
		"oversized":     `{"model_id":"` + strings.Repeat("a", maxModelProbeRequestBytes) + `"}`,
	} {
		t.Run(name, func(t *testing.T) {
			response := performFairyAdminRequest(handler, strings.NewReader(body))
			if response.Code != http.StatusBadRequest {
				t.Fatalf("invalid probe status=%d body=%s", response.Code, response.Body.String())
			}
		})
	}

	started := make(chan struct{})
	release := make(chan struct{})
	handler.probe = func(context.Context, Config, string) (ModelProbeResult, error) {
		close(started)
		<-release
		return ModelProbeResult{OK: true, ModelID: "probe-model", ProviderID: "probe-provider", Protocol: OpenAICompatibleProtocol}, nil
	}
	firstDone := make(chan *httptest.ResponseRecorder, 1)
	go func() {
		firstDone <- performFairyAdminRequest(handler, strings.NewReader(`{"model_id":"probe-model"}`))
	}()
	select {
	case <-started:
	case <-time.After(time.Second):
		t.Fatal("first probe did not start")
	}
	busy := performFairyAdminRequest(handler, strings.NewReader(`{"model_id":"probe-model"}`))
	if busy.Code != http.StatusTooManyRequests {
		t.Fatalf("concurrent probe status=%d body=%s", busy.Code, busy.Body.String())
	}
	close(release)
	first := <-firstDone
	if first.Code != http.StatusOK || strings.Contains(first.Body.String(), "never-return-this-key") {
		t.Fatalf("probe status=%d body=%s", first.Code, first.Body.String())
	}
}

func probeTestConfig(t *testing.T, baseURL, protocol, apiKey string) Config {
	t.Helper()
	cfg := modelRouterTestConfig(t, baseURL, 0)
	cfg.ModelProviders[0].ID = "probe-provider"
	cfg.ModelProviders[0].Protocol = protocol
	cfg.ModelProviders[0].APIKey = apiKey
	cfg.ModelDefinitions = []ModelDefinitionConfig{{
		ID: "probe-model", ProviderID: "probe-provider", RemoteName: "probe-remote", ContextWindow: 128000,
		InputPriceMicrosPerMillionTokens: 2_000_000, OutputPriceMicrosPerMillionTokens: 4_000_000,
	}}
	cfg.ModelTasks[0].CandidateModels = []string{"probe-model"}
	return cfg
}

func performFairyAdminRequest(handler http.Handler, body *strings.Reader) *httptest.ResponseRecorder {
	request := httptest.NewRequest(http.MethodPost, "/admin/model-probe", body)
	request.Header.Set("Authorization", "Bearer local-admin-token")
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	return response
}
