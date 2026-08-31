package store

import (
	"database/sql"
	"time"
)

// ---- Memory account session operations ----

func (s *MemoryStore) UpsertSession(session *Session) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	copy := *session
	if copy.CreatedAt.IsZero() {
		copy.CreatedAt = time.Now()
	}
	s.sessions[session.TokenHash] = &copy
	return nil
}

func (s *MemoryStore) GetSession(tokenHash string) (*Session, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	session := s.sessions[tokenHash]
	if session == nil {
		return nil, nil
	}
	copy := *session
	return &copy, nil
}

func (s *MemoryStore) DeleteSession(tokenHash string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.sessions, tokenHash)
	return nil
}

// ---- SQLite account session operations ----

func (s *SQLiteStore) UpsertSession(session *Session) error {
	_, err := s.db.Exec(`
		INSERT INTO sessions (token_hash, user_id, expires_at)
		VALUES (?, ?, ?)
		ON CONFLICT(token_hash) DO UPDATE SET
			user_id = excluded.user_id,
			expires_at = excluded.expires_at`,
		session.TokenHash, session.UserID, session.ExpiresAt,
	)
	return err
}

func (s *SQLiteStore) GetSession(tokenHash string) (*Session, error) {
	session := &Session{}
	err := s.db.QueryRow(`
		SELECT token_hash, user_id, expires_at, created_at
		FROM sessions WHERE token_hash = ?`, tokenHash,
	).Scan(
		&session.TokenHash,
		&session.UserID,
		&session.ExpiresAt,
		&session.CreatedAt,
	)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return session, nil
}

func (s *SQLiteStore) DeleteSession(tokenHash string) error {
	_, err := s.db.Exec("DELETE FROM sessions WHERE token_hash = ?", tokenHash)
	return err
}

// ---- PostgreSQL account session operations ----

func (s *PostgresStore) UpsertSession(session *Session) error {
	_, err := s.db.Exec(`
		INSERT INTO sessions (token_hash, user_id, expires_at)
		VALUES ($1, $2, $3)
		ON CONFLICT(token_hash) DO UPDATE SET
			user_id = EXCLUDED.user_id,
			expires_at = EXCLUDED.expires_at`,
		session.TokenHash, session.UserID, session.ExpiresAt,
	)
	return err
}

func (s *PostgresStore) GetSession(tokenHash string) (*Session, error) {
	session := &Session{}
	err := s.db.QueryRow(`
		SELECT token_hash, user_id, expires_at, created_at
		FROM sessions WHERE token_hash = $1`, tokenHash,
	).Scan(
		&session.TokenHash,
		&session.UserID,
		&session.ExpiresAt,
		&session.CreatedAt,
	)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return session, nil
}

func (s *PostgresStore) DeleteSession(tokenHash string) error {
	_, err := s.db.Exec("DELETE FROM sessions WHERE token_hash = $1", tokenHash)
	return err
}
