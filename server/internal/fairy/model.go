package fairy

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"math/rand"
	"mime"
	"mime/multipart"
	"net"
	"net/http"
	"net/textproto"
	"strings"
	"time"
)

const maxModelResponseBytes = 2 * 1024 * 1024

const (
	maxModelMessages      = 128
	maxModelMessageBytes  = 256 * 1024
	maxModelTools         = 32
	maxModelToolCalls     = 6
	maxModelToolArguments = 32 * 1024
	modelToolFunctionType = "function"
	modelResponseJSONType = "json_object"
)

type Model interface {
	Complete(ctx context.Context, messages []ChatMessage) (string, error)
}

type TaskModel interface {
	CompleteTask(ctx context.Context, taskID string, messages []ChatMessage) (string, error)
}

type ToolAwareModel interface {
	CompleteRequest(ctx context.Context, request ModelRequest) (ModelResponse, error)
}

type ModelTaskInspector interface {
	HasTask(taskID string) bool
}

type TranscriptionModel interface {
	Transcribe(ctx context.Context, audio ModelBinaryInput) (string, error)
}

type ModelBinaryInput struct {
	MIMEType string
	Name     string
	Data     []byte
}

type ModelToolDefinition struct {
	Name        string          `json:"name"`
	Description string          `json:"description"`
	Parameters  json.RawMessage `json:"parameters"`
}

type ModelToolFunction struct {
	Name      string `json:"name"`
	Arguments string `json:"arguments"`
}

type ModelToolCall struct {
	ID       string            `json:"id"`
	Type     string            `json:"type"`
	Function ModelToolFunction `json:"function"`
}

type ModelRequest struct {
	TaskID        string
	Messages      []ChatMessage
	Images        []ModelBinaryInput
	Tools         []ModelToolDefinition
	RequireJSON   bool
	Step          int
	PromptVersion string
	PromptDigest  string
}

type ModelResponse struct {
	Text      string
	ToolCalls []ModelToolCall
}

type ModelFailureCode string

const (
	ModelFailureCancelled       ModelFailureCode = "cancelled"
	ModelFailureDeadline        ModelFailureCode = "deadline_exceeded"
	ModelFailureNetwork         ModelFailureCode = "network_error"
	ModelFailureRateLimited     ModelFailureCode = "rate_limited"
	ModelFailureServer          ModelFailureCode = "provider_server_error"
	ModelFailureAuthentication  ModelFailureCode = "authentication_error"
	ModelFailureInvalidRequest  ModelFailureCode = "invalid_request"
	ModelFailureContentRejected ModelFailureCode = "content_rejected"
	ModelFailureInvalidResponse ModelFailureCode = "invalid_response"
)

type ModelFailure struct {
	Code            ModelFailureCode
	ProviderID      string
	ModelID         string
	TaskID          string
	HTTPStatus      int
	Attempt         int
	Retryable       bool
	FallbackAllowed bool
	cause           error
}

func (f *ModelFailure) Error() string {
	if f == nil {
		return "Fairy model request failed"
	}
	return fmt.Sprintf("Fairy model task %s failed with %s", f.TaskID, f.Code)
}

func (f *ModelFailure) Unwrap() error {
	if f == nil {
		return nil
	}
	return f.cause
}

type ModelUsage struct {
	InputTokens  int
	OutputTokens int
}

type ProviderSnapshot struct {
	ID           string
	Protocol     string
	BaseURL      string
	APIKey       string
	Timeout      time.Duration
	MaxRetries   int
	RetryBackoff time.Duration
}

type ModelSnapshot struct {
	ID                                string
	ProviderID                        string
	RemoteName                        string
	ContextWindow                     int
	InputPriceMicrosPerMillionTokens  int64
	OutputPriceMicrosPerMillionTokens int64
}

type TaskSnapshot struct {
	ID              string
	Strategy        string
	CandidateModels []string
	MaxOutputTokens int
	Timeout         time.Duration
	DailyLimit      int
}

type RuntimeModelSnapshot struct {
	ID        string
	providers map[string]ProviderSnapshot
	models    map[string]ModelSnapshot
	tasks     map[string]TaskSnapshot
}

func (s RuntimeModelSnapshot) Provider(id string) (ProviderSnapshot, bool) {
	provider, ok := s.providers[id]
	return provider, ok
}

func (s RuntimeModelSnapshot) Model(id string) (ModelSnapshot, bool) {
	model, ok := s.models[id]
	return model, ok
}

