package store

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/icradp/zzz-im-server/internal/protocol"
)

func TestMessageIdempotencyStores(t *testing.T) {
	tests := []struct {
		name string
		open func(*testing.T) Store
	}{
		{name: "memory", open: func(*testing.T) Store { return NewMemoryStore() }},
		{name: "sqlite", open: func(t *testing.T) Store {
			database, err := NewSQLiteStore(filepath.Join(t.TempDir(), "messages.db"))
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
			if err := database.SaveConversation(&Conversation{ID: conversationID, Type: "private", Title: "Alice and Bob", Participants: []string{"alice", "bob"}}); err != nil {
				t.Fatal(err)
			}
			segments := []protocol.MessageSegment{protocol.TextSegment("hello")}
			first, duplicate, err := database.StoreMessageIdempotent(conversationID, "alice", "Alice", "client-1", segments)
			if err != nil || duplicate {
				t.Fatalf("first store: message=%#v duplicate=%v err=%v", first, duplicate, err)
			}
			second, duplicate, err := database.StoreMessageIdempotent(conversationID, "alice", "Alice", "client-1", segments)
			if err != nil || !duplicate || second == nil || second.ID != first.ID || !second.Timestamp.Equal(first.Timestamp) {
				t.Fatalf("duplicate store: first=%#v second=%#v duplicate=%v err=%v", first, second, duplicate, err)
			}
			if _, _, err := database.StoreMessageIdempotent(conversationID, "alice", "Alice", "client-1", []protocol.MessageSegment{protocol.TextSegment("changed")}); !errors.Is(err, ErrMessageIdempotencyConflict) {
				t.Fatalf("changed request error = %v", err)
			}
			third, duplicate, err := database.StoreMessageIdempotent(conversationID, "bob", "Bob", "client-1", []protocol.MessageSegment{protocol.TextSegment("same ID, other sender")})
			if err != nil || duplicate || third.ID == first.ID {
				t.Fatalf("other sender store: message=%#v duplicate=%v err=%v", third, duplicate, err)
			}
			messages, err := database.GetMessages(conversationID, 100)
			if err != nil || len(messages) != 2 {
				t.Fatalf("stored messages = %d, err=%v", len(messages), err)
			}
		})
	}
}

func TestPostgresMessageIdempotency(t *testing.T) {
	dsn := os.Getenv("ZZZ_TEST_POSTGRES_DSN")
	if dsn == "" {
		t.Skip("ZZZ_TEST_POSTGRES_DSN is not configured")
	}
	suffix := time.Now().UnixNano()
	conversationID := fmt.Sprintf("idem_%d", suffix)
	aliceID := fmt.Sprintf("alice_%d", suffix)
	bobID := fmt.Sprintf("bob_%d", suffix)
	segments := []protocol.MessageSegment{protocol.TextSegment("persist once")}

	firstStore, err := NewPostgresStore(dsn)
	if err != nil {
		t.Fatal(err)
	}
	if err := firstStore.SaveConversation(&Conversation{
		ID: conversationID, Type: "private", Title: "Idempotency test", Participants: []string{aliceID, bobID},
	}); err != nil {
		t.Fatal(err)
	}
	first, duplicate, err := firstStore.StoreMessageIdempotent(conversationID, aliceID, "Alice", "client-1", segments)
	if err != nil || duplicate {
		t.Fatalf("first Postgres store: duplicate=%v err=%v", duplicate, err)
	}
	if err := firstStore.Close(); err != nil {
		t.Fatal(err)
	}

	reopened, err := NewPostgresStore(dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer reopened.Close()
	defer reopened.DeleteConversation(conversationID)
	second, duplicate, err := reopened.StoreMessageIdempotent(conversationID, aliceID, "Alice", "client-1", segments)
	if err != nil || !duplicate || second.ID != first.ID {
		t.Fatalf("reopened Postgres store: first=%s second=%#v duplicate=%v err=%v", first.ID, second, duplicate, err)
	}
	if _, _, err := reopened.StoreMessageIdempotent(conversationID, aliceID, "Alice", "client-1", []protocol.MessageSegment{protocol.TextSegment("changed")}); !errors.Is(err, ErrMessageIdempotencyConflict) {
		t.Fatalf("Postgres conflicting request error = %v", err)
	}
	third, duplicate, err := reopened.StoreMessageIdempotent(conversationID, bobID, "Bob", "client-1", []protocol.MessageSegment{protocol.TextSegment("other sender")})
	if err != nil || duplicate || third.ID == first.ID {
		t.Fatalf("other Postgres sender: message=%#v duplicate=%v err=%v", third, duplicate, err)
	}
	messages, err := reopened.GetMessages(conversationID, 100)
	if err != nil || len(messages) != 2 {
		t.Fatalf("Postgres messages = %d, err=%v", len(messages), err)
	}
}

func TestSQLiteMessageIdempotencySurvivesReopen(t *testing.T) {
	path := filepath.Join(t.TempDir(), "messages.db")
	conversationID := "private_alice_bob"
	segments := []protocol.MessageSegment{protocol.TextSegment("persist once")}
	firstStore, err := NewSQLiteStore(path)
	if err != nil {
		t.Fatal(err)
	}
	if err := firstStore.SaveConversation(&Conversation{ID: conversationID, Type: "private", Title: "Alice and Bob", Participants: []string{"alice", "bob"}}); err != nil {
		t.Fatal(err)
	}
	first, duplicate, err := firstStore.StoreMessageIdempotent(conversationID, "alice", "Alice", "durable-client-id", segments)
	if err != nil || duplicate {
		t.Fatalf("first store: duplicate=%v err=%v", duplicate, err)
	}
	if err := firstStore.Close(); err != nil {
		t.Fatal(err)
	}

	reopened, err := NewSQLiteStore(path)
	if err != nil {
		t.Fatal(err)
	}
	defer reopened.Close()
	second, duplicate, err := reopened.StoreMessageIdempotent(conversationID, "alice", "Alice", "durable-client-id", segments)
	if err != nil || !duplicate || second.ID != first.ID {
		t.Fatalf("reopened store: first=%s second=%#v duplicate=%v err=%v", first.ID, second, duplicate, err)
	}
	messages, err := reopened.GetMessages(conversationID, 100)
	if err != nil || len(messages) != 1 {
		t.Fatalf("reopened messages = %d, err=%v", len(messages), err)
	}
}
