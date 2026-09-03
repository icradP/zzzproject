package fairy

import (
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	_ "github.com/mattn/go-sqlite3"
)

const (
	traceKeyBytes           = 32
	defaultIngressRetention = 30 * 24 * time.Hour
	maxRecentTraceFailures  = 20
)

type TraceEventType string

const (
	TraceAdmissionAccepted TraceEventType = "admission_accepted"
	TraceAdmissionRejected TraceEventType = "admission_rejected"
	TraceIngressDuplicate  TraceEventType = "ingress_duplicate"
	TraceTurnStarted       TraceEventType = "turn_started"
	TraceTurnCompleted     TraceEventType = "turn_completed"
	TraceTurnCancelled     TraceEventType = "turn_cancelled"
	TraceTurnTimedOut      TraceEventType = "turn_timed_out"
	TraceModelAttempt      TraceEventType = "model_attempt"
	TraceToolCall          TraceEventType = "tool_call"
	TraceGateDecision      TraceEventType = "gate_decision"
)

type TraceEvent struct {
	Time            time.Time
	Type            TraceEventType
	TraceID         string
	TurnID          string
	ConversationID  string
	Source          string
	Status          string
	QueueDepth      int
	Pending         int
	TaskID          string
	ProviderID      string
	ModelID         string
	SnapshotID      string
	Attempt         int
	DurationMS      int64
	InputTokens     int
	OutputTokens    int
	CostMicroUSD    int64
	FailureCode     string
	Fallback        bool
	Repair          bool
	Step            int
	PromptVersion   string
	PromptDigest    string
	ToolCallID      string
	ToolName        string
	ToolRisk        string
	ToolPolicy      string
	ToolStatus      string
	ToolResultBytes int
	GateAction      GateAction
	GateReason      string
	GateHard        bool
	GateShadow      bool
}

type TraceStore interface {
	ClaimIngress(ctx context.Context, source, eventID string, at time.Time) (bool, error)
	Append(ctx context.Context, event TraceEvent) error
	Close() error
}

type TraceRuntimeStats struct {
	WindowHours    int                     `json:"window_hours"`
	ModelAttempts  int                     `json:"model_attempts"`
	ModelCompleted int                     `json:"model_completed"`
	ModelFailed    int                     `json:"model_failed"`
	ModelHealth    []TraceModelHealthStats `json:"model_health"`
	ToolCalls      int                     `json:"tool_calls"`
	ToolCompleted  int                     `json:"tool_completed"`
	ToolFailed     int                     `json:"tool_failed"`
	GateDecisions  int                     `json:"gate_decisions"`
	GateActions    map[string]int          `json:"gate_actions"`
	GateReasons    map[string]int          `json:"gate_reasons"`
	InputTokens    int                     `json:"input_tokens"`
	OutputTokens   int                     `json:"output_tokens"`
	CostMicroUSD   int64                   `json:"cost_microusd"`
	RecentFailures []TraceRecentFailure    `json:"recent_failures"`
}

type TraceModelHealthStats struct {
	TaskID           string         `json:"task_id"`
	ProviderID       string         `json:"provider_id"`
	ModelID          string         `json:"model_id"`
	Attempts         int            `json:"attempts"`
	Completed        int            `json:"completed"`
	Failed           int            `json:"failed"`
	FallbackAttempts int            `json:"fallback_attempts"`
	RepairAttempts   int            `json:"repair_attempts"`
	P50Millis        int64          `json:"p50_ms"`
	P95Millis        int64          `json:"p95_ms"`
	InputTokens      int            `json:"input_tokens"`
	OutputTokens     int            `json:"output_tokens"`
	CostMicroUSD     int64          `json:"cost_microusd"`
	FailureCodes     map[string]int `json:"failure_codes"`
}

type TraceRecentFailure struct {
	OccurredAt   time.Time `json:"occurred_at"`
	Kind         string    `json:"kind"`
	Code         string    `json:"code"`
	TaskID       string    `json:"task_id,omitempty"`
	ProviderID   string    `json:"provider_id,omitempty"`
	ModelID      string    `json:"model_id,omitempty"`
	ToolName     string    `json:"tool_name,omitempty"`
	ToolStatus   string    `json:"tool_status,omitempty"`
	DurationMS   int64     `json:"duration_ms,omitempty"`
	Attempt      int       `json:"attempt,omitempty"`
	Step         int       `json:"step,omitempty"`
	Fallback     bool      `json:"fallback,omitempty"`
	Repair       bool      `json:"repair,omitempty"`
	QueueDepth   int       `json:"queue_depth,omitempty"`
	PendingTurns int       `json:"pending_turns,omitempty"`
}

type TraceStatsReader interface {
	RuntimeStats(ctx context.Context, since time.Time) (TraceRuntimeStats, error)
}

type SQLiteTraceStore struct {
	db            *sql.DB
	key           []byte
	retention     time.Duration
	cleanupMu     sync.Mutex
	nextCleanupAt time.Time
}

