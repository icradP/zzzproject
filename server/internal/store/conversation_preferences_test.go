package store

import (
	"database/sql"
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
				ConversationID:    conversationID,
				UserID:            "bob",
				IsPinned:          true,
				NotificationLevel: NotificationLevelMentionsOnly,
			}
			if err := database.SetConversationPreference(preference); err != nil {
				t.Fatal(err)
			}
			stored, err := database.GetConversationPreference(conversationID, "bob")
			if err != nil {
				t.Fatal(err)
			}
			if stored == nil || !stored.IsPinned || stored.IsMuted || stored.NotificationLevel != NotificationLevelMentionsOnly {
				t.Fatalf("unexpected preference: %#v", stored)
			}
		})
	}
}

func TestSQLiteMigratesLegacyMuteAndAnnouncementOnce(t *testing.T) {
	path := filepath.Join(t.TempDir(), "legacy-preferences.db")
	legacy, err := sql.Open("sqlite3", path)
	if err != nil {
		t.Fatal(err)
	}
	for _, statement := range []string{
		`CREATE TABLE conversations (
			id TEXT PRIMARY KEY, type TEXT NOT NULL, title TEXT NOT NULL,
			avatar_url TEXT DEFAULT '', owner_id TEXT DEFAULT '', participants TEXT DEFAULT '[]',
			created_at DATETIME DEFAULT CURRENT_TIMESTAMP
		)`,
		`CREATE TABLE conversation_preferences (
			conversation_id TEXT NOT NULL, user_id TEXT NOT NULL,
			is_pinned BOOLEAN DEFAULT FALSE, is_muted BOOLEAN DEFAULT FALSE,
			updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
			PRIMARY KEY (conversation_id, user_id)
		)`,
		`CREATE TABLE groups (
			id TEXT PRIMARY KEY, name TEXT NOT NULL, avatar_url TEXT DEFAULT '',
			announcement TEXT DEFAULT '', owner_id TEXT NOT NULL,
			mute_all BOOLEAN DEFAULT FALSE, created_at DATETIME DEFAULT CURRENT_TIMESTAMP
		)`,
		`INSERT INTO conversations (id, type, title, participants)
			VALUES ('group_legacy', 'group', 'Legacy', '["owner","member"]')`,
		`INSERT INTO conversation_preferences (conversation_id, user_id, is_pinned, is_muted)
			VALUES ('group_legacy', 'member', TRUE, TRUE)`,
		`INSERT INTO groups (id, name, announcement, owner_id)
			VALUES ('group_legacy', 'Legacy', 'Legacy notice', 'owner')`,
	} {
		if _, err := legacy.Exec(statement); err != nil {
			t.Fatal(err)
		}
	}
	if err := legacy.Close(); err != nil {
		t.Fatal(err)
	}

	for attempt := 0; attempt < 2; attempt++ {
		database, err := NewSQLiteStore(path)
		if err != nil {
			t.Fatal(err)
		}
		preference, err := database.GetConversationPreference("group_legacy", "member")
		if err != nil || preference == nil || preference.NotificationLevel != NotificationLevelMuted || !preference.IsMuted {
			t.Fatalf("legacy mute was not migrated: %#v err=%v", preference, err)
		}
		announcements, err := database.GetGroupAnnouncements("group_legacy", "member")
		if err != nil || len(announcements) != 1 || announcements[0].Content != "Legacy notice" {
			t.Fatalf("legacy announcement migration is not idempotent: %#v err=%v", announcements, err)
		}
		if err := database.Close(); err != nil {
			t.Fatal(err)
		}
	}
}
