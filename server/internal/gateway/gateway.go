package gateway

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log"
	"math"
	"net/http"
	"net/url"
	"sort"
	"strings"
	"sync"
	"time"
	"unicode"

	"github.com/gorilla/websocket"
	"github.com/icradp/zzz-im-server/internal/protocol"
	"github.com/icradp/zzz-im-server/internal/store"
	"golang.org/x/crypto/bcrypt"
)

// Client represents a connected WebSocket client.
type Client struct {
	conn     *websocket.Conn
	userID   string
	send     chan []byte
	sendMu   sync.RWMutex
	sendDone bool
}

func (c *Client) enqueue(data []byte) bool {
	c.sendMu.RLock()
	defer c.sendMu.RUnlock()
	if c.sendDone {
		return false
	}
	select {
	case c.send <- data:
		return true
	default:
		return false
	}
}

func (c *Client) closeSend() {
	c.sendMu.Lock()
	defer c.sendMu.Unlock()
	if c.sendDone {
		return
	}
	c.sendDone = true
	close(c.send)
}

// Gateway manages WebSocket connections and message routing.
type Gateway struct {
	store       store.Store
	pushSender  PushSender
	media       MediaUploader
	accessToken string
	inviteCode  string
	upgrader    websocket.Upgrader
	configMu    sync.RWMutex

	mu sync.RWMutex
	// A user may be connected from several devices at once. Keep every
	// connection so desktop, mobile, and browser sessions receive the same
	// realtime events.
	clients  map[string]map[*Client]struct{} // userID -> active clients
	pokeMu   sync.Mutex
	pokeLast map[string]time.Time
}

// PushSender abstracts VAPID delivery so the gateway remains testable.
type PushSender interface {
	Enabled() bool
	PublicKey() string
	Send(context.Context, *store.PushSubscription, []byte) (bool, error)
}

type MediaUploader interface {
	Save(fileName, fileType, contentType string, data []byte, uploaderID string) (*store.MediaFile, error)
}

func NewGateway(database store.Store, pushSenders ...PushSender) *Gateway {
	var pushSender PushSender
	if len(pushSenders) > 0 {
		pushSender = pushSenders[0]
	}
	return &Gateway{
		store:      database,
		pushSender: pushSender,
		upgrader: websocket.Upgrader{
			CheckOrigin: func(r *http.Request) bool { return true },
		},
		clients:  make(map[string]map[*Client]struct{}),
		pokeLast: make(map[string]time.Time),
	}
}

func (g *Gateway) SetMediaUploader(media MediaUploader) {
	g.media = media
}

// SetAccessToken enables shared-token authentication for test deployments.
// User identity still comes from the explicit user_id request parameter.
func (g *Gateway) SetAccessToken(token string) {
	g.accessToken = token
}

// SetInviteCode enables account registration with a deployment-specific code.
// Registration remains disabled when no code is configured.
func (g *Gateway) SetInviteCode(code string) {
	g.configMu.Lock()
	defer g.configMu.Unlock()
	g.inviteCode = strings.TrimSpace(code)
}

// RegistrationEnabled reports whether account registration currently accepts
// an invitation code. The code itself is never exposed.
func (g *Gateway) RegistrationEnabled() bool {
	g.configMu.RLock()
	defer g.configMu.RUnlock()
	return g.inviteCode != ""
}

func (g *Gateway) currentInviteCode() string {
	g.configMu.RLock()
	defer g.configMu.RUnlock()
	return g.inviteCode
}

// HandleWebSocket handles incoming WebSocket connections.
func (g *Gateway) HandleWebSocket(w http.ResponseWriter, r *http.Request) {
	conn, err := g.upgrader.Upgrade(w, r, nil)
	if err != nil {
		log.Printf("[gateway] upgrade error: %v", err)
		return
	}

	client := &Client{
		conn: conn,
		send: make(chan []byte, 256),
	}

	go g.writePump(client)
	go g.readPump(client)
}

func (g *Gateway) readPump(client *Client) {
	defer func() {
		g.removeClient(client)
		client.conn.Close()
	}()
	client.conn.SetReadLimit(30 * 1024 * 1024)

	for {
		_, message, err := client.conn.ReadMessage()
		if err != nil {
			if websocket.IsUnexpectedCloseError(err, websocket.CloseGoingAway, websocket.CloseNormalClosure) {
				log.Printf("[gateway] read error: %v", err)
			}
			break
		}

		var req protocol.Request
		if err := json.Unmarshal(message, &req); err != nil {
			g.sendError(client, "", "invalid JSON")
			continue
		}

		g.handleRequest(client, &req)
	}
}

func (g *Gateway) writePump(client *Client) {
	defer client.conn.Close()

	for message := range client.send {
		if err := client.conn.WriteMessage(websocket.TextMessage, message); err != nil {
			log.Printf("[gateway] write error: %v", err)
			break
		}
	}
}

func (g *Gateway) handleRequest(client *Client, req *protocol.Request) {
	switch req.Action {
	case protocol.ActionAuth:
		g.handleAuth(client, req)
	case protocol.ActionRegister:
		g.handleRegister(client, req)
	case protocol.ActionLogout:
		g.handleLogout(client, req)
	case protocol.ActionPing:
		g.sendJSON(client, protocol.Response{
			Status:  "ok",
			RetCode: 0,
			Data:    "pong",
			Echo:    req.Echo,
		})
	case protocol.ActionSendMessage:
		g.handleSendMessage(client, req)
	case protocol.ActionEnsureConversation:
		g.handleEnsureConversation(client, req)
	case protocol.ActionRecallMessage:
		g.handleRecallMessage(client, req)
	case protocol.ActionReactMessage:
		g.handleReactMessage(client, req)
	case protocol.ActionGetConversations:
		g.handleGetConversations(client, req)
	case protocol.ActionSetConversationPreferences:
		g.handleSetConversationPreferences(client, req)
	case protocol.ActionGetMessages:
		g.handleGetMessages(client, req)
	case protocol.ActionMarkRead:
		g.handleMarkRead(client, req)
	case protocol.ActionGetUser:
		g.handleGetUser(client, req)
	case protocol.ActionUpdateProfile:
		g.handleUpdateProfile(client, req)
	case protocol.ActionGetUsers:
		g.handleGetUsers(client, req)
	case protocol.ActionGetFriends:
		g.handleGetFriends(client, req)
	case protocol.ActionSearchUsers:
		g.handleSearchUsers(client, req)
	case protocol.ActionGetFriendRequests:
		g.handleGetFriendRequests(client, req)
	case protocol.ActionRemoveFriend:
		g.handleRemoveFriend(client, req)
	case protocol.ActionGetGroupList:
		g.handleGetGroupList(client, req)
	case protocol.ActionGetGroupInfo:
		g.handleGetGroupInfo(client, req)
	case protocol.ActionCreateGroup:
		g.handleCreateGroup(client, req)
	case protocol.ActionGroupInvite:
		g.handleGroupInvite(client, req)
	case protocol.ActionJoinGroup:
		g.handleJoinGroup(client, req)
	case protocol.ActionLeaveGroup:
		g.handleLeaveGroup(client, req)
	case protocol.ActionGroupKick:
		g.handleGroupKick(client, req)
	case protocol.ActionGroupBan:
		g.handleGroupBan(client, req)
	case protocol.ActionUpdateGroup:
		g.handleUpdateGroup(client, req)
	case protocol.ActionSetGroupAdmin:
		g.handleSetGroupAdmin(client, req)
	case protocol.ActionTransferGroup:
		g.handleTransferGroup(client, req)
	case protocol.ActionDismissGroup:
		g.handleDismissGroup(client, req)
	case protocol.ActionGroupMuteAll:
		g.handleGroupMuteAll(client, req)
	case protocol.ActionGetGroupAnnouncements:
		g.handleGetGroupAnnouncements(client, req)
	case protocol.ActionCreateGroupAnnouncement:
		g.handleCreateGroupAnnouncement(client, req)
	case protocol.ActionUpdateGroupAnnouncement:
		g.handleUpdateGroupAnnouncement(client, req)
	case protocol.ActionDeleteGroupAnnouncement:
		g.handleDeleteGroupAnnouncement(client, req)
	case protocol.ActionMarkGroupAnnouncementRead:
		g.handleMarkGroupAnnouncementRead(client, req)
	case protocol.ActionFriendRequest:
		g.handleFriendRequest(client, req)
	case protocol.ActionFriendHandle:
		g.handleFriendHandle(client, req)
	case protocol.ActionGetForwardMessage:
		g.handleGetForwardMessage(client, req)
	case protocol.ActionCreateForward:
		g.handleCreateForward(client, req)
	case protocol.ActionUploadFile:
		g.handleUploadFile(client, req)
	case protocol.ActionGetPushConfig:
		g.handleGetPushConfig(client, req)
	case protocol.ActionRegisterPush:
		g.handleRegisterPush(client, req)
	case protocol.ActionUnregisterPush:
		g.handleUnregisterPush(client, req)
	default:
		g.sendError(client, req.Echo, "unknown action: "+req.Action)
	}
}

func (g *Gateway) handleEnsureConversation(client *Client, req *protocol.Request) {
	if client.userID == "" {
		g.sendError(client, req.Echo, "not authenticated")
		return
	}
	params, ok := req.Params.(map[string]interface{})
	if !ok {
		g.sendError(client, req.Echo, "invalid ensure_conversation params")
		return
	}
	id, _ := params["conversation_id"].(string)
	if id == "" {
		g.sendError(client, req.Echo, "conversation_id required")
		return
	}
	if strings.HasPrefix(id, "group_") {
		if group, _ := g.store.GetGroup(id); group != nil {
			if member, _ := g.store.IsGroupMember(id, client.userID); !member {
				g.sendError(client, req.Echo, "group access denied")
				return
			}
		}
	}
	convType, _ := params["type"].(string)
	if convType != "group" {
		convType = "private"
	}
	title, _ := params["title"].(string)
	if title == "" {
		title = id
	}
	avatar, _ := params["avatar_url"].(string)
	participants := []string{client.userID}
	if raw, ok := params["participants"].([]interface{}); ok {
		participants = participants[:0]
		seen := map[string]bool{}
		for _, value := range raw {
			participant, ok := value.(string)
			if !ok || participant == "" || seen[participant] {
				continue
			}
			seen[participant] = true
			participants = append(participants, participant)
		}
		if !seen[client.userID] {
			participants = append(participants, client.userID)
		}
	}
	if convType == "private" {
		existing, _ := g.store.GetConversation(id)
		if existing == nil {
			otherUserID := ""
			for _, participant := range participants {
				if participant != client.userID {
					otherUserID = participant
					break
				}
			}
			friends, _ := g.store.AreFriends(client.userID, otherUserID)
			if otherUserID == "" || !friends {
				g.sendError(client, req.Echo, "direct messages require a friend relationship")
				return
			}
		}
	}
	conversation := &store.Conversation{
		ID:           id,
		Type:         convType,
		Title:        title,
		Avatar:       avatar,
		Participants: participants,
		CreatedAt:    time.Now(),
	}
	if err := g.store.SaveConversation(conversation); err != nil {
		g.sendError(client, req.Echo, "failed to save conversation")
		return
	}
	g.sendJSON(client, protocol.Response{
		Status: "ok", RetCode: 0, Echo: req.Echo,
	})
}

func (g *Gateway) handleAuth(client *Client, req *protocol.Request) {
	params, ok := req.Params.(map[string]interface{})
	if !ok {
		g.sendError(client, req.Echo, "invalid auth params")
		return
	}

	token, _ := params["token"].(string)
	sessionToken, _ := params["session_token"].(string)
	userID, _ := params["user_id"].(string)
	password, _ := params["password"].(string)
	deviceID, _ := params["device_id"].(string)
	if sessionToken == "" {
		sessionToken = token
	}
	authenticatedBySession := false

	// New clients authenticate with a session token, or with username/password
	// on their first login. The shared token path remains for old test clients.
	if sessionToken != "" {
		if resolved, ok := g.userForSession(sessionToken); ok {
			userID = resolved
			authenticatedBySession = true
		} else if g.accessToken != "" && subtle.ConstantTimeCompare([]byte(sessionToken), []byte(g.accessToken)) != 1 {
			if password == "" {
				g.sendError(client, req.Echo, "invalid credentials")
				return
			}
		}
	}
	if password != "" {
		user, _ := g.store.GetUser(userID)
		if user == nil || user.PasswordHash == "" || bcrypt.CompareHashAndPassword([]byte(user.PasswordHash), []byte(password)) != nil {
			g.sendError(client, req.Echo, "invalid credentials")
			return
		}
	}
	if password == "" && userID == "" && g.accessToken == "" {
		g.sendError(client, req.Echo, "user_id required")
		return
	}
	if password == "" && !authenticatedBySession && g.accessToken != "" && subtle.ConstantTimeCompare([]byte(sessionToken), []byte(g.accessToken)) != 1 {
		g.sendError(client, req.Echo, "invalid credentials")
		return
	}
	if !validUserID(userID) {
		g.sendError(client, req.Echo, "valid user_id required")
		return
	}
	if client.userID != "" && client.userID != userID {
		g.sendError(client, req.Echo, "connection already authenticated as another user")
		return
	}

	// Ensure user exists in store.
	user, _ := g.store.GetUser(userID)
	if user == nil {
		if password != "" {
			g.sendError(client, req.Echo, "account not found")
			return
		}
		user = &store.User{
			ID:       userID,
			Nickname: userID,
			Online:   false,
		}
		if err := g.store.SetUser(user); err != nil {
			g.sendError(client, req.Echo, "failed to load account")
			return
		}
	}

	firstConnection := false
	if client.userID == "" {
		var err error
		firstConnection, err = g.addClient(client, userID)
		if err != nil {
			g.sendError(client, req.Echo, "failed to update presence")
			return
		}
	}
	if firstConnection {
		user.Online = true
	}

	// Send success response.
	responseData := map[string]interface{}{
		"user_id":    user.ID,
		"nickname":   user.Nickname,
		"avatar_url": user.Avatar,
	}
	if password != "" {
		if session, err := g.issueSession(userID); err == nil {
			responseData["session_token"] = session
		}
	}
	g.sendJSON(client, protocol.Response{
		Status:  "ok",
		RetCode: 0,
		Data:    responseData,
		Echo:    req.Echo,
	})
	if firstConnection {
		g.notifyFriendPresence(userID, true)
	}

	log.Printf("[gateway] user %s authenticated (device=%s)", userID, deviceID)
}

