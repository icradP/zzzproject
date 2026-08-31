package store

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"time"

	"github.com/icradp/zzz-im-server/internal/protocol"
	_ "github.com/lib/pq"
)

// PostgresStore implements Store using PostgreSQL.
type PostgresStore struct {
	db *sql.DB
}

// NewPostgresStore creates a new PostgreSQL store.
func NewPostgresStore(dsn string) (*PostgresStore, error) {
	db, err := sql.Open("postgres", dsn)
	if err != nil {
		return nil, fmt.Errorf("failed to open database: %w", err)
	}

	if err := db.Ping(); err != nil {
		return nil, fmt.Errorf("failed to ping database: %w", err)
	}

	store := &PostgresStore{db: db}
	if err := store.initSchema(); err != nil {
		return nil, fmt.Errorf("failed to initialize schema: %w", err)
	}

	return store, nil
}

// initSchema creates the database tables.
func (s *PostgresStore) initSchema() error {
	schema := `
	CREATE TABLE IF NOT EXISTS users (
		id VARCHAR(32) PRIMARY KEY,
		nickname VARCHAR(64) NOT NULL,
		avatar_url TEXT DEFAULT '',
		password_hash TEXT DEFAULT '',
		online BOOLEAN DEFAULT FALSE,
		created_at TIMESTAMP DEFAULT NOW()
	);

	CREATE TABLE IF NOT EXISTS conversations (
		id VARCHAR(32) PRIMARY KEY,
		type VARCHAR(20) NOT NULL,
		title VARCHAR(128) NOT NULL,
		avatar_url TEXT DEFAULT '',
		owner_id VARCHAR(32) DEFAULT '',
		participants JSONB DEFAULT '[]',
		created_at TIMESTAMP DEFAULT NOW()
	);

	CREATE TABLE IF NOT EXISTS sessions (
		token_hash TEXT PRIMARY KEY,
		user_id VARCHAR(32) NOT NULL,
		expires_at TIMESTAMP NOT NULL,
		created_at TIMESTAMP DEFAULT NOW()
	);

	CREATE INDEX IF NOT EXISTS idx_sessions_expires_at ON sessions(expires_at);

	CREATE TABLE IF NOT EXISTS messages (
		id VARCHAR(32) PRIMARY KEY,
		conversation_id VARCHAR(32) NOT NULL,
		sender_id VARCHAR(32) NOT NULL,
		sender_nickname VARCHAR(64) NOT NULL,
		segments JSONB NOT NULL,
		content_text TEXT,
		content_type VARCHAR(20),
		recalled BOOLEAN DEFAULT FALSE,
		created_at TIMESTAMP DEFAULT NOW()
	);

	CREATE INDEX IF NOT EXISTS idx_messages_conversation ON messages(conversation_id, created_at DESC);
	CREATE INDEX IF NOT EXISTS idx_messages_sender ON messages(sender_id);
	CREATE INDEX IF NOT EXISTS idx_messages_content_text ON messages USING GIN (to_tsvector('simple', COALESCE(content_text, '')));

	CREATE TABLE IF NOT EXISTS groups (
		id VARCHAR(32) PRIMARY KEY,
		name VARCHAR(128) NOT NULL,
		avatar_url TEXT DEFAULT '',
		owner_id VARCHAR(32) NOT NULL,
		created_at TIMESTAMP DEFAULT NOW()
	);

	CREATE TABLE IF NOT EXISTS group_members (
		group_id VARCHAR(32),
		user_id VARCHAR(32),
		role VARCHAR(20) DEFAULT 'member',
		joined_at TIMESTAMP DEFAULT NOW(),
		PRIMARY KEY (group_id, user_id)
	);

	CREATE TABLE IF NOT EXISTS friend_requests (
		id VARCHAR(32) PRIMARY KEY,
		from_id VARCHAR(32) NOT NULL,
		to_id VARCHAR(32) NOT NULL,
		comment TEXT DEFAULT '',
		status VARCHAR(20) DEFAULT 'pending',
		created_at TIMESTAMP DEFAULT NOW()
	);

	CREATE INDEX IF NOT EXISTS idx_friend_requests_to ON friend_requests(to_id, status);

	CREATE TABLE IF NOT EXISTS forwards (
		id VARCHAR(32) PRIMARY KEY,
		messages JSONB NOT NULL,
		created_at TIMESTAMP DEFAULT NOW()
	);

	CREATE TABLE IF NOT EXISTS media_files (
		id VARCHAR(64) PRIMARY KEY,
		file_name VARCHAR(256) NOT NULL,
		file_type VARCHAR(20) NOT NULL,
		mime_type VARCHAR(64) DEFAULT '',
		size BIGINT DEFAULT 0,
		url TEXT NOT NULL,
		uploader_id VARCHAR(32) NOT NULL,
		created_at TIMESTAMP DEFAULT NOW()
	);

	CREATE TABLE IF NOT EXISTS push_subscriptions (
		user_id VARCHAR(32) NOT NULL,
		endpoint TEXT NOT NULL,
		p256dh TEXT NOT NULL,
		auth TEXT NOT NULL,
		created_at TIMESTAMP DEFAULT NOW(),
		updated_at TIMESTAMP DEFAULT NOW(),
		PRIMARY KEY (user_id, endpoint)
	);

	CREATE INDEX IF NOT EXISTS idx_push_subscriptions_user ON push_subscriptions(user_id);
	`

	_, err := s.db.Exec(schema)
	if err != nil {
		return err
	}
	_, err = s.db.Exec("ALTER TABLE users ADD COLUMN IF NOT EXISTS password_hash TEXT DEFAULT ''")
	return err
}

