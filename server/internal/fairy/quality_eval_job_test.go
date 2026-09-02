package fairy

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestQualityEvalJobUsesSavedModelSnapshotAndRedactedState(t *testing.T) {
	const secret = "quality-job-secret"
	const baseURL = "https://provider.example.test/anthropic"
	cfg := probeTestConfig(t, baseURL, AnthropicCompatibleProtocol, secret)
	started := make(chan QualityEvalTarget, 1)
	release := make(chan struct{})
	manager := newQualityEvalJobManager(context.Background(), make(chan struct{}, 1))
	manager.run = func(ctx context.Context, target QualityEvalTarget, limits QualityEvalLimits) (QualityEvalReport, error) {
		started <- target
		select {
		case <-release:
		case <-ctx.Done():
			return QualityEvalReport{}, ctx.Err()
		}
		return QualityEvalReport{
			SchemaVersion: QualityEvalSchemaVersion, CorpusVersion: 1, Protocol: target.Protocol,
			Model: target.RemoteModel, Passed: true, CaseCount: 5, PassedCases: 5,
			P50Millis: 120, P95Millis: 240, InputTokens: 100, OutputTokens: 50,
			GateFailures: []string{}, Cases: []QualityEvalCaseResult{{
				ID: "zh-concise-help", Passed: true, Attempts: 2, LatencyMillis: 120,
			}},
		}, nil
	}
	job, err := manager.Start(cfg, "probe-model")
	if err != nil {
		t.Fatal(err)
	}
	if job.Status != QualityEvalJobRunning || job.JobID == "" || job.ModelID != "probe-model" || job.StartedAt == nil {
		t.Fatalf("started quality job = %#v", job)
	}
	var target QualityEvalTarget
	select {
	case target = <-started:
	case <-time.After(time.Second):
		t.Fatal("quality evaluation did not start")
	}
	if target.APIKey != secret || target.BaseURL != baseURL || target.RemoteModel != "probe-remote" ||
		target.Protocol != AnthropicCompatibleProtocol || target.MaxOutputTokens != 600 {
		t.Fatalf("quality target = %#v", target)
	}
	if _, err := manager.Start(cfg, "probe-model"); !errors.Is(err, ErrModelDiagnosticBusy) {
		t.Fatalf("concurrent quality job error = %v", err)
	}
	assertQualityJobRedacted(t, manager.Snapshot(), secret, baseURL)
	close(release)
	completed := waitForQualityJob(t, manager, QualityEvalJobPassed)
	if completed.CompletedAt == nil || completed.Report == nil || !completed.Report.Passed {
		t.Fatalf("completed quality job = %#v", completed)
	}
	completed.Report.Cases[0].ID = "mutated"
	if manager.Snapshot().Report.Cases[0].ID != "zh-concise-help" {
		t.Fatal("quality job snapshot was not cloned")
	}
	assertQualityJobRedacted(t, manager.Snapshot(), secret, baseURL)
	encoded, err := json.Marshal(manager.Snapshot())
	if err != nil {
		t.Fatal(err)
	}
	for _, forbidden := range []string{`"protocol"`, `"model"`, `"attempts"`, `"latency_ms"`, "probe-remote"} {
		if strings.Contains(string(encoded), forbidden) {
			t.Fatalf("quality job exposed non-management field %q: %s", forbidden, encoded)
		}
	}
}

func TestQualityEvalJobReportsFixedFailureAndCancellationStates(t *testing.T) {
	cfg := probeTestConfig(t, "https://provider.example.test/v1", OpenAICompatibleProtocol, "private-key")

	t.Run("gate failure", func(t *testing.T) {
		manager := newQualityEvalJobManager(context.Background(), make(chan struct{}, 1))
		manager.run = func(context.Context, QualityEvalTarget, QualityEvalLimits) (QualityEvalReport, error) {
			return QualityEvalReport{
				SchemaVersion: QualityEvalSchemaVersion, Passed: false,
				GateFailures: []string{QualityEvalGateCaseFailures},
			}, nil
		}
		if _, err := manager.Start(cfg, "probe-model"); err != nil {
			t.Fatal(err)
		}
		job := waitForQualityJob(t, manager, QualityEvalJobFailed)
		if job.Report == nil || len(job.Report.GateFailures) != 1 || job.FailureCode != "" {
			t.Fatalf("failed quality job = %#v", job)
		}
	})

	t.Run("parent cancellation", func(t *testing.T) {
		ctx, cancel := context.WithCancel(context.Background())
		manager := newQualityEvalJobManager(ctx, make(chan struct{}, 1))
		started := make(chan struct{})
		manager.run = func(ctx context.Context, _ QualityEvalTarget, _ QualityEvalLimits) (QualityEvalReport, error) {
			close(started)
			<-ctx.Done()
			return QualityEvalReport{}, ctx.Err()
		}
		if _, err := manager.Start(cfg, "probe-model"); err != nil {
			t.Fatal(err)
		}
		<-started
		cancel()
		job := waitForQualityJob(t, manager, QualityEvalJobCancelled)
		if job.FailureCode != string(ModelFailureCancelled) || job.Report != nil {
			t.Fatalf("cancelled quality job = %#v", job)
		}
	})
}