func (s RuntimeModelSnapshot) Task(id string) (TaskSnapshot, bool) {
	task, ok := s.tasks[id]
	task.CandidateModels = append([]string(nil), task.CandidateModels...)
	return task, ok
}

type modelCompletion struct {
	Response ModelResponse
	Usage    ModelUsage
}

type ModelRouter struct {
	snapshot RuntimeModelSnapshot
	clients  map[string]*http.Client
	trace    TraceStore
	wait     func(context.Context, time.Duration) error
	jitter   func(time.Duration) time.Duration
}

func NewModelRouter(cfg Config, trace TraceStore) (*ModelRouter, error) {
	if err := normalizeModelConfiguration(&cfg); err != nil {
		return nil, err
	}
	if err := cfg.Validate(); err != nil {
		return nil, err
	}
	if !cfg.ModelEnabled() {
		return nil, fmt.Errorf("Fairy replyer task is not configured")
	}
	snapshotID, err := newRuntimeID("snapshot")
	if err != nil {
		return nil, err
	}
	snapshot := RuntimeModelSnapshot{
		ID:        snapshotID,
		providers: make(map[string]ProviderSnapshot, len(cfg.ModelProviders)),
		models:    make(map[string]ModelSnapshot, len(cfg.ModelDefinitions)),
		tasks:     make(map[string]TaskSnapshot, len(cfg.ModelTasks)),
	}
	clients := make(map[string]*http.Client, len(cfg.ModelProviders))
	for _, provider := range cfg.ModelProviders {
		snapshot.providers[provider.ID] = ProviderSnapshot{
			ID: provider.ID, Protocol: provider.Protocol, BaseURL: provider.BaseURL, APIKey: provider.APIKey,
			Timeout: provider.Timeout, MaxRetries: provider.MaxRetries, RetryBackoff: provider.RetryBackoff,
		}
		clients[provider.ID] = &http.Client{
			Timeout:       provider.Timeout,
			CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
		}
	}
	for _, model := range cfg.ModelDefinitions {
		snapshot.models[model.ID] = ModelSnapshot{
			ID: model.ID, ProviderID: model.ProviderID, RemoteName: model.RemoteName,
			ContextWindow:                     model.ContextWindow,
			InputPriceMicrosPerMillionTokens:  model.InputPriceMicrosPerMillionTokens,
			OutputPriceMicrosPerMillionTokens: model.OutputPriceMicrosPerMillionTokens,
		}
	}
	for _, task := range cfg.ModelTasks {
		snapshot.tasks[task.ID] = TaskSnapshot{
			ID: task.ID, Strategy: task.Strategy,
			CandidateModels: append([]string(nil), task.CandidateModels...),
			MaxOutputTokens: task.MaxOutputTokens, Timeout: task.Timeout, DailyLimit: task.DailyLimit,
		}
	}
	return &ModelRouter{
		snapshot: snapshot,
		clients:  clients,
		trace:    trace,
		wait:     waitForModelRetry,
		jitter: func(delay time.Duration) time.Duration {
			if delay <= 0 {
				return 0
			}
			return time.Duration(rand.Int63n(int64(delay/4 + 1)))
		},
	}, nil
}

func (r *ModelRouter) Snapshot() RuntimeModelSnapshot {
	return r.snapshot
}

func (r *ModelRouter) Complete(ctx context.Context, messages []ChatMessage) (string, error) {
	return r.CompleteTask(ctx, ReplyerTaskID, messages)
}

func (r *ModelRouter) CompleteTask(ctx context.Context, taskID string, messages []ChatMessage) (string, error) {
	response, err := r.CompleteRequest(ctx, ModelRequest{TaskID: taskID, Messages: messages})
	if err != nil {
		return "", err
	}
	if len(response.ToolCalls) != 0 || strings.TrimSpace(response.Text) == "" {
		return "", &ModelFailure{Code: ModelFailureInvalidResponse, TaskID: taskID}
	}
	return response.Text, nil
}

func (r *ModelRouter) HasTask(taskID string) bool {
	_, exists := r.snapshot.tasks[taskID]
	return exists
}

