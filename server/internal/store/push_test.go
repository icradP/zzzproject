package store

import "testing"

func TestPushSubscriptionCRUD(t *testing.T) {
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

			subscription := &PushSubscription{
				UserID:   "alice",
				Endpoint: "https://push.example.test/device",
				P256DH:   "first-key",
				Auth:     "auth-key",
			}
			if err := database.UpsertPushSubscription(subscription); err != nil {
				t.Fatal(err)
			}
			subscription.P256DH = "updated-key"
			if err := database.UpsertPushSubscription(subscription); err != nil {
				t.Fatal(err)
			}

			stored, err := database.GetPushSubscriptions("alice")
			if err != nil {
				t.Fatal(err)
			}
			if len(stored) != 1 || stored[0].P256DH != "updated-key" {
				t.Fatalf("unexpected subscriptions: %#v", stored)
			}

			if err := database.DeletePushSubscription("alice", subscription.Endpoint); err != nil {
				t.Fatal(err)
			}
			stored, err = database.GetPushSubscriptions("alice")
			if err != nil {
				t.Fatal(err)
			}
			if len(stored) != 0 {
				t.Fatalf("subscription was not deleted: %#v", stored)
			}
		})
	}
}
