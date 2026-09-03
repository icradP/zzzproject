package fairy

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"time"
)

const (
	defaultDecisionChainLimit = 10
	maxDecisionChainLimit     = 50
)

type DecisionChainEvent struct {
	Sequence        int64           `json:"sequence"`
	OccurredAt      time.Time       `json:"occurred_at"`
	Type            TraceEventType  `json:"type"`
	Status          string          `json:"status,omitempty"`
	Source          string          `json:"source,omitempty"`
	QueueDepth      int             `json:"queue_depth,omitempty"`
	Pending         int             `json:"pending,omitempty"`
	TaskID          string          `json:"task_id,omitempty"`
	ProviderID      string          `json:"provider_id,omitempty"`
	ModelID         string          `json:"model_id,omitempty"`
	SnapshotID      string          `json:"snapshot_id,omitempty"`
	Attempt         int             `json:"attempt,omitempty"`
	Step            int             `json:"step,omitempty"`
	Repair          bool            `json:"repair,omitempty"`
	Fallback        bool            `json:"fallback,omitempty"`
	DurationMS      int64           `json:"duration_ms,omitempty"`
	InputTokens     int             `json:"input_tokens,omitempty"`
	OutputTokens    int             `json:"output_tokens,omitempty"`
	CostMicroUSD    int64           `json:"cost_microusd,omitempty"`
	FailureCode     string          `json:"failure_code,omitempty"`
	PromptVersion   string          `json:"prompt_version,omitempty"`
	PromptDigest    string          `json:"prompt_digest,omitempty"`
	ToolCallID      string          `json:"tool_call_id,omitempty"`
	ToolName        string          `json:"tool_name,omitempty"`
	ToolRisk        string          `json:"tool_risk,omitempty"`
	ToolPolicy      string          `json:"tool_policy,omitempty"`
	ToolStatus      string          `json:"tool_status,omitempty"`
	ToolResultBytes int             `json:"tool_result_bytes,omitempty"`
	GateAction      GateAction      `json:"gate_action,omitempty"`
	GateReason      string          `json:"gate_reason,omitempty"`
	GateHard        bool            `json:"gate_hard,omitempty"`
	GateShadow      bool            `json:"gate_shadow,omitempty"`
	Content         string          `json:"content,omitempty"`
	Signature       string          `json:"signature,omitempty"`
	Redacted        bool            `json:"redacted,omitempty"`
	Detail          json.RawMessage `json:"detail,omitempty"`
}

type DecisionChain struct {
	TurnID          string               `json:"turn_id"`
	TraceID         string               `json:"trace_id"`
	ConversationRef string               `json:"conversation_ref"`
	StartedAt       time.Time            `json:"started_at"`
	UpdatedAt       time.Time            `json:"updated_at"`
	Status          string               `json:"status"`
	Events          []DecisionChainEvent `json:"events"`
}

type DecisionChainReader interface {
	ListDecisionChains(context.Context, int) ([]DecisionChain, error)
}

func (s *SQLiteTraceStore) ListDecisionChains(ctx context.Context, limit int) ([]DecisionChain, error) {
	if limit <= 0 {
		limit = defaultDecisionChainLimit
	}
	if limit > maxDecisionChainLimit {
		limit = maxDecisionChainLimit
	}
	rows, err := s.db.QueryContext(ctx, `
SELECT turn_id
FROM fairy_trace_events
WHERE turn_id <> ''
GROUP BY turn_id
ORDER BY MAX(seq) DESC
LIMIT ?`, limit)
	if err != nil {
		return nil, fmt.Errorf("list Fairy decision-chain turns: %w", err)
	}
	turnIDs := make([]string, 0, limit)
	for rows.Next() {
		var turnID string
		if err := rows.Scan(&turnID); err != nil {
			_ = rows.Close()
			return nil, fmt.Errorf("scan Fairy decision-chain turn: %w", err)
		}
		turnIDs = append(turnIDs, turnID)
	}
	if err := rows.Close(); err != nil {
		return nil, fmt.Errorf("close Fairy decision-chain turns: %w", err)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("iterate Fairy decision-chain turns: %w", err)
	}

	chains := make([]DecisionChain, 0, len(turnIDs))
	for _, turnID := range turnIDs {
		chain, err := s.loadDecisionChain(ctx, turnID)
		if err != nil {
			return nil, err
		}
		chains = append(chains, chain)
	}
	return chains, nil
}

func (s *SQLiteTraceStore) loadDecisionChain(ctx context.Context, turnID string) (DecisionChain, error) {
	rows, err := s.db.QueryContext(ctx, `
SELECT seq, time_ms, type, trace_id, conversation_ref, payload_json
FROM fairy_trace_events
WHERE turn_id = ?
ORDER BY seq ASC`, turnID)
	if err != nil {
		return DecisionChain{}, fmt.Errorf("load Fairy decision chain: %w", err)
	}
	defer rows.Close()
	chain := DecisionChain{TurnID: turnID, Status: "running", Events: make([]DecisionChainEvent, 0, 8)}
	for rows.Next() {
		event, traceID, conversationRef, err := scanDecisionChainEvent(rows)
		if err != nil {
			return DecisionChain{}, err
		}
		if chain.TraceID == "" {
			chain.TraceID = traceID
		}
		if chain.ConversationRef == "" {
			chain.ConversationRef = conversationRef
		}
		if chain.StartedAt.IsZero() {
			chain.StartedAt = event.OccurredAt
		}
		chain.UpdatedAt = event.OccurredAt
		switch event.Type {
		case TraceTurnCompleted, TraceTurnCancelled, TraceTurnTimedOut:
			chain.Status = event.Status
		case TraceAdmissionRejected, TraceIngressDuplicate:
			chain.Status = event.Status
		}
		chain.Events = append(chain.Events, event)
	}
	if err := rows.Err(); err != nil {
		return DecisionChain{}, fmt.Errorf("iterate Fairy decision chain: %w", err)
	}
	return chain, nil
}

