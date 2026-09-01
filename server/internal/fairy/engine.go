package fairy

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"strings"
	"sync"
	"time"

	"github.com/icradp/zzz-im-server/internal/protocol"
)

const helpText = `Fairy 可用指令
/fairy help - 查看帮助
/fairy clear - 清除当前会话的临时上下文
/fairy status - 查看群开关、记忆和 AI 状态
/fairy privacy - 查看隐私说明
/fairy memory on|off - 开启或关闭当前会话的临时记忆
/fairy quota - 查看今日 AI 调用额度
/fairy on|off - 群主或管理员开启/关闭群回复
/zzz <UID> - 查询绝区零公开展示资料

私聊可直接提问；群聊只有 @Fairy 或 /fairy、/zzz 指令会触发。上下文仅保存在 Fairy 进程内存中并会自动过期。`

type botMessenger interface {
	SendText(ctx context.Context, conversationID, messageID, text string) error
	GetGroupMembers(ctx context.Context, groupID string) ([]protocol.GroupMember, error)
}

type Engine struct {
	cfg      Config
	state    *StateStore
	contexts *ContextStore
	model    Model
	plugins  []Plugin
	now      func() time.Time
	rateMu   sync.Mutex
	lastCall map[string]time.Time
}

func NewEngine(cfg Config, state *StateStore, model Model, plugins ...Plugin) *Engine {
	return &Engine{
		cfg:      cfg,
		state:    state,
		contexts: NewContextStore(cfg.ContextTTL, cfg.ContextMessages),
		model:    model,
		plugins:  plugins,
		now:      time.Now,
		lastCall: make(map[string]time.Time),
	}
}

func (e *Engine) HandleMessage(ctx context.Context, messenger botMessenger, event messageEvent) {
	if event.Sender.UserID == "" || event.Sender.UserID == e.cfg.UserID || event.ConversationID == "" {
		return
	}
	text, mentioned := messageText(event.Message, e.cfg.UserID)
	text = strings.TrimSpace(text)
	if text == "" {
		return
	}
	isGroup := event.MessageType == "group" || strings.HasPrefix(event.ConversationID, "group_")
	isCommand := commandTrigger(text)
	if isGroup && !mentioned && !isCommand {
		return
	}
	request := PluginRequest{
		Text:           normalizeTrigger(text),
		ConversationID: event.ConversationID,
		MessageType:    event.MessageType,
		SenderID:       event.Sender.UserID,
		SenderNickname: event.Sender.Nickname,
	}
	if handled := e.handleManagement(ctx, messenger, event, request, isGroup); handled {
		return
	}
	if isGroup && !e.state.GroupEnabled(event.ConversationID) {
		return
	}
	if !e.allow(event.ConversationID+"\x00"+event.Sender.UserID, e.now()) {
		e.reply(ctx, messenger, event, "请求太快了，请稍后再试。")
		return
	}
	for _, plugin := range e.plugins {
		if !plugin.Match(request) {
			continue
		}
		response, err := plugin.Handle(ctx, request)
		if err != nil {
			log.Printf("[fairy] plugin %s failed: %v", plugin.Name(), err)
			e.reply(ctx, messenger, event, "查询暂时失败，请稍后再试。")
			return
		}
		if strings.TrimSpace(response) != "" {
			e.reply(ctx, messenger, event, response)
		}
		return
	}
	if e.model == nil {
		e.reply(ctx, messenger, event, "Fairy 的 AI 对话尚未配置；ZZZ 查询和管理指令仍可使用。发送 /fairy help 查看帮助。")
		return
	}
	prompt := limitRunes(strings.TrimSpace(request.Text), 2000)
	if prompt == "" {
		return
	}
	if containsSensitiveCredential(request.Text) {
		e.reply(ctx, messenger, event, "检测到疑似密码、密钥、Token 或 Cookie。该内容未发送给 AI、未写入临时上下文，也未消耗调用额度。请移除敏感凭据后再试。")
		return
	}
	_, allowed, err := e.state.TakeModelCall(e.now(), e.cfg.ModelDailyLimit)
	if err != nil {
		log.Printf("[fairy] reserve model quota: %v", err)
		e.reply(ctx, messenger, event, "Fairy 暂时无法记录调用额度，请稍后再试。")
		return
	}
	if !allowed {
		e.reply(ctx, messenger, event, "Fairy 今天的 AI 调用额度已经用完，明天再来找我吧。")
		return
	}
	contextKey := event.ConversationID
	memoryEnabled := e.state.ContextEnabled(contextKey)
	history := []ChatMessage{{Role: "user", Content: prompt}}
	if memoryEnabled {
		history = e.contexts.Append(contextKey, e.now(), history...)
	}
	messages := make([]ChatMessage, 0, len(history)+1)
	messages = append(messages, ChatMessage{Role: "system", Content: e.cfg.SystemPrompt})
	messages = append(messages, history...)
	response, err := e.model.Complete(ctx, messages)
	if err != nil {
		log.Printf("[fairy] model completion failed: %v", err)
		e.reply(ctx, messenger, event, "Fairy 暂时无法连接 AI 服务，请稍后再试。")
		return
	}
	response = limitRunes(strings.TrimSpace(response), 4000)
	if response == "" {
		return
	}
	if memoryEnabled {
		e.contexts.Append(contextKey, e.now(), ChatMessage{Role: "assistant", Content: response})
	}
	e.reply(ctx, messenger, event, response)
}

