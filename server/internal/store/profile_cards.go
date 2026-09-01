package store

import (
	"database/sql"
	"errors"
	"sort"
	"time"
)

var ErrActiveTitleLimit = errors.New("a user may have at most five active titles")

func titleIsActive(title *UserTitle, userID string, now time.Time) bool {
	return title != nil && title.UserID == userID &&
		(title.ExpiresAt == nil || title.ExpiresAt.After(now))
}

func titleIsVisible(title *UserTitle, userID, groupID string, now time.Time) bool {
	if !titleIsActive(title, userID, now) {
		return false
	}
	return title.ScopeType == "system" ||
		(title.ScopeType == "group" && groupID != "" && title.ScopeID == groupID)
}

func (s *MemoryStore) GetUserTitles(userID, groupID string) ([]*UserTitle, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	now := time.Now()
	result := make([]*UserTitle, 0)
	for _, title := range s.userTitles {
		if titleIsVisible(title, userID, groupID, now) {
			copy := *title
			result = append(result, &copy)
		}
	}
	sort.Slice(result, func(i, j int) bool { return result[i].CreatedAt.Before(result[j].CreatedAt) })
	return result, nil
}

func (s *MemoryStore) GrantUserTitle(title *UserTitle) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	now := time.Now()
	active := 0
	for _, existing := range s.userTitles {
		if titleIsActive(existing, title.UserID, now) {
			active++
		}
	}
	if active >= 5 {
		return ErrActiveTitleLimit
	}
	copy := *title
	if copy.CreatedAt.IsZero() {
		copy.CreatedAt = now
	}
	s.userTitles[copy.ID] = &copy
	return nil
}

func (s *MemoryStore) DeleteUserTitle(titleID string) (bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.userTitles[titleID]; !ok {
		return false, nil
	}
	delete(s.userTitles, titleID)
	return true, nil
}

func (s *MemoryStore) SetUserBlocked(blockerID, blockedID string, blocked bool) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if !blocked {
		delete(s.userBlocks[blockerID], blockedID)
		return nil
	}
	if s.userBlocks[blockerID] == nil {
		s.userBlocks[blockerID] = make(map[string]time.Time)
	}
	s.userBlocks[blockerID][blockedID] = time.Now()
	return nil
}

func (s *MemoryStore) IsUserBlocked(blockerID, blockedID string) (bool, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	_, blocked := s.userBlocks[blockerID][blockedID]
	return blocked, nil
}

func (s *MemoryStore) CreateUserReport(report *UserReport) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	copy := *report
	if copy.CreatedAt.IsZero() {
		copy.CreatedAt = time.Now()
	}
	s.userReports = append(s.userReports, &copy)
	return nil
}

func (s *MemoryStore) GetUserReports(limit int) ([]*UserReport, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	if limit <= 0 || limit > len(s.userReports) {
		limit = len(s.userReports)
	}
	result := make([]*UserReport, 0, limit)
	for i := len(s.userReports) - 1; i >= 0 && len(result) < limit; i-- {
		copy := *s.userReports[i]
		result = append(result, &copy)
	}
	return result, nil
}

type titleScanner interface {
	Scan(dest ...interface{}) error
}

func scanUserTitle(scanner titleScanner) (*UserTitle, error) {
	title := &UserTitle{}
	var expiresAt sql.NullTime
	if err := scanner.Scan(
		&title.ID, &title.UserID, &title.ScopeType, &title.ScopeID,
		&title.Text, &title.Style, &title.GrantedBy, &expiresAt, &title.CreatedAt,
	); err != nil {
		return nil, err
	}
	if expiresAt.Valid {
		title.ExpiresAt = &expiresAt.Time
	}
	return title, nil
}

func (s *SQLiteStore) GetUserTitles(userID, groupID string) ([]*UserTitle, error) {
	rows, err := s.db.Query(`SELECT id, user_id, scope_type, scope_id, text, style, granted_by, expires_at, created_at
		FROM user_titles WHERE user_id = ?
		AND (scope_type = 'system' OR (scope_type = 'group' AND scope_id = ? AND ? <> ''))
		AND (expires_at IS NULL OR expires_at > ?)
		ORDER BY created_at, id`, userID, groupID, groupID, time.Now())
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	result := make([]*UserTitle, 0)
	for rows.Next() {
		title, err := scanUserTitle(rows)
		if err != nil {
			return nil, err
		}
		result = append(result, title)
	}
	return result, rows.Err()
}

func (s *SQLiteStore) GrantUserTitle(title *UserTitle) error {
	result, err := s.db.Exec(`INSERT INTO user_titles
		(id, user_id, scope_type, scope_id, text, style, granted_by, expires_at, created_at)
		SELECT ?, ?, ?, ?, ?, ?, ?, ?, ?
		WHERE (SELECT COUNT(*) FROM user_titles
			WHERE user_id = ? AND (expires_at IS NULL OR expires_at > ?)) < 5`,
		title.ID, title.UserID, title.ScopeType, title.ScopeID, title.Text, title.Style,
		title.GrantedBy, title.ExpiresAt, title.CreatedAt, title.UserID, time.Now())
	if err != nil {
		return err
	}
	inserted, err := result.RowsAffected()
	if err == nil && inserted == 0 {
		return ErrActiveTitleLimit
	}
	return err
}

func (s *SQLiteStore) DeleteUserTitle(titleID string) (bool, error) {
	result, err := s.db.Exec("DELETE FROM user_titles WHERE id = ?", titleID)
	if err != nil {
		return false, err
	}
	count, err := result.RowsAffected()
	return count > 0, err
}

