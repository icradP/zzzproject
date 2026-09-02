package gateway

import (
	"net"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/icradp/zzz-im-server/internal/protocol"
	"github.com/icradp/zzz-im-server/internal/store"
)

func TestSendMessageClientIDIsIdempotentWithoutDuplicateBroadcast(t *testing.T) {
	database := store.NewMemoryStore()
	gateway := NewGateway(database)
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
	conversationID := "private_alice_bob"
	assertOK(t, request(t, alice, "ensure_conversation", map[string]interface{}{
		"conversation_id": conversationID, "type": "private", "participants": []string{"alice", "bob"},
	}))
	params := map[string]interface{}{
		"conversation_id":   conversationID,
		"client_message_id": "desktop:message-1",
		"message":           []map[string]interface{}{{"type": "text", "data": map[string]interface{}{"text": "only once"}}},
	}
	first := request(t, alice, "send_message", params)
	assertOK(t, first)
	firstData := responseData(t, first)
	if firstData["duplicate"] != false || firstData["client_message_id"] != "desktop:message-1" {
		t.Fatalf("first response data = %#v", firstData)
	}
	firstEvent := readJSON(t, bob)
	if firstEvent["message_id"] != firstData["message_id"] {
		t.Fatalf("first event = %#v, response = %#v", firstEvent, firstData)
	}

	second := request(t, alice, "send_message", params)
	assertOK(t, second)
	secondData := responseData(t, second)
	if secondData["duplicate"] != true || secondData["message_id"] != firstData["message_id"] || secondData["timestamp_ms"] != firstData["timestamp_ms"] {
		t.Fatalf("duplicate response = %#v, first = %#v", secondData, firstData)
	}
	if err := bob.SetReadDeadline(time.Now().Add(100 * time.Millisecond)); err != nil {
		t.Fatal(err)
	}
	var unexpected map[string]interface{}
	if err := bob.ReadJSON(&unexpected); err == nil {
		t.Fatalf("duplicate request was broadcast: %#v", unexpected)
	} else if networkError, ok := err.(net.Error); !ok || !networkError.Timeout() {
		t.Fatalf("wait for duplicate broadcast: %v", err)
	}
	_ = bob.SetReadDeadline(time.Time{})

	conflictParams := map[string]interface{}{
		"conversation_id":   conversationID,
		"client_message_id": "desktop:message-1",
		"message":           []map[string]interface{}{{"type": "text", "data": map[string]interface{}{"text": "changed"}}},
	}
	if conflict := request(t, alice, "send_message", conflictParams); conflict["status"] == "ok" || !strings.Contains(conflict["msg"].(string), "different message") {
		t.Fatalf("conflicting idempotency response = %#v", conflict)
	}

	history := responseDataList(t, request(t, alice, "get_messages", map[string]interface{}{
		"conversation_id": conversationID, "limit": 100,
	}))
	if len(history) != 1 {
		t.Fatalf("message history has %d entries, want 1", len(history))
	}
}

func TestValidClientMessageID(t *testing.T) {
	for _, value := range []string{"", "has whitespace", strings.Repeat("a", 129)} {
		if validClientMessageID(value) {
			t.Fatalf("invalid client message ID was accepted: %q", value)
		}
	}
	for _, value := range []string{"fairy-msg-0123456789abcdef", "desktop:message_1", "a.b-c_d"} {
		if !validClientMessageID(value) {
			t.Fatalf("valid client message ID was rejected: %q", value)
		}
	}
}