func (g *Gateway) handleRegister(client *Client, req *protocol.Request) {
	params, ok := req.Params.(map[string]interface{})
	if !ok {
		g.sendError(client, req.Echo, "invalid register params")
		return
	}
	userID, _ := params["user_id"].(string)
	password, _ := params["password"].(string)
	nickname, _ := params["nickname"].(string)
	inviteCode, _ := params["invite_code"].(string)
	avatarURL, _ := params["avatar_url"].(string)
	avatarFile, _ := params["avatar_file"].(string)
	avatarFileName, _ := params["avatar_file_name"].(string)
	avatarMimeType, _ := params["avatar_mime_type"].(string)
	userID = strings.TrimSpace(userID)
	nickname = strings.TrimSpace(nickname)
	inviteCode = strings.TrimSpace(inviteCode)
	avatarURL = strings.TrimSpace(avatarURL)
	configuredCode := g.currentInviteCode()
	if configuredCode == "" {
		g.sendError(client, req.Echo, "registration is disabled")
		return
	}
	configuredInvite := sha256.Sum256([]byte(configuredCode))
	providedInvite := sha256.Sum256([]byte(inviteCode))
	if subtle.ConstantTimeCompare(configuredInvite[:], providedInvite[:]) != 1 {
		g.sendError(client, req.Echo, "invalid invite code")
		return
	}
	if !validUserID(userID) || len(userID) < 3 || len(userID) > 32 {
		g.sendError(client, req.Echo, "user_id must be 3-32 characters")
		return
	}
	if len(password) < 8 || len(password) > 72 {
		g.sendError(client, req.Echo, "password must be 8-72 characters")
		return
	}
	if nickname == "" {
		nickname = userID
	}
	if len(nickname) > 64 {
		g.sendError(client, req.Echo, "nickname is too long")
		return
	}
	if len(avatarURL) > 2048 || (avatarURL != "" && avatarFile != "") {
		g.sendError(client, req.Echo, "choose either a built-in or uploaded avatar")
		return
	}
	if existing, _ := g.store.GetUser(userID); existing != nil {
		g.sendError(client, req.Echo, "account already exists")
		return
	}
	hash, err := bcrypt.GenerateFromPassword([]byte(password), bcrypt.DefaultCost)
	if err != nil {
		g.sendError(client, req.Echo, "failed to create account")
		return
	}
	if avatarFile != "" {
		if g.media == nil {
			g.sendError(client, req.Echo, "avatar storage is not configured")
			return
		}
		if len(avatarFile) > 7*1024*1024 {
			g.sendError(client, req.Echo, "avatar must be 5 MB or smaller")
			return
		}
		avatarData, err := base64.StdEncoding.DecodeString(avatarFile)
		if err != nil || len(avatarData) == 0 || len(avatarData) > 5*1024*1024 {
			g.sendError(client, req.Echo, "invalid avatar file")
			return
		}
		detectedType := http.DetectContentType(avatarData)
		if !strings.HasPrefix(detectedType, "image/") || detectedType == "image/svg+xml" {
			g.sendError(client, req.Echo, "avatar must be a supported raster image")
			return
		}
		if strings.TrimSpace(avatarFileName) == "" {
			avatarFileName = "avatar"
		}
		if !strings.HasPrefix(avatarMimeType, "image/") {
			avatarMimeType = detectedType
		}
		media, err := g.media.Save(
			avatarFileName,
			"image",
			avatarMimeType,
			avatarData,
			userID,
		)
		if err != nil || media == nil || media.URL == "" {
			log.Printf("[media] registration avatar upload failed for %s: %v", userID, err)
			g.sendError(client, req.Echo, "failed to store avatar")
			return
		}
		avatarURL = media.URL
	}
	user := &store.User{
		ID: userID, Nickname: nickname, Avatar: avatarURL,
		PasswordHash: string(hash), Online: true, CreatedAt: time.Now(),
	}
	if err := g.store.SetUser(user); err != nil {
		g.sendError(client, req.Echo, "failed to create account")
		return
	}
	session, err := g.issueSession(userID)
	if err != nil {
		g.sendError(client, req.Echo, "failed to create session")
		return
	}
	g.sendJSON(client, protocol.Response{Status: "ok", RetCode: 0, Echo: req.Echo, Data: map[string]interface{}{
		"user_id": user.ID, "nickname": user.Nickname, "avatar_url": user.Avatar, "session_token": session,
	}})
}

func (g *Gateway) handleUpdateProfile(client *Client, req *protocol.Request) {
	if client.userID == "" {
		g.sendError(client, req.Echo, "not authenticated")
		return
	}
	params, ok := req.Params.(map[string]interface{})
	if !ok {
		g.sendError(client, req.Echo, "invalid update_profile params")
		return
	}
	user, err := g.store.GetUser(client.userID)
	if err != nil || user == nil {
		g.sendError(client, req.Echo, "account not found")
		return
	}
	if nickname, exists := params["nickname"]; exists {
		value, ok := nickname.(string)
		value = strings.TrimSpace(value)
		if !ok || value == "" || len(value) > 64 {
			g.sendError(client, req.Echo, "nickname must be 1-64 characters")
			return
		}
		user.Nickname = value
	}
	if avatar, exists := params["avatar_url"]; exists {
		value, ok := avatar.(string)
		if !ok || len(value) > 2048 {
			g.sendError(client, req.Echo, "avatar url is invalid")
			return
		}
		user.Avatar = value
	}
	if err := g.store.SetUser(user); err != nil {
		g.sendError(client, req.Echo, "failed to update profile")
		return
	}
	g.notifyProfileUpdate(user, client)
	g.sendJSON(client, protocol.Response{Status: "ok", RetCode: 0, Echo: req.Echo, Data: map[string]interface{}{
		"user_id": user.ID, "nickname": user.Nickname, "avatar_url": user.Avatar,
	}})
}

const sessionTTL = 90 * 24 * time.Hour

func (g *Gateway) issueSession(userID string) (string, error) {
	var raw [32]byte
	if _, err := rand.Read(raw[:]); err != nil {
		return "", err
	}
	token := base64.RawURLEncoding.EncodeToString(raw[:])
	if err := g.store.UpsertSession(&store.Session{
		TokenHash: hashSessionToken(token),
		UserID:    userID,
		ExpiresAt: time.Now().Add(sessionTTL),
	}); err != nil {
		return "", err
	}
	return token, nil
}

func (g *Gateway) userForSession(token string) (string, bool) {
	session, err := g.store.GetSession(hashSessionToken(token))
	if err != nil || session == nil {
		return "", false
	}
	if !session.ExpiresAt.After(time.Now()) {
		_ = g.store.DeleteSession(session.TokenHash)
		return "", false
	}
	return session.UserID, true
}

func (g *Gateway) handleLogout(client *Client, req *protocol.Request) {
	params, ok := req.Params.(map[string]interface{})
	if !ok {
		g.sendError(client, req.Echo, "invalid logout params")
		return
	}
	token, _ := params["session_token"].(string)
	if token == "" {
		g.sendError(client, req.Echo, "session_token required")
		return
	}
	if err := g.store.DeleteSession(hashSessionToken(token)); err != nil {
		g.sendError(client, req.Echo, "failed to revoke session")
		return
	}
	g.sendJSON(client, protocol.Response{Status: "ok", RetCode: 0, Echo: req.Echo})
}

func hashSessionToken(token string) string {
	digest := sha256.Sum256([]byte(token))
	return hex.EncodeToString(digest[:])
}

func validUserID(value string) bool {
	return value != "" &&
		len(value) <= 128 &&
		value == strings.TrimSpace(value) &&
		strings.IndexFunc(value, unicode.IsControl) == -1
}

func (g *Gateway) canAccessConversation(userID, conversationID string) bool {
	if userID == "" || conversationID == "" {
		return false
	}
	if strings.HasPrefix(conversationID, "group_") {
		member, err := g.store.IsGroupMember(conversationID, userID)
		return err == nil && member
	}
	conversation, err := g.store.GetConversation(conversationID)
	if err != nil || conversation == nil {
		return false
	}
	for _, participant := range conversation.Participants {
		if participant == userID {
			return true
		}
	}
	return false
}

func (g *Gateway) isGroupAdmin(groupID, userID string) bool {
	role := g.groupMemberRole(groupID, userID)
	return role == "owner" || role == "admin"
}

func (g *Gateway) groupMemberRole(groupID, userID string) string {
	members, err := g.store.GetGroupMembers(groupID)
	if err != nil {
		return ""
	}
	for _, member := range members {
		if member.UserID == userID {
			return member.Role
		}
	}
	return ""
}

const (
	maxGroupMembers     = 500
	maxGroupInviteBatch = 100
	maxGroupBanSeconds  = 30 * 24 * 60 * 60
)

func groupRoleOrder(role string) int {
	switch role {
	case "owner":
		return 0
	case "admin":
		return 1
	default:
		return 2
	}
}

func canManageGroupMember(actorRole, targetRole string) bool {
	return actorRole == "owner" && (targetRole == "admin" || targetRole == "member") ||
		actorRole == "admin" && targetRole == "member"
}

func unixTimeOrZero(value time.Time) int64 {
	if value.IsZero() {
		return 0
	}
	return value.Unix()
}

// syncGroupConversationParticipants keeps the conversation projection aligned
// with the canonical group_members table after every membership change.
func (g *Gateway) syncGroupConversationParticipants(groupID string) ([]string, error) {
	group, err := g.store.GetGroup(groupID)
	if err != nil || group == nil {
		return nil, fmt.Errorf("group not found")
	}
	members, err := g.store.GetGroupMembers(groupID)
	if err != nil {
		return nil, err
	}
	sort.SliceStable(members, func(i, j int) bool {
		left, right := groupRoleOrder(members[i].Role), groupRoleOrder(members[j].Role)
		if left != right {
			return left < right
		}
		if !members[i].JoinedAt.Equal(members[j].JoinedAt) {
			return members[i].JoinedAt.Before(members[j].JoinedAt)
		}
		return members[i].UserID < members[j].UserID
	})
	participants := make([]string, 0, len(members))
	for _, member := range members {
		participants = append(participants, member.UserID)
	}
	conversation, err := g.store.GetConversation(groupID)
	if err != nil {
		return nil, err
	}
	if conversation == nil {
		conversation = &store.Conversation{ID: groupID, CreatedAt: group.CreatedAt}
	}
	if conversation.CreatedAt.IsZero() {
		conversation.CreatedAt = group.CreatedAt
	}
	conversation.Type = "group"
	conversation.Title = group.Name
	conversation.Avatar = group.Avatar
	conversation.OwnerID = group.OwnerID
	conversation.Participants = participants
	if err := g.store.SaveConversation(conversation); err != nil {
		return nil, err
	}
	return participants, nil
}

func (g *Gateway) validateGroupInviteTargets(inviterID string, raw interface{}) ([]string, string) {
	if raw == nil {
		return nil, ""
	}
	values, ok := raw.([]interface{})
	if !ok {
		return nil, "members must be a list"
	}
	if len(values) > maxGroupInviteBatch {
		return nil, fmt.Sprintf("invite at most %d members at once", maxGroupInviteBatch)
	}
	seen := map[string]bool{inviterID: true}
	targets := make([]string, 0, len(values))
	for _, value := range values {
		targetID, ok := value.(string)
		if !ok || !validUserID(targetID) {
			return nil, "invalid member id"
		}
		if seen[targetID] {
			continue
		}
		seen[targetID] = true
		if user, err := g.store.GetUser(targetID); err != nil || user == nil {
			return nil, "member account not found: " + targetID
		}
		friends, err := g.store.AreFriends(inviterID, targetID)
		if err != nil || !friends {
			return nil, "only friends can be invited: " + targetID
		}
		targets = append(targets, targetID)
	}
	return targets, ""
}

