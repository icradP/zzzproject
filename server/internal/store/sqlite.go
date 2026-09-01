package store

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"strings"
	"time"

	"github.com/icradp/zzz-im-server/internal/protocol"
	_ "github.com/mattn/go-sqlite3"
)

// SQLiteStore implements Store using SQLite.
type SQLiteStore struct {
	db *sql.DB
}

// NewSQLiteStore creates a new SQLite store.
func NewSQLiteStore(dbPath string) (*SQLiteStore, error) {
	db, err := sql.Open("sqlite3", dbPath)
	if err != nil {
		return nil, fmt.Errorf("failed to open database: %w", err)
	}

	store := &SQLiteStore{db: db}
	if err := store.initSchema(); err != nil {
		return nil, fmt.Errorf("failed to initialize schema: %w", err)
	}

	return store, nil
}

// initSchema creates the database tables.
func (s *SQLiteStore) initSchema() error {
	schema := `
	CREATE TABLE IF NOT EXISTS users (
		id TEXT PRIMARY KEY,
		nickname TEXT NOT NULL,
		avatar_url TEXT DEFAULT '',
		password_hash TEXT DEFAULT '',
		online BOOLEAN DEFAULT FALSE,
		created_at DATETIME DEFAULT CURRENT_TIMESTAMP
	);

	CREATE TABLE IF NOT EXISTS schema_migrations (
		id TEXT PRIMARY KEY,
		applied_at DATETIME DEFAULT CURRENT_TIMESTAMP
	);

		CREATE TABLE IF NOT EXISTS conversations (
		id TEXT PRIMARY KEY,
		type TEXT NOT NULL, -- "private" or "group"
		title TEXT NOT NULL,
		avatar_url TEXT DEFAULT '',
		owner_id TEXT DEFAULT '',
		participants TEXT DEFAULT '[]', -- JSON array of user IDs
		created_at DATETIME DEFAULT CURRENT_TIMESTAMP
		);

		CREATE TABLE IF NOT EXISTS conversation_preferences (
			conversation_id TEXT NOT NULL,
			user_id TEXT NOT NULL,
			is_pinned BOOLEAN DEFAULT FALSE,
			is_muted BOOLEAN DEFAULT FALSE,
			updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
			PRIMARY KEY (conversation_id, user_id),
			FOREIGN KEY (conversation_id) REFERENCES conversations(id)
		);

		CREATE INDEX IF NOT EXISTS idx_conversation_preferences_user
			ON conversation_preferences(user_id, is_pinned, updated_at);

	CREATE TABLE IF NOT EXISTS sessions (
		token_hash TEXT PRIMARY KEY,
		user_id TEXT NOT NULL,
		expires_at DATETIME NOT NULL,
		created_at DATETIME DEFAULT CURRENT_TIMESTAMP
	);

	CREATE INDEX IF NOT EXISTS idx_sessions_expires_at ON sessions(expires_at);

	CREATE TABLE IF NOT EXISTS messages (
		id TEXT PRIMARY KEY,
		conversation_id TEXT NOT NULL,
		sender_id TEXT NOT NULL,
		sender_nickname TEXT NOT NULL,
		segments TEXT NOT NULL, -- JSON array of segments
		recalled BOOLEAN DEFAULT FALSE,
		timestamp DATETIME DEFAULT CURRENT_TIMESTAMP,
		FOREIGN KEY (conversation_id) REFERENCES conversations(id)
	);

	CREATE INDEX IF NOT EXISTS idx_messages_conversation ON messages(conversation_id, timestamp);
	CREATE INDEX IF NOT EXISTS idx_messages_sender ON messages(sender_id);

	CREATE TABLE IF NOT EXISTS message_reactions (
		message_id TEXT NOT NULL,
		emoji_id TEXT NOT NULL,
		user_id TEXT NOT NULL,
		created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
		PRIMARY KEY (message_id, emoji_id, user_id),
		FOREIGN KEY (message_id) REFERENCES messages(id)
	);

	CREATE INDEX IF NOT EXISTS idx_message_reactions_message
		ON message_reactions(message_id, emoji_id);

	CREATE TABLE IF NOT EXISTS conversation_reads (
		conversation_id TEXT NOT NULL,
		user_id TEXT NOT NULL,
		last_read_message_id TEXT DEFAULT '',
		read_at DATETIME NOT NULL,
		PRIMARY KEY (conversation_id, user_id),
		FOREIGN KEY (conversation_id) REFERENCES conversations(id)
	);

	CREATE INDEX IF NOT EXISTS idx_conversation_reads_conversation
		ON conversation_reads(conversation_id);

		CREATE TABLE IF NOT EXISTS groups (
			id TEXT PRIMARY KEY,
			name TEXT NOT NULL,
			avatar_url TEXT DEFAULT '',
			announcement TEXT DEFAULT '',
			owner_id TEXT NOT NULL,
			mute_all BOOLEAN DEFAULT FALSE,
			created_at DATETIME DEFAULT CURRENT_TIMESTAMP
	);

	CREATE TABLE IF NOT EXISTS group_members (
		group_id TEXT NOT NULL,
			user_id TEXT NOT NULL,
			role TEXT DEFAULT 'member', -- "owner", "admin", "member"
			joined_at DATETIME DEFAULT CURRENT_TIMESTAMP,
			muted_until DATETIME,
		PRIMARY KEY (group_id, user_id),
		FOREIGN KEY (group_id) REFERENCES groups(id)
	);

	CREATE TABLE IF NOT EXISTS friend_requests (
		id TEXT PRIMARY KEY,
		from_id TEXT NOT NULL,
		to_id TEXT NOT NULL,
		comment TEXT DEFAULT '',
		status TEXT DEFAULT 'pending', -- "pending", "accepted", "rejected"
		created_at DATETIME DEFAULT CURRENT_TIMESTAMP
	);

	CREATE INDEX IF NOT EXISTS idx_friend_requests_to ON friend_requests(to_id, status);

	CREATE TABLE IF NOT EXISTS friendships (
		user_id TEXT NOT NULL,
		friend_id TEXT NOT NULL,
		created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
		PRIMARY KEY (user_id, friend_id),
		FOREIGN KEY (user_id) REFERENCES users(id),
		FOREIGN KEY (friend_id) REFERENCES users(id)
	);

	CREATE INDEX IF NOT EXISTS idx_friendships_user ON friendships(user_id, created_at);

	CREATE TABLE IF NOT EXISTS forwards (
		id TEXT PRIMARY KEY,
		messages TEXT NOT NULL, -- JSON array of messages
		created_at DATETIME DEFAULT CURRENT_TIMESTAMP
	);

	CREATE TABLE IF NOT EXISTS media_files (
		id TEXT PRIMARY KEY,
		file_name TEXT NOT NULL,
		file_type TEXT NOT NULL, -- "image", "voice", "video", "file"
		mime_type TEXT DEFAULT '',
		size INTEGER DEFAULT 0,
		url TEXT NOT NULL,
		uploader_id TEXT NOT NULL,
		created_at DATETIME DEFAULT CURRENT_TIMESTAMP
	);

	CREATE TABLE IF NOT EXISTS push_subscriptions (
		user_id TEXT NOT NULL,
		endpoint TEXT NOT NULL,
		p256dh TEXT NOT NULL,
		auth TEXT NOT NULL,
		created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
		updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
		PRIMARY KEY (user_id, endpoint)
	);

	CREATE INDEX IF NOT EXISTS idx_push_subscriptions_user ON push_subscriptions(user_id);
	`

	if _, err := s.db.Exec(schema); err != nil {
		return err
	}
	// Upgrade databases created before account authentication was introduced.
	if _, err := s.db.Exec("ALTER TABLE users ADD COLUMN password_hash TEXT DEFAULT ''"); err != nil &&
		!strings.Contains(strings.ToLower(err.Error()), "duplicate column") {
		return err
	}
	for _, statement := range []string{
		"ALTER TABLE groups ADD COLUMN announcement TEXT DEFAULT ''",
		"ALTER TABLE groups ADD COLUMN mute_all BOOLEAN DEFAULT FALSE",
		"ALTER TABLE group_members ADD COLUMN muted_until DATETIME",
	} {
		if _, err := s.db.Exec(statement); err != nil &&
			!strings.Contains(strings.ToLower(err.Error()), "duplicate column") {
			return err
		}
	}
	return s.migrateLegacyFriendships()
}

