package fairy

import (
	"testing"

	"github.com/icradp/zzz-im-server/internal/protocol"
)

func TestMessageTextIgnoresLocalAgentRoute(t *testing.T) {
	text, mentioned := messageText([]protocol.MessageSegment{
		{Type: "agent_route", Data: map[string]interface{}{"route": "local"}},
		protocol.TextSegment("already handled locally"),
	}, "fairy")
	if text != "" || mentioned {
		t.Fatalf("local Agent message re-entered Fairy: text=%q mentioned=%v", text, mentioned)
	}
}

func TestMessageTextKeepsRemoteMessages(t *testing.T) {
	text, mentioned := messageText([]protocol.MessageSegment{
		protocol.TextSegment("hello"),
	}, "fairy")
	if text != "hello" || mentioned {
		t.Fatalf("remote message was not preserved: text=%q mentioned=%v", text, mentioned)
	}
}
