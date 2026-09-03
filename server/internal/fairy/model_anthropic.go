package fairy

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"strings"
)

const anthropicVersion = "2023-06-01"

type anthropicRequestPayload struct {
	Model       string               `json:"model"`
	System      string               `json:"system,omitempty"`
	Messages    []anthropicMessage   `json:"messages"`
	Tools       []anthropicTool      `json:"tools,omitempty"`
	ToolChoice  *anthropicToolChoice `json:"tool_choice,omitempty"`
	MaxTokens   int                  `json:"max_tokens"`
	Temperature float64              `json:"temperature"`
}

type anthropicMessage struct {
	Role    string                  `json:"role"`
	Content []anthropicContentBlock `json:"content"`
}

type anthropicContentBlock struct {
	Type      string                `json:"type"`
	Text      string                `json:"text,omitempty"`
	ID        string                `json:"id,omitempty"`
	Name      string                `json:"name,omitempty"`
	Input     json.RawMessage       `json:"input,omitempty"`
	ToolUseID string                `json:"tool_use_id,omitempty"`
	Content   string                `json:"content,omitempty"`
	Thinking  string                `json:"thinking,omitempty"`
	Signature string                `json:"signature,omitempty"`
	Data      string                `json:"data,omitempty"`
	Source    *anthropicImageSource `json:"source,omitempty"`
}

type anthropicImageSource struct {
	Type      string `json:"type"`
	MediaType string `json:"media_type"`
	Data      string `json:"data"`
}

type anthropicTool struct {
	Name        string          `json:"name"`
	Description string          `json:"description"`
	InputSchema json.RawMessage `json:"input_schema"`
}

type anthropicToolChoice struct {
	Type string `json:"type"`
}

type anthropicResponsePayload struct {
	Content    []anthropicContentBlock `json:"content"`
	StopReason string                  `json:"stop_reason"`
	Usage      struct {
		InputTokens  int `json:"input_tokens"`
		OutputTokens int `json:"output_tokens"`
	} `json:"usage"`
}

func (r *ModelRouter) completeAnthropicCompatibleAttempt(
	ctx context.Context,
	provider ProviderSnapshot,
	model ModelSnapshot,
	task TaskSnapshot,
	modelRequest ModelRequest,
) (modelCompletion, *ModelFailure) {
	if err := ctx.Err(); err != nil {
		return modelCompletion{}, cancellationFailure(ctx, task.ID, provider.ID, model.ID, err)
	}
	payload, err := anthropicPayload(model, task, modelRequest)
	if err != nil {
		return modelCompletion{}, &ModelFailure{Code: ModelFailureInvalidRequest, cause: err}
	}
	encodedPayload, err := json.Marshal(payload)
	if err != nil {
		return modelCompletion{}, &ModelFailure{Code: ModelFailureInvalidRequest, cause: err}
	}
	endpoint := strings.TrimRight(provider.BaseURL, "/") + "/v1/messages"
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, bytes.NewReader(encodedPayload))
	if err != nil {
		return modelCompletion{}, &ModelFailure{Code: ModelFailureInvalidRequest, cause: err}
	}
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set("User-Agent", "ZZZ-IM-Fairy/2.0")
	request.Header.Set("anthropic-version", anthropicVersion)
	if provider.APIKey != "" {
		request.Header.Set("x-api-key", provider.APIKey)
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
	var decoded anthropicResponsePayload
	if err := json.Unmarshal(body, &decoded); err != nil {
		return modelCompletion{}, &ModelFailure{Code: ModelFailureInvalidResponse, FallbackAllowed: true, cause: err}
	}
	switch decoded.StopReason {
	case "", "end_turn", "stop_sequence", "tool_use":
	case "refusal":
		return modelCompletion{}, &ModelFailure{Code: ModelFailureContentRejected}
	case "max_tokens", "pause_turn":
		return modelCompletion{}, &ModelFailure{Code: ModelFailureInvalidResponse, FallbackAllowed: true}
	default:
		return modelCompletion{}, &ModelFailure{Code: ModelFailureInvalidResponse, FallbackAllowed: true}
	}
	for _, block := range decoded.Content {
		if block.Type == "refusal" {
			return modelCompletion{}, &ModelFailure{Code: ModelFailureContentRejected}
		}
	}
	result, err := modelResponseFromAnthropic(decoded.Content)
	if err != nil {
		return modelCompletion{}, &ModelFailure{Code: ModelFailureInvalidResponse, FallbackAllowed: true, cause: err}
	}
	if err := validateModelResponse(result.Text, result.ToolCalls, modelRequest.RequireJSON); err != nil {
		return modelCompletion{}, &ModelFailure{Code: ModelFailureInvalidResponse, FallbackAllowed: true, cause: err}
	}
	return modelCompletion{
		Response: ModelResponse{
			Text: limitRunes(result.Text, 4000), ToolCalls: result.ToolCalls,
			Reasoning: result.Reasoning,
		},
		Usage: ModelUsage{
			InputTokens: validUsageTokens(decoded.Usage.InputTokens), OutputTokens: validUsageTokens(decoded.Usage.OutputTokens),
		},
	}, nil
}