// Close closes the database connection.
func (s *PostgresStore) Close() error {
	return s.db.Close()
}

// ---- User operations ----

func (s *PostgresStore) GetUser(id string) (*User, error) {
	user := &User{}
	err := s.db.QueryRow(
		"SELECT id, nickname, avatar_url, online, password_hash, created_at FROM users WHERE id = $1",
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

func (s *PostgresStore) SetUser(user *User) error {
	_, err := s.db.Exec(
		`INSERT INTO users (id, nickname, avatar_url, online, password_hash)
		 VALUES ($1, $2, $3, $4, $5)
		 ON CONFLICT (id) DO UPDATE SET nickname = $2, avatar_url = $3, online = $4, password_hash = $5`,
		user.ID, user.Nickname, user.Avatar, user.Online, user.PasswordHash,
	)
	return err
}

func (s *PostgresStore) GetUsers() ([]*User, error) {
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

func (s *PostgresStore) SetUserOnline(id string, online bool) error {
	_, err := s.db.Exec("UPDATE users SET online = $1 WHERE id = $2", online, id)
	return err
}

// ---- Conversation operations ----

func (s *PostgresStore) GetOrCreateConversation(id, convType, title string) (*Conversation, error) {
	conv, err := s.GetConversation(id)
	if err != nil {
		return nil, err
	}
	if conv != nil {
		return conv, nil
	}

	participantsJSON, _ := json.Marshal([]string{})
	_, err = s.db.Exec(
		`INSERT INTO conversations (id, type, title, participants)
		 VALUES ($1, $2, $3, $4)
		 ON CONFLICT (id) DO NOTHING`,
		id, convType, title, string(participantsJSON),
	)
	if err != nil {
		return nil, err
	}

	return s.GetConversation(id)
}

func (s *PostgresStore) SaveConversation(conversation *Conversation) error {
	participants, err := json.Marshal(conversation.Participants)
	if err != nil {
		return err
	}
	_, err = s.db.Exec(`
		INSERT INTO conversations (id, type, title, avatar_url, owner_id, participants)
		VALUES ($1, $2, $3, $4, $5, $6)
		ON CONFLICT (id) DO UPDATE SET
			type = EXCLUDED.type,
			title = EXCLUDED.title,
			avatar_url = EXCLUDED.avatar_url,
			owner_id = EXCLUDED.owner_id,
			participants = EXCLUDED.participants`,
		conversation.ID, conversation.Type, conversation.Title,
		conversation.Avatar, conversation.OwnerID, string(participants),
	)
	return err
}

func (s *PostgresStore) GetConversation(id string) (*Conversation, error) {
	conv := &Conversation{}
	var participantsJSON string
	err := s.db.QueryRow(
		"SELECT id, type, title, avatar_url, owner_id, participants, created_at FROM conversations WHERE id = $1",
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

func (s *PostgresStore) GetConversations() ([]*Conversation, error) {
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

func (s *PostgresStore) GetUserConversations(userID string) ([]*Conversation, error) {
	rows, err := s.db.Query(
		`SELECT id, type, title, avatar_url, owner_id, participants, created_at
		 FROM conversations
		 WHERE type = 'private' AND participants::jsonb ? $1
		 UNION
		 SELECT c.id, c.type, c.title, c.avatar_url, c.owner_id, c.participants, c.created_at
		 FROM conversations c
		 JOIN group_members gm ON c.id = gm.group_id
		 WHERE gm.user_id = $1`,
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

func (s *PostgresStore) DeleteConversation(id string) error {
	_, err := s.db.Exec("DELETE FROM messages WHERE conversation_id = $1", id)
	if err != nil {
		return err
	}
	_, err = s.db.Exec("DELETE FROM conversations WHERE id = $1", id)
	return err
}

// ---- Message operations ----

func (s *PostgresStore) StoreMessage(convID, senderID, senderNickname string, segments []protocol.MessageSegment) (*Message, error) {
	segmentsJSON, err := json.Marshal(segments)
	if err != nil {
		return nil, err
	}

	// Extract content text and type for indexing
	contentText := ""
	contentType := "text"
	for _, seg := range segments {
		switch seg.Type {
		case "text":
			if t, ok := seg.Data["text"].(string); ok {
				contentText += t
			}
		case "image":
			contentType = "image"
		case "record":
			contentType = "voice"
		case "video":
			contentType = "video"
		case "file":
			contentType = "file"
		}
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
		`INSERT INTO messages (id, conversation_id, sender_id, sender_nickname, segments, content_text, content_type, recalled, created_at)
		 VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)`,
		msg.ID, msg.ConversationID, msg.SenderID, msg.SenderNickname,
		string(segmentsJSON), contentText, contentType, msg.Recalled, msg.Timestamp,
	)
	if err != nil {
		return nil, err
	}

	return msg, nil
}

func (s *PostgresStore) GetMessage(msgID string) (*Message, error) {
	msg := &Message{}
	var segmentsJSON string
	err := s.db.QueryRow(
		"SELECT id, conversation_id, sender_id, sender_nickname, segments, recalled, created_at FROM messages WHERE id = $1",
		msgID,
	).Scan(&msg.ID, &msg.ConversationID, &msg.SenderID, &msg.SenderNickname, &segmentsJSON, &msg.Recalled, &msg.Timestamp)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	json.Unmarshal([]byte(segmentsJSON), &msg.Segments)
	return msg, nil
}

func (s *PostgresStore) GetMessages(convID string, limit int) ([]*Message, error) {
	rows, err := s.db.Query(
		"SELECT id, conversation_id, sender_id, sender_nickname, segments, recalled, created_at FROM messages WHERE conversation_id = $1 ORDER BY created_at DESC LIMIT $2",
		convID, limit,
	)
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
		msgs = append(msgs, msg)
	}

	// Reverse to chronological order
	for i, j := 0, len(msgs)-1; i < j; i, j = i+1, j-1 {
		msgs[i], msgs[j] = msgs[j], msgs[i]
	}

	return msgs, nil
}

func (s *PostgresStore) RecallMessage(msgID string) (bool, error) {
	result, err := s.db.Exec("UPDATE messages SET recalled = TRUE WHERE id = $1", msgID)
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

func (s *PostgresStore) CreateGroup(id, name, avatar, ownerID string) (*Group, error) {
	_, err := s.db.Exec(
		"INSERT INTO groups (id, name, avatar_url, owner_id) VALUES ($1, $2, $3, $4)",
		id, name, avatar, ownerID,
	)
	if err != nil {
		return nil, err
	}

	_, err = s.db.Exec(
		"INSERT INTO group_members (group_id, user_id, role) VALUES ($1, $2, 'owner')",
		id, ownerID,
	)
	if err != nil {
		return nil, err
	}

	return s.GetGroup(id)
}

func (s *PostgresStore) GetGroup(id string) (*Group, error) {
	group := &Group{}
	err := s.db.QueryRow(
		"SELECT id, name, avatar_url, owner_id, created_at FROM groups WHERE id = $1",
		id,
	).Scan(&group.ID, &group.Name, &group.Avatar, &group.OwnerID, &group.CreatedAt)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}

	members, err := s.GetGroupMembers(id)
	if err != nil {
		return nil, err
	}
	group.Members = members

	return group, nil
}

func (s *PostgresStore) GetGroups() ([]*Group, error) {
	rows, err := s.db.Query("SELECT id, name, avatar_url, owner_id, created_at FROM groups")
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var groups []*Group
	for rows.Next() {
		group := &Group{}
		if err := rows.Scan(&group.ID, &group.Name, &group.Avatar, &group.OwnerID, &group.CreatedAt); err != nil {
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

func (s *PostgresStore) GetUserGroups(userID string) ([]*Group, error) {
	rows, err := s.db.Query(
		`SELECT g.id, g.name, g.avatar_url, g.owner_id, g.created_at
		 FROM groups g
		 JOIN group_members gm ON g.id = gm.group_id
		 WHERE gm.user_id = $1`,
		userID,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var groups []*Group
	for rows.Next() {
		group := &Group{}
		if err := rows.Scan(&group.ID, &group.Name, &group.Avatar, &group.OwnerID, &group.CreatedAt); err != nil {
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

func (s *PostgresStore) AddGroupMember(groupID, userID string) (bool, error) {
	result, err := s.db.Exec(
		"INSERT INTO group_members (group_id, user_id) VALUES ($1, $2) ON CONFLICT DO NOTHING",
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

func (s *PostgresStore) RemoveGroupMember(groupID, userID string) (bool, error) {
	result, err := s.db.Exec(
		"DELETE FROM group_members WHERE group_id = $1 AND user_id = $2",
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

func (s *PostgresStore) IsGroupMember(groupID, userID string) (bool, error) {
	var count int
	err := s.db.QueryRow(
		"SELECT COUNT(*) FROM group_members WHERE group_id = $1 AND user_id = $2",
		groupID, userID,
	).Scan(&count)
	if err != nil {
		return false, err
	}
	return count > 0, nil
}

func (s *PostgresStore) GetGroupMembers(groupID string) ([]*GroupMember, error) {
	rows, err := s.db.Query(
		"SELECT user_id, role, joined_at FROM group_members WHERE group_id = $1",
		groupID,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var members []*GroupMember
	for rows.Next() {
		member := &GroupMember{}
		if err := rows.Scan(&member.UserID, &member.Role, &member.JoinedAt); err != nil {
			return nil, err
		}
		members = append(members, member)
	}
	return members, nil
}

// ---- Friend request operations ----

func (s *PostgresStore) CreateFriendRequest(fromID, toID, comment string) (*FriendRequest, error) {
	req := &FriendRequest{
		ID:        fmt.Sprintf("freq_%d", time.Now().UnixNano()),
		FromID:    fromID,
		ToID:      toID,
		Comment:   comment,
		Status:    "pending",
		CreatedAt: time.Now(),
	}

	_, err := s.db.Exec(
		"INSERT INTO friend_requests (id, from_id, to_id, comment, status) VALUES ($1, $2, $3, $4, $5)",
		req.ID, req.FromID, req.ToID, req.Comment, req.Status,
	)
	if err != nil {
		return nil, err
	}

	return req, nil
}

func (s *PostgresStore) GetFriendRequest(id string) (*FriendRequest, error) {
	req := &FriendRequest{}
	err := s.db.QueryRow(
		"SELECT id, from_id, to_id, comment, status, created_at FROM friend_requests WHERE id = $1",
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

func (s *PostgresStore) GetPendingFriendRequests(userID string) ([]*FriendRequest, error) {
	rows, err := s.db.Query(
		"SELECT id, from_id, to_id, comment, status, created_at FROM friend_requests WHERE to_id = $1 AND status = 'pending'",
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

func (s *PostgresStore) HandleFriendRequest(reqID, action string) (bool, error) {
	result, err := s.db.Exec(
		"UPDATE friend_requests SET status = $1 WHERE id = $2 AND status = 'pending'",
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

func (s *PostgresStore) StoreForward(messages []*Message) (*ForwardMessage, error) {
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
		"INSERT INTO forwards (id, messages) VALUES ($1, $2)",
		forward.ID, string(messagesJSON),
	)
	if err != nil {
		return nil, err
	}

	return forward, nil
}

func (s *PostgresStore) GetForward(id string) (*ForwardMessage, error) {
	forward := &ForwardMessage{}
	var messagesJSON string
	err := s.db.QueryRow(
		"SELECT id, messages, created_at FROM forwards WHERE id = $1",
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

func (s *PostgresStore) StoreMedia(file *MediaFile) error {
	_, err := s.db.Exec(
		`INSERT INTO media_files (id, file_name, file_type, mime_type, size, url, uploader_id)
		 VALUES ($1, $2, $3, $4, $5, $6, $7)
		 ON CONFLICT (id) DO UPDATE SET file_name = $2, url = $6`,
		file.ID, file.FileName, file.FileType, file.MimeType, file.Size, file.URL, file.UploaderID,
	)
	return err
}

func (s *PostgresStore) GetMedia(id string) (*MediaFile, error) {
	file := &MediaFile{}
	err := s.db.QueryRow(
		"SELECT id, file_name, file_type, mime_type, size, url, uploader_id, created_at FROM media_files WHERE id = $1",
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

func (s *PostgresStore) DeleteMedia(id string) error {
	_, err := s.db.Exec("DELETE FROM media_files WHERE id = $1", id)
	return err
}
