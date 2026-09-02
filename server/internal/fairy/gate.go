package fairy

import (
	"strings"
	"sync"
	"time"
)

type GateAction string

const (
	GateTrigger GateAction = "trigger"
	GateWait    GateAction = "wait"
	GateIgnore  GateAction = "ignore"
	GateReject  GateAction = "reject"
)

const (
	GateReasonPrivateMessage  = "private_message"
	GateReasonExplicitMention = "explicit_mention"
	GateReasonCommand         = "command"
	GateReasonSelfMessage     = "self_message"
	GateReasonInvalidEvent    = "invalid_event"
	GateReasonEmptyText       = "empty_text"
	GateReasonGroupDisabled   = "group_disabled"
	GateReasonGroupNoTrigger  = "group_no_trigger"
	GateReasonSoftDisabled    = "soft_disabled"
	GateReasonSoftShadow      = "soft_shadow"
	GateReasonSoftTrigger     = "soft_trigger"
	GateReasonSoftCooldown    = "soft_cooldown"
	GateReasonFocusConflict   = "focus_conflict"
)

type GateDecision struct {
	Action GateAction `json:"action"`
	Reason string     `json:"reason"`
	Hard   bool       `json:"hard"`
	Shadow bool       `json:"shadow"`
}

type BehaviorConfig struct {
	GroupSoftDefault GroupSoftMode
	FocusTTL         time.Duration
	SoftCooldown     time.Duration
	ExpressionStyle  ExpressionStyle
}

func behaviorConfigFromConfig(cfg Config) BehaviorConfig {
	return BehaviorConfig{
		GroupSoftDefault: cfg.GroupSoftDefault,
		FocusTTL:         cfg.FocusTTL,
		SoftCooldown:     cfg.SoftCooldown,
		ExpressionStyle:  cfg.ExpressionStyle,
	}
}

type conversationFocus struct {
	senderID   string
	expiresAt  time.Time
	lastSoftAt time.Time
}

type MessageGate struct {
	mu      sync.Mutex
	userID  string
	state   *StateStore
	focuses map[string]conversationFocus
}

func NewMessageGate(userID string, state *StateStore) *MessageGate {
	return &MessageGate{userID: userID, state: state, focuses: make(map[string]conversationFocus)}
}

// Evaluate is deterministic for a fixed snapshot. commit is false during the
// ingress preflight and true after the turn has entered its conversation queue.
func (g *MessageGate) Evaluate(event messageEvent, behavior BehaviorConfig, now time.Time, commit bool) GateDecision {
	if event.Sender.UserID == "" || event.ConversationID == "" || event.MessageID == "" {
		return GateDecision{Action: GateReject, Reason: GateReasonInvalidEvent}
	}
	if event.Sender.UserID == g.userID {
		return GateDecision{Action: GateIgnore, Reason: GateReasonSelfMessage}
	}
	text, mentioned := messageText(event.Message, g.userID)
	text = strings.TrimSpace(text)
	if text == "" && !summarizeMediaInputs(event.Message).present() {
		return GateDecision{Action: GateIgnore, Reason: GateReasonEmptyText}
	}
	isGroup := event.MessageType == "group" || strings.HasPrefix(event.ConversationID, "group_")
	if !isGroup {
		return GateDecision{Action: GateTrigger, Reason: GateReasonPrivateMessage, Hard: true}
	}
	isCommand := text != "" && commandTrigger(text)
	isManagement := false
	if isCommand {
		_, _, isManagement = fairyCommand(normalizeTrigger(text))
	}
	if !isManagement && (g.state == nil || !g.state.GroupEnabled(event.ConversationID)) {
		return GateDecision{Action: GateIgnore, Reason: GateReasonGroupDisabled}
	}
	if isCommand {
		decision := GateDecision{Action: GateTrigger, Reason: GateReasonCommand, Hard: true}
		if commit {
			g.focus(event, behavior, now)
		}
		return decision
	}
	if mentioned {
		decision := GateDecision{Action: GateTrigger, Reason: GateReasonExplicitMention, Hard: true}
		if commit {
			g.focus(event, behavior, now)
		}
		return decision
	}

	mode := behavior.GroupSoftDefault
	if g.state != nil {
		mode = g.state.GroupSoftMode(event.ConversationID)
	}
	if mode == GroupSoftOff {
		return GateDecision{Action: GateIgnore, Reason: GateReasonSoftDisabled}
	}

	g.mu.Lock()
	defer g.mu.Unlock()
	focus, exists := g.focuses[event.ConversationID]
	if !exists || !now.Before(focus.expiresAt) {
		delete(g.focuses, event.ConversationID)
		return GateDecision{Action: GateIgnore, Reason: GateReasonGroupNoTrigger}
	}
	if focus.senderID != event.Sender.UserID {
		return GateDecision{Action: GateWait, Reason: GateReasonFocusConflict}
	}
	if mode == GroupSoftShadow {
		return GateDecision{Action: GateWait, Reason: GateReasonSoftShadow, Shadow: true}
	}
	if behavior.SoftCooldown > 0 && !focus.lastSoftAt.IsZero() && now.Sub(focus.lastSoftAt) < behavior.SoftCooldown {
		return GateDecision{Action: GateWait, Reason: GateReasonSoftCooldown}
	}
	if commit {
		focus.lastSoftAt = now
		focus.expiresAt = now.Add(behavior.FocusTTL)
		g.focuses[event.ConversationID] = focus
	}
	return GateDecision{Action: GateTrigger, Reason: GateReasonSoftTrigger}
}