func (r *ModelRouter) CompleteRequest(ctx context.Context, request ModelRequest) (ModelResponse, error) {
	request = cloneModelRequest(request)
	if err := validateModelRequest(request); err != nil {
		return ModelResponse{}, &ModelFailure{Code: ModelFailureInvalidRequest, TaskID: request.TaskID, cause: err}
	}
	task, exists := r.snapshot.tasks[request.TaskID]
	if !exists {
		return ModelResponse{}, &ModelFailure{Code: ModelFailureInvalidRequest, TaskID: request.TaskID}
	}
	taskContext, cancel := context.WithTimeout(ctx, task.Timeout)
	defer cancel()
	traceScope, _ := turnTraceScopeFromContext(taskContext)
	if traceScope.TraceID == "" && r.trace != nil {
		var err error
		traceScope.TraceID, err = newRuntimeID("trace")
		if err != nil {
			return ModelResponse{}, err
		}
		traceScope.TurnID, err = newRuntimeID("turn")
		if err != nil {
			return ModelResponse{}, err
		}
		traceScope.Source = "model-router"
	}

	var lastFailure *ModelFailure
	for modelIndex, modelID := range task.CandidateModels {
		model := r.snapshot.models[modelID]
		provider := r.snapshot.providers[model.ProviderID]
		for attempt := 1; attempt <= provider.MaxRetries+1; attempt++ {
			startedAt := time.Now()
			completion, failure := r.completeAttempt(taskContext, provider, model, task, request)
			duration := time.Since(startedAt)
			if failure == nil {
				r.appendModelTrace(traceScope, task, provider, model, request, attempt, modelIndex > 0, duration, completion.Usage, nil)
				return completion.Response, nil
			}
			failure.ProviderID = provider.ID
			failure.ModelID = model.ID
			failure.TaskID = task.ID
			failure.Attempt = attempt
			lastFailure = failure
			r.appendModelTrace(traceScope, task, provider, model, request, attempt, modelIndex > 0, duration, ModelUsage{}, failure)
			if !failure.Retryable || attempt > provider.MaxRetries {
				break
			}
			delay := retryDelay(provider.RetryBackoff, attempt-1) + r.jitter(provider.RetryBackoff)
			if err := r.wait(taskContext, delay); err != nil {
				return ModelResponse{}, cancellationFailure(taskContext, task.ID, provider.ID, model.ID, err)
			}
		}
		if lastFailure == nil || !lastFailure.FallbackAllowed {
			break
		}
	}
	if lastFailure == nil {
		lastFailure = &ModelFailure{Code: ModelFailureInvalidRequest, TaskID: task.ID}
	}
	return ModelResponse{}, lastFailure
}

func (r *ModelRouter) Transcribe(ctx context.Context, audio ModelBinaryInput) (string, error) {
	if err := validateTranscriptionInput(audio); err != nil {
		return "", &ModelFailure{Code: ModelFailureInvalidRequest, TaskID: TranscriberTaskID, cause: err}
	}
	task, exists := r.snapshot.tasks[TranscriberTaskID]
	if !exists {
		return "", &ModelFailure{Code: ModelFailureInvalidRequest, TaskID: TranscriberTaskID}
	}
	taskContext, cancel := context.WithTimeout(ctx, task.Timeout)
	defer cancel()
	traceScope, err := r.modelTraceScope(taskContext)
	if err != nil {
		return "", err
	}
	traceRequest := ModelRequest{TaskID: TranscriberTaskID}
	var lastFailure *ModelFailure
	for modelIndex, modelID := range task.CandidateModels {
		model := r.snapshot.models[modelID]
		provider := r.snapshot.providers[model.ProviderID]
		for attempt := 1; attempt <= provider.MaxRetries+1; attempt++ {
			startedAt := time.Now()
			text, usage, failure := r.transcribeAttempt(taskContext, provider, model, task, audio)
			duration := time.Since(startedAt)
			if failure == nil {
				r.appendModelTrace(traceScope, task, provider, model, traceRequest, attempt, modelIndex > 0, duration, usage, nil)
				return text, nil
			}
			failure.ProviderID = provider.ID
			failure.ModelID = model.ID
			failure.TaskID = task.ID
			failure.Attempt = attempt
			lastFailure = failure
			r.appendModelTrace(traceScope, task, provider, model, traceRequest, attempt, modelIndex > 0, duration, ModelUsage{}, failure)
			if !failure.Retryable || attempt > provider.MaxRetries {
				break
			}
			delay := retryDelay(provider.RetryBackoff, attempt-1) + r.jitter(provider.RetryBackoff)
			if err := r.wait(taskContext, delay); err != nil {
				return "", cancellationFailure(taskContext, task.ID, provider.ID, model.ID, err)
			}
		}
		if lastFailure == nil || !lastFailure.FallbackAllowed {
			break
		}
	}
	if lastFailure == nil {
		lastFailure = &ModelFailure{Code: ModelFailureInvalidRequest, TaskID: task.ID}
	}
	return "", lastFailure
}

