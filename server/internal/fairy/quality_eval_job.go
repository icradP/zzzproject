package fairy

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"sync"
	"time"
)

const (
	QualityEvalJobSchemaVersion = "fairy-quality-eval-job/v1"
	QualityEvalJobIdle          = "idle"
	QualityEvalJobRunning       = "running"
	QualityEvalJobPassed        = "passed"
	QualityEvalJobFailed        = "failed"
	QualityEvalJobError         = "error"
	QualityEvalJobCancelled     = "cancelled"

	qualityEvalAdminTimeout = 4 * time.Minute
)

var ErrModelDiagnosticBusy = errors.New("a Fairy model diagnostic is already running")

type QualityEvalJob struct {
	SchemaVersion string                `json:"schema_version"`
	JobID         string                `json:"job_id,omitempty"`
	ModelID       string                `json:"model_id,omitempty"`
	Status        string                `json:"status"`
	FailureCode   string                `json:"failure_code,omitempty"`
	StartedAt     *time.Time            `json:"started_at,omitempty"`
	CompletedAt   *time.Time            `json:"completed_at,omitempty"`
	Report        *QualityEvalJobReport `json:"report,omitempty"`
}

// QualityEvalJobReport is the minimal management projection of an evaluation.
// It intentionally excludes provider and remote-model identifiers together
// with per-request timings, attempts, and costs.
type QualityEvalJobReport struct {
	SchemaVersion   string                     `json:"schema_version"`
	CorpusVersion   int                        `json:"corpus_version"`
	Passed          bool                       `json:"passed"`
	CaseCount       int                        `json:"case_count"`
	PassedCases     int                        `json:"passed_cases"`
	P50Millis       int64                      `json:"p50_ms"`
	P95Millis       int64                      `json:"p95_ms"`
	InputTokens     int                        `json:"input_tokens"`
	OutputTokens    int                        `json:"output_tokens"`
	CostMicroUSD    int64                      `json:"cost_microusd"`
	CostGateEnabled bool                       `json:"cost_gate_enabled"`
	GateFailures    []string                   `json:"gate_failures"`
	Cases           []QualityEvalJobCaseResult `json:"cases"`
}

type QualityEvalJobCaseResult struct {
	ID           string `json:"id"`
	Passed       bool   `json:"passed"`
	FailureCode  string `json:"failure_code,omitempty"`
	ModelFailure string `json:"model_failure,omitempty"`
}

type qualityEvalRunner func(context.Context, QualityEvalTarget, QualityEvalLimits) (QualityEvalReport, error)

// qualityEvalJobManager runs one fixed-corpus evaluation at a time. It stores
// only the redacted report; provider credentials remain in the goroutine's
// immutable call snapshot and are discarded when the run finishes.
type qualityEvalJobManager struct {
	ctx       context.Context
	slot      chan struct{}
	run       qualityEvalRunner
	mu        sync.RWMutex
	latestJob QualityEvalJob
}

func newQualityEvalJobManager(ctx context.Context, slot chan struct{}) *qualityEvalJobManager {
	if ctx == nil {
		ctx = context.Background()
	}
	return &qualityEvalJobManager{
		ctx: ctx, slot: slot, run: RunQualityEvaluation,
		latestJob: QualityEvalJob{SchemaVersion: QualityEvalJobSchemaVersion, Status: QualityEvalJobIdle},
	}
}

func (m *qualityEvalJobManager) Start(cfg Config, modelID string) (QualityEvalJob, error) {
	target, limits, err := qualityEvalTargetForConfiguredModel(cfg, modelID)
	if err != nil {
		return QualityEvalJob{}, err
	}
	if err := m.ctx.Err(); err != nil {
		return QualityEvalJob{}, fmt.Errorf("Fairy quality evaluator is unavailable")
	}
	select {
	case m.slot <- struct{}{}:
	case <-m.ctx.Done():
		return QualityEvalJob{}, fmt.Errorf("Fairy quality evaluator is unavailable")
	default:
		return QualityEvalJob{}, ErrModelDiagnosticBusy
	}
	jobID, err := newRuntimeID("eval")
	if err != nil {
		<-m.slot
		return QualityEvalJob{}, err
	}
	startedAt := time.Now().UTC()
	job := QualityEvalJob{
		SchemaVersion: QualityEvalJobSchemaVersion,
		JobID:         jobID, ModelID: modelID, Status: QualityEvalJobRunning, StartedAt: &startedAt,
	}
	m.mu.Lock()
	m.latestJob = job
	m.mu.Unlock()
	go m.evaluate(jobID, target, limits)
	return cloneQualityEvalJob(job), nil
}

func (m *qualityEvalJobManager) Snapshot() QualityEvalJob {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return cloneQualityEvalJob(m.latestJob)
}