func (g *MessageGate) focus(event messageEvent, behavior BehaviorConfig, now time.Time) {
	if behavior.FocusTTL <= 0 {
		return
	}
	g.mu.Lock()
	previous := g.focuses[event.ConversationID]
	if previous.senderID != event.Sender.UserID {
		previous.lastSoftAt = time.Time{}
	}
	previous.senderID = event.Sender.UserID
	previous.expiresAt = now.Add(behavior.FocusTTL)
	g.focuses[event.ConversationID] = previous
	for conversationID, focus := range g.focuses {
		if !now.Before(focus.expiresAt) {
			delete(g.focuses, conversationID)
		}
	}
	g.mu.Unlock()
}

func validGateAction(value GateAction) bool {
	switch value {
	case GateTrigger, GateWait, GateIgnore, GateReject:
		return true
	default:
		return false
	}
}

func validGateReason(value string) bool {
	switch value {
	case GateReasonPrivateMessage, GateReasonExplicitMention, GateReasonCommand,
		GateReasonSelfMessage, GateReasonInvalidEvent, GateReasonEmptyText,
		GateReasonGroupDisabled, GateReasonGroupNoTrigger, GateReasonSoftDisabled,
		GateReasonSoftShadow, GateReasonSoftTrigger, GateReasonSoftCooldown,
		GateReasonFocusConflict:
		return true
	default:
		return false
	}
}

func validGateDecision(decision GateDecision) bool {
	if !validGateAction(decision.Action) || !validGateReason(decision.Reason) {
		return false
	}
	switch decision.Reason {
	case GateReasonPrivateMessage, GateReasonExplicitMention, GateReasonCommand:
		return decision.Action == GateTrigger && decision.Hard && !decision.Shadow
	case GateReasonSoftTrigger:
		return decision.Action == GateTrigger && !decision.Hard && !decision.Shadow
	case GateReasonSoftShadow:
		return decision.Action == GateWait && !decision.Hard && decision.Shadow
	case GateReasonSoftCooldown, GateReasonFocusConflict:
		return decision.Action == GateWait && !decision.Hard && !decision.Shadow
	case GateReasonSelfMessage, GateReasonEmptyText, GateReasonGroupDisabled,
		GateReasonGroupNoTrigger, GateReasonSoftDisabled:
		return decision.Action == GateIgnore && !decision.Hard && !decision.Shadow
	case GateReasonInvalidEvent:
		return decision.Action == GateReject && !decision.Hard && !decision.Shadow
	default:
		return false
	}
}