func (g *Gateway) handleSendMessage(client *Client, req *protocol.Request) {
	if client.userID == "" {
		g.sendError(client, req.Echo, "not authenticated")
		return
	}

	params, ok := req.Params.(map[string]interface{})
	if !ok {
		g.sendError(client, req.Echo, "invalid send_message params")
		return
	}

	convID, _ := params["conversation_id"].(string)
	if convID == "" {
		g.sendError(client, req.Echo, "conversation_id required")
		return
	}

	// Parse message segments.
	msgData, err := json.Marshal(params["message"])
	if err != nil {
		g.sendError(client, req.Echo, "invalid message format")
		return
	}
	var segments []protocol.MessageSegment
	if err := json.Unmarshal(msgData, &segments); err != nil {
		g.sendError(client, req.Echo, "invalid message segments")
		return
	}
	if len(segments) == 0 || len(segments) > 20 {
		g.sendError(client, req.Echo, "message must contain between 1 and 20 segments")
		return
	}

	// Ensure conversation exists.
	convType := "private"
	if len(convID) > 6 && convID[:6] == "group_" {
		convType = "group"
	}
	if !g.canAccessConversation(client.userID, convID) {
		g.sendError(client, req.Echo, "conversation access denied")
		return
	}
	if convType == "group" {
		group, groupErr := g.store.GetGroup(convID)
		members, memberErr := g.store.GetGroupMembers(convID)
		if groupErr != nil || memberErr != nil || group == nil {
			g.sendError(client, req.Echo, "failed to load group permissions")
			return
		}
		var currentMember *store.GroupMember
		for _, member := range members {
			if member.UserID == client.userID {
				currentMember = member
				break
			}
		}
		if currentMember == nil {
			g.sendError(client, req.Echo, "group access denied")
			return
		}
		if group.MuteAll && currentMember.Role == "member" {
			g.sendError(client, req.Echo, "the group is muted for all members")
			return
		}
		if currentMember.Role != "owner" && currentMember.MutedUntil.After(time.Now()) {
			g.sendError(client, req.Echo, "you are muted until "+currentMember.MutedUntil.UTC().Format(time.RFC3339))
			return
		}
	}
	replyCount := 0
	for _, segment := range segments {
		if err := validateImageSegmentURL(segment); err != nil {
			g.sendError(client, req.Echo, err.Error())
			return
		}
		if err := validateStickerSegment(segment); err != nil {
			g.sendError(client, req.Echo, err.Error())
			return
		}
		if err := validateRecordSegment(segment); err != nil {
			g.sendError(client, req.Echo, err.Error())
			return
		}
		if err := validateShareSegment(segment); err != nil {
			g.sendError(client, req.Echo, err.Error())
			return
		}
		if err := validateLocationSegment(segment); err != nil {
			g.sendError(client, req.Echo, err.Error())
			return
		}
		if err := g.validateForwardSegment(segment, convID); err != nil {
			g.sendError(client, req.Echo, err.Error())
			return
		}
		if err := g.validatePokeSegment(segment, convID, client.userID); err != nil {
			g.sendError(client, req.Echo, err.Error())
			return
		}
		if segment.Type != "reply" {
			continue
		}
		replyCount++
		if replyCount > 1 {
			g.sendError(client, req.Echo, "only one reply segment is allowed")
			return
		}
		replyID, _ := segment.Data["id"].(string)
		if strings.TrimSpace(replyID) == "" {
			g.sendError(client, req.Echo, "reply message_id required")
			return
		}
		repliedMessage, err := g.store.GetMessage(replyID)
		if err != nil || repliedMessage == nil {
			g.sendError(client, req.Echo, "reply message not found")
			return
		}
		if repliedMessage.ConversationID != convID {
			g.sendError(client, req.Echo, "reply message belongs to another conversation")
			return
		}
	}
	if _, err := g.store.GetOrCreateConversation(convID, convType, convID); err != nil {
		g.sendError(client, req.Echo, "failed to load conversation")
		return
	}

	// Store message.
	user, _ := g.store.GetUser(client.userID)
	nickname := client.userID
	avatar := ""
	if user != nil {
		nickname = user.Nickname
		avatar = user.Avatar
	}
	msg, err := g.store.StoreMessage(convID, client.userID, nickname, segments)
	if err != nil {
		g.sendError(client, req.Echo, "failed to store message")
		return
	}

	// Send success response to sender.
	g.sendJSON(client, protocol.Response{
		Status:  "ok",
		RetCode: 0,
		Data: map[string]interface{}{
			"message_id": msg.ID,
		},
		Echo: req.Echo,
	})

	// Broadcast message event to all clients in the conversation.
	event := protocol.MessageEvent{
		PostType:       "message",
		MessageType:    convType,
		MessageID:      msg.ID,
		ConversationID: convID,
		Sender: protocol.Sender{
			UserID:   client.userID,
			Nickname: nickname,
			Avatar:   avatar,
		},
		Message:   segments,
		Reactions: msg.Reactions,
		Timestamp: msg.Timestamp.Unix(),
	}
	g.broadcastToConversation(convID, event, client.userID)
	g.pushToConversation(convID, msg, client.userID, false)

	log.Printf("[gateway] message %s sent to %s by %s", msg.ID, convID, client.userID)
}

func validateImageSegmentURL(segment protocol.MessageSegment) error {
	if segment.Type != "image" {
		return nil
	}
	for _, key := range []string{"url", "thumbnail_url"} {
		rawURL, _ := segment.Data[key].(string)
		if rawURL == "" {
			continue
		}
		if len(rawURL) > 2048 || rawURL != strings.TrimSpace(rawURL) {
			return fmt.Errorf("image URL is invalid")
		}
		if strings.HasPrefix(rawURL, "/files/") {
			parsed, err := url.ParseRequestURI(rawURL)
			if err != nil || parsed.IsAbs() || parsed.Host != "" {
				return fmt.Errorf("image URL is invalid")
			}
			continue
		}
		parsed, err := url.ParseRequestURI(rawURL)
		if err != nil || parsed.Scheme != "https" || parsed.Host == "" || parsed.User != nil {
			return fmt.Errorf("external image URL must use HTTPS")
		}
	}
	return nil
}

func validateStickerSegment(segment protocol.MessageSegment) error {
	if segment.Type != "sticker" {
		return nil
	}
	if len(segment.Data) != 3 {
		return fmt.Errorf("sticker data is invalid")
	}
	packID, packOK := segment.Data["pack_id"].(string)
	assetID, assetOK := segment.Data["asset_id"].(string)
	version, versionOK := segment.Data["version"].(float64)
	if !packOK || !assetOK || !validStickerIdentifier(packID) || !validStickerIdentifier(assetID) {
		return fmt.Errorf("sticker pack_id and asset_id are invalid")
	}
	if !versionOK || version < 1 || version > 1000 || version != float64(int(version)) {
		return fmt.Errorf("sticker version is invalid")
	}
	return nil
}

func validateRecordSegment(segment protocol.MessageSegment) error {
	if segment.Type != "record" {
		return nil
	}
	if duration, ok := segment.Data["duration_ms"].(float64); ok &&
		(duration < 0 || duration > float64((2*time.Minute)/time.Millisecond)) {
		return fmt.Errorf("voice message duration must not exceed 2 minutes")
	}
	if size, ok := segment.Data["size"].(float64); ok && (size < 0 || size > 10*1024*1024) {
		return fmt.Errorf("voice message must not exceed 10 MB")
	}
	return nil
}

func validateShareSegment(segment protocol.MessageSegment) error {
	if segment.Type != "share" {
		return nil
	}
	rawURL, _ := segment.Data["url"].(string)
	if len(rawURL) == 0 || len(rawURL) > 2048 || rawURL != strings.TrimSpace(rawURL) {
		return fmt.Errorf("link URL is invalid")
	}
	parsed, err := url.ParseRequestURI(rawURL)
	if err != nil || (parsed.Scheme != "https" && parsed.Scheme != "http") || parsed.Host == "" || parsed.User != nil {
		return fmt.Errorf("link URL must use HTTP or HTTPS")
	}
	title, _ := segment.Data["title"].(string)
	if len([]rune(title)) > 160 {
		return fmt.Errorf("link title is too long")
	}
	return nil
}

func validateLocationSegment(segment protocol.MessageSegment) error {
	if segment.Type != "location" {
		return nil
	}
	name, _ := segment.Data["name"].(string)
	if strings.TrimSpace(name) == "" || len([]rune(name)) > 120 {
		return fmt.Errorf("location name is required and must not exceed 120 characters")
	}
	lat, hasLat := segment.Data["lat"].(float64)
	lon, hasLon := segment.Data["lon"].(float64)
	if hasLat != hasLon {
		return fmt.Errorf("location coordinates must include both latitude and longitude")
	}
	if hasLat && (math.IsNaN(lat) || math.IsInf(lat, 0) || math.IsNaN(lon) || math.IsInf(lon, 0) || lat < -90 || lat > 90 || lon < -180 || lon > 180) {
		return fmt.Errorf("location coordinates are invalid")
	}
	return nil
}

func (g *Gateway) validateForwardSegment(segment protocol.MessageSegment, conversationID string) error {
	if segment.Type != "forward" {
		return nil
	}
	forwardID, _ := segment.Data["id"].(string)
	forward, err := g.store.GetForward(forwardID)
	if err != nil || forward == nil {
		return fmt.Errorf("forward not found")
	}
	if forward.ConversationID != conversationID {
		return fmt.Errorf("forward belongs to another conversation")
	}
	return nil
}

func (g *Gateway) validatePokeSegment(segment protocol.MessageSegment, conversationID, senderID string) error {
	if segment.Type != "poke" {
		return nil
	}
	targetID, _ := segment.Data["target_id"].(string)
	if targetID == "" || targetID == senderID {
		return fmt.Errorf("poke target is invalid")
	}
	conversation, err := g.store.GetConversation(conversationID)
	if err != nil || conversation == nil {
		return fmt.Errorf("conversation not found")
	}
	allowed := false
	if conversation.Type == "group" {
		allowed, err = g.store.IsGroupMember(conversationID, targetID)
	} else {
		for _, participantID := range conversation.Participants {
			if participantID == targetID {
				allowed = true
				break
			}
		}
	}
	if err != nil || !allowed {
		return fmt.Errorf("poke target is not in this conversation")
	}
	key := senderID + "\x00" + conversationID
	now := time.Now()
	g.pokeMu.Lock()
	defer g.pokeMu.Unlock()
	if previous := g.pokeLast[key]; !previous.IsZero() && now.Sub(previous) < 5*time.Second {
		return fmt.Errorf("please wait before poking again")
	}
	g.pokeLast[key] = now
	return nil
}

func validStickerIdentifier(value string) bool {
	if len(value) == 0 || len(value) > 64 {
		return false
	}
	for _, character := range value {
		if (character >= 'a' && character <= 'z') ||
			(character >= 'A' && character <= 'Z') ||
			(character >= '0' && character <= '9') ||
			character == '-' || character == '_' || character == '.' {
			continue
		}
		return false
	}
	return true
}

func (g *Gateway) handleReactMessage(client *Client, req *protocol.Request) {
	if client.userID == "" {
		g.sendError(client, req.Echo, "not authenticated")
		return
	}
	params, ok := req.Params.(map[string]interface{})
	if !ok {
		g.sendError(client, req.Echo, "invalid react_message params")
		return
	}
	messageID, _ := params["message_id"].(string)
	emojiID, _ := params["emoji_id"].(string)
	remove, _ := params["remove"].(bool)
	messageID = strings.TrimSpace(messageID)
	emojiID = strings.TrimSpace(emojiID)
	if messageID == "" {
		g.sendError(client, req.Echo, "message_id required")
		return
	}
	if emojiID == "" || len([]rune(emojiID)) > 32 {
		g.sendError(client, req.Echo, "emoji_id must contain 1-32 characters")
		return
	}
	for _, r := range emojiID {
		if unicode.IsControl(r) {
			g.sendError(client, req.Echo, "emoji_id contains invalid characters")
			return
		}
	}
	message, err := g.store.GetMessage(messageID)
	if err != nil {
		g.sendError(client, req.Echo, "failed to load message")
		return
	}
	if message == nil {
		g.sendError(client, req.Echo, "message not found")
		return
	}
	if !g.canAccessConversation(client.userID, message.ConversationID) {
		g.sendError(client, req.Echo, "conversation access denied")
		return
	}
	updated, err := g.store.ReactToMessage(messageID, client.userID, emojiID, remove)
	if err != nil {
		g.sendError(client, req.Echo, "failed to update reaction: "+err.Error())
		return
	}
	if updated == nil {
		g.sendError(client, req.Echo, "message not found or recalled")
		return
	}
	myReactions, err := g.store.GetMessageReactionIDs(messageID, client.userID)
	if err != nil {
		g.sendError(client, req.Echo, "failed to load reaction state")
		return
	}
	g.sendJSON(client, protocol.Response{
		Status:  "ok",
		RetCode: 0,
		Data: map[string]interface{}{
			"message_id":   messageID,
			"emoji_id":     emojiID,
			"removed":      remove,
			"reactions":    updated.Reactions,
			"my_reactions": myReactions,
		},
		Echo: req.Echo,
	})
	g.broadcastToConversation(message.ConversationID, protocol.NoticeEvent{
		PostType:       "notice",
		NoticeType:     protocol.NoticeTypeMessageReaction,
		ConversationID: message.ConversationID,
		MessageID:      messageID,
		UserID:         client.userID,
		EmojiID:        emojiID,
		Removed:        remove,
		Reactions:      updated.Reactions,
	}, "")
}

