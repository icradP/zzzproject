package store

import "testing"

func TestFriendshipCRUD(t *testing.T) {
	tests := []struct {
		name  string
		store func(t *testing.T) Store
	}{
		{name: "memory", store: func(t *testing.T) Store { return NewMemoryStore() }},
		{name: "sqlite", store: func(t *testing.T) Store {
			database, err := NewSQLiteStore(t.TempDir() + "/friends.db")
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
			for _, user := range []*User{
				{ID: "alice", Nickname: "Alice"},
				{ID: "bob", Nickname: "Bob"},
			} {
				if err := database.SetUser(user); err != nil {
					t.Fatal(err)
				}
			}

			added, err := database.AddFriend("alice", "bob")
			if err != nil || !added {
				t.Fatalf("AddFriend() = %v, %v", added, err)
			}
			for _, pair := range [][2]string{{"alice", "bob"}, {"bob", "alice"}} {
				friends, err := database.AreFriends(pair[0], pair[1])
				if err != nil || !friends {
					t.Fatalf("AreFriends(%q, %q) = %v, %v", pair[0], pair[1], friends, err)
				}
			}
			friends, err := database.GetFriends("alice")
			if err != nil || len(friends) != 1 || friends[0].ID != "bob" {
				t.Fatalf("GetFriends(alice) = %#v, %v", friends, err)
			}
			if addedAgain, err := database.AddFriend("alice", "bob"); err != nil || addedAgain {
				t.Fatalf("duplicate AddFriend() = %v, %v", addedAgain, err)
			}

			removed, err := database.RemoveFriend("bob", "alice")
			if err != nil || !removed {
				t.Fatalf("RemoveFriend() = %v, %v", removed, err)
			}
			friends, err = database.GetFriends("alice")
			if err != nil || len(friends) != 0 {
				t.Fatalf("friends remained after removal: %#v, %v", friends, err)
			}
		})
	}
}

func TestPendingFriendRequestsIncludeIncomingAndOutgoing(t *testing.T) {
	database := NewMemoryStore()
	if _, err := database.CreateFriendRequest("alice", "bob", "hello"); err != nil {
		t.Fatal(err)
	}
	for _, userID := range []string{"alice", "bob"} {
		requests, err := database.GetPendingFriendRequests(userID)
		if err != nil || len(requests) != 1 {
			t.Fatalf("GetPendingFriendRequests(%q) = %#v, %v", userID, requests, err)
		}
	}
}
