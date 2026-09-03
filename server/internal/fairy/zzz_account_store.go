package fairy

import (
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/url"
	"os"
	"path/filepath"
	"time"

	_ "github.com/mattn/go-sqlite3"
)

const zzzCredentialKeyBytes = 32

var ErrZZZAccountNotBound = errors.New("Fairy ZZZ account is not bound")

type zzzAccountCredential struct {
	OwnerID      string
	MYSAccountID string
	UID          string
	Cookie       string
	SToken       string
	MID          string
	UpdatedAt    time.Time
	GachaSynced  time.Time
}

type ZZZAccountSummary struct {
	Bound        bool      `json:"bound"`
	MYSAccountID string    `json:"mys_account_id,omitempty"`
	UID          string    `json:"uid,omitempty"`
	State        string    `json:"state,omitempty"`
	UpdatedAt    time.Time `json:"updated_at,omitempty"`
	GachaSynced  time.Time `json:"gacha_synced_at,omitempty"`
}

type ZZZAccountStoreStats struct {
	BoundAccounts int `json:"bound_accounts"`
	ValidAccounts int `json:"valid_accounts"`
	CachedRecords int `json:"cached_gacha_records"`
}

type zzzGachaRecord struct {
	RecordID string
	Pool     string
	ItemID   string
	Name     string
	ItemType string
	RankType string
	Time     string
}

type ZZZGachaPoolSummary struct {
	Pool       string `json:"pool"`
	Total      int    `json:"total"`
	SRank      int    `json:"s_rank"`
	SinceSRank int    `json:"since_s_rank"`
}

type ZZZGachaSummary struct {
	UID        string                `json:"uid"`
	Total      int                   `json:"total"`
	SRank      int                   `json:"s_rank"`
	SyncedAt   time.Time             `json:"synced_at,omitempty"`
	PoolCounts []ZZZGachaPoolSummary `json:"pools"`
}

type zzzStoredSToken struct {
	Token string `json:"token"`
	MID   string `json:"mid"`
}

type ZZZAccountStore struct {
	db   *sql.DB
	aead cipher.AEAD
}

func OpenZZZAccountStore(databasePath, keyPath string) (*ZZZAccountStore, error) {
	if err := ensurePrivateDirectory(filepath.Dir(databasePath)); err != nil {
		return nil, fmt.Errorf("prepare Fairy ZZZ account database directory: %w", err)
	}
	if err := ensurePrivateDirectory(filepath.Dir(keyPath)); err != nil {
		return nil, fmt.Errorf("prepare Fairy ZZZ credential key directory: %w", err)
	}
	key, err := loadOrCreateZZZCredentialKey(keyPath)
	if err != nil {
		return nil, err
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, fmt.Errorf("initialize Fairy ZZZ credential cipher: %w", err)
	}
	aead, err := cipher.NewGCM(block)
	if err != nil {
		return nil, fmt.Errorf("initialize Fairy ZZZ credential AEAD: %w", err)
	}
	absolutePath, err := filepath.Abs(databasePath)
	if err != nil {
		return nil, fmt.Errorf("resolve Fairy ZZZ account database path: %w", err)
	}
	databaseFile, err := os.OpenFile(absolutePath, os.O_RDWR|os.O_CREATE, 0o600)
	if err != nil {
		return nil, fmt.Errorf("create Fairy ZZZ account database: %w", err)
	}
	if err := databaseFile.Chmod(0o600); err != nil {
		_ = databaseFile.Close()
		return nil, fmt.Errorf("secure Fairy ZZZ account database: %w", err)
	}
	if err := databaseFile.Close(); err != nil {
		return nil, fmt.Errorf("close Fairy ZZZ account database: %w", err)
	}
	dsn := (&url.URL{Scheme: "file", Path: absolutePath, RawQuery: "_busy_timeout=5000&_foreign_keys=on&_journal_mode=WAL"}).String()
	database, err := sql.Open("sqlite3", dsn)
	if err != nil {
		return nil, fmt.Errorf("open Fairy ZZZ account database: %w", err)
	}
	database.SetMaxOpenConns(1)
	store := &ZZZAccountStore{db: database, aead: aead}
	if err := store.initialize(context.Background()); err != nil {
		_ = database.Close()
		return nil, err
	}
	return store, nil
}

