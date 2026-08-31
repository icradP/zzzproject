package gateway

import (
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/icradp/zzz-im-server/internal/store"
)

func TestAccountProfileAndGroupFlow(t *testing.T) {
	database := store.NewMemoryStore()
	gateway := NewGateway(database)
	gateway.SetInviteCode("diaogan")
	server := httptest.NewServer(gateway)
	t.Cleanup(server.Close)
	websocketURL := "ws" + strings.TrimPrefix(server.URL, "http")

	alice := dialWebSocket(t, websocketURL)
	t.Cleanup(func() { _ = alice.Close() })
	registered := request(t, alice, "register", map[string]interface{}{
		"user_id":     "alice-account",
		"password":    "correct horse battery staple",
		"nickname":    "Alice",
		"invite_code": "diaogan",
	})
	aliceSession := responseData(t, registered)["session_token"].(string)
	if aliceSession == "" {
		t.Fatal("registration did not return a session token")
	}

	bob := dialWebSocket(t, websocketURL)
	t.Cleanup(func() { _ = bob.Close() })
	bobRegistered := request(t, bob, "register", map[string]interface{}{
		"user_id":     "bob-account",
		"password":    "correct horse battery staple",
		"invite_code": "diaogan",
	})
	bobSession := responseData(t, bobRegistered)["session_token"].(string)

	login := request(t, alice, "auth", map[string]interface{}{
		"user_id":  "alice-account",
		"password": "correct horse battery staple",
	})
	if responseData(t, login)["session_token"] == "" {
		t.Fatal("password login did not return a session token")
	}
	assertOK(t, request(t, alice, "auth", map[string]interface{}{
		"session_token": aliceSession,
	}))
	assertOK(t, request(t, bob, "auth", map[string]interface{}{
		"session_token": bobSession,
	}))

	profile := request(t, alice, "update_profile", map[string]interface{}{
		"nickname":   "Alice Updated",
		"avatar_url": "/files/alice-avatar",
	})
	if responseData(t, profile)["nickname"] != "Alice Updated" {
		t.Fatalf("profile was not updated: %#v", profile)
	}
	if _, err := database.AddFriend("alice-account", "bob-account"); err != nil {
		t.Fatal(err)
	}

	group := request(t, alice, "create_group", map[string]interface{}{
		"name":    "Test Group",
		"members": []string{"bob-account"},
	})
	groupID, _ := responseData(t, group)["group_id"].(string)
	if groupID == "" {
		t.Fatal("group creation returned no id")
	}
	_ = readJSON(t, bob)
	info := request(t, bob, "get_group_info", map[string]interface{}{"group_id": groupID})
	if len(responseData(t, info)["members"].([]interface{})) != 2 {
		t.Fatalf("unexpected group members: %#v", info)
	}

	// A new gateway instance simulates a server restart while sharing the
	// persistent store. The original account session must remain valid.
	restartedGateway := NewGateway(database)
	restartedServer := httptest.NewServer(restartedGateway)
	t.Cleanup(restartedServer.Close)
	restartedURL := "ws" + strings.TrimPrefix(restartedServer.URL, "http")
	restartedClient := dialWebSocket(t, restartedURL)
	t.Cleanup(func() { _ = restartedClient.Close() })
	assertOK(t, request(t, restartedClient, "auth", map[string]interface{}{
		"session_token": aliceSession,
	}))

	logoutClient := dialWebSocket(t, restartedURL)
	t.Cleanup(func() { _ = logoutClient.Close() })
	assertOK(t, request(t, logoutClient, "logout", map[string]interface{}{
		"session_token": aliceSession,
	}))
	denied := request(t, logoutClient, "auth", map[string]interface{}{
		"session_token": aliceSession,
	})
	if denied["status"] == "ok" {
		t.Fatalf("revoked session was accepted: %#v", denied)
	}
}

func TestRegistrationRequiresConfiguredInviteCode(t *testing.T) {
	database := store.NewMemoryStore()
	gateway := NewGateway(database)
	gateway.SetInviteCode("diaogan")
	server := httptest.NewServer(gateway)
	t.Cleanup(server.Close)
	websocketURL := "ws" + strings.TrimPrefix(server.URL, "http")

	client := dialWebSocket(t, websocketURL)
	t.Cleanup(func() { _ = client.Close() })
	denied := request(t, client, "register", map[string]interface{}{
		"user_id":     "invite-test",
		"password":    "correct horse battery staple",
		"invite_code": "wrong-code",
	})
	if denied["status"] == "ok" {
		t.Fatalf("registration accepted an invalid invite: %#v", denied)
	}
	if user, _ := database.GetUser("invite-test"); user != nil {
		t.Fatal("invalid invitation created an account")
	}

	registered := request(t, client, "register", map[string]interface{}{
		"user_id":     "invite-test",
		"password":    "correct horse battery staple",
		"invite_code": "diaogan",
	})
	assertOK(t, registered)

	loginClient := dialWebSocket(t, websocketURL)
	t.Cleanup(func() { _ = loginClient.Close() })
	assertOK(t, request(t, loginClient, "auth", map[string]interface{}{
		"user_id":  "invite-test",
		"password": "correct horse battery staple",
	}))
}
