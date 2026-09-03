package fairy

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestModelRouterMigratesLegacyConfigAndUsesAuthorization(t *testing.T) {
	server := httptest.NewTLSServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		if request.URL.Path != "/v1/chat/completions" {
			t.Errorf("model path = %s", request.URL.Path)
		}
		if request.Header.Get("Authorization") != "Bearer test-key" {
			t.Errorf("authorization = %q", request.Header.Get("Authorization"))
		}
		var payload struct {
			Model     string        `json:"model"`
			Messages  []ChatMessage `json:"messages"`
			MaxTokens int           `json:"max_tokens"`
		}
		if err := json.NewDecoder(request.Body).Decode(&payload); err != nil {
			t.Fatal(err)
		}
		if payload.Model != "test-model" || payload.MaxTokens != 600 || len(payload.Messages) != 1 {
			t.Errorf("model payload = %#v", payload)
		}
		response.Header().Set("Content-Type", "application/json")
		_, _ = response.Write([]byte(`{"choices":[{"message":{"role":"assistant","content":"  测试回复  "}}]}`))
	}))
	defer server.Close()

	cfg := testConfig(t)
	cfg.ModelBaseURL = server.URL + "/v1"
	cfg.ModelAPIKey = "test-key"
	cfg.ModelName = "test-model"
	router, err := NewModelRouter(cfg, newMemoryTraceStore())
	if err != nil {
		t.Fatal(err)
	}
	router.clients[defaultProviderID] = server.Client()
	response, err := router.Complete(context.Background(), []ChatMessage{{Role: "user", Content: "你好"}})
	if err != nil {
		t.Fatal(err)
	}
	if strings.TrimSpace(response) != "测试回复" {
		t.Fatalf("model response = %q", response)
	}
}

func TestModelRouterMigratesLegacyAnthropicConfig(t *testing.T) {
	server := httptest.NewTLSServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		if request.URL.Path != "/anthropic/v1/messages" {
			t.Errorf("model path = %s", request.URL.Path)
		}
		if request.Header.Get("x-api-key") != "mimo-test-key" {
			t.Errorf("x-api-key = %q", request.Header.Get("x-api-key"))
		}
		if request.Header.Get("anthropic-version") != anthropicVersion {
			t.Errorf("anthropic-version = %q", request.Header.Get("anthropic-version"))
		}
		response.Header().Set("Content-Type", "application/json")
		_, _ = response.Write([]byte(`{"content":[{"type":"thinking","thinking":"private reasoning"},{"type":"text","text":"MiMo reply"}],"stop_reason":"end_turn","usage":{"input_tokens":12,"output_tokens":5}}`))
	}))
	defer server.Close()

	cfg := testConfig(t)
	cfg.ModelBaseURL = server.URL + "/anthropic"
	cfg.ModelProtocol = AnthropicCompatibleProtocol
	cfg.ModelAPIKey = "mimo-test-key"
	cfg.ModelName = "mimo-v2.5-pro"
	router, err := NewModelRouter(cfg, nil)
	if err != nil {
		t.Fatal(err)
	}
	router.clients[defaultProviderID] = server.Client()
	response, err := router.Complete(context.Background(), []ChatMessage{{Role: "user", Content: "你好"}})
	if err != nil {
		t.Fatal(err)
	}
	if response != "MiMo reply" {
		t.Fatalf("model response = %q", response)
	}
	provider, ok := router.Snapshot().Provider(defaultProviderID)
	if !ok || provider.Protocol != AnthropicCompatibleProtocol {
		t.Fatalf("legacy provider protocol = %#v", provider)
	}
}