func (r *ModelRouter) modelTraceScope(ctx context.Context) (TurnTraceScope, error) {
	traceScope, _ := turnTraceScopeFromContext(ctx)
	if traceScope.TraceID != "" || r.trace == nil {
		return traceScope, nil
	}
	var err error
	traceScope.TraceID, err = newRuntimeID("trace")
	if err != nil {
		return TurnTraceScope{}, err
	}
	traceScope.TurnID, err = newRuntimeID("turn")
	if err != nil {
		return TurnTraceScope{}, err
	}
	traceScope.Source = "model-router"
	return traceScope, nil
}

func (r *ModelRouter) completeAttempt(
	ctx context.Context,
	provider ProviderSnapshot,
	model ModelSnapshot,
	task TaskSnapshot,
	modelRequest ModelRequest,
) (modelCompletion, *ModelFailure) {
	switch provider.Protocol {
	case OpenAICompatibleProtocol:
		return r.completeOpenAICompatibleAttempt(ctx, provider, model, task, modelRequest)
	case AnthropicCompatibleProtocol:
		return r.completeAnthropicCompatibleAttempt(ctx, provider, model, task, modelRequest)
	default:
		return modelCompletion{}, &ModelFailure{Code: ModelFailureInvalidRequest}
	}
}

func (r *ModelRouter) completeOpenAICompatibleAttempt(
	ctx context.Context,
	provider ProviderSnapshot,
	model ModelSnapshot,
	task TaskSnapshot,
	modelRequest ModelRequest,
) (modelCompletion, *ModelFailure) {
	if err := ctx.Err(); err != nil {
		return modelCompletion{}, cancellationFailure(ctx, task.ID, provider.ID, model.ID, err)
	}
	payload := map[string]interface{}{
		"model": model.RemoteName, "messages": modelMessagePayload(modelRequest),
		"max_tokens": task.MaxOutputTokens, "temperature": 0.7,
	}
	if len(modelRequest.Tools) > 0 {
		tools := make([]map[string]interface{}, 0, len(modelRequest.Tools))
		for _, tool := range modelRequest.Tools {
			tools = append(tools, map[string]interface{}{
				"type": modelToolFunctionType,
				"function": map[string]interface{}{
					"name": tool.Name, "description": tool.Description, "parameters": tool.Parameters,
				},
			})
		}
		payload["tools"] = tools
		payload["tool_choice"] = "auto"
	}
	if modelRequest.RequireJSON {
		payload["response_format"] = map[string]string{"type": modelResponseJSONType}
	}
	encodedPayload, err := json.Marshal(payload)
	if err != nil {
		return modelCompletion{}, &ModelFailure{Code: ModelFailureInvalidRequest, cause: err}
	}
	endpoint := strings.TrimRight(provider.BaseURL, "/") + "/chat/completions"
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, bytes.NewReader(encodedPayload))
	if err != nil {
		return modelCompletion{}, &ModelFailure{Code: ModelFailureInvalidRequest, cause: err}
	}
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set("User-Agent", "ZZZ-IM-Fairy/2.0")
	if provider.APIKey != "" {
		request.Header.Set("Authorization", "Bearer "+provider.APIKey)
	}
	response, err := r.clients[provider.ID].Do(request)
	if err != nil {
		if ctx.Err() != nil {
			return modelCompletion{}, cancellationFailure(ctx, task.ID, provider.ID, model.ID, err)
		}
		var networkError net.Error
		code := ModelFailureNetwork
		if errors.As(err, &networkError) && networkError.Timeout() {
			code = ModelFailureDeadline
		}
		return modelCompletion{}, &ModelFailure{Code: code, Retryable: true, FallbackAllowed: true, cause: err}
	}
	defer response.Body.Close()
	body, err := io.ReadAll(io.LimitReader(response.Body, maxModelResponseBytes+1))
	if err != nil {
		return modelCompletion{}, &ModelFailure{Code: ModelFailureNetwork, Retryable: true, FallbackAllowed: true, cause: err}
	}
	if len(body) > maxModelResponseBytes {
		return modelCompletion{}, &ModelFailure{Code: ModelFailureInvalidResponse, FallbackAllowed: true}
	}
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return modelCompletion{}, classifyModelHTTPFailure(response.StatusCode, body)
	}
	var decoded struct {
		Choices []struct {
			Message      ChatMessage `json:"message"`
			FinishReason string      `json:"finish_reason"`
		} `json:"choices"`
		Usage struct {
			PromptTokens     int `json:"prompt_tokens"`
			CompletionTokens int `json:"completion_tokens"`
		} `json:"usage"`
	}
	if err := json.Unmarshal(body, &decoded); err != nil {
		return modelCompletion{}, &ModelFailure{Code: ModelFailureInvalidResponse, FallbackAllowed: true, cause: err}
	}
	if len(decoded.Choices) == 0 {
		return modelCompletion{}, &ModelFailure{Code: ModelFailureInvalidResponse, FallbackAllowed: true}
	}
	if decoded.Choices[0].FinishReason == "content_filter" {
		return modelCompletion{}, &ModelFailure{Code: ModelFailureContentRejected}
	}
	if decoded.Choices[0].FinishReason == "length" {
		return modelCompletion{}, &ModelFailure{Code: ModelFailureInvalidResponse, FallbackAllowed: true}
	}
	message := decoded.Choices[0].Message
	message.Content = strings.TrimSpace(message.Content)
	message.ToolCalls = cloneModelToolCalls(message.ToolCalls)
	if err := validateModelResponse(message.Content, message.ToolCalls, modelRequest.RequireJSON); err != nil {
		return modelCompletion{}, &ModelFailure{Code: ModelFailureInvalidResponse, FallbackAllowed: true, cause: err}
	}
	return modelCompletion{
		Response: ModelResponse{Text: limitRunes(message.Content, 4000), ToolCalls: message.ToolCalls},
		Usage: ModelUsage{
			InputTokens:  validUsageTokens(decoded.Usage.PromptTokens),
			OutputTokens: validUsageTokens(decoded.Usage.CompletionTokens),
		},
	}, nil
}

