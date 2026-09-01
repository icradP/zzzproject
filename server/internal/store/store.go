package store

import (
	"time"

	"github.com/icradp/zzz-im-server/internal/protocol"
)

// Store defines the storage interface for the IM server.
// Implementations can be MemoryStore, MySQLStore, SQLiteStore, etc.
type Store interface {
	// ---- User operations ----
	GetUser(id string) (*User, error)
	SetUser(user *User) error
	GetUsers() ([]*User, error)
	SetUserOnline(id string, online bool) error
	GetServerStats() (*ServerStats, error)

	// ---- Account session operations ----
	UpsertSession(session *Session) error
	GetSession(tokenHash string) (*Session, error)
	DeleteSession(tokenHash string) error

	// ---- Conversation operations ----
	GetOrCreateConversation(id, convType, title string) (*Conversation, error)
	SaveConversation(conversation *Conversation) error
	GetConversation(id string) (*Conversation, error)
	GetConversations() ([]*Conversation, error)
	GetUserConversations(userID string) ([]*Conversation, error)
	GetConversationPreference(conversationID, userID string) (*ConversationPreference, error)
	SetConversationPreference(preference *ConversationPreference) error
	DeleteConversation(id string) error

	// ---- Message operations ----
	StoreMessage(convID, senderID, senderNickname string, segments []protocol.MessageSegment) (*Message, error)
	GetMessage(msgID string) (*Message, error)
	GetMessages(convID string, limit int) ([]*Message, error)
	GetMessagesBefore(convID, beforeMessageID string, limit int) ([]*Message, error)
	ReactToMessage(msgID, userID, emojiID string, remove bool) (*Message, error)
	GetMessageReactionIDs(msgID, userID string) ([]string, error)
	RecallMessage(msgID string) (bool, error)
	MarkConversationRead(conversationID, userID string) (*ReadState, error)
	GetConversationRead(conversationID, userID string) (*ReadState, error)
	GetConversationReadStates(conversationID string) ([]*ReadState, error)
	CountUnreadMessages(conversationID, userID string) (int, error)

	// ---- Group operations ----
	CreateGroup(id, name, avatar, ownerID string) (*Group, error)
	GetGroup(id string) (*Group, error)
	GetGroups() ([]*Group, error)
	GetUserGroups(userID string) ([]*Group, error)
	UpdateGroup(groupID, name, avatar, announcement string, muteAll bool) error
	SetGroupMemberRole(groupID, userID, role string) error
	SetGroupMemberMute(groupID, userID string, mutedUntil time.Time) error
	TransferGroupOwnership(groupID, currentOwnerID, newOwnerID string) error
	DeleteGroup(groupID string) error
	AddGroupMember(groupID, userID string) (bool, error)
	RemoveGroupMember(groupID, userID string) (bool, error)
	IsGroupMember(groupID, userID string) (bool, error)
	GetGroupMembers(groupID string) ([]*GroupMember, error)

	// ---- Friend request operations ----
	GetFriends(userID string) ([]*User, error)
	AreFriends(userID, friendID string) (bool, error)
	AddFriend(userID, friendID string) (bool, error)
	RemoveFriend(userID, friendID string) (bool, error)
	CreateFriendRequest(fromID, toID, comment string) (*FriendRequest, error)
	GetFriendRequest(id string) (*FriendRequest, error)
	GetPendingFriendRequests(userID string) ([]*FriendRequest, error)
	HandleFriendRequest(reqID, action string) (bool, error)

	// ---- Forward message operations ----
	StoreForward(messages []*Message) (*ForwardMessage, error)
	GetForward(id string) (*ForwardMessage, error)

	// ---- Media operations ----
	StoreMedia(file *MediaFile) error
	GetMedia(id string) (*MediaFile, error)
	DeleteMedia(id string) error

	// ---- Web Push operations ----
	UpsertPushSubscription(subscription *PushSubscription) error
	DeletePushSubscription(userID, endpoint string) error
	GetPushSubscriptions(userID string) ([]*PushSubscription, error)

	// ---- Lifecycle ----
	Close() error
}

// ServerStats contains aggregate operational counts for the admin console.
type ServerStats struct {
	Users             int   `json:"users"`
	OnlineUsers       int   `json:"online_users"`
	Groups            int   `json:"groups"`
	Conversations     int   `json:"conversations"`
	Messages          int   `json:"messages"`
	ActiveSessions    int   `json:"active_sessions"`
	MediaFiles        int   `json:"media_files"`
	MediaBytes        int64 `json:"media_bytes"`
	PushSubscriptions int   `json:"push_subscriptions"`
}