func (s *SQLiteStore) migrateLegacyFriendships() error {
	const migrationID = "001_private_conversations_to_friendships"
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var applied int
	if err := tx.QueryRow(
		"SELECT COUNT(*) FROM schema_migrations WHERE id = ?", migrationID,
	).Scan(&applied); err != nil {
		return err
	}
	if applied > 0 {
		return tx.Commit()
	}
	if _, err := tx.Exec(`
		INSERT OR IGNORE INTO friendships (user_id, friend_id, created_at)
		SELECT source.value, target.value, conversation.created_at
		FROM conversations conversation
		JOIN json_each(conversation.participants) source
		JOIN json_each(conversation.participants) target
		WHERE conversation.type = 'private'
		  AND source.value <> target.value
		  AND EXISTS (SELECT 1 FROM users WHERE id = source.value)
		  AND EXISTS (SELECT 1 FROM users WHERE id = target.value)`); err != nil {
		return err
	}
	if _, err := tx.Exec(
		"INSERT INTO schema_migrations (id) VALUES (?)", migrationID,
	); err != nil {
		return err
	}
	return tx.Commit()
}

// Close closes the database connection.
func (s *SQLiteStore) Close() error {
	return s.db.Close()
}

// ---- User operations ----

func (s *SQLiteStore) GetUser(id string) (*User, error) {
	user := &User{}
	err := s.db.QueryRow(
		"SELECT id, nickname, avatar_url, online, password_hash, created_at FROM users WHERE id = ?",
		id,
	).Scan(&user.ID, &user.Nickname, &user.Avatar, &user.Online, &user.PasswordHash, &user.CreatedAt)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return user, nil
}

