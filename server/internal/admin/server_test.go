package admin

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/icradp/zzz-im-server/internal/clientperf"
	"github.com/icradp/zzz-im-server/internal/protocol"
	"github.com/icradp/zzz-im-server/internal/store"
	"golang.org/x/crypto/bcrypt"
)

type registrationStub struct {
	code string
}

type mediaStub struct {
	store *store.MemoryStore
}

func (m *mediaStub) Delete(id string) (bool, error) {
	file, err := m.store.GetMedia(id)
	if err != nil || file == nil {
		return false, err
	}
	return true, m.store.DeleteMedia(id)
}

func (r *registrationStub) RegistrationEnabled() bool { return r.code != "" }
func (r *registrationStub) SetInviteCode(code string) { r.code = strings.TrimSpace(code) }

func TestAdminAuthenticationAndOverview(t *testing.T) {
	database := store.NewMemoryStore()
	seedAdminStore(t, database)
	registration := &registrationStub{code: "diaogan"}
	performance := clientperf.New(10)
	if err := performance.Record(clientperf.Report{
		LoadKind: "cold", InteractiveMS: 4200, ResourceCount: 4, CacheHits: 1,
	}, time.Now()); err != nil {
		t.Fatal(err)
	}
	handler := New(Config{
		Store: database, Registration: registration, AdminToken: "secret-admin-token",
		Performance: performance,
		PublicPath:  "/admin", StorageDriver: "memory", PushEnabled: true,
		StartedAt: time.Now().Add(-time.Hour),
	})

	unauthorized := performRequest(handler, http.MethodGet, "/admin/api/overview", nil, nil, false)
	if unauthorized.Code != http.StatusUnauthorized {
		t.Fatalf("unauthorized status = %d", unauthorized.Code)
	}

	login := performRequest(handler, http.MethodPost, "/admin/api/session", map[string]interface{}{"token": "secret-admin-token"}, nil, false)
	if login.Code != http.StatusOK {
		t.Fatalf("login status = %d body=%s", login.Code, login.Body.String())
	}
	cookies := login.Result().Cookies()
	if len(cookies) != 1 || !cookies[0].HttpOnly || cookies[0].SameSite != http.SameSiteStrictMode || cookies[0].Path != "/admin" {
		t.Fatalf("unexpected admin cookie: %#v", cookies)
	}
	if strings.Contains(login.Body.String(), "secret-admin-token") || strings.Contains(cookies[0].Value, "secret-admin-token") {
		t.Fatal("admin token leaked into the session response")
	}

	overview := performRequest(handler, http.MethodGet, "/admin/api/overview", nil, cookies[0], false)
	if overview.Code != http.StatusOK {
		t.Fatalf("overview status = %d body=%s", overview.Code, overview.Body.String())
	}
	var payload struct {
		Stats       store.ServerStats      `json:"stats"`
		Service     map[string]interface{} `json:"service"`
		Performance clientperf.Snapshot    `json:"performance"`
	}
	if err := json.Unmarshal(overview.Body.Bytes(), &payload); err != nil {
		t.Fatal(err)
	}
	if payload.Stats.Users != 2 || payload.Stats.OnlineUsers != 1 || payload.Stats.Messages != 1 || payload.Stats.ActiveSessions != 1 {
		t.Fatalf("unexpected stats: %#v", payload.Stats)
	}
	if payload.Service["storage_driver"] != "memory" || payload.Service["registration_enabled"] != true {
		t.Fatalf("unexpected service state: %#v", payload.Service)
	}
	if payload.Performance.TotalSamples != 1 || payload.Performance.Cold.P50InteractiveMS != 4200 {
		t.Fatalf("unexpected performance snapshot: %#v", payload.Performance)
	}
}

