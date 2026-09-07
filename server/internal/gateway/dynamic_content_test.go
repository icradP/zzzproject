package gateway

import (
	"fmt"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/gorilla/websocket"
	"github.com/icradp/zzz-im-server/internal/protocol"
	"github.com/icradp/zzz-im-server/internal/store"
)

func validDynamicContentSegment() protocol.MessageSegment {
	return protocol.DynamicContentSegment(map[string]interface{}{
		"id":      "diagnosis-1",
		"version": "1.0",
		"source":  "ai",
		"tree": map[string]interface{}{
			"id":   "root",
			"type": "column",
			"children": []interface{}{
				map[string]interface{}{
					"id":    "status",
					"type":  "status",
					"props": map[string]interface{}{"text": "Checking"},
				},
			},
		},
	})
}

func TestDynamicContentValidationRejectsUnsafeAndMalformedTrees(t *testing.T) {
	valid := validDynamicContentSegment()
	if err := validateDynamicContentSegment(valid); err != nil {
		t.Fatalf("valid dynamic content rejected: %v", err)
	}

	unsafeImage := protocol.DynamicContentSegment(map[string]interface{}{
		"id": "image-1", "version": "1.0", "source": "server",
		"tree": map[string]interface{}{
			"id": "root", "type": "image",
			"props": map[string]interface{}{"url": "http://example.test/image.png"},
		},
	})
	if err := validateDynamicContentSegment(unsafeImage); err == nil {
		t.Fatal("insecure dynamic image URL was accepted")
	}

	duplicate := validDynamicContentSegment()
	tree := duplicate.Data["tree"].(map[string]interface{})
	tree["children"] = []interface{}{map[string]interface{}{"id": "root", "type": "text"}}
	if err := validateDynamicContentSegment(duplicate); err == nil {
		t.Fatal("duplicate dynamic node id was accepted")
	}

	images := make([]interface{}, maxDynamicImages+1)
	for index := range images {
		images[index] = map[string]interface{}{
			"id":   fmt.Sprintf("image-%d", index),
			"type": "image",
			"props": map[string]interface{}{
				"url": fmt.Sprintf("https://example.test/%d.png", index),
			},
		}
	}
	imageHeavy := protocol.DynamicContentSegment(map[string]interface{}{
		"id": "image-heavy", "version": "1.0", "source": "user",
		"tree": map[string]interface{}{
			"id": "root", "type": "column", "children": images,
		},
	})
	if err := validateDynamicContentSegment(imageHeavy); err == nil {
		t.Fatal("dynamic content image limit was not enforced")
	}
}

func TestDynamicUpdateTargetsMatchingContentAmongSiblings(t *testing.T) {
	segments := []protocol.MessageSegment{
		protocol.DynamicContentSegment(map[string]interface{}{
			"id": "first", "version": "1.0", "source": "ai",
			"tree": map[string]interface{}{
				"id": "first-root", "type": "status",
				"props": map[string]interface{}{"text": "First"},
			},
		}),
		{Type: "text", Data: map[string]interface{}{"text": "Between"}},
		protocol.DynamicContentSegment(map[string]interface{}{
			"id": "second", "version": "1.0", "source": "ai",
			"tree": map[string]interface{}{
				"id": "second-root", "type": "status",
				"props": map[string]interface{}{"text": "Before"},
			},
		}),
	}
	updateData := map[string]interface{}{
		"message_id": "message-1",
		"content_id": "second",
		"patches": []interface{}{
			map[string]interface{}{
				"operation": "update",
				"node_id":   "second-root",
				"props":     map[string]interface{}{"text": "After"},
			},
		},
	}

	updated, messageID, err := applyDynamicUpdateToSegments(segments, updateData)
	if err != nil {
		t.Fatal(err)
	}
	if messageID != "message-1" {
		t.Fatalf("message id = %q", messageID)
	}
	firstTree := updated[0].Data["tree"].(map[string]interface{})
	secondTree := updated[2].Data["tree"].(map[string]interface{})
	if got := firstTree["props"].(map[string]interface{})["text"]; got != "First" {
		t.Fatalf("first content changed: %#v", got)
	}
	if got := secondTree["props"].(map[string]interface{})["text"]; got != "After" {
		t.Fatalf("second content was not updated: %#v", got)
	}
}

func TestDynamicUpdateKeepsOneHistoryMessageAndBroadcastsPatch(t *testing.T) {
	database := store.NewMemoryStore()
	gateway := NewGateway(database)
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
	conversationID := "private_alice_bob"
	assertOK(t, request(t, alice, "ensure_conversation", map[string]interface{}{
		"conversation_id": conversationID,
		"type":            "private",
		"participants":    []string{"alice", "bob"},
	}))

	first := request(t, alice, "send_message", map[string]interface{}{
		"conversation_id": conversationID,
		"message":         []protocol.MessageSegment{validDynamicContentSegment()},
	})
	assertOK(t, first)
	messageID := responseData(t, first)["message_id"].(string)
	if event := readJSON(t, bob); event["message_id"] != messageID {
		t.Fatalf("initial event = %#v", event)
	}

	update := protocol.DynamicUpdateSegment(messageID, "diagnosis-1", []protocol.DynamicPatch{{
		Operation: "update",
		NodeID:    "status",
		Props:     map[string]interface{}{"text": "Complete"},
	}})
	updated := request(t, alice, "send_message", map[string]interface{}{
		"conversation_id": conversationID,
		"message":         []protocol.MessageSegment{update},
	})
	assertOK(t, updated)
	if responseData(t, updated)["message_id"] != messageID || responseData(t, updated)["updated"] != true {
		t.Fatalf("unexpected update response: %#v", updated)
	}
	for _, connection := range []*websocket.Conn{alice, bob} {
		event := readJSON(t, connection)
		if event["message_id"] != messageID {
			t.Fatalf("update event = %#v", event)
		}
		segments := event["message"].([]interface{})
		if segments[0].(map[string]interface{})["type"] != "dynamic_update" {
			t.Fatalf("update event segments = %#v", segments)
		}
	}

	history := responseDataList(t, request(t, alice, "get_messages", map[string]interface{}{
		"conversation_id": conversationID,
		"limit":           100,
	}))
	if len(history) != 1 {
		t.Fatalf("dynamic update created %d history messages", len(history))
	}
	segments := history[0].(map[string]interface{})["message"].([]interface{})
	tree := segments[0].(map[string]interface{})["data"].(map[string]interface{})["tree"].(map[string]interface{})
	children := tree["children"].([]interface{})
	status := children[0].(map[string]interface{})["props"].(map[string]interface{})
	if status["text"] != "Complete" {
		t.Fatalf("history did not persist patch: %#v", status)
	}
}