func OpenSQLiteTraceStore(databasePath, keyPath string) (*SQLiteTraceStore, error) {
	if err := ensurePrivateDirectory(filepath.Dir(databasePath)); err != nil {
		return nil, fmt.Errorf("prepare Fairy trace database directory: %w", err)
	}
	if err := ensurePrivateDirectory(filepath.Dir(keyPath)); err != nil {
		return nil, fmt.Errorf("prepare Fairy trace key directory: %w", err)
	}
	key, err := loadOrCreateTraceKey(keyPath)
	if err != nil {
		return nil, err
	}
	absolutePath, err := filepath.Abs(databasePath)
	if err != nil {
		return nil, fmt.Errorf("resolve Fairy trace database path: %w", err)
	}
	databaseFile, err := os.OpenFile(absolutePath, os.O_RDWR|os.O_CREATE, 0o600)
	if err != nil {
		return nil, fmt.Errorf("create Fairy trace database: %w", err)
	}
	if err := databaseFile.Chmod(0o600); err != nil {
		_ = databaseFile.Close()
		return nil, fmt.Errorf("secure Fairy trace database: %w", err)
	}
	if err := databaseFile.Close(); err != nil {
		return nil, fmt.Errorf("close Fairy trace database: %w", err)
	}
	dsn := (&url.URL{
		Scheme:   "file",
		Path:     absolutePath,
		RawQuery: "_busy_timeout=5000&_foreign_keys=on&_journal_mode=WAL",
	}).String()
	database, err := sql.Open("sqlite3", dsn)
	if err != nil {
		return nil, fmt.Errorf("open Fairy trace database: %w", err)
	}
	database.SetMaxOpenConns(1)
	store := &SQLiteTraceStore{db: database, key: key, retention: defaultIngressRetention}
	if err := store.initialize(context.Background()); err != nil {
		_ = database.Close()
		return nil, err
	}
	return store, nil
}

func (s *SQLiteTraceStore) initialize(ctx context.Context) error {
	const schema = `
CREATE TABLE IF NOT EXISTS fairy_ingress_events (
    source TEXT NOT NULL,
    event_id TEXT NOT NULL,
    received_at INTEGER NOT NULL,
    expires_at INTEGER NOT NULL,
    status TEXT NOT NULL,
    PRIMARY KEY (source, event_id)
);
CREATE INDEX IF NOT EXISTS idx_fairy_ingress_expires_at
    ON fairy_ingress_events(expires_at);
CREATE TABLE IF NOT EXISTS fairy_trace_events (
    seq INTEGER PRIMARY KEY AUTOINCREMENT,
    time_ms INTEGER NOT NULL,
    type TEXT NOT NULL,
    trace_id TEXT NOT NULL,
    turn_id TEXT NOT NULL,
    conversation_ref TEXT NOT NULL,
    payload_json TEXT NOT NULL
);
	CREATE INDEX IF NOT EXISTS idx_fairy_trace_time_type
	    ON fairy_trace_events(time_ms, type);
	CREATE TABLE IF NOT EXISTS fairy_feedback_outputs (
	    message_ref TEXT PRIMARY KEY,
	    turn_id TEXT NOT NULL,
	    created_at INTEGER NOT NULL,
	    expires_at INTEGER NOT NULL
	);
	CREATE INDEX IF NOT EXISTS idx_fairy_feedback_outputs_expires_at
	    ON fairy_feedback_outputs(expires_at);
	CREATE TABLE IF NOT EXISTS fairy_feedback_ratings (
	    message_ref TEXT NOT NULL,
	    actor_ref TEXT NOT NULL,
	    label TEXT NOT NULL CHECK(label IN ('positive', 'negative')),
	    rated_at INTEGER NOT NULL,
	    PRIMARY KEY (message_ref, actor_ref),
	    FOREIGN KEY (message_ref) REFERENCES fairy_feedback_outputs(message_ref) ON DELETE CASCADE
	);
	CREATE INDEX IF NOT EXISTS idx_fairy_feedback_ratings_time_label
	    ON fairy_feedback_ratings(rated_at, label);`
	if _, err := s.db.ExecContext(ctx, schema); err != nil {
		return fmt.Errorf("initialize Fairy trace database: %w", err)
	}
	if _, err := s.db.ExecContext(ctx, `DELETE FROM fairy_ingress_events WHERE expires_at <= ?`, time.Now().UnixMilli()); err != nil {
		return fmt.Errorf("prune expired Fairy ingress events: %w", err)
	}
	if _, err := s.db.ExecContext(ctx, `DELETE FROM fairy_trace_events WHERE time_ms <= ?`, time.Now().Add(-s.retention).UnixMilli()); err != nil {
		return fmt.Errorf("prune expired Fairy trace events: %w", err)
	}
	if _, err := s.db.ExecContext(ctx, `DELETE FROM fairy_feedback_outputs WHERE expires_at <= ?`, time.Now().UnixMilli()); err != nil {
		return fmt.Errorf("prune expired Fairy feedback outputs: %w", err)
	}
	s.nextCleanupAt = time.Now().Add(time.Hour)
	return nil
}