func (g *Gateway) handleRecallMessage(client *Client, req *protocol.Request) {
	if client.userID == "" {
		g.sendError(client, req.Echo, "not authenticated")
		return
	}

	params, ok := req.Params.(map[string]interface{})
	if !ok {
		g.sendError(client, req.Echo, "invalid params")
		return
	}

	msgID, _ := params["message_id"].(string)
	if msgID == "" {
		g.sendError(client, req.Echo, "message_id required")
		return
	}

	msg, err := g.store.GetMessage(msgID)
	if err != nil {
		g.sendError(client, req.Echo, "failed to load message")
		return
	}
	if msg == nil {
		g.sendError(client, req.Echo, "message not found")
		return
	}
	if !g.canAccessConversation(client.userID, msg.ConversationID) {
		g.sendError(client, req.Echo, "conversation access denied")
		return
	}
	if msg.Recalled {
		g.sendError(client, req.Echo, "message already recalled")
		return
	}
	if time.Since(msg.Timestamp) > 2*time.Minute {
		g.sendError(client, req.Echo, "message can only be recalled within two minutes")
		return
	}

	conversation, err := g.store.GetConversation(msg.ConversationID)
	if err != nil || conversation == nil {
		g.sendError(client, req.Echo, "failed to load conversation")
		return
	}
	isGroup := conversation.Type == "group"
	if msg.SenderID != client.userID && (!isGroup || !g.isGroupAdmin(msg.ConversationID, client.userID)) {
		g.sendError(client, req.Echo, "message recall permission denied")
		return
	}

	recalled, err := g.store.RecallMessage(msgID)
	if err != nil {
		g.sendError(client, req.Echo, "failed to recall message")
		return
	}
	if !recalled {
		g.sendError(client, req.Echo, "message not found")
		return
	}

	g.sendJSON(client, protocol.Response{
		Status:  "ok",
		RetCode: 0,
		Echo:    req.Echo,
	})

	noticeType := protocol.NoticeTypeFriendRecall
	if isGroup {
		noticeType = protocol.NoticeTypeGroupRecall
	}
	g.broadcastToConversation(msg.ConversationID, protocol.NoticeEvent{
		PostType:       "notice",
		NoticeType:     noticeType,
		ConversationID: msg.ConversationID,
		MessageID:      msgID,
		UserID:         msg.SenderID,
		OperatorID:     client.userID,
	}, "")
}

func (g *Gateway) handleGetConversations(client *Client, req *protocol.Request) {
	if client.userID == "" {
		g.sendError(client, req.Echo, "not authenticated")
		return
	}

	convs, err := g.store.GetUserConversations(client.userID)
	if err != nil {
		g.sendError(client, req.Echo, "failed to load conversations")
		return
	}
	result := make([]protocol.Conversation, len(convs))
	for i, conv := range convs {
		lastMsg := ""
		var lastTs int64
		title := conv.Title
		avatar := conv.Avatar
		if conv.Type == "private" {
			for _, participantID := range conv.Participants {
				if participantID == client.userID {
					continue
				}
				if peer, peerErr := g.store.GetUser(participantID); peerErr == nil && peer != nil {
					title = peer.Nickname
					avatar = peer.Avatar
				}
				break
			}
		}
		msgs, err := g.store.GetMessages(conv.ID, 1)
		if err != nil {
			g.sendError(client, req.Echo, "failed to load conversations")
			return
		}
		if len(msgs) > 0 {
			if len(msgs[0].Segments) > 0 && msgs[0].Segments[0].Type == "text" {
				lastMsg, _ = msgs[0].Segments[0].Data["text"].(string)
			}
			lastTs = msgs[0].Timestamp.Unix()
		}
		unreadCount, err := g.store.CountUnreadMessages(conv.ID, client.userID)
		if err != nil {
			g.sendError(client, req.Echo, "failed to load unread count")
			return
		}
		preference, err := g.store.GetConversationPreference(conv.ID, client.userID)
		if err != nil {
			g.sendError(client, req.Echo, "failed to load conversation preferences")
			return
		}
		result[i] = protocol.Conversation{
			ConversationID:    conv.ID,
			Type:              conv.Type,
			Title:             title,
			Avatar:            avatar,
			UnreadCount:       unreadCount,
			IsPinned:          preference != nil && preference.IsPinned,
			IsMuted:           preference != nil && preference.IsMuted,
			NotificationLevel: conversationNotificationLevel(preference),
			LastMessage:       lastMsg,
			LastTimestamp:     lastTs,
			Participants:      conv.Participants,
		}
	}

	g.sendJSON(client, protocol.Response{
		Status:  "ok",
		RetCode: 0,
		Data:    result,
		Echo:    req.Echo,
	})
}

func (g *Gateway) handleSetConversationPreferences(client *Client, req *protocol.Request) {
	if client.userID == "" {
		g.sendError(client, req.Echo, "not authenticated")
		return
	}
	params, ok := req.Params.(map[string]interface{})
	if !ok {
		g.sendError(client, req.Echo, "invalid params")
		return
	}
	conversationID, _ := params["conversation_id"].(string)
	isPinned, pinnedOK := params["is_pinned"].(bool)
	legacyMuted, mutedOK := params["is_muted"].(bool)
	level, levelOK := params["notification_level"].(string)
	if conversationID == "" || !pinnedOK || (!levelOK && !mutedOK) {
		g.sendError(client, req.Echo, "conversation_id, is_pinned and notification_level required")
		return
	}
	if levelOK && level != store.NotificationLevelNormal &&
		level != store.NotificationLevelMentionsOnly && level != store.NotificationLevelMuted {
		g.sendError(client, req.Echo, "invalid notification_level")
		return
	}
	level = store.NormalizeNotificationLevel(level, legacyMuted)
	isMuted := level == store.NotificationLevelMuted
	if !g.canAccessConversation(client.userID, conversationID) {
		g.sendError(client, req.Echo, "conversation access denied")
		return
	}
	preference := &store.ConversationPreference{
		ConversationID:    conversationID,
		UserID:            client.userID,
		IsPinned:          isPinned,
		NotificationLevel: level,
		IsMuted:           isMuted,
	}
	if err := g.store.SetConversationPreference(preference); err != nil {
		g.sendError(client, req.Echo, "failed to save conversation preferences")
		return
	}
	g.sendJSON(client, protocol.Response{
		Status: "ok", RetCode: 0, Data: preference, Echo: req.Echo,
	})
	g.sendToUser(client.userID, protocol.NoticeEvent{
		PostType:          "notice",
		NoticeType:        protocol.NoticeTypeConversationPreferences,
		UserID:            client.userID,
		ConversationID:    conversationID,
		IsPinned:          &isPinned,
		IsMuted:           &isMuted,
		NotificationLevel: level,
	})
}

func conversationNotificationLevel(preference *store.ConversationPreference) string {
	if preference == nil {
		return store.NotificationLevelNormal
	}
	return store.NormalizeNotificationLevel(preference.NotificationLevel, preference.IsMuted)
}

func (g *Gateway) handleGetMessages(client *Client, req *protocol.Request) {
	if client.userID == "" {
		g.sendError(client, req.Echo, "not authenticated")
		return
	}

	params, ok := req.Params.(map[string]interface{})
	if !ok {
		g.sendError(client, req.Echo, "invalid params")
		return
	}

	convID, _ := params["conversation_id"].(string)
	if convID == "" {
		g.sendError(client, req.Echo, "conversation_id required")
		return
	}
	if !g.canAccessConversation(client.userID, convID) {
		g.sendError(client, req.Echo, "conversation access denied")
		return
	}

	limit := 50
	if l, ok := params["limit"].(float64); ok {
		limit = int(l)
	}
	if limit < 1 {
		limit = 1
	} else if limit > 100 {
		limit = 100
	}
	beforeMessageID, _ := params["before_message_id"].(string)

	msgs, err := g.store.GetMessagesBefore(convID, beforeMessageID, limit)
	if err != nil {
		g.sendError(client, req.Echo, "failed to load messages")
		return
	}
	readStates, err := g.store.GetConversationReadStates(convID)
	if err != nil {
		g.sendError(client, req.Echo, "failed to load read state")
		return
	}
	readStateByUser := make(map[string]*store.ReadState, len(readStates))
	for _, state := range readStates {
		readStateByUser[state.UserID] = state
	}
	recipients := g.conversationRecipients(convID, client.userID)
	result := make([]map[string]interface{}, len(msgs))
	for i, msg := range msgs {
		senderAvatar := ""
		if sender, err := g.store.GetUser(msg.SenderID); err == nil && sender != nil {
			senderAvatar = sender.Avatar
		}
		status := "sent"
		readCount := 0
		recipientCount := 0
		if msg.SenderID == client.userID {
			recipientCount = len(recipients)
			for _, recipientID := range recipients {
				if hasReadMessage(readStateByUser[recipientID], msg) {
					readCount++
				}
			}
			if readCount > 0 {
				status = "read"
			}
		}
		myReactions, err := g.store.GetMessageReactionIDs(msg.ID, client.userID)
		if err != nil {
			g.sendError(client, req.Echo, "failed to load reaction state")
			return
		}
		result[i] = map[string]interface{}{
			"message_id":      msg.ID,
			"conversation_id": msg.ConversationID,
			"sender": map[string]interface{}{
				"user_id":    msg.SenderID,
				"nickname":   msg.SenderNickname,
				"avatar_url": senderAvatar,
			},
			"message":         msg.Segments,
			"timestamp":       msg.Timestamp.Unix(),
			"recalled":        msg.Recalled,
			"reactions":       msg.Reactions,
			"my_reactions":    myReactions,
			"status":          status,
			"read_count":      readCount,
			"recipient_count": recipientCount,
		}
	}

	g.sendJSON(client, protocol.Response{
		Status:  "ok",
		RetCode: 0,
		Data:    result,
		Echo:    req.Echo,
	})
}

func (g *Gateway) handleMarkRead(client *Client, req *protocol.Request) {
	if client.userID == "" {
		g.sendError(client, req.Echo, "not authenticated")
		return
	}
	params, ok := req.Params.(map[string]interface{})
	if !ok {
		g.sendError(client, req.Echo, "invalid params")
		return
	}
	conversationID, _ := params["conversation_id"].(string)
	if conversationID == "" {
		g.sendError(client, req.Echo, "conversation_id required")
		return
	}
	if !g.canAccessConversation(client.userID, conversationID) {
		g.sendError(client, req.Echo, "conversation access denied")
		return
	}
	state, err := g.store.MarkConversationRead(conversationID, client.userID)
	if err != nil {
		g.sendError(client, req.Echo, "failed to mark conversation read")
		return
	}
	g.sendJSON(client, protocol.Response{
		Status:  "ok",
		RetCode: 0,
		Data:    state,
		Echo:    req.Echo,
	})
	g.broadcastToConversation(conversationID, protocol.NoticeEvent{
		PostType:          "notice",
		NoticeType:        protocol.NoticeTypeMessageRead,
		UserID:            client.userID,
		ConversationID:    conversationID,
		LastReadMessageID: state.LastReadMessageID,
		ReadAt:            state.ReadAt.Unix(),
	}, client.userID)
}

func hasReadMessage(state *store.ReadState, message *store.Message) bool {
	if state == nil || message == nil {
		return false
	}
	return state.ReadAt.After(message.Timestamp) ||
		state.ReadAt.Equal(message.Timestamp) ||
		state.LastReadMessageID == message.ID
}

func (g *Gateway) handleGetUser(client *Client, req *protocol.Request) {
	if client.userID == "" {
		g.sendError(client, req.Echo, "not authenticated")
		return
	}
	params, ok := req.Params.(map[string]interface{})
	if !ok {
		g.sendError(client, req.Echo, "invalid params")
		return
	}

	userID, _ := params["user_id"].(string)
	user, _ := g.store.GetUser(userID)
	if user == nil {
		g.sendError(client, req.Echo, "user not found")
		return
	}

	g.sendJSON(client, protocol.Response{
		Status:  "ok",
		RetCode: 0,
		Data: protocol.User{
			UserID:   user.ID,
			Nickname: user.Nickname,
			Avatar:   user.Avatar,
			Online:   user.Online,
		},
		Echo: req.Echo,
	})
}

func (g *Gateway) handleGetUsers(client *Client, req *protocol.Request) {
	if client.userID == "" {
		g.sendError(client, req.Echo, "not authenticated")
		return
	}
	users, _ := g.store.GetFriends(client.userID)
	result := make([]protocol.User, len(users))
	for i, u := range users {
		result[i] = protocol.User{
			UserID:   u.ID,
			Nickname: u.Nickname,
			Avatar:   u.Avatar,
			Online:   u.Online,
		}
	}

	g.sendJSON(client, protocol.Response{
		Status:  "ok",
		RetCode: 0,
		Data:    result,
		Echo:    req.Echo,
	})
}

