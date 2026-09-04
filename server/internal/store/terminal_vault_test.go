package store

import (
	"errors"
	"path/filepath"
	"testing"
)

func TestTerminalVaultUsesOptimisticRevision(t *testing.T) {
	tests := []struct {
		name string
		open func(*testing.T) Store
	}{
		{name: "memory", open: func(*testing.T) Store { return NewMemoryStore() }},
		{name: "sqlite", open: func(t *testing.T) Store {
			database, err := NewSQLiteStore(filepath.Join(t.TempDir(), "im.db"))
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
			if current, err := database.PutTerminalVault("alice", "invalid-initial-write", 9); !errors.Is(err, ErrTerminalVaultConflict) || current != nil {
				t.Fatalf("non-zero initial revision = %#v, %v", current, err)
			}
			first, err := database.PutTerminalVault("alice", "encrypted-one", 0)
			if err != nil || first.Revision != 1 {
				t.Fatalf("first write = %#v, %v", first, err)
			}
			if current, err := database.PutTerminalVault("alice", "stale", 0); !errors.Is(err, ErrTerminalVaultConflict) || current == nil || current.Revision != 1 {
				t.Fatalf("stale write error = %v", err)
			}
			second, err := database.PutTerminalVault("alice", "encrypted-two", 1)
			if err != nil || second.Revision != 2 {
				t.Fatalf("second write = %#v, %v", second, err)
			}
			stored, err := database.GetTerminalVault("alice")
			if err != nil || stored.Payload != "encrypted-two" || stored.Revision != 2 {
				t.Fatalf("stored vault = %#v, %v", stored, err)
			}
			if other, err := database.GetTerminalVault("bob"); err != nil || other != nil {
				t.Fatalf("vault leaked across account: %#v, %v", other, err)
			}
		})
	}
}
