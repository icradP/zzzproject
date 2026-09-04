package fairy

import (
	"context"
	"strings"
	"testing"
	"time"
)

func TestTerminalBridgeCreatesShortLivedPrivateApprovalRequest(t *testing.T) {
	plugin := NewTerminalBridgePlugin()
	now := time.Unix(1_800_000_000, 0)
	plugin.now = func() time.Time { return now }
	messenger := &fakeInteractiveMessenger{}
	handled, err := plugin.HandleInteractive(context.Background(), messenger, PluginRequest{
		Text: "/term run production uptime", ConversationID: "private_alice_fairy",
		MessageID: "msg-1", MessageType: "private", SenderID: "alice",
	})
	if err != nil || !handled || len(messenger.segments) != 1 {
		t.Fatalf("HandleInteractive() = %v, %v, segments=%d", handled, err, len(messenger.segments))
	}
	segments := messenger.segments[0]
	if len(segments) != 3 || segments[2].Type != "terminal_request" {
		t.Fatalf("unexpected terminal message: %#v", segments)
	}
	data := segments[2].Data
	if data["operation"] != "run_command" || data["host_id"] != "production" || data["command"] != "uptime" || data["expires_at"] != now.Add(terminalRequestTTL).UnixMilli() {
		t.Fatalf("unexpected request data: %#v", data)
	}
}

func TestTerminalBridgeRejectsGroupAndInvalidCommands(t *testing.T) {
	plugin := NewTerminalBridgePlugin()
	messenger := &fakeInteractiveMessenger{}
	for _, request := range []PluginRequest{
		{Text: "/term hosts", ConversationID: "group_1", MessageID: "msg-1", MessageType: "group"},
		{Text: "/term run host", ConversationID: "private_alice_fairy", MessageID: "msg-2", MessageType: "private"},
	} {
		handled, err := plugin.HandleInteractive(context.Background(), messenger, request)
		if err != nil || !handled {
			t.Fatalf("HandleInteractive() = %v, %v", handled, err)
		}
	}
	if len(messenger.texts) != 2 || len(messenger.segments) != 0 {
		t.Fatalf("unexpected responses: texts=%#v segments=%#v", messenger.texts, messenger.segments)
	}
}

func TestTerminalBridgeRejectsSensitiveCommandsBeforeApproval(t *testing.T) {
	plugin := NewTerminalBridgePlugin()
	messenger := &fakeInteractiveMessenger{}
	handled, err := plugin.HandleInteractive(context.Background(), messenger, PluginRequest{
		Text:           "/term run production curl -H 'Authorization: Bearer sk-test-secret-value'",
		ConversationID: "private_alice_fairy",
		MessageID:      "msg-sensitive",
		MessageType:    "private",
		SenderID:       "alice",
	})
	if err != nil || !handled {
		t.Fatalf("HandleInteractive() = %v, %v", handled, err)
	}
	if len(messenger.segments) != 0 || len(messenger.texts) != 1 {
		t.Fatalf("sensitive command created an approval request: texts=%#v segments=%#v", messenger.texts, messenger.segments)
	}
	if !strings.Contains(messenger.texts[0], "不会发送") {
		t.Fatalf("unexpected sensitive command response: %q", messenger.texts[0])
	}
}