func (m *qualityEvalJobManager) evaluate(jobID string, target QualityEvalTarget, limits QualityEvalLimits) {
	defer func() { <-m.slot }()
	ctx, cancel := context.WithTimeout(m.ctx, qualityEvalAdminTimeout)
	defer cancel()
	report, err := m.run(ctx, target, limits)
	completedAt := time.Now().UTC()
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.latestJob.JobID != jobID || m.latestJob.Status != QualityEvalJobRunning {
		return
	}
	m.latestJob.CompletedAt = &completedAt
	if err == nil {
		adminReport := newQualityEvalJobReport(report)
		m.latestJob.Report = &adminReport
		if report.Passed {
			m.latestJob.Status = QualityEvalJobPassed
		} else {
			m.latestJob.Status = QualityEvalJobFailed
		}
		return
	}
	switch {
	case errors.Is(err, context.Canceled):
		m.latestJob.Status = QualityEvalJobCancelled
		m.latestJob.FailureCode = string(ModelFailureCancelled)
	case errors.Is(err, context.DeadlineExceeded):
		m.latestJob.Status = QualityEvalJobError
		m.latestJob.FailureCode = string(ModelFailureDeadline)
	default:
		m.latestJob.Status = QualityEvalJobError
		m.latestJob.FailureCode = "evaluation_error"
	}
}

func newQualityEvalJobReport(report QualityEvalReport) QualityEvalJobReport {
	cases := make([]QualityEvalJobCaseResult, 0, len(report.Cases))
	for _, result := range report.Cases {
		cases = append(cases, QualityEvalJobCaseResult{
			ID: result.ID, Passed: result.Passed,
			FailureCode: result.FailureCode, ModelFailure: result.ModelFailure,
		})
	}
	return QualityEvalJobReport{
		SchemaVersion: report.SchemaVersion, CorpusVersion: report.CorpusVersion,
		Passed: report.Passed, CaseCount: report.CaseCount, PassedCases: report.PassedCases,
		P50Millis: report.P50Millis, P95Millis: report.P95Millis,
		InputTokens: report.InputTokens, OutputTokens: report.OutputTokens,
		CostMicroUSD: report.CostMicroUSD, CostGateEnabled: report.CostGateEnabled,
		GateFailures: append([]string(nil), report.GateFailures...), Cases: cases,
	}
}

func qualityEvalTargetForConfiguredModel(cfg Config, modelID string) (QualityEvalTarget, QualityEvalLimits, error) {
	modelID = strings.TrimSpace(modelID)
	if !validModelConfigID(modelID) {
		return QualityEvalTarget{}, QualityEvalLimits{}, fmt.Errorf("invalid Fairy model ID")
	}
	if err := normalizeModelConfiguration(&cfg); err != nil {
		return QualityEvalTarget{}, QualityEvalLimits{}, fmt.Errorf("invalid Fairy model configuration")
	}
	var selectedModel *ModelDefinitionConfig
	for index := range cfg.ModelDefinitions {
		if cfg.ModelDefinitions[index].ID == modelID {
			selectedModel = &cfg.ModelDefinitions[index]
			break
		}
	}
	if selectedModel == nil {
		return QualityEvalTarget{}, QualityEvalLimits{}, fmt.Errorf("Fairy model %q is not configured", modelID)
	}
	var selectedProvider *ModelProviderConfig
	for index := range cfg.ModelProviders {
		if cfg.ModelProviders[index].ID == selectedModel.ProviderID {
			selectedProvider = &cfg.ModelProviders[index]
			break
		}
	}
	if selectedProvider == nil {
		return QualityEvalTarget{}, QualityEvalLimits{}, fmt.Errorf("Fairy model provider is not configured")
	}
	return QualityEvalTarget{
			Protocol: selectedProvider.Protocol, BaseURL: selectedProvider.BaseURL, APIKey: selectedProvider.APIKey,
			RemoteModel: selectedModel.RemoteName, Timeout: selectedProvider.Timeout, MaxOutputTokens: 600,
			InputPriceMicrosPerMillionTokens:  selectedModel.InputPriceMicrosPerMillionTokens,
			OutputPriceMicrosPerMillionTokens: selectedModel.OutputPriceMicrosPerMillionTokens,
		}, QualityEvalLimits{
			MaxP95Latency: 30 * time.Second, MaxInputTokens: 10_000, MaxOutputTokens: 4_000,
		}, nil
}

func cloneQualityEvalJob(value QualityEvalJob) QualityEvalJob {
	cloned := value
	if value.StartedAt != nil {
		startedAt := *value.StartedAt
		cloned.StartedAt = &startedAt
	}
	if value.CompletedAt != nil {
		completedAt := *value.CompletedAt
		cloned.CompletedAt = &completedAt
	}
	if value.Report != nil {
		report := *value.Report
		report.GateFailures = append([]string(nil), value.Report.GateFailures...)
		report.Cases = append([]QualityEvalJobCaseResult(nil), value.Report.Cases...)
		cloned.Report = &report
	}
	return cloned
}
