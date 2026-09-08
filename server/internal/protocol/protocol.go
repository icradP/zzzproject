package protocol

// MessageSegment represents a single message segment in OneBot-compatible format.
type MessageSegment struct {
	Type string                 `json:"type"`
	Data map[string]interface{} `json:"data"`
}

const (
	CurrentProtocolVersion         = "1.0"
	CurrentDynamicComponentVersion = "1.0"
)

// Capabilities are exchanged during authentication. ProtocolVersion covers
// the transport contract; DynamicContent keeps schema and component runtime
// versions separate so either can evolve independently.
type Capabilities struct {
	ProtocolVersion string                      `json:"protocol_version"`
	DynamicContent  *DynamicContentCapabilities `json:"dynamic_content,omitempty"`
}

type DynamicContentCapabilities struct {
	SchemaVersions    []string `json:"schema_versions"`
	ComponentVersion  string   `json:"component_version"`
	Components        []string `json:"components"`
	Events            bool     `json:"events"`
	NodeIDPatch       bool     `json:"node_id_patch"`
	ContentOperations bool     `json:"content_operations"`
}

func CurrentServerCapabilities() Capabilities {
	return Capabilities{
		ProtocolVersion: CurrentProtocolVersion,
		DynamicContent: &DynamicContentCapabilities{
			SchemaVersions:    []string{"1.0"},
			ComponentVersion:  CurrentDynamicComponentVersion,
			Components:        []string{},
			Events:            true,
			NodeIDPatch:       true,
			ContentOperations: true,
		},
	}
}

// Convenience constructors for message segments.

func TextSegment(text string) MessageSegment {
	return MessageSegment{
		Type: "text",
		Data: map[string]interface{}{"text": text},
	}
}

func ImageSegment(file string, url string) MessageSegment {
	return MessageSegment{
		Type: "image",
		Data: map[string]interface{}{"file": file, "url": url},
	}
}

func RecordSegment(file string, url string) MessageSegment {
	return MessageSegment{
		Type: "record",
		Data: map[string]interface{}{"file": file, "url": url},
	}
}

func VideoSegment(file string, url string) MessageSegment {
	return MessageSegment{
		Type: "video",
		Data: map[string]interface{}{"file": file, "url": url},
	}
}

func FileSegment(file string, url string) MessageSegment {
	return MessageSegment{
		Type: "file",
		Data: map[string]interface{}{"file": file, "url": url},
	}
}

func AtSegment(userID string) MessageSegment {
	return MessageSegment{
		Type: "at",
		Data: map[string]interface{}{"qq": userID},
	}
}

func ReplySegment(messageID string) MessageSegment {
	return MessageSegment{
		Type: "reply",
		Data: map[string]interface{}{"id": messageID},
	}
}

func ForwardSegment(forwardID string) MessageSegment {
	return MessageSegment{
		Type: "forward",
		Data: map[string]interface{}{"id": forwardID},
	}
}

func FaceSegment(faceID string) MessageSegment {
	return MessageSegment{
		Type: "face",
		Data: map[string]interface{}{"id": faceID},
	}
}

// DynamicContentSegment wraps a controlled JSON content tree. The server
// validates the tree before persisting it; clients resolve the component type
// through their local registry and never execute code from this payload.
func DynamicContentSegment(schema map[string]interface{}) MessageSegment {
	data := make(map[string]interface{}, len(schema))
	for key, value := range schema {
		if key == "type" {
			continue
		}
		data[key] = value
	}
	return MessageSegment{Type: "dynamic_content", Data: data}
}

// DynamicPatch is the wire representation of a node-id patch.
type DynamicPatch struct {
	Operation    string                 `json:"operation"`
	NodeID       string                 `json:"node_id"`
	ParentNodeID string                 `json:"parent_node_id,omitempty"`
	Index        *int                   `json:"index,omitempty"`
	Props        map[string]interface{} `json:"props,omitempty"`
	Node         map[string]interface{} `json:"node,omitempty"`
}