func TestAdminManagementBoundaries(t *testing.T) {
	database := store.NewMemoryStore()
	seedAdminStore(t, database)
	registration := &registrationStub{code: "diaogan"}
	handler := New(Config{Store: database, Registration: registration, AdminToken: "admin", PublicPath: "/admin"})
	cookie := loginCookie(t, handler, "admin")

	missingHeader := performRequest(handler, http.MethodPatch, "/admin/api/users", map[string]interface{}{
		"user_id": "alice", "nickname": "Alice Updated",
	}, cookie, false)
	if missingHeader.Code != http.StatusForbidden {
		t.Fatalf("mutation without admin header = %d", missingHeader.Code)
	}

	updated := performRequest(handler, http.MethodPatch, "/admin/api/users", map[string]interface{}{
		"user_id": "alice", "nickname": "Alice Updated",
	}, cookie, true)
	if updated.Code != http.StatusOK {
		t.Fatalf("user update status = %d body=%s", updated.Code, updated.Body.String())
	}
	user, _ := database.GetUser("alice")
	if user.Nickname != "Alice Updated" {
		t.Fatalf("nickname = %q", user.Nickname)
	}

	groupConversation := performRequest(handler, http.MethodDelete, "/admin/api/conversations", map[string]interface{}{
		"conversation_id": "group-team",
	}, cookie, true)
	if groupConversation.Code != http.StatusConflict {
		t.Fatalf("group conversation deletion status = %d", groupConversation.Code)
	}

	deletedConversation := performRequest(handler, http.MethodDelete, "/admin/api/conversations", map[string]interface{}{
		"conversation_id": "private-alice-bob",
	}, cookie, true)
	if deletedConversation.Code != http.StatusNoContent {
		t.Fatalf("conversation deletion status = %d body=%s", deletedConversation.Code, deletedConversation.Body.String())
	}
	conversation, _ := database.GetConversation("private-alice-bob")
	if conversation != nil {
		t.Fatal("private conversation was not deleted")
	}

	disabled := performRequest(handler, http.MethodPatch, "/admin/api/settings/registration", map[string]interface{}{
		"enabled": false, "invite_code": "",
	}, cookie, true)
	if disabled.Code != http.StatusOK || registration.RegistrationEnabled() {
		t.Fatalf("registration was not disabled: %d", disabled.Code)
	}

	missingInvite := performRequest(handler, http.MethodPatch, "/admin/api/settings/registration", map[string]interface{}{
		"enabled": true, "invite_code": "",
	}, cookie, true)
	if missingInvite.Code != http.StatusBadRequest {
		t.Fatalf("registration enabled without code: %d", missingInvite.Code)
	}

	enabled := performRequest(handler, http.MethodPatch, "/admin/api/settings/registration", map[string]interface{}{
		"enabled": true, "invite_code": "new-invite",
	}, cookie, true)
	if enabled.Code != http.StatusOK || registration.code != "new-invite" {
		t.Fatalf("registration was not updated: status=%d code=%q", enabled.Code, registration.code)
	}

	deletedGroup := performRequest(handler, http.MethodDelete, "/admin/api/groups", map[string]interface{}{
		"group_id": "group-team",
	}, cookie, true)
	if deletedGroup.Code != http.StatusNoContent {
		t.Fatalf("group deletion status = %d body=%s", deletedGroup.Code, deletedGroup.Body.String())
	}
	group, _ := database.GetGroup("group-team")
	if group != nil {
		t.Fatal("group was not deleted")
	}
}

