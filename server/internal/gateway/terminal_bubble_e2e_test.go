package gateway

import (
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"
	"github.com/icradp/zzz-im-server/internal/protocol"
	"github.com/icradp/zzz-im-server/internal/store"
)

// TestTerminalBubbleLifecycleAcrossDevices exercises the protocol path used by
// ZZZ IM and ZZZTerm. The two clients share one account, while Fairy remains a
// separate conversation participant. This catches regressions where a local
// Agent result is persisted but never reaches the user's IM device.
func TestTerminalBubbleLifecycleAcrossDevices(t *testing.T) {
	database := store.NewMemoryStore()
	gateway := NewGateway(database)
	server := httptest.NewServer(gateway)
	t.Cleanup(server.Close)
	websocketURL := "ws" + strings.TrimPrefix(server.URL, "http")

	zzzIM := dialWebSocket(t, websocketURL)
	zzzTerm := dialWebSocket(t, websocketURL)
	fairy := dialWebSocket(t, websocketURL)
	t.Cleanup(func() { _ = zzzIM.Close() })
	t.Cleanup(func() { _ = zzzTerm.Close() })
	t.Cleanup(func() { _ = fairy.Close() })
	authenticateWithDevice(t, zzzIM, "alice", "pwa-im-e2e")
	authenticateWithDevice(t, zzzTerm, "alice", "zzzterm-e2e")
	authenticateWithDevice(t, fairy, "fairy", "fairy-e2e")
	if _, err := database.AddFriend("alice", "fairy"); err != nil {
		t.Fatal(err)
	}

	const conversationID = "private_alice_fairy"
	assertOK(t, request(t, zzzIM, "ensure_conversation", map[string]interface{}{
		"conversation_id": conversationID,
		"type":            "private",
		"participants":    []string{"alice", "fairy"},
	}))

	// The IM device sends the request to Fairy. The sender already owns this
	// message locally, so only Fairy needs the realtime event here.
	prompt := request(t, zzzIM, "send_message", map[string]interface{}{
		"conversation_id": conversationID,
		"message":         []protocol.MessageSegment{protocol.TextSegment("Inspect the host")},
	})
	assertOK(t, prompt)
	promptID := responseData(t, prompt)["message_id"].(string)
	if event := readJSON(t, fairy); event["message_id"] != promptID {
		t.Fatalf("Fairy did not receive the IM prompt: %#v", event)
	}

	// Fairy proposes a command. Both the IM device and the execution device
	// must receive the same approval bubble.
	requestID := "term-e2e-1"
	proposal := request(t, fairy, "send_message", map[string]interface{}{
		"conversation_id": conversationID,
		"message": []protocol.MessageSegment{
			protocol.TextSegment("I will inspect the host."),
			protocol.TerminalRequestSegment(
				requestID,
				"run_command",
				"prod-host",
				"uptime",
				time.Now().Add(2*time.Minute).UnixMilli(),
			),
		},
	})
	assertOK(t, proposal)
	proposalID := responseData(t, proposal)["message_id"].(string)
	for name, connection := range map[string]*websocket.Conn{
		"ZZZ IM":  zzzIM,
		"ZZZTerm": zzzTerm,
	} {
		event := readJSON(t, connection)
		if event["message_id"] != proposalID || event["sender"].(map[string]interface{})["user_id"] != "fairy" {
			t.Fatalf("%s did not receive Fairy proposal: %#v", name, event)
		}
	}

	// Approval is a transient dynamic event. It must reach ZZZTerm without
	// creating an extra history message.
	approval := protocol.DynamicEventSegment(
		proposalID,
		"legacy:"+proposalID+":1",
		"terminal-request-"+requestID,
		"click",
		"approve",
		nil,
	)
	assertOK(t, request(t, zzzIM, "send_message", map[string]interface{}{
		"conversation_id": conversationID,
		"message":         []protocol.MessageSegment{approval},
	}))
	termEvent := readJSON(t, zzzTerm)
	if termEvent["message_id"] != proposalID {
		t.Fatalf("ZZZTerm did not receive approval event: %#v", termEvent)
	}
	if segment := termEvent["message"].([]interface{})[0].(map[string]interface{}); segment["type"] != "dynamic_event" {
		t.Fatalf("approval was not delivered as dynamic_event: %#v", segment)
	}
	// The interaction result is now a durable, immediately broadcast audit row.
	// Consume it on every device before the command result is sent.
	for name, connection := range map[string]*websocket.Conn{
		"ZZZ IM":  zzzIM,
		"ZZZTerm": zzzTerm,
		"Fairy":   fairy,
	} {
		if name == "Fairy" {
			// Fairy receives the transient event before the durable audit row.
			transient := readJSON(t, connection)
			if transient["message_id"] != proposalID {
				t.Fatalf("Fairy did not receive approval event before audit: %#v", transient)
			}
		}
		audit := readJSON(t, connection)
		if audit["dynamic_event_audit"] != true {
			t.Fatalf("%s did not receive approval audit: %#v", name, audit)
		}
	}

	// The local execution device publishes the result. Its other same-account
	// device must receive it in realtime, while the sending socket is not echoed.
	result := request(t, zzzTerm, "send_message", map[string]interface{}{
		"conversation_id":   conversationID,
		"client_message_id": "zzzterm-local-term-e2e-1-result",
		"message": []protocol.MessageSegment{
			{Type: "agent_route", Data: map[string]interface{}{"route": "local", "role": "assistant"}},
			protocol.TextSegment("The command completed successfully."),
			{Type: "terminal_result", Data: map[string]interface{}{
				"request_id": requestID,
				"status":     "completed",
				"output":     "up 3 days",
				"exit_code":  0,
			}},
		},
	})
	assertOK(t, result)
	resultID := responseData(t, result)["message_id"].(string)
	imResult := readJSON(t, zzzIM)
	if imResult["message_id"] != resultID || imResult["sender"].(map[string]interface{})["user_id"] != "alice" {
		t.Fatalf("ZZZ IM did not receive local Agent result: %#v", imResult)
	}
	if resultSegments := imResult["message"].([]interface{}); len(resultSegments) != 3 || resultSegments[2].(map[string]interface{})["type"] != "terminal_result" {
		t.Fatalf("local Agent result segments = %#v", resultSegments)
	}
	_ = readJSON(t, fairy)

	// The transient approval is absent, and the canonical history contains the
	// prompt, proposal, durable approval audit, and result exactly once.
	history := responseDataList(t, request(t, zzzIM, "get_messages", map[string]interface{}{
		"conversation_id": conversationID,
		"limit":           100,
	}))
	if len(history) != 4 {
		t.Fatalf("terminal bubble lifecycle created %d history messages: %#v", len(history), history)
	}
	if history[0].(map[string]interface{})["message_id"] != promptID ||
		history[1].(map[string]interface{})["message_id"] != proposalID ||
		history[3].(map[string]interface{})["message_id"] != resultID {
		t.Fatalf("history order changed: %#v", history)
	}
	if history[2].(map[string]interface{})["message"].([]interface{})[1].(map[string]interface{})["type"] != "dynamic_event_result" {
		t.Fatalf("approval audit was not persisted: %#v", history[2])
	}
}

func authenticateWithDevice(
	t *testing.T,
	connection *websocket.Conn,
	userID string,
	deviceID string,
) {
	t.Helper()
	response := request(t, connection, "auth", map[string]interface{}{
		"token":        userID,
		"user_id":      userID,
		"device_id":    deviceID,
		"capabilities": currentTestCapabilities(),
	})
	assertOK(t, response)
}
