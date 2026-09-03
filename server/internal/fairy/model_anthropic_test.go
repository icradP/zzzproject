package fairy

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestAnthropicCompatibleProjectsMessagesToolsAndUsage(t *testing.T) {
	server := httptest.NewTLSServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		if request.URL.Path != "/anthropic/v1/messages" {
			t.Errorf("Anthropic path = %s", request.URL.Path)
		}
		if request.Header.Get("x-api-key") != "router-secret" || request.Header.Get("anthropic-version") != anthropicVersion ||
			request.Header.Get("Authorization") != "" {
			t.Errorf("Anthropic headers key=%q version=%q authorization=%q",
				request.Header.Get("x-api-key"), request.Header.Get("anthropic-version"), request.Header.Get("Authorization"))
		}
		var payload anthropicRequestPayload
		if err := json.NewDecoder(request.Body).Decode(&payload); err != nil {
			t.Fatal(err)
		}
		if payload.Model != "primary-remote" || payload.System != "system-one\n\nsystem-two" || payload.MaxTokens != 600 ||
			len(payload.Messages) != 3 || len(payload.Tools) != 1 || payload.ToolChoice == nil || payload.ToolChoice.Type != "auto" {
			t.Fatalf("Anthropic payload = %#v", payload)
		}
		if payload.Messages[0].Role != "user" || payload.Messages[0].Content[0].Text != "first request" ||
			payload.Messages[1].Role != "assistant" || payload.Messages[1].Content[0].Type != "tool_use" ||
			payload.Messages[1].Content[0].Name != "lookup" || string(payload.Messages[1].Content[0].Input) != `{"value":"first"}` ||
			payload.Messages[2].Role != "user" || len(payload.Messages[2].Content) != 2 ||
			payload.Messages[2].Content[0].Type != "tool_result" || payload.Messages[2].Content[0].ToolUseID != "call_previous" ||
			payload.Messages[2].Content[1].Text != "continue" {
			t.Fatalf("Anthropic messages = %#v", payload.Messages)
		}
		if payload.Tools[0].Name != "lookup" || string(payload.Tools[0].InputSchema) != `{"type":"object"}` {
			t.Fatalf("Anthropic tools = %#v", payload.Tools)
		}
		response.Header().Set("Content-Type", "application/json")
		_, _ = response.Write([]byte(`{
			"type":"message","role":"assistant","stop_reason":"tool_use",
			"content":[{"type":"thinking","thinking":"private reasoning","signature":"opaque"},{"type":"tool_use","id":"call_next","name":"lookup","input":{"value":"next"}}],
			"usage":{"input_tokens":31,"output_tokens":7}
		}`))
	}))
	defer server.Close()

	cfg := anthropicModelRouterTestConfig(t, server.URL+"/anthropic", 0)
	cfg.ModelTasks = append(cfg.ModelTasks, ModelTaskConfig{
		ID: PlannerTaskID, Strategy: SequentialModelStrategy, CandidateModels: []string{"primary"},
		MaxOutputTokens: 600, Timeout: 5 * time.Second,
	})
	trace := newMemoryTraceStore()
	router, err := NewModelRouter(cfg, trace)
	if err != nil {
		t.Fatal(err)
	}
	router.clients["provider"] = server.Client()
	result, err := router.CompleteRequest(context.Background(), ModelRequest{
		TaskID: PlannerTaskID,
		Messages: []ChatMessage{
			{Role: "system", Content: "system-one"},
			{Role: "user", Content: "first request"},
			{Role: "system", Content: "system-two"},
			{Role: "assistant", ToolCalls: []ModelToolCall{nativeToolCall("call_previous", "lookup", `{"value":"first"}`)}},
			{Role: "tool", ToolCallID: "call_previous", Content: "untrusted result"},
			{Role: "user", Content: "continue"},
		},
		Tools:       []ModelToolDefinition{{Name: "lookup", Description: "Look up a value.", Parameters: json.RawMessage(`{"type":"object"}`)}},
		RequireJSON: true, Step: 2,
	})
	if err != nil {
		t.Fatal(err)
	}
	if result.Text != "" || len(result.ToolCalls) != 1 || result.ToolCalls[0].ID != "call_next" ||
		result.ToolCalls[0].Function.Name != "lookup" || result.ToolCalls[0].Function.Arguments != `{"value":"next"}` {
		t.Fatalf("Anthropic result = %#v", result)
	}
	if len(trace.events) != 2 || trace.events[0].InputTokens != 31 || trace.events[0].OutputTokens != 7 ||
		trace.events[0].ProviderID != "provider" || trace.events[0].TaskID != PlannerTaskID {
		t.Fatalf("Anthropic trace = %#v", trace.events)
	}
	if trace.events[1].Type != TraceModelReasoning || trace.events[1].Content != "private reasoning" ||
		trace.events[1].Signature != "opaque" || trace.events[1].Redacted {
		t.Fatalf("Anthropic reasoning trace = %#v", trace.events[1])
	}
}

