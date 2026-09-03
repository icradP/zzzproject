package fairy

import (
	"bytes"
	"context"
	"encoding/json"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/icradp/zzz-im-server/internal/protocol"
)

type fakeZZZMYSService struct {
	mu          sync.Mutex
	createCalls int
	abyssErr    error
}

func (f *fakeZZZMYSService) CreateQR(context.Context) (zzzQRLogin, error) {
	f.mu.Lock()
	f.createCalls++
	f.mu.Unlock()
	return zzzQRLogin{Ticket: "ticket", URL: "https://example.test/qr", DeviceID: strings.Repeat("a", 64)}, nil
}

func (f *fakeZZZMYSService) QueryQR(context.Context, zzzQRLogin) (zzzQRLoginStatus, error) {
	return zzzQRLoginStatus{Status: "Confirmed", AccountID: "123456789", MID: "mid-secret", SToken: "stoken-secret"}, nil
}

func (f *fakeZZZMYSService) ExchangeCookieToken(context.Context, zzzQRLoginStatus) (string, error) {
	return "cookie-secret", nil
}

func (f *fakeZZZMYSService) GameRoles(context.Context, string, string) ([]zzzMYSRole, error) {
	return []zzzMYSRole{{GameID: 8, GameBiz: "nap_cn", UID: "27280531", Nickname: "Belle"}}, nil
}

func (f *fakeZZZMYSService) AuthKey(context.Context, zzzAccountCredential) (string, error) {
	return "authkey-secret", nil
}

func (f *fakeZZZMYSService) GachaPage(_ context.Context, _ zzzAccountCredential, _ string, gachaType string, page int, _ string, _ string) (zzzGachaPage, error) {
	if gachaType == "1001" && page == 1 {
		return zzzGachaPage{Records: []zzzGachaRecord{{
			RecordID: "100", ItemID: "1", Name: "Ellen", ItemType: "角色", RankType: "4", Time: "2026-01-01 00:00:00",
		}}}, nil
	}
	return zzzGachaPage{}, nil
}

func (f *fakeZZZMYSService) Abyss(_ context.Context, account zzzAccountCredential, scheduleType int) (zzzAbyssSummary, error) {
	if f.abyssErr != nil {
		return zzzAbyssSummary{}, f.abyssErr
	}
	return zzzAbyssSummary{UID: account.UID, ScheduleType: scheduleType, Rating: "S", Score: 42000, MaxScore: 50000}, nil
}

type fakeInteractiveMessenger struct {
	mu       sync.Mutex
	texts    []string
	segments [][]protocol.MessageSegment
	uploads  [][]byte
}

func (m *fakeInteractiveMessenger) SendText(_ context.Context, _, _, text string) error {
	m.mu.Lock()
	m.texts = append(m.texts, text)
	m.mu.Unlock()
	return nil
}

func (m *fakeInteractiveMessenger) SendSegments(_ context.Context, _ string, segments []protocol.MessageSegment) error {
	m.mu.Lock()
	m.segments = append(m.segments, append([]protocol.MessageSegment(nil), segments...))
	m.mu.Unlock()
	return nil
}

func (m *fakeInteractiveMessenger) UploadFile(_ context.Context, _, _, _ string, data []byte) (UploadedFile, error) {
	m.mu.Lock()
	m.uploads = append(m.uploads, append([]byte(nil), data...))
	m.mu.Unlock()
	return UploadedFile{FileID: "file-id", URL: "https://example.test/media/qr.png"}, nil
}

func (m *fakeInteractiveMessenger) GetGroupMembers(context.Context, string) ([]protocol.GroupMember, error) {
	return nil, nil
}

func (m *fakeInteractiveMessenger) allOutput() string {
	m.mu.Lock()
	defer m.mu.Unlock()
	var output strings.Builder
	for _, text := range m.texts {
		output.WriteString(text)
	}
	for _, chain := range m.segments {
		for _, segment := range chain {
			for _, value := range segment.Data {
				if text, ok := value.(string); ok {
					output.WriteString(text)
				}
			}
		}
	}
	return output.String()
}

func openTestZZZAccountStore(t *testing.T) *ZZZAccountStore {
	t.Helper()
	directory := t.TempDir()
	store, err := OpenZZZAccountStore(directory+"/zzz.db", directory+"/zzz.key")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = store.Close() })
	return store
}