func TestFairyAdminAPIModelEvaluationLifecycleAndSharedDiagnosticLimit(t *testing.T) {
	cfg := probeTestConfig(t, "https://provider.example.test/v1", OpenAICompatibleProtocol, "never-return-eval-key")
	cfg.ConfigFile = ""
	handler := NewAdminAPI(NewConfigManager(cfg), "local-admin-token", nil, nil)

	unauthorized := httptest.NewRecorder()
	handler.ServeHTTP(unauthorized, httptest.NewRequest(http.MethodGet, "/admin/model-eval", nil))
	if unauthorized.Code != http.StatusUnauthorized {
		t.Fatalf("unauthorized quality status = %d", unauthorized.Code)
	}
	idle := performFairyEvaluationRequest(handler, http.MethodGet, "", nil)
	if idle.Code != http.StatusOK || !strings.Contains(idle.Body.String(), `"status":"idle"`) {
		t.Fatalf("idle quality status=%d body=%s", idle.Code, idle.Body.String())
	}
	for name, body := range map[string]string{
		"unknown field": `{"model_id":"probe-model","prompt":"private"}`,
		"trailing JSON": `{"model_id":"probe-model"}{}`,
		"oversized":     `{"model_id":"` + strings.Repeat("a", maxModelProbeRequestBytes) + `"}`,
	} {
		t.Run(name, func(t *testing.T) {
			response := performFairyEvaluationRequest(handler, http.MethodPost, "", strings.NewReader(body))
			if response.Code != http.StatusBadRequest {
				t.Fatalf("invalid quality status=%d body=%s", response.Code, response.Body.String())
			}
		})
	}
	invalidQuery := performFairyEvaluationRequest(handler, http.MethodGet, "?prompt=private", nil)
	if invalidQuery.Code != http.StatusBadRequest {
		t.Fatalf("quality query status=%d body=%s", invalidQuery.Code, invalidQuery.Body.String())
	}

	started := make(chan struct{})
	release := make(chan struct{})
	handler.qualityEval.run = func(ctx context.Context, _ QualityEvalTarget, _ QualityEvalLimits) (QualityEvalReport, error) {
		close(started)
		select {
		case <-release:
			return QualityEvalReport{SchemaVersion: QualityEvalSchemaVersion, Passed: true}, nil
		case <-ctx.Done():
			return QualityEvalReport{}, ctx.Err()
		}
	}
	startedResponse := performFairyEvaluationRequest(handler, http.MethodPost, "", strings.NewReader(`{"model_id":"probe-model"}`))
	if startedResponse.Code != http.StatusAccepted || !strings.Contains(startedResponse.Body.String(), `"status":"running"`) {
		t.Fatalf("start quality status=%d body=%s", startedResponse.Code, startedResponse.Body.String())
	}
	select {
	case <-started:
	case <-time.After(time.Second):
		t.Fatal("admin quality evaluation did not start")
	}
	running := performFairyEvaluationRequest(handler, http.MethodGet, "", nil)
	if running.Code != http.StatusOK || !strings.Contains(running.Body.String(), `"status":"running"`) {
		t.Fatalf("running quality status=%d body=%s", running.Code, running.Body.String())
	}
	probe := performFairyAdminRequest(handler, strings.NewReader(`{"model_id":"probe-model"}`))
	if probe.Code != http.StatusTooManyRequests || probe.Header().Get("Retry-After") != "1" {
		t.Fatalf("probe during quality status=%d body=%s", probe.Code, probe.Body.String())
	}
	busy := performFairyEvaluationRequest(handler, http.MethodPost, "", strings.NewReader(`{"model_id":"probe-model"}`))
	if busy.Code != http.StatusTooManyRequests || busy.Header().Get("Retry-After") != "1" {
		t.Fatalf("concurrent quality status=%d body=%s", busy.Code, busy.Body.String())
	}
	close(release)
	job := waitForQualityJob(t, handler.qualityEval, QualityEvalJobPassed)
	assertQualityJobRedacted(t, job, "never-return-eval-key", cfg.ModelProviders[0].BaseURL)
}

func waitForQualityJob(t *testing.T, manager *qualityEvalJobManager, status string) QualityEvalJob {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		job := manager.Snapshot()
		if job.Status == status {
			return job
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatalf("quality job did not reach %s: %#v", status, manager.Snapshot())
	return QualityEvalJob{}
}

func assertQualityJobRedacted(t *testing.T, job QualityEvalJob, forbidden ...string) {
	t.Helper()
	encoded, err := json.Marshal(job)
	if err != nil {
		t.Fatal(err)
	}
	for _, value := range forbidden {
		if strings.Contains(string(encoded), value) {
			t.Fatalf("quality job exposed private value %q: %s", value, encoded)
		}
	}
}

func performFairyEvaluationRequest(handler http.Handler, method, query string, body *strings.Reader) *httptest.ResponseRecorder {
	var request *http.Request
	if body == nil {
		request = httptest.NewRequest(method, "/admin/model-eval"+query, nil)
	} else {
		request = httptest.NewRequest(method, "/admin/model-eval"+query, body)
	}
	request.Header.Set("Authorization", "Bearer local-admin-token")
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	return response
}