func anthropicPayload(model ModelSnapshot, task TaskSnapshot, request ModelRequest) (anthropicRequestPayload, error) {
	system, messages, err := anthropicMessages(request)
	if err != nil {
		return anthropicRequestPayload{}, err
	}
	payload := anthropicRequestPayload{
		Model: model.RemoteName, System: system, Messages: messages,
		MaxTokens: task.MaxOutputTokens, Temperature: 0.7,
	}
	if len(request.Tools) > 0 {
		payload.Tools = make([]anthropicTool, 0, len(request.Tools))
		for _, tool := range request.Tools {
			payload.Tools = append(payload.Tools, anthropicTool{
				Name: tool.Name, Description: tool.Description, InputSchema: append(json.RawMessage(nil), tool.Parameters...),
			})
		}
		payload.ToolChoice = &anthropicToolChoice{Type: "auto"}
	}
	return payload, nil
}

func anthropicMessages(request ModelRequest) (string, []anthropicMessage, error) {
	systemParts := make([]string, 0, 2)
	messages := make([]anthropicMessage, 0, len(request.Messages))
	lastUser := -1
	for index := range request.Messages {
		if request.Messages[index].Role == "user" {
			lastUser = index
		}
	}
	for index, message := range request.Messages {
		if message.Role == "system" {
			systemParts = append(systemParts, message.Content)
			continue
		}
		role := message.Role
		blocks := make([]anthropicContentBlock, 0, 1+len(message.ToolCalls)+len(request.Images))
		switch message.Role {
		case "user":
			blocks = append(blocks, anthropicContentBlock{Type: "text", Text: message.Content})
			if index == lastUser {
				for _, image := range request.Images {
					blocks = append(blocks, anthropicContentBlock{Type: "image", Source: &anthropicImageSource{
						Type: "base64", MediaType: image.MIMEType, Data: base64.StdEncoding.EncodeToString(image.Data),
					}})
				}
			}
		case "assistant":
			if strings.TrimSpace(message.Content) != "" {
				blocks = append(blocks, anthropicContentBlock{Type: "text", Text: message.Content})
			}
			for _, call := range message.ToolCalls {
				var input map[string]interface{}
				if err := json.Unmarshal([]byte(call.Function.Arguments), &input); err != nil || input == nil {
					return "", nil, errors.New("invalid Anthropic tool input")
				}
				encoded, err := json.Marshal(input)
				if err != nil {
					return "", nil, err
				}
				blocks = append(blocks, anthropicContentBlock{
					Type: "tool_use", ID: call.ID, Name: call.Function.Name, Input: encoded,
				})
			}
		case "tool":
			role = "user"
			blocks = append(blocks, anthropicContentBlock{
				Type: "tool_result", ToolUseID: message.ToolCallID, Content: message.Content,
			})
		default:
			return "", nil, errors.New("unsupported Anthropic message role")
		}
		messages = appendAnthropicMessage(messages, role, blocks)
	}
	if len(messages) == 0 {
		return "", nil, errors.New("Anthropic request requires non-system messages")
	}
	return strings.Join(systemParts, "\n\n"), messages, nil
}

func appendAnthropicMessage(messages []anthropicMessage, role string, blocks []anthropicContentBlock) []anthropicMessage {
	if len(messages) > 0 && messages[len(messages)-1].Role == role {
		messages[len(messages)-1].Content = append(messages[len(messages)-1].Content, blocks...)
		return messages
	}
	return append(messages, anthropicMessage{Role: role, Content: blocks})
}

func modelResponseFromAnthropic(blocks []anthropicContentBlock) (ModelResponse, error) {
	texts := make([]string, 0, 1)
	calls := make([]ModelToolCall, 0, 1)
	reasoning := make([]ModelReasoningBlock, 0, 1)
	for _, block := range blocks {
		switch block.Type {
		case "text":
			if value := strings.TrimSpace(block.Text); value != "" {
				texts = append(texts, value)
			}
		case "tool_use":
			if len(block.Input) == 0 {
				return ModelResponse{}, errors.New("Anthropic tool use has no input")
			}
			calls = append(calls, ModelToolCall{
				ID: block.ID, Type: modelToolFunctionType,
				Function: ModelToolFunction{Name: block.Name, Arguments: string(block.Input)},
			})
		case "refusal":
			return ModelResponse{}, errors.New("Anthropic response was refused")
		case "thinking":
			if block.Thinking != "" {
				reasoning = append(reasoning, ModelReasoningBlock{
					Text: block.Thinking, Signature: block.Signature,
				})
			}
		case "redacted_thinking":
			signature := block.Signature
			if signature == "" && block.Data != "" {
				digest := sha256.Sum256([]byte(block.Data))
				signature = "sha256:" + hex.EncodeToString(digest[:])
			}
			reasoning = append(reasoning, ModelReasoningBlock{
				Signature: signature, Redacted: true,
			})
		default:
			return ModelResponse{}, errors.New("unsupported Anthropic response block")
		}
	}
	return ModelResponse{Text: strings.Join(texts, "\n"), ToolCalls: calls, Reasoning: reasoning}, nil
}
