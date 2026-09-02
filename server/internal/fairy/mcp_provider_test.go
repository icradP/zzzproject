package fairy

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"os"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

func TestMCPHelperProcess(t *testing.T) {
	if os.Getenv("ZZZ_MCP_HELPER") != "1" {
		return
	}
	if pidFile := os.Getenv("ZZZ_MCP_PID_FILE"); pidFile != "" {
		if err := os.WriteFile(pidFile, []byte(strconv.Itoa(os.Getpid())), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	switch os.Getenv("ZZZ_MCP_MODE") {
	case "hang":
		select {}
	case "malformed":
		_, _ = fmt.Fprintln(os.Stdout, "{not-json")
		select {}
	}
	if os.Getenv("ZZZ_MCP_NOISY_STDERR") == "1" {
		_, _ = io.WriteString(os.Stderr, strings.Repeat("x", 2*1024*1024))
	}
	server := mcp.NewServer(
		&mcp.Implementation{Name: "fairy-test-provider", Version: "v1"},
		&mcp.ServerOptions{PageSize: 1, Logger: slog.New(slog.NewTextHandler(io.Discard, nil))},
	)
	readOnly := true
	notDestructive := false
	destructive := true
	objectSchema := map[string]interface{}{
		"type": "object", "properties": map[string]interface{}{}, "additionalProperties": false,
	}
	server.AddTool(&mcp.Tool{
		Name: "echo", Description: "Return test data.", InputSchema: objectSchema,
		Annotations: &mcp.ToolAnnotations{ReadOnlyHint: readOnly, DestructiveHint: &notDestructive},
	}, func(context.Context, *mcp.CallToolRequest) (*mcp.CallToolResult, error) {
		return &mcp.CallToolResult{
			Content:           []mcp.Content{&mcp.TextContent{Text: "hello from MCP"}},
			StructuredContent: map[string]interface{}{"answer": 42},
		}, nil
	})
	server.AddTool(&mcp.Tool{
		Name: "hidden", Description: "Not allowlisted.", InputSchema: objectSchema,
		Annotations: &mcp.ToolAnnotations{ReadOnlyHint: readOnly, DestructiveHint: &notDestructive},
	}, func(context.Context, *mcp.CallToolRequest) (*mcp.CallToolResult, error) {
		return &mcp.CallToolResult{Content: []mcp.Content{&mcp.TextContent{Text: "hidden"}}}, nil
	})
	server.AddTool(&mcp.Tool{
		Name: "write", Description: "Not read-only.", InputSchema: objectSchema,
		Annotations: &mcp.ToolAnnotations{ReadOnlyHint: false, DestructiveHint: &notDestructive},
	}, func(context.Context, *mcp.CallToolRequest) (*mcp.CallToolResult, error) {
		return &mcp.CallToolResult{Content: []mcp.Content{&mcp.TextContent{Text: "write"}}}, nil
	})
	server.AddTool(&mcp.Tool{
		Name: "destructive", Description: "Contradictory annotations.", InputSchema: objectSchema,
		Annotations: &mcp.ToolAnnotations{ReadOnlyHint: true, DestructiveHint: &destructive},
	}, func(context.Context, *mcp.CallToolRequest) (*mcp.CallToolResult, error) {
		return &mcp.CallToolResult{Content: []mcp.Content{&mcp.TextContent{Text: "destructive"}}}, nil
	})
	server.AddTool(&mcp.Tool{
		Name: "unsupported", Description: "Unsupported schema.",
		InputSchema: map[string]interface{}{"type": "object", "properties": map[string]interface{}{"choice": map[string]interface{}{"type": "string", "enum": []string{"a"}}}},
		Annotations: &mcp.ToolAnnotations{ReadOnlyHint: true, DestructiveHint: &notDestructive},
	}, func(context.Context, *mcp.CallToolRequest) (*mcp.CallToolResult, error) {
		return &mcp.CallToolResult{Content: []mcp.Content{&mcp.TextContent{Text: "unsupported"}}}, nil
	})
	server.AddTool(&mcp.Tool{
		Name: "oversized", Description: "Return too much data.", InputSchema: objectSchema,
		Annotations: &mcp.ToolAnnotations{ReadOnlyHint: true, DestructiveHint: &notDestructive},
	}, func(context.Context, *mcp.CallToolRequest) (*mcp.CallToolResult, error) {
		return &mcp.CallToolResult{Content: []mcp.Content{&mcp.TextContent{Text: strings.Repeat("z", 4096)}}}, nil
	})
	server.AddTool(&mcp.Tool{
		Name: "slow-once", Description: "Timeout once, then recover.", InputSchema: objectSchema,
		Annotations: &mcp.ToolAnnotations{ReadOnlyHint: true, DestructiveHint: &notDestructive},
	}, func(ctx context.Context, _ *mcp.CallToolRequest) (*mcp.CallToolResult, error) {
		marker := os.Getenv("ZZZ_MCP_MARKER")
		if _, err := os.Stat(marker); os.IsNotExist(err) {
			if err := os.WriteFile(marker, []byte("timed-out"), 0o600); err != nil {
				return nil, err
			}
			select {
			case <-time.After(5 * time.Second):
			case <-ctx.Done():
				return nil, ctx.Err()
			}
		}
		return &mcp.CallToolResult{Content: []mcp.Content{&mcp.TextContent{Text: "recovered"}}}, nil
	})
	if err := server.Run(context.Background(), &mcp.StdioTransport{}); err != nil {
		t.Fatal(err)
	}
}

func TestExternalToolManagerDiscoversOnlyAllowedReadOnlySupportedTools(t *testing.T) {
	pidFile := t.TempDir() + "/provider.pid"
	cfg := mcpTestProviderConfig(t, []string{"echo", "write", "destructive", "unsupported"})
	t.Setenv("ZZZ_MCP_PID_FILE", pidFile)
	cfg.EnvironmentAllowlist = append(cfg.EnvironmentAllowlist, "ZZZ_MCP_PID_FILE")
	manager := StartExternalToolManager(context.Background(), []ExternalToolProviderConfig{cfg})
	tools := manager.Tools()
	if len(tools) != 1 || tools[0].Spec().Name != "test-provider.echo" {
		t.Fatalf("registered tools = %#v", toolNames(tools))
	}
	output, err := tools[0].Execute(context.Background(), json.RawMessage(`{}`))
	if err != nil {
		t.Fatal(err)
	}
	projection, err := tools[0].Project(output)
	if err != nil || !strings.Contains(projection.ModelText, `answer`) || !strings.Contains(projection.UserText, `{"answer":42}`) || !strings.Contains(projection.UserText, "hello from MCP") {
		t.Fatalf("projection=%#v err=%v", projection, err)
	}
	status := manager.Status()
	if len(status) != 1 || status[0].Status != "ready" || status[0].Tools != 1 || status[0].ConsecutiveFails != 0 {
		t.Fatalf("provider status = %#v", status)
	}
	if err := manager.Close(); err != nil && !strings.Contains(err.Error(), "signal") {
		t.Fatal(err)
	}
	assertProcessExited(t, pidFile)
}

func TestNormalizeMCPShutdownError(t *testing.T) {
	if err := normalizeMCPShutdownError(fmt.Errorf("close MCP transport: %w", os.ErrProcessDone)); err != nil {
		t.Fatalf("finished process error was not ignored: %v", err)
	}
	expected := errors.New("close failed")
	if err := normalizeMCPShutdownError(expected); !errors.Is(err, expected) {
		t.Fatalf("unexpected close error = %v", err)
	}
}

func TestExternalToolProviderRejectsOversizedOutput(t *testing.T) {
	cfg := mcpTestProviderConfig(t, []string{"oversized"})
	cfg.MaxOutputBytes = 1024
	manager := StartExternalToolManager(context.Background(), []ExternalToolProviderConfig{cfg})
	defer manager.Close()
	tools := manager.Tools()
	if len(tools) != 1 {
		t.Fatalf("registered tools = %v", toolNames(tools))
	}
	if _, err := tools[0].Execute(context.Background(), json.RawMessage(`{}`)); err == nil || !strings.Contains(err.Error(), "exceeds") {
		t.Fatalf("oversized result error = %v", err)
	}
}

func TestExternalToolProviderTimeoutOpensCircuitAndRecovers(t *testing.T) {
	marker := t.TempDir() + "/slow-once"
	cfg := mcpTestProviderConfig(t, []string{"slow-once"})
	t.Setenv("ZZZ_MCP_MARKER", marker)
	cfg.EnvironmentAllowlist = append(cfg.EnvironmentAllowlist, "ZZZ_MCP_MARKER")
	cfg.CallTimeout = time.Second
	cfg.ResetTimeout = time.Second
	manager := StartExternalToolManager(context.Background(), []ExternalToolProviderConfig{cfg})
	defer manager.Close()
	tools := manager.Tools()
	if len(tools) != 1 {
		t.Fatalf("registered tools = %v", toolNames(tools))
	}
	if _, err := tools[0].Execute(context.Background(), json.RawMessage(`{}`)); !errorsIsDeadline(err) {
		t.Fatalf("timeout error = %v", err)
	}
	if status := manager.Status()[0]; status.Status != "circuit_open" || status.CircuitOpenUntil == "" {
		t.Fatalf("status after timeout = %#v", status)
	}
	if _, err := tools[0].Execute(context.Background(), json.RawMessage(`{}`)); err == nil || !strings.Contains(err.Error(), "circuit") {
		t.Fatalf("open circuit error = %v", err)
	}
	time.Sleep(1100 * time.Millisecond)
	output, err := tools[0].Execute(context.Background(), json.RawMessage(`{}`))
	if err != nil || !strings.Contains(string(output), "recovered") {
		t.Fatalf("recovery output=%s err=%v", output, err)
	}
	if status := manager.Status()[0]; status.Status != "ready" || status.ConsecutiveFails != 0 {
		t.Fatalf("status after recovery = %#v", status)
	}
}

func TestExternalToolProviderStartupFailureDoesNotFailManager(t *testing.T) {
	for _, mode := range []string{"hang", "malformed"} {
		t.Run(mode, func(t *testing.T) {
			cfg := mcpTestProviderConfig(t, []string{"echo"})
			t.Setenv("ZZZ_MCP_MODE", mode)
			cfg.EnvironmentAllowlist = append(cfg.EnvironmentAllowlist, "ZZZ_MCP_MODE")
			cfg.StartupTimeout = time.Second
			manager := StartExternalToolManager(context.Background(), []ExternalToolProviderConfig{cfg})
			defer manager.Close()
			if len(manager.Tools()) != 0 || manager.Status()[0].Status != "startup_failed" {
				t.Fatalf("startup failure state: tools=%v status=%#v", toolNames(manager.Tools()), manager.Status())
			}
		})
	}
}

func TestExternalToolProviderNoisyStderrDoesNotBlockStartup(t *testing.T) {
	cfg := mcpTestProviderConfig(t, []string{"echo"})
	t.Setenv("ZZZ_MCP_NOISY_STDERR", "1")
	cfg.EnvironmentAllowlist = append(cfg.EnvironmentAllowlist, "ZZZ_MCP_NOISY_STDERR")
	manager := StartExternalToolManager(context.Background(), []ExternalToolProviderConfig{cfg})
	defer manager.Close()
	if len(manager.Tools()) != 1 || manager.Status()[0].Status != "ready" {
		t.Fatalf("noisy provider failed: %#v", manager.Status())
	}
}

func TestExternalToolProviderRejectsSecretArgumentsAndUnsafeLinks(t *testing.T) {
	cfg := mcpTestProviderConfig(t, []string{"echo"})
	cfg.Args = append(cfg.Args, "--api-key=must-not-be-returned")
	if err := normalizeExternalToolConfiguration(&Config{ExternalToolProviders: []ExternalToolProviderConfig{cfg}}); err == nil {
		t.Fatal("secret command argument was accepted")
	}
	unsafe := &mcp.CallToolResult{Content: []mcp.Content{&mcp.ResourceLink{Name: "local", URI: "file:///etc/passwd"}}}
	if _, err := normalizeMCPToolResult("provider", "lookup", unsafe, 4096); err == nil {
		t.Fatal("unsafe MCP resource link was accepted")
	}
}

func mcpTestProviderConfig(t *testing.T, allowedTools []string) ExternalToolProviderConfig {
	t.Helper()
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	t.Setenv("ZZZ_MCP_HELPER", "1")
	return ExternalToolProviderConfig{
		ID: "test-provider", Enabled: true, Protocol: MCPStdioProtocol,
		Command: executable, Args: []string{"-test.run=^TestMCPHelperProcess$"},
		EnvironmentAllowlist: []string{"ZZZ_MCP_HELPER"}, AllowedTools: allowedTools,
		StartupTimeout: 3 * time.Second, CallTimeout: 2 * time.Second,
		FailureThreshold: 2, ResetTimeout: time.Second, MaxOutputBytes: 64 * 1024,
	}
}

func toolNames(tools []Tool) []string {
	names := make([]string, 0, len(tools))
	for _, tool := range tools {
		names = append(names, tool.Spec().Name)
	}
	return names
}

func errorsIsDeadline(err error) bool {
	return err == context.DeadlineExceeded || err != nil && strings.Contains(err.Error(), context.DeadlineExceeded.Error())
}

func assertProcessExited(t *testing.T, pidFile string) {
	t.Helper()
	content, err := os.ReadFile(pidFile)
	if err != nil {
		t.Fatal(err)
	}
	pid, err := strconv.Atoi(string(content))
	if err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if err := syscall.Kill(pid, syscall.Signal(0)); err != nil {
			return
		}
		time.Sleep(25 * time.Millisecond)
	}
	t.Fatalf("MCP provider process %d is still running", pid)
}
