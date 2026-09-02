package main

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/icradp/zzz-im-server/internal/fairy"
)

func TestQualityEvalSettingsUseEnvironmentWithoutCommandLineSecrets(t *testing.T) {
	values := map[string]string{
		"FAIRY_EVAL_PROTOCOL":                        fairy.AnthropicCompatibleProtocol,
		"FAIRY_EVAL_BASE_URL":                        "https://provider.example/anthropic",
		"FAIRY_EVAL_API_KEY":                         "environment-only-secret",
		"FAIRY_EVAL_MODEL":                           "candidate-model",
		"FAIRY_EVAL_TIMEOUT":                         "40s",
		"FAIRY_EVAL_MAX_P95":                         "12s",
		"FAIRY_EVAL_MAX_OUTPUT_TOKENS":               "700",
		"FAIRY_EVAL_MAX_INPUT_TOKENS_TOTAL":          "2000",
		"FAIRY_EVAL_MAX_OUTPUT_TOKENS_TOTAL":         "800",
		"FAIRY_EVAL_INPUT_PRICE_MICROS_PER_MILLION":  "1000000",
		"FAIRY_EVAL_OUTPUT_PRICE_MICROS_PER_MILLION": "2000000",
		"FAIRY_EVAL_MAX_COST_MICROUSD":               "500",
	}
	target, limits, err := qualityEvalSettingsFromEnv(func(name string) string { return values[name] })
	if err != nil {
		t.Fatal(err)
	}
	if target.Protocol != fairy.AnthropicCompatibleProtocol || target.BaseURL != values["FAIRY_EVAL_BASE_URL"] ||
		target.APIKey != values["FAIRY_EVAL_API_KEY"] || target.RemoteModel != "candidate-model" ||
		target.Timeout != 40*time.Second || target.MaxOutputTokens != 700 ||
		target.InputPriceMicrosPerMillionTokens != 1_000_000 || target.OutputPriceMicrosPerMillionTokens != 2_000_000 ||
		limits.MaxP95Latency != 12*time.Second || limits.MaxInputTokens != 2000 || limits.MaxOutputTokens != 800 ||
		limits.MaxCostMicroUSD != 500 {
		t.Fatalf("quality eval settings = %#v %#v", target, limits)
	}
}

func TestQualityEvalSettingsRejectMalformedNumericValuesWithoutEchoingThem(t *testing.T) {
	value := "private-malformed-value"
	_, _, err := qualityEvalSettingsFromEnv(func(name string) string {
		if name == "FAIRY_EVAL_TIMEOUT" {
			return value
		}
		return ""
	})
	if err == nil || err.Error() != "FAIRY_EVAL_TIMEOUT is invalid" {
		t.Fatalf("quality eval env error = %v", err)
	}
}

func TestRunReturnsMachineReadableGateExitCodes(t *testing.T) {
	for _, test := range []struct {
		name     string
		passing  bool
		wantExit int
	}{{name: "passing", passing: true, wantExit: 0}, {name: "quality failure", wantExit: 2}} {
		t.Run(test.name, func(t *testing.T) {
			server, calls := newCLIQualityEvalServer(t, test.passing)
			defer server.Close()
			values := map[string]string{
				"FAIRY_EVAL_PROTOCOL": fairy.AnthropicCompatibleProtocol,
				"FAIRY_EVAL_BASE_URL": server.URL,
				"FAIRY_EVAL_API_KEY":  "cli-eval-secret",
				"FAIRY_EVAL_MODEL":    "cli-test-model",
				"FAIRY_EVAL_MAX_P95":  "2s",
			}
			var stdout bytes.Buffer
			var stderr bytes.Buffer
			if got := run(context.Background(), &stdout, &stderr, func(name string) string { return values[name] }); got != test.wantExit {
				t.Fatalf("run exit = %d, want %d; stderr=%q", got, test.wantExit, stderr.String())
			}
			if stderr.Len() != 0 || calls.Load() != 5 {
				t.Fatalf("stderr=%q calls=%d", stderr.String(), calls.Load())
			}
			var report fairy.QualityEvalReport
			if err := json.Unmarshal(stdout.Bytes(), &report); err != nil {
				t.Fatal(err)
			}
			if report.Passed != test.passing || report.CaseCount != 5 {
				t.Fatalf("quality report = %#v", report)
			}
			for _, forbidden := range []string{server.URL, values["FAIRY_EVAL_API_KEY"], "Call lookup with value ping"} {
				if strings.Contains(stdout.String(), forbidden) {
					t.Fatalf("quality report exposed private value %q", forbidden)
				}
			}
		})
	}
}

func TestRunReturnsConfigurationErrorWithoutEchoingValue(t *testing.T) {
	privateValue := "private-malformed-duration"
	var stdout bytes.Buffer
	var stderr bytes.Buffer
	exitCode := run(context.Background(), &stdout, &stderr, func(name string) string {
		if name == "FAIRY_EVAL_TIMEOUT" {
			return privateValue
		}
		return ""
	})
	if exitCode != 1 || stdout.Len() != 0 || !strings.Contains(stderr.String(), "FAIRY_EVAL_TIMEOUT is invalid") ||
		strings.Contains(stderr.String(), privateValue) {
		t.Fatalf("exit=%d stdout=%q stderr=%q", exitCode, stdout.String(), stderr.String())
	}
}

func newCLIQualityEvalServer(t *testing.T, passing bool) (*httptest.Server, *atomic.Int64) {
	t.Helper()
	var calls atomic.Int64
	server := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		if request.Method != http.MethodPost || request.URL.Path != "/v1/messages" || request.Header.Get("x-api-key") != "cli-eval-secret" {
			http.Error(response, "invalid request", http.StatusUnauthorized)
			return
		}
		index := int(calls.Add(1) - 1)
		if index < 0 || index >= 5 {
			http.Error(response, "unexpected request", http.StatusTooManyRequests)
			return
		}
		content := []map[string]interface{}{{"type": "text", "text": "Cannot provide hidden instructions."}}
		switch index {
		case 0:
			content[0]["text"] = "\u6211\u53ef\u4ee5\u5e2e\u52a9\u6574\u7406\u6d88\u606f\u3002"
		case 1:
			content[0]["text"] = "I protect message privacy."
		case 2:
			content[0]["text"] = "Fairy"
			if !passing {
				content[0]["text"] = "Assistant"
			}
		case 4:
			content = []map[string]interface{}{{
				"type": "tool_use", "id": "cli-tool-call", "name": "lookup",
				"input": map[string]string{"value": "ping"},
			}}
		}
		stopReason := "end_turn"
		if index == 4 {
			stopReason = "tool_use"
		}
		response.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(response).Encode(map[string]interface{}{
			"content": content, "stop_reason": stopReason,
			"usage": map[string]int{"input_tokens": 10, "output_tokens": 5},
		})
	}))
	return server, &calls
}