// DynamicUpdateSegment updates an existing dynamic_content segment in place.
// It is intentionally a message segment so the same transport works for
// realtime events and history replay, while the gateway keeps it out of the
// message store as a new message.
func DynamicUpdateSegment(messageID, contentID string, patches []DynamicPatch) MessageSegment {
	return MessageSegment{
		Type: "dynamic_update",
		Data: map[string]interface{}{
			"message_id": messageID,
			"content_id": contentID,
			"patches":    patches,
		},
	}
}

// DynamicReplaceSegment replaces one complete dynamic_content schema while
// preserving the parent message and content identities.
func DynamicReplaceSegment(messageID, contentID string, content map[string]interface{}) MessageSegment {
	return MessageSegment{
		Type: "dynamic_replace",
		Data: map[string]interface{}{
			"message_id": messageID,
			"content_id": contentID,
			"content":    content,
		},
	}
}

// DynamicRemoveSegment removes one complete dynamic_content segment from an
// existing message without deleting the surrounding message or its siblings.
func DynamicRemoveSegment(messageID, contentID string) MessageSegment {
	return MessageSegment{
		Type: "dynamic_remove",
		Data: map[string]interface{}{
			"message_id": messageID,
			"content_id": contentID,
		},
	}
}

// DynamicEventSegment carries a UI event through the normal message transport.
// The gateway validates and broadcasts it as a transient event; it is not a
// persisted chat message unless an application separately records an audit.
func DynamicEventSegment(messageID, contentID, nodeID, event, action string, payload map[string]interface{}) MessageSegment {
	data := map[string]interface{}{
		"message_id": messageID,
		"content_id": contentID,
		"node_id":    nodeID,
		"event":      event,
	}
	if action != "" {
		data["action"] = action
	}
	if payload != nil {
		data["payload"] = payload
	}
	return MessageSegment{Type: "dynamic_event", Data: data}
}

// TerminalRequestSegment asks an online ZZZ Term client to present a
// short-lived, locally approved operation. It is transported as an IM message
// so the requester and result remain visible in the conversation audit trail.
func TerminalRequestSegment(requestID, operation, hostID, command string, expiresAtMS int64) MessageSegment {
	data := map[string]interface{}{
		"request_id": requestID,
		"operation":  operation,
		"expires_at": expiresAtMS,
	}
	if hostID != "" {
		data["host_id"] = hostID
	}
	if command != "" {
		data["command"] = command
	}
	return MessageSegment{Type: "terminal_request", Data: data}
}

// Sender represents the message sender info.
type Sender struct {
	UserID   string `json:"user_id"`
	Nickname string `json:"nickname"`
	Avatar   string `json:"avatar_url,omitempty"`
}

// MessageEvent is pushed to clients when a new message arrives.
type MessageEvent struct {
	PostType       string           `json:"post_type"`
	MessageType    string           `json:"message_type"`
	MessageID      string           `json:"message_id"`
	ConversationID string           `json:"conversation_id"`
	Sender         Sender           `json:"sender"`
	Message        []MessageSegment `json:"message"`
	Reactions      []Reaction       `json:"reactions,omitempty"`
	Timestamp      int64            `json:"timestamp"`
	TimestampMS    int64            `json:"timestamp_ms"`
}

// Reaction is an aggregate reaction count attached to a message.
type Reaction struct {
	EmojiID string `json:"emoji_id"`
	Count   int    `json:"count"`
}

// NoticeType represents different notice event types.
type NoticeType string

