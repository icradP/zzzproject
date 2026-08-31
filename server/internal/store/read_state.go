package store

import (
	"database/sql"
	"time"
)

// ---- Memory read-state operations ----

func (s *MemoryStore) MarkConversationRead(conversationID, userID string) (*ReadState, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	state := &ReadState{
		ConversationID: conversationID,
		UserID:         userID,
		ReadAt:         time.Now(),
	}
	messages := s.messages[conversationID]
	if len(messages) > 0 {
		last := messages[len(messages)-1]
		state.LastReadMessageID = last.ID
		state.ReadAt = last.Timestamp
	}
	if s.readStates[conversationID] == nil {
		s.readStates[conversationID] = make(map[string]*ReadState)
	}
	copy := *state
	s.readStates[conversationID][userID] = &copy
	return state, nil
}

func (s *MemoryStore) GetConversationRead(conversationID, userID string) (*ReadState, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	state := s.readStates[conversationID][userID]
	if state == nil {
		return nil, nil
	}
	copy := *state
	return &copy, nil
}

func (s *MemoryStore) GetConversationReadStates(conversationID string) ([]*ReadState, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	states := s.readStates[conversationID]
	result := make([]*ReadState, 0, len(states))
	for _, state := range states {
		copy := *state
		result = append(result, &copy)
	}
	return result, nil
}

func (s *MemoryStore) CountUnreadMessages(conversationID, userID string) (int, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	messages := s.messages[conversationID]
	start := 0
	if state := s.readStates[conversationID][userID]; state != nil {
		start = len(messages)
		if state.LastReadMessageID != "" {
			for index, message := range messages {
				if message.ID == state.LastReadMessageID {
					start = index + 1
					break
				}
			}
		} else {
			for index, message := range messages {
				if message.Timestamp.After(state.ReadAt) {
					start = index
					break
				}
			}
		}
	}
	unread := 0
	for _, message := range messages[start:] {
		if message.SenderID != userID {
			unread++
		}
	}
	return unread, nil
}

// ---- SQLite read-state operations ----

func (s *SQLiteStore) MarkConversationRead(conversationID, userID string) (*ReadState, error) {
	state := &ReadState{
		ConversationID: conversationID,
		UserID:         userID,
		ReadAt:         time.Now(),
	}
	err := s.db.QueryRow(`
		SELECT id, timestamp FROM messages
		WHERE conversation_id = ?
		ORDER BY timestamp DESC, id DESC LIMIT 1`, conversationID,
	).Scan(&state.LastReadMessageID, &state.ReadAt)
	if err != nil && err != sql.ErrNoRows {
		return nil, err
	}
	_, err = s.db.Exec(`
		INSERT INTO conversation_reads (conversation_id, user_id, last_read_message_id, read_at)
		VALUES (?, ?, ?, ?)
		ON CONFLICT(conversation_id, user_id) DO UPDATE SET
			last_read_message_id = excluded.last_read_message_id,
			read_at = excluded.read_at`,
		state.ConversationID, state.UserID, state.LastReadMessageID, state.ReadAt,
	)
	if err != nil {
		return nil, err
	}
	return state, nil
}

func (s *SQLiteStore) GetConversationRead(conversationID, userID string) (*ReadState, error) {
	state := &ReadState{}
	err := s.db.QueryRow(`
		SELECT conversation_id, user_id, last_read_message_id, read_at
		FROM conversation_reads WHERE conversation_id = ? AND user_id = ?`,
		conversationID, userID,
	).Scan(&state.ConversationID, &state.UserID, &state.LastReadMessageID, &state.ReadAt)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return state, nil
}

func (s *SQLiteStore) GetConversationReadStates(conversationID string) ([]*ReadState, error) {
	rows, err := s.db.Query(`
		SELECT conversation_id, user_id, last_read_message_id, read_at
		FROM conversation_reads WHERE conversation_id = ?`, conversationID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var result []*ReadState
	for rows.Next() {
		state := &ReadState{}
		if err := rows.Scan(&state.ConversationID, &state.UserID, &state.LastReadMessageID, &state.ReadAt); err != nil {
			return nil, err
		}
		result = append(result, state)
	}
	return result, rows.Err()
}

func (s *SQLiteStore) CountUnreadMessages(conversationID, userID string) (int, error) {
	state, err := s.GetConversationRead(conversationID, userID)
	if err != nil {
		return 0, err
	}
	query := `SELECT COUNT(*) FROM messages WHERE conversation_id = ? AND sender_id <> ?`
	args := []interface{}{conversationID, userID}
	if state != nil {
		query += " AND timestamp > ?"
		args = append(args, state.ReadAt)
	}
	var count int
	if err := s.db.QueryRow(query, args...).Scan(&count); err != nil {
		return 0, err
	}
	return count, nil
}

// ---- PostgreSQL read-state operations ----

func (s *PostgresStore) MarkConversationRead(conversationID, userID string) (*ReadState, error) {
	state := &ReadState{
		ConversationID: conversationID,
		UserID:         userID,
		ReadAt:         time.Now(),
	}
	err := s.db.QueryRow(`
		SELECT id, created_at FROM messages
		WHERE conversation_id = $1
		ORDER BY created_at DESC, id DESC LIMIT 1`, conversationID,
	).Scan(&state.LastReadMessageID, &state.ReadAt)
	if err != nil && err != sql.ErrNoRows {
		return nil, err
	}
	_, err = s.db.Exec(`
		INSERT INTO conversation_reads (conversation_id, user_id, last_read_message_id, read_at)
		VALUES ($1, $2, $3, $4)
		ON CONFLICT(conversation_id, user_id) DO UPDATE SET
			last_read_message_id = EXCLUDED.last_read_message_id,
			read_at = EXCLUDED.read_at`,
		state.ConversationID, state.UserID, state.LastReadMessageID, state.ReadAt,
	)
	if err != nil {
		return nil, err
	}
	return state, nil
}

func (s *PostgresStore) GetConversationRead(conversationID, userID string) (*ReadState, error) {
	state := &ReadState{}
	err := s.db.QueryRow(`
		SELECT conversation_id, user_id, last_read_message_id, read_at
		FROM conversation_reads WHERE conversation_id = $1 AND user_id = $2`,
		conversationID, userID,
	).Scan(&state.ConversationID, &state.UserID, &state.LastReadMessageID, &state.ReadAt)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return state, nil
}

func (s *PostgresStore) GetConversationReadStates(conversationID string) ([]*ReadState, error) {
	rows, err := s.db.Query(`
		SELECT conversation_id, user_id, last_read_message_id, read_at
		FROM conversation_reads WHERE conversation_id = $1`, conversationID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var result []*ReadState
	for rows.Next() {
		state := &ReadState{}
		if err := rows.Scan(&state.ConversationID, &state.UserID, &state.LastReadMessageID, &state.ReadAt); err != nil {
			return nil, err
		}
		result = append(result, state)
	}
	return result, rows.Err()
}

func (s *PostgresStore) CountUnreadMessages(conversationID, userID string) (int, error) {
	state, err := s.GetConversationRead(conversationID, userID)
	if err != nil {
		return 0, err
	}
	query := `SELECT COUNT(*) FROM messages WHERE conversation_id = $1 AND sender_id <> $2`
	args := []interface{}{conversationID, userID}
	if state != nil {
		query += " AND created_at > $3"
		args = append(args, state.ReadAt)
	}
	var count int
	if err := s.db.QueryRow(query, args...).Scan(&count); err != nil {
		return 0, err
	}
	return count, nil
}