func TestWebSocketReplyAndRecallLifecycle(t *testing.T) {
	database := store.NewMemoryStore()
	gateway := NewGateway(database)
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
	if _, err := database.AddFriend("alice", "bob"); err != nil {
		t.Fatal(err)
	}
	if _, err := database.AddFriend("alice", "eve"); err != nil {
		t.Fatal(err)
	}

	firstConversation := "private_alice_bob"
	secondConversation := "private_alice_eve"
	assertOK(t, request(t, alice, "ensure_conversation", map[string]interface{}{
		"conversation_id": firstConversation,
		"type":            "private",
		"participants":    []string{"alice", "bob"},
	}))
	assertOK(t, request(t, alice, "ensure_conversation", map[string]interface{}{
		"conversation_id": secondConversation,
		"type":            "private",
		"participants":    []string{"alice", "eve"},
	}))

	originalResponse := request(t, alice, "send_message", map[string]interface{}{
		"conversation_id": firstConversation,
		"message": []map[string]interface{}{
			{"type": "text", "data": map[string]interface{}{"text": "original"}},
		},
	})
	assertOK(t, originalResponse)
	originalID := responseData(t, originalResponse)["message_id"].(string)
	_ = readJSON(t, bob)

	replyResponse := request(t, bob, "send_message", map[string]interface{}{
		"conversation_id": firstConversation,
		"message": []map[string]interface{}{
			{"type": "reply", "data": map[string]interface{}{"id": originalID}},
			{"type": "text", "data": map[string]interface{}{"text": "quoted reply"}},
		},
	})
	assertOK(t, replyResponse)
	replyEvent := readJSON(t, alice)
	segments := replyEvent["message"].([]interface{})
	if len(segments) != 2 ||
		segments[0].(map[string]interface{})["type"] != "reply" ||
		segments[0].(map[string]interface{})["data"].(map[string]interface{})["id"] != originalID {
		t.Fatalf("reply segments were not broadcast intact: %#v", replyEvent)
	}

	history := responseDataList(t, request(t, alice, "get_messages", map[string]interface{}{
		"conversation_id": firstConversation,
		"limit":           100,
	}))
	storedReply := history[1].(map[string]interface{})["message"].([]interface{})
	if storedReply[0].(map[string]interface{})["type"] != "reply" {
		t.Fatalf("reply segment was not stored: %#v", history[1])
	}

	crossConversationReply := request(t, alice, "send_message", map[string]interface{}{
		"conversation_id": secondConversation,
		"message": []map[string]interface{}{
			{"type": "reply", "data": map[string]interface{}{"id": originalID}},
			{"type": "text", "data": map[string]interface{}{"text": "forged reply"}},
		},
	})
	if crossConversationReply["status"] == "ok" {
		t.Fatalf("cross-conversation reply was accepted: %#v", crossConversationReply)
	}

	unauthorizedRecall := request(t, bob, "recall_message", map[string]interface{}{
		"message_id": originalID,
	})
	if unauthorizedRecall["status"] == "ok" {
		t.Fatalf("private recipient recalled another user's message: %#v", unauthorizedRecall)
	}

	assertOK(t, request(t, alice, "recall_message", map[string]interface{}{
		"message_id": originalID,
	}))
	aliceRecall := readJSON(t, alice)
	bobRecall := readJSON(t, bob)
	for _, notice := range []map[string]interface{}{aliceRecall, bobRecall} {
		if notice["notice_type"] != "friend_recall" ||
			notice["conversation_id"] != firstConversation ||
			notice["message_id"] != originalID ||
			notice["user_id"] != "alice" ||
			notice["operator_id"] != "alice" {
			t.Fatalf("unexpected private recall notice: %#v", notice)
		}
	}
	history = responseDataList(t, request(t, bob, "get_messages", map[string]interface{}{
		"conversation_id": firstConversation,
		"limit":           100,
	}))
	if history[0].(map[string]interface{})["recalled"] != true {
		t.Fatalf("history did not retain recalled state: %#v", history[0])
	}

	oldMessage, err := database.StoreMessage(
		firstConversation,
		"alice",
		"Alice",
		[]protocol.MessageSegment{protocol.TextSegment("too old")},
	)
	if err != nil {
		t.Fatal(err)
	}
	oldMessage.Timestamp = time.Now().Add(-3 * time.Minute)
	expiredRecall := request(t, alice, "recall_message", map[string]interface{}{
		"message_id": oldMessage.ID,
	})
	if expiredRecall["status"] == "ok" {
		t.Fatalf("expired message was recalled: %#v", expiredRecall)
	}

	groupResponse := request(t, alice, "create_group", map[string]interface{}{
		"name":    "Recall test",
		"members": []string{"bob"},
	})
	assertOK(t, groupResponse)
	groupID := responseData(t, groupResponse)["group_id"].(string)
	_ = readJSON(t, bob)
	groupMessageResponse := request(t, bob, "send_message", map[string]interface{}{
		"conversation_id": groupID,
		"message": []map[string]interface{}{
			{"type": "text", "data": map[string]interface{}{"text": "group message"}},
		},
	})
	assertOK(t, groupMessageResponse)
	groupMessageID := responseData(t, groupMessageResponse)["message_id"].(string)
	_ = readJSON(t, alice)

	assertOK(t, request(t, alice, "recall_message", map[string]interface{}{
		"message_id": groupMessageID,
	}))
	ownerNotice := readJSON(t, alice)
	senderNotice := readJSON(t, bob)
	for _, notice := range []map[string]interface{}{ownerNotice, senderNotice} {
		if notice["notice_type"] != "group_recall" ||
			notice["conversation_id"] != groupID ||
			notice["user_id"] != "bob" ||
			notice["operator_id"] != "alice" {
			t.Fatalf("unexpected group recall notice: %#v", notice)
		}
	}
}

