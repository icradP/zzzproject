package store

import (
	"path/filepath"
	"testing"

	"github.com/icradp/zzz-im-server/internal/protocol"
)

func TestConversationReadStateStores(t *testing.T) {
	tests := []struct {
		name string
		open func(t *testing.T) Store
	}{
		{name: "memory", open: func(t *testing.T) Store { return NewMemoryStore() }},
		{name: "sqlite", open: func(t *testing.T) Store {
			database, err := NewSQLiteStore(filepath.Join(t.TempDir(), "read-state.db"))
			if err != nil {
				t.Fatal(err)
			}
			return database
		}},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			database := test.open(t)
			t.Cleanup(func() { _ = database.Close() })
			conversationID := "private_alice_bob"
			if err := database.SaveConversation(&Conversation{
				ID: conversationID, Type: "private", Title: "Alice and Bob",
				Participants: []string{"alice", "bob"},
			}); err != nil {
				t.Fatal(err)
			}

			first, err := database.StoreMessage(
				conversationID, "alice", "Alice", []protocol.MessageSegment{protocol.TextSegment("hello")},
			)
			if err != nil {
				t.Fatal(err)
			}
			assertUnreadCount(t, database, conversationID, "alice", 0)
			assertUnreadCount(t, database, conversationID, "bob", 1)

			state, err := database.MarkConversationRead(conversationID, "bob")
			if err != nil {
				t.Fatal(err)
			}
			if state.LastReadMessageID != first.ID {
				t.Fatalf("read cursor = %q, want %q", state.LastReadMessageID, first.ID)
			}
			assertUnreadCount(t, database, conversationID, "bob", 0)

			if _, err := database.StoreMessage(
				conversationID, "bob", "Bob", []protocol.MessageSegment{protocol.TextSegment("reply")},
			); err != nil {
				t.Fatal(err)
			}
			assertUnreadCount(t, database, conversationID, "alice", 1)
			assertUnreadCount(t, database, conversationID, "bob", 0)

			if _, err := database.StoreMessage(
				conversationID, "alice", "Alice", []protocol.MessageSegment{protocol.TextSegment("again")},
			); err != nil {
				t.Fatal(err)
			}
			assertUnreadCount(t, database, conversationID, "bob", 1)
		})
	}
}

func TestSQLiteReadStateSurvivesReopen(t *testing.T) {
	path := filepath.Join(t.TempDir(), "persisted-read-state.db")
	conversationID := "private_alice_bob"
	first, err := NewSQLiteStore(path)
	if err != nil {
		t.Fatal(err)
	}
	if err := first.SaveConversation(&Conversation{
		ID: conversationID, Type: "private", Title: "Alice and Bob",
		Participants: []string{"alice", "bob"},
	}); err != nil {
		t.Fatal(err)
	}
	message, err := first.StoreMessage(
		conversationID, "alice", "Alice", []protocol.MessageSegment{protocol.TextSegment("persist me")},
	)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := first.MarkConversationRead(conversationID, "bob"); err != nil {
		t.Fatal(err)
	}
	if err := first.Close(); err != nil {
		t.Fatal(err)
	}

	reopened, err := NewSQLiteStore(path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = reopened.Close() })
	state, err := reopened.GetConversationRead(conversationID, "bob")
	if err != nil {
		t.Fatal(err)
	}
	if state == nil || state.LastReadMessageID != message.ID {
		t.Fatalf("persisted read state = %#v", state)
	}
	assertUnreadCount(t, reopened, conversationID, "bob", 0)
	if _, err := reopened.StoreMessage(
		conversationID, "alice", "Alice", []protocol.MessageSegment{protocol.TextSegment("new")},
	); err != nil {
		t.Fatal(err)
	}
	assertUnreadCount(t, reopened, conversationID, "bob", 1)
}

func assertUnreadCount(t *testing.T, database Store, conversationID, userID string, want int) {
	t.Helper()
	got, err := database.CountUnreadMessages(conversationID, userID)
	if err != nil {
		t.Fatal(err)
	}
	if got != want {
		t.Fatalf("unread count for %s = %d, want %d", userID, got, want)
	}
}
