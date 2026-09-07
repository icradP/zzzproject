package fairy

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"sync"
	"time"

	"github.com/icradp/zzz-im-server/internal/protocol"
)

const (
	terminalBridgeToolName     = "terminal.run"
	terminalToolOutputBytes    = 48 * 1024
	terminalToolMaxCommandSize = 8192
)

// terminalResultPayload is deliberately kept separate from protocol message
// types. It is data returned by an untrusted client and is only fed back into
// the Planner as an untrusted tool result.
type terminalResultPayload struct {
	RequestID string `json:"request_id"`
	Operation string `json:"operation,omitempty"`
	Status    string `json:"status"`
	Summary   string `json:"summary,omitempty"`
	Output    string `json:"output,omitempty"`
	ExitCode  *int   `json:"exit_code,omitempty"`
}

// TerminalRequestBroker pairs a request sent by Fairy with the result message
// returned by an online ZZZTerm client. The broker never executes commands or
// receives credentials; it only transports an explicitly approved result.
type TerminalRequestBroker struct {
	mu        sync.Mutex
	messenger *reliableMessenger
	pending   map[string]chan terminalResultPayload
	now       func() time.Time
}

func NewTerminalRequestBroker() *TerminalRequestBroker {
	return &TerminalRequestBroker{
		pending: make(map[string]chan terminalResultPayload),
		now:     time.Now,
	}
}

func (b *TerminalRequestBroker) Attach(messenger *reliableMessenger) {
	if b == nil {
		return
	}
	b.mu.Lock()
	b.messenger = messenger
	b.mu.Unlock()
}

func (b *TerminalRequestBroker) Submit(
	ctx context.Context,
	scope ToolScope,
	operation, hostID, command string,
) (terminalResultPayload, error) {
	if b == nil {
		return terminalResultPayload{}, errors.New("terminal bridge is unavailable")
	}
	if ctx == nil {
		ctx = context.Background()
	}
	if scope.MessageType == "group" || strings.HasPrefix(scope.ConversationID, "group_") {
		return terminalResultPayload{}, errors.New("terminal operations are only available in private conversations")
	}
	if strings.TrimSpace(scope.ConversationID) == "" {
		return terminalResultPayload{}, errors.New("terminal conversation is missing")
	}
	operation = strings.TrimSpace(operation)
	hostID = strings.TrimSpace(hostID)
	command = strings.TrimSpace(command)
	switch operation {
	case "list_hosts":
	case "get_host":
		if hostID == "" || len(hostID) > 128 {
			return terminalResultPayload{}, errors.New("host_id is required")
		}
	case "run_command":
		if hostID == "" || len(hostID) > 128 || command == "" || len(command) > terminalToolMaxCommandSize {
			return terminalResultPayload{}, errors.New("run_command requires a valid host_id and command")
		}
		if containsSensitiveCredential(command) {
			return terminalResultPayload{}, errors.New("command contains sensitive credential material")
		}
	default:
		return terminalResultPayload{}, fmt.Errorf("unsupported terminal operation %q", operation)
	}

	requestID, err := newRuntimeID("term")
	if err != nil {
		return terminalResultPayload{}, err
	}
	expiresAt := b.now().Add(terminalRequestTTL)
	resultCh := make(chan terminalResultPayload, 2)
	b.mu.Lock()
	messenger := b.messenger
	b.pending[requestID] = resultCh
	b.mu.Unlock()
	defer func() {
		b.mu.Lock()
		delete(b.pending, requestID)
		b.mu.Unlock()
	}()
	if messenger == nil {
		return terminalResultPayload{}, errors.New("no Fairy IM connection is available")
	}
	label := terminalOperationLabel(operation, hostID, command)
	segments := []protocol.MessageSegment{
		protocol.TextSegment(label + "\n请在同账号在线的 ZZZ Term 中确认；请求 2 分钟后失效。"),
		protocol.TerminalRequestSegment(requestID, operation, hostID, command, expiresAt.UnixMilli()),
	}
	if err := messenger.SendSegments(ctx, scope.ConversationID, segments); err != nil {
		return terminalResultPayload{}, fmt.Errorf("send terminal request: %w", err)
	}
	for {
		select {
		case <-ctx.Done():
			return terminalResultPayload{}, ctx.Err()
		case result := <-resultCh:
			if result.Status == "approved" {
				continue
			}
			return result, nil
		}
	}
}

func (b *TerminalRequestBroker) Complete(event messageEvent, fairyUserID string) bool {
	if b == nil || event.MessageType != "private" || event.ConversationID == "" || event.Sender.UserID == "" || event.Sender.UserID == fairyUserID {
		return false
	}
	matched := false
	for _, segment := range event.Message {
		if segment.Type != "terminal_result" {
			continue
		}
		payloadBytes, err := json.Marshal(segment.Data)
		if err != nil {
			continue
		}
		var result terminalResultPayload
		if json.Unmarshal(payloadBytes, &result) != nil || !validTerminalResult(result) {
			continue
		}
		if result.Summary == "" {
			result.Summary = terminalMessageSummary(event.Message)
		}
		matched = true
		b.mu.Lock()
		channel := b.pending[result.RequestID]
		b.mu.Unlock()
		if channel == nil {
			continue
		}
		select {
		case channel <- result:
		default:
		}
	}
	return matched
}