func TestAnthropicRedactedThinkingStoresOnlyDigestSignature(t *testing.T) {
	response, err := modelResponseFromAnthropic([]anthropicContentBlock{{
		Type: "redacted_thinking", Data: "provider-encrypted-reasoning",
	}})
	if err != nil {
		t.Fatal(err)
	}
	if len(response.Reasoning) != 1 || !response.Reasoning[0].Redacted ||
		!strings.HasPrefix(response.Reasoning[0].Signature, "sha256:") || response.Reasoning[0].Text != "" ||
		strings.Contains(response.Reasoning[0].Signature, "provider-encrypted-reasoning") {
		t.Fatalf("redacted reasoning = %#v", response.Reasoning)
	}
}

func TestAnthropicCompatibleProjectsValidatedImage(t *testing.T) {
	server := httptest.NewTLSServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		var payload anthropicRequestPayload
		if err := json.NewDecoder(request.Body).Decode(&payload); err != nil {
			t.Fatal(err)
		}
		if len(payload.Messages) != 1 || len(payload.Messages[0].Content) != 2 {
			t.Fatalf("Anthropic vision messages = %#v", payload.Messages)
		}
		image := payload.Messages[0].Content[1]
		if image.Type != "image" || image.Source == nil || image.Source.Type != "base64" ||
			image.Source.MediaType != "image/png" || image.Source.Data != "dmFsaWRhdGVkLWltYWdl" {
			t.Fatalf("Anthropic image block = %#v", image)
		}
		_, _ = response.Write([]byte(`{"content":[{"type":"text","text":"test image"}],"stop_reason":"end_turn","usage":{"input_tokens":9,"output_tokens":2}}`))
	}))
	defer server.Close()

	cfg := anthropicModelRouterTestConfig(t, server.URL+"/anthropic", 0)
	cfg.ModelTasks = append(cfg.ModelTasks, ModelTaskConfig{
		ID: VisionTaskID, Strategy: SequentialModelStrategy, CandidateModels: []string{"primary"},
		MaxOutputTokens: 300, Timeout: 5 * time.Second,
	})
	router, err := NewModelRouter(cfg, nil)
	if err != nil {
		t.Fatal(err)
	}
	router.clients["provider"] = server.Client()
	result, err := router.CompleteRequest(context.Background(), ModelRequest{
		TaskID: VisionTaskID, Messages: []ChatMessage{{Role: "user", Content: "describe"}},
		Images: []ModelBinaryInput{{MIMEType: "image/png", Data: []byte("validated-image")}},
	})
	if err != nil || result.Text != "test image" {
		t.Fatalf("Anthropic vision result=%#v err=%v", result, err)
	}
}

func TestAnthropicCompatibleStopReasonsControlFallback(t *testing.T) {
	tests := []struct {
		name        string
		primaryBody string
		wantReply   string
		wantCalls   int32
		wantFailure ModelFailureCode
	}{
		{name: "max tokens falls back", primaryBody: `{"content":[{"type":"text","text":"partial"}],"stop_reason":"max_tokens"}`, wantReply: "fallback", wantCalls: 2},
		{name: "refusal does not fall back", primaryBody: `{"content":[{"type":"refusal","text":"denied"}],"stop_reason":"refusal"}`, wantCalls: 1, wantFailure: ModelFailureContentRejected},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			var calls atomic.Int32
			server := httptest.NewTLSServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
				var payload anthropicRequestPayload
				if err := json.NewDecoder(request.Body).Decode(&payload); err != nil {
					t.Fatal(err)
				}
				calls.Add(1)
				if payload.Model == "primary-remote" {
					_, _ = response.Write([]byte(test.primaryBody))
					return
				}
				_, _ = response.Write([]byte(`{"content":[{"type":"text","text":"fallback"}],"stop_reason":"end_turn"}`))
			}))
			defer server.Close()
			cfg := anthropicModelRouterTestConfig(t, server.URL+"/anthropic", 0)
			router, err := NewModelRouter(cfg, nil)
			if err != nil {
				t.Fatal(err)
			}
			router.clients["provider"] = server.Client()
			reply, err := router.Complete(context.Background(), []ChatMessage{{Role: "user", Content: "hello"}})
			if test.wantFailure != "" {
				var failure *ModelFailure
				if !errors.As(err, &failure) || failure.Code != test.wantFailure {
					t.Fatalf("Anthropic failure = %#v", err)
				}
			} else if err != nil || reply != test.wantReply {
				t.Fatalf("Anthropic reply=%q err=%v", reply, err)
			}
			if calls.Load() != test.wantCalls {
				t.Fatalf("Anthropic calls=%d want=%d", calls.Load(), test.wantCalls)
			}
		})
	}
}

func TestAnthropicProviderCannotBackTranscriberTask(t *testing.T) {
	cfg := anthropicModelRouterTestConfig(t, "https://provider.example.test/anthropic", 0)
	cfg.ModelTasks = append(cfg.ModelTasks, ModelTaskConfig{
		ID: TranscriberTaskID, Strategy: SequentialModelStrategy, CandidateModels: []string{"primary"},
		MaxOutputTokens: 300, Timeout: 5 * time.Second,
	})
	if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "OpenAI-compatible") {
		t.Fatalf("Anthropic transcriber config error = %v", err)
	}
}

func anthropicModelRouterTestConfig(t *testing.T, baseURL string, maxRetries int) Config {
	t.Helper()
	cfg := modelRouterTestConfig(t, baseURL, maxRetries)
	cfg.ModelProviders[0].Protocol = AnthropicCompatibleProtocol
	return cfg
}