func TestValidateImageSegmentURL(t *testing.T) {
	tests := []struct {
		name    string
		url     string
		wantErr bool
	}{
		{name: "hosted HTTPS", url: "https://cdn.example.test/image.png"},
		{name: "server media", url: "/files/0123456789abcdef0123456789abcdef/image.png"},
		{name: "insecure external", url: "http://cdn.example.test/image.png", wantErr: true},
		{name: "credentials", url: "https://token@cdn.example.test/image.png", wantErr: true},
		{name: "protocol relative", url: "//cdn.example.test/image.png", wantErr: true},
		{name: "leading whitespace", url: " https://cdn.example.test/image.png", wantErr: true},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			err := validateImageSegmentURL(protocol.ImageSegment("", test.url))
			if (err != nil) != test.wantErr {
				t.Fatalf("validateImageSegmentURL() err=%v wantErr=%v", err, test.wantErr)
			}
		})
	}
}

func TestValidateM4StructuredSegments(t *testing.T) {
	t.Run("link", func(t *testing.T) {
		valid := protocol.MessageSegment{Type: "share", Data: map[string]interface{}{
			"url": "https://example.test/docs", "title": "Documentation",
		}}
		if err := validateShareSegment(valid); err != nil {
			t.Fatalf("valid link rejected: %v", err)
		}
		invalid := valid
		invalid.Data = map[string]interface{}{"url": "file:///etc/passwd"}
		if err := validateShareSegment(invalid); err == nil {
			t.Fatal("unsafe link scheme was accepted")
		}
	})

	t.Run("location", func(t *testing.T) {
		nameOnly := protocol.MessageSegment{Type: "location", Data: map[string]interface{}{
			"name": "People's Square",
		}}
		if err := validateLocationSegment(nameOnly); err != nil {
			t.Fatalf("name-only location rejected: %v", err)
		}
		coordinates := protocol.MessageSegment{Type: "location", Data: map[string]interface{}{
			"name": "People's Square", "lat": float64(31.2304), "lon": float64(121.4737),
		}}
		if err := validateLocationSegment(coordinates); err != nil {
			t.Fatalf("valid coordinates rejected: %v", err)
		}
		coordinates.Data["lat"] = float64(91)
		if err := validateLocationSegment(coordinates); err == nil {
			t.Fatal("out-of-range latitude was accepted")
		}
	})

	t.Run("voice", func(t *testing.T) {
		valid := protocol.MessageSegment{Type: "record", Data: map[string]interface{}{
			"duration_ms": float64(120000), "size": float64(10 * 1024 * 1024),
		}}
		if err := validateRecordSegment(valid); err != nil {
			t.Fatalf("boundary voice message rejected: %v", err)
		}
		valid.Data["duration_ms"] = float64(120001)
		if err := validateRecordSegment(valid); err == nil {
			t.Fatal("overlong voice message was accepted")
		}
	})

	if body := pushBody([]protocol.MessageSegment{
		{Type: "share", Data: map[string]interface{}{"title": "Docs"}},
		{Type: "location", Data: map[string]interface{}{"name": "Office"}},
		{Type: "poke", Data: map[string]interface{}{}},
	}); body != "[Link] Docs[Location] Office[Poke]" {
		t.Fatalf("unexpected structured push body: %q", body)
	}
}

