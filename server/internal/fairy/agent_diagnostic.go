package fairy

import (
	"context"
	"errors"
	"strings"
	"time"
)

const (
	AgentDiagnosticCasePipeline = "pipeline-basic"
	AgentDiagnosticPassed       = "passed"
	AgentDiagnosticStopped      = "stopped"
)

var (
	ErrAgentDiagnosticUnavailable = errors.New("Fairy agent diagnostic unavailable")
	ErrAgentDiagnosticInvalidCase = errors.New("Fairy agent diagnostic case is invalid")
)

// AgentDiagnosticResult is intentionally small: the admin surface gets a
// sanitized outcome, never planner messages, tool arguments, or model trace.
type AgentDiagnosticResult struct {
	CaseID         string `json:"case_id"`
	Status         string `json:"status"`
	Reply          string `json:"reply,omitempty"`
	DurationMillis int64  `json:"duration_ms"`
}

const agentDiagnosticPrompt = "请用一句简短中文确认 Fairy 的 Agent 诊断链路已经收到请求。不要调用工具。"

func (e *Engine) RunAgentDiagnostic(ctx context.Context, caseID string) (AgentDiagnosticResult, error) {
	if strings.TrimSpace(caseID) != AgentDiagnosticCasePipeline {
		return AgentDiagnosticResult{}, ErrAgentDiagnosticInvalidCase
	}
	if e == nil {
		return AgentDiagnosticResult{}, ErrAgentDiagnosticUnavailable
	}
	agent := e.agent
	if agent == nil {
		// Production AI may intentionally be off while an administrator still
		// needs to validate the saved Planner/Replyer route. Build an isolated
		// router for this diagnostic and never attach it to message handling.
		if !e.cfg.ModelConfigured() || e.tools == nil {
			return AgentDiagnosticResult{}, ErrAgentDiagnosticUnavailable
		}
		router, err := NewModelRouter(e.cfg, e.trace)
		if err != nil {
			return AgentDiagnosticResult{}, ErrAgentDiagnosticUnavailable
		}
		agent = NewAgentRuntime(e.cfg, router, e.tools)
		if agent == nil {
			return AgentDiagnosticResult{}, ErrAgentDiagnosticUnavailable
		}
	}
	started := time.Now()
	now := e.now()
	if now.IsZero() {
		now = started
	}
	outcome, err := agent.Run(ctx, AgentInput{
		ConversationID:  "admin:fairy-diagnostic",
		MessageType:     "private",
		SenderID:        "admin-diagnostic",
		Text:            agentDiagnosticPrompt,
		History:         []ChatMessage{{Role: "user", Content: agentDiagnosticPrompt, SourceID: "admin-agent-diagnostic", SourceTimeMS: now.UnixMilli()}},
		VisibleTools:    map[string]bool{},
		Now:             now,
		ExpressionStyle: e.BehaviorConfig().ExpressionStyle,
	})
	if err != nil {
		return AgentDiagnosticResult{}, err
	}
	result := AgentDiagnosticResult{
		CaseID:         AgentDiagnosticCasePipeline,
		Status:         AgentDiagnosticPassed,
		Reply:          outcome.Reply,
		DurationMillis: time.Since(started).Milliseconds(),
	}
	if outcome.Stopped {
		result.Status = AgentDiagnosticStopped
		result.Reply = ""
	}
	return result, nil
}
