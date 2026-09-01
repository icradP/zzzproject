package store

import (
	"path/filepath"
	"testing"
	"time"

	"github.com/icradp/zzz-im-server/internal/protocol"
)

func TestSQLiteServerStats(t *testing.T) {
	database, err := NewSQLiteStore(filepath.Join(t.TempDir(), "stats.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = database.Close() })

	for _, user := range []*User{
		{ID: "alice", Nickname: "Alice", Online: true},
		{ID: "bob", Nickname: "Bob"},
	} {
		if err := database.SetUser(user); err != nil {
			t.Fatal(err)
		}
	}
	conversation := &Conversation{
		ID:           "private-alice-bob",
		Type:         "private",
		Title:        "Alice and Bob",
		Participants: []string{"alice", "bob"},
		CreatedAt:    time.Now(),
	}
	if err := database.SaveConversation(conversation); err != nil {
		t.Fatal(err)
	}
	if _, err := database.StoreMessage(conversation.ID, "alice", "Alice", []protocol.MessageSegment{{Type: "text", Data: map[string]interface{}{"text": "hello"}}}); err != nil {
		t.Fatal(err)
	}
	if err := database.UpsertSession(&Session{TokenHash: "active", UserID: "alice", ExpiresAt: time.Now().Add(time.Hour)}); err != nil {
		t.Fatal(err)
	}
	if err := database.UpsertSession(&Session{TokenHash: "expired", UserID: "bob", ExpiresAt: time.Now().Add(-time.Hour)}); err != nil {
		t.Fatal(err)
	}
	if err := database.StoreMedia(&MediaFile{ID: "media-1", FileName: "photo.jpg", FileType: "image", Size: 2048, URL: "/files/media-1", UploaderID: "alice"}); err != nil {
		t.Fatal(err)
	}
	if err := database.UpsertPushSubscription(&PushSubscription{UserID: "alice", Endpoint: "https://push.example/1", P256DH: "key", Auth: "auth"}); err != nil {
		t.Fatal(err)
	}

	stats, err := database.GetServerStats()
	if err != nil {
		t.Fatal(err)
	}
	if stats.Users != 2 || stats.OnlineUsers != 1 || stats.Conversations != 1 || stats.Messages != 1 {
		t.Fatalf("unexpected core stats: %#v", stats)
	}
	if stats.ActiveSessions != 1 || stats.MediaFiles != 1 || stats.MediaBytes != 2048 || stats.PushSubscriptions != 1 {
		t.Fatalf("unexpected operational stats: %#v", stats)
	}
}