func terminalMessageSummary(segments []protocol.MessageSegment) string {
	var builder strings.Builder
	for _, segment := range segments {
		if segment.Type != "text" {
			continue
		}
		text, _ := segment.Data["text"].(string)
		text = strings.TrimSpace(text)
		if text == "" {
			continue
		}
		if builder.Len() > 0 {
			builder.WriteString("\n")
		}
		builder.WriteString(text)
	}
	return limitRunes(builder.String(), 4000)
}

func validTerminalResult(result terminalResultPayload) bool {
	if result.RequestID == "" || len(result.RequestID) > 128 || !validTerminalRequestID(result.RequestID) {
		return false
	}
	switch result.Status {
	case "approved", "denied", "expired", "failed", "completed":
	default:
		return false
	}
	return len(result.Output) <= 64*1024 && len(result.Summary) <= 4000
}

func validTerminalRequestID(value string) bool {
	for _, character := range value {
		if character >= 'a' && character <= 'z' || character >= 'A' && character <= 'Z' ||
			character >= '0' && character <= '9' || character == '.' || character == ':' ||
			character == '-' || character == '_' {
			continue
		}
		return false
	}
	return true
}

type terminalBridgeTool struct {
	broker *TerminalRequestBroker
}

func (t *terminalBridgeTool) Spec() ToolSpec {
	return ToolSpec{
		Name:           terminalBridgeToolName,
		Description:    "Request a host listing, public host details, or run a command in an already connected ZZZTerm SSH session. Command execution always requires explicit Allow in ZZZTerm; never create connections or select credentials.",
		InputSchema:    json.RawMessage(`{"type":"object","properties":{"operation":{"type":"string","minLength":1,"maxLength":32},"host_id":{"type":"string","maxLength":128},"command":{"type":"string","maxLength":8192}},"required":["operation"],"additionalProperties":false}`),
		OutputSchema:   json.RawMessage(`{"type":"object","properties":{"request_id":{"type":"string","maxLength":128},"operation":{"type":"string","maxLength":32},"status":{"type":"string","maxLength":16},"summary":{"type":"string","maxLength":4000},"output":{"type":"string","maxLength":49152},"exit_code":{"type":"integer"}},"required":["request_id","operation","status","summary","output"],"additionalProperties":false}`),
		Risk:           RiskLow,
		Concurrency:    ToolSerial,
		Idempotency:    ToolReadOnly,
		ReplyMode:      ToolReplyViaModel,
		Timeout:        terminalRequestTTL,
		MaxInputBytes:  16 * 1024,
		MaxOutputBytes: 64 * 1024,
	}
}

func (t *terminalBridgeTool) Execute(ctx context.Context, arguments json.RawMessage) (json.RawMessage, error) {
	return t.execute(ctx, ToolScope{}, arguments)
}

func (t *terminalBridgeTool) ExecuteScoped(ctx context.Context, scope ToolScope, arguments json.RawMessage) (json.RawMessage, error) {
	return t.execute(ctx, scope, arguments)
}

func (t *terminalBridgeTool) execute(ctx context.Context, scope ToolScope, arguments json.RawMessage) (json.RawMessage, error) {
	var input struct {
		Operation string `json:"operation"`
		HostID    string `json:"host_id"`
		Command   string `json:"command"`
	}
	if err := json.Unmarshal(arguments, &input); err != nil {
		return nil, err
	}
	result, err := t.broker.Submit(ctx, scope, input.Operation, input.HostID, input.Command)
	if err != nil {
		return nil, err
	}
	result.Operation = strings.TrimSpace(input.Operation)
	if result.Summary == "" {
		result.Summary = terminalResultSummary(result.Status)
	}
	if result.Output == "" {
		result.Output = ""
	}
	if len(result.Output) > terminalToolOutputBytes {
		result.Output = truncateUTF8(result.Output, terminalToolOutputBytes)
	}
	return json.Marshal(result)
}

func (t *terminalBridgeTool) Project(output json.RawMessage) (ToolProjection, error) {
	var result terminalResultPayload
	if err := json.Unmarshal(output, &result); err != nil {
		return ToolProjection{}, err
	}
	modelText, _ := json.Marshal(result)
	userText := strings.TrimSpace(result.Summary)
	if result.Output != "" {
		userText += "\n\n" + result.Output
	}
	return ToolProjection{ModelText: string(modelText), UserText: strings.TrimSpace(userText)}, nil
}

func terminalOperationLabel(operation, hostID, command string) string {
	switch operation {
	case "list_hosts":
		return "Fairy 请求列出 ZZZTerm 主机"
	case "get_host":
		return fmt.Sprintf("Fairy 请求读取主机 %s 的公开信息", hostID)
	case "run_command":
		return fmt.Sprintf("Fairy 请求在主机 %s 执行：%s", hostID, limitRunes(command, 240))
	default:
		return "Fairy 请求执行终端操作"
	}
}

func terminalResultSummary(status string) string {
	switch status {
	case "completed":
		return "Terminal operation completed."
	case "denied":
		return "The user denied this terminal request."
	case "expired":
		return "The terminal request expired before approval."
	case "failed":
		return "The terminal operation failed."
	default:
		return "Terminal operation returned a result."
	}
}

func truncateUTF8(value string, maxBytes int) string {
	if maxBytes <= 0 || len(value) <= maxBytes {
		return value
	}
	for maxBytes > 0 && (value[maxBytes]&0xc0) == 0x80 {
		maxBytes--
	}
	return value[:maxBytes]
}

var _ PluginToolProvider = (*TerminalBridgePlugin)(nil)
var _ ToolIntentMatcher = (*TerminalBridgePlugin)(nil)
var _ ScopedTool = (*terminalBridgeTool)(nil)