func TestWebSocketForwardAccessAndPokeRateLimit(t *testing.T) {
	database := store.NewMemoryStore()
	gateway := NewGateway(database)
	server := httptest.NewServer(gateway)
	t.Cleanup(server.Close)
	websocketURL := "ws" + strings.TrimPrefix(server.URL, "http")

	alice := dialWebSocket(t, websocketURL)
	bob := dialWebSocket(t, websocketURL)
	eve := dialWebSocket(t, websocketURL)
	t.Cleanup(func() { _ = alice.Close() })
	t.Cleanup(func() { _ = bob.Close() })
	t.Cleanup(func() { _ = eve.Close() })
	authenticate(t, alice, "alice")
	authenticate(t, bob, "bob")
	authenticate(t, eve, "eve")
	if _, err := database.AddFriend("alice", "bob"); err != nil {
		t.Fatal(err)
	}
	if _, err := database.AddFriend("alice", "eve"); err != nil {
		t.Fatal(err)
	}

	sourceConversation := "private_alice_bob"
	targetConversation := "private_alice_eve"
	for _, conversation := range []struct {
		id           string
		participants []string
	}{
		{id: sourceConversation, participants: []string{"alice", "bob"}},
		{id: targetConversation, participants: []string{"alice", "eve"}},
	} {
		assertOK(t, request(t, alice, "ensure_conversation", map[string]interface{}{
			"conversation_id": conversation.id,
			"type":            "private",
			"participants":    conversation.participants,
		}))
	}

	original := request(t, alice, "send_message", map[string]interface{}{
		"conversation_id": sourceConversation,
		"message": []map[string]interface{}{
			{"type": "text", "data": map[string]interface{}{"text": "immutable source"}},
		},
	})
	assertOK(t, original)
	originalID := responseData(t, original)["message_id"].(string)
	_ = readJSON(t, bob)

	created := request(t, alice, "create_forward", map[string]interface{}{
		"conversation_id": targetConversation,
		"message_ids":     []string{originalID},
	})
	assertOK(t, created)
	forwardID := responseData(t, created)["forward_id"].(string)

	forwarded := request(t, alice, "send_message", map[string]interface{}{
		"conversation_id": targetConversation,
		"message": []map[string]interface{}{
			{"type": "forward", "data": map[string]interface{}{"id": forwardID, "count": 1}},
		},
	})
	assertOK(t, forwarded)
	event := readJSON(t, eve)
	segments := event["message"].([]interface{})
	if segments[0].(map[string]interface{})["type"] != "forward" {
		t.Fatalf("forward event was not structured: %#v", event)
	}

	available := request(t, eve, "get_forward_msg", map[string]interface{}{"forward_id": forwardID})
	assertOK(t, available)
	if got := len(responseDataList(t, available)); got != 1 {
		t.Fatalf("forward snapshot has %d messages, want 1", got)
	}
	denied := request(t, bob, "get_forward_msg", map[string]interface{}{"forward_id": forwardID})
	if denied["status"] == "ok" {
		t.Fatalf("non-target conversation member read forward snapshot: %#v", denied)
	}
	crossConversation := request(t, alice, "send_message", map[string]interface{}{
		"conversation_id": sourceConversation,
		"message": []map[string]interface{}{
			{"type": "forward", "data": map[string]interface{}{"id": forwardID}},
		},
	})
	if crossConversation["status"] == "ok" {
		t.Fatalf("forward snapshot was reused across conversations: %#v", crossConversation)
	}

	poke := func() map[string]interface{} {
		return request(t, alice, "send_message", map[string]interface{}{
			"conversation_id": sourceConversation,
			"message": []map[string]interface{}{
				{"type": "poke", "data": map[string]interface{}{"target_id": "bob"}},
			},
		})
	}
	assertOK(t, poke())
	pokeEvent := readJSON(t, bob)
	pokeSegments := pokeEvent["message"].([]interface{})
	if pokeSegments[0].(map[string]interface{})["type"] != "poke" {
		t.Fatalf("poke was converted to a text message: %#v", pokeEvent)
	}
	limited := poke()
	if limited["status"] == "ok" || !strings.Contains(limited["msg"].(string), "wait") {
		t.Fatalf("poke rate limit did not apply: %#v", limited)
	}
}

