package store

import (
	"path/filepath"
	"testing"

	"github.com/icradp/zzz-im-server/internal/protocol"
)

func TestMemoryStoreMessageReactionsAreIdempotentAndPerUser(t *testing.T) {
	db := NewMemoryStore()
	if err := db.SetUser(&User{ID: "alice", Nickname: "Alice"}); err != nil {
		t.Fatal(err)
	}
	message, err := db.StoreMessage(
		"private_alice_bob",
		"alice",
		"Alice",
		[]protocol.MessageSegment{protocol.TextSegment("hello")},
	)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.ReactToMessage(message.ID, "alice", "76", false); err != nil {
		t.Fatal(err)
	}
	if _, err := db.ReactToMessage(message.ID, "alice", "76", false); err != nil {
		t.Fatal(err)
	}
	if _, err := db.ReactToMessage(message.ID, "bob", "76", false); err != nil {
		t.Fatal(err)
	}
	updated, err := db.GetMessage(message.ID)
	if err != nil {
		t.Fatal(err)
	}
	if len(updated.Reactions) != 1 || updated.Reactions[0].EmojiID != "76" || updated.Reactions[0].Count != 2 {
		t.Fatalf("unexpected aggregate: %#v", updated.Reactions)
	}
	ids, err := db.GetMessageReactionIDs(message.ID, "alice")
	if err != nil {
		t.Fatal(err)
	}
	if len(ids) != 1 || ids[0] != "76" {
		t.Fatalf("unexpected alice reactions: %#v", ids)
	}
	if _, err := db.ReactToMessage(message.ID, "alice", "76", true); err != nil {
		t.Fatal(err)
	}
	updated, err = db.GetMessage(message.ID)
	if err != nil {
		t.Fatal(err)
	}
	if len(updated.Reactions) != 1 || updated.Reactions[0].Count != 1 {
		t.Fatalf("unexpected count after removal: %#v", updated.Reactions)
	}
}

func TestSQLiteStoreMessageReactionsPersist(t *testing.T) {
	db, err := NewSQLiteStore(filepath.Join(t.TempDir(), "reactions.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = db.Close() })
	message, err := db.StoreMessage(
		"private_alice_bob",
		"alice",
		"Alice",
		[]protocol.MessageSegment{protocol.TextSegment("hello")},
	)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.ReactToMessage(message.ID, "alice", "66", false); err != nil {
		t.Fatal(err)
	}
	history, err := db.GetMessages("private_alice_bob", 10)
	if err != nil {
		t.Fatal(err)
	}
	if len(history) != 1 || len(history[0].Reactions) != 1 || history[0].Reactions[0].EmojiID != "66" {
		t.Fatalf("reaction did not persist: %#v", history)
	}
}