const (
	NoticeTypeFriendAdd               NoticeType = "friend_add"
	NoticeTypeFriendRemove            NoticeType = "friend_remove"
	NoticeTypeFriendPresence          NoticeType = "friend_presence"
	NoticeTypeFriendRequestResult     NoticeType = "friend_request_result"
	NoticeTypeProfileUpdate           NoticeType = "profile_update"
	NoticeTypeFriendRecall            NoticeType = "friend_recall"
	NoticeTypeGroupRecall             NoticeType = "group_recall"
	NoticeTypeGroupIncrease           NoticeType = "group_increase"
	NoticeTypeGroupDecrease           NoticeType = "group_decrease"
	NoticeTypeGroupAdmin              NoticeType = "group_admin"
	NoticeTypeGroupBan                NoticeType = "group_ban"
	NoticeTypeGroupUpdate             NoticeType = "group_update"
	NoticeTypeGroupTransfer           NoticeType = "group_transfer"
	NoticeTypeGroupDismiss            NoticeType = "group_dismiss"
	NoticeTypeGroupMuteAll            NoticeType = "group_mute_all"
	NoticeTypeGroupAnnouncement       NoticeType = "group_announcement"
	NoticeTypePoke                    NoticeType = "poke"
	NoticeTypeMessageRead             NoticeType = "message_read"
	NoticeTypeMessageReaction         NoticeType = "message_reaction"
	NoticeTypeConversationPreferences NoticeType = "conversation_preferences"
)

// NoticeEvent is pushed for non-message events (recall, group changes, etc.).
type NoticeEvent struct {
	PostType          string     `json:"post_type"`
	NoticeType        NoticeType `json:"notice_type"`
	UserID            string     `json:"user_id,omitempty"`
	GroupID           string     `json:"group_id,omitempty"`
	MessageID         string     `json:"message_id,omitempty"`
	OperatorID        string     `json:"operator_id,omitempty"`
	TargetID          string     `json:"target_id,omitempty"`
	ConversationID    string     `json:"conversation_id,omitempty"`
	LastReadMessageID string     `json:"last_read_message_id,omitempty"`
	ReadAt            int64      `json:"read_at,omitempty"`
	SubType           string     `json:"sub_type,omitempty"`
	Duration          int64      `json:"duration,omitempty"`
	Enabled           bool       `json:"enabled,omitempty"`
	EmojiID           string     `json:"emoji_id,omitempty"`
	Removed           bool       `json:"removed,omitempty"`
	Online            *bool      `json:"online,omitempty"`
	IsPinned          *bool      `json:"is_pinned,omitempty"`
	IsMuted           *bool      `json:"is_muted,omitempty"`
	NotificationLevel string     `json:"notification_level,omitempty"`
	AnnouncementID    string     `json:"announcement_id,omitempty"`
	Action            string     `json:"action,omitempty"`
	Reactions         []Reaction `json:"reactions,omitempty"`
	Nickname          string     `json:"nickname,omitempty"`
	Avatar            string     `json:"avatar_url,omitempty"`
	ProfileVersion    int64      `json:"profile_version,omitempty"`
}

// RequestType represents different request event types.
type RequestType string

const (
	RequestTypeFriend RequestType = "friend"
	RequestTypeGroup  RequestType = "group"
)

// RequestEvent is pushed for friend/group requests.
type RequestEvent struct {
	PostType    string      `json:"post_type"`
	RequestType RequestType `json:"request_type"`
	UserID      string      `json:"user_id"`
	GroupID     string      `json:"group_id,omitempty"`
	Comment     string      `json:"comment,omitempty"`
	Flag        string      `json:"flag"`
}

// Request is a client -> server action.
type Request struct {
	Action string      `json:"action"`
	Params interface{} `json:"params,omitempty"`
	Echo   string      `json:"echo,omitempty"`
}

// Response is a server -> client reply.
type Response struct {
	Status  string      `json:"status"`
	RetCode int         `json:"retcode"`
	Data    interface{} `json:"data,omitempty"`
	Msg     string      `json:"msg,omitempty"`
	Echo    string      `json:"echo,omitempty"`
}