func TestWebSocketMessageReactionLifecycle(t *testing.T) {
	database := store.NewMemoryStore()
	gateway := NewGateway(database)
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
	conversationID := "private_alice_bob"
	assertOK(t, request(t, alice, "ensure_conversation", map[string]interface{}{
		"conversation_id": conversationID,
		"type":            "private",
		"participants":    []string{"alice", "bob"},
	}))
	send := request(t, alice, "send_message", map[string]interface{}{
		"conversation_id": conversationID,
		"message": []map[string]interface{}{
			{"type": "text", "data": map[string]interface{}{"text": "react me"}},
		},
	})
	assertOK(t, send)
	messageID := responseData(t, send)["message_id"].(string)
	_ = readJSON(t, bob)

	assertOK(t, request(t, alice, "react_message", map[string]interface{}{
		"message_id": messageID,
		"emoji_id":   "76",
	}))
	aliceEvent := readJSON(t, alice)
	bobEvent := readJSON(t, bob)
	for _, event := range []map[string]interface{}{aliceEvent, bobEvent} {
		if event["notice_type"] != "message_reaction" || event["message_id"] != messageID {
			t.Fatalf("unexpected reaction event: %#v", event)
		}
		reactions := event["reactions"].([]interface{})
		if len(reactions) != 1 || reactions[0].(map[string]interface{})["count"] != float64(1) {
			t.Fatalf("unexpected reaction aggregate: %#v", event)
		}
	}

	assertOK(t, request(t, bob, "react_message", map[string]interface{}{
		"message_id": messageID,
		"emoji_id":   "76",
	}))
	_ = readJSON(t, alice)
	_ = readJSON(t, bob)
	history := responseDataList(t, request(t, bob, "get_messages", map[string]interface{}{
		"conversation_id": conversationID,
		"limit":           10,
	}))
	item := history[0].(map[string]interface{})
	if len(item["my_reactions"].([]interface{})) != 1 {
		t.Fatalf("bob reaction state missing: %#v", item)
	}

	assertOK(t, request(t, alice, "react_message", map[string]interface{}{
		"message_id": messageID,
		"emoji_id":   "76",
		"remove":     true,
	}))
	_ = readJSON(t, alice)
	_ = readJSON(t, bob)
	updated := responseDataList(t, request(t, alice, "get_messages", map[string]interface{}{
		"conversation_id": conversationID,
		"limit":           10,
	}))
	updatedItem := updated[0].(map[string]interface{})
	if len(updatedItem["my_reactions"].([]interface{})) != 0 {
		t.Fatalf("alice reaction was not removed: %#v", updatedItem)
	}
}