func TestModelRouterProjectsNativeToolsAndParsesToolCalls(t *testing.T) {
	server := httptest.NewTLSServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		var payload struct {
			Model          string                   `json:"model"`
			Messages       []ChatMessage            `json:"messages"`
			Tools          []map[string]interface{} `json:"tools"`
			ToolChoice     string                   `json:"tool_choice"`
			ResponseFormat map[string]string        `json:"response_format"`
		}
		if err := json.NewDecoder(request.Body).Decode(&payload); err != nil {
			t.Fatal(err)
		}
		if payload.Model != "primary-remote" || len(payload.Messages) != 1 || len(payload.Tools) != 1 ||
			payload.ToolChoice != "auto" || payload.ResponseFormat["type"] != modelResponseJSONType {
			t.Errorf("tool-aware payload = %#v", payload)
		}
		_, _ = response.Write([]byte(`{
			"choices":[{"message":{"role":"assistant","content":null,"tool_calls":[{
				"id":"call_provider_1","type":"function","function":{"name":"lookup","arguments":"{\"value\":\"okay\"}"}
			}]}}],"usage":{"prompt_tokens":20,"completion_tokens":10}
		}`))
	}))
	defer server.Close()
	cfg := modelRouterTestConfig(t, server.URL+"/v1", 0)
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
		TaskID: PlannerTaskID, Messages: []ChatMessage{{Role: "user", Content: "lookup"}}, Step: 2,
		Tools: []ModelToolDefinition{{
			Name: "lookup", Description: "Look up one value.",
			Parameters: json.RawMessage(`{"type":"object","properties":{"value":{"type":"string"}},"required":["value"]}`),
		}},
		RequireJSON: true,
	})
	if err != nil {
		t.Fatal(err)
	}
	if result.Text != "" || len(result.ToolCalls) != 1 || result.ToolCalls[0].Function.Name != "lookup" ||
		result.ToolCalls[0].Function.Arguments != `{"value":"okay"}` {
		t.Fatalf("tool-aware result = %#v", result)
	}
	if len(trace.events) != 1 || trace.events[0].TaskID != PlannerTaskID || trace.events[0].Step != 2 ||
		trace.events[0].InputTokens != 20 || trace.events[0].OutputTokens != 10 {
		t.Fatalf("tool-aware trace = %#v", trace.events)
	}
}

func TestModelRouterValidatesAndTracesRepairMetadata(t *testing.T) {
	server := httptest.NewTLSServer(http.HandlerFunc(func(response http.ResponseWriter, _ *http.Request) {
		_, _ = response.Write([]byte(`{"choices":[{"message":{"role":"assistant","content":"{\"action\":\"stop\"}"}}]}`))
	}))
	defer server.Close()
	cfg := modelRouterTestConfig(t, server.URL+"/v1", 0)
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
	request := ModelRequest{
		TaskID: PlannerTaskID, Messages: []ChatMessage{{Role: "user", Content: "plan"}},
		RequireJSON: true, Repair: true, Step: 1,
	}
	if _, err := router.CompleteRequest(context.Background(), request); err != nil {
		t.Fatal(err)
	}
	if len(trace.events) != 1 || !trace.events[0].Repair || trace.events[0].TaskID != PlannerTaskID || trace.events[0].Step != 1 {
		t.Fatalf("repair trace = %#v", trace.events)
	}
	replyerRequest := ModelRequest{
		TaskID: ReplyerTaskID, Messages: []ChatMessage{{Role: "user", Content: "reply"}},
		Repair: true, Step: 1,
	}
	if _, err := router.CompleteRequest(context.Background(), replyerRequest); err != nil {
		t.Fatal(err)
	}
	if len(trace.events) != 2 || !trace.events[1].Repair || trace.events[1].TaskID != ReplyerTaskID || trace.events[1].Step != 1 {
		t.Fatalf("Replyer repair trace = %#v", trace.events)
	}
	for _, invalid := range []ModelRequest{
		{TaskID: ReplyerTaskID, Messages: request.Messages, RequireJSON: true, Repair: true, Step: 1},
		{TaskID: PlannerTaskID, Messages: request.Messages, Repair: true, Step: 1},
		{TaskID: VisionTaskID, Messages: request.Messages, Repair: true, Step: 1},
		{TaskID: PlannerTaskID, Messages: request.Messages, RequireJSON: true, Repair: true, Step: 0},
		{TaskID: PlannerTaskID, Messages: request.Messages, RequireJSON: true, Repair: true, Step: maxPlannerSteps + 1},
		{TaskID: ReplyerTaskID, Messages: request.Messages, Repair: true, Step: 0},
		{TaskID: ReplyerTaskID, Messages: request.Messages, Repair: true, Step: maxPlannerSteps + 1},
	} {
		if err := validateModelRequest(invalid); err == nil {
			t.Fatalf("invalid repair metadata accepted: %#v", invalid)
		}
	}
}