type decisionEventScanner interface {
	Scan(...interface{}) error
}

func scanDecisionChainEvent(scanner decisionEventScanner) (DecisionChainEvent, string, string, error) {
	var (
		event           DecisionChainEvent
		timeMS          int64
		eventType       string
		traceID         string
		conversationRef string
		payload         []byte
	)
	if err := scanner.Scan(&event.Sequence, &timeMS, &eventType, &traceID, &conversationRef, &payload); err != nil {
		if err == sql.ErrNoRows {
			return event, "", "", err
		}
		return event, "", "", fmt.Errorf("scan Fairy decision-chain event: %w", err)
	}
	var detail struct {
		Source          string          `json:"source"`
		Status          string          `json:"status"`
		QueueDepth      int             `json:"queue_depth"`
		Pending         int             `json:"pending"`
		TaskID          string          `json:"gen_ai.operation.name"`
		ProviderID      string          `json:"gen_ai.provider.name"`
		ModelID         string          `json:"gen_ai.request.model"`
		SnapshotID      string          `json:"fairy.config.snapshot_id"`
		Attempt         int             `json:"fairy.model.attempt"`
		Step            int             `json:"fairy.step"`
		Repair          bool            `json:"fairy.model.repair"`
		Fallback        bool            `json:"fairy.model.fallback"`
		DurationMS      int64           `json:"fairy.duration_ms"`
		InputTokens     int             `json:"gen_ai.usage.input_tokens"`
		OutputTokens    int             `json:"gen_ai.usage.output_tokens"`
		CostMicroUSD    int64           `json:"fairy.cost_microusd"`
		FailureCode     string          `json:"error.type"`
		PromptVersion   string          `json:"fairy.prompt.version"`
		PromptDigest    string          `json:"fairy.prompt.digest"`
		ToolCallID      string          `json:"gen_ai.tool.call.id"`
		ToolName        string          `json:"gen_ai.tool.name"`
		ToolRisk        string          `json:"fairy.tool.risk"`
		ToolPolicy      string          `json:"fairy.tool.policy"`
		ToolStatus      string          `json:"fairy.tool.status"`
		ToolResultBytes int             `json:"fairy.tool.result_bytes"`
		GateAction      GateAction      `json:"fairy.gate.action"`
		GateReason      string          `json:"fairy.gate.reason"`
		GateHard        bool            `json:"fairy.gate.hard"`
		GateShadow      bool            `json:"fairy.gate.shadow"`
		Content         string          `json:"fairy.content"`
		Signature       string          `json:"fairy.signature"`
		Redacted        bool            `json:"fairy.redacted"`
		Detail          json.RawMessage `json:"fairy.detail"`
	}
	if err := json.Unmarshal(payload, &detail); err != nil {
		return event, "", "", fmt.Errorf("decode Fairy decision-chain event: %w", err)
	}
	event.OccurredAt = time.UnixMilli(timeMS).UTC()
	event.Type = TraceEventType(eventType)
	event.Status = detail.Status
	event.Source = detail.Source
	event.QueueDepth = detail.QueueDepth
	event.Pending = detail.Pending
	event.TaskID = detail.TaskID
	event.ProviderID = detail.ProviderID
	event.ModelID = detail.ModelID
	event.SnapshotID = detail.SnapshotID
	event.Attempt = detail.Attempt
	event.Step = detail.Step
	event.Repair = detail.Repair
	event.Fallback = detail.Fallback
	event.DurationMS = detail.DurationMS
	event.InputTokens = detail.InputTokens
	event.OutputTokens = detail.OutputTokens
	event.CostMicroUSD = detail.CostMicroUSD
	event.FailureCode = detail.FailureCode
	event.PromptVersion = detail.PromptVersion
	event.PromptDigest = detail.PromptDigest
	event.ToolCallID = detail.ToolCallID
	event.ToolName = detail.ToolName
	event.ToolRisk = detail.ToolRisk
	event.ToolPolicy = detail.ToolPolicy
	event.ToolStatus = detail.ToolStatus
	event.ToolResultBytes = detail.ToolResultBytes
	event.GateAction = detail.GateAction
	event.GateReason = detail.GateReason
	event.GateHard = detail.GateHard
	event.GateShadow = detail.GateShadow
	event.Content = detail.Content
	event.Signature = detail.Signature
	event.Redacted = detail.Redacted
	event.Detail = detail.Detail
	return event, traceID, conversationRef, nil
}