func loadOrCreateZZZCredentialKey(path string) ([]byte, error) {
	key, err := os.ReadFile(path)
	if err == nil {
		if len(key) != zzzCredentialKeyBytes {
			return nil, fmt.Errorf("Fairy ZZZ credential key must contain exactly %d bytes", zzzCredentialKeyBytes)
		}
		if err := os.Chmod(path, 0o600); err != nil {
			return nil, fmt.Errorf("secure Fairy ZZZ credential key: %w", err)
		}
		return key, nil
	}
	if !errors.Is(err, os.ErrNotExist) {
		return nil, fmt.Errorf("read Fairy ZZZ credential key: %w", err)
	}
	key = make([]byte, zzzCredentialKeyBytes)
	if _, err := io.ReadFull(rand.Reader, key); err != nil {
		return nil, fmt.Errorf("generate Fairy ZZZ credential key: %w", err)
	}
	file, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return nil, fmt.Errorf("create Fairy ZZZ credential key: %w", err)
	}
	if _, err := file.Write(key); err != nil {
		_ = file.Close()
		return nil, fmt.Errorf("write Fairy ZZZ credential key: %w", err)
	}
	if err := file.Close(); err != nil {
		return nil, fmt.Errorf("close Fairy ZZZ credential key: %w", err)
	}
	return key, nil
}

func (s *ZZZAccountStore) initialize(ctx context.Context) error {
	const schema = `
CREATE TABLE IF NOT EXISTS zzz_accounts (
    owner_id TEXT PRIMARY KEY,
    mys_account_id TEXT NOT NULL,
    uid TEXT NOT NULL,
    cookie_cipher BLOB NOT NULL,
    stoken_cipher BLOB NOT NULL,
    credential_state TEXT NOT NULL DEFAULT 'valid',
    updated_at INTEGER NOT NULL,
    gacha_synced_at INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS zzz_gacha_records (
    owner_id TEXT NOT NULL,
    uid TEXT NOT NULL,
    record_id TEXT NOT NULL,
    pool TEXT NOT NULL,
    item_id TEXT NOT NULL,
    item_name TEXT NOT NULL,
    item_type TEXT NOT NULL,
    rank_type TEXT NOT NULL,
    occurred_at TEXT NOT NULL,
    PRIMARY KEY (owner_id, uid, record_id),
    FOREIGN KEY (owner_id) REFERENCES zzz_accounts(owner_id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_zzz_gacha_owner_pool
    ON zzz_gacha_records(owner_id, uid, pool, record_id DESC);`
	if _, err := s.db.ExecContext(ctx, schema); err != nil {
		return fmt.Errorf("initialize Fairy ZZZ account database: %w", err)
	}
	return nil
}

func (s *ZZZAccountStore) PutAccount(ctx context.Context, account zzzAccountCredential) error {
	if account.OwnerID == "" || account.MYSAccountID == "" || account.UID == "" || account.Cookie == "" || account.SToken == "" {
		return errors.New("incomplete Fairy ZZZ account credential")
	}
	stoken, err := json.Marshal(zzzStoredSToken{Token: account.SToken, MID: account.MID})
	if err != nil {
		return fmt.Errorf("encode Fairy ZZZ stoken metadata: %w", err)
	}
	cookieCipher, err := s.encrypt(account.OwnerID, "cookie", []byte(account.Cookie))
	if err != nil {
		return err
	}
	stokenCipher, err := s.encrypt(account.OwnerID, "stoken", stoken)
	if err != nil {
		return err
	}
	updatedAt := account.UpdatedAt
	if updatedAt.IsZero() {
		updatedAt = time.Now()
	}
	transaction, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("begin Fairy ZZZ account write: %w", err)
	}
	defer transaction.Rollback()
	if _, err := transaction.ExecContext(ctx, `DELETE FROM zzz_gacha_records WHERE owner_id = ? AND uid <> ?`, account.OwnerID, account.UID); err != nil {
		return fmt.Errorf("remove stale Fairy ZZZ gacha cache: %w", err)
	}
	_, err = transaction.ExecContext(ctx, `
INSERT INTO zzz_accounts(owner_id, mys_account_id, uid, cookie_cipher, stoken_cipher, credential_state, updated_at)
VALUES(?, ?, ?, ?, ?, 'valid', ?)
ON CONFLICT(owner_id) DO UPDATE SET
    mys_account_id=excluded.mys_account_id,
    uid=excluded.uid,
    cookie_cipher=excluded.cookie_cipher,
    stoken_cipher=excluded.stoken_cipher,
    credential_state='valid',
	updated_at=excluded.updated_at,
	gacha_synced_at=CASE WHEN zzz_accounts.uid = excluded.uid THEN zzz_accounts.gacha_synced_at ELSE 0 END`,
		account.OwnerID, account.MYSAccountID, account.UID, cookieCipher, stokenCipher, updatedAt.UTC().UnixMilli())
	if err != nil {
		return fmt.Errorf("store Fairy ZZZ account: %w", err)
	}
	if err := transaction.Commit(); err != nil {
		return fmt.Errorf("commit Fairy ZZZ account write: %w", err)
	}
	return nil
}