func TestAdminLoginRateLimitAndStaticSecurity(t *testing.T) {
	handler := New(Config{
		Store: store.NewMemoryStore(), Registration: &registrationStub{}, AdminToken: "admin", PublicPath: "/admin",
	})
	for attempt := 0; attempt < maxLoginFailure; attempt++ {
		response := performRequest(handler, http.MethodPost, "/admin/api/session", map[string]interface{}{"token": "wrong"}, nil, false)
		if response.Code != http.StatusUnauthorized {
			t.Fatalf("attempt %d status = %d", attempt+1, response.Code)
		}
	}
	blocked := performRequest(handler, http.MethodPost, "/admin/api/session", map[string]interface{}{"token": "admin"}, nil, false)
	if blocked.Code != http.StatusTooManyRequests || blocked.Header().Get("Retry-After") == "" {
		t.Fatalf("blocked status = %d retry=%q", blocked.Code, blocked.Header().Get("Retry-After"))
	}

	page := performRequest(handler, http.MethodGet, "/admin/", nil, nil, false)
	if page.Code != http.StatusOK || !strings.Contains(page.Body.String(), "ZZZ IM Server") ||
		!strings.Contains(page.Body.String(), `id="view-fairy"`) ||
		!strings.Contains(page.Body.String(), `id="fairy-config-form"`) ||
		!strings.Contains(page.Body.String(), `id="view-terminal"`) {
		t.Fatalf("admin page failed: %d", page.Code)
	}
	for _, marker := range []string{
		`data-fairy-section="runtime"`,
		`data-fairy-section="models"`,
		`data-fairy-section="behavior"`,
		`data-fairy-section="plugins"`,
		`data-fairy-section="decisions"`,
		`id="fairy-decision-list"`,
		`id="fairy-decision-detail"`,
		`id="fairy-refresh-decisions"`,
		`id="terminal-activities-body"`,
		`id="terminal-vaults-body"`,
		`id="terminal-dialog"`,
	} {
		if !strings.Contains(page.Body.String(), marker) {
			t.Fatalf("admin Fairy navigation is missing %s", marker)
		}
	}
	if page.Header().Get("Content-Security-Policy") == "" || page.Header().Get("X-Frame-Options") != "DENY" {
		t.Fatalf("missing static security headers: %#v", page.Header())
	}
}

func TestAdminContentAndPasswordManagement(t *testing.T) {
	database := store.NewMemoryStore()
	seedAdminStore(t, database)
	if err := database.StoreMedia(&store.MediaFile{
		ID: "media-one", FileName: "photo.png", FileType: "image", MimeType: "image/png",
		Size: 128, URL: "/files/media-one/photo.png", UploaderID: "alice", CreatedAt: time.Now(),
	}); err != nil {
		t.Fatal(err)
	}
	handler := New(Config{
		Store: database, Media: &mediaStub{store: database}, Registration: &registrationStub{code: "diaogan"},
		AdminToken: "admin", PublicPath: "/admin",
	})
	cookie := loginCookie(t, handler, "admin")

	messages := performRequest(handler, http.MethodGet, "/admin/api/messages", nil, cookie, false)
	if messages.Code != http.StatusOK {
		t.Fatalf("messages status=%d body=%s", messages.Code, messages.Body.String())
	}
	var messagePayload struct {
		Messages []*store.Message `json:"messages"`
	}
	if err := json.Unmarshal(messages.Body.Bytes(), &messagePayload); err != nil || len(messagePayload.Messages) != 1 {
		t.Fatalf("messages payload=%#v err=%v", messagePayload, err)
	}
	deletedMessage := performRequest(handler, http.MethodDelete, "/admin/api/messages", map[string]interface{}{
		"message_id": messagePayload.Messages[0].ID,
	}, cookie, true)
	if deletedMessage.Code != http.StatusNoContent {
		t.Fatalf("message delete status=%d body=%s", deletedMessage.Code, deletedMessage.Body.String())
	}

	media := performRequest(handler, http.MethodGet, "/admin/api/media", nil, cookie, false)
	if media.Code != http.StatusOK || !strings.Contains(media.Body.String(), "photo.png") {
		t.Fatalf("media status=%d body=%s", media.Code, media.Body.String())
	}
	deletedMedia := performRequest(handler, http.MethodDelete, "/admin/api/media", map[string]interface{}{
		"media_id": "media-one",
	}, cookie, true)
	if deletedMedia.Code != http.StatusNoContent {
		t.Fatalf("media delete status=%d body=%s", deletedMedia.Code, deletedMedia.Body.String())
	}

	reset := performRequest(handler, http.MethodPatch, "/admin/api/users/password", map[string]interface{}{
		"user_id": "alice", "password": "new secure password",
	}, cookie, true)
	if reset.Code != http.StatusOK {
		t.Fatalf("password reset status=%d body=%s", reset.Code, reset.Body.String())
	}
	if strings.Contains(reset.Body.String(), "new secure password") || strings.Contains(reset.Body.String(), "password_hash") {
		t.Fatal("password data leaked in response")
	}
	user, err := database.GetUser("alice")
	if err != nil || bcrypt.CompareHashAndPassword([]byte(user.PasswordHash), []byte("new secure password")) != nil {
		t.Fatalf("password hash was not updated: user=%#v err=%v", user, err)
	}
	if session, err := database.GetSession("active"); err != nil || session != nil {
		t.Fatalf("account session was not revoked: session=%#v err=%v", session, err)
	}
	if session, err := database.GetSession("expired"); err != nil || session == nil {
		t.Fatalf("other account session changed: session=%#v err=%v", session, err)
	}

	granted := performRequest(handler, http.MethodPost, "/admin/api/titles", map[string]interface{}{
		"user_id": "alice", "text": "Founder", "style": "gold",
	}, cookie, true)
	if granted.Code != http.StatusCreated {
		t.Fatalf("title grant status=%d body=%s", granted.Code, granted.Body.String())
	}
	titles := performRequest(handler, http.MethodGet, "/admin/api/titles?user_id=alice", nil, cookie, false)
	if titles.Code != http.StatusOK || !strings.Contains(titles.Body.String(), "Founder") {
		t.Fatalf("titles status=%d body=%s", titles.Code, titles.Body.String())
	}
	var titlePayload struct {
		Title store.UserTitle `json:"title"`
	}
	if err := json.Unmarshal(granted.Body.Bytes(), &titlePayload); err != nil {
		t.Fatal(err)
	}
	revoked := performRequest(handler, http.MethodDelete, "/admin/api/titles", map[string]interface{}{
		"title_id": titlePayload.Title.ID,
	}, cookie, true)
	if revoked.Code != http.StatusNoContent {
		t.Fatalf("title revoke status=%d body=%s", revoked.Code, revoked.Body.String())
	}

	if err := database.CreateUserReport(&store.UserReport{
		ID: "report-one", ReporterID: "bob", TargetID: "alice",
		Reason: "spam", Details: "Repeated links", CreatedAt: time.Now(),
	}); err != nil {
		t.Fatal(err)
	}
	reports := performRequest(handler, http.MethodGet, "/admin/api/reports", nil, cookie, false)
	if reports.Code != http.StatusOK || !strings.Contains(reports.Body.String(), "Repeated links") {
		t.Fatalf("reports status=%d body=%s", reports.Code, reports.Body.String())
	}
}