func (r *ModelRouter) transcribeAttempt(
	ctx context.Context,
	provider ProviderSnapshot,
	model ModelSnapshot,
	task TaskSnapshot,
	audio ModelBinaryInput,
) (string, ModelUsage, *ModelFailure) {
	if err := ctx.Err(); err != nil {
		return "", ModelUsage{}, cancellationFailure(ctx, task.ID, provider.ID, model.ID, err)
	}
	var body bytes.Buffer
	writer := multipart.NewWriter(&body)
	headers := make(textproto.MIMEHeader)
	headers.Set("Content-Disposition", mime.FormatMediaType("form-data", map[string]string{
		"name": "file", "filename": safeMediaUploadName(audio.Name, audio.MIMEType),
	}))
	headers.Set("Content-Type", audio.MIMEType)
	part, err := writer.CreatePart(headers)
	if err == nil {
		_, err = part.Write(audio.Data)
	}
	if err == nil {
		err = writer.WriteField("model", model.RemoteName)
	}
	if err == nil {
		err = writer.WriteField("response_format", "json")
	}
	if closeErr := writer.Close(); err == nil {
		err = closeErr
	}
	if err != nil {
		return "", ModelUsage{}, &ModelFailure{Code: ModelFailureInvalidRequest, cause: err}
	}
	endpoint := strings.TrimRight(provider.BaseURL, "/") + "/audio/transcriptions"
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, bytes.NewReader(body.Bytes()))
	if err != nil {
		return "", ModelUsage{}, &ModelFailure{Code: ModelFailureInvalidRequest, cause: err}
	}
	request.Header.Set("Content-Type", writer.FormDataContentType())
	request.Header.Set("User-Agent", "ZZZ-IM-Fairy/2.0")
	if provider.APIKey != "" {
		request.Header.Set("Authorization", "Bearer "+provider.APIKey)
	}
	response, err := r.clients[provider.ID].Do(request)
	if err != nil {
		if ctx.Err() != nil {
			return "", ModelUsage{}, cancellationFailure(ctx, task.ID, provider.ID, model.ID, err)
		}
		var networkError net.Error
		code := ModelFailureNetwork
		if errors.As(err, &networkError) && networkError.Timeout() {
			code = ModelFailureDeadline
		}
		return "", ModelUsage{}, &ModelFailure{Code: code, Retryable: true, FallbackAllowed: true, cause: err}
	}
	defer response.Body.Close()
	responseBody, err := io.ReadAll(io.LimitReader(response.Body, maxModelResponseBytes+1))
	if err != nil {
		return "", ModelUsage{}, &ModelFailure{Code: ModelFailureNetwork, Retryable: true, FallbackAllowed: true, cause: err}
	}
	if len(responseBody) > maxModelResponseBytes {
		return "", ModelUsage{}, &ModelFailure{Code: ModelFailureInvalidResponse, FallbackAllowed: true}
	}
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return "", ModelUsage{}, classifyModelHTTPFailure(response.StatusCode, responseBody)
	}
	var decoded struct {
		Text  string `json:"text"`
		Usage struct {
			InputTokens  int `json:"input_tokens"`
			OutputTokens int `json:"output_tokens"`
		} `json:"usage"`
	}
	if err := json.Unmarshal(responseBody, &decoded); err != nil {
		return "", ModelUsage{}, &ModelFailure{Code: ModelFailureInvalidResponse, FallbackAllowed: true, cause: err}
	}
	text := strings.TrimSpace(decoded.Text)
	if text == "" || len([]rune(text)) > 8000 {
		return "", ModelUsage{}, &ModelFailure{Code: ModelFailureInvalidResponse, FallbackAllowed: true}
	}
	return text, ModelUsage{
		InputTokens: validUsageTokens(decoded.Usage.InputTokens), OutputTokens: validUsageTokens(decoded.Usage.OutputTokens),
	}, nil
}

