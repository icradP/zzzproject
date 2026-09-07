package gateway

import (
	"fmt"
	"net"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/gorilla/websocket"
	"github.com/icradp/zzz-im-server/internal/protocol"
	"github.com/icradp/zzz-im-server/internal/store"
)

type slowDynamicUpdateStore struct {
	store.Store
	mu            sync.Mutex
	activeReads   int
	maxConcurrent int
}

func (s *slowDynamicUpdateStore) GetMessage(messageID string) (*store.Message, error) {
	message, err := s.Store.GetMessage(messageID)
	s.mu.Lock()
	s.activeReads++
	if s.activeReads > s.maxConcurrent {
		s.maxConcurrent = s.activeReads
	}
	s.mu.Unlock()
	time.Sleep(40 * time.Millisecond)
	s.mu.Lock()
	s.activeReads--
	s.mu.Unlock()
	return message, err
}

func (s *slowDynamicUpdateStore) maxConcurrentReads() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.maxConcurrent
}

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

	invalidMetadata := validDynamicContentSegment()
	invalidMetadata.Data["metadata"] = []interface{}{"not", "an", "object"}
	if err := validateDynamicContentSegment(invalidMetadata); err == nil {
		t.Fatal("non-object dynamic metadata was accepted")
	}

	invalidFallback := validDynamicContentSegment()
	invalidFallback.Data["fallback"] = map[string]interface{}{
		"type": "text", "content": 42,
	}
	if err := validateDynamicContentSegment(invalidFallback); err == nil {
		t.Fatal("non-string dynamic fallback content was accepted")
	}
}