func (g *Gateway) handleGetFriends(client *Client, req *protocol.Request) {
	if client.userID == "" {
		g.sendError(client, req.Echo, "not authenticated")
		return
	}

	users, _ := g.store.GetFriends(client.userID)
	result := make([]protocol.User, 0)
	for _, u := range users {
		if u.ID != client.userID {
			result = append(result, protocol.User{
				UserID:   u.ID,
				Nickname: u.Nickname,
				Avatar:   u.Avatar,
				Online:   u.Online,
			})
		}
	}

	g.sendJSON(client, protocol.Response{
		Status:  "ok",
		RetCode: 0,
		Data:    result,
		Echo:    req.Echo,
	})
}

func (g *Gateway) handleSearchUsers(client *Client, req *protocol.Request) {
	if client.userID == "" {
		g.sendError(client, req.Echo, "not authenticated")
		return
	}
	params, ok := req.Params.(map[string]interface{})
	if !ok {
		g.sendError(client, req.Echo, "invalid search_users params")
		return
	}
	query, _ := params["query"].(string)
	query = strings.ToLower(strings.TrimSpace(query))
	if query == "" || len(query) > 64 {
		g.sendError(client, req.Echo, "query must be 1-64 characters")
		return
	}
	requests, _ := g.store.GetPendingFriendRequests(client.userID)
	users, err := g.store.GetUsers()
	if err != nil {
		g.sendError(client, req.Echo, "failed to search users")
		return
	}
	result := make([]protocol.User, 0, 20)
	for _, user := range users {
		if user.ID == client.userID ||
			(!strings.Contains(strings.ToLower(user.ID), query) &&
				!strings.Contains(strings.ToLower(user.Nickname), query)) {
			continue
		}
		relationship := "none"
		if friends, _ := g.store.AreFriends(client.userID, user.ID); friends {
			relationship = "friend"
		} else {
			for _, pending := range requests {
				if pending.FromID == client.userID && pending.ToID == user.ID {
					relationship = "outgoing"
					break
				}
				if pending.ToID == client.userID && pending.FromID == user.ID {
					relationship = "incoming"
					break
				}
			}
		}
		result = append(result, protocol.User{
			UserID: user.ID, Nickname: user.Nickname, Avatar: user.Avatar,
			Online: user.Online, Relationship: relationship,
		})
	}
	sort.Slice(result, func(i, j int) bool {
		iExact := strings.ToLower(result[i].UserID) == query
		jExact := strings.ToLower(result[j].UserID) == query
		if iExact != jExact {
			return iExact
		}
		return strings.ToLower(result[i].Nickname) < strings.ToLower(result[j].Nickname)
	})
	if len(result) > 20 {
		result = result[:20]
	}
	g.sendJSON(client, protocol.Response{Status: "ok", RetCode: 0, Data: result, Echo: req.Echo})
}

func (g *Gateway) handleGetFriendRequests(client *Client, req *protocol.Request) {
	if client.userID == "" {
		g.sendError(client, req.Echo, "not authenticated")
		return
	}
	requests, err := g.store.GetPendingFriendRequests(client.userID)
	if err != nil {
		g.sendError(client, req.Echo, "failed to load friend requests")
		return
	}
	result := make([]protocol.FriendRequestInfo, 0, len(requests))
	for _, friendRequest := range requests {
		from, _ := g.store.GetUser(friendRequest.FromID)
		to, _ := g.store.GetUser(friendRequest.ToID)
		if from == nil || to == nil {
			continue
		}
		result = append(result, protocol.FriendRequestInfo{
			Flag:     friendRequest.ID,
			FromUser: protocol.User{UserID: from.ID, Nickname: from.Nickname, Avatar: from.Avatar, Online: from.Online},
			ToUser:   protocol.User{UserID: to.ID, Nickname: to.Nickname, Avatar: to.Avatar, Online: to.Online},
			Comment:  friendRequest.Comment, Status: friendRequest.Status,
			CreatedAt: friendRequest.CreatedAt.Unix(),
		})
	}
	g.sendJSON(client, protocol.Response{Status: "ok", RetCode: 0, Data: result, Echo: req.Echo})
}

func (g *Gateway) handleRemoveFriend(client *Client, req *protocol.Request) {
	if client.userID == "" {
		g.sendError(client, req.Echo, "not authenticated")
		return
	}
	params, ok := req.Params.(map[string]interface{})
	if !ok {
		g.sendError(client, req.Echo, "invalid remove_friend params")
		return
	}
	friendID, _ := params["user_id"].(string)
	removed, err := g.store.RemoveFriend(client.userID, friendID)
	if err != nil || !removed {
		g.sendError(client, req.Echo, "friend relationship not found")
		return
	}
	g.sendJSON(client, protocol.Response{Status: "ok", RetCode: 0, Echo: req.Echo})
	g.sendToUser(friendID, protocol.NoticeEvent{
		PostType: "notice", NoticeType: protocol.NoticeTypeFriendRemove,
		UserID: client.userID,
	})
}

func (g *Gateway) handleGetGroupList(client *Client, req *protocol.Request) {
	if client.userID == "" {
		g.sendError(client, req.Echo, "not authenticated")
		return
	}

	groups, _ := g.store.GetUserGroups(client.userID)
	result := make([]protocol.Group, len(groups))
	for i, grp := range groups {
		result[i] = protocol.Group{
			GroupID:      grp.ID,
			Name:         grp.Name,
			Avatar:       grp.Avatar,
			Announcement: grp.Announcement,
			OwnerID:      grp.OwnerID,
			MemberCount:  len(grp.Members),
			MuteAll:      grp.MuteAll,
		}
		if len(grp.Members) == 0 {
			if members, err := g.store.GetGroupMembers(grp.ID); err == nil {
				result[i].MemberCount = len(members)
			}
		}
	}

	g.sendJSON(client, protocol.Response{
		Status:  "ok",
		RetCode: 0,
		Data:    result,
		Echo:    req.Echo,
	})
}

func (g *Gateway) handleGetGroupInfo(client *Client, req *protocol.Request) {
	if client.userID == "" {
		g.sendError(client, req.Echo, "not authenticated")
		return
	}
	params, ok := req.Params.(map[string]interface{})
	if !ok {
		g.sendError(client, req.Echo, "invalid params")
		return
	}

	groupID, _ := params["group_id"].(string)
	if member, _ := g.store.IsGroupMember(groupID, client.userID); !member {
		g.sendError(client, req.Echo, "group access denied")
		return
	}
	group, _ := g.store.GetGroup(groupID)
	if group == nil {
		g.sendError(client, req.Echo, "group not found")
		return
	}

	members, _ := g.store.GetGroupMembers(groupID)
	memberList := make([]protocol.GroupMember, len(members))
	for i, m := range members {
		user, _ := g.store.GetUser(m.UserID)
		nickname := m.UserID
		avatar := ""
		if user != nil {
			nickname = user.Nickname
			avatar = user.Avatar
		}
		memberList[i] = protocol.GroupMember{
			UserID:     m.UserID,
			Nickname:   nickname,
			Avatar:     avatar,
			Role:       m.Role,
			JoinedAt:   m.JoinedAt.Unix(),
			MutedUntil: unixTimeOrZero(m.MutedUntil),
		}
	}

	g.sendJSON(client, protocol.Response{
		Status:  "ok",
		RetCode: 0,
		Data: map[string]interface{}{
			"group_id":     group.ID,
			"name":         group.Name,
			"avatar_url":   group.Avatar,
			"announcement": group.Announcement,
			"owner_id":     group.OwnerID,
			"mute_all":     group.MuteAll,
			"member_count": len(members),
			"members":      memberList,
		},
		Echo: req.Echo,
	})
}

func (g *Gateway) handleCreateGroup(client *Client, req *protocol.Request) {
	if client.userID == "" {
		g.sendError(client, req.Echo, "not authenticated")
		return
	}

	params, ok := req.Params.(map[string]interface{})
	if !ok {
		g.sendError(client, req.Echo, "invalid params")
		return
	}

	name, _ := params["name"].(string)
	avatar, _ := params["avatar"].(string)
	name = strings.TrimSpace(name)
	if name == "" || len(name) > 80 {
		g.sendError(client, req.Echo, "group name must be 1-80 characters")
		return
	}
	if len(avatar) > 2048 {
		g.sendError(client, req.Echo, "group avatar is invalid")
		return
	}
	memberIDs, validationError := g.validateGroupInviteTargets(client.userID, params["members"])
	if validationError != "" {
		g.sendError(client, req.Echo, validationError)
		return
	}
	groupID := fmt.Sprintf("group_%d", time.Now().UnixNano())
	group, err := g.store.CreateGroup(groupID, name, avatar, client.userID)
	if err != nil || group == nil {
		g.sendError(client, req.Echo, "failed to create group")
		return
	}
	participants := []string{client.userID}
	addedMembers := make([]string, 0, len(memberIDs))
	for _, memberID := range memberIDs {
		added, addErr := g.store.AddGroupMember(groupID, memberID)
		if addErr != nil || !added {
			for _, rollbackID := range addedMembers {
				_, _ = g.store.RemoveGroupMember(groupID, rollbackID)
			}
			g.sendError(client, req.Echo, "failed to add group members")
			return
		}
		participants = append(participants, memberID)
		addedMembers = append(addedMembers, memberID)
	}
	if _, err := g.syncGroupConversationParticipants(groupID); err != nil {
		g.sendError(client, req.Echo, "failed to create group conversation")
		return
	}

	g.sendJSON(client, protocol.Response{
		Status:  "ok",
		RetCode: 0,
		Data: map[string]interface{}{
			"group_id":     group.ID,
			"name":         group.Name,
			"avatar_url":   group.Avatar,
			"owner_id":     group.OwnerID,
			"member_count": len(participants),
			"participants": participants,
		},
		Echo: req.Echo,
	})
	for _, memberID := range addedMembers {
		g.sendToUser(memberID, protocol.NoticeEvent{
			PostType:   "notice",
			NoticeType: protocol.NoticeTypeGroupIncrease,
			GroupID:    groupID,
			UserID:     memberID,
			OperatorID: client.userID,
		})
	}
}

func (g *Gateway) handleGroupInvite(client *Client, req *protocol.Request) {
	if client.userID == "" {
		g.sendError(client, req.Echo, "not authenticated")
		return
	}
	params, ok := req.Params.(map[string]interface{})
	if !ok {
		g.sendError(client, req.Echo, "invalid group_invite params")
		return
	}
	groupID, _ := params["group_id"].(string)
	group, err := g.store.GetGroup(groupID)
	if err != nil || group == nil {
		g.sendError(client, req.Echo, "group not found")
		return
	}
	if !g.isGroupAdmin(groupID, client.userID) {
		g.sendError(client, req.Echo, "group permission denied")
		return
	}
	targets, validationError := g.validateGroupInviteTargets(client.userID, params["members"])
	if validationError != "" {
		g.sendError(client, req.Echo, validationError)
		return
	}
	members, err := g.store.GetGroupMembers(groupID)
	if err != nil {
		g.sendError(client, req.Echo, "failed to load group members")
		return
	}
	existing := make(map[string]bool, len(members))
	for _, member := range members {
		existing[member.UserID] = true
	}
	filtered := targets[:0]
	for _, targetID := range targets {
		if !existing[targetID] {
			filtered = append(filtered, targetID)
		}
	}
	targets = filtered
	if len(members)+len(targets) > maxGroupMembers {
		g.sendError(client, req.Echo, fmt.Sprintf("group member limit is %d", maxGroupMembers))
		return
	}
	addedMembers := make([]string, 0, len(targets))
	for _, targetID := range targets {
		added, addErr := g.store.AddGroupMember(groupID, targetID)
		if addErr != nil || !added {
			for _, rollbackID := range addedMembers {
				_, _ = g.store.RemoveGroupMember(groupID, rollbackID)
			}
			g.sendError(client, req.Echo, "failed to invite group members")
			return
		}
		addedMembers = append(addedMembers, targetID)
	}
	participants, err := g.syncGroupConversationParticipants(groupID)
	if err != nil {
		for _, rollbackID := range addedMembers {
			_, _ = g.store.RemoveGroupMember(groupID, rollbackID)
		}
		_, _ = g.syncGroupConversationParticipants(groupID)
		g.sendError(client, req.Echo, "failed to update group conversation")
		return
	}
	g.sendJSON(client, protocol.Response{Status: "ok", RetCode: 0, Echo: req.Echo, Data: map[string]interface{}{
		"added_members": addedMembers,
		"participants":  participants,
		"member_count":  len(participants),
	}})
	for _, targetID := range addedMembers {
		g.broadcastToConversation(groupID, protocol.NoticeEvent{
			PostType:   "notice",
			NoticeType: protocol.NoticeTypeGroupIncrease,
			GroupID:    groupID,
			UserID:     targetID,
			OperatorID: client.userID,
		}, "")
	}
}

