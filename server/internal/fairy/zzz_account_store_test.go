package fairy

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestZZZAccountStoreEncryptsCredentialsAndDeletesCache(t *testing.T) {
	directory := t.TempDir()
	databasePath := filepath.Join(directory, "zzz.db")
	keyPath := filepath.Join(directory, "zzz.key")
	store, err := OpenZZZAccountStore(databasePath, keyPath)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()

	for _, path := range []string{databasePath, keyPath} {
		info, err := os.Stat(path)
		if err != nil {
			t.Fatal(err)
		}
		if info.Mode().Perm() != 0o600 {
			t.Fatalf("%s mode = %o, want 600", path, info.Mode().Perm())
		}
	}

	credential := zzzAccountCredential{
		OwnerID: "alice", MYSAccountID: "123456789", UID: "27280531",
		Cookie: "account_id=123456789;cookie_token=cookie-secret-value",
		SToken: "v2_stoken-secret-value", MID: "mid-value",
		UpdatedAt: time.Unix(1_700_000_000, 0),
	}
	if err := store.PutAccount(context.Background(), credential); err != nil {
		t.Fatal(err)
	}

	var cookieCipher, stokenCipher []byte
	if err := store.db.QueryRow(`SELECT cookie_cipher, stoken_cipher FROM zzz_accounts WHERE owner_id = 'alice'`).Scan(&cookieCipher, &stokenCipher); err != nil {
		t.Fatal(err)
	}
	for _, secret := range [][]byte{[]byte(credential.Cookie), []byte(credential.SToken)} {
		if bytes.Contains(cookieCipher, secret) || bytes.Contains(stokenCipher, secret) {
			t.Fatal("credential ciphertext contains plaintext secret")
		}
	}
	if _, err := store.decrypt("bob", "cookie", cookieCipher); err == nil {
		t.Fatal("ciphertext authenticated for the wrong owner")
	}

	loaded, err := store.Account(context.Background(), "alice")
	if err != nil {
		t.Fatal(err)
	}
	if loaded.Cookie != credential.Cookie || loaded.SToken != credential.SToken || loaded.MID != credential.MID || loaded.UID != credential.UID {
		t.Fatalf("loaded credential = %#v", loaded)
	}

	records := []zzzGachaRecord{
		{RecordID: "103", Pool: "独家频段", ItemID: "1", Name: "S", ItemType: "角色", RankType: "4", Time: "2026-01-03 00:00:00"},
		{RecordID: "102", Pool: "独家频段", ItemID: "2", Name: "A", ItemType: "角色", RankType: "3", Time: "2026-01-02 00:00:00"},
		{RecordID: "101", Pool: "独家频段", ItemID: "3", Name: "B", ItemType: "角色", RankType: "3", Time: "2026-01-01 00:00:00"},
	}
	added, err := store.AddGachaRecords(context.Background(), "alice", credential.UID, records)
	if err != nil || added != len(records) {
		t.Fatalf("AddGachaRecords() = %d, %v", added, err)
	}
	if duplicate, err := store.AddGachaRecords(context.Background(), "alice", credential.UID, records); err != nil || duplicate != 0 {
		t.Fatalf("duplicate AddGachaRecords() = %d, %v", duplicate, err)
	}
	syncedAt := time.Unix(1_800_000_000, 0)
	if err := store.MarkGachaSynced(context.Background(), "alice", syncedAt); err != nil {
		t.Fatal(err)
	}
	summary, err := store.GachaSummary(context.Background(), "alice")
	if err != nil {
		t.Fatal(err)
	}
	if summary.Total != 3 || summary.SRank != 1 || len(summary.PoolCounts) != 1 || summary.PoolCounts[0].SinceSRank != 0 {
		t.Fatalf("GachaSummary() = %#v", summary)
	}
	if err := store.PutAccount(context.Background(), zzzAccountCredential{
		OwnerID: "alice", MYSAccountID: "987654321", UID: "12345678",
		Cookie: "replacement-cookie", SToken: "replacement-stoken",
	}); err != nil {
		t.Fatal(err)
	}
	rebound, err := store.GachaSummary(context.Background(), "alice")
	if err != nil {
		t.Fatal(err)
	}
	if rebound.Total != 0 || !rebound.SyncedAt.IsZero() {
		t.Fatalf("rebound GachaSummary() retained stale data: %#v", rebound)
	}

	if err := store.DeleteAccount(context.Background(), "alice"); err != nil {
		t.Fatal(err)
	}
	if _, err := store.Account(context.Background(), "alice"); err != ErrZZZAccountNotBound {
		t.Fatalf("Account() after deletion error = %v", err)
	}
	stats, err := store.Stats(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if stats.BoundAccounts != 0 || stats.CachedRecords != 0 {
		t.Fatalf("Stats() after deletion = %#v", stats)
	}
}

func TestZZZAccountStoreRejectsWrongKey(t *testing.T) {
	directory := t.TempDir()
	keyPath := filepath.Join(directory, "zzz.key")
	if err := os.WriteFile(keyPath, []byte("short"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := OpenZZZAccountStore(filepath.Join(directory, "zzz.db"), keyPath); err == nil {
		t.Fatal("OpenZZZAccountStore() accepted an invalid key")
	}
}
