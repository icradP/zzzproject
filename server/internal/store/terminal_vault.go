package store

import (
	"database/sql"
	"time"
)

func cloneTerminalVault(vault *TerminalVault) *TerminalVault {
	if vault == nil {
		return nil
	}
	copy := *vault
	return &copy
}

func (s *MemoryStore) GetTerminalVault(userID string) (*TerminalVault, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return cloneTerminalVault(s.terminalVaults[userID]), nil
}

func (s *MemoryStore) PutTerminalVault(userID, payload string, expectedRevision int64) (*TerminalVault, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	current := s.terminalVaults[userID]
	currentRevision := int64(0)
	if current != nil {
		currentRevision = current.Revision
	}
	if currentRevision != expectedRevision {
		return cloneTerminalVault(current), ErrTerminalVaultConflict
	}
	vault := &TerminalVault{
		UserID: userID, Payload: payload, Revision: currentRevision + 1, UpdatedAt: time.Now().UTC(),
	}
	s.terminalVaults[userID] = vault
	return cloneTerminalVault(vault), nil
}

func (s *MemoryStore) DeleteTerminalVault(userID string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.terminalVaults, userID)
	return nil
}

func (s *SQLiteStore) GetTerminalVault(userID string) (*TerminalVault, error) {
	vault := &TerminalVault{UserID: userID}
	err := s.db.QueryRow(`SELECT payload, revision, updated_at FROM terminal_vaults WHERE user_id = ?`, userID).
		Scan(&vault.Payload, &vault.Revision, &vault.UpdatedAt)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	return vault, err
}

func (s *SQLiteStore) PutTerminalVault(userID, payload string, expectedRevision int64) (*TerminalVault, error) {
	tx, err := s.db.Begin()
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	var revision int64
	err = tx.QueryRow(`SELECT revision FROM terminal_vaults WHERE user_id = ?`, userID).Scan(&revision)
	if err == sql.ErrNoRows {
		revision = 0
	} else if err != nil {
		return nil, err
	}
	if revision != expectedRevision {
		current := &TerminalVault{UserID: userID}
		if scanErr := tx.QueryRow(`SELECT payload, revision, updated_at FROM terminal_vaults WHERE user_id = ?`, userID).
			Scan(&current.Payload, &current.Revision, &current.UpdatedAt); scanErr == sql.ErrNoRows {
			current = nil
		} else if scanErr != nil {
			return nil, scanErr
		}
		return current, ErrTerminalVaultConflict
	}
	vault := &TerminalVault{UserID: userID, Payload: payload, Revision: revision + 1, UpdatedAt: time.Now().UTC()}
	_, err = tx.Exec(`INSERT INTO terminal_vaults (user_id, payload, revision, updated_at) VALUES (?, ?, ?, ?)
		ON CONFLICT(user_id) DO UPDATE SET payload = excluded.payload, revision = excluded.revision, updated_at = excluded.updated_at`,
		userID, payload, vault.Revision, vault.UpdatedAt)
	if err != nil {
		return nil, err
	}
	if err := tx.Commit(); err != nil {
		return nil, err
	}
	return vault, nil
}

func (s *SQLiteStore) DeleteTerminalVault(userID string) error {
	_, err := s.db.Exec(`DELETE FROM terminal_vaults WHERE user_id = ?`, userID)
	return err
}

func (s *PostgresStore) GetTerminalVault(userID string) (*TerminalVault, error) {
	vault := &TerminalVault{UserID: userID}
	err := s.db.QueryRow(`SELECT payload, revision, updated_at FROM terminal_vaults WHERE user_id = $1`, userID).
		Scan(&vault.Payload, &vault.Revision, &vault.UpdatedAt)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	return vault, err
}

func (s *PostgresStore) PutTerminalVault(userID, payload string, expectedRevision int64) (*TerminalVault, error) {
	// An absent vault has the implicit revision zero. Do not let a non-zero
	// expected revision create a new record through the INSERT branch.
	if expectedRevision != 0 {
		current, err := s.GetTerminalVault(userID)
		if err != nil {
			return nil, err
		}
		if current == nil || current.Revision != expectedRevision {
			return current, ErrTerminalVaultConflict
		}
	}
	vault := &TerminalVault{
		UserID: userID, Payload: payload, Revision: expectedRevision + 1, UpdatedAt: time.Now().UTC(),
	}
	err := s.db.QueryRow(`INSERT INTO terminal_vaults (user_id, payload, revision, updated_at)
		VALUES ($1, $2, $3, $4)
		ON CONFLICT(user_id) DO UPDATE
		SET payload = EXCLUDED.payload, revision = EXCLUDED.revision, updated_at = EXCLUDED.updated_at
		WHERE terminal_vaults.revision = $5
		RETURNING revision, updated_at`,
		userID, payload, vault.Revision, vault.UpdatedAt, expectedRevision).
		Scan(&vault.Revision, &vault.UpdatedAt)
	if err == sql.ErrNoRows {
		current, getErr := s.GetTerminalVault(userID)
		if getErr != nil {
			return nil, getErr
		}
		return current, ErrTerminalVaultConflict
	}
	if err != nil {
		return nil, err
	}
	return vault, nil
}

func (s *PostgresStore) DeleteTerminalVault(userID string) error {
	_, err := s.db.Exec(`DELETE FROM terminal_vaults WHERE user_id = $1`, userID)
	return err
}