func TestModelRouterPlannerJSONValidationControlsFallback(t *testing.T) {
	t.Run("invalid JSON falls back", func(t *testing.T) {
		var calls atomic.Int32
		server := httptest.NewTLSServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
			var payload struct {
				Model string `json:"model"`
			}
			if err := json.NewDecoder(request.Body).Decode(&payload); err != nil {
				t.Fatal(err)
			}
			calls.Add(1)
			if payload.Model == "primary-remote" {
				_, _ = response.Write([]byte(`{"choices":[{"message":{"role":"assistant","content":"not JSON"},"finish_reason":"stop"}]}`))
				return
			}
			_, _ = response.Write([]byte(`{"choices":[{"message":{"role":"assistant","content":"{\"action\":\"respond\",\"reply_intent\":\"answer\"}"},"finish_reason":"stop"}]}`))
		}))
		defer server.Close()
		cfg := modelRouterTestConfig(t, server.URL+"/v1", 0)
		cfg.ModelTasks = append(cfg.ModelTasks, ModelTaskConfig{
			ID: PlannerTaskID, Strategy: SequentialModelStrategy, CandidateModels: []string{"primary", "fallback"},
			MaxOutputTokens: 600, Timeout: 5 * time.Second,
		})
		trace := newMemoryTraceStore()
		router, err := NewModelRouter(cfg, trace)
		if err != nil {
			t.Fatal(err)
		}
		router.clients["provider"] = server.Client()
		result, err := router.CompleteRequest(context.Background(), ModelRequest{
			TaskID: PlannerTaskID, Messages: []ChatMessage{{Role: "user", Content: "plan"}}, RequireJSON: true, Step: 1,
		})
		if err != nil || !strings.Contains(result.Text, `"action":"respond"`) || calls.Load() != 2 {
			t.Fatalf("result=%#v calls=%d err=%v", result, calls.Load(), err)
		}
		if len(trace.events) != 2 || trace.events[0].FailureCode != string(ModelFailureInvalidResponse) || !trace.events[1].Fallback {
			t.Fatalf("planner fallback trace = %#v", trace.events)
		}
	})

	t.Run("content filter never falls back", func(t *testing.T) {
		var calls atomic.Int32
		server := httptest.NewTLSServer(http.HandlerFunc(func(response http.ResponseWriter, _ *http.Request) {
			calls.Add(1)
			_, _ = response.Write([]byte(`{"choices":[{"message":{"role":"assistant","content":""},"finish_reason":"content_filter"}]}`))
		}))
		defer server.Close()
		cfg := modelRouterTestConfig(t, server.URL+"/v1", 0)
		cfg.ModelTasks = append(cfg.ModelTasks, ModelTaskConfig{
			ID: PlannerTaskID, Strategy: SequentialModelStrategy, CandidateModels: []string{"primary", "fallback"},
			MaxOutputTokens: 600, Timeout: 5 * time.Second,
		})
		router, err := NewModelRouter(cfg, nil)
		if err != nil {
			t.Fatal(err)
		}
		router.clients["provider"] = server.Client()
		_, err = router.CompleteRequest(context.Background(), ModelRequest{
			TaskID: PlannerTaskID, Messages: []ChatMessage{{Role: "user", Content: "plan"}}, RequireJSON: true,
		})
		var failure *ModelFailure
		if !errors.As(err, &failure) || failure.Code != ModelFailureContentRejected || calls.Load() != 1 {
			t.Fatalf("failure=%#v calls=%d", err, calls.Load())
		}
	})
}

func TestModelRequestSizeIncludesToolArguments(t *testing.T) {
	arguments := strings.Repeat("x", maxModelToolArguments-32)
	calls := make([]ModelToolCall, maxModelToolCalls)
	for index := range calls {
		calls[index] = nativeToolCall(
			fmt.Sprintf("call_%d", index), "lookup", `{"value":"`+arguments+`"}`,
		)
	}
	messages := []ChatMessage{{Role: "user", Content: "lookup"}}
	for step := 0; step < 2; step++ {
		messages = append(messages, ChatMessage{Role: "assistant", ToolCalls: calls})
		for _, call := range calls {
			messages = append(messages, ChatMessage{Role: "tool", ToolCallID: call.ID, Content: "bounded result"})
		}
	}
	err := validateModelRequest(ModelRequest{TaskID: PlannerTaskID, Messages: messages})
	if err == nil || !strings.Contains(err.Error(), "too large") {
		t.Fatalf("oversized tool transcript error = %v", err)
	}
}

