package store

import (
	"path/filepath"
	"testing"
	"time"

	"github.com/icradp/zzz-im-server/internal/protocol"
)

func TestAdminManagementOperations(t *testing.T) {
	tests := []struct {
		name string
		open func(*testing.T) Store
	}{
		{name: "memory", open: func(_ *testing.T) Store { return NewMemoryStore() }},
		{name: "sqlite", open: func(t *testing.T) Store {
			database, err := NewSQLiteStore(filepath.Join(t.TempDir(), "admin.db"))
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
			testAdminManagementOperations(t, database)
		})
	}
}

func testAdminManagementOperations(t *testing.T, database Store) {
	t.Helper()
	for _, userID := range []string{"alice", "bob"} {
		if err := database.SetUser(&User{ID: userID, Nickname: userID, CreatedAt: time.Now()}); err != nil {
			t.Fatal(err)
		}
	}
	if err := database.SaveConversation(&Conversation{ID: "private", Type: "private", Title: "Private", Participants: []string{"alice", "bob"}}); err != nil {
		t.Fatal(err)
	}
	first, err := database.StoreMessage("private", "alice", "Alice", []protocol.MessageSegment{protocol.TextSegment("first")})
	if err != nil {
		t.Fatal(err)
	}
	second, err := database.StoreMessage("private", "bob", "Bob", []protocol.MessageSegment{protocol.TextSegment("second")})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := database.ReactToMessage(first.ID, "bob", "like", false); err != nil {
		t.Fatal(err)
	}
	messages, err := database.GetRecentMessages(10)
	if err != nil || len(messages) != 2 {
		t.Fatalf("recent messages=%#v err=%v", messages, err)
	}
	if messages[0].ID != second.ID {
		t.Fatalf("newest message=%q want=%q", messages[0].ID, second.ID)
	}
	deleted, err := database.DeleteMessage(first.ID)
	if err != nil || !deleted {
		t.Fatalf("delete message=%v err=%v", deleted, err)
	}
	message, err := database.GetMessage(first.ID)
	if err != nil || message != nil {
		t.Fatalf("message after delete=%#v err=%v", message, err)
	}
	reactions, err := database.GetMessageReactionIDs(first.ID, "bob")
	if err != nil || len(reactions) != 0 {
		t.Fatalf("reactions after delete=%#v err=%v", reactions, err)
	}

	for _, session := range []*Session{
		{TokenHash: "alice-one", UserID: "alice", ExpiresAt: time.Now().Add(time.Hour)},
		{TokenHash: "alice-two", UserID: "alice", ExpiresAt: time.Now().Add(time.Hour)},
		{TokenHash: "bob-one", UserID: "bob", ExpiresAt: time.Now().Add(time.Hour)},
	} {
		if err := database.UpsertSession(session); err != nil {
			t.Fatal(err)
		}
	}
	if err := database.DeleteSessionsForUser("alice"); err != nil {
		t.Fatal(err)
	}
	for _, tokenHash := range []string{"alice-one", "alice-two"} {
		session, err := database.GetSession(tokenHash)
		if err != nil || session != nil {
			t.Fatalf("revoked session %q=%#v err=%v", tokenHash, session, err)
		}
	}
	if session, err := database.GetSession("bob-one"); err != nil || session == nil {
		t.Fatalf("unrelated session=%#v err=%v", session, err)
	}

	for _, file := range []*MediaFile{
		{ID: "media-one", FileName: "one.png", FileType: "image", MimeType: "image/png", Size: 10, URL: "/files/media-one", UploaderID: "alice", CreatedAt: time.Now().Add(-time.Minute)},
		{ID: "media-two", FileName: "two.pdf", FileType: "file", MimeType: "application/pdf", Size: 20, URL: "/files/media-two", UploaderID: "bob", CreatedAt: time.Now()},
	} {
		if err := database.StoreMedia(file); err != nil {
			t.Fatal(err)
		}
	}
	files, err := database.GetMediaFiles(10)
	if err != nil || len(files) != 2 {
		t.Fatalf("media files=%#v err=%v", files, err)
	}
}