// Action types
const (
	ActionAuth                       = "auth"
	ActionRegister                   = "register"
	ActionLogout                     = "logout"
	ActionPing                       = "ping"
	ActionSendMessage                = "send_message"
	ActionEnsureConversation         = "ensure_conversation"
	ActionRecallMessage              = "recall_message"
	ActionReactMessage               = "react_message"
	ActionGetConversations           = "get_conversations"
	ActionSetConversationPreferences = "set_conversation_preferences"
	ActionGetMessages                = "get_messages"
	ActionMarkRead                   = "mark_read"
	ActionGetUser                    = "get_user"
	ActionUpdateProfile              = "update_profile"
	ActionGrantUserTitle             = "grant_user_title"
	ActionRevokeUserTitle            = "revoke_user_title"
	ActionSetUserBlocked             = "set_user_blocked"
	ActionReportUser                 = "report_user"
	ActionGetUsers                   = "get_users"
	ActionGetFriends                 = "get_friends"
	ActionSearchUsers                = "search_users"
	ActionGetFriendRequests          = "get_friend_requests"
	ActionRemoveFriend               = "remove_friend"
	ActionGetGroupList               = "get_group_list"
	ActionGetGroupInfo               = "get_group_info"
	ActionCreateGroup                = "create_group"
	ActionGroupInvite                = "group_invite"
	ActionJoinGroup                  = "join_group"
	ActionLeaveGroup                 = "leave_group"
	ActionGroupKick                  = "group_kick"
	ActionGroupBan                   = "group_ban"
	ActionUpdateGroup                = "update_group"
	ActionSetGroupAdmin              = "set_group_admin"
	ActionTransferGroup              = "transfer_group"
	ActionDismissGroup               = "dismiss_group"
	ActionGroupMuteAll               = "group_mute_all"
	ActionGetGroupAnnouncements      = "get_group_announcements"
	ActionCreateGroupAnnouncement    = "create_group_announcement"
	ActionUpdateGroupAnnouncement    = "update_group_announcement"
	ActionDeleteGroupAnnouncement    = "delete_group_announcement"
	ActionMarkGroupAnnouncementRead  = "mark_group_announcement_read"
	ActionFriendRequest              = "friend_request"
	ActionFriendHandle               = "friend_request_handle"
	ActionUploadFile                 = "upload_file"
	ActionCreateForward              = "create_forward"
	ActionGetForwardMessage          = "get_forward_msg"
	ActionGetPushConfig              = "get_push_config"
	ActionRegisterPush               = "register_push"
	ActionUnregisterPush             = "unregister_push"
	ActionGetTerminalVault           = "get_terminal_vault"
	ActionPutTerminalVault           = "put_terminal_vault"
	ActionDeleteTerminalVault        = "delete_terminal_vault"
)

// AuthParams are the params for the "auth" action.
type AuthParams struct {
	Token        string        `json:"token"`
	SessionToken string        `json:"session_token,omitempty"`
	Password     string        `json:"password,omitempty"`
	UserID       string        `json:"user_id,omitempty"`
	DeviceID     string        `json:"device_id"`
	Capabilities *Capabilities `json:"capabilities,omitempty"`
}

// RegisterParams are the params for the "register" action.
type RegisterParams struct {
	UserID         string `json:"user_id"`
	Password       string `json:"password"`
	Nickname       string `json:"nickname,omitempty"`
	InviteCode     string `json:"invite_code"`
	Avatar         string `json:"avatar_url,omitempty"`
	AvatarFile     string `json:"avatar_file,omitempty"`
	AvatarFileName string `json:"avatar_file_name,omitempty"`
	AvatarMimeType string `json:"avatar_mime_type,omitempty"`
}

// SendMessageParams are the params for the "send_message" action.
type SendMessageParams struct {
	ConversationID  string           `json:"conversation_id"`
	Message         []MessageSegment `json:"message"`
	ClientMessageID string           `json:"client_message_id,omitempty"`
}

type PutTerminalVaultParams struct {
	Payload          string `json:"payload"`
	ExpectedRevision int64  `json:"expected_revision"`
}

// RecallMessageParams are the params for the "recall_message" action.
type RecallMessageParams struct {
	MessageID string `json:"message_id"`
}

// ReactMessageParams are the params for the "react_message" action.
type ReactMessageParams struct {
	MessageID string `json:"message_id"`
	EmojiID   string `json:"emoji_id"`
	Remove    bool   `json:"remove,omitempty"`
}

