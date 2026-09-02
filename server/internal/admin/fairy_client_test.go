package admin

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/icradp/zzz-im-server/internal/store"
)

type fairyControllerStub struct {
	method string
	body   string
	status int
	result string
}

func (f *fairyControllerStub) Request(_ context.Context, method string, body []byte) (int, []byte, error) {
	f.method = method
	f.body = string(body)
	return f.status, []byte(f.result), nil
}

func TestFairyHTTPControllerRequiresLoopbackAndProtectsToken(t *testing.T) {
	if _, err := NewFairyHTTPController("https://example.test/admin", "token"); err == nil {
		t.Fatal("public Fairy admin URL was accepted")
	}
	if _, err := NewFairyHTTPController("http://127.0.0.1:18081/admin", ""); err == nil {
		t.Fatal("empty Fairy admin token was accepted")
	}

	var upstreamMethod string
	upstream := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		upstreamMethod = request.Method
		if request.URL.Path != "/admin/config" || request.Header.Get("Authorization") != "Bearer local-secret" {
			t.Fatalf("unexpected upstream request path=%q auth=%q", request.URL.Path, request.Header.Get("Authorization"))
		}
		response.Header().Set("Content-Type", "application/json")
		_, _ = response.Write([]byte(`{"ok":true}`))
	}))
	defer upstream.Close()
	controller, err := NewFairyHTTPController(upstream.URL+"/admin", "local-secret")
	if err != nil {
		t.Fatal(err)
	}
	status, payload, err := controller.Request(context.Background(), http.MethodPatch, []byte(`{}`))
	if err != nil || status != http.StatusOK || upstreamMethod != http.MethodPatch || string(payload) != `{"ok":true}` {
		t.Fatalf("proxy status=%d method=%q payload=%s err=%v", status, upstreamMethod, payload, err)
	}
}

func TestAdminConsoleProxiesFairyConfiguration(t *testing.T) {
	fairy := &fairyControllerStub{
		status: http.StatusOK,
		result: `{"connected":true,"config":{"model_api_key_configured":true},"plugins":[]}`,
	}
	handler := New(Config{
		Store: store.NewMemoryStore(), Registration: &registrationStub{}, Fairy: fairy,
		AdminToken: "admin", PublicPath: "/admin",
	})
	cookie := loginCookie(t, handler, "admin")

	loaded := performRequest(handler, http.MethodGet, "/admin/api/fairy/config", nil, cookie, false)
	if loaded.Code != http.StatusOK || fairy.method != http.MethodGet || !strings.Contains(loaded.Body.String(), `"connected":true`) {
		t.Fatalf("Fairy GET status=%d method=%q body=%s", loaded.Code, fairy.method, loaded.Body.String())
	}
	patched := performRequest(handler, http.MethodPatch, "/admin/api/fairy/config", map[string]interface{}{
		"model_name": "test-model",
	}, cookie, true)
	if patched.Code != http.StatusOK || fairy.method != http.MethodPatch || !strings.Contains(fairy.body, "test-model") {
		t.Fatalf("Fairy PATCH status=%d method=%q body=%q", patched.Code, fairy.method, fairy.body)
	}
}
