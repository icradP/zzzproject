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
	valid.Data["tree"].(map[string]interface{})["events"] = map[string]interface{}{
		"select": map[string]interface{}{"action": "select_option"},
	}
	if err := validateDynamicContentSegment(valid); err != nil {
		t.Fatalf("documented select event rejected: %v", err)
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

func TestDynamicReplaceAndRemoveKeepMessageIdentityAndAreIdempotent(t *testing.T) {
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

	first := validDynamicContentSegment()
	first.Data["metadata"] = map[string]interface{}{"title": "Original"}
	first.Data["fallback"] = map[string]interface{}{
		"type":    "text",
		"content": "Original fallback",
	}
	second := protocol.DynamicContentSegment(map[string]interface{}{
		"id": "second-card", "version": "1.0", "source": "user",
		"tree": map[string]interface{}{
			"id": "second-root", "type": "status",
			"props": map[string]interface{}{"text": "Keep me"},
		},
	})
	initial := request(t, alice, "send_message", map[string]interface{}{
		"conversation_id": conversationID,
		"message": []protocol.MessageSegment{
			protocol.TextSegment("Before cards"),
			first,
			second,
		},
	})
	assertOK(t, initial)
	messageID := responseData(t, initial)["message_id"].(string)
	_ = readJSON(t, bob)

	replacement := protocol.DynamicContentSegment(map[string]interface{}{
		"id": "diagnosis-1", "version": "1.0", "source": "ai",
		"metadata": map[string]interface{}{"title": "Replaced"},
		"fallback": map[string]interface{}{
			"type":    "text",
			"content": "Replacement fallback",
		},
		"tree": map[string]interface{}{
			"id": "replacement-root", "type": "card",
			"props": map[string]interface{}{"title": "Complete"},
		},
	})
	replaceParams := map[string]interface{}{
		"conversation_id":   conversationID,
		"client_message_id": "dynamic-replace-1",
		"message": []protocol.MessageSegment{
			protocol.DynamicReplaceSegment(messageID, "diagnosis-1", replacement.Data),
		},
	}
	replaced := request(t, alice, "send_message", replaceParams)
	assertOK(t, replaced)
	if data := responseData(t, replaced); data["message_id"] != messageID || data["updated"] != true || data["duplicate"] != false {
		t.Fatalf("unexpected replace response: %#v", replaced)
	}
	for _, connection := range []*websocket.Conn{alice, bob} {
		event := readJSON(t, connection)
		if event["message_id"] != messageID {
			t.Fatalf("replace event message id = %#v", event)
		}
		segments := event["message"].([]interface{})
		if segments[0].(map[string]interface{})["type"] != "dynamic_replace" {
			t.Fatalf("replace event segments = %#v", segments)
		}
	}

	history := responseDataList(t, request(t, alice, "get_messages", map[string]interface{}{
		"conversation_id": conversationID,
		"limit":           100,
	}))
	if len(history) != 1 {
		t.Fatalf("replace created %d history messages", len(history))
	}
	storedSegments := history[0].(map[string]interface{})["message"].([]interface{})
	if len(storedSegments) != 3 || storedSegments[0].(map[string]interface{})["type"] != "text" {
		t.Fatalf("replace changed message siblings: %#v", storedSegments)
	}
	storedReplacement := storedSegments[1].(map[string]interface{})["data"].(map[string]interface{})
	if storedReplacement["version"] != "1.0" || storedReplacement["metadata"].(map[string]interface{})["title"] != "Replaced" || storedReplacement["fallback"].(map[string]interface{})["content"] != "Replacement fallback" {
		t.Fatalf("replacement schema fields were not preserved: %#v", storedReplacement)
	}
	if storedSegments[2].(map[string]interface{})["data"].(map[string]interface{})["id"] != "second-card" {
		t.Fatalf("sibling dynamic content changed: %#v", storedSegments[2])
	}

	duplicateReplace := request(t, alice, "send_message", replaceParams)
	assertOK(t, duplicateReplace)
	if responseData(t, duplicateReplace)["duplicate"] != true {
		t.Fatalf("replace retry was not idempotent: %#v", duplicateReplace)
	}

	removeParams := map[string]interface{}{
		"conversation_id":   conversationID,
		"client_message_id": "dynamic-remove-1",
		"message": []protocol.MessageSegment{
			protocol.DynamicRemoveSegment(messageID, "second-card"),
		},
	}
	removed := request(t, alice, "send_message", removeParams)
	assertOK(t, removed)
	if data := responseData(t, removed); data["message_id"] != messageID || data["updated"] != true || data["duplicate"] != false {
		t.Fatalf("unexpected remove response: %#v", removed)
	}
	for _, connection := range []*websocket.Conn{alice, bob} {
		event := readJSON(t, connection)
		if event["message_id"] != messageID {
			t.Fatalf("remove event message id = %#v", event)
		}
		segments := event["message"].([]interface{})
		if segments[0].(map[string]interface{})["type"] != "dynamic_remove" {
			t.Fatalf("remove event segments = %#v", segments)
		}
	}

	duplicateRemove := request(t, alice, "send_message", removeParams)
	assertOK(t, duplicateRemove)
	if responseData(t, duplicateRemove)["duplicate"] != true {
		t.Fatalf("remove retry was not idempotent: %#v", duplicateRemove)
	}
	finalHistory := responseDataList(t, request(t, alice, "get_messages", map[string]interface{}{
		"conversation_id": conversationID,
		"limit":           100,
	}))
	finalSegments := finalHistory[0].(map[string]interface{})["message"].([]interface{})
	if len(finalSegments) != 2 || finalSegments[0].(map[string]interface{})["type"] != "text" || finalSegments[1].(map[string]interface{})["data"].(map[string]interface{})["id"] != "diagnosis-1" {
		t.Fatalf("remove did not preserve remaining content: %#v", finalSegments)
	}
}

func TestDynamicCapabilitiesNegotiateAndDowngradeLegacyClients(t *testing.T) {
	database := store.NewMemoryStore()
	gateway := NewGateway(database)
	server := httptest.NewServer(gateway)
	t.Cleanup(server.Close)
	websocketURL := "ws" + strings.TrimPrefix(server.URL, "http")
	alice := dialWebSocket(t, websocketURL)
	bob := dialWebSocket(t, websocketURL)
	t.Cleanup(func() { _ = alice.Close() })
	t.Cleanup(func() { _ = bob.Close() })

	authResponse := request(t, alice, "auth", map[string]interface{}{
		"token":        "alice",
		"user_id":      "alice",
		"capabilities": currentTestCapabilities(),
	})
	assertOK(t, authResponse)
	authData := responseData(t, authResponse)
	serverCapabilities := authData["server_capabilities"].(map[string]interface{})
	negotiated := authData["negotiated_capabilities"].(map[string]interface{})
	if serverCapabilities["protocol_version"] != protocol.CurrentProtocolVersion ||
		negotiated["protocol_version"] != protocol.CurrentProtocolVersion {
		t.Fatalf("unexpected capability negotiation: %#v", authData)
	}
	authenticateLegacy(t, bob, "bob")
	if _, err := database.AddFriend("alice", "bob"); err != nil {
		t.Fatal(err)
	}
	conversationID := "private_alice_bob"
	assertOK(t, request(t, alice, "ensure_conversation", map[string]interface{}{
		"conversation_id": conversationID,
		"type":            "private",
		"participants":    []string{"alice", "bob"},
	}))

	content := validDynamicContentSegment()
	content.Data["fallback"] = map[string]interface{}{
		"type":    "text",
		"content": "Network diagnosis requires a newer client",
	}
	sent := request(t, alice, "send_message", map[string]interface{}{
		"conversation_id": conversationID,
		"message": []protocol.MessageSegment{
			protocol.TextSegment("Diagnosis ready"),
			content,
		},
	})
	assertOK(t, sent)
	messageID := responseData(t, sent)["message_id"].(string)

	legacyEvent := readJSON(t, bob)
	legacySegments := legacyEvent["message"].([]interface{})
	if len(legacySegments) != 2 ||
		legacySegments[1].(map[string]interface{})["type"] != "text" ||
		legacySegments[1].(map[string]interface{})["data"].(map[string]interface{})["text"] != "Network diagnosis requires a newer client" {
		t.Fatalf("legacy event was not downgraded: %#v", legacySegments)
	}

	stored, err := database.GetMessage(messageID)
	if err != nil || stored == nil || stored.Segments[1].Type != "dynamic_content" {
		t.Fatalf("canonical dynamic content was not preserved: %#v err=%v", stored, err)
	}
	legacyHistory := responseDataList(t, request(t, bob, "get_messages", map[string]interface{}{
		"conversation_id": conversationID,
		"limit":           100,
	}))
	legacyHistorySegments := legacyHistory[0].(map[string]interface{})["message"].([]interface{})
	if legacyHistorySegments[1].(map[string]interface{})["type"] != "text" {
		t.Fatalf("legacy history was not downgraded: %#v", legacyHistorySegments)
	}
	modernHistory := responseDataList(t, request(t, alice, "get_messages", map[string]interface{}{
		"conversation_id": conversationID,
		"limit":           100,
	}))
	modernHistorySegments := modernHistory[0].(map[string]interface{})["message"].([]interface{})
	if modernHistorySegments[1].(map[string]interface{})["type"] != "dynamic_content" {
		t.Fatalf("modern history lost dynamic content: %#v", modernHistorySegments)
	}

	update := protocol.DynamicUpdateSegment(messageID, "diagnosis-1", []protocol.DynamicPatch{{
		Operation: "update",
		NodeID:    "status",
		Props:     map[string]interface{}{"text": "Complete"},
	}})
	assertOK(t, request(t, alice, "send_message", map[string]interface{}{
		"conversation_id": conversationID,
		"message":         []protocol.MessageSegment{update},
	}))
	if event := readJSON(t, alice); event["message_id"] != messageID {
		t.Fatalf("modern update event = %#v", event)
	}
	if err := bob.SetReadDeadline(time.Now().Add(100 * time.Millisecond)); err != nil {
		t.Fatal(err)
	}
	var unexpected map[string]interface{}
	if err := bob.ReadJSON(&unexpected); err == nil {
		t.Fatalf("legacy client received a dynamic patch: %#v", unexpected)
	} else if networkError, ok := err.(net.Error); !ok || !networkError.Timeout() {
		t.Fatalf("wait for legacy patch: %v", err)
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
	for name, connection := range map[string]*websocket.Conn{
		"Alice":        alice,
		"Alice device": aliceSecondDevice,
		"Bob":          bob,
	} {
		audit := readJSON(t, connection)
		if audit["dynamic_event_audit"] != true {
			t.Fatalf("%s did not receive the durable interaction audit: %#v", name, audit)
		}
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

	invalidPayload := dynamicEvent
	invalidPayload.Data = cloneDynamicMap(dynamicEvent.Data)
	invalidPayload.Data["payload"] = []interface{}{"not", "an", "object"}
	payloadRejected := request(t, bob, "send_message", map[string]interface{}{
		"conversation_id": conversationID,
		"message":         []protocol.MessageSegment{invalidPayload},
	})
	if payloadRejected["status"] != "error" {
		t.Fatalf("invalid event payload was accepted: %#v", payloadRejected)
	}

	history := responseDataList(t, request(t, alice, "get_messages", map[string]interface{}{
		"conversation_id": conversationID,
		"limit":           100,
	}))
	if len(history) != 2 {
		t.Fatalf("dynamic event audit created %d history messages", len(history))
	}
	auditSegments := history[1].(map[string]interface{})["message"].([]interface{})
	if auditSegments[1].(map[string]interface{})["type"] != "dynamic_event_result" {
		t.Fatalf("dynamic event audit segment = %#v", auditSegments)
	}
}

func TestDynamicInteractionVotePersistsStateAndBroadcastsAudit(t *testing.T) {
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
	const conversationID = "private_alice_bob"
	assertOK(t, request(t, alice, "ensure_conversation", map[string]interface{}{
		"conversation_id": conversationID,
		"type":            "private",
		"participants":    []string{"alice", "bob"},
	}))
	content := protocol.DynamicContentSegment(map[string]interface{}{
		"id": "vote-card-1", "version": "1.0", "source": "user",
		"metadata": map[string]interface{}{
			"interaction": map[string]interface{}{
				"kind": "vote", "total": 2, "progress_node_id": "progress",
			},
		},
		"tree": map[string]interface{}{
			"id": "root", "type": "column",
			"children": []interface{}{
				map[string]interface{}{
					"id": "progress", "type": "progress",
					"props": map[string]interface{}{"value": 0.0, "text": "0/2"},
				},
				map[string]interface{}{
					"id": "yes", "type": "button",
					"props":  map[string]interface{}{"option": "yes", "text": "Yes ({{count}})"},
					"events": map[string]interface{}{"click": map[string]interface{}{"action": "yes"}},
				},
			},
		},
	})
	initial := request(t, alice, "send_message", map[string]interface{}{
		"conversation_id": conversationID,
		"message":         []protocol.MessageSegment{content},
	})
	assertOK(t, initial)
	messageID := responseData(t, initial)["message_id"].(string)
	_ = readJSON(t, bob)
	event := protocol.DynamicEventSegment(messageID, "vote-card-1", "yes", "click", "yes", nil)
	dispatched := request(t, bob, "send_message", map[string]interface{}{
		"conversation_id": conversationID,
		"message":         []protocol.MessageSegment{event},
	})
	assertOK(t, dispatched)
	if responseData(t, dispatched)["duplicate"] != false {
		t.Fatalf("first vote was marked duplicate: %#v", dispatched)
	}
	if got := readJSON(t, alice)["message"].([]interface{})[0].(map[string]interface{})["type"]; got != "dynamic_event" {
		t.Fatalf("alice did not receive transient vote event: %#v", got)
	}
	aliceReplacement := readJSON(t, alice)
	bobReplacement := readJSON(t, bob)
	for name, value := range map[string]map[string]interface{}{"alice": aliceReplacement, "bob": bobReplacement} {
		if value["message"].([]interface{})[0].(map[string]interface{})["type"] != "dynamic_replace" {
			t.Fatalf("%s did not receive vote state replacement: %#v", name, value)
		}
	}
	for name, connection := range map[string]*websocket.Conn{"alice": alice, "bob": bob} {
		audit := readJSON(t, connection)
		if audit["dynamic_event_audit"] != true {
			t.Fatalf("%s did not receive vote audit: %#v", name, audit)
		}
	}
	aggregate := request(t, bob, "get_dynamic_interactions", map[string]interface{}{
		"conversation_id": conversationID,
		"message_id":      messageID,
		"content_id":      "vote-card-1",
	})
	assertOK(t, aggregate)
	if events, _ := responseData(t, aggregate)["events"].([]interface{}); len(events) != 0 {
		t.Fatalf("aggregate visibility leaked event details: %#v", events)
	}
	history := responseDataList(t, request(t, alice, "get_messages", map[string]interface{}{
		"conversation_id": conversationID,
		"limit":           100,
	}))
	if len(history) != 2 {
		t.Fatalf("vote history length = %d, want original plus audit", len(history))
	}
	updated := history[0].(map[string]interface{})["message"].([]interface{})[0].(map[string]interface{})
	updatedTree := updated["data"].(map[string]interface{})["tree"].(map[string]interface{})
	children := updatedTree["children"].([]interface{})
	progress := children[0].(map[string]interface{})["props"].(map[string]interface{})
	if progress["value"] != 0.5 || progress["text"] != "1/2" {
		t.Fatalf("vote progress = %#v", progress)
	}
	duplicate := request(t, bob, "send_message", map[string]interface{}{
		"conversation_id": conversationID,
		"message":         []protocol.MessageSegment{event},
	})
	assertOK(t, duplicate)
	if responseData(t, duplicate)["duplicate"] != true {
		t.Fatalf("duplicate vote was not idempotent: %#v", duplicate)
	}
}

func TestGenericDynamicInteractionLedgerQueryUsesEventIDAndNoAudit(t *testing.T) {
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
	const conversationID = "private_alice_bob"
	assertOK(t, request(t, alice, "ensure_conversation", map[string]interface{}{
		"conversation_id": conversationID,
		"type":            "private",
		"participants":    []string{"alice", "bob"},
	}))
	content := protocol.DynamicContentSegment(map[string]interface{}{
		"id": "counter-card-1", "version": "1.0", "source": "ai",
		"metadata": map[string]interface{}{
			"interaction": map[string]interface{}{
				"reducer": "counter",
				"policy": map[string]interface{}{
					"response": "many", "visibility": "public_detail", "total": 2,
				},
				"routing": map[string]interface{}{"fairy": "manual"},
			},
		},
		"tree": map[string]interface{}{
			"id": "root", "type": "button",
			"props": map[string]interface{}{"text": "Add"},
			"events": map[string]interface{}{
				"click": map[string]interface{}{"action": "increment"},
			},
		},
	})
	initial := request(t, alice, "send_message", map[string]interface{}{
		"conversation_id": conversationID,
		"message":         []protocol.MessageSegment{content},
	})
	assertOK(t, initial)
	messageID := responseData(t, initial)["message_id"].(string)
	_ = readJSON(t, bob)
	event := protocol.DynamicEventSegmentWithID(
		"counter-event-1", messageID, "counter-card-1", "root", "click", "increment", nil,
	)
	dispatched := request(t, bob, "send_message", map[string]interface{}{
		"conversation_id": conversationID,
		"message":         []protocol.MessageSegment{event},
	})
	assertOK(t, dispatched)
	if responseData(t, dispatched)["duplicate"] != false {
		t.Fatalf("first generic event was marked duplicate: %#v", dispatched)
	}
	// Drain the transient event and in-place projection broadcast before the
	// next request; the test websocket helper intentionally reads one frame.
	_ = readJSON(t, alice)
	_ = readJSON(t, alice)
	_ = readJSON(t, bob)
	query := request(t, alice, "get_dynamic_interactions", map[string]interface{}{
		"conversation_id": conversationID,
		"message_id":      messageID,
		"content_id":      "counter-card-1",
	})
	assertOK(t, query)
	data := responseData(t, query)
	if data["visibility"] != "public_detail" {
		t.Fatalf("visibility = %#v", data["visibility"])
	}
	state := data["state"].(map[string]interface{})
	if state["responded"] != float64(1) || state["total"] != float64(2) {
		t.Fatalf("state = %#v", state)
	}
	events := data["events"].([]interface{})
	if len(events) != 1 || events[0].(map[string]interface{})["event_id"] != "counter-event-1" {
		t.Fatalf("events = %#v", events)
	}
	history := responseDataList(t, request(t, alice, "get_messages", map[string]interface{}{
		"conversation_id": conversationID,
		"limit":           100,
	}))
	if len(history) != 1 {
		t.Fatalf("generic interaction created %d history messages", len(history))
	}
	duplicate := request(t, bob, "send_message", map[string]interface{}{
		"conversation_id": conversationID,
		"message":         []protocol.MessageSegment{event},
	})
	assertOK(t, duplicate)
	if responseData(t, duplicate)["duplicate"] != true {
		t.Fatalf("event_id retry was not idempotent: %#v", duplicate)
	}
}