func modelMessagePayload(request ModelRequest) interface{} {
	if len(request.Images) == 0 {
		return request.Messages
	}
	messages := make([]interface{}, 0, len(request.Messages))
	lastUser := -1
	for index := range request.Messages {
		if request.Messages[index].Role == "user" {
			lastUser = index
		}
	}
	for index, message := range request.Messages {
		if index != lastUser {
			messages = append(messages, message)
			continue
		}
		content := make([]map[string]interface{}, 0, len(request.Images)+1)
		content = append(content, map[string]interface{}{"type": "text", "text": message.Content})
		for _, image := range request.Images {
			content = append(content, map[string]interface{}{
				"type": "image_url",
				"image_url": map[string]string{
					"url": "data:" + image.MIMEType + ";base64," + base64.StdEncoding.EncodeToString(image.Data),
				},
			})
		}
		messages = append(messages, map[string]interface{}{"role": message.Role, "content": content})
	}
	return messages
}

func (r *ModelRouter) appendModelTrace(
	scope TurnTraceScope,
	task TaskSnapshot,
	provider ProviderSnapshot,
	model ModelSnapshot,
	request ModelRequest,
	attempt int,
	fallback bool,
	duration time.Duration,
	usage ModelUsage,
	failure *ModelFailure,
) {
	if r.trace == nil {
		return
	}
	status := "completed"
	failureCode := ""
	if failure != nil {
		status = "failed"
		failureCode = string(failure.Code)
	}
	event := TraceEvent{
		Time: time.Now(), Type: TraceModelAttempt,
		TraceID: scope.TraceID, TurnID: scope.TurnID, ConversationID: scope.ConversationID,
		Source: scope.Source, Status: status,
		TaskID: task.ID, ProviderID: provider.ID, ModelID: model.ID, SnapshotID: r.snapshot.ID,
		Step: request.Step, PromptVersion: request.PromptVersion, PromptDigest: request.PromptDigest,
		Attempt: attempt, DurationMS: duration.Milliseconds(),
		InputTokens: usage.InputTokens, OutputTokens: usage.OutputTokens,
		CostMicroUSD: modelCostMicroUSD(model, usage), FailureCode: failureCode, Fallback: fallback,
	}
	traceContext, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := r.trace.Append(traceContext, event); err != nil {
		log.Printf("[fairy] append model trace: %v", err)
	}
}

func cloneModelRequest(request ModelRequest) ModelRequest {
	request.Messages = cloneChatMessages(request.Messages)
	request.Images = cloneModelBinaryInputs(request.Images)
	sourceTools := request.Tools
	request.Tools = make([]ModelToolDefinition, len(sourceTools))
	for index, tool := range sourceTools {
		request.Tools[index] = tool
		request.Tools[index].Parameters = append(json.RawMessage(nil), tool.Parameters...)
	}
	return request
}

func cloneModelBinaryInputs(inputs []ModelBinaryInput) []ModelBinaryInput {
	if len(inputs) == 0 {
		return nil
	}
	cloned := make([]ModelBinaryInput, len(inputs))
	for index, input := range inputs {
		cloned[index] = input
		cloned[index].Data = append([]byte(nil), input.Data...)
	}
	return cloned
}

func cloneModelToolCalls(calls []ModelToolCall) []ModelToolCall {
	if len(calls) == 0 {
		return nil
	}
	return append([]ModelToolCall(nil), calls...)
}

