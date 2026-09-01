package store

import "time"

// GetServerStats returns aggregate counts without loading full records.
func (s *MemoryStore) GetServerStats() (*ServerStats, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	stats := &ServerStats{
		Users:         len(s.users),
		Groups:        len(s.groups),
		Conversations: len(s.conversations),
		MediaFiles:    len(s.mediaFiles),
	}
	now := time.Now()
	for _, user := range s.users {
		if user.Online {
			stats.OnlineUsers++
		}
	}
	for _, messages := range s.messages {
		stats.Messages += len(messages)
	}
	for _, session := range s.sessions {
		if session.ExpiresAt.After(now) {
			stats.ActiveSessions++
		}
	}
	for _, file := range s.mediaFiles {
		stats.MediaBytes += file.Size
	}
	for _, subscriptions := range s.pushSubscriptions {
		stats.PushSubscriptions += len(subscriptions)
	}
	return stats, nil
}

func (s *SQLiteStore) GetServerStats() (*ServerStats, error) {
	stats := &ServerStats{}
	queries := []struct {
		destination *int
		query       string
		args        []interface{}
	}{
		{&stats.Users, "SELECT COUNT(*) FROM users", nil},
		{&stats.OnlineUsers, "SELECT COUNT(*) FROM users WHERE online = TRUE", nil},
		{&stats.Groups, "SELECT COUNT(*) FROM groups", nil},
		{&stats.Conversations, "SELECT COUNT(*) FROM conversations", nil},
		{&stats.Messages, "SELECT COUNT(*) FROM messages", nil},
		{&stats.ActiveSessions, "SELECT COUNT(*) FROM sessions WHERE expires_at > ?", []interface{}{time.Now()}},
		{&stats.MediaFiles, "SELECT COUNT(*) FROM media_files", nil},
		{&stats.PushSubscriptions, "SELECT COUNT(*) FROM push_subscriptions", nil},
	}
	for _, item := range queries {
		if err := s.db.QueryRow(item.query, item.args...).Scan(item.destination); err != nil {
			return nil, err
		}
	}
	if err := s.db.QueryRow("SELECT COALESCE(SUM(size), 0) FROM media_files").Scan(&stats.MediaBytes); err != nil {
		return nil, err
	}
	return stats, nil
}

func (s *PostgresStore) GetServerStats() (*ServerStats, error) {
	stats := &ServerStats{}
	queries := []struct {
		destination *int
		query       string
		args        []interface{}
	}{
		{&stats.Users, "SELECT COUNT(*) FROM users", nil},
		{&stats.OnlineUsers, "SELECT COUNT(*) FROM users WHERE online = TRUE", nil},
		{&stats.Groups, "SELECT COUNT(*) FROM groups", nil},
		{&stats.Conversations, "SELECT COUNT(*) FROM conversations", nil},
		{&stats.Messages, "SELECT COUNT(*) FROM messages", nil},
		{&stats.ActiveSessions, "SELECT COUNT(*) FROM sessions WHERE expires_at > $1", []interface{}{time.Now()}},
		{&stats.MediaFiles, "SELECT COUNT(*) FROM media_files", nil},
		{&stats.PushSubscriptions, "SELECT COUNT(*) FROM push_subscriptions", nil},
	}
	for _, item := range queries {
		if err := s.db.QueryRow(item.query, item.args...).Scan(item.destination); err != nil {
			return nil, err
		}
	}
	if err := s.db.QueryRow("SELECT COALESCE(SUM(size), 0) FROM media_files").Scan(&stats.MediaBytes); err != nil {
		return nil, err
	}
	return stats, nil
}