func TestAdminTerminalActivityDoesNotExposeVaultPayload(t *testing.T) {
	database := store.NewMemoryStore()
	seedAdminStore(t, database)
	conversationID := "private-alice-bob"
	requestID := "term-request-1"
	if _, err := database.StoreMessage(conversationID, "fairy", "Fairy", []protocol.MessageSegment{
		protocol.TextSegment("Requesting host status"),
		protocol.TerminalRequestSegment(requestID, "run_command", "workstation", "uptime", time.Now().Add(time.Minute).UnixMilli()),
	}); err != nil {
		t.Fatal(err)
	}
	if _, err := database.StoreMessage(conversationID, "alice", "Alice", []protocol.MessageSegment{
		protocol.TextSegment("Completed"),
		{Type: "terminal_result", Data: map[string]interface{}{
			"request_id": requestID, "status": "completed", "output": "up 3 days", "exit_code": int64(0),
		}},
	}); err != nil {
		t.Fatal(err)
	}
	if _, err := database.StoreMessage(conversationID, "fairy", "Fairy", []protocol.MessageSegment{
		protocol.TerminalRequestSegment("term-expired", "list_hosts", "", "", time.Now().Add(-time.Minute).UnixMilli()),
	}); err != nil {
		t.Fatal(err)
	}
	if _, err := database.PutTerminalVault("alice", "client-secret-envelope", 0); err != nil {
		t.Fatal(err)
	}
	handler := New(Config{Store: database, Registration: &registrationStub{}, AdminToken: "admin", PublicPath: "/admin"})
	cookie := loginCookie(t, handler, "admin")
	response := performRequest(handler, http.MethodGet, "/admin/api/terminal?limit=20", nil, cookie, false)
	if response.Code != http.StatusOK {
		t.Fatalf("terminal status=%d body=%s", response.Code, response.Body.String())
	}
	if strings.Contains(response.Body.String(), "client-secret-envelope") {
		t.Fatal("terminal vault payload leaked through admin API")
	}
	var payload struct {
		Overview struct {
			Requests         int `json:"requests"`
			Results          int `json:"results"`
			Completed        int `json:"completed"`
			Expired          int `json:"expired"`
			VaultsConfigured int `json:"vaults_configured"`
		} `json:"overview"`
		Activities []struct {
			RequestID string `json:"request_id"`
			Kind      string `json:"kind"`
			Status    string `json:"status"`
		} `json:"activities"`
		Vaults []struct {
			PayloadBytes int `json:"payload_bytes"`
		} `json:"vaults"`
	}
	if err := json.Unmarshal(response.Body.Bytes(), &payload); err != nil {
		t.Fatal(err)
	}
	if payload.Overview.Requests != 2 || payload.Overview.Results != 1 || payload.Overview.Completed != 1 || payload.Overview.Expired != 1 || payload.Overview.VaultsConfigured != 1 {
		t.Fatalf("unexpected terminal overview: %#v", payload.Overview)
	}
	if len(payload.Activities) != 3 || len(payload.Vaults) != 1 || payload.Vaults[0].PayloadBytes != len("client-secret-envelope") {
		t.Fatalf("unexpected terminal payload: activities=%#v vaults=%#v", payload.Activities, payload.Vaults)
	}
}