func validateModelRequest(request ModelRequest) error {
	if !validTraceLabel(request.TaskID) || request.Step < 0 || request.Step > 64 {
		return fmt.Errorf("invalid Fairy model request metadata")
	}
	if len(request.Messages) == 0 || len(request.Messages) > maxModelMessages || len(request.Tools) > maxModelTools {
		return fmt.Errorf("Fairy model request exceeds message or tool limits")
	}
	if len(request.Images) > 0 {
		if request.TaskID != VisionTaskID || len(request.Images) > maxMediaImages || len(request.Tools) != 0 || request.RequireJSON {
			return fmt.Errorf("invalid Fairy vision request")
		}
		totalImageBytes := 0
		hasUserMessage := false
		for _, message := range request.Messages {
			hasUserMessage = hasUserMessage || message.Role == "user"
		}
		if !hasUserMessage {
			return fmt.Errorf("Fairy vision request requires a user message")
		}
		for _, image := range request.Images {
			if !allowedImageMIME(image.MIMEType) || len(image.Data) == 0 || len(image.Data) > maxMediaImageBytes {
				return fmt.Errorf("invalid Fairy vision image")
			}
			totalImageBytes += len(image.Data)
		}
		if totalImageBytes > maxMediaImageTotal {
			return fmt.Errorf("Fairy vision images are too large")
		}
	}
	if (request.PromptVersion == "") != (request.PromptDigest == "") ||
		request.PromptVersion != "" && (!validTraceLabel(request.PromptVersion) || !validPromptDigest(request.PromptDigest)) {
		return fmt.Errorf("invalid Fairy prompt trace metadata")
	}
	totalBytes := 0
	for _, message := range request.Messages {
		totalBytes += len(message.Content) + len(message.ToolCallID)
		for _, call := range message.ToolCalls {
			totalBytes += len(call.ID) + len(call.Type) + len(call.Function.Name) + len(call.Function.Arguments)
		}
		switch message.Role {
		case "system", "user":
			if strings.TrimSpace(message.Content) == "" || message.ToolCallID != "" || len(message.ToolCalls) != 0 {
				return fmt.Errorf("invalid Fairy %s model message", message.Role)
			}
		case "assistant":
			if strings.TrimSpace(message.Content) == "" && len(message.ToolCalls) == 0 || message.ToolCallID != "" {
				return fmt.Errorf("invalid Fairy assistant model message")
			}
			if err := validateModelToolCalls(message.ToolCalls); err != nil {
				return err
			}
		case "tool":
			if strings.TrimSpace(message.Content) == "" || !validModelToolCallID(message.ToolCallID) || len(message.ToolCalls) != 0 {
				return fmt.Errorf("invalid Fairy tool model message")
			}
		default:
			return fmt.Errorf("invalid Fairy model message role")
		}
	}
	if totalBytes > maxModelMessageBytes {
		return fmt.Errorf("Fairy model message content is too large")
	}
	seenTools := make(map[string]struct{}, len(request.Tools))
	for _, tool := range request.Tools {
		totalBytes += len(tool.Name) + len(tool.Description) + len(tool.Parameters)
		if !validTraceLabel(tool.Name) || strings.TrimSpace(tool.Description) == "" || len(tool.Description) > 2000 ||
			len(tool.Parameters) == 0 || len(tool.Parameters) > maxModelToolArguments || !json.Valid(tool.Parameters) {
			return fmt.Errorf("invalid Fairy model tool definition")
		}
		if _, exists := seenTools[tool.Name]; exists {
			return fmt.Errorf("duplicate Fairy model tool definition")
		}
		seenTools[tool.Name] = struct{}{}
	}
	if totalBytes > maxModelMessageBytes {
		return fmt.Errorf("Fairy model request is too large")
	}
	return nil
}

func validateTranscriptionInput(audio ModelBinaryInput) error {
	returnError := func() error { return fmt.Errorf("invalid Fairy transcription audio") }
	if !allowedAudioMIME(audio.MIMEType) || len(audio.Data) == 0 || len(audio.Data) > maxMediaAudioBytes ||
		len(audio.Name) > 255 || strings.ContainsAny(audio.Name, "\r\n\x00/\\") {
		return returnError()
	}
	return nil
}

func safeMediaUploadName(name, mimeType string) string {
	name = strings.TrimSpace(name)
	if name == "" || len(name) > 255 || strings.ContainsAny(name, "\r\n\x00/\\") {
		kind := mediaInputRecord
		if strings.HasPrefix(mimeType, "image/") {
			kind = mediaInputImage
		}
		return mediaFileName(kind, mimeType)
	}
	return name
}

