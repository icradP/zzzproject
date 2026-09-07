package store

import (
	"testing"
	"time"
)

func TestSessionCRUD(t *testing.T) {
	tests := []struct {
		name  string
		store func(t *testing.T) Store
	}{
		{
			name: "memory",
			store: func(t *testing.T) Store {
				return NewMemoryStore()
			},
		},
		{
			name: "sqlite",
			store: func(t *testing.T) Store {
				database, err := NewSQLiteStore(t.TempDir() + "/store.db")
				if err != nil {
					t.Fatal(err)
				}
				return database
			},
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			database := test.store(t)
			t.Cleanup(func() { _ = database.Close() })
			expiresAt := time.Now().Add(24 * time.Hour).UTC().Truncate(time.Second)
			session := &Session{
				TokenHash: "token-digest",
				UserID:    "alice",
				ExpiresAt: expiresAt,
			}
			if err := database.UpsertSession(session); err != nil {
				t.Fatal(err)
			}

			stored, err := database.GetSession(session.TokenHash)
			if err != nil {
				t.Fatal(err)
			}
			if stored == nil || stored.UserID != session.UserID ||
				stored.ExpiresAt.UTC().Truncate(time.Second) != expiresAt {
				t.Fatalf("unexpected session: %#v", stored)
			}

			if err := database.DeleteSession(session.TokenHash); err != nil {
				t.Fatal(err)
			}
			stored, err = database.GetSession(session.TokenHash)
			if err != nil {
				t.Fatal(err)
			}
			if stored != nil {
				t.Fatalf("session was not deleted: %#v", stored)
			}
		})
	}
}

func TestSQLiteSessionSurvivesReopen(t *testing.T) {
	path := t.TempDir() + "/store.db"
	first, err := NewSQLiteStore(path)
	if err != nil {
		t.Fatal(err)
	}
	session := &Session{
		TokenHash: "persisted-token-digest",
		UserID:    "alice",
		ExpiresAt: time.Now().Add(24 * time.Hour),
	}
	if err := first.UpsertSession(session); err != nil {
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
	stored, err := reopened.GetSession(session.TokenHash)
	if err != nil {
		t.Fatal(err)
	}
	if stored == nil || stored.UserID != session.UserID {
		t.Fatalf("session did not survive reopen: %#v", stored)
	}
}

func TestTerminalSessionAuditLifecycle(t *testing.T) {
	tests := []struct {
		name  string
		store func(t *testing.T) Store
	}{
		{name: "memory", store: func(t *testing.T) Store { return NewMemoryStore() }},
		{name: "sqlite", store: func(t *testing.T) Store {
			database, err := NewSQLiteStore(t.TempDir() + "/store.db")
			if err != nil {
				t.Fatal(err)
			}
			return database
		}},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			database := test.store(t)
			t.Cleanup(func() { _ = database.Close() })
			loginAt := time.Now().Add(-time.Minute).UTC().Truncate(time.Second)
			if err := database.UpsertTerminalSession(&TerminalSession{
				ID: "term-session-1", UserID: "alice", DeviceID: "zzzterm-device",
				ClientType: "desktop", Connected: true, LoginAt: loginAt, LastSeenAt: loginAt,
			}); err != nil {
				t.Fatal(err)
			}
			seenAt := loginAt.Add(30 * time.Second)
			if err := database.TouchTerminalSession("term-session-1", seenAt); err != nil {
				t.Fatal(err)
			}
			items, err := database.GetRecentTerminalSessions(10)
			if err != nil || len(items) != 1 || !items[0].Connected || items[0].DeviceID != "zzzterm-device" {
				t.Fatalf("unexpected active terminal sessions: %#v err=%v", items, err)
			}
			endedAt := seenAt.Add(time.Minute)
			if err := database.EndTerminalSession("term-session-1", endedAt); err != nil {
				t.Fatal(err)
			}
			items, err = database.GetRecentTerminalSessions(10)
			if err != nil || len(items) != 1 || items[0].Connected || items[0].LogoutAt == nil {
				t.Fatalf("unexpected ended terminal session: %#v err=%v", items, err)
			}
		})
	}
}