func seedAdminStore(t *testing.T, database *store.MemoryStore) {
	t.Helper()
	for _, user := range []*store.User{
		{ID: "alice", Nickname: "Alice", Online: true, CreatedAt: time.Now().Add(-time.Hour)},
		{ID: "bob", Nickname: "Bob", CreatedAt: time.Now().Add(-30 * time.Minute)},
	} {
		if err := database.SetUser(user); err != nil {
			t.Fatal(err)
		}
	}
	private := &store.Conversation{ID: "private-alice-bob", Type: "private", Title: "Alice and Bob", Participants: []string{"alice", "bob"}, CreatedAt: time.Now()}
	if err := database.SaveConversation(private); err != nil {
		t.Fatal(err)
	}
	if _, err := database.StoreMessage(private.ID, "alice", "Alice", []protocol.MessageSegment{{Type: "text", Data: map[string]interface{}{"text": "hello"}}}); err != nil {
		t.Fatal(err)
	}
	if _, err := database.CreateGroup("group-team", "Team", "", "alice"); err != nil {
		t.Fatal(err)
	}
	if _, err := database.AddGroupMember("group-team", "bob"); err != nil {
		t.Fatal(err)
	}
	if err := database.SaveConversation(&store.Conversation{ID: "group-team", Type: "group", Title: "Team", OwnerID: "alice", Participants: []string{"alice", "bob"}, CreatedAt: time.Now()}); err != nil {
		t.Fatal(err)
	}
	if err := database.UpsertSession(&store.Session{TokenHash: "active", UserID: "alice", ExpiresAt: time.Now().Add(time.Hour)}); err != nil {
		t.Fatal(err)
	}
	if err := database.UpsertSession(&store.Session{TokenHash: "expired", UserID: "bob", ExpiresAt: time.Now().Add(-time.Hour)}); err != nil {
		t.Fatal(err)
	}
}

func loginCookie(t *testing.T, handler http.Handler, token string) *http.Cookie {
	t.Helper()
	response := performRequest(handler, http.MethodPost, "/admin/api/session", map[string]interface{}{"token": token}, nil, false)
	if response.Code != http.StatusOK || len(response.Result().Cookies()) != 1 {
		t.Fatalf("login failed: %d %s", response.Code, response.Body.String())
	}
	return response.Result().Cookies()[0]
}

func performRequest(handler http.Handler, method, path string, body interface{}, cookie *http.Cookie, adminHeader bool) *httptest.ResponseRecorder {
	var requestBody *bytes.Reader
	if body == nil {
		requestBody = bytes.NewReader(nil)
	} else {
		encoded, _ := json.Marshal(body)
		requestBody = bytes.NewReader(encoded)
	}
	request := httptest.NewRequest(method, path, requestBody)
	request.RemoteAddr = "192.0.2.1:1234"
	if cookie != nil {
		request.AddCookie(cookie)
	}
	if adminHeader {
		request.Header.Set("X-ZZZ-Admin", "1")
	}
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	return response
}