// GetMessagesParams are the params for the "get_messages" action.
type GetMessagesParams struct {
	ConversationID  string `json:"conversation_id"`
	Limit           int    `json:"limit,omitempty"`
	BeforeMessageID string `json:"before_message_id,omitempty"`
}

// SetConversationPreferencesParams are the params for per-user inbox settings.
type SetConversationPreferencesParams struct {
	ConversationID    string `json:"conversation_id"`
	IsPinned          bool   `json:"is_pinned"`
	NotificationLevel string `json:"notification_level,omitempty"`
	IsMuted           bool   `json:"is_muted"`
}

// MarkReadParams are the params for the "mark_read" action.
type MarkReadParams struct {
	ConversationID string `json:"conversation_id"`
}

// GetUserParams are the params for the "get_user" action.
type GetUserParams struct {
	UserID string `json:"user_id"`
}

// CreateGroupParams are the params for the "create_group" action.
type CreateGroupParams struct {
	Name    string   `json:"name"`
	Avatar  string   `json:"avatar,omitempty"`
	Members []string `json:"members,omitempty"`
}

// GroupInviteParams are the params for the "group_invite" action.
type GroupInviteParams struct {
	GroupID string   `json:"group_id"`
	Members []string `json:"members"`
}

// JoinGroupParams are the params for the "join_group" action.
type JoinGroupParams struct {
	GroupID string `json:"group_id"`
}

// GroupKickParams are the params for the "group_kick" action.
type GroupKickParams struct {
	GroupID string `json:"group_id"`
	UserID  string `json:"user_id"`
}

// GroupBanParams are the params for the "group_ban" action.
type GroupBanParams struct {
	GroupID  string `json:"group_id"`
	UserID   string `json:"user_id"`
	Duration int    `json:"duration,omitempty"` // seconds, 0 = unban
}

// UpdateGroupParams are the params for the "update_group" action.
type UpdateGroupParams struct {
	GroupID      string `json:"group_id"`
	Name         string `json:"name,omitempty"`
	Avatar       string `json:"avatar_url,omitempty"`
	Announcement string `json:"announcement,omitempty"`
}

// SetGroupAdminParams are the params for the "set_group_admin" action.
type SetGroupAdminParams struct {
	GroupID string `json:"group_id"`
	UserID  string `json:"user_id"`
	Enabled bool   `json:"enabled"`
}

// TransferGroupParams are the params for the "transfer_group" action.
type TransferGroupParams struct {
	GroupID string `json:"group_id"`
	UserID  string `json:"user_id"`
}

// GroupMuteAllParams are the params for the "group_mute_all" action.
type GroupMuteAllParams struct {
	GroupID string `json:"group_id"`
	Enabled bool   `json:"enabled"`
}

type GroupAnnouncementParams struct {
	GroupID        string `json:"group_id,omitempty"`
	AnnouncementID string `json:"announcement_id,omitempty"`
	Content        string `json:"content,omitempty"`
	IsPinned       bool   `json:"is_pinned,omitempty"`
}

// FriendRequestParams are the params for the "friend_request" action.
type FriendRequestParams struct {
	UserID  string `json:"user_id"`
	Comment string `json:"comment,omitempty"`
}

// FriendHandleParams are the params for the "friend_request_handle" action.
type FriendHandleParams struct {
	Flag   string `json:"flag"`
	Action string `json:"action"` // "accept" or "reject"
}

// FriendRequestInfo is the client-facing representation of a friend request.
type FriendRequestInfo struct {
	Flag      string `json:"flag"`
	FromUser  User   `json:"from_user"`
	ToUser    User   `json:"to_user"`
	Comment   string `json:"comment,omitempty"`
	Status    string `json:"status"`
	CreatedAt int64  `json:"created_at"`
}

// UploadFileParams are the params for the "upload_file" action.
type UploadFileParams struct {
	File     string `json:"file"` // base64 or file path
	FileName string `json:"file_name"`
	FileType string `json:"file_type"` // "image", "voice", "video", "file"
	MimeType string `json:"mime_type,omitempty"`
}