func (s *ZZZAccountStore) Account(ctx context.Context, ownerID string) (zzzAccountCredential, error) {
	var account zzzAccountCredential
	var cookieCipher, stokenCipher []byte
	var updatedAt, syncedAt int64
	err := s.db.QueryRowContext(ctx, `
SELECT mys_account_id, uid, cookie_cipher, stoken_cipher, updated_at, gacha_synced_at
FROM zzz_accounts WHERE owner_id = ?`, ownerID).Scan(
		&account.MYSAccountID, &account.UID, &cookieCipher, &stokenCipher, &updatedAt, &syncedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return zzzAccountCredential{}, ErrZZZAccountNotBound
	}
	if err != nil {
		return zzzAccountCredential{}, fmt.Errorf("read Fairy ZZZ account: %w", err)
	}
	cookie, err := s.decrypt(ownerID, "cookie", cookieCipher)
	if err != nil {
		return zzzAccountCredential{}, err
	}
	stokenJSON, err := s.decrypt(ownerID, "stoken", stokenCipher)
	if err != nil {
		return zzzAccountCredential{}, err
	}
	var stoken zzzStoredSToken
	if err := json.Unmarshal(stokenJSON, &stoken); err != nil || stoken.Token == "" {
		return zzzAccountCredential{}, errors.New("decode Fairy ZZZ encrypted credential")
	}
	account.OwnerID = ownerID
	account.Cookie = string(cookie)
	account.SToken = stoken.Token
	account.MID = stoken.MID
	account.UpdatedAt = time.UnixMilli(updatedAt).UTC()
	if syncedAt > 0 {
		account.GachaSynced = time.UnixMilli(syncedAt).UTC()
	}
	return account, nil
}

func (s *ZZZAccountStore) Summary(ctx context.Context, ownerID string) (ZZZAccountSummary, error) {
	var summary ZZZAccountSummary
	var updatedAt, syncedAt int64
	err := s.db.QueryRowContext(ctx, `
SELECT mys_account_id, uid, credential_state, updated_at, gacha_synced_at
FROM zzz_accounts WHERE owner_id = ?`, ownerID).Scan(
		&summary.MYSAccountID, &summary.UID, &summary.State, &updatedAt, &syncedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return ZZZAccountSummary{}, nil
	}
	if err != nil {
		return ZZZAccountSummary{}, fmt.Errorf("read Fairy ZZZ account summary: %w", err)
	}
	summary.Bound = true
	summary.UpdatedAt = time.UnixMilli(updatedAt).UTC()
	if syncedAt > 0 {
		summary.GachaSynced = time.UnixMilli(syncedAt).UTC()
	}
	return summary, nil
}

func (s *ZZZAccountStore) MarkInvalid(ctx context.Context, ownerID string) error {
	_, err := s.db.ExecContext(ctx, `UPDATE zzz_accounts SET credential_state = 'invalid' WHERE owner_id = ?`, ownerID)
	if err != nil {
		return fmt.Errorf("mark Fairy ZZZ account invalid: %w", err)
	}
	return nil
}

func (s *ZZZAccountStore) DeleteAccount(ctx context.Context, ownerID string) error {
	transaction, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("begin Fairy ZZZ account deletion: %w", err)
	}
	defer transaction.Rollback()
	if _, err := transaction.ExecContext(ctx, `DELETE FROM zzz_gacha_records WHERE owner_id = ?`, ownerID); err != nil {
		return fmt.Errorf("delete Fairy ZZZ gacha cache: %w", err)
	}
	if _, err := transaction.ExecContext(ctx, `DELETE FROM zzz_accounts WHERE owner_id = ?`, ownerID); err != nil {
		return fmt.Errorf("delete Fairy ZZZ account: %w", err)
	}
	if err := transaction.Commit(); err != nil {
		return fmt.Errorf("commit Fairy ZZZ account deletion: %w", err)
	}
	return nil
}

func (s *ZZZAccountStore) AddGachaRecords(ctx context.Context, ownerID, uid string, records []zzzGachaRecord) (int, error) {
	transaction, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return 0, fmt.Errorf("begin Fairy ZZZ gacha cache write: %w", err)
	}
	defer transaction.Rollback()
	added := 0
	for _, record := range records {
		result, err := transaction.ExecContext(ctx, `
INSERT OR IGNORE INTO zzz_gacha_records(
    owner_id, uid, record_id, pool, item_id, item_name, item_type, rank_type, occurred_at
) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?)`, ownerID, uid, record.RecordID, record.Pool,
			record.ItemID, record.Name, record.ItemType, record.RankType, record.Time)
		if err != nil {
			return 0, fmt.Errorf("cache Fairy ZZZ gacha record: %w", err)
		}
		rows, err := result.RowsAffected()
		if err == nil {
			added += int(rows)
		}
	}
	if err := transaction.Commit(); err != nil {
		return 0, fmt.Errorf("commit Fairy ZZZ gacha cache write: %w", err)
	}
	return added, nil
}

