package gateway

import (
	"context"
	"crypto/subtle"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"strings"
	"sync"
	"time"
	"unicode"

	"github.com/gorilla/websocket"
	"github.com/icradp/zzz-im-server/internal/protocol"
	"github.com/icradp/zzz-im-server/internal/store"
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
	case protocol.ActionGetUsers:
		g.handleGetUsers(client, req)
	case protocol.ActionGetFriends:
		g.handleGetFriends(client, req)
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
	userID, _ := params["user_id"].(string)
	deviceID, _ := params["device_id"].(string)

	if token == "" {
		g.sendError(client, req.Echo, "token required")
		return
	}
	if g.accessToken != "" && subtle.ConstantTimeCompare(
		[]byte(token),
		[]byte(g.accessToken),
	) != 1 {
		g.sendError(client, req.Echo, "invalid credentials")
		return
	}

	// Preserve the original local-development behavior for older clients that
	// do not send user_id. Public deployments should configure accessToken.
	if userID == "" && g.accessToken == "" {
		userID = token
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
	g.sendJSON(client, protocol.Response{
		Status:  "ok",
		RetCode: 0,
		Data: map[string]interface{}{
			"user_id":  user.ID,
			"nickname": user.Nickname,
		},
		Echo: req.Echo,
	})

	log.Printf("[gateway] user %s authenticated (device=%s)", userID, deviceID)
}

func validUserID(value string) bool {
	return value != "" &&
		len(value) <= 128 &&
		value == strings.TrimSpace(value) &&
		strings.IndexFunc(value, unicode.IsControl) == -1
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
	if _, err := g.store.GetOrCreateConversation(convID, convType, convID); err != nil {
		g.sendError(client, req.Echo, "failed to load conversation")
		return
	}

	// Store message.
	user, _ := g.store.GetUser(client.userID)
	nickname := client.userID
	if user != nil {
		nickname = user.Nickname
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

	limit := 50
	if l, ok := params["limit"].(float64); ok {
		limit = int(l)
	}

	msgs, _ := g.store.GetMessages(convID, limit)
	result := make([]map[string]interface{}, len(msgs))
	for i, msg := range msgs {
		result[i] = map[string]interface{}{
			"message_id":      msg.ID,
			"conversation_id": msg.ConversationID,
			"sender": map[string]interface{}{
				"user_id":  msg.SenderID,
				"nickname": msg.SenderNickname,
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
		},
		Echo: req.Echo,
	})
}

func (g *Gateway) handleGetUsers(client *Client, req *protocol.Request) {
	users, _ := g.store.GetUsers()
	result := make([]protocol.User, len(users))
	for i, u := range users {
		result[i] = protocol.User{
			UserID:   u.ID,
			Nickname: u.Nickname,
			Avatar:   u.Avatar,
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

	// For MVP, return all users except self
	users, _ := g.store.GetUsers()
	result := make([]protocol.User, 0)
	for _, u := range users {
		if u.ID != client.userID {
			result = append(result, protocol.User{
				UserID:   u.ID,
				Nickname: u.Nickname,
				Avatar:   u.Avatar,
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
	}

	g.sendJSON(client, protocol.Response{
		Status:  "ok",
		RetCode: 0,
		Data:    result,
		Echo:    req.Echo,
	})
}

func (g *Gateway) handleGetGroupInfo(client *Client, req *protocol.Request) {
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

	allGroups, _ := g.store.GetGroups()
	groupID := fmt.Sprintf("group_%d", len(allGroups)+1)
	group, _ := g.store.CreateGroup(groupID, name, avatar, client.userID)

	// Create group conversation
	g.store.GetOrCreateConversation(groupID, "group", name)

	// Add members if provided
	if members, ok := params["members"].([]interface{}); ok {
		for _, m := range members {
			if memberID, ok := m.(string); ok {
				g.store.AddGroupMember(groupID, memberID)
			}
		}
	}

	g.sendJSON(client, protocol.Response{
		Status:  "ok",
		RetCode: 0,
		Data: map[string]interface{}{
			"group_id": group.ID,
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
	addOk, _ := g.store.AddGroupMember(groupID, client.userID)
	if addOk {
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
	removeOk, _ := g.store.RemoveGroupMember(groupID, client.userID)
	if removeOk {
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

	// TODO: Check if requester is admin/owner
	kickOk, _ := g.store.RemoveGroupMember(groupID, userID)
	if kickOk {
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

	friendReq, _ := g.store.CreateFriendRequest(client.userID, targetID, comment)

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

	handleOk, _ := g.store.HandleFriendRequest(flag, action)
	if handleOk {
		g.sendJSON(client, protocol.Response{
			Status:  "ok",
			RetCode: 0,
			Echo:    req.Echo,
		})

		// Notify requester
		friendReq, _ := g.store.GetFriendRequest(flag)
		if friendReq != nil && action == "accepted" {
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
				}
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