func (s *SQLiteTraceStore) ClaimIngress(ctx context.Context, source, eventID string, at time.Time) (bool, error) {
	if !validTraceLabel(source) || eventID == "" || len(eventID) > 1024 {
		return false, fmt.Errorf("Fairy ingress source and event ID are required")
	}
	if at.IsZero() {
		at = time.Now()
	}
	if err := s.pruneIfDue(ctx, at); err != nil {
		return false, err
	}
	transaction, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return false, fmt.Errorf("begin Fairy ingress claim: %w", err)
	}
	defer transaction.Rollback()
	if _, err := transaction.ExecContext(ctx,
		`DELETE FROM fairy_ingress_events WHERE source = ? AND event_id = ? AND expires_at <= ?`,
		source, eventID, at.UnixMilli(),
	); err != nil {
		return false, fmt.Errorf("remove expired Fairy ingress claim: %w", err)
	}
	result, err := transaction.ExecContext(ctx, `
INSERT OR IGNORE INTO fairy_ingress_events(source, event_id, received_at, expires_at, status)
VALUES (?, ?, ?, ?, 'admitted')`,
		source, eventID, at.UnixMilli(), at.Add(s.retention).UnixMilli(),
	)
	if err != nil {
		return false, fmt.Errorf("claim Fairy ingress event: %w", err)
	}
	rows, err := result.RowsAffected()
	if err != nil {
		return false, fmt.Errorf("read Fairy ingress claim result: %w", err)
	}
	if err := transaction.Commit(); err != nil {
		return false, fmt.Errorf("commit Fairy ingress claim: %w", err)
	}
	return rows == 1, nil
}

func (s *SQLiteTraceStore) Append(ctx context.Context, event TraceEvent) error {
	if !validTraceEventType(event.Type) || !validTraceLabel(event.Source) || !validTraceStatus(event.Status) ||
		!validRuntimeID(event.TraceID) || (event.TurnID != "" && !validRuntimeID(event.TurnID)) ||
		!validTraceEventDetails(event) {
		return fmt.Errorf("invalid Fairy trace event metadata")
	}
	if event.Time.IsZero() {
		event.Time = time.Now()
	}
	payload, err := json.Marshal(struct {
		Source          string `json:"source,omitempty"`
		Status          string `json:"status,omitempty"`
		QueueDepth      int    `json:"queue_depth,omitempty"`
		Pending         int    `json:"pending,omitempty"`
		TaskID          string `json:"gen_ai.operation.name,omitempty"`
		ProviderID      string `json:"gen_ai.provider.name,omitempty"`
		ModelID         string `json:"gen_ai.request.model,omitempty"`
		SnapshotID      string `json:"fairy.config.snapshot_id,omitempty"`
		Attempt         int    `json:"fairy.model.attempt,omitempty"`
		DurationMS      int64  `json:"fairy.duration_ms,omitempty"`
		InputTokens     int    `json:"gen_ai.usage.input_tokens,omitempty"`
		OutputTokens    int    `json:"gen_ai.usage.output_tokens,omitempty"`
		CostMicroUSD    int64  `json:"fairy.cost_microusd,omitempty"`
		FailureCode     string `json:"error.type,omitempty"`
		Fallback        bool   `json:"fairy.model.fallback,omitempty"`
		Repair          bool   `json:"fairy.model.repair,omitempty"`
		Step            int    `json:"fairy.step,omitempty"`
		PromptVersion   string `json:"fairy.prompt.version,omitempty"`
		PromptDigest    string `json:"fairy.prompt.digest,omitempty"`
		ToolCallID      string `json:"gen_ai.tool.call.id,omitempty"`
		ToolName        string `json:"gen_ai.tool.name,omitempty"`
		ToolRisk        string `json:"fairy.tool.risk,omitempty"`
		ToolPolicy      string `json:"fairy.tool.policy,omitempty"`
		ToolStatus      string `json:"fairy.tool.status,omitempty"`
		ToolResultBytes int    `json:"fairy.tool.result_bytes,omitempty"`
		GateAction      string `json:"fairy.gate.action,omitempty"`
		GateReason      string `json:"fairy.gate.reason,omitempty"`
		GateHard        bool   `json:"fairy.gate.hard,omitempty"`
		GateShadow      bool   `json:"fairy.gate.shadow,omitempty"`
	}{
		Source:          event.Source,
		Status:          event.Status,
		QueueDepth:      event.QueueDepth,
		Pending:         event.Pending,
		TaskID:          event.TaskID,
		ProviderID:      event.ProviderID,
		ModelID:         event.ModelID,
		SnapshotID:      event.SnapshotID,
		Attempt:         event.Attempt,
		DurationMS:      event.DurationMS,
		InputTokens:     event.InputTokens,
		OutputTokens:    event.OutputTokens,
		CostMicroUSD:    event.CostMicroUSD,
		FailureCode:     event.FailureCode,
		Fallback:        event.Fallback,
		Repair:          event.Repair,
		Step:            event.Step,
		PromptVersion:   event.PromptVersion,
		PromptDigest:    event.PromptDigest,
		ToolCallID:      event.ToolCallID,
		ToolName:        event.ToolName,
		ToolRisk:        event.ToolRisk,
		ToolPolicy:      event.ToolPolicy,
		ToolStatus:      event.ToolStatus,
		ToolResultBytes: event.ToolResultBytes,
		GateAction:      string(event.GateAction),
		GateReason:      event.GateReason,
		GateHard:        event.GateHard,
		GateShadow:      event.GateShadow,
	})
	if err != nil {
		return fmt.Errorf("encode Fairy trace payload: %w", err)
	}
	_, err = s.db.ExecContext(ctx, `
INSERT INTO fairy_trace_events(time_ms, type, trace_id, turn_id, conversation_ref, payload_json)
VALUES (?, ?, ?, ?, ?, ?)`,
		event.Time.UnixMilli(), string(event.Type), event.TraceID, event.TurnID,
		s.conversationRef(event.ConversationID), string(payload),
	)
	if err != nil {
		return fmt.Errorf("append Fairy trace event: %w", err)
	}
	return nil
}

