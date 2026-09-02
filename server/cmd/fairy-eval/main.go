package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/icradp/zzz-im-server/internal/fairy"
)

func main() {
	os.Exit(run(context.Background(), os.Stdout, os.Stderr, os.Getenv))
}

func run(parent context.Context, stdout, stderr io.Writer, getenv func(string) string) int {
	target, limits, err := qualityEvalSettingsFromEnv(getenv)
	if err != nil {
		fmt.Fprintf(stderr, "fairy-eval: %v\n", err)
		return 1
	}
	ctx, stop := signal.NotifyContext(parent, os.Interrupt, syscall.SIGTERM)
	defer stop()
	report, err := fairy.RunQualityEvaluation(ctx, target, limits)
	if err != nil {
		fmt.Fprintf(stderr, "fairy-eval: evaluation failed\n")
		return 1
	}
	encoder := json.NewEncoder(stdout)
	encoder.SetIndent("", "  ")
	if err := encoder.Encode(report); err != nil {
		fmt.Fprintf(stderr, "fairy-eval: encode report failed\n")
		return 1
	}
	if !report.Passed {
		return 2
	}
	return 0
}

func qualityEvalSettingsFromEnv(getenv func(string) string) (fairy.QualityEvalTarget, fairy.QualityEvalLimits, error) {
	protocol := strings.TrimSpace(getenv("FAIRY_EVAL_PROTOCOL"))
	if protocol == "" {
		protocol = fairy.AnthropicCompatibleProtocol
	}
	timeout, err := envDuration(getenv, "FAIRY_EVAL_TIMEOUT", 45*time.Second)
	if err != nil {
		return fairy.QualityEvalTarget{}, fairy.QualityEvalLimits{}, err
	}
	maxP95, err := envDuration(getenv, "FAIRY_EVAL_MAX_P95", 30*time.Second)
	if err != nil {
		return fairy.QualityEvalTarget{}, fairy.QualityEvalLimits{}, err
	}
	maxOutputPerCall, err := envInt(getenv, "FAIRY_EVAL_MAX_OUTPUT_TOKENS", 600)
	if err != nil {
		return fairy.QualityEvalTarget{}, fairy.QualityEvalLimits{}, err
	}
	maxInputTotal, err := envInt(getenv, "FAIRY_EVAL_MAX_INPUT_TOKENS_TOTAL", 10_000)
	if err != nil {
		return fairy.QualityEvalTarget{}, fairy.QualityEvalLimits{}, err
	}
	maxOutputTotal, err := envInt(getenv, "FAIRY_EVAL_MAX_OUTPUT_TOKENS_TOTAL", 4_000)
	if err != nil {
		return fairy.QualityEvalTarget{}, fairy.QualityEvalLimits{}, err
	}
	inputPrice, err := envInt64(getenv, "FAIRY_EVAL_INPUT_PRICE_MICROS_PER_MILLION", 0)
	if err != nil {
		return fairy.QualityEvalTarget{}, fairy.QualityEvalLimits{}, err
	}
	outputPrice, err := envInt64(getenv, "FAIRY_EVAL_OUTPUT_PRICE_MICROS_PER_MILLION", 0)
	if err != nil {
		return fairy.QualityEvalTarget{}, fairy.QualityEvalLimits{}, err
	}
	maxCost, err := envInt64(getenv, "FAIRY_EVAL_MAX_COST_MICROUSD", 0)
	if err != nil {
		return fairy.QualityEvalTarget{}, fairy.QualityEvalLimits{}, err
	}
	target := fairy.QualityEvalTarget{
		Protocol: protocol, BaseURL: strings.TrimSpace(getenv("FAIRY_EVAL_BASE_URL")),
		APIKey: getenv("FAIRY_EVAL_API_KEY"), RemoteModel: strings.TrimSpace(getenv("FAIRY_EVAL_MODEL")),
		Timeout: timeout, MaxOutputTokens: maxOutputPerCall,
		InputPriceMicrosPerMillionTokens: inputPrice, OutputPriceMicrosPerMillionTokens: outputPrice,
	}
	limits := fairy.QualityEvalLimits{
		MaxP95Latency: maxP95, MaxInputTokens: maxInputTotal, MaxOutputTokens: maxOutputTotal,
		MaxCostMicroUSD: maxCost,
	}
	return target, limits, nil
}

func envDuration(getenv func(string) string, name string, fallback time.Duration) (time.Duration, error) {
	value := strings.TrimSpace(getenv(name))
	if value == "" {
		return fallback, nil
	}
	parsed, err := time.ParseDuration(value)
	if err != nil {
		return 0, fmt.Errorf("%s is invalid", name)
	}
	return parsed, nil
}

func envInt(getenv func(string) string, name string, fallback int) (int, error) {
	value := strings.TrimSpace(getenv(name))
	if value == "" {
		return fallback, nil
	}
	parsed, err := strconv.Atoi(value)
	if err != nil {
		return 0, fmt.Errorf("%s is invalid", name)
	}
	return parsed, nil
}

func envInt64(getenv func(string) string, name string, fallback int64) (int64, error) {
	value := strings.TrimSpace(getenv(name))
	if value == "" {
		return fallback, nil
	}
	parsed, err := strconv.ParseInt(value, 10, 64)
	if err != nil {
		return 0, fmt.Errorf("%s is invalid", name)
	}
	return parsed, nil
}
