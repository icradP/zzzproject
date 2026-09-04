package fairy

import (
	"context"
	"fmt"
	"strings"
	"time"

	"github.com/icradp/zzz-im-server/internal/protocol"
)

const terminalRequestTTL = 2 * time.Minute

type TerminalBridgePlugin struct {
	now func() time.Time
}

func NewTerminalBridgePlugin() *TerminalBridgePlugin {
	return &TerminalBridgePlugin{now: time.Now}
}

func (p *TerminalBridgePlugin) Name() string { return TerminalBridgePluginID }

func (p *TerminalBridgePlugin) Match(request PluginRequest) bool {
	text := strings.TrimSpace(strings.ToLower(request.Text))
	return text == "/term" || strings.HasPrefix(text, "/term ")
}

func (p *TerminalBridgePlugin) Handle(context.Context, PluginRequest) (string, error) {
	return "", nil
}

func (p *TerminalBridgePlugin) HandleInteractive(ctx context.Context, messenger interactiveMessenger, request PluginRequest) (bool, error) {
	if request.MessageType == "group" || strings.HasPrefix(request.ConversationID, "group_") {
		return true, messenger.SendText(ctx, request.ConversationID, request.MessageID, "终端操作仅支持与 Fairy 的私聊。")
	}
	operation, hostID, command, ok := parseTerminalCommand(request.Text)
	if !ok {
		return true, messenger.SendText(ctx, request.ConversationID, request.MessageID,
			"用法：/term hosts；/term info <主机ID>；/term run <主机ID> <命令>。")
	}
	if operation == "run_command" && containsSensitiveCredential(command) {
		return true, messenger.SendText(ctx, request.ConversationID, request.MessageID,
			"检测到命令中包含疑似密码、密钥、Token、Cookie 或私钥。该命令不会发送到 ZZZ Term，也不会生成审批请求。")
	}
	requestID, err := newRuntimeID("term")
	if err != nil {
		return true, err
	}
	label := "请求列出 ZZZ Term 主机"
	switch operation {
	case "get_host":
		label = fmt.Sprintf("请求读取主机 %s 的公开信息", hostID)
	case "run_command":
		label = fmt.Sprintf("请求在主机 %s 执行：%s", hostID, limitRunes(command, 240))
	}
	segments := []protocol.MessageSegment{
		protocol.ReplySegment(request.MessageID),
		protocol.TextSegment(label + "\n请在同账号在线的 ZZZ Term 中确认；请求 2 分钟后失效。"),
		protocol.TerminalRequestSegment(requestID, operation, hostID, command, p.now().Add(terminalRequestTTL).UnixMilli()),
	}
	return true, messenger.SendSegments(ctx, request.ConversationID, segments)
}

func parseTerminalCommand(text string) (operation, hostID, command string, ok bool) {
	parts := strings.Fields(strings.TrimSpace(text))
	if len(parts) == 2 && strings.EqualFold(parts[0], "/term") && strings.EqualFold(parts[1], "hosts") {
		return "list_hosts", "", "", true
	}
	if len(parts) == 3 && strings.EqualFold(parts[0], "/term") && strings.EqualFold(parts[1], "info") && len(parts[2]) <= 128 {
		return "get_host", parts[2], "", true
	}
	if len(parts) >= 4 && strings.EqualFold(parts[0], "/term") && strings.EqualFold(parts[1], "run") && len(parts[2]) <= 128 {
		commandStart := strings.Index(text, parts[2]) + len(parts[2])
		command = strings.TrimSpace(text[commandStart:])
		if command != "" && len(command) <= 8192 {
			return "run_command", parts[2], command, true
		}
	}
	return "", "", "", false
}