func (s *SQLiteStore) SetUserBlocked(blockerID, blockedID string, blocked bool) error {
	if !blocked {
		_, err := s.db.Exec("DELETE FROM user_blocks WHERE blocker_id = ? AND blocked_id = ?", blockerID, blockedID)
		return err
	}
	_, err := s.db.Exec(`INSERT INTO user_blocks (blocker_id, blocked_id) VALUES (?, ?)
		ON CONFLICT(blocker_id, blocked_id) DO NOTHING`, blockerID, blockedID)
	return err
}

func (s *SQLiteStore) IsUserBlocked(blockerID, blockedID string) (bool, error) {
	var count int
	err := s.db.QueryRow("SELECT COUNT(*) FROM user_blocks WHERE blocker_id = ? AND blocked_id = ?", blockerID, blockedID).Scan(&count)
	return count > 0, err
}

func (s *SQLiteStore) CreateUserReport(report *UserReport) error {
	_, err := s.db.Exec(`INSERT INTO user_reports
		(id, reporter_id, target_id, reason, details, created_at) VALUES (?, ?, ?, ?, ?, ?)`,
		report.ID, report.ReporterID, report.TargetID, report.Reason, report.Details, report.CreatedAt)
	return err
}

func (s *SQLiteStore) GetUserReports(limit int) ([]*UserReport, error) {
	if limit <= 0 || limit > 500 {
		limit = 500
	}
	rows, err := s.db.Query(`SELECT id, reporter_id, target_id, reason, details, created_at
		FROM user_reports ORDER BY created_at DESC LIMIT ?`, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	result := make([]*UserReport, 0)
	for rows.Next() {
		report := &UserReport{}
		if err := rows.Scan(&report.ID, &report.ReporterID, &report.TargetID, &report.Reason, &report.Details, &report.CreatedAt); err != nil {
			return nil, err
		}
		result = append(result, report)
	}
	return result, rows.Err()
}

func (s *PostgresStore) GetUserTitles(userID, groupID string) ([]*UserTitle, error) {
	rows, err := s.db.Query(`SELECT id, user_id, scope_type, scope_id, text, style, granted_by, expires_at, created_at
		FROM user_titles WHERE user_id = $1
		AND (scope_type = 'system' OR (scope_type = 'group' AND scope_id = $2 AND $2 <> ''))
		AND (expires_at IS NULL OR expires_at > $3)
		ORDER BY created_at, id`, userID, groupID, time.Now())
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	result := make([]*UserTitle, 0)
	for rows.Next() {
		title, err := scanUserTitle(rows)
		if err != nil {
			return nil, err
		}
		result = append(result, title)
	}
	return result, rows.Err()
}

func (s *PostgresStore) GrantUserTitle(title *UserTitle) error {
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err := tx.Exec("SELECT pg_advisory_xact_lock(hashtext($1))", title.UserID); err != nil {
		return err
	}
	var active int
	if err := tx.QueryRow(`SELECT COUNT(*) FROM user_titles
		WHERE user_id = $1 AND (expires_at IS NULL OR expires_at > $2)`,
		title.UserID, time.Now()).Scan(&active); err != nil {
		return err
	}
	if active >= 5 {
		return ErrActiveTitleLimit
	}
	if _, err := tx.Exec(`INSERT INTO user_titles
		(id, user_id, scope_type, scope_id, text, style, granted_by, expires_at, created_at)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)`, title.ID, title.UserID,
		title.ScopeType, title.ScopeID, title.Text, title.Style, title.GrantedBy, title.ExpiresAt, title.CreatedAt); err != nil {
		return err
	}
	return tx.Commit()
}

func (s *PostgresStore) DeleteUserTitle(titleID string) (bool, error) {
	result, err := s.db.Exec("DELETE FROM user_titles WHERE id = $1", titleID)
	if err != nil {
		return false, err
	}
	count, err := result.RowsAffected()
	return count > 0, err
}

func (s *PostgresStore) SetUserBlocked(blockerID, blockedID string, blocked bool) error {
	if !blocked {
		_, err := s.db.Exec("DELETE FROM user_blocks WHERE blocker_id = $1 AND blocked_id = $2", blockerID, blockedID)
		return err
	}
	_, err := s.db.Exec(`INSERT INTO user_blocks (blocker_id, blocked_id) VALUES ($1, $2)
		ON CONFLICT(blocker_id, blocked_id) DO NOTHING`, blockerID, blockedID)
	return err
}

func (s *PostgresStore) IsUserBlocked(blockerID, blockedID string) (bool, error) {
	var count int
	err := s.db.QueryRow("SELECT COUNT(*) FROM user_blocks WHERE blocker_id = $1 AND blocked_id = $2", blockerID, blockedID).Scan(&count)
	return count > 0, err
}

func (s *PostgresStore) CreateUserReport(report *UserReport) error {
	_, err := s.db.Exec(`INSERT INTO user_reports
		(id, reporter_id, target_id, reason, details, created_at) VALUES ($1, $2, $3, $4, $5, $6)`,
		report.ID, report.ReporterID, report.TargetID, report.Reason, report.Details, report.CreatedAt)
	return err
}

func (s *PostgresStore) GetUserReports(limit int) ([]*UserReport, error) {
	if limit <= 0 || limit > 500 {
		limit = 500
	}
	rows, err := s.db.Query(`SELECT id, reporter_id, target_id, reason, details, created_at
		FROM user_reports ORDER BY created_at DESC LIMIT $1`, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	result := make([]*UserReport, 0)
	for rows.Next() {
		report := &UserReport{}
		if err := rows.Scan(&report.ID, &report.ReporterID, &report.TargetID, &report.Reason, &report.Details, &report.CreatedAt); err != nil {
			return nil, err
		}
		result = append(result, report)
	}
	return result, rows.Err()
}