func TestModelRouterRetriesFallsBackAndTracesUsage(t *testing.T) {
	var primaryCalls atomic.Int32
	var fallbackCalls atomic.Int32
	server := httptest.NewTLSServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		var payload struct {
			Model string `json:"model"`
		}
		if err := json.NewDecoder(request.Body).Decode(&payload); err != nil {
			t.Error(err)
			response.WriteHeader(http.StatusBadRequest)
			return
		}
		switch payload.Model {
		case "primary-remote":
			call := primaryCalls.Add(1)
			if call == 1 {
				response.WriteHeader(http.StatusTooManyRequests)
			} else {
				response.WriteHeader(http.StatusBadGateway)
			}
			_, _ = response.Write([]byte(`{"error":{"message":"temporary"}}`))
		case "fallback-remote":
			fallbackCalls.Add(1)
			_, _ = response.Write([]byte(`{"choices":[{"message":{"role":"assistant","content":"fallback reply"}}],"usage":{"prompt_tokens":100,"completion_tokens":50}}`))
		default:
			t.Errorf("unexpected model %q", payload.Model)
			response.WriteHeader(http.StatusBadRequest)
		}
	}))
	defer server.Close()

	trace := newMemoryTraceStore()
	cfg := modelRouterTestConfig(t, server.URL+"/v1", 1)
	router, err := NewModelRouter(cfg, trace)
	if err != nil {
		t.Fatal(err)
	}
	router.clients["provider"] = server.Client()
	router.wait = func(context.Context, time.Duration) error { return nil }
	router.jitter = func(time.Duration) time.Duration { return 0 }

	reply, err := router.Complete(context.Background(), []ChatMessage{{Role: "user", Content: "private prompt"}})
	if err != nil {
		t.Fatal(err)
	}
	if reply != "fallback reply" || primaryCalls.Load() != 2 || fallbackCalls.Load() != 1 {
		t.Fatalf("reply=%q primary=%d fallback=%d", reply, primaryCalls.Load(), fallbackCalls.Load())
	}
	if len(trace.events) != 3 {
		t.Fatalf("model trace count = %d, want 3", len(trace.events))
	}
	if trace.events[0].FailureCode != string(ModelFailureRateLimited) || trace.events[1].FailureCode != string(ModelFailureServer) {
		t.Fatalf("primary trace failures = %#v", trace.events[:2])
	}
	completed := trace.events[2]
	if !completed.Fallback || completed.Status != "completed" || completed.InputTokens != 100 || completed.OutputTokens != 50 ||
		completed.CostMicroUSD != 400 || completed.SnapshotID == "" {
		t.Fatalf("fallback trace = %#v", completed)
	}
	for _, event := range trace.events {
		encoded, marshalErr := json.Marshal(event)
		if marshalErr != nil {
			t.Fatal(marshalErr)
		}
		if strings.Contains(string(encoded), "private prompt") || strings.Contains(string(encoded), "router-secret") {
			t.Fatalf("model trace leaked request data: %s", encoded)
		}
	}
}

func TestModelRouterDoesNotRetryOrFallbackPermanentFailures(t *testing.T) {
	tests := []struct {
		name        string
		status      int
		body        string
		failureCode ModelFailureCode
	}{
		{name: "authentication", status: http.StatusUnauthorized, body: `{"error":"unauthorized"}`, failureCode: ModelFailureAuthentication},
		{name: "invalid request", status: http.StatusBadRequest, body: `{"error":"bad request"}`, failureCode: ModelFailureInvalidRequest},
		{name: "content rejection", status: http.StatusBadRequest, body: `{"error":{"code":"content_policy"}}`, failureCode: ModelFailureContentRejected},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			var calls atomic.Int32
			server := httptest.NewTLSServer(http.HandlerFunc(func(response http.ResponseWriter, _ *http.Request) {
				calls.Add(1)
				response.WriteHeader(test.status)
				_, _ = response.Write([]byte(test.body))
			}))
			defer server.Close()

			cfg := modelRouterTestConfig(t, server.URL+"/v1", 3)
			router, err := NewModelRouter(cfg, nil)
			if err != nil {
				t.Fatal(err)
			}
			router.clients["provider"] = server.Client()
			_, err = router.Complete(context.Background(), []ChatMessage{{Role: "user", Content: "hello"}})
			var failure *ModelFailure
			if !errors.As(err, &failure) || failure.Code != test.failureCode {
				t.Fatalf("failure = %#v, want %s", err, test.failureCode)
			}
			if calls.Load() != 1 {
				t.Fatalf("permanent failure made %d requests", calls.Load())
			}
		})
	}
}

