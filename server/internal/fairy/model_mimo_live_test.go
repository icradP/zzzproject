package fairy

import (
	"context"
	"os"
	"testing"
	"time"
)

func TestMiMoAnthropicLiveEval(t *testing.T) {
	if os.Getenv("FAIRY_MIMO_LIVE") != "1" {
		t.Skip("set FAIRY_MIMO_LIVE=1 to run the isolated MiMo evaluation")
	}
	apiKey := os.Getenv("FAIRY_MIMO_API_KEY")
	if apiKey == "" {
		t.Fatal("FAIRY_MIMO_API_KEY is required")
	}
	report, err := RunQualityEvaluation(context.Background(), QualityEvalTarget{
		Protocol: AnthropicCompatibleProtocol,
		BaseURL:  envOrDefault("FAIRY_MIMO_BASE_URL", "https://token-plan-cn.xiaomimimo.com/anthropic"),
		APIKey:   apiKey, RemoteModel: envOrDefault("FAIRY_MIMO_MODEL", "mimo-v2.5-pro"),
		Timeout: 45 * time.Second, MaxOutputTokens: 600,
	}, QualityEvalLimits{MaxP95Latency: 30 * time.Second, MaxInputTokens: 10_000, MaxOutputTokens: 4_000})
	if err != nil {
		t.Fatal(err)
	}
	if !report.Passed {
		t.Fatalf("MiMo quality gate failed: %#v", report)
	}
	t.Logf("MiMo quality eval: cases=%d input_tokens=%d output_tokens=%d p50_ms=%d p95_ms=%d",
		report.CaseCount, report.InputTokens, report.OutputTokens, report.P50Millis, report.P95Millis)
}

func TestMiMoAnthropicLiveProbe(t *testing.T) {
	if os.Getenv("FAIRY_MIMO_LIVE") != "1" {
		t.Skip("set FAIRY_MIMO_LIVE=1 to run the isolated MiMo probe")
	}
	apiKey := os.Getenv("FAIRY_MIMO_API_KEY")
	if apiKey == "" {
		t.Fatal("FAIRY_MIMO_API_KEY is required")
	}
	baseURL := envOrDefault("FAIRY_MIMO_BASE_URL", "https://token-plan-cn.xiaomimimo.com/anthropic")
	remoteModel := envOrDefault("FAIRY_MIMO_MODEL", "mimo-v2.5-pro")
	cfg := probeTestConfig(t, baseURL, AnthropicCompatibleProtocol, apiKey)
	cfg.ModelProviders[0].Timeout = 30 * time.Second
	cfg.ModelDefinitions[0].RemoteName = remoteModel
	cfg.ModelDefinitions[0].InputPriceMicrosPerMillionTokens = 0
	cfg.ModelDefinitions[0].OutputPriceMicrosPerMillionTokens = 0

	result, err := ProbeConfiguredModel(context.Background(), cfg, "probe-model")
	if err != nil {
		t.Fatal(err)
	}
	if !result.OK || result.Protocol != AnthropicCompatibleProtocol || result.InputTokens <= 0 || result.OutputTokens <= 0 {
		t.Fatalf("MiMo probe failed: %#v", result)
	}
	t.Logf("MiMo live probe: latency_ms=%d input_tokens=%d output_tokens=%d cost_microusd=%d",
		result.LatencyMillis, result.InputTokens, result.OutputTokens, result.EstimatedCostMicroUSD)
}

func TestMiMoAnthropicLiveAgentDiagnostic(t *testing.T) {
	if os.Getenv("FAIRY_MIMO_LIVE") != "1" {
		t.Skip("set FAIRY_MIMO_LIVE=1 to run the isolated MiMo agent diagnostic")
	}
	apiKey := os.Getenv("FAIRY_MIMO_API_KEY")
	if apiKey == "" {
		t.Fatal("FAIRY_MIMO_API_KEY is required")
	}
	baseURL := envOrDefault("FAIRY_MIMO_BASE_URL", "https://token-plan-cn.xiaomimimo.com/anthropic")
	remoteModel := envOrDefault("FAIRY_MIMO_MODEL", "mimo-v2.5-pro")
	cfg := probeTestConfig(t, baseURL, AnthropicCompatibleProtocol, apiKey)
	cfg.AIEnabled = false
	cfg.AIRolloutMode = AIRolloutOff
	cfg.ModelProviders[0].Timeout = 45 * time.Second
	cfg.ModelDefinitions[0].RemoteName = remoteModel
	cfg.ModelDefinitions[0].InputPriceMicrosPerMillionTokens = 0
	cfg.ModelDefinitions[0].OutputPriceMicrosPerMillionTokens = 0
	for index := range cfg.ModelTasks {
		cfg.ModelTasks[index].Timeout = 45 * time.Second
	}
	state, err := OpenStateStoreWithDefaults(cfg.StateFile, cfg.GroupDefault, cfg.GroupSoftDefault)
	if err != nil {
		t.Fatal(err)
	}
	engine := NewEngine(cfg, state, nil)
	result, err := engine.RunAgentDiagnostic(context.Background(), AgentDiagnosticCasePipeline)
	if err != nil {
		t.Fatal(err)
	}
	if result.Status != AgentDiagnosticPassed || result.Reply == "" {
		t.Fatalf("MiMo agent diagnostic failed: %#v", result)
	}
	used, remaining := state.ModelQuotaStatus(engine.now(), cfg.ModelDailyLimit)
	if used != 0 || remaining != cfg.ModelDailyLimit {
		t.Fatalf("MiMo agent diagnostic consumed model quota: used=%d remaining=%d", used, remaining)
	}
	t.Logf("MiMo live agent diagnostic: status=%s duration_ms=%d", result.Status, result.DurationMillis)
}