func (e *Engine) handleManagement(
	ctx context.Context,
	messenger botMessenger,
	event messageEvent,
	request PluginRequest,
	isGroup bool,
) bool {
	command, argument, ok := fairyCommand(request.Text)
	if !ok {
		return false
	}
	switch command {
	case "help", "帮助":
		e.reply(ctx, messenger, event, helpText)
		return true
	case "clear", "清除", "清空":
		e.contexts.Clear(event.ConversationID)
		e.reply(ctx, messenger, event, "当前会话的 Fairy 临时上下文已清除。")
		return true
	case "privacy", "隐私":
		e.reply(ctx, messenger, event, fmt.Sprintf(
			"只有私聊中直接发送给 Fairy 的内容，以及群聊中明确 @Fairy 或使用指令的内容才会进入处理流程。临时上下文只保存在 Fairy 进程内存中，最多 %d 条，%s 后自动过期；状态文件只保存开关和额度计数，不保存消息正文。发送 /fairy memory off 可关闭当前会话记忆。",
			e.cfg.ContextMessages,
			formatDuration(e.cfg.ContextTTL),
		))
		return true
	case "quota", "额度":
		used, remaining := e.state.ModelQuotaStatus(e.now(), e.cfg.ModelDailyLimit)
		modelStatus := "AI 已配置"
		if e.model == nil {
			modelStatus = "AI 未配置"
		}
		e.reply(ctx, messenger, event, fmt.Sprintf("%s；今日已用 %d 次，剩余 %d 次（按 UTC 日期重置）。", modelStatus, used, remaining))
		return true
	case "memory", "记忆":
		enabled, valid := parseSwitch(argument)
		if !valid {
			e.reply(ctx, messenger, event, "请使用 /fairy memory on 或 /fairy memory off。")
			return true
		}
		if isGroup {
			admin, err := e.isGroupAdmin(ctx, messenger, event.ConversationID, event.Sender.UserID)
			if err != nil {
				log.Printf("[fairy] load group role: %v", err)
				e.reply(ctx, messenger, event, "暂时无法确认群权限，请稍后再试。")
				return true
			}
			if !admin {
				e.reply(ctx, messenger, event, "只有群主或管理员可以修改 Fairy 群记忆设置。")
				return true
			}
		}
		if err := e.state.SetContextEnabled(event.ConversationID, enabled); err != nil {
			log.Printf("[fairy] persist memory switch: %v", err)
			e.reply(ctx, messenger, event, "保存 Fairy 记忆设置失败，请稍后再试。")
			return true
		}
		if !enabled {
			e.contexts.Clear(event.ConversationID)
			e.reply(ctx, messenger, event, "当前会话的临时记忆已关闭，已有上下文已立即清除；指令和插件仍可使用。")
		} else {
			e.reply(ctx, messenger, event, "当前会话的临时记忆已开启；只会记住明确触发 Fairy 的对话，并按时自动过期。")
		}
		return true
	case "status", "状态":
		groupStatus := "仅私聊"
		if isGroup {
			if e.state.GroupEnabled(event.ConversationID) {
				groupStatus = "群回复已开启"
			} else {
				groupStatus = "群回复已关闭"
			}
		}
		memoryStatus := "临时记忆已关闭"
		if e.state.ContextEnabled(event.ConversationID) {
			memoryStatus = "临时记忆已开启"
		}
		used, remaining := e.state.ModelQuotaStatus(e.now(), e.cfg.ModelDailyLimit)
		modelStatus := fmt.Sprintf("AI 未配置，今日额度已用 %d 次、剩余 %d 次", used, remaining)
		if e.model != nil {
			modelStatus = fmt.Sprintf("AI 已配置，今日额度已用 %d 次、剩余 %d 次", used, remaining)
		}
		e.reply(ctx, messenger, event, groupStatus+"；"+memoryStatus+"；"+modelStatus+"。")
		return true
	case "on", "off", "开启", "关闭":
		if !isGroup {
			e.reply(ctx, messenger, event, "群回复开关只能在群聊中设置。")
			return true
		}
		admin, err := e.isGroupAdmin(ctx, messenger, event.ConversationID, event.Sender.UserID)
		if err != nil {
			log.Printf("[fairy] load group role: %v", err)
			e.reply(ctx, messenger, event, "暂时无法确认群权限，请稍后再试。")
			return true
		}
		if !admin {
			e.reply(ctx, messenger, event, "只有群主或管理员可以修改 Fairy 群回复开关。")
			return true
		}
		enabled := command == "on" || command == "开启"
		if err := e.state.SetGroupEnabled(event.ConversationID, enabled); err != nil {
			log.Printf("[fairy] persist group switch: %v", err)
			e.reply(ctx, messenger, event, "保存群回复设置失败，请稍后再试。")
			return true
		}
		if enabled {
			e.reply(ctx, messenger, event, "Fairy 群回复已开启；普通聊天仍需 @Fairy 才会触发。")
		} else {
			e.reply(ctx, messenger, event, "Fairy 群回复已关闭；管理指令仍然可用。")
		}
		return true
	default:
		if argument == "" && (command == "" || command == "fairy") {
			e.reply(ctx, messenger, event, helpText)
			return true
		}
	}
	return false
}