func (s *SQLiteStore) SetUser(user *User) error {
	_, err := s.db.Exec(
		"INSERT INTO users (id, nickname, avatar_url, online, password_hash) VALUES (?, ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET nickname=excluded.nickname, avatar_url=excluded.avatar_url, online=excluded.online, password_hash=excluded.password_hash",
		user.ID, user.Nickname, user.Avatar, user.Online, user.PasswordHash,
	)
	return err
}

func (s *SQLiteStore) GetUsers() ([]*User, error) {
	rows, err := s.db.Query("SELECT id, nickname, avatar_url, online, password_hash, created_at FROM users")
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var users []*User
	for rows.Next() {
		user := &User{}
		if err := rows.Scan(&user.ID, &user.Nickname, &user.Avatar, &user.Online, &user.PasswordHash, &user.CreatedAt); err != nil {
			return nil, err
		}
		users = append(users, user)
	}
	return users, nil
}

func (s *SQLiteStore) SetUserOnline(id string, online bool) error {
	_, err := s.db.Exec("UPDATE users SET online = ? WHERE id = ?", online, id)
	return err
}

// ---- Conversation operations ----

func (s *SQLiteStore) GetOrCreateConversation(id, convType, title string) (*Conversation, error) {
	conv, err := s.GetConversation(id)
	if err != nil {
		return nil, err
	}
	if conv != nil {
		return conv, nil
	}

	participantsJSON, _ := json.Marshal([]string{})
	_, err = s.db.Exec(
		"INSERT INTO conversations (id, type, title, participants) VALUES (?, ?, ?, ?)",
		id, convType, title, string(participantsJSON),
	)
	if err != nil {
		return nil, err
	}

	return s.GetConversation(id)
}

func (s *SQLiteStore) SaveConversation(conversation *Conversation) error {
	participants, err := json.Marshal(conversation.Participants)
	if err != nil {
		return err
	}
	_, err = s.db.Exec(`
		INSERT INTO conversations (id, type, title, avatar_url, owner_id, participants)
		VALUES (?, ?, ?, ?, ?, ?)
		ON CONFLICT(id) DO UPDATE SET
			type = excluded.type,
			title = excluded.title,
			avatar_url = excluded.avatar_url,
			owner_id = excluded.owner_id,
			participants = excluded.participants`,
		conversation.ID, conversation.Type, conversation.Title,
		conversation.Avatar, conversation.OwnerID, string(participants),
	)
	return err
}

func (s *SQLiteStore) GetConversation(id string) (*Conversation, error) {
	conv := &Conversation{}
	var participantsJSON string
	err := s.db.QueryRow(
		"SELECT id, type, title, avatar_url, owner_id, participants, created_at FROM conversations WHERE id = ?",
		id,
	).Scan(&conv.ID, &conv.Type, &conv.Title, &conv.Avatar, &conv.OwnerID, &participantsJSON, &conv.CreatedAt)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	json.Unmarshal([]byte(participantsJSON), &conv.Participants)
	return conv, nil
}

func (s *SQLiteStore) GetConversations() ([]*Conversation, error) {
	rows, err := s.db.Query("SELECT id, type, title, avatar_url, owner_id, participants, created_at FROM conversations")
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var convs []*Conversation
	for rows.Next() {
		conv := &Conversation{}
		var participantsJSON string
		if err := rows.Scan(&conv.ID, &conv.Type, &conv.Title, &conv.Avatar, &conv.OwnerID, &participantsJSON, &conv.CreatedAt); err != nil {
			return nil, err
		}
		json.Unmarshal([]byte(participantsJSON), &conv.Participants)
		convs = append(convs, conv)
	}
	return convs, nil
}

func (s *SQLiteStore) GetUserConversations(userID string) ([]*Conversation, error) {
	// Get private conversations
	privateConvs, err := s.getPrivateConversations(userID)
	if err != nil {
		return nil, err
	}

	// Get group conversations
	groupConvs, err := s.getGroupConversations(userID)
	if err != nil {
		return nil, err
	}

	return append(privateConvs, groupConvs...), nil
}

func (s *SQLiteStore) GetConversationPreference(conversationID, userID string) (*ConversationPreference, error) {
	preference := &ConversationPreference{}
	err := s.db.QueryRow(
		`SELECT conversation_id, user_id, is_pinned, is_muted, updated_at
		 FROM conversation_preferences WHERE conversation_id = ? AND user_id = ?`,
		conversationID, userID,
	).Scan(
		&preference.ConversationID, &preference.UserID, &preference.IsPinned,
		&preference.IsMuted, &preference.UpdatedAt,
	)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return preference, nil
}

func (s *SQLiteStore) SetConversationPreference(preference *ConversationPreference) error {
	_, err := s.db.Exec(`
		INSERT INTO conversation_preferences
			(conversation_id, user_id, is_pinned, is_muted, updated_at)
		VALUES (?, ?, ?, ?, ?)
		ON CONFLICT(conversation_id, user_id) DO UPDATE SET
			is_pinned = excluded.is_pinned,
			is_muted = excluded.is_muted,
			updated_at = excluded.updated_at`,
		preference.ConversationID, preference.UserID, preference.IsPinned,
		preference.IsMuted, time.Now(),
	)
	return err
}

