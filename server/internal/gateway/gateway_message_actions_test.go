package gateway

import (
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/icradp/zzz-im-server/internal/protocol"
	"github.com/icradp/zzz-im-server/internal/store"
)

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
