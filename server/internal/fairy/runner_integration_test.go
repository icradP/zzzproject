package fairy

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/icradp/zzz-im-server/internal/gateway"
	"github.com/icradp/zzz-im-server/internal/protocol"
	"github.com/icradp/zzz-im-server/internal/store"
)

func TestRunnerRegistersAcceptsFriendsAndRepliesWithGroupTriggerRules(t *testing.T) {
	database := store.NewMemoryStore()
	imGateway := gateway.NewGateway(database)
	imGateway.SetInviteCode("diaogan")
	mux := http.NewServeMux()
	mux.HandleFunc("/ws", imGateway.HandleWebSocket)
	server := httptest.NewServer(mux)
	defer server.Close()

	cfg := testConfig(t)
	cfg.ServerURL = "ws" + strings.TrimPrefix(server.URL, "http") + "/ws"
	state, err := OpenStateStore(cfg.StateFile, cfg.GroupDefault)
	if err != nil {
		t.Fatal(err)
	}
	engine := NewEngine(cfg, state, nil)
	runner := NewRunner(cfg, engine)
	runnerContext, stopRunner := context.WithCancel(context.Background())
	runnerDone := make(chan error, 1)
	go func() { runnerDone <- runner.Run(runnerContext) }()
	defer func() {
		stopRunner()
		select {
		case err := <-runnerDone:
			if err != nil {
				t.Errorf("runner stopped with error: %v", err)
			}
		case <-time.After(3 * time.Second):
			t.Error("runner did not stop")
		}
	}()
	waitUntil(t, 3*time.Second, runner.Connected, "Fairy connection")

	alice, err := Dial(context.Background(), cfg.ServerURL)
	if err != nil {
		t.Fatal(err)
	}
	defer alice.Close()
	requestOK(t, alice, protocol.ActionAuth, protocol.AuthParams{UserID: "alice", DeviceID: "test"}, nil)
	requestOK(t, alice, protocol.ActionFriendRequest, protocol.FriendRequestParams{
		UserID: cfg.UserID, Comment: "test",
	}, nil)
	waitUntil(t, 3*time.Second, func() bool {
		var friends []protocol.User
		ctx, cancel := context.WithTimeout(context.Background(), time.Second)
		defer cancel()
		return alice.Request(ctx, protocol.ActionGetFriends, map[string]interface{}{}, &friends) == nil &&
			len(friends) == 1 && friends[0].UserID == cfg.UserID
	}, "automatic friend acceptance")

	privateID := "private_alice_fairy"
	requestOK(t, alice, protocol.ActionEnsureConversation, map[string]interface{}{
		"conversation_id": privateID,
		"type":            "private",
		"participants":    []string{"alice", cfg.UserID},
	}, nil)
	requestOK(t, alice, protocol.ActionSendMessage, protocol.SendMessageParams{
		ConversationID: privateID,
		Message:        []protocol.MessageSegment{protocol.TextSegment("/fairy help")},
	}, nil)
	privateReply := waitForFairyMessage(t, alice, 3*time.Second, cfg.UserID)
	if !strings.Contains(eventText(privateReply), "Fairy 可用指令") {
		t.Fatalf("private reply = %#v", privateReply)
	}

	var group struct {
		GroupID string `json:"group_id"`
	}
	requestOK(t, alice, protocol.ActionCreateGroup, protocol.CreateGroupParams{
		Name: "Fairy Test", Members: []string{cfg.UserID},
	}, &group)
	if group.GroupID == "" {
		t.Fatal("group creation returned no group ID")
	}
	requestOK(t, alice, protocol.ActionSendMessage, protocol.SendMessageParams{
		ConversationID: group.GroupID,
		Message:        []protocol.MessageSegment{protocol.TextSegment("普通群消息")},
	}, nil)
	assertNoFairyMessage(t, alice, 250*time.Millisecond, cfg.UserID)
	requestOK(t, alice, protocol.ActionSendMessage, protocol.SendMessageParams{
		ConversationID: group.GroupID,
		Message: []protocol.MessageSegment{
			protocol.AtSegment(cfg.UserID),
			protocol.TextSegment(" /fairy status"),
		},
	}, nil)
	groupReply := waitForFairyMessage(t, alice, 3*time.Second, cfg.UserID)
	if !strings.Contains(eventText(groupReply), "群回复已开启") {
		t.Fatalf("group reply = %#v", groupReply)
	}
}

func requestOK(t *testing.T, client *Client, action string, params, result interface{}) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	if err := client.Request(ctx, action, params, result); err != nil {
		t.Fatalf("%s: %v", action, err)
	}
}

func waitUntil(t *testing.T, timeout time.Duration, condition func() bool, description string) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if condition() {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for %s", description)
}

func waitForFairyMessage(t *testing.T, client *Client, timeout time.Duration, userID string) messageEvent {
	t.Helper()
	deadline := time.NewTimer(timeout)
	defer deadline.Stop()
	for {
		select {
		case payload := <-client.Events():
			var event messageEvent
			if json.Unmarshal(payload, &event) == nil && event.PostType == "message" && event.Sender.UserID == userID {
				return event
			}
		case <-deadline.C:
			t.Fatal("timed out waiting for Fairy message")
		}
	}
}

func assertNoFairyMessage(t *testing.T, client *Client, duration time.Duration, userID string) {
	t.Helper()
	deadline := time.NewTimer(duration)
	defer deadline.Stop()
	for {
		select {
		case payload := <-client.Events():
			var event messageEvent
			if json.Unmarshal(payload, &event) == nil && event.PostType == "message" && event.Sender.UserID == userID {
				t.Fatalf("unexpected Fairy message: %#v", event)
			}
		case <-deadline.C:
			return
		}
	}
}

func eventText(event messageEvent) string {
	text, _ := messageText(event.Message, "fairy")
	return text
}