func (s *SQLiteTraceStore) Close() error {
	return s.db.Close()
}

func (s *SQLiteTraceStore) RuntimeStats(ctx context.Context, since time.Time) (TraceRuntimeStats, error) {
	if since.IsZero() {
		since = time.Now().Add(-24 * time.Hour)
	}
	stats := TraceRuntimeStats{
		WindowHours:    24,
		GateActions:    make(map[string]int),
		GateReasons:    make(map[string]int),
		ModelHealth:    make([]TraceModelHealthStats, 0),
		RecentFailures: make([]TraceRecentFailure, 0),
	}
	modelHealth := make(map[traceModelHealthKey]*traceModelHealthAccumulator)
	rows, err := s.db.QueryContext(ctx, `
	SELECT time_ms, type, payload_json
	FROM fairy_trace_events
	WHERE time_ms >= ? AND type IN (?, ?, ?, ?, ?)
	ORDER BY time_ms DESC, seq DESC`, since.UnixMilli(), string(TraceModelAttempt), string(TraceToolCall), string(TraceGateDecision),
		string(TraceAdmissionRejected), string(TraceTurnTimedOut))
	if err != nil {
		return TraceRuntimeStats{}, fmt.Errorf("query Fairy runtime trace stats: %w", err)
	}
	defer rows.Close()
	for rows.Next() {
		var timeMS int64
		var eventType string
		var payloadJSON string
		if err := rows.Scan(&timeMS, &eventType, &payloadJSON); err != nil {
			return TraceRuntimeStats{}, fmt.Errorf("scan Fairy runtime trace stats: %w", err)
		}
		var payload traceRuntimeStatsPayload
		if err := json.Unmarshal([]byte(payloadJSON), &payload); err != nil {
			return TraceRuntimeStats{}, fmt.Errorf("decode Fairy runtime trace stats: %w", err)
		}
		switch TraceEventType(eventType) {
		case TraceModelAttempt:
			if !validTraceModelHealthPayload(payload) {
				return TraceRuntimeStats{}, fmt.Errorf("invalid Fairy model metadata in trace store")
			}
			stats.ModelAttempts++
			stats.InputTokens += payload.InputTokens
			stats.OutputTokens += payload.OutputTokens
			stats.CostMicroUSD += payload.CostMicroUSD
			if payload.Status == "completed" {
				stats.ModelCompleted++
			} else {
				stats.ModelFailed++
			}
			recordTraceModelHealth(modelHealth, payload)
			if payload.Status == "failed" {
				appendTraceRecentFailure(&stats, timeMS, TraceModelAttempt, payload)
			}
		case TraceToolCall:
			if !validTraceToolRuntimePayload(payload) {
				return TraceRuntimeStats{}, fmt.Errorf("invalid Fairy tool metadata in trace store")
			}
			stats.ToolCalls++
			if payload.Status == "completed" {
				stats.ToolCompleted++
			} else {
				stats.ToolFailed++
				appendTraceRecentFailure(&stats, timeMS, TraceToolCall, payload)
			}
		case TraceGateDecision:
			if !validGateAction(GateAction(payload.GateAction)) || !validGateReason(payload.GateReason) {
				return TraceRuntimeStats{}, fmt.Errorf("invalid Fairy gate metadata in trace store")
			}
			stats.GateDecisions++
			stats.GateActions[payload.GateAction]++
			stats.GateReasons[payload.GateReason]++
		case TraceAdmissionRejected:
			if !validTraceAdmissionFailurePayload(payload) {
				return TraceRuntimeStats{}, fmt.Errorf("invalid Fairy admission metadata in trace store")
			}
			appendTraceRecentFailure(&stats, timeMS, TraceAdmissionRejected, payload)
		case TraceTurnTimedOut:
			if !validTraceTurnFailurePayload(payload) {
				return TraceRuntimeStats{}, fmt.Errorf("invalid Fairy turn metadata in trace store")
			}
			appendTraceRecentFailure(&stats, timeMS, TraceTurnTimedOut, payload)
		}
	}
	if err := rows.Err(); err != nil {
		return TraceRuntimeStats{}, fmt.Errorf("iterate Fairy runtime trace stats: %w", err)
	}
	stats.ModelHealth = finalizeTraceModelHealth(modelHealth)
	return stats, nil
}

