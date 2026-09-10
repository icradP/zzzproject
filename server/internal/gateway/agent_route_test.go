package gateway

import (
	"strings"
	"testing"

	"github.com/icradp/zzz-im-server/internal/protocol"
	"github.com/icradp/zzz-im-server/internal/store"
)

func TestAgentRouteValidationRequiresExactFairyConversation(t *testing.T) {
	database := store.NewMemoryStore()
	gateway := NewGateway(database)
	client := &Client{userID: "alice", deviceID: "zzzterm-validation"}
	assistant := []protocol.MessageSegment{
		{Type: "agent_route", Data: map[string]interface{}{"route": "local", "role": "assistant"}},
		protocol.TextSegment("local answer"),
	}

	if err := database.SaveConversation(&store.Conversation{
		ID: "private_alice_fairy", Type: "private",
		Participants: []string{"alice", "fairy"},
	}); err != nil {
		t.Fatal(err)
	}
	if err := gateway.validateAgentRouteSegments(client, "private_alice_fairy", "private", assistant); err != nil {
		t.Fatalf("valid local Agent route rejected: %v", err)
	}

	cases := []struct {
		name           string
		conversationID string
		conversation   *store.Conversation
		deviceID       string
		segments       []protocol.MessageSegment
		want           string
	}{
		{
			name:           "ordinary private conversation",
			conversationID: "private_alice_bob",
			conversation: &store.Conversation{
				ID: "private_alice_bob", Type: "private",
				Participants: []string{"alice", "bob"},
			},
			want: "Fairy",
		},
		{
			name:           "extra participant",
			conversationID: "agent_shared",
			conversation: &store.Conversation{
				ID: "agent_shared", Type: "private",
				Participants: []string{"alice", "fairy", "bob"},
			},
			want: "only",
		},
		{
			name:           "non terminal device",
			conversationID: "private_alice_fairy",
			conversation:   nil,
			deviceID:       "pwa-alice",
			want:           "ZZZTerm",
		},
		{
			name:           "group conversation",
			conversationID: "group_room",
			conversation: &store.Conversation{
				ID: "group_room", Type: "group",
				Participants: []string{"alice", "fairy"},
			},
			want: "private",
		},
		{
			name:           "local user cannot create Agent card",
			conversationID: "private_alice_fairy",
			conversation:   nil,
			segments: []protocol.MessageSegment{
				{Type: "agent_route", Data: map[string]interface{}{"route": "local", "role": "user"}},
				protocol.DynamicContentSegment(map[string]interface{}{"id": "card"}),
			},
			want: "user messages cannot",
		},
	}
	for _, testCase := range cases {
		t.Run(testCase.name, func(t *testing.T) {
			if testCase.conversation != nil {
				if err := database.SaveConversation(testCase.conversation); err != nil {
					t.Fatal(err)
				}
			}
			candidate := client
			if testCase.deviceID != "" {
				candidate = &Client{userID: "alice", deviceID: testCase.deviceID}
			}
			segments := testCase.segments
			if segments == nil {
				segments = assistant
			}
			err := gateway.validateAgentRouteSegments(
				candidate,
				testCase.conversationID,
				map[bool]string{true: "group", false: "private"}[strings.HasPrefix(testCase.conversationID, "group_")],
				segments,
			)
			if err == nil || !strings.Contains(err.Error(), testCase.want) {
				t.Fatalf("validation error = %v, want substring %q", err, testCase.want)
			}
		})
	}
}

func TestAgentConversationParticipantsAreRestricted(t *testing.T) {
	if !isExactAgentConversationParticipants([]string{"alice", "fairy"}, "alice") {
		t.Fatal("expected the current user and Fairy pair to be accepted")
	}
	for _, participants := range [][]string{
		{"alice", "fairy", "bob"},
		{"alice", "bob"},
		{"alice", "alice"},
		{"fairy", "bob"},
	} {
		if isExactAgentConversationParticipants(participants, "alice") {
			t.Fatalf("unexpected Agent participant set accepted: %v", participants)
		}
	}
}
