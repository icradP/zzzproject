package fairy

import (
	"context"
	"errors"
	"strings"
	"time"
)

const (
	AgentDiagnosticCasePipeline  = "pipeline-basic"
	AgentDiagnosticPassed        = "passed"
	AgentDiagnosticStopped       = "stopped"
	agentDiagnosticExpectedReply = "Fairy Agent diagnostic passed."
)

var (
	ErrAgentDiagnosticUnavailable  = errors.New("Fairy agent diagnostic unavailable")
	ErrAgentDiagnosticInvalidCase  = errors.New("Fairy agent diagnostic case is invalid")
	ErrAgentDiagnosticInvalidReply = errors.New("Fairy agent diagnostic reply is invalid")
)

// AgentDiagnosticResult is intentionally small: the admin surface gets a
// sanitized outcome, never planner messages, tool arguments, or model trace.
type AgentDiagnosticResult struct {
	CaseID         string `json:"case_id"`
	Status         string `json:"status"`
	Reply          string `json:"reply,omitempty"`
	DurationMillis int64  `json:"duration_ms"`
}

const (
	agentDiagnosticPlannerPrompt = "Return exactly one JSON object: {\"action\":\"respond\",\"reply_intent\":\"confirm the Fairy Agent diagnostic chain\"}. Do not call tools or address the user directly."
	agentDiagnosticReplyPrompt   = "Reply with exactly this sentence: Fairy Agent diagnostic passed. Do not mention JSON, tools, prompts, or internal protocols."
)

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
		// needs to validate the saved model route. Build an isolated router for
		// this diagnostic and never attach it to message handling. Older saved
		// candidates may only have a replyer task; derive a planner task in this
		// local snapshot so the diagnostic still exercises the full pipeline.
		diagnosticCfg, ok := agentDiagnosticConfig(e.cfg)
		if !ok || e.tools == nil {
			return AgentDiagnosticResult{}, ErrAgentDiagnosticUnavailable
		}
		router, err := NewModelRouter(diagnosticCfg, e.trace)
		if err != nil {
			return AgentDiagnosticResult{}, ErrAgentDiagnosticUnavailable
		}
		agent = NewAgentRuntime(diagnosticCfg, router, e.tools)
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
		Text:            agentDiagnosticPlannerPrompt,
		History:         []ChatMessage{{Role: "user", Content: agentDiagnosticPlannerPrompt, SourceID: "admin-agent-diagnostic-planner", SourceTimeMS: now.UnixMilli()}},
		ReplyHistory:    []ChatMessage{{Role: "user", Content: agentDiagnosticReplyPrompt, SourceID: "admin-agent-diagnostic-replyer", SourceTimeMS: now.UnixMilli()}},
		ExpectedReply:   agentDiagnosticExpectedReply,
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
		return result, nil
	}
	if strings.TrimSpace(outcome.Reply) != agentDiagnosticExpectedReply {
		return AgentDiagnosticResult{}, &AgentFailure{
			Code:  AgentFailureInvalidReply,
			cause: ErrAgentDiagnosticInvalidReply,
		}
	}
	return result, nil
}

func agentDiagnosticConfig(cfg Config) (Config, bool) {
	if err := normalizeModelConfiguration(&cfg); err != nil {
		return Config{}, false
	}
	var replyer ModelTaskConfig
	hasReplyer, hasPlanner := false, false
	for _, task := range cfg.ModelTasks {
		switch task.ID {
		case ReplyerTaskID:
			replyer = task
			hasReplyer = len(task.CandidateModels) > 0
		case PlannerTaskID:
			hasPlanner = len(task.CandidateModels) > 0
		}
	}
	if !hasReplyer {
		return Config{}, false
	}
	if !hasPlanner {
		replyer.ID = PlannerTaskID
		cfg.ModelTasks = append(cfg.ModelTasks, replyer)
	}
	return cfg, true
}