type traceRuntimeStatsPayload struct {
	Status          string `json:"status"`
	QueueDepth      int    `json:"queue_depth"`
	Pending         int    `json:"pending"`
	TaskID          string `json:"gen_ai.operation.name"`
	ProviderID      string `json:"gen_ai.provider.name"`
	ModelID         string `json:"gen_ai.request.model"`
	Attempt         int    `json:"fairy.model.attempt"`
	DurationMS      int64  `json:"fairy.duration_ms"`
	InputTokens     int    `json:"gen_ai.usage.input_tokens"`
	OutputTokens    int    `json:"gen_ai.usage.output_tokens"`
	CostMicroUSD    int64  `json:"fairy.cost_microusd"`
	FailureCode     string `json:"error.type"`
	Fallback        bool   `json:"fairy.model.fallback"`
	Repair          bool   `json:"fairy.model.repair"`
	Step            int    `json:"fairy.step"`
	ToolName        string `json:"gen_ai.tool.name"`
	ToolRisk        string `json:"fairy.tool.risk"`
	ToolPolicy      string `json:"fairy.tool.policy"`
	ToolStatus      string `json:"fairy.tool.status"`
	ToolResultBytes int    `json:"fairy.tool.result_bytes"`
	GateAction      string `json:"fairy.gate.action"`
	GateReason      string `json:"fairy.gate.reason"`
}

type traceModelHealthKey struct {
	TaskID     string
	ProviderID string
	ModelID    string
}

type traceModelHealthAccumulator struct {
	stats     TraceModelHealthStats
	durations []int64
}

func validTraceModelHealthPayload(payload traceRuntimeStatsPayload) bool {
	if !validTraceLabel(payload.TaskID) || !validTraceLabel(payload.ProviderID) || !validTraceLabel(payload.ModelID) ||
		payload.Attempt < 1 || payload.Step < 0 || payload.Step > maxPlannerSteps || payload.DurationMS < 0 ||
		payload.InputTokens < 0 || payload.OutputTokens < 0 || payload.CostMicroUSD < 0 {
		return false
	}
	if payload.Repair && (payload.TaskID != PlannerTaskID && payload.TaskID != ReplyerTaskID || payload.Step < 1) {
		return false
	}
	if payload.Status == "completed" {
		return payload.FailureCode == ""
	}
	return payload.Status == "failed" && validModelFailureCode(ModelFailureCode(payload.FailureCode))
}

func validTraceToolRuntimePayload(payload traceRuntimeStatsPayload) bool {
	if !validTraceLabel(payload.ToolName) || !validToolTraceRisk(payload.ToolRisk) ||
		!validToolTracePolicy(payload.ToolPolicy) || !validToolTraceStatus(payload.ToolStatus) ||
		payload.Step < 0 || payload.Step > maxPlannerSteps || payload.DurationMS < 0 || payload.ToolResultBytes < 0 {
		return false
	}
	if payload.Status == "completed" {
		return payload.ToolStatus == "completed" && payload.ToolPolicy == "allowed" && payload.FailureCode == ""
	}
	return payload.Status == "failed" && payload.ToolStatus != "completed" &&
		validToolFailureCode(ToolFailureCode(payload.FailureCode))
}

func validTraceAdmissionFailurePayload(payload traceRuntimeStatsPayload) bool {
	return (payload.Status == "global_pending_limit" || payload.Status == "conversation_pending_limit") &&
		payload.QueueDepth >= 0 && payload.Pending >= 0
}

func validTraceTurnFailurePayload(payload traceRuntimeStatsPayload) bool {
	return payload.Status == "deadline_exceeded"
}

