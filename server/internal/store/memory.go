package store

import (
	"fmt"
	"sync"
	"time"

	"github.com/icradp/zzz-im-server/internal/protocol"
)

// MemoryStore is an in-memory store for MVP.
type MemoryStore struct {
	mu sync.RWMutex

	users             map[string]*User
	sessions          map[string]*Session // SHA-256 token hash -> session
	groups            map[string]*Group
	conversations     map[string]*Conversation
	messages          map[string][]*Message            // conversationID -> messages
	readStates        map[string]map[string]*ReadState // conversationID -> userID -> cursor
	friendRequests    map[string]*FriendRequest
	friendships       map[string]map[string]time.Time
	forwards          map[string]*ForwardMessage
	mediaFiles        map[string]*MediaFile
	pushSubscriptions map[string]map[string]*PushSubscription // userID -> endpoint -> subscription
	msgCounter        int64
	friendReqCounter  int64
}

func NewMemoryStore() *MemoryStore {
	return &MemoryStore{
		users:             make(map[string]*User),
		sessions:          make(map[string]*Session),
		groups:            make(map[string]*Group),
		conversations:     make(map[string]*Conversation),
		messages:          make(map[string][]*Message),
		readStates:        make(map[string]map[string]*ReadState),
		friendRequests:    make(map[string]*FriendRequest),
		friendships:       make(map[string]map[string]time.Time),
		forwards:          make(map[string]*ForwardMessage),
		mediaFiles:        make(map[string]*MediaFile),
		pushSubscriptions: make(map[string]map[string]*PushSubscription),
	}
}

func (s *MemoryStore) Close() error { return nil }

// ---- User operations ----

func (s *MemoryStore) GetUser(id string) (*User, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.users[id], nil
}

func (s *MemoryStore) SetUser(user *User) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.users[user.ID] = user
	return nil
}

func (s *MemoryStore) GetUsers() ([]*User, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	result := make([]*User, 0, len(s.users))
	for _, user := range s.users {
		result = append(result, user)
	}
	return result, nil
}

func (s *MemoryStore) SetUserOnline(id string, online bool) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if user, ok := s.users[id]; ok {
		user.Online = online
	}
	return nil
}

// ---- Conversation operations ----

func (s *MemoryStore) GetOrCreateConversation(id, convType, title string) (*Conversation, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if conv, ok := s.conversations[id]; ok {
		return conv, nil
	}
	conv := &Conversation{
		ID:        id,
		Type:      convType,
		Title:     title,
		CreatedAt: time.Now(),
	}
	s.conversations[id] = conv
	return conv, nil
}

func (s *MemoryStore) SaveConversation(conversation *Conversation) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	copy := *conversation
	copy.Participants = append([]string(nil), conversation.Participants...)
	s.conversations[conversation.ID] = &copy
	return nil
}

func (s *MemoryStore) GetConversation(id string) (*Conversation, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.conversations[id], nil
}

func (s *MemoryStore) GetConversations() ([]*Conversation, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	result := make([]*Conversation, 0, len(s.conversations))
	for _, conv := range s.conversations {
		result = append(result, conv)
	}
	return result, nil
}

func (s *MemoryStore) GetUserConversations(userID string) ([]*Conversation, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	result := make([]*Conversation, 0)
	for _, conv := range s.conversations {
		if conv.Type == "private" {
			for _, p := range conv.Participants {
				if p == userID {
					result = append(result, conv)
					break
				}
			}
		} else {
			if s.isGroupMember(conv.ID, userID) {
				result = append(result, conv)
			}
		}
	}
	return result, nil
}

func (s *MemoryStore) DeleteConversation(id string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.conversations, id)
	delete(s.messages, id)
	delete(s.readStates, id)
	return nil
}

// ---- Message operations ----

func (s *MemoryStore) StoreMessage(convID, senderID, senderNickname string, segments []protocol.MessageSegment) (*Message, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.msgCounter++
	msg := &Message{
		ID:             fmt.Sprintf("msg_%d", s.msgCounter),
		ConversationID: convID,
		SenderID:       senderID,
		SenderNickname: senderNickname,
		Segments:       segments,
		Timestamp:      time.Now(),
	}
	s.messages[convID] = append(s.messages[convID], msg)
	return msg, nil
}

func (s *MemoryStore) GetMessage(msgID string) (*Message, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	for _, msgs := range s.messages {
		for _, msg := range msgs {
			if msg.ID == msgID {
				return msg, nil
			}
		}
	}
	return nil, nil
}

func (s *MemoryStore) GetMessages(convID string, limit int) ([]*Message, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	msgs := s.messages[convID]
	if limit <= 0 || limit > len(msgs) {
		limit = len(msgs)
	}
	start := len(msgs) - limit
	if start < 0 {
		start = 0
	}
	result := make([]*Message, limit)
	copy(result, msgs[start:])
	return result, nil
}

func (s *MemoryStore) RecallMessage(msgID string) (bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, msgs := range s.messages {
		for _, msg := range msgs {
			if msg.ID == msgID {
				msg.Recalled = true
				return true, nil
			}
		}
	}
	return false, nil
}

// ---- Group operations ----

func (s *MemoryStore) CreateGroup(id, name, avatar, ownerID string) (*Group, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	group := &Group{
		ID:      id,
		Name:    name,
		Avatar:  avatar,
		OwnerID: ownerID,
		Members: []*GroupMember{
			{
				UserID:   ownerID,
				Role:     "owner",
				JoinedAt: time.Now(),
			},
		},
		CreatedAt: time.Now(),
	}
	s.groups[id] = group
	return group, nil
}