func TestZZZAccountPluginLoginUsesUploadedQRAndNeverRepliesWithCredentials(t *testing.T) {
	store := openTestZZZAccountStore(t)
	mys := &fakeZZZMYSService{}
	plugin := newZZZAccountPluginWithDependencies(Config{}, store, mys)
	plugin.pollInterval = time.Millisecond
	plugin.loginTimeout = time.Second
	if err := plugin.Start(context.Background()); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), time.Second)
		defer cancel()
		_ = plugin.Stop(ctx)
	})
	messenger := &fakeInteractiveMessenger{}
	request := PluginRequest{Text: "/zzz login", ConversationID: "private-alice-fairy", MessageID: "message-1", MessageType: "private", SenderID: "alice"}
	handled, err := plugin.HandleInteractive(context.Background(), messenger, request)
	if err != nil || !handled {
		t.Fatalf("HandleInteractive() = %v, %v", handled, err)
	}
	waitForZZZTest(t, time.Second, func() bool {
		summary, err := store.Summary(context.Background(), "alice")
		return err == nil && summary.Bound && strings.Contains(messenger.allOutput(), "绑定成功")
	})

	messenger.mu.Lock()
	if len(messenger.uploads) != 1 || !bytes.HasPrefix(messenger.uploads[0], []byte("\x89PNG\r\n\x1a\n")) {
		messenger.mu.Unlock()
		t.Fatal("login did not upload a generated PNG QR code")
	}
	if len(messenger.segments) != 1 || len(messenger.segments[0]) != 1 || messenger.segments[0][0].Type != "image" {
		messenger.mu.Unlock()
		t.Fatalf("login segments = %#v", messenger.segments)
	}
	if len(messenger.texts) == 0 || !strings.Contains(messenger.texts[0], "扫描下方二维码") {
		messenger.mu.Unlock()
		t.Fatalf("login instructions = %#v", messenger.texts)
	}
	messenger.mu.Unlock()
	output := messenger.allOutput()
	for _, secret := range []string{"stoken-secret", "cookie-secret", "mid-secret"} {
		if strings.Contains(output, secret) {
			t.Fatalf("login output exposed %q: %s", secret, output)
		}
	}
	account, err := store.Account(context.Background(), "alice")
	if err != nil || account.UID != "27280531" || account.SToken != "stoken-secret" {
		t.Fatalf("stored account = %#v, %v", account, err)
	}
}

func TestZZZAccountPluginPrivateCommandsRejectGroups(t *testing.T) {
	store := openTestZZZAccountStore(t)
	mys := &fakeZZZMYSService{}
	plugin := newZZZAccountPluginWithDependencies(Config{}, store, mys)
	if err := plugin.Start(context.Background()); err != nil {
		t.Fatal(err)
	}
	defer plugin.Stop(context.Background())
	messenger := &fakeInteractiveMessenger{}
	request := PluginRequest{Text: "/zzz login", ConversationID: "group-1", MessageType: "group", SenderID: "alice"}
	if handled, err := plugin.HandleInteractive(context.Background(), messenger, request); err != nil || !handled {
		t.Fatalf("HandleInteractive() = %v, %v", handled, err)
	}
	mys.mu.Lock()
	createCalls := mys.createCalls
	mys.mu.Unlock()
	if createCalls != 0 || !strings.Contains(messenger.allOutput(), "请私聊") {
		t.Fatalf("group login was not rejected: calls=%d output=%q", createCalls, messenger.allOutput())
	}
}

func TestZZZAccountScopedToolUsesRuntimeSenderOnly(t *testing.T) {
	store := openTestZZZAccountStore(t)
	for _, account := range []zzzAccountCredential{
		{OwnerID: "alice", MYSAccountID: "11111111", UID: "27280531", Cookie: "alice-cookie", SToken: "alice-stoken"},
		{OwnerID: "bob", MYSAccountID: "22222222", UID: "12345678", Cookie: "bob-cookie", SToken: "bob-stoken"},
	} {
		if err := store.PutAccount(context.Background(), account); err != nil {
			t.Fatal(err)
		}
	}
	plugin := newZZZAccountPluginWithDependencies(Config{}, store, &fakeZZZMYSService{})
	tool := &zzzAccountScopedTool{plugin: plugin}
	registry := NewToolRegistry()
	if err := registry.Register(tool); err != nil {
		t.Fatal(err)
	}
	runtime := NewToolRuntime(registry, DefaultToolPolicy(registry.Names()), nil, nil)
	session := runtime.NewSession(ToolScope{SenderID: "alice", VisibleTools: map[string]bool{zzzAccountToolName: true}})
	result := session.Execute(context.Background(), ToolCall{Name: zzzAccountToolName, Arguments: json.RawMessage(`{}`)})
	if !result.OK() || !strings.Contains(result.Projection.UserText, "27280531") || strings.Contains(result.Projection.UserText, "12345678") {
		t.Fatalf("scoped result = %#v", result)
	}

	malicious := runtime.NewSession(ToolScope{SenderID: "alice", VisibleTools: map[string]bool{zzzAccountToolName: true}}).
		Execute(context.Background(), ToolCall{Name: zzzAccountToolName, Arguments: json.RawMessage(`{"owner_id":"bob"}`)})
	if malicious.Failure == nil || malicious.Failure.Code != ToolFailureInvalidArguments {
		t.Fatalf("malicious scoped result = %#v", malicious)
	}
}