func validateModelResponse(text string, calls []ModelToolCall, requireJSON bool) error {
	if strings.TrimSpace(text) == "" && len(calls) == 0 {
		return fmt.Errorf("Fairy model returned no content")
	}
	if requireJSON && len(calls) == 0 && !json.Valid([]byte(text)) {
		return fmt.Errorf("Fairy model returned invalid structured JSON")
	}
	return validateModelToolCalls(calls)
}

func validateModelToolCalls(calls []ModelToolCall) error {
	if len(calls) > maxModelToolCalls {
		return fmt.Errorf("Fairy model returned too many tool calls")
	}
	seen := make(map[string]struct{}, len(calls))
	for _, call := range calls {
		if !validModelToolCallID(call.ID) || call.Type != modelToolFunctionType || !validTraceLabel(call.Function.Name) ||
			len(call.Function.Arguments) == 0 || len(call.Function.Arguments) > maxModelToolArguments || !json.Valid([]byte(call.Function.Arguments)) {
			return fmt.Errorf("Fairy model returned an invalid tool call")
		}
		var object map[string]interface{}
		if err := json.Unmarshal([]byte(call.Function.Arguments), &object); err != nil || object == nil {
			return fmt.Errorf("Fairy model tool arguments must be a JSON object")
		}
		if _, exists := seen[call.ID]; exists {
			return fmt.Errorf("Fairy model repeated a tool call ID")
		}
		seen[call.ID] = struct{}{}
	}
	return nil
}

func validModelToolCallID(value string) bool {
	if value == "" || len(value) > 128 {
		return false
	}
	for _, character := range value {
		if character < 0x21 || character > 0x7e {
			return false
		}
	}
	return true
}

func classifyModelHTTPFailure(status int, body []byte) *ModelFailure {
	bodyText := strings.ToLower(string(body))
	if strings.Contains(bodyText, "content_policy") || strings.Contains(bodyText, "content_filter") ||
		strings.Contains(bodyText, "content moderation") {
		return &ModelFailure{Code: ModelFailureContentRejected, HTTPStatus: status}
	}
	switch {
	case status == http.StatusUnauthorized || status == http.StatusForbidden:
		return &ModelFailure{Code: ModelFailureAuthentication, HTTPStatus: status}
	case status == http.StatusTooManyRequests:
		return &ModelFailure{Code: ModelFailureRateLimited, HTTPStatus: status, Retryable: true, FallbackAllowed: true}
	case status == http.StatusRequestTimeout:
		return &ModelFailure{Code: ModelFailureDeadline, HTTPStatus: status, Retryable: true, FallbackAllowed: true}
	case status >= 500:
		return &ModelFailure{Code: ModelFailureServer, HTTPStatus: status, Retryable: true, FallbackAllowed: true}
	default:
		return &ModelFailure{Code: ModelFailureInvalidRequest, HTTPStatus: status}
	}
}

func cancellationFailure(ctx context.Context, taskID, providerID, modelID string, cause error) *ModelFailure {
	code := ModelFailureCancelled
	if errors.Is(ctx.Err(), context.DeadlineExceeded) || errors.Is(cause, context.DeadlineExceeded) {
		code = ModelFailureDeadline
	}
	return &ModelFailure{Code: code, TaskID: taskID, ProviderID: providerID, ModelID: modelID, cause: cause}
}

func retryDelay(base time.Duration, retryIndex int) time.Duration {
	if retryIndex < 0 {
		retryIndex = 0
	}
	delay := base
	for index := 0; index < retryIndex && delay < 5*time.Second; index++ {
		delay *= 2
	}
	if delay > 5*time.Second {
		return 5 * time.Second
	}
	return delay
}

func waitForModelRetry(ctx context.Context, delay time.Duration) error {
	timer := time.NewTimer(delay)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-timer.C:
		return nil
	}
}

func validUsageTokens(value int) int {
	if value < 0 || value > 1_000_000_000 {
		return 0
	}
	return value
}

func modelCostMicroUSD(model ModelSnapshot, usage ModelUsage) int64 {
	return tokenCostMicroUSD(usage.InputTokens, model.InputPriceMicrosPerMillionTokens) +
		tokenCostMicroUSD(usage.OutputTokens, model.OutputPriceMicrosPerMillionTokens)
}

func tokenCostMicroUSD(tokens int, pricePerMillion int64) int64 {
	if tokens <= 0 || pricePerMillion <= 0 {
		return 0
	}
	wholeMillions := int64(tokens) / 1_000_000
	remainder := int64(tokens) % 1_000_000
	return wholeMillions*pricePerMillion + remainder*pricePerMillion/1_000_000
}
