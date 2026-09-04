package gateway

import (
	"strings"
	"testing"
	"time"

	"net/http/httptest"

	"github.com/icradp/zzz-im-server/internal/protocol"
	"github.com/icradp/zzz-im-server/internal/store"
)

func TestTerminalVaultIsScopedToAuthenticatedAccount(t *testing.T) {
	gateway := NewGateway(store.NewMemoryStore())
	server := httptest.NewServer(gateway)
	t.Cleanup(server.Close)
	websocketURL := "ws" + strings.TrimPrefix(server.URL, "http")
	alice := dialWebSocket(t, websocketURL)
	bob := dialWebSocket(t, websocketURL)
	t.Cleanup(func() { _ = alice.Close() })
	t.Cleanup(func() { _ = bob.Close() })
	authenticate(t, alice, "alice")
	authenticate(t, bob, "bob")

	assertOK(t, request(t, alice, protocol.ActionPutTerminalVault, map[string]interface{}{
		"payload": "opaque-ciphertext", "expected_revision": 0,
	}))
	aliceVault := responseData(t, request(t, alice, protocol.ActionGetTerminalVault, map[string]interface{}{}))
	if aliceVault["payload"] != "opaque-ciphertext" || aliceVault["revision"] != float64(1) {
		t.Fatalf("unexpected Alice vault: %#v", aliceVault)
	}
	bobVault := responseData(t, request(t, bob, protocol.ActionGetTerminalVault, map[string]interface{}{}))
	if bobVault["revision"] != float64(0) || bobVault["payload"] != nil {
		t.Fatalf("Alice vault leaked to Bob: %#v", bobVault)
	}
	conflict := request(t, alice, protocol.ActionPutTerminalVault, map[string]interface{}{
		"payload": "stale", "expected_revision": 0,
	})
	if conflict["retcode"] != float64(409) {
		t.Fatalf("expected revision conflict: %#v", conflict)
	}
}

func TestTerminalMessageValidation(t *testing.T) {
	valid := protocol.TerminalRequestSegment(
		"term-123", "run_command", "production", "uptime", time.Now().Add(time.Minute).UnixMilli(),
	)
	if err := validateTerminalSegment(valid, "private"); err != nil {
		t.Fatalf("valid terminal request rejected: %v", err)
	}
	if err := validateTerminalSegment(valid, "group"); err == nil {
		t.Fatal("group terminal request was accepted")
	}
	expired := protocol.TerminalRequestSegment(
		"term-124", "run_command", "production", "uptime", time.Now().Add(-2*time.Minute).UnixMilli(),
	)
	if err := validateTerminalSegment(expired, "private"); err == nil {
		t.Fatal("expired terminal request was accepted")
	}
}