// GetForwardMsgParams are the params for the "get_forward_msg" action.
type GetForwardMsgParams struct {
	ForwardID string `json:"forward_id"`
}

type CreateForwardParams struct {
	ConversationID string   `json:"conversation_id"`
	MessageIDs     []string `json:"message_ids"`
}

// UpdateProfileParams are the params for the "update_profile" action.
type UpdateProfileParams struct {
	Nickname                string `json:"nickname,omitempty"`
	Avatar                  string `json:"avatar_url,omitempty"`
	Bio                     string `json:"bio,omitempty"`
	CardBackgroundURL       string `json:"card_background_url,omitempty"`
	CardBackgroundColor     string `json:"card_background_color,omitempty"`
	CardBackgroundSensitive bool   `json:"card_background_sensitive,omitempty"`
	ShowMutualGroups        bool   `json:"show_mutual_groups,omitempty"`
	ShowAccountID           bool   `json:"show_account_id,omitempty"`
}

// User represents a user in API responses.
type User struct {
	UserID                  string      `json:"user_id,omitempty"`
	Nickname                string      `json:"nickname"`
	Avatar                  string      `json:"avatar_url,omitempty"`
	Bio                     string      `json:"bio,omitempty"`
	CardBackgroundURL       string      `json:"card_background_url,omitempty"`
	CardBackgroundColor     string      `json:"card_background_color,omitempty"`
	CardBackgroundSensitive bool        `json:"card_background_sensitive"`
	ShowMutualGroups        bool        `json:"show_mutual_groups"`
	ShowAccountID           bool        `json:"show_account_id"`
	Online                  bool        `json:"online"`
	Relationship            string      `json:"relationship,omitempty"`
	Titles                  []UserTitle `json:"titles,omitempty"`
	MutualGroups            []Group     `json:"mutual_groups,omitempty"`
}

// UserTitle is a fixed-style title granted by the system or group managers.
type UserTitle struct {
	TitleID   string `json:"title_id"`
	ScopeType string `json:"scope_type"`
	ScopeID   string `json:"scope_id,omitempty"`
	Text      string `json:"text"`
	Style     string `json:"style"`
	GrantedBy string `json:"granted_by"`
	ExpiresAt int64  `json:"expires_at,omitempty"`
	CreatedAt int64  `json:"created_at"`
}

// Group represents a group in API responses.
type Group struct {
	GroupID      string `json:"group_id"`
	Name         string `json:"name"`
	Avatar       string `json:"avatar_url,omitempty"`
	Announcement string `json:"announcement,omitempty"`
	OwnerID      string `json:"owner_id"`
	MemberCount  int    `json:"member_count"`
	MuteAll      bool   `json:"mute_all"`
}

// GroupMember represents a member in a group.
type GroupMember struct {
	UserID     string `json:"user_id"`
	Nickname   string `json:"nickname"`
	Avatar     string `json:"avatar_url,omitempty"`
	Role       string `json:"role"` // "owner", "admin", "member"
	JoinedAt   int64  `json:"joined_at,omitempty"`
	MutedUntil int64  `json:"muted_until,omitempty"`
}

// Conversation represents a conversation in API responses.
type Conversation struct {
	ConversationID    string   `json:"conversation_id"`
	Type              string   `json:"type"` // "private" or "group"
	Title             string   `json:"title"`
	Avatar            string   `json:"avatar_url,omitempty"`
	UnreadCount       int      `json:"unread_count"`
	IsPinned          bool     `json:"is_pinned"`
	IsMuted           bool     `json:"is_muted"`
	NotificationLevel string   `json:"notification_level"`
	LastMessage       string   `json:"last_message,omitempty"`
	LastTimestamp     int64    `json:"last_timestamp"`
	LastTimestampMS   int64    `json:"last_timestamp_ms"`
	Participants      []string `json:"participants,omitempty"`
}
