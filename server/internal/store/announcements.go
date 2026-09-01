package store

import (
	"database/sql"
	"fmt"
	"sort"
	"time"
)

func (s *MemoryStore) CreateGroupAnnouncement(groupID, content, authorID string, isPinned bool) (*GroupAnnouncement, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.groups[groupID] == nil {
		return nil, fmt.Errorf("group not found")
	}
	s.announcementCounter++
	now := time.Now()
	announcement := &GroupAnnouncement{
		ID:      fmt.Sprintf("announcement_%d_%d", now.UnixNano(), s.announcementCounter),
		GroupID: groupID, Content: content, AuthorID: authorID, IsPinned: isPinned,
		CreatedAt: now, UpdatedAt: now,
	}
	s.groupAnnouncements[groupID] = append(s.groupAnnouncements[groupID], announcement)
	copy := *announcement
	return &copy, nil
}

func (s *MemoryStore) GetGroupAnnouncement(id string) (*GroupAnnouncement, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	for _, announcements := range s.groupAnnouncements {
		for _, announcement := range announcements {
			if announcement.ID == id {
				copy := *announcement
				return &copy, nil
			}
		}
	}
	return nil, nil
}

func (s *MemoryStore) GetGroupAnnouncements(groupID, userID string) ([]*GroupAnnouncement, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	result := make([]*GroupAnnouncement, 0, len(s.groupAnnouncements[groupID]))
	for _, announcement := range s.groupAnnouncements[groupID] {
		copy := *announcement
		copy.IsRead = s.announcementReads[announcement.ID][userID]
		result = append(result, &copy)
	}
	sort.Slice(result, func(i, j int) bool {
		if result[i].IsPinned != result[j].IsPinned {
			return result[i].IsPinned
		}
		return result[i].UpdatedAt.After(result[j].UpdatedAt)
	})
	return result, nil
}

func (s *MemoryStore) UpdateGroupAnnouncement(id, content string, isPinned bool) (*GroupAnnouncement, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, announcements := range s.groupAnnouncements {
		for _, announcement := range announcements {
			if announcement.ID == id {
				announcement.Content = content
				announcement.IsPinned = isPinned
				announcement.UpdatedAt = time.Now()
				copy := *announcement
				return &copy, nil
			}
		}
	}
	return nil, nil
}

func (s *MemoryStore) DeleteGroupAnnouncement(id string) (bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	for groupID, announcements := range s.groupAnnouncements {
		for index, announcement := range announcements {
			if announcement.ID == id {
				s.groupAnnouncements[groupID] = append(announcements[:index], announcements[index+1:]...)
				delete(s.announcementReads, id)
				return true, nil
			}
		}
	}
	return false, nil
}

func (s *MemoryStore) MarkGroupAnnouncementRead(id, userID string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	found := false
	for _, announcements := range s.groupAnnouncements {
		for _, announcement := range announcements {
			if announcement.ID == id {
				found = true
				break
			}
		}
	}
	if !found {
		return sql.ErrNoRows
	}
	readers := s.announcementReads[id]
	if readers == nil {
		readers = make(map[string]bool)
		s.announcementReads[id] = readers
	}
	readers[userID] = true
	return nil
}

func (s *SQLiteStore) CreateGroupAnnouncement(groupID, content, authorID string, isPinned bool) (*GroupAnnouncement, error) {
	now := time.Now()
	announcement := &GroupAnnouncement{
		ID: fmt.Sprintf("announcement_%d", now.UnixNano()), GroupID: groupID,
		Content: content, AuthorID: authorID, IsPinned: isPinned,
		CreatedAt: now, UpdatedAt: now,
	}
	_, err := s.db.Exec(`INSERT INTO group_announcements
		(id, group_id, content, author_id, is_pinned, created_at, updated_at)
		VALUES (?, ?, ?, ?, ?, ?, ?)`, announcement.ID, groupID, content, authorID, isPinned, now, now)
	if err != nil {
		return nil, err
	}
	return announcement, nil
}

func (s *SQLiteStore) GetGroupAnnouncement(id string) (*GroupAnnouncement, error) {
	announcement := &GroupAnnouncement{}
	err := s.db.QueryRow(`SELECT id, group_id, content, author_id, is_pinned, created_at, updated_at
		FROM group_announcements WHERE id = ?`, id).Scan(
		&announcement.ID, &announcement.GroupID, &announcement.Content, &announcement.AuthorID,
		&announcement.IsPinned, &announcement.CreatedAt, &announcement.UpdatedAt,
	)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	return announcement, err
}

