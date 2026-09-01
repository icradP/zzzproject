package store

import (
	"path/filepath"
	"testing"

	"github.com/icradp/zzz-im-server/internal/protocol"
)

func TestConversationPreferencesAndMessageCursor(t *testing.T) {
	tests := []struct {
		name string
		open func(*testing.T) Store
	}{
		{
			name: "memory",
			open: func(t *testing.T) Store { return NewMemoryStore() },
		},
		{
			name: "sqlite",
			open: func(t *testing.T) Store {
				store, err := NewSQLiteStore(filepath.Join(t.TempDir(), "im.db"))
				if err != nil {
					t.Fatal(err)
				}
				return store
			},
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			database := test.open(t)
			t.Cleanup(func() { _ = database.Close() })
			conversationID := "private_alice_bob"
			if err := database.SaveConversation(&Conversation{
				ID: conversationID, Type: "private", Title: "Bob",
				Participants: []string{"alice", "bob"},
			}); err != nil {
				t.Fatal(err)
			}

			messageIDs := make([]string, 0, 5)
			for index := 0; index < 5; index++ {
				message, err := database.StoreMessage(
					conversationID, "alice", "Alice",
					[]protocol.MessageSegment{protocol.TextSegment("message")},
				)
				if err != nil {
					t.Fatal(err)
				}
				messageIDs = append(messageIDs, message.ID)
			}

			latest, err := database.GetMessages(conversationID, 2)
			if err != nil {
				t.Fatal(err)
			}
			if len(latest) != 2 || latest[0].ID != messageIDs[3] || latest[1].ID != messageIDs[4] {
				t.Fatalf("unexpected latest page: %#v", latest)
			}
			older, err := database.GetMessagesBefore(conversationID, latest[0].ID, 2)
			if err != nil {
				t.Fatal(err)
			}
			if len(older) != 2 || older[0].ID != messageIDs[1] || older[1].ID != messageIDs[2] {
				t.Fatalf("unexpected older page: %#v", older)
			}

			preference := &ConversationPreference{
				ConversationID: conversationID,
				UserID:         "bob",
				IsPinned:       true,
				IsMuted:        true,
			}
			if err := database.SetConversationPreference(preference); err != nil {
				t.Fatal(err)
			}
			stored, err := database.GetConversationPreference(conversationID, "bob")
			if err != nil {
				t.Fatal(err)
			}
			if stored == nil || !stored.IsPinned || !stored.IsMuted {
				t.Fatalf("unexpected preference: %#v", stored)
			}
		})
	}
}