func (g *Gateway) handleJoinGroup(client *Client, req *protocol.Request) {
	if client.userID == "" {
		g.sendError(client, req.Echo, "not authenticated")
		return
	}

	params, ok := req.Params.(map[string]interface{})
	if !ok {
		g.sendError(client, req.Echo, "invalid params")
		return
	}

	groupID, _ := params["group_id"].(string)
	if group, _ := g.store.GetGroup(groupID); group == nil {
		g.sendError(client, req.Echo, "group not found")
		return
	}
	addOk, err := g.store.AddGroupMember(groupID, client.userID)
	if err == nil && addOk {
		participants, syncErr := g.syncGroupConversationParticipants(groupID)
		if syncErr != nil {
			_, _ = g.store.RemoveGroupMember(groupID, client.userID)
			g.sendError(client, req.Echo, "failed to update group conversation")
			return
		}
		g.sendJSON(client, protocol.Response{
			Status:  "ok",
			RetCode: 0,
			Data:    map[string]interface{}{"participants": participants},
			Echo:    req.Echo,
		})

		// Broadcast join notice
		g.broadcastToConversation(groupID, protocol.NoticeEvent{
			PostType:   "notice",
			NoticeType: protocol.NoticeTypeGroupIncrease,
			GroupID:    groupID,
			UserID:     client.userID,
		}, "")
	} else {
		g.sendError(client, req.Echo, "failed to join group")
	}
}

func (g *Gateway) handleLeaveGroup(client *Client, req *protocol.Request) {
	if client.userID == "" {
		g.sendError(client, req.Echo, "not authenticated")
		return
	}

	params, ok := req.Params.(map[string]interface{})
	if !ok {
		g.sendError(client, req.Echo, "invalid params")
		return
	}

	groupID, _ := params["group_id"].(string)
	group, _ := g.store.GetGroup(groupID)
	if group == nil {
		g.sendError(client, req.Echo, "group not found")
		return
	}
	if group.OwnerID == client.userID {
		g.sendError(client, req.Echo, "group owner cannot leave")
		return
	}
	removeOk, err := g.store.RemoveGroupMember(groupID, client.userID)
	if err == nil && removeOk {
		if _, syncErr := g.syncGroupConversationParticipants(groupID); syncErr != nil {
			_, _ = g.store.AddGroupMember(groupID, client.userID)
			_, _ = g.syncGroupConversationParticipants(groupID)
			g.sendError(client, req.Echo, "failed to update group conversation")
			return
		}
		g.sendJSON(client, protocol.Response{
			Status:  "ok",
			RetCode: 0,
			Echo:    req.Echo,
		})

		notice := protocol.NoticeEvent{
			PostType:   "notice",
			NoticeType: protocol.NoticeTypeGroupDecrease,
			GroupID:    groupID,
			UserID:     client.userID,
			OperatorID: client.userID,
		}
		g.sendToUser(client.userID, notice)
		g.broadcastToConversation(groupID, protocol.NoticeEvent{
			PostType:   "notice",
			NoticeType: protocol.NoticeTypeGroupDecrease,
			GroupID:    groupID,
			UserID:     client.userID,
			OperatorID: client.userID,
		}, client.userID)
	} else {
		g.sendError(client, req.Echo, "failed to leave group")
	}
}

func (g *Gateway) handleGroupKick(client *Client, req *protocol.Request) {
	if client.userID == "" {
		g.sendError(client, req.Echo, "not authenticated")
		return
	}

	params, ok := req.Params.(map[string]interface{})
	if !ok {
		g.sendError(client, req.Echo, "invalid params")
		return
	}

	groupID, _ := params["group_id"].(string)
	userID, _ := params["user_id"].(string)
	group, _ := g.store.GetGroup(groupID)
	if group == nil {
		g.sendError(client, req.Echo, "group not found")
		return
	}
	actorRole := g.groupMemberRole(groupID, client.userID)
	targetRole := g.groupMemberRole(groupID, userID)
	canKick := canManageGroupMember(actorRole, targetRole)
	if !canKick || userID == client.userID || userID == group.OwnerID {
		g.sendError(client, req.Echo, "group permission denied")
		return
	}
	kickOk, err := g.store.RemoveGroupMember(groupID, userID)
	if err == nil && kickOk {
		if _, syncErr := g.syncGroupConversationParticipants(groupID); syncErr != nil {
			_, _ = g.store.AddGroupMember(groupID, userID)
			_, _ = g.syncGroupConversationParticipants(groupID)
			g.sendError(client, req.Echo, "failed to update group conversation")
			return
		}
		g.sendJSON(client, protocol.Response{
			Status:  "ok",
			RetCode: 0,
			Echo:    req.Echo,
		})

		notice := protocol.NoticeEvent{
			PostType:   "notice",
			NoticeType: protocol.NoticeTypeGroupDecrease,
			GroupID:    groupID,
			UserID:     userID,
			OperatorID: client.userID,
		}
		g.sendToUser(userID, notice)
		g.broadcastToConversation(groupID, notice, userID)
	} else {
		g.sendError(client, req.Echo, "failed to kick user")
	}
}

func (g *Gateway) handleGroupBan(client *Client, req *protocol.Request) {
	if client.userID == "" {
		g.sendError(client, req.Echo, "not authenticated")
		return
	}
	params, ok := req.Params.(map[string]interface{})
	if !ok {
		g.sendError(client, req.Echo, "invalid group_ban params")
		return
	}
	groupID, _ := params["group_id"].(string)
	userID, _ := params["user_id"].(string)
	durationValue, durationOK := params["duration"].(float64)
	duration := int64(durationValue)
	if groupID == "" || userID == "" || !durationOK || durationValue != float64(duration) || duration < 0 || duration > maxGroupBanSeconds {
		g.sendError(client, req.Echo, "duration must be 0-2592000 seconds")
		return
	}
	if group, _ := g.store.GetGroup(groupID); group == nil {
		g.sendError(client, req.Echo, "group not found")
		return
	}
	actorRole := g.groupMemberRole(groupID, client.userID)
	targetRole := g.groupMemberRole(groupID, userID)
	if userID == client.userID || !canManageGroupMember(actorRole, targetRole) {
		g.sendError(client, req.Echo, "group permission denied")
		return
	}
	mutedUntil := time.Time{}
	if duration > 0 {
		mutedUntil = time.Now().Add(time.Duration(duration) * time.Second)
	}
	if err := g.store.SetGroupMemberMute(groupID, userID, mutedUntil); err != nil {
		g.sendError(client, req.Echo, "failed to update member mute")
		return
	}
	g.sendJSON(client, protocol.Response{Status: "ok", RetCode: 0, Echo: req.Echo, Data: map[string]interface{}{
		"group_id": groupID, "user_id": userID, "muted_until": unixTimeOrZero(mutedUntil),
	}})
	g.broadcastToConversation(groupID, protocol.NoticeEvent{
		PostType: "notice", NoticeType: protocol.NoticeTypeGroupBan,
		GroupID: groupID, UserID: userID, OperatorID: client.userID,
		SubType: map[bool]string{true: "ban", false: "lift_ban"}[duration > 0], Duration: duration,
	}, "")
}

func (g *Gateway) handleUpdateGroup(client *Client, req *protocol.Request) {
	if client.userID == "" {
		g.sendError(client, req.Echo, "not authenticated")
		return
	}
	params, ok := req.Params.(map[string]interface{})
	if !ok {
		g.sendError(client, req.Echo, "invalid update_group params")
		return
	}
	groupID, _ := params["group_id"].(string)
	group, err := g.store.GetGroup(groupID)
	if err != nil || group == nil {
		g.sendError(client, req.Echo, "group not found")
		return
	}
	if !g.isGroupAdmin(groupID, client.userID) {
		g.sendError(client, req.Echo, "group permission denied")
		return
	}
	oldName, oldAvatar, oldAnnouncement := group.Name, group.Avatar, group.Announcement
	name, avatar, announcement := oldName, oldAvatar, oldAnnouncement
	changed := false
	if raw, exists := params["name"]; exists {
		value, valid := raw.(string)
		value = strings.TrimSpace(value)
		if !valid || value == "" || len(value) > 80 {
			g.sendError(client, req.Echo, "group name must be 1-80 characters")
			return
		}
		name, changed = value, true
	}
	if raw, exists := params["avatar_url"]; exists {
		value, valid := raw.(string)
		if !valid || len(value) > 2048 {
			g.sendError(client, req.Echo, "group avatar is invalid")
			return
		}
		avatar, changed = value, true
	}
	if raw, exists := params["announcement"]; exists {
		value, valid := raw.(string)
		value = strings.TrimSpace(value)
		if !valid || len(value) > 2000 {
			g.sendError(client, req.Echo, "group announcement is too long")
			return
		}
		announcement, changed = value, true
	}
	if !changed {
		g.sendError(client, req.Echo, "at least one group field is required")
		return
	}
	if err := g.store.UpdateGroup(groupID, name, avatar, announcement, group.MuteAll); err != nil {
		g.sendError(client, req.Echo, "failed to update group")
		return
	}
	if _, err := g.syncGroupConversationParticipants(groupID); err != nil {
		_ = g.store.UpdateGroup(groupID, oldName, oldAvatar, oldAnnouncement, group.MuteAll)
		g.sendError(client, req.Echo, "failed to update group conversation")
		return
	}
	g.sendJSON(client, protocol.Response{Status: "ok", RetCode: 0, Echo: req.Echo, Data: map[string]interface{}{
		"group_id": groupID, "name": name, "avatar_url": avatar, "announcement": announcement,
	}})
	g.broadcastToConversation(groupID, protocol.NoticeEvent{
		PostType: "notice", NoticeType: protocol.NoticeTypeGroupUpdate,
		GroupID: groupID, OperatorID: client.userID,
	}, "")
}

func (g *Gateway) handleSetGroupAdmin(client *Client, req *protocol.Request) {
	if client.userID == "" {
		g.sendError(client, req.Echo, "not authenticated")
		return
	}
	params, ok := req.Params.(map[string]interface{})
	if !ok {
		g.sendError(client, req.Echo, "invalid set_group_admin params")
		return
	}
	groupID, _ := params["group_id"].(string)
	userID, _ := params["user_id"].(string)
	enabled, enabledOK := params["enabled"].(bool)
	group, err := g.store.GetGroup(groupID)
	if err != nil || group == nil {
		g.sendError(client, req.Echo, "group not found")
		return
	}
	if group.OwnerID != client.userID || userID == client.userID {
		g.sendError(client, req.Echo, "only the group owner can manage administrators")
		return
	}
	targetRole := g.groupMemberRole(groupID, userID)
	if !enabledOK || targetRole == "" || targetRole == "owner" || enabled && targetRole != "member" || !enabled && targetRole != "admin" {
		g.sendError(client, req.Echo, "invalid administrator change")
		return
	}
	role := "member"
	if enabled {
		role = "admin"
	}
	if err := g.store.SetGroupMemberRole(groupID, userID, role); err != nil {
		g.sendError(client, req.Echo, "failed to update administrator")
		return
	}
	g.sendJSON(client, protocol.Response{Status: "ok", RetCode: 0, Echo: req.Echo})
	g.broadcastToConversation(groupID, protocol.NoticeEvent{
		PostType: "notice", NoticeType: protocol.NoticeTypeGroupAdmin,
		GroupID: groupID, UserID: userID, OperatorID: client.userID,
		SubType: map[bool]string{true: "set", false: "unset"}[enabled], Enabled: enabled,
	}, "")
}

func (g *Gateway) handleTransferGroup(client *Client, req *protocol.Request) {
	if client.userID == "" {
		g.sendError(client, req.Echo, "not authenticated")
		return
	}
	params, ok := req.Params.(map[string]interface{})
	if !ok {
		g.sendError(client, req.Echo, "invalid transfer_group params")
		return
	}
	groupID, _ := params["group_id"].(string)
	userID, _ := params["user_id"].(string)
	group, err := g.store.GetGroup(groupID)
	if err != nil || group == nil {
		g.sendError(client, req.Echo, "group not found")
		return
	}
	if group.OwnerID != client.userID || userID == client.userID || g.groupMemberRole(groupID, userID) == "" {
		g.sendError(client, req.Echo, "group ownership transfer denied")
		return
	}
	if err := g.store.TransferGroupOwnership(groupID, client.userID, userID); err != nil {
		g.sendError(client, req.Echo, "failed to transfer group ownership")
		return
	}
	if _, err := g.syncGroupConversationParticipants(groupID); err != nil {
		_ = g.store.TransferGroupOwnership(groupID, userID, client.userID)
		g.sendError(client, req.Echo, "failed to update group conversation")
		return
	}
	g.sendJSON(client, protocol.Response{Status: "ok", RetCode: 0, Echo: req.Echo})
	g.broadcastToConversation(groupID, protocol.NoticeEvent{
		PostType: "notice", NoticeType: protocol.NoticeTypeGroupTransfer,
		GroupID: groupID, UserID: userID, OperatorID: client.userID,
	}, "")
}

