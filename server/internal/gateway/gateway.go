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
	"net/http"
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
	conn   *websocket.Conn
	userID string
	send   chan []byte
}

// Gateway manages WebSocket connections and message routing.
type Gateway struct {
	store       store.Store
	pushSender  PushSender
	media       MediaUploader
	accessToken string
	inviteCode  string
	upgrader    websocket.Upgrader

	mu      sync.RWMutex
	clients map[string]*Client // userID -> Client
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
		clients: make(map[string]*Client),
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
	g.inviteCode = strings.TrimSpace(code)
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
	case protocol.ActionGetConversations:
		g.handleGetConversations(client, req)
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
	case protocol.ActionJoinGroup:
		g.handleJoinGroup(client, req)
	case protocol.ActionLeaveGroup:
		g.handleLeaveGroup(client, req)
	case protocol.ActionGroupKick:
		g.handleGroupKick(client, req)
	case protocol.ActionGroupBan:
		g.handleGroupBan(client, req)
	case protocol.ActionFriendRequest:
		g.handleFriendRequest(client, req)
	case protocol.ActionFriendHandle:
		g.handleFriendHandle(client, req)
	case protocol.ActionGetForwardMessage:
		g.handleGetForwardMessage(client, req)
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

	// Register client.
	g.addClient(client, userID)

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
			Online:   true,
		}
		g.store.SetUser(user)
	} else {
		g.store.SetUserOnline(userID, true)
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
	userID = strings.TrimSpace(userID)
	nickname = strings.TrimSpace(nickname)
	inviteCode = strings.TrimSpace(inviteCode)
	if g.inviteCode == "" {
		g.sendError(client, req.Echo, "registration is disabled")
		return
	}
	configuredInvite := sha256.Sum256([]byte(g.inviteCode))
	providedInvite := sha256.Sum256([]byte(inviteCode))
	if subtle.ConstantTimeCompare(configuredInvite[:], providedInvite[:]) != 1 {
		g.sendError(client, req.Echo, "invalid invite code")
		return
	}
	if !validUserID(userID) || len(userID) < 3 || len(userID) > 32 {
		g.sendError(client, req.Echo, "user_id must be 3-32 characters")
		return
	}
	if len(password) < 8 || len(password) > 128 {
		g.sendError(client, req.Echo, "password must be 8-128 characters")
		return
	}
	if nickname == "" {
		nickname = userID
	}
	if len(nickname) > 64 {
		g.sendError(client, req.Echo, "nickname is too long")
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
	user := &store.User{ID: userID, Nickname: nickname, PasswordHash: string(hash), Online: true, CreatedAt: time.Now()}
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
	members, err := g.store.GetGroupMembers(groupID)
	if err != nil {
		return false
	}
	for _, member := range members {
		if member.UserID == userID {
			return member.Role == "owner" || member.Role == "admin"
		}
	}
	return false
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

	// Ensure conversation exists.
	convType := "private"
	if len(convID) > 6 && convID[:6] == "group_" {
		convType = "group"
	}
	if !g.canAccessConversation(client.userID, convID) {
		g.sendError(client, req.Echo, "conversation access denied")
		return
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
		Timestamp: msg.Timestamp.Unix(),
	}
	g.broadcastToConversation(convID, event, client.userID)
	g.pushToConversation(convID, msg, client.userID)

	log.Printf("[gateway] message %s sent to %s by %s", msg.ID, convID, client.userID)
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

	msg, _ := g.store.GetMessage(msgID)
	if msg == nil {
		g.sendError(client, req.Echo, "message not found")
		return
	}

	if msg.SenderID != client.userID {
		g.sendError(client, req.Echo, "not your message")
		return
	}

	recalled, _ := g.store.RecallMessage(msgID)
	if recalled {
		g.sendJSON(client, protocol.Response{
			Status:  "ok",
			RetCode: 0,
			Echo:    req.Echo,
		})

		// Broadcast recall notice
		g.broadcastToConversation(msg.ConversationID, protocol.NoticeEvent{
			PostType:   "notice",
			NoticeType: protocol.NoticeTypeFriendRecall,
			MessageID:  msgID,
			UserID:     client.userID,
		}, "")
	}
}

func (g *Gateway) handleGetConversations(client *Client, req *protocol.Request) {
	if client.userID == "" {
		g.sendError(client, req.Echo, "not authenticated")
		return
	}

	convs, _ := g.store.GetUserConversations(client.userID)
	result := make([]protocol.Conversation, len(convs))
	for i, conv := range convs {
		lastMsg := ""
		var lastTs int64
		msgs, _ := g.store.GetMessages(conv.ID, 1)
		if len(msgs) > 0 {
			if len(msgs[0].Segments) > 0 && msgs[0].Segments[0].Type == "text" {
				lastMsg, _ = msgs[0].Segments[0].Data["text"].(string)
			}
			lastTs = msgs[0].Timestamp.Unix()
		}
		result[i] = protocol.Conversation{
			ConversationID: conv.ID,
			Type:           conv.Type,
			Title:          conv.Title,
			Avatar:         conv.Avatar,
			LastMessage:    lastMsg,
			LastTimestamp:  lastTs,
			Participants:   conv.Participants,
		}
	}

	g.sendJSON(client, protocol.Response{
		Status:  "ok",
		RetCode: 0,
		Data:    result,
		Echo:    req.Echo,
	})
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

	msgs, _ := g.store.GetMessages(convID, limit)
	result := make([]map[string]interface{}, len(msgs))
	for i, msg := range msgs {
		senderAvatar := ""
		if sender, err := g.store.GetUser(msg.SenderID); err == nil && sender != nil {
			senderAvatar = sender.Avatar
		}
		result[i] = map[string]interface{}{
			"message_id":      msg.ID,
			"conversation_id": msg.ConversationID,
			"sender": map[string]interface{}{
				"user_id":    msg.SenderID,
				"nickname":   msg.SenderNickname,
				"avatar_url": senderAvatar,
			},
			"message":   msg.Segments,
			"timestamp": msg.Timestamp.Unix(),
			"recalled":  msg.Recalled,
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
	// For MVP, just acknowledge
	g.sendJSON(client, protocol.Response{
		Status:  "ok",
		RetCode: 0,
		Echo:    req.Echo,
	})
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
			GroupID:     grp.ID,
			Name:        grp.Name,
			Avatar:      grp.Avatar,
			OwnerID:     grp.OwnerID,
			MemberCount: len(grp.Members),
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
		if user != nil {
			nickname = user.Nickname
		}
		memberList[i] = protocol.GroupMember{
			UserID:   m.UserID,
			Nickname: nickname,
			Role:     m.Role,
		}
	}

	g.sendJSON(client, protocol.Response{
		Status:  "ok",
		RetCode: 0,
		Data: map[string]interface{}{
			"group_id":     group.ID,
			"name":         group.Name,
			"avatar_url":   group.Avatar,
			"owner_id":     group.OwnerID,
			"member_count": len(group.Members),
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
	groupID := fmt.Sprintf("group_%d", time.Now().UnixNano())
	group, err := g.store.CreateGroup(groupID, name, avatar, client.userID)
	if err != nil || group == nil {
		g.sendError(client, req.Echo, "failed to create group")
		return
	}
	participants := []string{client.userID}
	seen := map[string]bool{client.userID: true}
	// Add members if provided, but never create references to unknown users.
	if members, ok := params["members"].([]interface{}); ok {
		for _, m := range members {
			if memberID, ok := m.(string); ok && validUserID(memberID) && !seen[memberID] {
				if user, _ := g.store.GetUser(memberID); user != nil {
					if added, addErr := g.store.AddGroupMember(groupID, memberID); addErr == nil && added {
						participants = append(participants, memberID)
						seen[memberID] = true
					}
				}
			}
		}
	}
	if err := g.store.SaveConversation(&store.Conversation{ID: groupID, Type: "group", Title: name, Avatar: avatar, OwnerID: client.userID, Participants: participants, CreatedAt: time.Now()}); err != nil {
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
		g.sendJSON(client, protocol.Response{
			Status:  "ok",
			RetCode: 0,
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
		g.sendJSON(client, protocol.Response{
			Status:  "ok",
			RetCode: 0,
			Echo:    req.Echo,
		})

		// Broadcast leave notice
		g.broadcastToConversation(groupID, protocol.NoticeEvent{
			PostType:   "notice",
			NoticeType: protocol.NoticeTypeGroupDecrease,
			GroupID:    groupID,
			UserID:     client.userID,
		}, "")
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
	if !g.isGroupAdmin(groupID, client.userID) || userID == group.OwnerID {
		g.sendError(client, req.Echo, "group permission denied")
		return
	}
	kickOk, err := g.store.RemoveGroupMember(groupID, userID)
	if err == nil && kickOk {
		g.sendJSON(client, protocol.Response{
			Status:  "ok",
			RetCode: 0,
			Echo:    req.Echo,
		})

		g.broadcastToConversation(groupID, protocol.NoticeEvent{
			PostType:   "notice",
			NoticeType: protocol.NoticeTypeGroupDecrease,
			GroupID:    groupID,
			UserID:     userID,
			OperatorID: client.userID,
		}, "")
	} else {
		g.sendError(client, req.Echo, "failed to kick user")
	}
}

func (g *Gateway) handleGroupBan(client *Client, req *protocol.Request) {
	// TODO: Implement group ban
	g.sendError(client, req.Echo, "not implemented")
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
		}
	} else {
		g.sendError(client, req.Echo, "failed to handle request")
	}
}

func (g *Gateway) handleGetForwardMessage(client *Client, req *protocol.Request) {
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
	if len(fileData) > 28*1024*1024 {
		g.sendError(client, req.Echo, "file is larger than 20 MB")
		return
	}
	data, err := base64.StdEncoding.DecodeString(fileData)
	if err != nil {
		g.sendError(client, req.Echo, "invalid base64 file data")
		return
	}
	if len(data) == 0 || len(data) > 20*1024*1024 {
		g.sendError(client, req.Echo, "file must be between 1 byte and 20 MB")
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
			"file_id":   media.ID,
			"url":       media.URL,
			"mime_type": media.MimeType,
			"size":      media.Size,
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

func (g *Gateway) addClient(client *Client, userID string) {
	g.mu.Lock()
	defer g.mu.Unlock()
	client.userID = userID
	g.clients[userID] = client
}

func (g *Gateway) removeClient(client *Client) {
	g.mu.Lock()
	defer g.mu.Unlock()
	if client.userID != "" {
		g.store.SetUserOnline(client.userID, false)
		if existing, ok := g.clients[client.userID]; ok && existing == client {
			delete(g.clients, client.userID)
		}
	}
	close(client.send)
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

	g.mu.RLock()
	defer g.mu.RUnlock()

	if conv.Type == "private" {
		// For private conversations, send to participants
		for _, userID := range conv.Participants {
			if userID == excludeUserID {
				continue
			}
			if client, ok := g.clients[userID]; ok {
				select {
				case client.send <- data:
				default:
				}
			}
		}
	} else {
		// For group conversations, send to all group members
		members, _ := g.store.GetGroupMembers(convID)
		for _, member := range members {
			if member.UserID == excludeUserID {
				continue
			}
			if client, ok := g.clients[member.UserID]; ok {
				select {
				case client.send <- data:
				default:
				}
			}
		}
	}
}

func (g *Gateway) pushToConversation(convID string, message *store.Message, excludeUserID string) {
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

	g.mu.RLock()
	defer g.mu.RUnlock()

	if client, ok := g.clients[userID]; ok {
		select {
		case client.send <- data:
		default:
		}
	}
}

// Helpers.

func (g *Gateway) sendJSON(client *Client, v interface{}) {
	data, err := json.Marshal(v)
	if err != nil {
		log.Printf("[gateway] marshal error: %v", err)
		return
	}
	select {
	case client.send <- data:
	default:
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
