package gateway

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"
	"github.com/icradp/zzz-im-server/internal/store"
)

type pushDelivery struct {
	subscription *store.PushSubscription
	payload      map[string]interface{}
}

type fakePushSender struct {
	deliveries chan pushDelivery
}

func (f *fakePushSender) Enabled() bool     { return true }
func (f *fakePushSender) PublicKey() string { return "test-public-key" }

func (f *fakePushSender) Send(
	_ context.Context,
	subscription *store.PushSubscription,
	payload []byte,
) (bool, error) {
	var decoded map[string]interface{}
	if err := json.Unmarshal(payload, &decoded); err != nil {
		return false, err
	}
	f.deliveries <- pushDelivery{subscription: subscription, payload: decoded}
	return false, nil
}

func TestWebSocketChatHistoryAndPush(t *testing.T) {
	database := store.NewMemoryStore()
	pushSender := &fakePushSender{deliveries: make(chan pushDelivery, 1)}
	gateway := NewGateway(database, pushSender)

	server := httptest.NewServer(gateway)
	t.Cleanup(server.Close)
	websocketURL := "ws" + strings.TrimPrefix(server.URL, "http")

	alice := dialWebSocket(t, websocketURL)
	t.Cleanup(func() { _ = alice.Close() })
	bob := dialWebSocket(t, websocketURL)
	t.Cleanup(func() { _ = bob.Close() })

	authenticate(t, alice, "alice")
	authenticate(t, bob, "bob")

	pushConfig := request(t, bob, "get_push_config", map[string]interface{}{})
	data := responseData(t, pushConfig)
	if data["enabled"] != true || data["public_key"] != "test-public-key" {
		t.Fatalf("unexpected push config: %#v", data)
	}

	subscription := map[string]interface{}{
		"endpoint": "https://push.example.test/bob-device",
		"keys": map[string]interface{}{
			"p256dh": "p256dh-key",
			"auth":   "auth-key",
		},
	}
	assertOK(t, request(t, bob, "register_push", subscription))

	conversationID := "private_alice_bob"
	assertOK(t, request(t, alice, "ensure_conversation", map[string]interface{}{
		"conversation_id": conversationID,
		"type":            "private",
		"title":           "Alice and Bob",
		"participants":    []string{"alice", "bob"},
	}))

	sendResponse := request(t, alice, "send_message", map[string]interface{}{
		"conversation_id": conversationID,
		"message": []map[string]interface{}{
			{"type": "text", "data": map[string]interface{}{"text": "hello bob"}},
		},
	})
	assertOK(t, sendResponse)
	messageID, _ := responseData(t, sendResponse)["message_id"].(string)
	if messageID == "" {
		t.Fatal("send_message returned an empty message_id")
	}

	event := readJSON(t, bob)
	if event["post_type"] != "message" ||
		event["conversation_id"] != conversationID ||
		event["message_id"] != messageID {
		t.Fatalf("unexpected realtime message event: %#v", event)
	}

	select {
	case delivery := <-pushSender.deliveries:
		if delivery.subscription.UserID != "bob" ||
			delivery.payload["conversation_id"] != conversationID ||
			delivery.payload["body"] != "hello bob" {
			t.Fatalf("unexpected push delivery: %#v", delivery)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for Web Push delivery")
	}

	conversations := responseDataList(t, request(t, bob, "get_conversations", map[string]interface{}{}))
	if len(conversations) != 1 || conversations[0].(map[string]interface{})["conversation_id"] != conversationID {
		t.Fatalf("unexpected conversations: %#v", conversations)
	}

	messages := responseDataList(t, request(t, bob, "get_messages", map[string]interface{}{
		"conversation_id": conversationID,
		"limit":           100,
	}))
	if len(messages) != 1 || messages[0].(map[string]interface{})["message_id"] != messageID {
		t.Fatalf("unexpected message history: %#v", messages)
	}

	assertOK(t, request(t, bob, "unregister_push", map[string]interface{}{
		"endpoint": subscription["endpoint"],
	}))
	storedSubscriptions, err := database.GetPushSubscriptions("bob")
	if err != nil {
		t.Fatal(err)
	}
	if len(storedSubscriptions) != 0 {
		t.Fatalf("subscription was not deleted: %#v", storedSubscriptions)
	}
}

func TestWebSocketSharedTokenAuthenticationUsesExplicitUserID(t *testing.T) {
	database := store.NewMemoryStore()
	gateway := NewGateway(database)
	gateway.SetAccessToken("server-test-token")

	server := httptest.NewServer(gateway)
	t.Cleanup(server.Close)
	websocketURL := "ws" + strings.TrimPrefix(server.URL, "http")

	connection := dialWebSocket(t, websocketURL)
	t.Cleanup(func() { _ = connection.Close() })

	denied := request(t, connection, "auth", map[string]interface{}{
		"token":   "wrong-token",
		"user_id": "alice",
	})
	if denied["status"] == "ok" {
		t.Fatalf("invalid shared token was accepted: %#v", denied)
	}

	authenticated := request(t, connection, "auth", map[string]interface{}{
		"token":     "server-test-token",
		"user_id":   "alice",
		"device_id": "browser-a",
	})
	assertOK(t, authenticated)
	if responseData(t, authenticated)["user_id"] != "alice" {
		t.Fatalf("user identity did not come from user_id: %#v", authenticated)
	}
}

func (g *Gateway) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	g.HandleWebSocket(w, r)
}

func dialWebSocket(t *testing.T, url string) *websocket.Conn {
	t.Helper()
	connection, _, err := websocket.DefaultDialer.Dial(url, nil)
	if err != nil {
		t.Fatal(err)
	}
	return connection
}

func authenticate(t *testing.T, connection *websocket.Conn, userID string) {
	t.Helper()
	response := request(t, connection, "auth", map[string]interface{}{
		"token":   userID,
		"user_id": userID,
	})
	assertOK(t, response)
	if responseData(t, response)["user_id"] != userID {
		t.Fatalf("authenticated as unexpected user: %#v", response)
	}
}

func request(
	t *testing.T,
	connection *websocket.Conn,
	action string,
	params map[string]interface{},
) map[string]interface{} {
	t.Helper()
	echo := action + "-echo"
	if err := connection.WriteJSON(map[string]interface{}{
		"action": action,
		"params": params,
		"echo":   echo,
	}); err != nil {
		t.Fatal(err)
	}
	response := readJSON(t, connection)
	if response["echo"] != echo {
		t.Fatalf("unexpected response for %s: %#v", action, response)
	}
	return response
}

func readJSON(t *testing.T, connection *websocket.Conn) map[string]interface{} {
	t.Helper()
	if err := connection.SetReadDeadline(time.Now().Add(3 * time.Second)); err != nil {
		t.Fatal(err)
	}
	var value map[string]interface{}
	if err := connection.ReadJSON(&value); err != nil {
		t.Fatal(err)
	}
	return value
}

func assertOK(t *testing.T, response map[string]interface{}) {
	t.Helper()
	if response["status"] != "ok" || response["retcode"] != float64(0) {
		t.Fatalf("request failed: %#v", response)
	}
}

func responseData(t *testing.T, response map[string]interface{}) map[string]interface{} {
	t.Helper()
	data, ok := response["data"].(map[string]interface{})
	if !ok {
		t.Fatalf("response data is not an object: %#v", response)
	}
	return data
}

func responseDataList(t *testing.T, response map[string]interface{}) []interface{} {
	t.Helper()
	assertOK(t, response)
	data, ok := response["data"].([]interface{})
	if !ok {
		t.Fatalf("response data is not a list: %#v", response)
	}
	return data
}
