package store

import (
	"database/sql"
	"errors"
	"path/filepath"
	"testing"
	"time"

	_ "github.com/mattn/go-sqlite3"
)

func TestProfileCardStoreContract(t *testing.T) {
	factories := map[string]func(*testing.T) Store{
		"memory": func(*testing.T) Store { return NewMemoryStore() },
		"sqlite": func(t *testing.T) Store {
			database, err := NewSQLiteStore(filepath.Join(t.TempDir(), "profiles.db"))
			if err != nil {
				t.Fatal(err)
			}
			return database
		},
	}
	for name, factory := range factories {
		t.Run(name, func(t *testing.T) {
			database := factory(t)
			t.Cleanup(func() { _ = database.Close() })
			user := &User{
				ID: "alice", Nickname: "Alice", Bio: "Hollows investigator",
				CardBackgroundURL:       "https://images.example/alice.webp",
				CardBackgroundColor:     "#123ABC",
				CardBackgroundSensitive: true, ShowMutualGroups: true,
				ShowAccountID: true,
			}
			if err := database.SetUser(user); err != nil {
				t.Fatal(err)
			}
			loaded, err := database.GetUser(user.ID)
			if err != nil || loaded == nil || loaded.Bio != user.Bio ||
				loaded.CardBackgroundURL != user.CardBackgroundURL ||
				loaded.CardBackgroundColor != user.CardBackgroundColor ||
				!loaded.CardBackgroundSensitive || !loaded.ShowMutualGroups ||
				!loaded.ShowAccountID {
				t.Fatalf("profile fields were not persisted: user=%#v err=%v", loaded, err)
			}

			now := time.Now()
			expires := now.Add(time.Hour)
			for _, title := range []*UserTitle{
				{ID: "system", UserID: user.ID, ScopeType: "system", Text: "Founder", Style: "gold", GrantedBy: "admin", CreatedAt: now},
				{ID: "group", UserID: user.ID, ScopeType: "group", ScopeID: "group_one", Text: "Proxy", Style: "aurora", GrantedBy: "owner", ExpiresAt: &expires, CreatedAt: now},
				{ID: "expired", UserID: user.ID, ScopeType: "system", Text: "Old", Style: "red", GrantedBy: "admin", ExpiresAt: pointerTime(now.Add(-time.Hour)), CreatedAt: now},
			} {
				if err := database.GrantUserTitle(title); err != nil {
					t.Fatal(err)
				}
			}
			systemTitles, err := database.GetUserTitles(user.ID, "")
			if err != nil || len(systemTitles) != 1 || systemTitles[0].ID != "system" {
				t.Fatalf("system titles=%#v err=%v", systemTitles, err)
			}
			groupTitles, err := database.GetUserTitles(user.ID, "group_one")
			if err != nil || len(groupTitles) != 2 {
				t.Fatalf("group context titles=%#v err=%v", groupTitles, err)
			}
			if deleted, err := database.DeleteUserTitle("group"); err != nil || !deleted {
				t.Fatalf("delete title=%v err=%v", deleted, err)
			}
			for index := 0; index < 4; index++ {
				if err := database.GrantUserTitle(&UserTitle{
					ID: "limit-" + string(rune('a'+index)), UserID: user.ID,
					ScopeType: "group", ScopeID: "group_two", Text: "Title",
					Style: "yellow", GrantedBy: "owner", CreatedAt: now,
				}); err != nil {
					t.Fatalf("grant title %d: %v", index, err)
				}
			}
			if err := database.GrantUserTitle(&UserTitle{
				ID: "over-limit", UserID: user.ID, ScopeType: "system",
				Text: "Too many", Style: "red", GrantedBy: "admin", CreatedAt: now,
			}); !errors.Is(err, ErrActiveTitleLimit) {
				t.Fatalf("sixth active title error=%v", err)
			}

			if err := database.SetUserBlocked("alice", "bob", true); err != nil {
				t.Fatal(err)
			}
			if blocked, err := database.IsUserBlocked("alice", "bob"); err != nil || !blocked {
				t.Fatalf("block state=%v err=%v", blocked, err)
			}
			if err := database.SetUserBlocked("alice", "bob", false); err != nil {
				t.Fatal(err)
			}
			if blocked, err := database.IsUserBlocked("alice", "bob"); err != nil || blocked {
				t.Fatalf("unblock state=%v err=%v", blocked, err)
			}

			report := &UserReport{ID: "report_one", ReporterID: "alice", TargetID: "bob", Reason: "spam", Details: "Repeated links", CreatedAt: now}
			if err := database.CreateUserReport(report); err != nil {
				t.Fatal(err)
			}
			reports, err := database.GetUserReports(10)
			if err != nil || len(reports) != 1 || reports[0].Details != report.Details {
				t.Fatalf("reports=%#v err=%v", reports, err)
			}
		})
	}
}

func TestSQLiteMigratesLegacyUserProfileColumns(t *testing.T) {
	path := filepath.Join(t.TempDir(), "legacy-profile.db")
	legacy, err := sql.Open("sqlite3", path)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := legacy.Exec(`CREATE TABLE users (
		id TEXT PRIMARY KEY, nickname TEXT NOT NULL, avatar_url TEXT DEFAULT '',
		password_hash TEXT DEFAULT '', online BOOLEAN DEFAULT FALSE,
		created_at DATETIME DEFAULT CURRENT_TIMESTAMP
	)`); err != nil {
		t.Fatal(err)
	}
	if _, err := legacy.Exec("INSERT INTO users (id, nickname) VALUES ('legacy', 'Legacy')"); err != nil {
		t.Fatal(err)
	}
	if err := legacy.Close(); err != nil {
		t.Fatal(err)
	}

	database, err := NewSQLiteStore(path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = database.Close() })
	user, err := database.GetUser("legacy")
	if err != nil || user == nil || !user.ShowMutualGroups || !user.ShowAccountID {
		t.Fatalf("legacy profile defaults were not migrated: user=%#v err=%v", user, err)
	}
}

func pointerTime(value time.Time) *time.Time { return &value }
