package fairy

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"

	"github.com/icradp/zzz-im-server/internal/protocol"
)

const DynamicContentPluginID = "dynamic-content"

// DynamicContentPlugin exposes a model-facing producer for controlled
// Dynamic Content. It transports the model's JSON tree; the gateway remains
// the authority that validates and persists the message.
type DynamicContentPlugin struct {
	messenger *reliableMessenger
}

func NewDynamicContentPlugin() *DynamicContentPlugin {
	return &DynamicContentPlugin{}
}

func (p *DynamicContentPlugin) Name() string             { return DynamicContentPluginID }
func (p *DynamicContentPlugin) Match(PluginRequest) bool { return false }
func (p *DynamicContentPlugin) Handle(context.Context, PluginRequest) (string, error) {
	return "", nil
}

func (p *DynamicContentPlugin) Tools() []Tool {
	if p == nil {
		return nil
	}
	return []Tool{&dynamicContentTool{plugin: p}}
}

func (p *DynamicContentPlugin) attachMessenger(messenger *reliableMessenger) {
	if p != nil {
		p.messenger = messenger
	}
}

type dynamicContentTool struct {
	plugin *DynamicContentPlugin
}

func (t *dynamicContentTool) Spec() ToolSpec {
	return ToolSpec{
		Name:         "dynamic_content.create",
		Description:  "Send a controlled Dynamic Content bubble for this Fairy reply. Use markdown for tables/code/long read-only output, or card/row/column/progress/status/button/input/checkbox/select for structured or interactive UI. Shared vote/read/ack/approval state can be declared in metadata.interaction. The tree is data only and never executes code.",
		InputSchema:  json.RawMessage(`{"type":"object","properties":{"content":{"type":"object"},"text":{"type":"string","maxLength":2000}},"required":["content"],"additionalProperties":false}`),
		OutputSchema: json.RawMessage(`{"type":"object","properties":{"status":{"type":"string"},"sent":{"type":"boolean"}},"required":["status","sent"],"additionalProperties":false}`),
		Risk:         RiskLow, Concurrency: ToolSerial, Idempotency: ToolReadOnly,
		ReplyMode: ToolReplyViaModel, Timeout: defaultToolTimeout,
		MaxInputBytes: 512 * 1024, MaxOutputBytes: 1024,
	}
}

func (t *dynamicContentTool) Execute(ctx context.Context, arguments json.RawMessage) (json.RawMessage, error) {
	return t.execute(ctx, ToolScope{}, arguments)
}

func (t *dynamicContentTool) ExecuteScoped(ctx context.Context, scope ToolScope, arguments json.RawMessage) (json.RawMessage, error) {
	return t.execute(ctx, scope, arguments)
}

func (t *dynamicContentTool) execute(ctx context.Context, scope ToolScope, arguments json.RawMessage) (json.RawMessage, error) {
	if t == nil || t.plugin == nil || t.plugin.messenger == nil {
		return nil, errors.New("dynamic content delivery is unavailable")
	}
	if strings.TrimSpace(scope.ConversationID) == "" {
		return nil, errors.New("dynamic content conversation is missing")
	}
	var input struct {
		Content map[string]interface{} `json:"content"`
		Text    string                 `json:"text"`
	}
	if err := json.Unmarshal(arguments, &input); err != nil {
		return nil, fmt.Errorf("invalid dynamic content arguments: %w", err)
	}
	if input.Content == nil {
		return nil, errors.New("dynamic content is required")
	}
	content := cloneDynamicContentMap(input.Content)
	// The producer identity is trusted and cannot be overridden by model data.
	content["source"] = "ai"
	if err := t.plugin.messenger.SendSegments(ctx, scope.ConversationID, dynamicContentSegments(content, input.Text)); err != nil {
		return nil, err
	}
	return json.Marshal(map[string]interface{}{"status": "sent", "sent": true})
}

func (t *dynamicContentTool) Project(output json.RawMessage) (ToolProjection, error) {
	var result map[string]interface{}
	if err := json.Unmarshal(output, &result); err != nil {
		return ToolProjection{}, err
	}
	encoded, _ := json.Marshal(result)
	return ToolProjection{ModelText: string(encoded)}, nil
}

func dynamicContentSegments(content map[string]interface{}, text string) []protocol.MessageSegment {
	segments := make([]protocol.MessageSegment, 0, 2)
	if value := strings.TrimSpace(text); value != "" {
		segments = append(segments, protocol.TextSegment(value))
	}
	segments = append(segments, protocol.DynamicContentSegment(content))
	return segments
}

func cloneDynamicContentMap(value map[string]interface{}) map[string]interface{} {
	encoded, err := json.Marshal(value)
	if err != nil {
		return map[string]interface{}{}
	}
	var cloned map[string]interface{}
	if err := json.Unmarshal(encoded, &cloned); err != nil || cloned == nil {
		return map[string]interface{}{}
	}
	return cloned
}

var _ PluginToolProvider = (*DynamicContentPlugin)(nil)
var _ ScopedTool = (*dynamicContentTool)(nil)