func (s *SQLiteStore) getPrivateConversations(userID string) ([]*Conversation, error) {
	rows, err := s.db.Query(
		"SELECT id, type, title, avatar_url, owner_id, participants, created_at FROM conversations WHERE type = 'private' AND participants LIKE ?",
		"%"+userID+"%",
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var convs []*Conversation
	for rows.Next() {
		conv := &Conversation{}
		var participantsJSON string
		if err := rows.Scan(&conv.ID, &conv.Type, &conv.Title, &conv.Avatar, &conv.OwnerID, &participantsJSON, &conv.CreatedAt); err != nil {
			return nil, err
		}
		json.Unmarshal([]byte(participantsJSON), &conv.Participants)
		convs = append(convs, conv)
	}
	return convs, nil
}

func (s *SQLiteStore) getGroupConversations(userID string) ([]*Conversation, error) {
	rows, err := s.db.Query(
		`SELECT c.id, c.type, c.title, c.avatar_url, c.owner_id, c.participants, c.created_at
		 FROM conversations c
		 JOIN group_members gm ON c.id = gm.group_id
		 WHERE gm.user_id = ?`,
		userID,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var convs []*Conversation
	for rows.Next() {
		conv := &Conversation{}
		var participantsJSON string
		if err := rows.Scan(&conv.ID, &conv.Type, &conv.Title, &conv.Avatar, &conv.OwnerID, &participantsJSON, &conv.CreatedAt); err != nil {
			return nil, err
		}
		json.Unmarshal([]byte(participantsJSON), &conv.Participants)
		convs = append(convs, conv)
	}
	return convs, nil
}

func (s *SQLiteStore) DeleteConversation(id string) error {
	if _, err := s.db.Exec("DELETE FROM conversation_preferences WHERE conversation_id = ?", id); err != nil {
		return err
	}
	if _, err := s.db.Exec("DELETE FROM conversation_reads WHERE conversation_id = ?", id); err != nil {
		return err
	}
	if _, err := s.db.Exec("DELETE FROM message_reactions WHERE message_id IN (SELECT id FROM messages WHERE conversation_id = ?)", id); err != nil {
		return err
	}
	_, err := s.db.Exec("DELETE FROM messages WHERE conversation_id = ?", id)
	if err != nil {
		return err
	}
	_, err = s.db.Exec("DELETE FROM conversations WHERE id = ?", id)
	return err
}

// ---- Message operations ----

func (s *SQLiteStore) StoreMessage(convID, senderID, senderNickname string, segments []protocol.MessageSegment) (*Message, error) {
	segmentsJSON, err := json.Marshal(segments)
	if err != nil {
		return nil, err
	}

	msg := &Message{
		ID:             fmt.Sprintf("msg_%d", time.Now().UnixNano()),
		ConversationID: convID,
		SenderID:       senderID,
		SenderNickname: senderNickname,
		Segments:       segments,
		Timestamp:      time.Now(),
	}

	_, err = s.db.Exec(
		"INSERT INTO messages (id, conversation_id, sender_id, sender_nickname, segments, timestamp) VALUES (?, ?, ?, ?, ?, ?)",
		msg.ID, msg.ConversationID, msg.SenderID, msg.SenderNickname, string(segmentsJSON), msg.Timestamp,
	)
	if err != nil {
		return nil, err
	}

	return msg, nil
}

func (s *SQLiteStore) GetMessage(msgID string) (*Message, error) {
	msg := &Message{}
	var segmentsJSON string
	err := s.db.QueryRow(
		"SELECT id, conversation_id, sender_id, sender_nickname, segments, recalled, timestamp FROM messages WHERE id = ?",
		msgID,
	).Scan(&msg.ID, &msg.ConversationID, &msg.SenderID, &msg.SenderNickname, &segmentsJSON, &msg.Recalled, &msg.Timestamp)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	json.Unmarshal([]byte(segmentsJSON), &msg.Segments)
	msg.Reactions, err = s.loadReactionCounts(msg.ID)
	if err != nil {
		return nil, err
	}
	return msg, nil
}

func (s *SQLiteStore) GetMessages(convID string, limit int) ([]*Message, error) {
	return s.GetMessagesBefore(convID, "", limit)
}

func (s *SQLiteStore) GetMessagesBefore(convID, beforeMessageID string, limit int) ([]*Message, error) {
	query := "SELECT id, conversation_id, sender_id, sender_nickname, segments, recalled, timestamp FROM messages WHERE conversation_id = ?"
	args := []interface{}{convID}
	if beforeMessageID != "" {
		query += " AND (timestamp, id) < (SELECT timestamp, id FROM messages WHERE conversation_id = ? AND id = ?)"
		args = append(args, convID, beforeMessageID)
	}
	query += " ORDER BY timestamp DESC, id DESC LIMIT ?"
	args = append(args, limit)
	rows, err := s.db.Query(query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var msgs []*Message
	for rows.Next() {
		msg := &Message{}
		var segmentsJSON string
		if err := rows.Scan(&msg.ID, &msg.ConversationID, &msg.SenderID, &msg.SenderNickname, &segmentsJSON, &msg.Recalled, &msg.Timestamp); err != nil {
			return nil, err
		}
		json.Unmarshal([]byte(segmentsJSON), &msg.Segments)
		msg.Reactions, err = s.loadReactionCounts(msg.ID)
		if err != nil {
			return nil, err
		}
		msgs = append(msgs, msg)
	}

	// Reverse to get chronological order
	for i, j := 0, len(msgs)-1; i < j; i, j = i+1, j-1 {
		msgs[i], msgs[j] = msgs[j], msgs[i]
	}

	return msgs, nil
}

func (s *SQLiteStore) GetRecentMessages(limit int) ([]*Message, error) {
	if limit <= 0 {
		limit = 200
	}
	rows, err := s.db.Query(
		"SELECT id, conversation_id, sender_id, sender_nickname, segments, recalled, timestamp FROM messages ORDER BY timestamp DESC, id DESC LIMIT ?",
		limit,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var messages []*Message
	for rows.Next() {
		message := &Message{}
		var segmentsJSON string
		if err := rows.Scan(&message.ID, &message.ConversationID, &message.SenderID, &message.SenderNickname, &segmentsJSON, &message.Recalled, &message.Timestamp); err != nil {
			return nil, err
		}
		if err := json.Unmarshal([]byte(segmentsJSON), &message.Segments); err != nil {
			return nil, err
		}
		messages = append(messages, message)
	}
	return messages, rows.Err()
}

func (s *SQLiteStore) DeleteMessage(msgID string) (bool, error) {
	tx, err := s.db.Begin()
	if err != nil {
		return false, err
	}
	defer tx.Rollback()
	if _, err := tx.Exec("DELETE FROM message_reactions WHERE message_id = ?", msgID); err != nil {
		return false, err
	}
	result, err := tx.Exec("DELETE FROM messages WHERE id = ?", msgID)
	if err != nil {
		return false, err
	}
	deleted, err := result.RowsAffected()
	if err != nil {
		return false, err
	}
	if err := tx.Commit(); err != nil {
		return false, err
	}
	return deleted > 0, nil
}

func (s *SQLiteStore) ReactToMessage(msgID, userID, emojiID string, remove bool) (*Message, error) {
	tx, err := s.db.Begin()
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	var exists bool
	if err := tx.QueryRow("SELECT EXISTS(SELECT 1 FROM messages WHERE id = ? AND recalled = FALSE)", msgID).Scan(&exists); err != nil {
		return nil, err
	}
	if !exists {
		return nil, nil
	}
	if remove {
		_, err = tx.Exec("DELETE FROM message_reactions WHERE message_id = ? AND emoji_id = ? AND user_id = ?", msgID, emojiID, userID)
	} else {
		_, err = tx.Exec("INSERT OR IGNORE INTO message_reactions (message_id, emoji_id, user_id) VALUES (?, ?, ?)", msgID, emojiID, userID)
	}
	if err != nil {
		return nil, err
	}
	if err := tx.Commit(); err != nil {
		return nil, err
	}
	return s.GetMessage(msgID)
}

func (s *SQLiteStore) GetMessageReactionIDs(msgID, userID string) ([]string, error) {
	rows, err := s.db.Query(
		"SELECT emoji_id FROM message_reactions WHERE message_id = ? AND user_id = ? ORDER BY emoji_id",
		msgID, userID,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var result []string
	for rows.Next() {
		var emojiID string
		if err := rows.Scan(&emojiID); err != nil {
			return nil, err
		}
		result = append(result, emojiID)
	}
	return result, rows.Err()
}

func (s *SQLiteStore) loadReactionCounts(msgID string) ([]protocol.Reaction, error) {
	rows, err := s.db.Query(
		"SELECT emoji_id, COUNT(*) FROM message_reactions WHERE message_id = ? GROUP BY emoji_id ORDER BY emoji_id",
		msgID,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var result []protocol.Reaction
	for rows.Next() {
		var reaction protocol.Reaction
		if err := rows.Scan(&reaction.EmojiID, &reaction.Count); err != nil {
			return nil, err
		}
		result = append(result, reaction)
	}
	return result, rows.Err()
}

func (s *SQLiteStore) RecallMessage(msgID string) (bool, error) {
	result, err := s.db.Exec("UPDATE messages SET recalled = TRUE WHERE id = ?", msgID)
	if err != nil {
		return false, err
	}
	rows, err := result.RowsAffected()
	if err != nil {
		return false, err
	}
	return rows > 0, nil
}

// ---- Group operations ----

func (s *SQLiteStore) CreateGroup(id, name, avatar, ownerID string) (*Group, error) {
	_, err := s.db.Exec(
		"INSERT INTO groups (id, name, avatar_url, owner_id) VALUES (?, ?, ?, ?)",
		id, name, avatar, ownerID,
	)
	if err != nil {
		return nil, err
	}

	// Add owner as member
	_, err = s.db.Exec(
		"INSERT INTO group_members (group_id, user_id, role) VALUES (?, ?, 'owner')",
		id, ownerID,
	)
	if err != nil {
		return nil, err
	}

	return s.GetGroup(id)
}

func (s *SQLiteStore) GetGroup(id string) (*Group, error) {
	group := &Group{}
	err := s.db.QueryRow(
		"SELECT id, name, avatar_url, announcement, owner_id, mute_all, created_at FROM groups WHERE id = ?",
		id,
	).Scan(&group.ID, &group.Name, &group.Avatar, &group.Announcement, &group.OwnerID, &group.MuteAll, &group.CreatedAt)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}

	// Load members
	members, err := s.GetGroupMembers(id)
	if err != nil {
		return nil, err
	}
	group.Members = members

	return group, nil
}

func (s *SQLiteStore) GetGroups() ([]*Group, error) {
	rows, err := s.db.Query("SELECT id, name, avatar_url, announcement, owner_id, mute_all, created_at FROM groups")
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var groups []*Group
	for rows.Next() {
		group := &Group{}
		if err := rows.Scan(&group.ID, &group.Name, &group.Avatar, &group.Announcement, &group.OwnerID, &group.MuteAll, &group.CreatedAt); err != nil {
			return nil, err
		}
		members, err := s.GetGroupMembers(group.ID)
		if err != nil {
			return nil, err
		}
		group.Members = members
		groups = append(groups, group)
	}
	return groups, nil
}

func (s *SQLiteStore) GetUserGroups(userID string) ([]*Group, error) {
	rows, err := s.db.Query(
		`SELECT g.id, g.name, g.avatar_url, g.announcement, g.owner_id, g.mute_all, g.created_at
		 FROM groups g
		 JOIN group_members gm ON g.id = gm.group_id
		 WHERE gm.user_id = ?`,
		userID,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var groups []*Group
	for rows.Next() {
		group := &Group{}
		if err := rows.Scan(&group.ID, &group.Name, &group.Avatar, &group.Announcement, &group.OwnerID, &group.MuteAll, &group.CreatedAt); err != nil {
			return nil, err
		}
		members, err := s.GetGroupMembers(group.ID)
		if err != nil {
			return nil, err
		}
		group.Members = members
		groups = append(groups, group)
	}
	return groups, nil
}

func (s *SQLiteStore) UpdateGroup(groupID, name, avatar, announcement string, muteAll bool) error {
	result, err := s.db.Exec(
		"UPDATE groups SET name = ?, avatar_url = ?, announcement = ?, mute_all = ? WHERE id = ?",
		name, avatar, announcement, muteAll, groupID,
	)
	if err != nil {
		return err
	}
	rows, err := result.RowsAffected()
	if err != nil {
		return err
	}
	if rows == 0 {
		return sql.ErrNoRows
	}
	return nil
}

func (s *SQLiteStore) SetGroupMemberRole(groupID, userID, role string) error {
	result, err := s.db.Exec(
		"UPDATE group_members SET role = ? WHERE group_id = ? AND user_id = ?",
		role, groupID, userID,
	)
	if err != nil {
		return err
	}
	rows, err := result.RowsAffected()
	if err != nil {
		return err
	}
	if rows == 0 {
		return sql.ErrNoRows
	}
	return nil
}

func (s *SQLiteStore) SetGroupMemberMute(groupID, userID string, mutedUntil time.Time) error {
	var value interface{}
	if !mutedUntil.IsZero() {
		value = mutedUntil
	}
	result, err := s.db.Exec(
		"UPDATE group_members SET muted_until = ? WHERE group_id = ? AND user_id = ?",
		value, groupID, userID,
	)
	if err != nil {
		return err
	}
	rows, err := result.RowsAffected()
	if err != nil {
		return err
	}
	if rows == 0 {
		return sql.ErrNoRows
	}
	return nil
}

func (s *SQLiteStore) TransferGroupOwnership(groupID, currentOwnerID, newOwnerID string) error {
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var targetRole string
	if err := tx.QueryRow(
		"SELECT role FROM group_members WHERE group_id = ? AND user_id = ?",
		groupID, newOwnerID,
	).Scan(&targetRole); err != nil {
		return err
	}
	if targetRole != "member" && targetRole != "admin" {
		return fmt.Errorf("invalid new owner")
	}
	result, err := tx.Exec(
		"UPDATE groups SET owner_id = ? WHERE id = ? AND owner_id = ?",
		newOwnerID, groupID, currentOwnerID,
	)
	if err != nil {
		return err
	}
	rows, err := result.RowsAffected()
	if err != nil || rows != 1 {
		return fmt.Errorf("group owner mismatch")
	}
	if _, err := tx.Exec(
		"UPDATE group_members SET role = 'member' WHERE group_id = ? AND user_id = ?",
		groupID, currentOwnerID,
	); err != nil {
		return err
	}
	if _, err := tx.Exec(
		"UPDATE group_members SET role = 'owner', muted_until = NULL WHERE group_id = ? AND user_id = ?",
		groupID, newOwnerID,
	); err != nil {
		return err
	}
	return tx.Commit()
}

func (s *SQLiteStore) DeleteGroup(groupID string) error {
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	for _, statement := range []string{
		"DELETE FROM conversation_reads WHERE conversation_id = ?",
		"DELETE FROM messages WHERE conversation_id = ?",
		"DELETE FROM group_members WHERE group_id = ?",
		"DELETE FROM conversations WHERE id = ?",
	} {
		if _, err := tx.Exec(statement, groupID); err != nil {
			return err
		}
	}
	result, err := tx.Exec("DELETE FROM groups WHERE id = ?", groupID)
	if err != nil {
		return err
	}
	rows, err := result.RowsAffected()
	if err != nil || rows != 1 {
		return sql.ErrNoRows
	}
	return tx.Commit()
}

func (s *SQLiteStore) AddGroupMember(groupID, userID string) (bool, error) {
	result, err := s.db.Exec(
		"INSERT OR IGNORE INTO group_members (group_id, user_id) VALUES (?, ?)",
		groupID, userID,
	)
	if err != nil {
		return false, err
	}
	rows, err := result.RowsAffected()
	if err != nil {
		return false, err
	}
	return rows > 0, nil
}

func (s *SQLiteStore) RemoveGroupMember(groupID, userID string) (bool, error) {
	result, err := s.db.Exec(
		"DELETE FROM group_members WHERE group_id = ? AND user_id = ?",
		groupID, userID,
	)
	if err != nil {
		return false, err
	}
	rows, err := result.RowsAffected()
	if err != nil {
		return false, err
	}
	return rows > 0, nil
}

func (s *SQLiteStore) IsGroupMember(groupID, userID string) (bool, error) {
	var count int
	err := s.db.QueryRow(
		"SELECT COUNT(*) FROM group_members WHERE group_id = ? AND user_id = ?",
		groupID, userID,
	).Scan(&count)
	if err != nil {
		return false, err
	}
	return count > 0, nil
}

func (s *SQLiteStore) GetGroupMembers(groupID string) ([]*GroupMember, error) {
	rows, err := s.db.Query(
		"SELECT user_id, role, joined_at, muted_until FROM group_members WHERE group_id = ?",
		groupID,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var members []*GroupMember
	for rows.Next() {
		member := &GroupMember{}
		var mutedUntil sql.NullTime
		if err := rows.Scan(&member.UserID, &member.Role, &member.JoinedAt, &mutedUntil); err != nil {
			return nil, err
		}
		if mutedUntil.Valid {
			member.MutedUntil = mutedUntil.Time
		}
		members = append(members, member)
	}
	return members, nil
}

// ---- Friend request operations ----

func (s *SQLiteStore) GetFriends(userID string) ([]*User, error) {
	rows, err := s.db.Query(`
		SELECT u.id, u.nickname, u.avatar_url, u.online, u.password_hash, u.created_at
		FROM friendships f
		JOIN users u ON u.id = f.friend_id
		WHERE f.user_id = ?
		ORDER BY u.nickname COLLATE NOCASE, u.id`, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	users := make([]*User, 0)
	for rows.Next() {
		user := &User{}
		if err := rows.Scan(&user.ID, &user.Nickname, &user.Avatar, &user.Online, &user.PasswordHash, &user.CreatedAt); err != nil {
			return nil, err
		}
		users = append(users, user)
	}
	return users, rows.Err()
}

func (s *SQLiteStore) AreFriends(userID, friendID string) (bool, error) {
	var count int
	err := s.db.QueryRow(
		"SELECT COUNT(*) FROM friendships WHERE user_id = ? AND friend_id = ?",
		userID, friendID,
	).Scan(&count)
	return count > 0, err
}

func (s *SQLiteStore) AddFriend(userID, friendID string) (bool, error) {
	if userID == "" || friendID == "" || userID == friendID {
		return false, nil
	}
	tx, err := s.db.Begin()
	if err != nil {
		return false, err
	}
	defer tx.Rollback()
	result, err := tx.Exec(
		"INSERT OR IGNORE INTO friendships (user_id, friend_id) VALUES (?, ?)",
		userID, friendID,
	)
	if err != nil {
		return false, err
	}
	if _, err := tx.Exec(
		"INSERT OR IGNORE INTO friendships (user_id, friend_id) VALUES (?, ?)",
		friendID, userID,
	); err != nil {
		return false, err
	}
	rows, err := result.RowsAffected()
	if err != nil {
		return false, err
	}
	if err := tx.Commit(); err != nil {
		return false, err
	}
	return rows > 0, nil
}

func (s *SQLiteStore) RemoveFriend(userID, friendID string) (bool, error) {
	tx, err := s.db.Begin()
	if err != nil {
		return false, err
	}
	defer tx.Rollback()
	result, err := tx.Exec(
		"DELETE FROM friendships WHERE user_id = ? AND friend_id = ?",
		userID, friendID,
	)
	if err != nil {
		return false, err
	}
	if _, err := tx.Exec(
		"DELETE FROM friendships WHERE user_id = ? AND friend_id = ?",
		friendID, userID,
	); err != nil {
		return false, err
	}
	rows, err := result.RowsAffected()
	if err != nil {
		return false, err
	}
	if err := tx.Commit(); err != nil {
		return false, err
	}
	return rows > 0, nil
}

func (s *SQLiteStore) CreateFriendRequest(fromID, toID, comment string) (*FriendRequest, error) {
	req := &FriendRequest{
		ID:        fmt.Sprintf("freq_%d", time.Now().UnixNano()),
		FromID:    fromID,
		ToID:      toID,
		Comment:   comment,
		Status:    "pending",
		CreatedAt: time.Now(),
	}

	_, err := s.db.Exec(
		"INSERT INTO friend_requests (id, from_id, to_id, comment, status) VALUES (?, ?, ?, ?, ?)",
		req.ID, req.FromID, req.ToID, req.Comment, req.Status,
	)
	if err != nil {
		return nil, err
	}

	return req, nil
}

func (s *SQLiteStore) GetFriendRequest(id string) (*FriendRequest, error) {
	req := &FriendRequest{}
	err := s.db.QueryRow(
		"SELECT id, from_id, to_id, comment, status, created_at FROM friend_requests WHERE id = ?",
		id,
	).Scan(&req.ID, &req.FromID, &req.ToID, &req.Comment, &req.Status, &req.CreatedAt)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return req, nil
}

func (s *SQLiteStore) GetPendingFriendRequests(userID string) ([]*FriendRequest, error) {
	rows, err := s.db.Query(
		"SELECT id, from_id, to_id, comment, status, created_at FROM friend_requests WHERE (to_id = ? OR from_id = ?) AND status = 'pending' ORDER BY created_at DESC",
		userID,
		userID,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var reqs []*FriendRequest
	for rows.Next() {
		req := &FriendRequest{}
		if err := rows.Scan(&req.ID, &req.FromID, &req.ToID, &req.Comment, &req.Status, &req.CreatedAt); err != nil {
			return nil, err
		}
		reqs = append(reqs, req)
	}
	return reqs, nil
}

func (s *SQLiteStore) HandleFriendRequest(reqID, action string) (bool, error) {
	result, err := s.db.Exec(
		"UPDATE friend_requests SET status = ? WHERE id = ? AND status = 'pending'",
		action, reqID,
	)
	if err != nil {
		return false, err
	}
	rows, err := result.RowsAffected()
	if err != nil {
		return false, err
	}
	return rows > 0, nil
}

// ---- Forward message operations ----

func (s *SQLiteStore) StoreForward(messages []*Message) (*ForwardMessage, error) {
	messagesJSON, err := json.Marshal(messages)
	if err != nil {
		return nil, err
	}

	forward := &ForwardMessage{
		ID:        fmt.Sprintf("fwd_%d", time.Now().UnixNano()),
		Messages:  messages,
		CreatedAt: time.Now(),
	}

	_, err = s.db.Exec(
		"INSERT INTO forwards (id, messages) VALUES (?, ?)",
		forward.ID, string(messagesJSON),
	)
	if err != nil {
		return nil, err
	}

	return forward, nil
}

func (s *SQLiteStore) GetForward(id string) (*ForwardMessage, error) {
	forward := &ForwardMessage{}
	var messagesJSON string
	err := s.db.QueryRow(
		"SELECT id, messages, created_at FROM forwards WHERE id = ?",
		id,
	).Scan(&forward.ID, &messagesJSON, &forward.CreatedAt)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	json.Unmarshal([]byte(messagesJSON), &forward.Messages)
	return forward, nil
}

// ---- Media operations ----

func (s *SQLiteStore) StoreMedia(file *MediaFile) error {
	_, err := s.db.Exec(
		"INSERT INTO media_files (id, file_name, file_type, mime_type, size, url, uploader_id) VALUES (?, ?, ?, ?, ?, ?, ?)",
		file.ID, file.FileName, file.FileType, file.MimeType, file.Size, file.URL, file.UploaderID,
	)
	return err
}

func (s *SQLiteStore) GetMedia(id string) (*MediaFile, error) {
	file := &MediaFile{}
	err := s.db.QueryRow(
		"SELECT id, file_name, file_type, mime_type, size, url, uploader_id, created_at FROM media_files WHERE id = ?",
		id,
	).Scan(&file.ID, &file.FileName, &file.FileType, &file.MimeType, &file.Size, &file.URL, &file.UploaderID, &file.CreatedAt)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return file, nil
}

func (s *SQLiteStore) GetMediaFiles(limit int) ([]*MediaFile, error) {
	if limit <= 0 {
		limit = 200
	}
	rows, err := s.db.Query(
		"SELECT id, file_name, file_type, mime_type, size, url, uploader_id, created_at FROM media_files ORDER BY created_at DESC, id DESC LIMIT ?",
		limit,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var files []*MediaFile
	for rows.Next() {
		file := &MediaFile{}
		if err := rows.Scan(&file.ID, &file.FileName, &file.FileType, &file.MimeType, &file.Size, &file.URL, &file.UploaderID, &file.CreatedAt); err != nil {
			return nil, err
		}
		files = append(files, file)
	}
	return files, rows.Err()
}

func (s *SQLiteStore) DeleteMedia(id string) error {
	_, err := s.db.Exec("DELETE FROM media_files WHERE id = ?", id)
	return err
}
