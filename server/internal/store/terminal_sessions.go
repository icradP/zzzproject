package store

import (
	"sort"
	"time"
)

// ---- Memory terminal session audit operations ----

func (s *MemoryStore) UpsertTerminalSession(session *TerminalSession) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	copy := *session
	if copy.LoginAt.IsZero() {
		copy.LoginAt = time.Now()
	}
	if copy.LastSeenAt.IsZero() {
		copy.LastSeenAt = copy.LoginAt
	}
	s.terminalSessions[copy.ID] = &copy
	return nil
}

func (s *MemoryStore) TouchTerminalSession(id string, seenAt time.Time) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if session := s.terminalSessions[id]; session != nil {
		if seenAt.After(session.LastSeenAt) {
			session.LastSeenAt = seenAt
		}
	}
	return nil
}

func (s *MemoryStore) EndTerminalSession(id string, endedAt time.Time) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if session := s.terminalSessions[id]; session != nil {
		session.Connected = false
		if endedAt.IsZero() {
			endedAt = time.Now()
		}
		session.LastSeenAt = endedAt
		session.LogoutAt = &endedAt
	}
	return nil
}

func (s *MemoryStore) GetRecentTerminalSessions(limit int) ([]*TerminalSession, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	if limit <= 0 {
		limit = 200
	}
	result := make([]*TerminalSession, 0, len(s.terminalSessions))
	for _, item := range s.terminalSessions {
		copy := *item
		if item.LogoutAt != nil {
			ended := *item.LogoutAt
			copy.LogoutAt = &ended
		}
		result = append(result, &copy)
	}
	sort.Slice(result, func(i, j int) bool {
		return result[i].LastSeenAt.After(result[j].LastSeenAt)
	})
	if len(result) > limit {
		result = result[:limit]
	}
	return result, nil
}

// ---- SQLite terminal session audit operations ----

func (s *SQLiteStore) UpsertTerminalSession(session *TerminalSession) error {
	_, err := s.db.Exec(`
		INSERT INTO terminal_sessions
			(id, user_id, device_id, client_type, connected, login_at, last_seen_at, logout_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(id) DO UPDATE SET
			connected = excluded.connected,
			last_seen_at = excluded.last_seen_at,
			logout_at = excluded.logout_at`,
		session.ID, session.UserID, session.DeviceID, session.ClientType,
		session.Connected, session.LoginAt, session.LastSeenAt, session.LogoutAt,
	)
	return err
}

func (s *SQLiteStore) TouchTerminalSession(id string, seenAt time.Time) error {
	_, err := s.db.Exec(`
		UPDATE terminal_sessions SET last_seen_at = ?, connected = TRUE
		WHERE id = ? AND last_seen_at < ?`, seenAt, id, seenAt)
	return err
}

func (s *SQLiteStore) EndTerminalSession(id string, endedAt time.Time) error {
	_, err := s.db.Exec(`
		UPDATE terminal_sessions SET connected = FALSE, last_seen_at = ?, logout_at = ?
		WHERE id = ?`, endedAt, endedAt, id)
	return err
}

func (s *SQLiteStore) GetRecentTerminalSessions(limit int) ([]*TerminalSession, error) {
	if limit <= 0 {
		limit = 200
	}
	rows, err := s.db.Query(`
		SELECT id, user_id, device_id, client_type, connected, login_at, last_seen_at, logout_at
		FROM terminal_sessions ORDER BY last_seen_at DESC, id DESC LIMIT ?`, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var result []*TerminalSession
	for rows.Next() {
		item := &TerminalSession{}
		if err := rows.Scan(&item.ID, &item.UserID, &item.DeviceID, &item.ClientType,
			&item.Connected, &item.LoginAt, &item.LastSeenAt, &item.LogoutAt); err != nil {
			return nil, err
		}
		result = append(result, item)
	}
	return result, rows.Err()
}

// ---- PostgreSQL terminal session audit operations ----

func (s *PostgresStore) UpsertTerminalSession(session *TerminalSession) error {
	_, err := s.db.Exec(`
		INSERT INTO terminal_sessions
			(id, user_id, device_id, client_type, connected, login_at, last_seen_at, logout_at)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
		ON CONFLICT(id) DO UPDATE SET
			connected = EXCLUDED.connected,
			last_seen_at = EXCLUDED.last_seen_at,
			logout_at = EXCLUDED.logout_at`,
		session.ID, session.UserID, session.DeviceID, session.ClientType,
		session.Connected, session.LoginAt, session.LastSeenAt, session.LogoutAt,
	)
	return err
}

func (s *PostgresStore) TouchTerminalSession(id string, seenAt time.Time) error {
	_, err := s.db.Exec(`
		UPDATE terminal_sessions SET last_seen_at = $1, connected = TRUE
		WHERE id = $2 AND last_seen_at < $1`, seenAt, id)
	return err
}

func (s *PostgresStore) EndTerminalSession(id string, endedAt time.Time) error {
	_, err := s.db.Exec(`
		UPDATE terminal_sessions SET connected = FALSE, last_seen_at = $1, logout_at = $1
		WHERE id = $2`, endedAt, id)
	return err
}

func (s *PostgresStore) GetRecentTerminalSessions(limit int) ([]*TerminalSession, error) {
	if limit <= 0 {
		limit = 200
	}
	rows, err := s.db.Query(`
		SELECT id, user_id, device_id, client_type, connected, login_at, last_seen_at, logout_at
		FROM terminal_sessions ORDER BY last_seen_at DESC, id DESC LIMIT $1`, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var result []*TerminalSession
	for rows.Next() {
		item := &TerminalSession{}
		if err := rows.Scan(&item.ID, &item.UserID, &item.DeviceID, &item.ClientType,
			&item.Connected, &item.LoginAt, &item.LastSeenAt, &item.LogoutAt); err != nil {
			return nil, err
		}
		result = append(result, item)
	}
	return result, rows.Err()
}