func appendTraceRecentFailure(stats *TraceRuntimeStats, timeMS int64, eventType TraceEventType, payload traceRuntimeStatsPayload) {
	if len(stats.RecentFailures) >= maxRecentTraceFailures {
		return
	}
	failure := TraceRecentFailure{OccurredAt: time.UnixMilli(timeMS).UTC()}
	switch eventType {
	case TraceModelAttempt:
		failure.Kind = "model"
		failure.Code = payload.FailureCode
		failure.TaskID = payload.TaskID
		failure.ProviderID = payload.ProviderID
		failure.ModelID = payload.ModelID
		failure.DurationMS = payload.DurationMS
		failure.Attempt = payload.Attempt
		failure.Step = payload.Step
		failure.Fallback = payload.Fallback
		failure.Repair = payload.Repair
	case TraceToolCall:
		failure.Kind = "tool"
		failure.Code = payload.FailureCode
		failure.ToolName = payload.ToolName
		failure.ToolStatus = payload.ToolStatus
		failure.DurationMS = payload.DurationMS
		failure.Step = payload.Step
	case TraceAdmissionRejected:
		failure.Kind = "admission"
		failure.Code = payload.Status
		failure.QueueDepth = payload.QueueDepth
		failure.PendingTurns = payload.Pending
	case TraceTurnTimedOut:
		failure.Kind = "turn"
		failure.Code = payload.Status
	default:
		return
	}
	stats.RecentFailures = append(stats.RecentFailures, failure)
}

func recordTraceModelHealth(groups map[traceModelHealthKey]*traceModelHealthAccumulator, payload traceRuntimeStatsPayload) {
	key := traceModelHealthKey{TaskID: payload.TaskID, ProviderID: payload.ProviderID, ModelID: payload.ModelID}
	group := groups[key]
	if group == nil {
		group = &traceModelHealthAccumulator{stats: TraceModelHealthStats{
			TaskID: payload.TaskID, ProviderID: payload.ProviderID, ModelID: payload.ModelID,
			FailureCodes: make(map[string]int),
		}}
		groups[key] = group
	}
	group.stats.Attempts++
	group.stats.InputTokens += payload.InputTokens
	group.stats.OutputTokens += payload.OutputTokens
	group.stats.CostMicroUSD += payload.CostMicroUSD
	group.durations = append(group.durations, payload.DurationMS)
	if payload.Fallback {
		group.stats.FallbackAttempts++
	}
	if payload.Repair {
		group.stats.RepairAttempts++
	}
	if payload.Status == "completed" {
		group.stats.Completed++
		return
	}
	group.stats.Failed++
	group.stats.FailureCodes[payload.FailureCode]++
}

func finalizeTraceModelHealth(groups map[traceModelHealthKey]*traceModelHealthAccumulator) []TraceModelHealthStats {
	result := make([]TraceModelHealthStats, 0, len(groups))
	for _, group := range groups {
		sort.Slice(group.durations, func(left, right int) bool { return group.durations[left] < group.durations[right] })
		group.stats.P50Millis = percentileTraceMillis(group.durations, 0.50)
		group.stats.P95Millis = percentileTraceMillis(group.durations, 0.95)
		result = append(result, group.stats)
	}
	sort.Slice(result, func(left, right int) bool {
		if result[left].TaskID != result[right].TaskID {
			return result[left].TaskID < result[right].TaskID
		}
		if result[left].ProviderID != result[right].ProviderID {
			return result[left].ProviderID < result[right].ProviderID
		}
		return result[left].ModelID < result[right].ModelID
	})
	return result
}

func percentileTraceMillis(values []int64, percentile float64) int64 {
	if len(values) == 0 {
		return 0
	}
	index := int(float64(len(values)-1)*percentile + 0.5)
	if index < 0 {
		index = 0
	}
	if index >= len(values) {
		index = len(values) - 1
	}
	return values[index]
}

func (s *SQLiteTraceStore) DigestPrompt(content []byte) string {
	digest := hmac.New(sha256.New, s.key)
	_, _ = digest.Write(content)
	return "hmac-sha256:" + hex.EncodeToString(digest.Sum(nil))
}

func (s *SQLiteTraceStore) conversationRef(conversationID string) string {
	if conversationID == "" {
		return ""
	}
	digest := hmac.New(sha256.New, s.key)
	_, _ = digest.Write([]byte(conversationID))
	return "hmac-sha256:" + hex.EncodeToString(digest.Sum(nil))
}

func (s *SQLiteTraceStore) pruneIfDue(ctx context.Context, now time.Time) error {
	s.cleanupMu.Lock()
	defer s.cleanupMu.Unlock()
	if now.Before(s.nextCleanupAt) {
		return nil
	}
	if _, err := s.db.ExecContext(ctx, `DELETE FROM fairy_ingress_events WHERE expires_at <= ?`, now.UnixMilli()); err != nil {
		return fmt.Errorf("prune expired Fairy ingress events: %w", err)
	}
	if _, err := s.db.ExecContext(ctx, `DELETE FROM fairy_trace_events WHERE time_ms <= ?`, now.Add(-s.retention).UnixMilli()); err != nil {
		return fmt.Errorf("prune expired Fairy trace events: %w", err)
	}
	if _, err := s.db.ExecContext(ctx, `DELETE FROM fairy_feedback_outputs WHERE expires_at <= ?`, now.UnixMilli()); err != nil {
		return fmt.Errorf("prune expired Fairy feedback outputs: %w", err)
	}
	s.nextCleanupAt = now.Add(time.Hour)
	return nil
}

