package fairy

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/icradp/zzz-im-server/internal/protocol"
)

type sentReply struct {
	conversationID string
	messageID      string
	text           string
}

type fakeMessenger struct {
	mu      sync.Mutex
	replies []sentReply
	members []protocol.GroupMember
}

func (m *fakeMessenger) SendText(_ context.Context, conversationID, messageID, text string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.replies = append(m.replies, sentReply{conversationID: conversationID, messageID: messageID, text: text})
	return nil
}

func (m *fakeMessenger) GetGroupMembers(context.Context, string) ([]protocol.GroupMember, error) {
	return append([]protocol.GroupMember(nil), m.members...), nil
}

func (m *fakeMessenger) replyCount() int {
	m.mu.Lock()
	defer m.mu.Unlock()
	return len(m.replies)
}

func (m *fakeMessenger) lastReply() sentReply {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.replies[len(m.replies)-1]
}

type fakeModel struct {
	mu       sync.Mutex
	requests [][]ChatMessage
	response string
}

func (m *fakeModel) Complete(_ context.Context, messages []ChatMessage) (string, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.requests = append(m.requests, append([]ChatMessage(nil), messages...))
	return m.response, nil
}

func TestEngineGroupTriggersAndAdminSwitch(t *testing.T) {
	cfg := testConfig(t)
	state, err := OpenStateStore(cfg.StateFile, true)
	if err != nil {
		t.Fatal(err)
	}
	engine := NewEngine(cfg, state, nil)
	messenger := &fakeMessenger{members: []protocol.GroupMember{{UserID: "alice", Role: "owner"}}}

	plain := testMessage("group_room", "group", "alice", "普通聊天")
	engine.HandleMessage(context.Background(), messenger, plain)
	if messenger.replyCount() != 0 {
		t.Fatal("unmentioned group message triggered Fairy")
	}

	help := testMessage("group_room", "group", "alice", "/fairy help")
	engine.HandleMessage(context.Background(), messenger, help)
	if messenger.replyCount() != 1 || !strings.Contains(messenger.lastReply().text, "Fairy 可用指令") {
		t.Fatalf("help reply = %#v", messenger.replies)
	}

	off := testMessage("group_room", "group", "alice", "/fairy off")
	engine.HandleMessage(context.Background(), messenger, off)
	if state.GroupEnabled("group_room") {
		t.Fatal("group switch stayed enabled")
	}
	mentioned := testMessage("group_room", "group", "alice", "能听见吗")
	mentioned.Message = append([]protocol.MessageSegment{protocol.AtSegment("fairy")}, mentioned.Message...)
	before := messenger.replyCount()
	engine.HandleMessage(context.Background(), messenger, mentioned)
	if messenger.replyCount() != before {
		t.Fatal("disabled group produced a normal reply")
	}
	engine.HandleMessage(context.Background(), messenger, testMessage("group_room", "group", "alice", "/fairy status"))
	if !strings.Contains(messenger.lastReply().text, "群回复已关闭") {
		t.Fatalf("status reply = %q", messenger.lastReply().text)
	}
}

func TestEngineModelContextQuotaAndClear(t *testing.T) {
	cfg := testConfig(t)
	cfg.ModelDailyLimit = 1
	state, err := OpenStateStore(filepath.Join(t.TempDir(), "state.json"), true)
	if err != nil {
		t.Fatal(err)
	}
	model := &fakeModel{response: "你好，代理人。"}
	engine := NewEngine(cfg, state, model)
	messenger := &fakeMessenger{}
	event := testMessage("private_alice_fairy", "private", "alice", "你好")
	engine.HandleMessage(context.Background(), messenger, event)
	if messenger.lastReply().text != "你好，代理人。" {
		t.Fatalf("model reply = %q", messenger.lastReply().text)
	}
	if len(model.requests) != 1 || len(model.requests[0]) != 2 || model.requests[0][0].Role != "system" {
		t.Fatalf("model messages = %#v", model.requests)
	}
	event.MessageID = "message_2"
	event.Message = []protocol.MessageSegment{protocol.TextSegment("再说一次")}
	engine.HandleMessage(context.Background(), messenger, event)
	if !strings.Contains(messenger.lastReply().text, "额度") || len(model.requests) != 1 {
		t.Fatalf("quota reply = %q, model calls = %d", messenger.lastReply().text, len(model.requests))
	}
	engine.HandleMessage(context.Background(), messenger, testMessage("private_alice_fairy", "private", "alice", "/fairy clear"))
	if !strings.Contains(messenger.lastReply().text, "已清除") {
		t.Fatalf("clear reply = %q", messenger.lastReply().text)
	}
}

func TestZZZPluginFormatsAndCachesPublicProfile(t *testing.T) {
	var mu sync.Mutex
	requests := 0
	server := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		mu.Lock()
		requests++
		mu.Unlock()
		response.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(response).Encode(map[string]interface{}{
			"uid": "123456789",
			"ttl": 300,
			"PlayerInfo": map[string]interface{}{
				"SocialDetail": map[string]interface{}{
					"Desc":          "欢迎来到新艾利都",
					"ProfileDetail": map[string]interface{}{"Nickname": "铃", "Level": 60},
				},
				"ShowcaseDetail": map[string]interface{}{
					"AvatarList": []map[string]interface{}{{"Id": 1011, "Level": 60, "TalentLevel": 2}},
				},
			},
		})
	}))
	defer server.Close()
	cfg := testConfig(t)
	cfg.ZZZAPIURL = server.URL + "/{uid}"
	plugin := NewZZZPlugin(cfg)
	request := PluginRequest{Text: "/zzz 123456789"}
	for index := 0; index < 2; index++ {
		text, err := plugin.Handle(context.Background(), request)
		if err != nil {
			t.Fatal(err)
		}
		if !strings.Contains(text, "铃 · UID 123456789 · 绳网等级 60") || !strings.Contains(text, "影画 2") {
			t.Fatalf("formatted profile = %q", text)
		}
	}
	mu.Lock()
	defer mu.Unlock()
	if requests != 1 {
		t.Fatalf("upstream requests = %d, want 1", requests)
	}
}

func testMessage(conversationID, messageType, senderID, text string) messageEvent {
	return messageEvent{
		PostType:       "message",
		MessageType:    messageType,
		MessageID:      "message_1",
		ConversationID: conversationID,
		Sender:         protocol.Sender{UserID: senderID, Nickname: "Alice"},
		Message:        []protocol.MessageSegment{protocol.TextSegment(text)},
		Timestamp:      time.Now().Unix(),
	}
}