func TestModelRouterFallsBackOnInvalidResponses(t *testing.T) {
	tests := []struct {
		name string
		body string
	}{
		{name: "malformed", body: `{"choices":`},
		{name: "oversized", body: strings.Repeat("x", maxModelResponseBytes+1)},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			var calls atomic.Int32
			server := httptest.NewTLSServer(http.HandlerFunc(func(response http.ResponseWriter, _ *http.Request) {
				if calls.Add(1) == 1 {
					_, _ = response.Write([]byte(test.body))
					return
				}
				_, _ = response.Write([]byte(`{"choices":[{"message":{"role":"assistant","content":"valid fallback"}}]}`))
			}))
			defer server.Close()

			cfg := modelRouterTestConfig(t, server.URL+"/v1", 0)
			router, err := NewModelRouter(cfg, nil)
			if err != nil {
				t.Fatal(err)
			}
			router.clients["provider"] = server.Client()
			reply, err := router.Complete(context.Background(), []ChatMessage{{Role: "user", Content: "hello"}})
			if err != nil || reply != "valid fallback" || calls.Load() != 2 {
				t.Fatalf("reply=%q calls=%d err=%v", reply, calls.Load(), err)
			}
		})
	}
}

func TestModelRouterRetryWaitIsCancellable(t *testing.T) {
	server := httptest.NewTLSServer(http.HandlerFunc(func(response http.ResponseWriter, _ *http.Request) {
		response.WriteHeader(http.StatusTooManyRequests)
	}))
	defer server.Close()
	cfg := modelRouterTestConfig(t, server.URL+"/v1", 2)
	router, err := NewModelRouter(cfg, nil)
	if err != nil {
		t.Fatal(err)
	}
	router.clients["provider"] = server.Client()
	waiting := make(chan struct{})
	router.wait = func(ctx context.Context, _ time.Duration) error {
		close(waiting)
		<-ctx.Done()
		return ctx.Err()
	}

	ctx, cancel := context.WithCancel(context.Background())
	result := make(chan error, 1)
	go func() {
		_, completeErr := router.Complete(ctx, []ChatMessage{{Role: "user", Content: "hello"}})
		result <- completeErr
	}()
	select {
	case <-waiting:
	case <-time.After(time.Second):
		t.Fatal("router did not enter retry wait")
	}
	cancel()
	select {
	case completeErr := <-result:
		var failure *ModelFailure
		if !errors.As(completeErr, &failure) || failure.Code != ModelFailureCancelled {
			t.Fatalf("cancel failure = %#v", completeErr)
		}
	case <-time.After(time.Second):
		t.Fatal("router did not cancel retry wait")
	}
}

func TestModelRouterEnforcesTaskTimeout(t *testing.T) {
	requestCancelled := make(chan struct{})
	cfg := modelRouterTestConfig(t, "https://provider.example.test/v1", 0)
	cfg.ModelTasks[0].Timeout = time.Second
	router, err := NewModelRouter(cfg, nil)
	if err != nil {
		t.Fatal(err)
	}
	router.clients["provider"] = &http.Client{Transport: roundTripFunc(func(request *http.Request) (*http.Response, error) {
		<-request.Context().Done()
		close(requestCancelled)
		return nil, request.Context().Err()
	})}

	startedAt := time.Now()
	_, err = router.Complete(context.Background(), []ChatMessage{{Role: "user", Content: "hello"}})
	var failure *ModelFailure
	if !errors.As(err, &failure) || failure.Code != ModelFailureDeadline {
		t.Fatalf("task timeout failure = %#v", err)
	}
	if elapsed := time.Since(startedAt); elapsed < 900*time.Millisecond || elapsed > 2*time.Second {
		t.Fatalf("task timeout elapsed = %s", elapsed)
	}
	select {
	case <-requestCancelled:
	case <-time.After(time.Second):
		t.Fatal("task timeout did not cancel provider request")
	}
}