func ensurePrivateDirectory(path string) error {
	if path == "." || path == "" {
		return nil
	}
	return os.MkdirAll(path, 0o700)
}

func loadOrCreateTraceKey(path string) ([]byte, error) {
	key, err := os.ReadFile(path)
	if err == nil {
		return validateTraceKey(path, key)
	}
	if !errors.Is(err, os.ErrNotExist) {
		return nil, fmt.Errorf("read Fairy trace key: %w", err)
	}
	key = make([]byte, traceKeyBytes)
	if _, err := rand.Read(key); err != nil {
		return nil, fmt.Errorf("generate Fairy trace key: %w", err)
	}
	file, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if errors.Is(err, os.ErrExist) {
		existing, readErr := os.ReadFile(path)
		if readErr != nil {
			return nil, fmt.Errorf("read concurrently created Fairy trace key: %w", readErr)
		}
		return validateTraceKey(path, existing)
	}
	if err != nil {
		return nil, fmt.Errorf("create Fairy trace key: %w", err)
	}
	cleanup := func() {
		_ = file.Close()
		_ = os.Remove(path)
	}
	if _, err := file.Write(key); err != nil {
		cleanup()
		return nil, fmt.Errorf("write Fairy trace key: %w", err)
	}
	if err := file.Sync(); err != nil {
		cleanup()
		return nil, fmt.Errorf("sync Fairy trace key: %w", err)
	}
	if err := file.Close(); err != nil {
		_ = os.Remove(path)
		return nil, fmt.Errorf("close Fairy trace key: %w", err)
	}
	return key, nil
}

func validateTraceKey(path string, key []byte) ([]byte, error) {
	if len(key) != traceKeyBytes {
		return nil, fmt.Errorf("Fairy trace key %s must contain exactly %d bytes", path, traceKeyBytes)
	}
	info, err := os.Stat(path)
	if err != nil {
		return nil, fmt.Errorf("inspect Fairy trace key: %w", err)
	}
	if info.Mode().Perm()&0o077 != 0 {
		return nil, fmt.Errorf("Fairy trace key %s must not be accessible by group or other users", path)
	}
	return append([]byte(nil), key...), nil
}

func validTraceEventType(value TraceEventType) bool {
	switch value {
	case TraceAdmissionAccepted, TraceAdmissionRejected, TraceIngressDuplicate,
		TraceTurnStarted, TraceTurnCompleted, TraceTurnCancelled, TraceTurnTimedOut,
		TraceModelAttempt, TraceToolCall, TraceGateDecision:
		return true
	default:
		return false
	}
}

func validTraceStatus(value string) bool {
	switch value {
	case "admitted", "global_pending_limit", "conversation_pending_limit", "ignored",
		"running", "completed", "failed", "user_cancelled", "deadline_exceeded", "runtime_cancelled",
		string(GateTrigger), string(GateWait), string(GateIgnore), string(GateReject):
		return true
	default:
		return false
	}
}

func validTraceLabel(value string) bool {
	if value == "" || len(value) > 64 {
		return false
	}
	for _, character := range value {
		if character >= 'a' && character <= 'z' || character >= '0' && character <= '9' ||
			character == '-' || character == '_' || character == '.' {
			continue
		}
		return false
	}
	return true
}

