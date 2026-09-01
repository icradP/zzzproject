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
	if _, err := database.AddFriend("alice", "bob"); err != nil {
		t.Fatal(err)
	}

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
	if conversations[0].(map[string]interface{})["unread_count"] != float64(1) {
		t.Fatalf("unexpected unread count before mark_read: %#v", conversations)
	}
	aliceConversations := responseDataList(t, request(t, alice, "get_conversations", map[string]interface{}{}))
	if aliceConversations[0].(map[string]interface{})["unread_count"] != float64(0) {
		t.Fatalf("sender's own message counted as unread: %#v", aliceConversations)
	}

	messages := responseDataList(t, request(t, bob, "get_messages", map[string]interface{}{
		"conversation_id": conversationID,
		"limit":           100,
	}))
	if len(messages) != 1 || messages[0].(map[string]interface{})["message_id"] != messageID {
		t.Fatalf("unexpected message history: %#v", messages)
	}

	assertOK(t, request(t, bob, "mark_read", map[string]interface{}{
		"conversation_id": conversationID,
	}))
	readNotice := readJSON(t, alice)
	if readNotice["notice_type"] != "message_read" ||
		readNotice["conversation_id"] != conversationID ||
		readNotice["last_read_message_id"] != messageID ||
		readNotice["user_id"] != "bob" {
		t.Fatalf("unexpected message read notice: %#v", readNotice)
	}
	conversations = responseDataList(t, request(t, bob, "get_conversations", map[string]interface{}{}))
	if conversations[0].(map[string]interface{})["unread_count"] != float64(0) {
		t.Fatalf("unread count was not cleared: %#v", conversations)
	}
	aliceMessages := responseDataList(t, request(t, alice, "get_messages", map[string]interface{}{
		"conversation_id": conversationID,
		"limit":           100,
	}))
	if aliceMessages[0].(map[string]interface{})["status"] != "read" ||
		aliceMessages[0].(map[string]interface{})["read_count"] != float64(1) ||
		aliceMessages[0].(map[string]interface{})["recipient_count"] != float64(1) {
		t.Fatalf("sender did not receive canonical read status: %#v", aliceMessages)
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

func TestWebSocketDeliversToMultipleDevicesAndKeepsPresenceUntilLastDisconnect(t *testing.T) {
	database := store.NewMemoryStore()
	gateway := NewGateway(database)
	server := httptest.NewServer(gateway)
	t.Cleanup(server.Close)
	websocketURL := "ws" + strings.TrimPrefix(server.URL, "http")

	aliceDesktop := dialWebSocket(t, websocketURL)
	t.Cleanup(func() { _ = aliceDesktop.Close() })
	aliceMobile := dialWebSocket(t, websocketURL)
	t.Cleanup(func() { _ = aliceMobile.Close() })
	bob := dialWebSocket(t, websocketURL)
	t.Cleanup(func() { _ = bob.Close() })
	authenticate(t, aliceDesktop, "alice")
	authenticate(t, aliceMobile, "alice")
	authenticate(t, bob, "bob")
	if _, err := database.AddFriend("alice", "bob"); err != nil {
		t.Fatal(err)
	}

	const conversationID = "private_alice_bob_multi_device"
	assertOK(t, request(t, aliceDesktop, "ensure_conversation", map[string]interface{}{
		"conversation_id": conversationID,
		"type":            "private",
		"participants":    []string{"alice", "bob"},
	}))

	send := request(t, bob, "send_message", map[string]interface{}{
		"conversation_id": conversationID,
		"message": []map[string]interface{}{
			{"type": "text", "data": map[string]interface{}{"text": "hello both devices"}},
		},
	})
	assertOK(t, send)
	messageID := responseData(t, send)["message_id"]
	for name, connection := range map[string]*websocket.Conn{
		"desktop": aliceDesktop,
		"mobile":  aliceMobile,
	} {
		event := readJSON(t, connection)
		if event["post_type"] != "message" ||
			event["conversation_id"] != conversationID ||
			event["message_id"] != messageID {
			t.Fatalf("%s did not receive the message event: %#v", name, event)
		}
	}

	// Closing one device must not make the account appear offline while the
	// second device is still connected.
	_ = aliceDesktop.Close()
	time.Sleep(50 * time.Millisecond)
	user := responseData(t, request(t, bob, "get_user", map[string]interface{}{
		"user_id": "alice",
	}))
	if user["online"] != true {
		t.Fatalf("alice went offline while another device was connected: %#v", user)
	}

	_ = aliceMobile.Close()
	presence := readJSON(t, bob)
	if presence["notice_type"] != "friend_presence" ||
		presence["user_id"] != "alice" ||
		presence["online"] != false {
		t.Fatalf("unexpected final-device presence notice: %#v", presence)
	}
	time.Sleep(50 * time.Millisecond)
	storedUser, err := database.GetUser("alice")
	if err != nil || storedUser == nil || storedUser.Online {
		t.Fatalf("alice remained online after the last device disconnected: %#v", storedUser)
	}
}

func TestFriendPresenceChangesOnlyOnFirstAndLastDevice(t *testing.T) {
	database := store.NewMemoryStore()
	for _, userID := range []string{"alice", "bob"} {
		if err := database.SetUser(&store.User{ID: userID, Nickname: userID}); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := database.AddFriend("alice", "bob"); err != nil {
		t.Fatal(err)
	}
	gateway := NewGateway(database)
	server := httptest.NewServer(gateway)
	t.Cleanup(server.Close)
	websocketURL := "ws" + strings.TrimPrefix(server.URL, "http")

	bob := dialWebSocket(t, websocketURL)
	t.Cleanup(func() { _ = bob.Close() })
	authenticate(t, bob, "bob")
	events := make(chan map[string]interface{}, 4)
	errors := make(chan error, 1)
	go func() {
		for {
			var event map[string]interface{}
			if err := bob.ReadJSON(&event); err != nil {
				errors <- err
				return
			}
			events <- event
		}
	}()

	aliceDesktop := dialWebSocket(t, websocketURL)
	t.Cleanup(func() { _ = aliceDesktop.Close() })
	authenticate(t, aliceDesktop, "alice")
	assertPresenceEvent(t, events, errors, "alice", true)

	aliceMobile := dialWebSocket(t, websocketURL)
	t.Cleanup(func() { _ = aliceMobile.Close() })
	authenticate(t, aliceMobile, "alice")
	assertNoPresenceEvent(t, events, errors)

	_ = aliceDesktop.Close()
	assertNoPresenceEvent(t, events, errors)
	_ = aliceMobile.Close()
	assertPresenceEvent(t, events, errors, "alice", false)
}

func TestFailedAndRepeatedAuthenticationDoNotLeakClientRegistrations(t *testing.T) {
	database := store.NewMemoryStore()
	gateway := NewGateway(database)
	gateway.SetAccessToken("shared-secret")
	server := httptest.NewServer(gateway)
	t.Cleanup(server.Close)
	websocketURL := "ws" + strings.TrimPrefix(server.URL, "http")

	connection := dialWebSocket(t, websocketURL)
	t.Cleanup(func() { _ = connection.Close() })
	failed := request(t, connection, "auth", map[string]interface{}{
		"token": "wrong-secret", "user_id": "alice",
	})
	if failed["status"] == "ok" {
		t.Fatalf("invalid credentials were accepted: %#v", failed)
	}
	gateway.mu.RLock()
	registeredAfterFailure := len(gateway.clients)
	gateway.mu.RUnlock()
	if registeredAfterFailure != 0 {
		t.Fatalf("failed authentication registered a client: %#v", gateway.clients)
	}

	assertOK(t, request(t, connection, "auth", map[string]interface{}{
		"token": "shared-secret", "user_id": "alice",
	}))
	repeated := request(t, connection, "auth", map[string]interface{}{
		"token": "shared-secret", "user_id": "bob",
	})
	if repeated["status"] == "ok" {
		t.Fatalf("connection switched authenticated users: %#v", repeated)
	}
	gateway.mu.RLock()
	aliceClients := len(gateway.clients["alice"])
	bobClients := len(gateway.clients["bob"])
	gateway.mu.RUnlock()
	if aliceClients != 1 || bobClients != 0 {
		t.Fatalf("unexpected client registrations: alice=%d bob=%d", aliceClients, bobClients)
	}
}

func assertPresenceEvent(
	t *testing.T,
	events <-chan map[string]interface{},
	errors <-chan error,
	userID string,
	online bool,
) {
	t.Helper()
	select {
	case event := <-events:
		if event["notice_type"] != "friend_presence" ||
			event["user_id"] != userID ||
			event["online"] != online {
			t.Fatalf("unexpected presence event: %#v", event)
		}
	case err := <-errors:
		t.Fatalf("presence observer failed: %v", err)
	case <-time.After(2 * time.Second):
		t.Fatalf("timed out waiting for %s presence=%v", userID, online)
	}
}

func assertNoPresenceEvent(
	t *testing.T,
	events <-chan map[string]interface{},
	errors <-chan error,
) {
	t.Helper()
	select {
	case event := <-events:
		t.Fatalf("unexpected duplicate presence event: %#v", event)
	case err := <-errors:
		t.Fatalf("presence observer failed: %v", err)
	case <-time.After(100 * time.Millisecond):
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

func TestFriendRequestLifecycleAndDirectMessagePermission(t *testing.T) {
	database := store.NewMemoryStore()
	pushSender := &fakePushSender{deliveries: make(chan pushDelivery, 2)}
	gateway := NewGateway(database, pushSender)
	server := httptest.NewServer(gateway)
	t.Cleanup(server.Close)
	websocketURL := "ws" + strings.TrimPrefix(server.URL, "http")

	alice := dialWebSocket(t, websocketURL)
	t.Cleanup(func() { _ = alice.Close() })
	bob := dialWebSocket(t, websocketURL)
	t.Cleanup(func() { _ = bob.Close() })
	eve := dialWebSocket(t, websocketURL)
	t.Cleanup(func() { _ = eve.Close() })
	authenticate(t, alice, "alice")
	authenticate(t, bob, "bob")
	authenticate(t, eve, "eve")
	for user, connection := range map[string]*websocket.Conn{"alice": alice, "bob": bob} {
		assertOK(t, request(t, connection, "register_push", map[string]interface{}{
			"endpoint": "https://push.example.test/" + user,
			"keys":     map[string]interface{}{"p256dh": "key", "auth": "auth"},
		}))
	}

	search := responseDataList(t, request(t, alice, "search_users", map[string]interface{}{"query": "bob"}))
	if len(search) != 1 || search[0].(map[string]interface{})["relationship"] != "none" {
		t.Fatalf("unexpected search results: %#v", search)
	}

	created := request(t, alice, "friend_request", map[string]interface{}{
		"user_id": "bob",
		"comment": "Hi, I am Alice",
	})
	assertOK(t, created)
	flag, _ := responseData(t, created)["flag"].(string)
	if flag == "" {
		t.Fatal("friend request returned no flag")
	}
	requestEvent := readJSON(t, bob)
	if requestEvent["post_type"] != "request" || requestEvent["flag"] != flag {
		t.Fatalf("unexpected friend request event: %#v", requestEvent)
	}
	requestPush := waitForPushType(t, pushSender.deliveries, "friend_request")
	if requestPush.subscription.UserID != "bob" || requestPush.payload["request_id"] != flag {
		t.Fatalf("unexpected friend request push: %#v", requestPush)
	}

	duplicate := request(t, alice, "friend_request", map[string]interface{}{"user_id": "bob"})
	if duplicate["status"] == "ok" {
		t.Fatalf("duplicate friend request was accepted: %#v", duplicate)
	}
	denied := request(t, eve, "friend_request_handle", map[string]interface{}{
		"flag": flag, "action": "accept",
	})
	if denied["status"] == "ok" {
		t.Fatalf("third party handled friend request: %#v", denied)
	}

	pending := responseDataList(t, request(t, bob, "get_friend_requests", map[string]interface{}{}))
	if len(pending) != 1 || pending[0].(map[string]interface{})["comment"] != "Hi, I am Alice" {
		t.Fatalf("unexpected pending requests: %#v", pending)
	}
	assertOK(t, request(t, bob, "friend_request_handle", map[string]interface{}{
		"flag": flag, "action": "accept",
	}))
	friendNotice := readJSON(t, alice)
	if friendNotice["notice_type"] != "friend_add" || friendNotice["user_id"] != "bob" {
		t.Fatalf("unexpected friend notice: %#v", friendNotice)
	}
	resultPush := waitForPushType(t, pushSender.deliveries, "friend_request_result")
	if resultPush.subscription.UserID != "alice" || resultPush.payload["request_id"] != flag {
		t.Fatalf("unexpected friend result push: %#v", resultPush)
	}

	for name, connection := range map[string]*websocket.Conn{"alice": alice, "bob": bob} {
		friends := responseDataList(t, request(t, connection, "get_friends", map[string]interface{}{}))
		if len(friends) != 1 {
			t.Fatalf("%s friends = %#v", name, friends)
		}
	}
	assertOK(t, request(t, alice, "ensure_conversation", map[string]interface{}{
		"conversation_id": "private_alice_bob",
		"type":            "private",
		"participants":    []string{"alice", "bob"},
	}))
	deniedRead := request(t, eve, "mark_read", map[string]interface{}{
		"conversation_id": "private_alice_bob",
	})
	if deniedRead["status"] == "ok" {
		t.Fatalf("non-participant marked conversation read: %#v", deniedRead)
	}

	assertOK(t, request(t, alice, "remove_friend", map[string]interface{}{"user_id": "bob"}))
	removeNotice := readJSON(t, bob)
	if removeNotice["notice_type"] != "friend_remove" {
		t.Fatalf("unexpected remove notice: %#v", removeNotice)
	}
	if friends := responseDataList(t, request(t, alice, "get_friends", map[string]interface{}{})); len(friends) != 0 {
		t.Fatalf("friend remained after removal: %#v", friends)
	}
	blocked := request(t, alice, "ensure_conversation", map[string]interface{}{
		"conversation_id": "private_alice_bob_new",
		"type":            "private",
		"participants":    []string{"alice", "bob"},
	})
	if blocked["status"] == "ok" {
		t.Fatalf("new direct conversation was allowed after removal: %#v", blocked)
	}
}

func waitForPushType(
	t *testing.T,
	deliveries <-chan pushDelivery,
	eventType string,
) pushDelivery {
	t.Helper()
	deadline := time.After(2 * time.Second)
	for {
		select {
		case delivery := <-deliveries:
			if delivery.payload["type"] == eventType {
				return delivery
			}
		case <-deadline:
			t.Fatalf("timed out waiting for %s push", eventType)
		}
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
