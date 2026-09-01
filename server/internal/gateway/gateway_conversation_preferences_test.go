package gateway

import (
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/icradp/zzz-im-server/internal/store"
)

func TestConversationNotificationLevelsFilterPushWithoutDroppingUnread(t *testing.T) {
	database := store.NewMemoryStore()
	pushSender := &fakePushSender{deliveries: make(chan pushDelivery, 4)}
	gateway := NewGateway(database, pushSender)
	server := httptest.NewServer(gateway)
	t.Cleanup(server.Close)
	websocketURL := "ws" + strings.TrimPrefix(server.URL, "http")

	alice := dialWebSocket(t, websocketURL)
	bob := dialWebSocket(t, websocketURL)
	t.Cleanup(func() { _ = alice.Close() })
	t.Cleanup(func() { _ = bob.Close() })
	authenticate(t, alice, "alice")
	authenticate(t, bob, "bob")
	if _, err := database.AddFriend("alice", "bob"); err != nil {
		t.Fatal(err)
	}

	assertOK(t, request(t, bob, "register_push", map[string]interface{}{
		"endpoint": "https://push.example.test/bob-muted",
		"keys": map[string]interface{}{
			"p256dh": "p256dh-key",
			"auth":   "auth-key",
		},
	}))
	conversationID := "private_alice_bob"
	assertOK(t, request(t, alice, "ensure_conversation", map[string]interface{}{
		"conversation_id": conversationID,
		"type":            "private",
		"title":           "Alice and Bob",
		"participants":    []string{"alice", "bob"},
	}))
	assertOK(t, request(t, bob, "set_conversation_preferences", map[string]interface{}{
		"conversation_id":    conversationID,
		"is_pinned":          true,
		"notification_level": "muted",
	}))
	preferenceNotice := readJSON(t, bob)
	if preferenceNotice["notice_type"] != "conversation_preferences" ||
		preferenceNotice["is_pinned"] != true || preferenceNotice["is_muted"] != true ||
		preferenceNotice["notification_level"] != "muted" {
		t.Fatalf("unexpected preference notice: %#v", preferenceNotice)
	}

	conversations := responseDataList(t, request(t, bob, "get_conversations", map[string]interface{}{}))
	conversation := conversations[0].(map[string]interface{})
	if conversation["is_pinned"] != true || conversation["is_muted"] != true ||
		conversation["notification_level"] != "muted" {
		t.Fatalf("preferences missing from conversation: %#v", conversation)
	}

	assertOK(t, request(t, alice, "send_message", map[string]interface{}{
		"conversation_id": conversationID,
		"message": []map[string]interface{}{
			{"type": "text", "data": map[string]interface{}{"text": "quiet message"}},
		},
	}))
	messageEvent := readJSON(t, bob)
	if messageEvent["post_type"] != "message" {
		t.Fatalf("muted conversation lost realtime delivery: %#v", messageEvent)
	}
	select {
	case delivery := <-pushSender.deliveries:
		t.Fatalf("muted conversation produced push delivery: %#v", delivery)
	case <-time.After(250 * time.Millisecond):
	}
	conversations = responseDataList(t, request(t, bob, "get_conversations", map[string]interface{}{}))
	conversation = conversations[0].(map[string]interface{})
	if conversation["unread_count"] != float64(1) {
		t.Fatalf("muted message did not accumulate unread state: %#v", conversation)
	}

	assertOK(t, request(t, bob, "set_conversation_preferences", map[string]interface{}{
		"conversation_id":    conversationID,
		"is_pinned":          true,
		"notification_level": "mentions_only",
	}))
	preferenceNotice = readJSON(t, bob)
	if preferenceNotice["notification_level"] != "mentions_only" || preferenceNotice["is_muted"] != false {
		t.Fatalf("unexpected mentions-only notice: %#v", preferenceNotice)
	}
	assertOK(t, request(t, alice, "send_message", map[string]interface{}{
		"conversation_id": conversationID,
		"message": []map[string]interface{}{
			{"type": "text", "data": map[string]interface{}{"text": "ordinary message"}},
		},
	}))
	_ = readJSON(t, bob)
	select {
	case delivery := <-pushSender.deliveries:
		t.Fatalf("ordinary message produced mentions-only push: %#v", delivery)
	case <-time.After(250 * time.Millisecond):
	}

	assertOK(t, request(t, alice, "send_message", map[string]interface{}{
		"conversation_id": conversationID,
		"message": []map[string]interface{}{
			{"type": "at", "data": map[string]interface{}{"qq": "bob"}},
			{"type": "text", "data": map[string]interface{}{"text": "please review"}},
		},
	}))
	_ = readJSON(t, bob)
	select {
	case delivery := <-pushSender.deliveries:
		if delivery.subscription.UserID != "bob" {
			t.Fatalf("mention push reached wrong user: %#v", delivery)
		}
	case <-time.After(time.Second):
		t.Fatal("mention did not produce push delivery")
	}
}
