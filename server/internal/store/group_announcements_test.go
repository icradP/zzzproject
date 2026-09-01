package store

import (
	"path/filepath"
	"testing"
)

func TestGroupAnnouncementStoreContract(t *testing.T) {
	factories := map[string]func(*testing.T) Store{
		"memory": func(t *testing.T) Store { return NewMemoryStore() },
		"sqlite": func(t *testing.T) Store {
			database, err := NewSQLiteStore(filepath.Join(t.TempDir(), "announcements.db"))
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
			group, err := database.CreateGroup("group_test", "Test", "", "owner")
			if err != nil {
				t.Fatal(err)
			}
			if added, err := database.AddGroupMember(group.ID, "member"); err != nil || !added {
				t.Fatalf("add member: added=%v err=%v", added, err)
			}
			first, err := database.CreateGroupAnnouncement(group.ID, "First", "owner", false)
			if err != nil {
				t.Fatal(err)
			}
			second, err := database.CreateGroupAnnouncement(group.ID, "Pinned", "owner", true)
			if err != nil {
				t.Fatal(err)
			}
			announcements, err := database.GetGroupAnnouncements(group.ID, "member")
			if err != nil || len(announcements) != 2 || announcements[0].ID != second.ID || announcements[0].IsRead {
				t.Fatalf("unexpected announcements: %#v err=%v", announcements, err)
			}
			if err := database.MarkGroupAnnouncementRead(second.ID, "member"); err != nil {
				t.Fatal(err)
			}
			announcements, err = database.GetGroupAnnouncements(group.ID, "member")
			if err != nil || !announcements[0].IsRead {
				t.Fatalf("read state was not persisted: %#v err=%v", announcements, err)
			}
			updated, err := database.UpdateGroupAnnouncement(first.ID, "Updated", true)
			if err != nil || updated == nil || updated.Content != "Updated" || !updated.IsPinned {
				t.Fatalf("announcement was not updated: %#v err=%v", updated, err)
			}
			deleted, err := database.DeleteGroupAnnouncement(second.ID)
			if err != nil || !deleted {
				t.Fatalf("announcement was not deleted: deleted=%v err=%v", deleted, err)
			}
			announcements, err = database.GetGroupAnnouncements(group.ID, "member")
			if err != nil || len(announcements) != 1 || announcements[0].ID != first.ID {
				t.Fatalf("unexpected remaining announcements: %#v err=%v", announcements, err)
			}
		})
	}
}