func validTraceEventDetails(event TraceEvent) bool {
	if event.QueueDepth < 0 || event.Pending < 0 || event.Attempt < 0 || event.DurationMS < 0 ||
		event.InputTokens < 0 || event.OutputTokens < 0 || event.CostMicroUSD < 0 || event.Step < 0 || event.Step > maxPlannerSteps ||
		event.ToolResultBytes < 0 {
		return false
	}
	if event.Type == TraceGateDecision {
		if !validGateDecision(GateDecision{
			Action: event.GateAction, Reason: event.GateReason, Hard: event.GateHard, Shadow: event.GateShadow,
		}) || event.Status != string(event.GateAction) {
			return false
		}
		return event.QueueDepth == 0 && event.Pending == 0 && event.Attempt == 0 && event.DurationMS == 0 &&
			event.InputTokens == 0 && event.OutputTokens == 0 && event.CostMicroUSD == 0 && event.FailureCode == "" &&
			!event.Fallback && !event.Repair && event.Step == 0 && event.PromptVersion == "" && event.PromptDigest == "" &&
			event.TaskID == "" && event.ProviderID == "" && event.ModelID == "" && event.SnapshotID == "" &&
			event.ToolCallID == "" && event.ToolName == "" && event.ToolRisk == "" && event.ToolPolicy == "" &&
			event.ToolStatus == "" && event.ToolResultBytes == 0
	}
	if event.Type == TraceToolCall {
		if !validRuntimeID(event.ToolCallID) || !validTraceLabel(event.ToolName) ||
			!validToolTraceRisk(event.ToolRisk) || !validToolTracePolicy(event.ToolPolicy) ||
			!validToolTraceStatus(event.ToolStatus) || event.Attempt != 0 || event.InputTokens != 0 ||
			event.OutputTokens != 0 || event.CostMicroUSD != 0 || event.TaskID != "" ||
			event.ProviderID != "" || event.ModelID != "" || event.SnapshotID != "" || event.PromptVersion != "" ||
			event.PromptDigest != "" || event.Fallback || event.Repair || event.GateAction != "" || event.GateReason != "" ||
			event.GateHard || event.GateShadow {
			return false
		}
		if event.Status == "completed" {
			return event.ToolStatus == "completed" && event.ToolPolicy == "allowed" && event.FailureCode == ""
		}
		return event.Status == "failed" && event.ToolStatus != "completed" && validToolFailureCode(ToolFailureCode(event.FailureCode))
	}
	if event.Type != TraceModelAttempt {
		return event.TaskID == "" && event.ProviderID == "" && event.ModelID == "" && event.SnapshotID == "" &&
			event.Attempt == 0 && event.DurationMS == 0 && event.InputTokens == 0 && event.OutputTokens == 0 &&
			event.CostMicroUSD == 0 && event.FailureCode == "" && !event.Fallback && !event.Repair && event.Step == 0 &&
			event.PromptVersion == "" && event.PromptDigest == "" &&
			event.ToolCallID == "" && event.ToolName == "" && event.ToolRisk == "" && event.ToolPolicy == "" &&
			event.ToolStatus == "" && event.ToolResultBytes == 0 && event.GateAction == "" &&
			event.GateReason == "" && !event.GateHard && !event.GateShadow
	}
	if !validTraceLabel(event.TaskID) || !validTraceLabel(event.ProviderID) || !validTraceLabel(event.ModelID) ||
		!validRuntimeID(event.SnapshotID) || event.Attempt < 1 || event.ToolCallID != "" ||
		event.ToolName != "" || event.ToolRisk != "" || event.ToolPolicy != "" || event.ToolStatus != "" ||
		event.ToolResultBytes != 0 || event.GateAction != "" || event.GateReason != "" || event.GateHard || event.GateShadow {
		return false
	}
	if event.Repair && (event.TaskID != PlannerTaskID && event.TaskID != ReplyerTaskID || event.Step < 1) {
		return false
	}
	if (event.PromptVersion == "") != (event.PromptDigest == "") ||
		event.PromptVersion != "" && (!validTraceLabel(event.PromptVersion) || !validPromptDigest(event.PromptDigest)) {
		return false
	}
	if event.Status == "completed" {
		return event.FailureCode == ""
	}
	return event.Status == "failed" && validModelFailureCode(ModelFailureCode(event.FailureCode))
}

func validPromptDigest(value string) bool {
	const prefix = "hmac-sha256:"
	if !strings.HasPrefix(value, prefix) || len(value) != len(prefix)+sha256.Size*2 {
		return false
	}
	_, err := hex.DecodeString(value[len(prefix):])
	return err == nil
}

func validToolTraceRisk(value string) bool {
	return value == string(RiskLow) || value == string(RiskMedium) || value == string(RiskHigh) || value == "unknown"
}

func validToolTracePolicy(value string) bool {
	return value == "allowed" || value == "denied" || value == "not_evaluated"
}

func validToolTraceStatus(value string) bool {
	switch value {
	case "completed", "rejected", "failed", "timed_out", "cancelled":
		return true
	default:
		return false
	}
}

func validToolFailureCode(value ToolFailureCode) bool {
	switch value {
	case ToolFailureNotFound, ToolFailureInvalidArguments, ToolFailureNotVisible,
		ToolFailureUnauthorized, ToolFailurePolicyDenied, ToolFailureLimitExceeded,
		ToolFailureTimeout, ToolFailureCancelled, ToolFailureExecution,
		ToolFailureInvalidOutput, ToolFailureOutputTooLarge:
		return true
	default:
		return false
	}
}

func validModelFailureCode(value ModelFailureCode) bool {
	switch value {
	case ModelFailureCancelled, ModelFailureDeadline, ModelFailureNetwork, ModelFailureRateLimited,
		ModelFailureServer, ModelFailureAuthentication, ModelFailureInvalidRequest,
		ModelFailureContentRejected, ModelFailureInvalidResponse:
		return true
	default:
		return false
	}
}

func validRuntimeID(value string) bool {
	if value == "" || len(value) > 80 {
		return false
	}
	for _, character := range value {
		if character >= 'a' && character <= 'z' || character >= '0' && character <= '9' ||
			character == '-' || character == '_' {
			continue
		}
		return false
	}
	return true
}