func (g *Gateway) handleDismissGroup(client *Client, req *protocol.Request) {
	if client.userID == "" {
		g.sendError(client, req.Echo, "not authenticated")
		return
	}
	params, ok := req.Params.(map[string]interface{})
	if !ok {
		g.sendError(client, req.Echo, "invalid dismiss_group params")
		return
	}
	groupID, _ := params["group_id"].(string)
	group, err := g.store.GetGroup(groupID)
	if err != nil || group == nil {
		g.sendError(client, req.Echo, "group not found")
		return
	}
	if group.OwnerID != client.userID {
		g.sendError(client, req.Echo, "only the group owner can dismiss the group")
		return
	}
	members, err := g.store.GetGroupMembers(groupID)
	if err != nil {
		g.sendError(client, req.Echo, "failed to load group members")
		return
	}
	if err := g.store.DeleteGroup(groupID); err != nil {
		g.sendError(client, req.Echo, "failed to dismiss group")
		return
	}
	g.sendJSON(client, protocol.Response{Status: "ok", RetCode: 0, Echo: req.Echo})
	notice := protocol.NoticeEvent{
		PostType: "notice", NoticeType: protocol.NoticeTypeGroupDismiss,
		GroupID: groupID, OperatorID: client.userID,
	}
	for _, member := range members {
		g.sendToUser(member.UserID, notice)
	}
}

func (g *Gateway) handleGroupMuteAll(client *Client, req *protocol.Request) {
	if client.userID == "" {
		g.sendError(client, req.Echo, "not authenticated")
		return
	}
	params, ok := req.Params.(map[string]interface{})
	if !ok {
		g.sendError(client, req.Echo, "invalid group_mute_all params")
		return
	}
	groupID, _ := params["group_id"].(string)
	enabled, enabledOK := params["enabled"].(bool)
	group, err := g.store.GetGroup(groupID)
	if err != nil || group == nil {
		g.sendError(client, req.Echo, "group not found")
		return
	}
	if !enabledOK || !g.isGroupAdmin(groupID, client.userID) {
		g.sendError(client, req.Echo, "group permission denied")
		return
	}
	if err := g.store.UpdateGroup(groupID, group.Name, group.Avatar, group.Announcement, enabled); err != nil {
		g.sendError(client, req.Echo, "failed to update group mute")
		return
	}
	g.sendJSON(client, protocol.Response{Status: "ok", RetCode: 0, Echo: req.Echo})
	g.broadcastToConversation(groupID, protocol.NoticeEvent{
		PostType: "notice", NoticeType: protocol.NoticeTypeGroupMuteAll,
		GroupID: groupID, OperatorID: client.userID,
		SubType: map[bool]string{true: "enable", false: "disable"}[enabled], Enabled: enabled,
	}, "")
}

func (g *Gateway) handleFriendRequest(client *Client, req *protocol.Request) {
	if client.userID == "" {
		g.sendError(client, req.Echo, "not authenticated")
		return
	}

	params, ok := req.Params.(map[string]interface{})
	if !ok {
		g.sendError(client, req.Echo, "invalid params")
		return
	}

	targetID, _ := params["user_id"].(string)
	comment, _ := params["comment"].(string)
	targetID = strings.TrimSpace(targetID)
	comment = strings.TrimSpace(comment)
	if targetID == "" || targetID == client.userID {
		g.sendError(client, req.Echo, "valid target user required")
		return
	}
	if len(comment) > 200 {
		g.sendError(client, req.Echo, "comment is too long")
		return
	}
	if target, _ := g.store.GetUser(targetID); target == nil {
		g.sendError(client, req.Echo, "user not found")
		return
	}
	if friends, _ := g.store.AreFriends(client.userID, targetID); friends {
		g.sendError(client, req.Echo, "already friends")
		return
	}
	pending, _ := g.store.GetPendingFriendRequests(client.userID)
	for _, existing := range pending {
		if (existing.FromID == client.userID && existing.ToID == targetID) ||
			(existing.FromID == targetID && existing.ToID == client.userID) {
			g.sendError(client, req.Echo, "friend request already pending")
			return
		}
	}

	friendReq, err := g.store.CreateFriendRequest(client.userID, targetID, comment)
	if err != nil || friendReq == nil {
		g.sendError(client, req.Echo, "failed to create friend request")
		return
	}

	// Notify target user
	g.sendToUser(targetID, protocol.RequestEvent{
		PostType:    "request",
		RequestType: protocol.RequestTypeFriend,
		UserID:      client.userID,
		Comment:     comment,
		Flag:        friendReq.ID,
	})
	requesterName := client.userID
	if requester, _ := g.store.GetUser(client.userID); requester != nil && requester.Nickname != "" {
		requesterName = requester.Nickname
	}
	body := requesterName + " wants to connect"
	if comment != "" {
		body += ": " + comment
	}
	g.pushEventToUser(targetID, map[string]interface{}{
		"type":       "friend_request",
		"title":      "New friend request",
		"body":       body,
		"request_id": friendReq.ID,
		"user_id":    client.userID,
		"path":       "/contacts",
	}, "friend request "+friendReq.ID)

	g.sendJSON(client, protocol.Response{
		Status:  "ok",
		RetCode: 0,
		Data: map[string]interface{}{
			"flag": friendReq.ID,
		},
		Echo: req.Echo,
	})
}

func (g *Gateway) handleFriendHandle(client *Client, req *protocol.Request) {
	if client.userID == "" {
		g.sendError(client, req.Echo, "not authenticated")
		return
	}

	params, ok := req.Params.(map[string]interface{})
	if !ok {
		g.sendError(client, req.Echo, "invalid params")
		return
	}

	flag, _ := params["flag"].(string)
	action, _ := params["action"].(string)
	friendReq, _ := g.store.GetFriendRequest(flag)
	if friendReq == nil || friendReq.ToID != client.userID || friendReq.Status != "pending" {
		g.sendError(client, req.Echo, "friend request not found")
		return
	}
	normalizedAction := ""
	switch action {
	case "accept", "accepted":
		normalizedAction = "accepted"
	case "reject", "rejected":
		normalizedAction = "rejected"
	default:
		g.sendError(client, req.Echo, "action must be accept or reject")
		return
	}
	friendAdded := false
	if normalizedAction == "accepted" {
		var err error
		friendAdded, err = g.store.AddFriend(friendReq.FromID, friendReq.ToID)
		if err != nil {
			g.sendError(client, req.Echo, "failed to add friend")
			return
		}
	}
	handleOk, err := g.store.HandleFriendRequest(flag, normalizedAction)
	if (err != nil || !handleOk) && friendAdded {
		_, _ = g.store.RemoveFriend(friendReq.FromID, friendReq.ToID)
	}
	if handleOk {
		g.sendJSON(client, protocol.Response{
			Status:  "ok",
			RetCode: 0,
			Echo:    req.Echo,
		})

		// Notify requester
		if normalizedAction == "accepted" {
			g.sendToUser(friendReq.FromID, protocol.NoticeEvent{
				PostType:   "notice",
				NoticeType: protocol.NoticeTypeFriendAdd,
				UserID:     client.userID,
			})
		} else {
			g.sendToUser(friendReq.FromID, protocol.NoticeEvent{
				PostType:   "notice",
				NoticeType: protocol.NoticeTypeFriendRequestResult,
				UserID:     client.userID,
				SubType:    normalizedAction,
			})
		}
		handlerName := client.userID
		if handler, _ := g.store.GetUser(client.userID); handler != nil && handler.Nickname != "" {
			handlerName = handler.Nickname
		}
		resultText := "declined your friend request"
		if normalizedAction == "accepted" {
			resultText = "accepted your friend request"
		}
		g.pushEventToUser(friendReq.FromID, map[string]interface{}{
			"type":       "friend_request_result",
			"title":      "Friend request updated",
			"body":       handlerName + " " + resultText,
			"request_id": friendReq.ID,
			"user_id":    client.userID,
			"path":       "/contacts",
		}, "friend request result "+friendReq.ID)
	} else {
		g.sendError(client, req.Echo, "failed to handle request")
	}
}

func (g *Gateway) handleCreateForward(client *Client, req *protocol.Request) {
	if client.userID == "" {
		g.sendError(client, req.Echo, "not authenticated")
		return
	}
	params, ok := req.Params.(map[string]interface{})
	if !ok {
		g.sendError(client, req.Echo, "invalid create_forward params")
		return
	}
	conversationID, _ := params["conversation_id"].(string)
	if conversationID == "" || !g.canAccessConversation(client.userID, conversationID) {
		g.sendError(client, req.Echo, "conversation access denied")
		return
	}
	rawIDs, ok := params["message_ids"].([]interface{})
	if !ok || len(rawIDs) == 0 || len(rawIDs) > 100 {
		g.sendError(client, req.Echo, "message_ids must contain between 1 and 100 messages")
		return
	}
	messages := make([]*store.Message, 0, len(rawIDs))
	seen := make(map[string]bool, len(rawIDs))
	for _, rawID := range rawIDs {
		messageID, ok := rawID.(string)
		if !ok || strings.TrimSpace(messageID) == "" || seen[messageID] {
			g.sendError(client, req.Echo, "message_ids contains an invalid or duplicate ID")
			return
		}
		seen[messageID] = true
		message, err := g.store.GetMessage(messageID)
		if err != nil || message == nil || message.Recalled || !g.canAccessConversation(client.userID, message.ConversationID) {
			g.sendError(client, req.Echo, "forward source message is unavailable")
			return
		}
		encoded, err := json.Marshal(message)
		if err != nil {
			g.sendError(client, req.Echo, "failed to copy forward source message")
			return
		}
		var snapshot store.Message
		if err := json.Unmarshal(encoded, &snapshot); err != nil {
			g.sendError(client, req.Echo, "failed to copy forward source message")
			return
		}
		messages = append(messages, &snapshot)
	}
	forward, err := g.store.StoreForward(conversationID, messages)
	if err != nil {
		g.sendError(client, req.Echo, "failed to create forward")
		return
	}
	g.sendJSON(client, protocol.Response{
		Status: "ok", RetCode: 0, Echo: req.Echo,
		Data: map[string]interface{}{"forward_id": forward.ID, "count": len(messages)},
	})
}

func (g *Gateway) handleGetForwardMessage(client *Client, req *protocol.Request) {
	if client.userID == "" {
		g.sendError(client, req.Echo, "not authenticated")
		return
	}
	params, ok := req.Params.(map[string]interface{})
	if !ok {
		g.sendError(client, req.Echo, "invalid params")
		return
	}

	forwardID, _ := params["forward_id"].(string)
	forward, _ := g.store.GetForward(forwardID)
	if forward == nil {
		g.sendError(client, req.Echo, "forward not found")
		return
	}
	if forward.ConversationID == "" || !g.canAccessConversation(client.userID, forward.ConversationID) {
		g.sendError(client, req.Echo, "forward access denied")
		return
	}

	result := make([]map[string]interface{}, len(forward.Messages))
	for i, msg := range forward.Messages {
		result[i] = map[string]interface{}{
			"message_id": msg.ID,
			"sender": map[string]interface{}{
				"user_id":  msg.SenderID,
				"nickname": msg.SenderNickname,
			},
			"message":   msg.Segments,
			"timestamp": msg.Timestamp.Unix(),
		}
	}

	g.sendJSON(client, protocol.Response{
		Status:  "ok",
		RetCode: 0,
		Data:    result,
		Echo:    req.Echo,
	})
}

func (g *Gateway) handleUploadFile(client *Client, req *protocol.Request) {
	if client.userID == "" {
		g.sendError(client, req.Echo, "not authenticated")
		return
	}

	params, ok := req.Params.(map[string]interface{})
	if !ok {
		g.sendError(client, req.Echo, "invalid params")
		return
	}

	fileName, _ := params["file_name"].(string)
	fileData, _ := params["file"].(string)
	fileType, _ := params["file_type"].(string)
	mimeType, _ := params["mime_type"].(string)

	if fileName == "" || fileData == "" {
		g.sendError(client, req.Echo, "file_name and file required")
		return
	}
	if fileType != "image" && fileType != "voice" && fileType != "video" && fileType != "file" {
		g.sendError(client, req.Echo, "invalid file_type")
		return
	}
	if g.media == nil {
		g.sendError(client, req.Echo, "media storage is not configured")
		return
	}
	maxBytes := 20 * 1024 * 1024
	if fileType == "voice" {
		maxBytes = 10 * 1024 * 1024
	}
	if len(fileData) > (maxBytes*4/3)+16 {
		g.sendError(client, req.Echo, "file exceeds the size limit")
		return
	}
	data, err := base64.StdEncoding.DecodeString(fileData)
	if err != nil {
		g.sendError(client, req.Echo, "invalid base64 file data")
		return
	}
	if len(data) == 0 || len(data) > maxBytes {
		g.sendError(client, req.Echo, "file exceeds the size limit")
		return
	}
	media, err := g.media.Save(fileName, fileType, mimeType, data, client.userID)
	if err != nil {
		log.Printf("[media] upload failed for %s: %v", client.userID, err)
		g.sendError(client, req.Echo, "failed to store file")
		return
	}

	g.sendJSON(client, protocol.Response{
		Status:  "ok",
		RetCode: 0,
		Data: map[string]interface{}{
			"file_id":       media.ID,
			"url":           media.URL,
			"thumbnail_url": media.ThumbnailURL,
			"mime_type":     media.MimeType,
			"size":          media.Size,
			"width":         media.Width,
			"height":        media.Height,
		},
		Echo: req.Echo,
	})
}