func (e *Engine) isGroupAdmin(ctx context.Context, messenger botMessenger, groupID, userID string) (bool, error) {
	members, err := messenger.GetGroupMembers(ctx, groupID)
	if err != nil {
		return false, err
	}
	for _, member := range members {
		if member.UserID == userID {
			return member.Role == "owner" || member.Role == "admin", nil
		}
	}
	return false, nil
}

func (e *Engine) allow(key string, now time.Time) bool {
	if e.cfg.RateLimit <= 0 {
		return true
	}
	e.rateMu.Lock()
	defer e.rateMu.Unlock()
	if previous := e.lastCall[key]; !previous.IsZero() && now.Sub(previous) < e.cfg.RateLimit {
		return false
	}
	e.lastCall[key] = now
	for existingKey, previous := range e.lastCall {
		if now.Sub(previous) > 2*e.cfg.ContextTTL {
			delete(e.lastCall, existingKey)
		}
	}
	return true
}

func (e *Engine) reply(ctx context.Context, messenger botMessenger, event messageEvent, text string) {
	replyCtx, cancel := requestTimeout(ctx, 20*time.Second)
	defer cancel()
	if err := messenger.SendText(replyCtx, event.ConversationID, event.MessageID, text); err != nil {
		log.Printf("[fairy] send reply to %s: %v", event.ConversationID, err)
	}
}

func messageText(segments []protocol.MessageSegment, fairyUserID string) (string, bool) {
	var text strings.Builder
	mentioned := false
	for _, segment := range segments {
		switch segment.Type {
		case "text":
			value, _ := segment.Data["text"].(string)
			text.WriteString(value)
		case "at":
			for _, key := range []string{"qq", "user_id", "target_id"} {
				target, _ := segment.Data[key].(string)
				if target == fairyUserID {
					mentioned = true
				}
			}
		}
	}
	return text.String(), mentioned
}

func commandTrigger(text string) bool {
	lower := strings.ToLower(strings.TrimSpace(text))
	return strings.HasPrefix(lower, "/fairy") || strings.HasPrefix(lower, "/zzz") ||
		strings.HasPrefix(lower, "fairy ") || strings.HasPrefix(lower, "zzz查询 ") ||
		strings.HasPrefix(lower, "绝区零查询 ")
}

func normalizeTrigger(text string) string {
	value := strings.TrimSpace(text)
	lower := strings.ToLower(value)
	for _, prefix := range []string{"@fairy", "fairy：", "fairy:", "fairy,"} {
		if strings.HasPrefix(lower, prefix) {
			return strings.TrimSpace(value[len(prefix):])
		}
	}
	return value
}

func fairyCommand(text string) (command string, argument string, ok bool) {
	fields := strings.Fields(strings.TrimSpace(text))
	if len(fields) == 0 {
		return "", "", false
	}
	first := strings.ToLower(fields[0])
	if first != "/fairy" && first != "fairy" {
		return "", "", false
	}
	if len(fields) == 1 {
		return "help", "", true
	}
	return strings.ToLower(fields[1]), strings.Join(fields[2:], " "), true
}

func parseSwitch(value string) (enabled bool, valid bool) {
	switch strings.ToLower(strings.TrimSpace(value)) {
	case "on", "开启", "开":
		return true, true
	case "off", "关闭", "关":
		return false, true
	default:
		return false, false
	}
}

func formatDuration(value time.Duration) string {
	if value%time.Hour == 0 {
		return fmt.Sprintf("%d 小时", int(value/time.Hour))
	}
	if value%time.Minute == 0 {
		return fmt.Sprintf("%d 分钟", int(value/time.Minute))
	}
	return value.String()
}

func decodePostType(payload json.RawMessage) string {
	var envelope struct {
		PostType string `json:"post_type"`
	}
	_ = json.Unmarshal(payload, &envelope)
	return envelope.PostType
}