// Message represents a stored message.
type Message struct {
	ID             string                    `json:"id"`
	ConversationID string                    `json:"conversation_id"`
	SenderID       string                    `json:"sender_id"`
	SenderNickname string                    `json:"sender_nickname"`
	Segments       []protocol.MessageSegment `json:"segments"`
	Timestamp      time.Time                 `json:"timestamp"`
	Recalled       bool                      `json:"recalled"`
	Reactions      []protocol.Reaction       `json:"reactions,omitempty"`
}

// ReadState stores a user's durable read cursor within a conversation.
type ReadState struct {
	ConversationID    string    `json:"conversation_id"`
	UserID            string    `json:"user_id"`
	LastReadMessageID string    `json:"last_read_message_id,omitempty"`
	ReadAt            time.Time `json:"read_at"`
}

// Conversation represents a chat thread.
type Conversation struct {
	ID           string    `json:"id"`
	Type         string    `json:"type"` // "private" or "group"
	Title        string    `json:"title"`
	Avatar       string    `json:"avatar_url,omitempty"`
	OwnerID      string    `json:"owner_id,omitempty"`
	Participants []string  `json:"participants,omitempty"`
	CreatedAt    time.Time `json:"created_at"`
}

// ConversationPreference stores per-user inbox behavior for a conversation.
type ConversationPreference struct {
	ConversationID string    `json:"conversation_id"`
	UserID         string    `json:"user_id"`
	IsPinned       bool      `json:"is_pinned"`
	IsMuted        bool      `json:"is_muted"`
	UpdatedAt      time.Time `json:"updated_at"`
}

// User represents a user.
type User struct {
	ID           string    `json:"id"`
	Nickname     string    `json:"nickname"`
	Avatar       string    `json:"avatar_url,omitempty"`
	Online       bool      `json:"online"`
	PasswordHash string    `json:"-"`
	CreatedAt    time.Time `json:"created_at"`
}

// Session is a persisted account login. TokenHash is a SHA-256 digest; the
// opaque token sent to clients is never stored by the server.
type Session struct {
	TokenHash string    `json:"-"`
	UserID    string    `json:"user_id"`
	ExpiresAt time.Time `json:"expires_at"`
	CreatedAt time.Time `json:"created_at"`
}

// Group represents a group.
type Group struct {
	ID           string         `json:"id"`
	Name         string         `json:"name"`
	Avatar       string         `json:"avatar_url,omitempty"`
	Announcement string         `json:"announcement,omitempty"`
	OwnerID      string         `json:"owner_id"`
	MuteAll      bool           `json:"mute_all"`
	Members      []*GroupMember `json:"members,omitempty"`
	CreatedAt    time.Time      `json:"created_at"`
}

// GroupMember represents a member in a group.
type GroupMember struct {
	UserID     string    `json:"user_id"`
	Role       string    `json:"role"` // "owner", "admin", "member"
	JoinedAt   time.Time `json:"joined_at"`
	MutedUntil time.Time `json:"muted_until,omitempty"`
}

// FriendRequest represents a pending friend request.
type FriendRequest struct {
	ID        string    `json:"id"`
	FromID    string    `json:"from_id"`
	ToID      string    `json:"to_id"`
	Comment   string    `json:"comment,omitempty"`
	Status    string    `json:"status"` // "pending", "accepted", "rejected"
	CreatedAt time.Time `json:"created_at"`
}

// ForwardMessage represents a forwarded message group.
type ForwardMessage struct {
	ID        string     `json:"id"`
	Messages  []*Message `json:"messages"`
	CreatedAt time.Time  `json:"created_at"`
}

// MediaFile represents a stored media file.
type MediaFile struct {
	ID         string    `json:"id"`
	FileName   string    `json:"file_name"`
	FileType   string    `json:"file_type"` // "image", "voice", "video", "file"
	MimeType   string    `json:"mime_type"`
	Size       int64     `json:"size"`
	URL        string    `json:"url"`
	UploaderID string    `json:"uploader_id"`
	CreatedAt  time.Time `json:"created_at"`
}

// PushSubscription contains the browser keys required for Web Push delivery.
type PushSubscription struct {
	UserID    string    `json:"user_id"`
	Endpoint  string    `json:"endpoint"`
	P256DH    string    `json:"p256dh"`
	Auth      string    `json:"auth"`
	CreatedAt time.Time `json:"created_at"`
	UpdatedAt time.Time `json:"updated_at"`
}
