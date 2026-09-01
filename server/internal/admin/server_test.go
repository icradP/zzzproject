package admin

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/icradp/zzz-im-server/internal/protocol"
	"github.com/icradp/zzz-im-server/internal/store"
)

type registrationStub struct {
	code string
}

func (r *registrationStub) RegistrationEnabled() bool { return r.code != "" }
func (r *registrationStub) SetInviteCode(code string) { r.code = strings.TrimSpace(code) }

func TestAdminAuthenticationAndOverview(t *testing.T) {
	database := store.NewMemoryStore()
	seedAdminStore(t, database)
	registration := &registrationStub{code: "diaogan"}
	handler := New(Config{
		Store: database, Registration: registration, AdminToken: "secret-admin-token",
		PublicPath: "/admin", StorageDriver: "memory", PushEnabled: true,
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
		Stats   store.ServerStats      `json:"stats"`
		Service map[string]interface{} `json:"service"`
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
	if page.Code != http.StatusOK || !strings.Contains(page.Body.String(), "ZZZ IM Server") {
		t.Fatalf("admin page failed: %d", page.Code)
	}
	if page.Header().Get("Content-Security-Policy") == "" || page.Header().Get("X-Frame-Options") != "DENY" {
		t.Fatalf("missing static security headers: %#v", page.Header())
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