func (s *SQLiteStore) GetGroupAnnouncements(groupID, userID string) ([]*GroupAnnouncement, error) {
	rows, err := s.db.Query(`SELECT a.id, a.group_id, a.content, a.author_id, a.is_pinned,
		a.created_at, a.updated_at, CASE WHEN r.user_id IS NULL THEN FALSE ELSE TRUE END
		FROM group_announcements a
		LEFT JOIN group_announcement_reads r ON r.announcement_id = a.id AND r.user_id = ?
		WHERE a.group_id = ? ORDER BY a.is_pinned DESC, a.updated_at DESC`, userID, groupID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var result []*GroupAnnouncement
	for rows.Next() {
		announcement := &GroupAnnouncement{}
		if err := rows.Scan(&announcement.ID, &announcement.GroupID, &announcement.Content,
			&announcement.AuthorID, &announcement.IsPinned, &announcement.CreatedAt,
			&announcement.UpdatedAt, &announcement.IsRead); err != nil {
			return nil, err
		}
		result = append(result, announcement)
	}
	return result, rows.Err()
}

func (s *SQLiteStore) UpdateGroupAnnouncement(id, content string, isPinned bool) (*GroupAnnouncement, error) {
	result, err := s.db.Exec(`UPDATE group_announcements SET content = ?, is_pinned = ?, updated_at = ? WHERE id = ?`,
		content, isPinned, time.Now(), id)
	if err != nil {
		return nil, err
	}
	rows, err := result.RowsAffected()
	if err != nil || rows == 0 {
		return nil, err
	}
	return s.GetGroupAnnouncement(id)
}

func (s *SQLiteStore) DeleteGroupAnnouncement(id string) (bool, error) {
	tx, err := s.db.Begin()
	if err != nil {
		return false, err
	}
	defer tx.Rollback()
	if _, err := tx.Exec("DELETE FROM group_announcement_reads WHERE announcement_id = ?", id); err != nil {
		return false, err
	}
	result, err := tx.Exec("DELETE FROM group_announcements WHERE id = ?", id)
	if err != nil {
		return false, err
	}
	rows, err := result.RowsAffected()
	if err != nil {
		return false, err
	}
	return rows > 0, tx.Commit()
}

func (s *SQLiteStore) MarkGroupAnnouncementRead(id, userID string) error {
	_, err := s.db.Exec(`INSERT INTO group_announcement_reads (announcement_id, user_id, read_at)
		VALUES (?, ?, ?) ON CONFLICT(announcement_id, user_id) DO UPDATE SET read_at = excluded.read_at`,
		id, userID, time.Now())
	return err
}

func (s *PostgresStore) CreateGroupAnnouncement(groupID, content, authorID string, isPinned bool) (*GroupAnnouncement, error) {
	now := time.Now()
	announcement := &GroupAnnouncement{
		ID: fmt.Sprintf("announcement_%d", now.UnixNano()), GroupID: groupID,
		Content: content, AuthorID: authorID, IsPinned: isPinned,
		CreatedAt: now, UpdatedAt: now,
	}
	_, err := s.db.Exec(`INSERT INTO group_announcements
		(id, group_id, content, author_id, is_pinned, created_at, updated_at)
		VALUES ($1, $2, $3, $4, $5, $6, $7)`, announcement.ID, groupID, content, authorID, isPinned, now, now)
	if err != nil {
		return nil, err
	}
	return announcement, nil
}

func (s *PostgresStore) GetGroupAnnouncement(id string) (*GroupAnnouncement, error) {
	announcement := &GroupAnnouncement{}
	err := s.db.QueryRow(`SELECT id, group_id, content, author_id, is_pinned, created_at, updated_at
		FROM group_announcements WHERE id = $1`, id).Scan(
		&announcement.ID, &announcement.GroupID, &announcement.Content, &announcement.AuthorID,
		&announcement.IsPinned, &announcement.CreatedAt, &announcement.UpdatedAt,
	)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	return announcement, err
}

func (s *PostgresStore) GetGroupAnnouncements(groupID, userID string) ([]*GroupAnnouncement, error) {
	rows, err := s.db.Query(`SELECT a.id, a.group_id, a.content, a.author_id, a.is_pinned,
		a.created_at, a.updated_at, CASE WHEN r.user_id IS NULL THEN FALSE ELSE TRUE END
		FROM group_announcements a
		LEFT JOIN group_announcement_reads r ON r.announcement_id = a.id AND r.user_id = $1
		WHERE a.group_id = $2 ORDER BY a.is_pinned DESC, a.updated_at DESC`, userID, groupID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var result []*GroupAnnouncement
	for rows.Next() {
		announcement := &GroupAnnouncement{}
		if err := rows.Scan(&announcement.ID, &announcement.GroupID, &announcement.Content,
			&announcement.AuthorID, &announcement.IsPinned, &announcement.CreatedAt,
			&announcement.UpdatedAt, &announcement.IsRead); err != nil {
			return nil, err
		}
		result = append(result, announcement)
	}
	return result, rows.Err()
}

func (s *PostgresStore) UpdateGroupAnnouncement(id, content string, isPinned bool) (*GroupAnnouncement, error) {
	result, err := s.db.Exec(`UPDATE group_announcements SET content = $1, is_pinned = $2, updated_at = $3 WHERE id = $4`,
		content, isPinned, time.Now(), id)
	if err != nil {
		return nil, err
	}
	rows, err := result.RowsAffected()
	if err != nil || rows == 0 {
		return nil, err
	}
	return s.GetGroupAnnouncement(id)
}

func (s *PostgresStore) DeleteGroupAnnouncement(id string) (bool, error) {
	tx, err := s.db.Begin()
	if err != nil {
		return false, err
	}
	defer tx.Rollback()
	if _, err := tx.Exec("DELETE FROM group_announcement_reads WHERE announcement_id = $1", id); err != nil {
		return false, err
	}
	result, err := tx.Exec("DELETE FROM group_announcements WHERE id = $1", id)
	if err != nil {
		return false, err
	}
	rows, err := result.RowsAffected()
	if err != nil {
		return false, err
	}
	return rows > 0, tx.Commit()
}

func (s *PostgresStore) MarkGroupAnnouncementRead(id, userID string) error {
	_, err := s.db.Exec(`INSERT INTO group_announcement_reads (announcement_id, user_id, read_at)
		VALUES ($1, $2, $3) ON CONFLICT(announcement_id, user_id) DO UPDATE SET read_at = EXCLUDED.read_at`,
		id, userID, time.Now())
	return err
}