func TestDynamicEventTargetAcceptsLegacyTerminalAdapterIdentity(t *testing.T) {
	segments := []protocol.MessageSegment{{
		Type: "terminal_request",
		Data: map[string]interface{}{"request_id": "request-1"},
	}}
	valid := map[string]interface{}{
		"message_id": "message-1",
		"content_id": "legacy:message-1:0",
		"node_id":    "terminal-request-request-1",
		"event":      "click",
		"action":     "approve",
	}
	if err := validateDynamicEventTarget(segments, valid); err != nil {
		t.Fatalf("legacy adapter event rejected: %v", err)
	}
	valid["action"] = "delete_everything"
	if err := validateDynamicEventTarget(segments, valid); err == nil {
		t.Fatal("unsupported legacy terminal action was accepted")
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

func TestConcurrentDynamicUpdatesToOneMessageDoNotLosePatches(t *testing.T) {
	database := store.NewMemoryStore()
	conversationID := "private_alice_bob"
	if err := database.SaveConversation(&store.Conversation{
		ID: conversationID, Type: "private", Title: "Dynamic", Participants: []string{"alice", "bob"},
	}); err != nil {
		t.Fatal(err)
	}
	message, err := database.StoreMessage(conversationID, "alice", "Alice", []protocol.MessageSegment{
		protocol.DynamicContentSegment(map[string]interface{}{
			"id": "concurrent-card", "version": "1.0", "source": "ai",
			"tree": map[string]interface{}{
				"id": "root", "type": "column", "children": []interface{}{
					map[string]interface{}{"id": "first", "type": "status", "props": map[string]interface{}{"text": "Before first"}},
					map[string]interface{}{"id": "second", "type": "status", "props": map[string]interface{}{"text": "Before second"}},
				},
			},
		}),
	})
	if err != nil {
		t.Fatal(err)
	}
	slowStore := &slowDynamicUpdateStore{Store: database}
	gateway := NewGateway(slowStore)
	updates := []protocol.MessageSegment{
		{Type: "dynamic_update", Data: map[string]interface{}{
			"message_id": message.ID, "content_id": "concurrent-card", "patches": []interface{}{
				map[string]interface{}{"operation": "update", "node_id": "first", "props": map[string]interface{}{"text": "After first"}},
			},
		}},
		{Type: "dynamic_update", Data: map[string]interface{}{
			"message_id": message.ID, "content_id": "concurrent-card", "patches": []interface{}{
				map[string]interface{}{"operation": "update", "node_id": "second", "props": map[string]interface{}{"text": "After second"}},
			},
		}},
	}
	start := make(chan struct{})
	var wait sync.WaitGroup
	for index, update := range updates {
		wait.Add(1)
		go func(index int, update protocol.MessageSegment) {
			defer wait.Done()
			<-start
			gateway.handleDynamicUpdate(
				&Client{userID: "alice", send: make(chan []byte, 1)},
				&protocol.Request{Echo: fmt.Sprintf("update-%d", index)},
				conversationID,
				"private",
				fmt.Sprintf("concurrent-update-%d", index),
				update,
			)
		}(index, update)
	}
	close(start)
	wait.Wait()

	if got := slowStore.maxConcurrentReads(); got != 1 {
		t.Fatalf("same-message reads ran concurrently: %d", got)
	}
	gateway.dynamicUpdateMu.Lock()
	activeLocks := len(gateway.dynamicUpdateLocks)
	gateway.dynamicUpdateMu.Unlock()
	if activeLocks != 0 {
		t.Fatalf("dynamic update locks were not released: %d", activeLocks)
	}
	updated, err := database.GetMessage(message.ID)
	if err != nil || updated == nil {
		t.Fatalf("updated message = %#v err=%v", updated, err)
	}
	tree := updated.Segments[0].Data["tree"].(map[string]interface{})
	children := tree["children"].([]interface{})
	if got := children[0].(map[string]interface{})["props"].(map[string]interface{})["text"]; got != "After first" {
		t.Fatalf("first patch was lost: %#v", got)
	}
	if got := children[1].(map[string]interface{})["props"].(map[string]interface{})["text"]; got != "After second" {
		t.Fatalf("second patch was lost: %#v", got)
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

func TestDynamicUpdateClientIDIsIdempotentForCreatePatch(t *testing.T) {
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
	_ = readJSON(t, bob)
	update := protocol.DynamicUpdateSegment(messageID, "diagnosis-1", []protocol.DynamicPatch{{
		Operation:    "create",
		NodeID:       "result",
		ParentNodeID: "root",
		Node:         map[string]interface{}{"id": "result", "type": "status"},
	}})
	params := map[string]interface{}{
		"conversation_id":   conversationID,
		"client_message_id": "dynamic-update-create-1",
		"message":           []protocol.MessageSegment{update},
	}
	firstUpdate := request(t, alice, "send_message", params)
	assertOK(t, firstUpdate)
	if responseData(t, firstUpdate)["duplicate"] != false {
		t.Fatalf("first update was marked duplicate: %#v", firstUpdate)
	}
	_ = readJSON(t, alice)
	_ = readJSON(t, bob)

	secondUpdate := request(t, alice, "send_message", params)
	assertOK(t, secondUpdate)
	if responseData(t, secondUpdate)["duplicate"] != true {
		t.Fatalf("retry was not marked duplicate: %#v", secondUpdate)
	}
	history := responseDataList(t, request(t, alice, "get_messages", map[string]interface{}{
		"conversation_id": conversationID,
		"limit":           100,
	}))
	if len(history) != 1 {
		t.Fatalf("dynamic retry created %d history messages", len(history))
	}
	children := history[0].(map[string]interface{})["message"].([]interface{})[0].(map[string]interface{})["data"].(map[string]interface{})["tree"].(map[string]interface{})["children"].([]interface{})
	if len(children) != 2 || children[1].(map[string]interface{})["id"] != "result" {
		t.Fatalf("create patch was applied more than once: %#v", children)
	}
	if err := bob.SetReadDeadline(time.Now().Add(100 * time.Millisecond)); err != nil {
		t.Fatal(err)
	}
	var unexpected map[string]interface{}
	if err := bob.ReadJSON(&unexpected); err == nil {
		t.Fatalf("duplicate update was broadcast: %#v", unexpected)
	} else if networkError, ok := err.(net.Error); !ok || !networkError.Timeout() {
		t.Fatalf("wait for duplicate update broadcast: %v", err)
	}
}

func TestDynamicEventDispatchesTransientlyAndValidatesSchema(t *testing.T) {
	database := store.NewMemoryStore()
	gateway := NewGateway(database)
	server := httptest.NewServer(gateway)
	t.Cleanup(server.Close)
	websocketURL := "ws" + strings.TrimPrefix(server.URL, "http")
	alice := dialWebSocket(t, websocketURL)
	aliceSecondDevice := dialWebSocket(t, websocketURL)
	bob := dialWebSocket(t, websocketURL)
	t.Cleanup(func() { _ = alice.Close() })
	t.Cleanup(func() { _ = aliceSecondDevice.Close() })
	t.Cleanup(func() { _ = bob.Close() })
	authenticate(t, alice, "alice")
	authenticate(t, aliceSecondDevice, "alice")
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

	content := protocol.DynamicContentSegment(map[string]interface{}{
		"id": "event-card-1", "version": "1.0", "source": "user",
		"tree": map[string]interface{}{
			"id": "root", "type": "column",
			"children": []interface{}{map[string]interface{}{
				"id": "retry", "type": "button",
				"props": map[string]interface{}{"text": "Retry"},
				"events": map[string]interface{}{
					"click": map[string]interface{}{"action": "retry"},
				},
			}},
		},
	})
	initial := request(t, alice, "send_message", map[string]interface{}{
		"conversation_id": conversationID,
		"message":         []protocol.MessageSegment{content},
	})
	assertOK(t, initial)
	messageID := responseData(t, initial)["message_id"].(string)
	if event := readJSON(t, bob); event["message_id"] != messageID {
		t.Fatalf("initial event = %#v", event)
	}

	dynamicEvent := protocol.DynamicEventSegment(
		messageID,
		"event-card-1",
		"retry",
		"click",
		"retry",
		map[string]interface{}{"source": "test"},
	)
	dispatched := request(t, bob, "send_message", map[string]interface{}{
		"conversation_id": conversationID,
		"message":         []protocol.MessageSegment{dynamicEvent},
	})
	assertOK(t, dispatched)
	if responseData(t, dispatched)["dispatched"] != true {
		t.Fatalf("unexpected dispatch response: %#v", dispatched)
	}
	transient := readJSON(t, alice)
	if transient["message_id"] != messageID {
		t.Fatalf("transient event message id = %#v", transient)
	}
	transientSegments := transient["message"].([]interface{})
	if transientSegments[0].(map[string]interface{})["type"] != "dynamic_event" {
		t.Fatalf("transient event segments = %#v", transientSegments)
	}
	if secondDeviceEvent := readJSON(t, aliceSecondDevice); secondDeviceEvent["message_id"] != messageID {
		t.Fatalf("same-account device did not receive transient event: %#v", secondDeviceEvent)
	}

	invalid := protocol.DynamicEventSegment(
		messageID,
		"event-card-1",
		"retry",
		"click",
		"delete_everything",
		nil,
	)
	rejected := request(t, bob, "send_message", map[string]interface{}{
		"conversation_id": conversationID,
		"message":         []protocol.MessageSegment{invalid},
	})
	if rejected["status"] != "error" {
		t.Fatalf("invalid event was accepted: %#v", rejected)
	}

	history := responseDataList(t, request(t, alice, "get_messages", map[string]interface{}{
		"conversation_id": conversationID,
		"limit":           100,
	}))
	if len(history) != 1 {
		t.Fatalf("dynamic event created %d history messages", len(history))
	}
}