func (s *ZZZAccountStore) MarkGachaSynced(ctx context.Context, ownerID string, at time.Time) error {
	_, err := s.db.ExecContext(ctx, `UPDATE zzz_accounts SET gacha_synced_at = ? WHERE owner_id = ?`, at.UTC().UnixMilli(), ownerID)
	if err != nil {
		return fmt.Errorf("mark Fairy ZZZ gacha sync: %w", err)
	}
	return nil
}

func (s *ZZZAccountStore) GachaSummary(ctx context.Context, ownerID string) (ZZZGachaSummary, error) {
	account, err := s.Summary(ctx, ownerID)
	if err != nil {
		return ZZZGachaSummary{}, err
	}
	if !account.Bound {
		return ZZZGachaSummary{}, ErrZZZAccountNotBound
	}
	rows, err := s.db.QueryContext(ctx, `
SELECT pool, record_id, rank_type
FROM zzz_gacha_records
WHERE owner_id = ? AND uid = ?
ORDER BY pool, length(record_id) DESC, record_id DESC`, ownerID, account.UID)
	if err != nil {
		return ZZZGachaSummary{}, fmt.Errorf("read Fairy ZZZ gacha cache: %w", err)
	}
	defer rows.Close()
	poolOrder := make([]string, 0)
	pools := make(map[string]*ZZZGachaPoolSummary)
	seenS := make(map[string]bool)
	summary := ZZZGachaSummary{UID: account.UID, SyncedAt: account.GachaSynced}
	for rows.Next() {
		var pool, recordID, rankType string
		if err := rows.Scan(&pool, &recordID, &rankType); err != nil {
			return ZZZGachaSummary{}, fmt.Errorf("scan Fairy ZZZ gacha cache: %w", err)
		}
		item := pools[pool]
		if item == nil {
			item = &ZZZGachaPoolSummary{Pool: pool}
			pools[pool] = item
			poolOrder = append(poolOrder, pool)
		}
		item.Total++
		summary.Total++
		if rankType == "4" {
			item.SRank++
			summary.SRank++
			seenS[pool] = true
		} else if !seenS[pool] {
			item.SinceSRank++
		}
	}
	if err := rows.Err(); err != nil {
		return ZZZGachaSummary{}, fmt.Errorf("iterate Fairy ZZZ gacha cache: %w", err)
	}
	for _, pool := range poolOrder {
		summary.PoolCounts = append(summary.PoolCounts, *pools[pool])
	}
	return summary, nil
}

func (s *ZZZAccountStore) Stats(ctx context.Context) (ZZZAccountStoreStats, error) {
	var stats ZZZAccountStoreStats
	if err := s.db.QueryRowContext(ctx, `
SELECT COUNT(*), COALESCE(SUM(CASE WHEN credential_state = 'valid' THEN 1 ELSE 0 END), 0)
FROM zzz_accounts`).Scan(&stats.BoundAccounts, &stats.ValidAccounts); err != nil {
		return ZZZAccountStoreStats{}, fmt.Errorf("read Fairy ZZZ account stats: %w", err)
	}
	if err := s.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM zzz_gacha_records`).Scan(&stats.CachedRecords); err != nil {
		return ZZZAccountStoreStats{}, fmt.Errorf("read Fairy ZZZ gacha stats: %w", err)
	}
	return stats, nil
}

func (s *ZZZAccountStore) encrypt(ownerID, kind string, plaintext []byte) ([]byte, error) {
	nonce := make([]byte, s.aead.NonceSize())
	if _, err := io.ReadFull(rand.Reader, nonce); err != nil {
		return nil, fmt.Errorf("generate Fairy ZZZ credential nonce: %w", err)
	}
	return s.aead.Seal(nonce, nonce, plaintext, zzzCredentialAAD(ownerID, kind)), nil
}

func (s *ZZZAccountStore) decrypt(ownerID, kind string, ciphertext []byte) ([]byte, error) {
	if len(ciphertext) < s.aead.NonceSize() {
		return nil, errors.New("invalid Fairy ZZZ encrypted credential")
	}
	nonce := ciphertext[:s.aead.NonceSize()]
	plaintext, err := s.aead.Open(nil, nonce, ciphertext[s.aead.NonceSize():], zzzCredentialAAD(ownerID, kind))
	if err != nil {
		return nil, errors.New("authenticate Fairy ZZZ encrypted credential")
	}
	return plaintext, nil
}

func zzzCredentialAAD(ownerID, kind string) []byte {
	return []byte("fairy-zzz-account\x00" + ownerID + "\x00" + kind)
}

func (s *ZZZAccountStore) Close() error {
	if s == nil || s.db == nil {
		return nil
	}
	return s.db.Close()
}