func TestModelRouterCopiesConfigurationIntoSnapshot(t *testing.T) {
	requestStarted := make(chan struct{})
	releaseRequest := make(chan struct{})
	server := httptest.NewTLSServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		close(requestStarted)
		<-releaseRequest
		if request.Header.Get("Authorization") != "Bearer router-secret" {
			t.Errorf("authorization = %q", request.Header.Get("Authorization"))
		}
		var payload struct {
			Model string `json:"model"`
		}
		if err := json.NewDecoder(request.Body).Decode(&payload); err != nil {
			t.Error(err)
		}
		if payload.Model != "primary-remote" {
			t.Errorf("model = %q", payload.Model)
		}
		_, _ = response.Write([]byte(`{"choices":[{"message":{"role":"assistant","content":"snapshot reply"}}]}`))
	}))
	defer server.Close()

	cfg := modelRouterTestConfig(t, server.URL+"/v1", 0)
	cfg.ModelTasks[0].DailyLimit = 11
	router, err := NewModelRouter(cfg, nil)
	if err != nil {
		t.Fatal(err)
	}
	router.clients["provider"] = server.Client()
	result := make(chan error, 1)
	go func() {
		_, completeErr := router.Complete(context.Background(), []ChatMessage{{Role: "user", Content: "hello"}})
		result <- completeErr
	}()
	select {
	case <-requestStarted:
	case <-time.After(time.Second):
		t.Fatal("model request did not start")
	}
	cfg.ModelProviders[0].BaseURL = "https://changed.example.test/v1"
	cfg.ModelProviders[0].APIKey = "changed-secret"
	cfg.ModelDefinitions[0].RemoteName = "changed-model"
	cfg.ModelTasks[0].CandidateModels[0] = "changed-model-id"
	cfg.ModelTasks[0].DailyLimit = 99
	close(releaseRequest)
	if completeErr := <-result; completeErr != nil {
		t.Fatal(completeErr)
	}
	provider, _ := router.Snapshot().Provider("provider")
	model, _ := router.Snapshot().Model("primary")
	task, _ := router.Snapshot().Task(ReplyerTaskID)
	if provider.APIKey != "router-secret" || model.RemoteName != "primary-remote" || task.CandidateModels[0] != "primary" || task.DailyLimit != 11 {
		t.Fatalf("snapshot changed with source config: %#v %#v %#v", provider, model, task)
	}
}

func modelRouterTestConfig(t *testing.T, baseURL string, maxRetries int) Config {
	t.Helper()
	cfg := testConfig(t)
	cfg.AIEnabled = true
	cfg.ModelProviders = []ModelProviderConfig{{
		ID: "provider", Protocol: OpenAICompatibleProtocol, BaseURL: baseURL, APIKey: "router-secret",
		Timeout: 5 * time.Second, MaxRetries: maxRetries, RetryBackoff: 50 * time.Millisecond,
	}}
	cfg.ModelDefinitions = []ModelDefinitionConfig{
		{ID: "primary", ProviderID: "provider", RemoteName: "primary-remote", ContextWindow: 128000},
		{
			ID: "fallback", ProviderID: "provider", RemoteName: "fallback-remote", ContextWindow: 128000,
			InputPriceMicrosPerMillionTokens: 2_000_000, OutputPriceMicrosPerMillionTokens: 4_000_000,
		},
	}
	cfg.ModelTasks = []ModelTaskConfig{{
		ID: ReplyerTaskID, Strategy: SequentialModelStrategy, CandidateModels: []string{"primary", "fallback"},
		MaxOutputTokens: 600, Timeout: 5 * time.Second,
	}}
	return cfg
}

type roundTripFunc func(*http.Request) (*http.Response, error)

func (function roundTripFunc) RoundTrip(request *http.Request) (*http.Response, error) {
	return function(request)
}
