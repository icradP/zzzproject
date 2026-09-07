package fairy

import (
	"encoding/json"
	"testing"

	"github.com/icradp/zzz-im-server/internal/protocol"
)

func TestTerminalRequestBrokerCompletesOnlyPrivateClientResults(t *testing.T) {
	broker := NewTerminalRequestBroker()
	resultCh := make(chan terminalResultPayload, 1)
	broker.pending["term-test"] = resultCh
	event := messageEvent{
		MessageType:    "private",
		ConversationID: "private_alice_fairy",
		Sender:         protocol.Sender{UserID: "alice"},
		Message: []protocol.MessageSegment{
			protocol.TextSegment("Command finished."),
			{Type: "terminal_result", Data: map[string]interface{}{
				"request_id": "term-test", "status": "completed", "output": "ok", "exit_code": 0,
			}},
		},
	}
	if !broker.Complete(event, "fairy") {
		t.Fatal("valid private terminal result was not accepted")
	}
	select {
	case result := <-resultCh:
		if result.Status != "completed" || result.Summary != "Command finished." || result.Output != "ok" {
			t.Fatalf("unexpected result: %#v", result)
		}
	default:
		t.Fatal("terminal result was not delivered to pending request")
	}
	if broker.Complete(messageEvent{
		MessageType: "private", ConversationID: event.ConversationID,
		Sender: protocol.Sender{UserID: "fairy"}, Message: event.Message,
	}, "fairy") {
		t.Fatal("Fairy self-message should not complete a terminal request")
	}
}

func TestTerminalBridgeToolProducesPlannerSafeResult(t *testing.T) {
	tool := &terminalBridgeTool{}
	if got := tool.Spec().Name; got != terminalBridgeToolName {
		t.Fatalf("tool name = %q", got)
	}
	output, err := json.Marshal(terminalResultPayload{
		RequestID: "term-test", Operation: "run_command", Status: "completed",
		Summary: "Command finished.", Output: "ok",
	})
	if err != nil {
		t.Fatal(err)
	}
	projection, err := tool.Project(output)
	if err != nil {
		t.Fatal(err)
	}
	if projection.UserText != "Command finished.\n\nok" || projection.ModelText == "" {
		t.Fatalf("unexpected projection: %#v", projection)
	}
}