func TestZZZGachaToolProjectsNotBoundReasonForModelWithFallback(t *testing.T) {
	plugin := newZZZAccountPluginWithDependencies(Config{}, openTestZZZAccountStore(t), &fakeZZZMYSService{})
	tool := &zzzGachaScopedTool{plugin: plugin}
	output, err := tool.ExecuteScoped(context.Background(), ToolScope{SenderID: "alice"}, json.RawMessage(`{}`))
	if err != nil {
		t.Fatal(err)
	}
	projection, err := tool.Project(output)
	if err != nil {
		t.Fatal(err)
	}
	if tool.Spec().ReplyMode != ToolReplyViaModel || !strings.Contains(projection.UserText, "/zzz login") || projection.ModelText != projection.UserText {
		t.Fatalf("gacha projection=%#v spec=%#v", projection, tool.Spec())
	}
}

func TestZZZAbyssToolProjectsSafeUpstreamReasonForModelWithFallback(t *testing.T) {
	store := openTestZZZAccountStore(t)
	if err := store.PutAccount(context.Background(), zzzAccountCredential{
		OwnerID: "alice", MYSAccountID: "123456789", UID: "27280531", Cookie: "cookie", SToken: "stoken",
	}); err != nil {
		t.Fatal(err)
	}
	plugin := newZZZAccountPluginWithDependencies(Config{}, store, &fakeZZZMYSService{
		abyssErr: &zzzMYSFailure{Code: zzzMYSFailureRisk},
	})
	tool := &zzzAbyssScopedTool{plugin: plugin}
	output, err := tool.ExecuteScoped(context.Background(), ToolScope{SenderID: "alice"}, json.RawMessage(`{"schedule_type":1}`))
	if err != nil {
		t.Fatal(err)
	}
	projection, err := tool.Project(output)
	if err != nil {
		t.Fatal(err)
	}
	if tool.Spec().ReplyMode != ToolReplyViaModel || !strings.Contains(projection.UserText, "安全验证") || projection.ModelText != projection.UserText {
		t.Fatalf("abyss projection=%#v spec=%#v", projection, tool.Spec())
	}
}

func TestZZZAccountPluginSyncsGachaInBackground(t *testing.T) {
	store := openTestZZZAccountStore(t)
	if err := store.PutAccount(context.Background(), zzzAccountCredential{
		OwnerID: "alice", MYSAccountID: "123456789", UID: "27280531", Cookie: "cookie", SToken: "stoken",
	}); err != nil {
		t.Fatal(err)
	}
	plugin := newZZZAccountPluginWithDependencies(Config{}, store, &fakeZZZMYSService{})
	plugin.syncDelay = time.Millisecond
	plugin.syncTimeout = time.Second
	if err := plugin.Start(context.Background()); err != nil {
		t.Fatal(err)
	}
	defer plugin.Stop(context.Background())
	messenger := &fakeInteractiveMessenger{}
	request := PluginRequest{Text: "/zzz gacha sync", ConversationID: "private-alice-fairy", MessageType: "private", SenderID: "alice"}
	if handled, err := plugin.HandleInteractive(context.Background(), messenger, request); err != nil || !handled {
		t.Fatalf("HandleInteractive() = %v, %v", handled, err)
	}
	waitForZZZTest(t, time.Second, func() bool {
		summary, err := store.GachaSummary(context.Background(), "alice")
		return err == nil && summary.Total == 1 && !summary.SyncedAt.IsZero() && strings.Contains(messenger.allOutput(), "本次新增 1 条")
	})
	output := messenger.allOutput()
	if !strings.Contains(output, "本次新增 1 条") || strings.Contains(output, "authkey-secret") {
		t.Fatalf("sync output = %q", output)
	}
}

func TestBuiltinZZZAccountPluginStartsWithScopedTools(t *testing.T) {
	cfg := testConfig(t)
	cfg.ZZZAccountDB = t.TempDir() + "/zzz.db"
	cfg.ZZZCredentialKeyFile = t.TempDir() + "/zzz.key"
	cfg.PluginEnabled = cloneBoolMap(cfg.PluginEnabled)
	cfg.PluginEnabled[ZZZAccountPluginID] = true
	engine := NewEngine(cfg, nil, nil, NewBuiltinPlugins(cfg)...)
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), time.Second)
		defer cancel()
		if err := engine.ClosePlugins(ctx); err != nil {
			t.Error(err)
		}
	})
	if !engine.pluginRunning(ZZZAccountPluginID) {
		t.Fatal("builtin ZZZ account plugin did not start")
	}
	toolNames := engine.tools.registry.Names()
	for _, name := range []string{zzzAccountToolName, zzzGachaToolName, zzzAbyssToolName} {
		if !containsString(toolNames, name) {
			t.Fatalf("builtin tool %q is missing from %v", name, toolNames)
		}
	}
}

func waitForZZZTest(t *testing.T, timeout time.Duration, condition func() bool) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if condition() {
			return
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatal("condition was not met before timeout")
}

var _ zzzMYSService = (*fakeZZZMYSService)(nil)
var _ interactiveMessenger = (*fakeInteractiveMessenger)(nil)