func (g *Gateway) handleGetPushConfig(client *Client, req *protocol.Request) {
	if client.userID == "" {
		g.sendError(client, req.Echo, "not authenticated")
		return
	}

	publicKey := ""
	enabled := g.pushSender != nil && g.pushSender.Enabled()
	if enabled {
		publicKey = g.pushSender.PublicKey()
	}
	g.sendJSON(client, protocol.Response{
		Status:  "ok",
		RetCode: 0,
		Data: map[string]interface{}{
			"enabled":    enabled,
			"public_key": publicKey,
		},
		Echo: req.Echo,
	})
}

func (g *Gateway) handleRegisterPush(client *Client, req *protocol.Request) {
	if client.userID == "" {
		g.sendError(client, req.Echo, "not authenticated")
		return
	}
	if g.pushSender == nil || !g.pushSender.Enabled() {
		g.sendError(client, req.Echo, "web push is not configured")
		return
	}

	params, ok := req.Params.(map[string]interface{})
	if !ok {
		g.sendError(client, req.Echo, "invalid push subscription")
		return
	}
	endpoint, _ := params["endpoint"].(string)
	keys, _ := params["keys"].(map[string]interface{})
	p256dh, _ := keys["p256dh"].(string)
	auth, _ := keys["auth"].(string)
	if endpoint == "" || p256dh == "" || auth == "" {
		g.sendError(client, req.Echo, "endpoint, keys.p256dh, and keys.auth are required")
		return
	}

	if err := g.store.UpsertPushSubscription(&store.PushSubscription{
		UserID:   client.userID,
		Endpoint: endpoint,
		P256DH:   p256dh,
		Auth:     auth,
	}); err != nil {
		g.sendError(client, req.Echo, "failed to save push subscription")
		return
	}
	log.Printf("[push] subscription registered for %s", client.userID)
	g.sendJSON(client, protocol.Response{
		Status: "ok", RetCode: 0, Echo: req.Echo,
	})
}

func (g *Gateway) handleUnregisterPush(client *Client, req *protocol.Request) {
	if client.userID == "" {
		g.sendError(client, req.Echo, "not authenticated")
		return
	}
	params, ok := req.Params.(map[string]interface{})
	if !ok {
		g.sendError(client, req.Echo, "invalid unregister_push params")
		return
	}
	endpoint, _ := params["endpoint"].(string)
	if endpoint == "" {
		g.sendError(client, req.Echo, "endpoint required")
		return
	}
	if err := g.store.DeletePushSubscription(client.userID, endpoint); err != nil {
		g.sendError(client, req.Echo, "failed to delete push subscription")
		return
	}
	log.Printf("[push] subscription removed for %s", client.userID)
	g.sendJSON(client, protocol.Response{
		Status: "ok", RetCode: 0, Echo: req.Echo,
	})
}

// Client management.

func (g *Gateway) addClient(client *Client, userID string) (bool, error) {
	g.mu.Lock()
	defer g.mu.Unlock()
	if client.userID != "" {
		return false, nil
	}
	clients := g.clients[userID]
	firstConnection := len(clients) == 0
	if firstConnection {
		if err := g.store.SetUserOnline(userID, true); err != nil {
			return false, err
		}
	}
	client.userID = userID
	if clients == nil {
		clients = make(map[*Client]struct{})
		g.clients[userID] = clients
	}
	clients[client] = struct{}{}
	return firstConnection, nil
}

func (g *Gateway) removeClient(client *Client) {
	userID, lastConnection := g.detachClient(client)
	client.closeSend()
	if !lastConnection {
		return
	}
	g.notifyFriendPresence(userID, false)
}

func (g *Gateway) detachClient(client *Client) (string, bool) {
	g.mu.Lock()
	defer g.mu.Unlock()
	userID := client.userID
	if userID == "" {
		return "", false
	}
	client.userID = ""
	clients := g.clients[userID]
	if clients == nil {
		return userID, false
	}
	delete(clients, client)
	lastConnection := len(clients) == 0
	if lastConnection {
		delete(g.clients, userID)
		if err := g.store.SetUserOnline(userID, false); err != nil {
			log.Printf("[gateway] failed to mark %s offline: %v", userID, err)
		}
	}
	return userID, lastConnection
}

func (g *Gateway) broadcastToConversation(convID string, event interface{}, excludeUserID string) {
	data, err := json.Marshal(event)
	if err != nil {
		return
	}

	conv, _ := g.store.GetConversation(convID)
	if conv == nil {
		return
	}

	var clients []*Client
	if conv.Type == "private" {
		// For private conversations, send to participants
		for _, userID := range conv.Participants {
			if userID == excludeUserID {
				continue
			}
			clients = append(clients, g.clientsForUser(userID)...)
		}
	} else {
		// For group conversations, send to all group members
		members, _ := g.store.GetGroupMembers(convID)
		for _, member := range members {
			if member.UserID == excludeUserID {
				continue
			}
			clients = append(clients, g.clientsForUser(member.UserID)...)
		}
	}
	for _, client := range clients {
		client.enqueue(data)
	}
}

func (g *Gateway) pushToConversation(convID string, message *store.Message, excludeUserID string, important bool) {
	if g.pushSender == nil || !g.pushSender.Enabled() {
		return
	}
	recipients := g.conversationRecipients(convID, excludeUserID)
	if len(recipients) == 0 {
		return
	}
	payload, err := json.Marshal(map[string]interface{}{
		"title":           message.SenderNickname,
		"body":            pushBody(message.Segments),
		"conversation_id": message.ConversationID,
		"message_id":      message.ID,
	})
	if err != nil {
		return
	}

	go func() {
		for _, userID := range recipients {
			preference, err := g.store.GetConversationPreference(convID, userID)
			if err != nil {
				log.Printf("[push] failed to load conversation preferences for %s: %v", userID, err)
				continue
			}
			level := conversationNotificationLevel(preference)
			if level == store.NotificationLevelMuted ||
				(level == store.NotificationLevelMentionsOnly && !important && !messageMentionsUser(message.Segments, userID)) {
				continue
			}
			subscriptions, err := g.store.GetPushSubscriptions(userID)
			if err != nil {
				log.Printf("[push] failed to load subscriptions for %s: %v", userID, err)
				continue
			}
			for _, subscription := range subscriptions {
				ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
				expired, sendErr := g.pushSender.Send(ctx, subscription, payload)
				cancel()
				if expired {
					if err := g.store.DeletePushSubscription(userID, subscription.Endpoint); err != nil {
						log.Printf("[push] failed to remove expired subscription for %s: %v", userID, err)
					}
					continue
				}
				if sendErr != nil {
					log.Printf("[push] delivery failed for %s: %v", userID, sendErr)
					continue
				}
				log.Printf("[push] delivered message %s to %s", message.ID, userID)
			}
		}
	}()
}

func messageMentionsUser(segments []protocol.MessageSegment, userID string) bool {
	for _, segment := range segments {
		if segment.Type != "at" {
			continue
		}
		for _, key := range []string{"qq", "user_id", "target_id"} {
			target, _ := segment.Data[key].(string)
			if target == userID || target == "all" {
				return true
			}
		}
	}
	return false
}

func (g *Gateway) pushEventToUser(
	userID string,
	payload map[string]interface{},
	description string,
) {
	if g.pushSender == nil || !g.pushSender.Enabled() || userID == "" {
		return
	}
	encoded, err := json.Marshal(payload)
	if err != nil {
		return
	}
	go func() {
		subscriptions, err := g.store.GetPushSubscriptions(userID)
		if err != nil {
			log.Printf("[push] failed to load subscriptions for %s: %v", userID, err)
			return
		}
		for _, subscription := range subscriptions {
			ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
			expired, sendErr := g.pushSender.Send(ctx, subscription, encoded)
			cancel()
			if expired {
				if err := g.store.DeletePushSubscription(userID, subscription.Endpoint); err != nil {
					log.Printf("[push] failed to remove expired subscription for %s: %v", userID, err)
				}
				continue
			}
			if sendErr != nil {
				log.Printf("[push] delivery failed for %s: %v", userID, sendErr)
				continue
			}
			log.Printf("[push] delivered %s to %s", description, userID)
		}
	}()
}

func (g *Gateway) notifyProfileUpdate(user *store.User, exclude *Client) {
	if user == nil {
		return
	}
	event := protocol.NoticeEvent{
		PostType:       "notice",
		NoticeType:     protocol.NoticeTypeProfileUpdate,
		UserID:         user.ID,
		Nickname:       user.Nickname,
		Avatar:         user.Avatar,
		ProfileVersion: time.Now().UnixMilli(),
	}
	data, err := json.Marshal(event)
	if err == nil {
		for _, registered := range g.clientsForUser(user.ID) {
			if registered != exclude {
				registered.enqueue(data)
			}
		}
	}
	friends, err := g.store.GetFriends(user.ID)
	if err != nil {
		return
	}
	for _, friend := range friends {
		if friend != nil && friend.ID != user.ID {
			g.sendToUser(friend.ID, event)
		}
	}
}

func (g *Gateway) conversationRecipients(convID, excludeUserID string) []string {
	conversation, err := g.store.GetConversation(convID)
	if err != nil || conversation == nil {
		return nil
	}

	candidates := conversation.Participants
	if conversation.Type != "private" {
		members, err := g.store.GetGroupMembers(convID)
		if err != nil {
			return nil
		}
		candidates = make([]string, 0, len(members))
		for _, member := range members {
			candidates = append(candidates, member.UserID)
		}
	}

	seen := make(map[string]bool, len(candidates))
	recipients := make([]string, 0, len(candidates))
	for _, userID := range candidates {
		if userID == "" || userID == excludeUserID || seen[userID] {
			continue
		}
		seen[userID] = true
		recipients = append(recipients, userID)
	}
	return recipients
}

func pushBody(segments []protocol.MessageSegment) string {
	var text strings.Builder
	for _, segment := range segments {
		switch segment.Type {
		case "text":
			if value, ok := segment.Data["text"].(string); ok {
				text.WriteString(value)
			}
		case "image":
			text.WriteString("[Image]")
		case "record":
			text.WriteString("[Voice message]")
		case "video":
			text.WriteString("[Video]")
		case "file":
			text.WriteString("[File]")
		case "sticker":
			text.WriteString("[Sticker]")
		case "share":
			if title, ok := segment.Data["title"].(string); ok && strings.TrimSpace(title) != "" {
				text.WriteString("[Link] " + title)
			} else {
				text.WriteString("[Link]")
			}
		case "location":
			if name, ok := segment.Data["name"].(string); ok && strings.TrimSpace(name) != "" {
				text.WriteString("[Location] " + name)
			} else {
				text.WriteString("[Location]")
			}
		case "forward":
			text.WriteString("[Chat records]")
		case "poke":
			text.WriteString("[Poke]")
		case "system":
			if value, ok := segment.Data["text"].(string); ok {
				text.WriteString(value)
			} else {
				text.WriteString("[System message]")
			}
		}
	}
	result := strings.TrimSpace(text.String())
	if result == "" {
		return "New message"
	}
	const maxRunes = 160
	runes := []rune(result)
	if len(runes) > maxRunes {
		return string(runes[:maxRunes]) + "..."
	}
	return result
}

func (g *Gateway) sendToUser(userID string, event interface{}) {
	data, err := json.Marshal(event)
	if err != nil {
		return
	}

	for _, client := range g.clientsForUser(userID) {
		client.enqueue(data)
	}
}

func (g *Gateway) clientsForUser(userID string) []*Client {
	g.mu.RLock()
	defer g.mu.RUnlock()
	clients := make([]*Client, 0, len(g.clients[userID]))
	for client := range g.clients[userID] {
		clients = append(clients, client)
	}
	return clients
}

func (g *Gateway) notifyFriendPresence(userID string, online bool) {
	friends, err := g.store.GetFriends(userID)
	if err != nil {
		log.Printf("[gateway] failed to load friends for presence of %s: %v", userID, err)
		return
	}
	event := protocol.NoticeEvent{
		PostType:   "notice",
		NoticeType: protocol.NoticeTypeFriendPresence,
		UserID:     userID,
		Online:     &online,
	}
	for _, friend := range friends {
		g.sendToUser(friend.ID, event)
	}
}

// Helpers.

func (g *Gateway) sendJSON(client *Client, v interface{}) {
	data, err := json.Marshal(v)
	if err != nil {
		log.Printf("[gateway] marshal error: %v", err)
		return
	}
	if !client.enqueue(data) {
		log.Printf("[gateway] client %s buffer full", client.userID)
	}
}

func (g *Gateway) sendError(client *Client, echo string, msg string) {
	g.sendJSON(client, protocol.Response{
		Status:  "error",
		RetCode: 100,
		Msg:     msg,
		Echo:    echo,
	})
}