func (s *MemoryStore) GetGroup(id string) (*Group, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.groups[id], nil
}

func (s *MemoryStore) GetGroups() ([]*Group, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	result := make([]*Group, 0, len(s.groups))
	for _, group := range s.groups {
		result = append(result, group)
	}
	return result, nil
}

func (s *MemoryStore) GetUserGroups(userID string) ([]*Group, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	result := make([]*Group, 0)
	for _, group := range s.groups {
		for _, member := range group.Members {
			if member.UserID == userID {
				result = append(result, group)
				break
			}
		}
	}
	return result, nil
}

func (s *MemoryStore) AddGroupMember(groupID, userID string) (bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	group, ok := s.groups[groupID]
	if !ok {
		return false, nil
	}
	for _, m := range group.Members {
		if m.UserID == userID {
			return false, nil
		}
	}
	group.Members = append(group.Members, &GroupMember{
		UserID:   userID,
		Role:     "member",
		JoinedAt: time.Now(),
	})
	return true, nil
}

func (s *MemoryStore) RemoveGroupMember(groupID, userID string) (bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	group, ok := s.groups[groupID]
	if !ok {
		return false, nil
	}
	for i, m := range group.Members {
		if m.UserID == userID {
			group.Members = append(group.Members[:i], group.Members[i+1:]...)
			return true, nil
		}
	}
	return false, nil
}

func (s *MemoryStore) IsGroupMember(groupID, userID string) (bool, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.isGroupMember(groupID, userID), nil
}

func (s *MemoryStore) isGroupMember(groupID, userID string) bool {
	group, ok := s.groups[groupID]
	if !ok {
		return false
	}
	for _, m := range group.Members {
		if m.UserID == userID {
			return true
		}
	}
	return false
}

func (s *MemoryStore) GetGroupMembers(groupID string) ([]*GroupMember, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	group, ok := s.groups[groupID]
	if !ok {
		return nil, nil
	}
	result := make([]*GroupMember, len(group.Members))
	copy(result, group.Members)
	return result, nil
}

// ---- Friend request operations ----

func (s *MemoryStore) GetFriends(userID string) ([]*User, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	friendIDs := s.friendships[userID]
	result := make([]*User, 0, len(friendIDs))
	for friendID := range friendIDs {
		if user := s.users[friendID]; user != nil {
			copy := *user
			result = append(result, &copy)
		}
	}
	return result, nil
}

func (s *MemoryStore) AreFriends(userID, friendID string) (bool, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	_, ok := s.friendships[userID][friendID]
	return ok, nil
}

func (s *MemoryStore) AddFriend(userID, friendID string) (bool, error) {
	if userID == "" || friendID == "" || userID == friendID {
		return false, nil
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.friendships[userID] == nil {
		s.friendships[userID] = make(map[string]time.Time)
	}
	if s.friendships[friendID] == nil {
		s.friendships[friendID] = make(map[string]time.Time)
	}
	if _, exists := s.friendships[userID][friendID]; exists {
		return false, nil
	}
	now := time.Now()
	s.friendships[userID][friendID] = now
	s.friendships[friendID][userID] = now
	return true, nil
}

func (s *MemoryStore) RemoveFriend(userID, friendID string) (bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, exists := s.friendships[userID][friendID]; !exists {
		return false, nil
	}
	delete(s.friendships[userID], friendID)
	delete(s.friendships[friendID], userID)
	return true, nil
}

func (s *MemoryStore) CreateFriendRequest(fromID, toID, comment string) (*FriendRequest, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.friendReqCounter++
	req := &FriendRequest{
		ID:        fmt.Sprintf("freq_%d", s.friendReqCounter),
		FromID:    fromID,
		ToID:      toID,
		Comment:   comment,
		Status:    "pending",
		CreatedAt: time.Now(),
	}
	s.friendRequests[req.ID] = req
	return req, nil
}

func (s *MemoryStore) GetFriendRequest(id string) (*FriendRequest, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.friendRequests[id], nil
}

func (s *MemoryStore) GetPendingFriendRequests(userID string) ([]*FriendRequest, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	result := make([]*FriendRequest, 0)
	for _, req := range s.friendRequests {
		if (req.ToID == userID || req.FromID == userID) && req.Status == "pending" {
			result = append(result, req)
		}
	}
	return result, nil
}

func (s *MemoryStore) HandleFriendRequest(reqID, action string) (bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	req, ok := s.friendRequests[reqID]
	if !ok || req.Status != "pending" {
		return false, nil
	}
	req.Status = action
	return true, nil
}

// ---- Forward message operations ----

func (s *MemoryStore) StoreForward(messages []*Message) (*ForwardMessage, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	forward := &ForwardMessage{
		ID:        fmt.Sprintf("fwd_%d", time.Now().UnixNano()),
		Messages:  messages,
		CreatedAt: time.Now(),
	}
	s.forwards[forward.ID] = forward
	return forward, nil
}

func (s *MemoryStore) GetForward(id string) (*ForwardMessage, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.forwards[id], nil
}

// ---- Media operations ----

func (s *MemoryStore) StoreMedia(file *MediaFile) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	copy := *file
	s.mediaFiles[file.ID] = &copy
	return nil
}

func (s *MemoryStore) GetMedia(id string) (*MediaFile, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	file := s.mediaFiles[id]
	if file == nil {
		return nil, nil
	}
	copy := *file
	return &copy, nil
}

func (s *MemoryStore) DeleteMedia(id string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.mediaFiles, id)
	return nil
}
