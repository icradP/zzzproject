package store

import (
	"database/sql"
	"path/filepath"
	"testing"
	"time"

	_ "github.com/mattn/go-sqlite3"
)

func TestGroupGovernanceStoreContract(t *testing.T) {
	factories := map[string]func(*testing.T) Store{
		"memory": func(t *testing.T) Store {
			return NewMemoryStore()
		},
		"sqlite": func(t *testing.T) Store {
			database, err := NewSQLiteStore(filepath.Join(t.TempDir(), "groups.db"))
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
			group, err := database.CreateGroup("group_test", "Original", "", "owner")
			if err != nil || group == nil {
				t.Fatalf("create group: group=%#v err=%v", group, err)
			}
			if added, err := database.AddGroupMember(group.ID, "member"); err != nil || !added {
				t.Fatalf("add member: added=%v err=%v", added, err)
			}
			if err := database.UpdateGroup(group.ID, "Renamed", "/avatar.png", "Announcement", true); err != nil {
				t.Fatal(err)
			}
			if err := database.SetGroupMemberRole(group.ID, "member", "admin"); err != nil {
				t.Fatal(err)
			}
			mutedUntil := time.Now().Add(time.Hour).Truncate(time.Second)
			if err := database.SetGroupMemberMute(group.ID, "member", mutedUntil); err != nil {
				t.Fatal(err)
			}
			loaded, err := database.GetGroup(group.ID)
			if err != nil || loaded == nil {
				t.Fatalf("load group: group=%#v err=%v", loaded, err)
			}
			if loaded.Name != "Renamed" || loaded.Avatar != "/avatar.png" || loaded.Announcement != "Announcement" || !loaded.MuteAll {
				t.Fatalf("group settings were not persisted: %#v", loaded)
			}
			member := groupMemberForStoreTest(t, loaded, "member")
			if member.Role != "admin" || member.MutedUntil.Unix() != mutedUntil.Unix() {
				t.Fatalf("member governance was not persisted: %#v", member)
			}
			if err := database.TransferGroupOwnership(group.ID, "owner", "member"); err != nil {
				t.Fatal(err)
			}
			transferred, err := database.GetGroup(group.ID)
			if err != nil || transferred == nil || transferred.OwnerID != "member" {
				t.Fatalf("ownership was not transferred: %#v err=%v", transferred, err)
			}
			if groupMemberForStoreTest(t, transferred, "owner").Role != "member" ||
				groupMemberForStoreTest(t, transferred, "member").Role != "owner" ||
				!groupMemberForStoreTest(t, transferred, "member").MutedUntil.IsZero() {
				t.Fatalf("ownership roles are inconsistent: %#v", transferred.Members)
			}
			if err := database.DeleteGroup(group.ID); err != nil {
				t.Fatal(err)
			}
			deleted, err := database.GetGroup(group.ID)
			if err != nil || deleted != nil {
				t.Fatalf("deleted group is still available: %#v err=%v", deleted, err)
			}
		})
	}
}

func TestSQLiteMigratesExistingGroupGovernanceSchema(t *testing.T) {
	path := filepath.Join(t.TempDir(), "legacy.db")
	legacy, err := sql.Open("sqlite3", path)
	if err != nil {
		t.Fatal(err)
	}
	for _, statement := range []string{
		`CREATE TABLE groups (
			id TEXT PRIMARY KEY, name TEXT NOT NULL, avatar_url TEXT DEFAULT '',
			owner_id TEXT NOT NULL, created_at DATETIME DEFAULT CURRENT_TIMESTAMP
		)`,
		`CREATE TABLE group_members (
			group_id TEXT NOT NULL, user_id TEXT NOT NULL, role TEXT DEFAULT 'member',
			joined_at DATETIME DEFAULT CURRENT_TIMESTAMP,
			PRIMARY KEY (group_id, user_id)
		)`,
	} {
		if _, err := legacy.Exec(statement); err != nil {
			t.Fatal(err)
		}
	}
	if err := legacy.Close(); err != nil {
		t.Fatal(err)
	}

	database, err := NewSQLiteStore(path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = database.Close() })
	group, err := database.CreateGroup("group_legacy", "Legacy", "", "owner")
	if err != nil {
		t.Fatal(err)
	}
	if added, err := database.AddGroupMember(group.ID, "member"); err != nil || !added {
		t.Fatalf("add member after migration: added=%v err=%v", added, err)
	}
	if err := database.UpdateGroup(group.ID, "Migrated", "", "Now supported", true); err != nil {
		t.Fatal(err)
	}
	if err := database.SetGroupMemberMute(group.ID, "member", time.Now().Add(time.Minute)); err != nil {
		t.Fatal(err)
	}
	loaded, err := database.GetGroup(group.ID)
	if err != nil || loaded == nil || loaded.Announcement != "Now supported" || !loaded.MuteAll ||
		!groupMemberForStoreTest(t, loaded, "member").MutedUntil.After(time.Now()) {
		t.Fatalf("legacy migration did not enable governance fields: %#v err=%v", loaded, err)
	}
}

func groupMemberForStoreTest(t *testing.T, group *Group, userID string) *GroupMember {
	t.Helper()
	for _, member := range group.Members {
		if member.UserID == userID {
			return member
		}
	}
	t.Fatalf("member %s not found", userID)
	return nil
}
