package fairy

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/gorilla/websocket"
	"github.com/icradp/zzz-im-server/internal/gateway"
	"github.com/icradp/zzz-im-server/internal/protocol"
	"github.com/icradp/zzz-im-server/internal/store"
)

const feedbackPersistenceTimeout = 8 * time.Second

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
	engine := NewEngine(cfg, state, &fakeModel{response: "integration model reply"})
	trace, err := OpenSQLiteTraceStore(cfg.TraceDB, cfg.TraceKeyFile)
	if err != nil {
		t.Fatal(err)
	}
	defer trace.Close()
	runner := NewRunner(cfg, engine, trace)
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
	requestOK(t, alice, protocol.ActionReactMessage, protocol.ReactMessageParams{
		MessageID: privateReply.MessageID, EmojiID: FairyPositiveReactionID,
	}, nil)
	requestOK(t, alice, protocol.ActionSendMessage, protocol.SendMessageParams{
		ConversationID: privateID,
		Message:        []protocol.MessageSegment{protocol.TextSegment("hello model")},
	}, nil)
	modelReply := waitForFairyMessage(t, alice, 3*time.Second, cfg.UserID)
	if eventText(modelReply) != "integration model reply" {
		t.Fatalf("model reply = %#v", modelReply)
	}
	requestOK(t, alice, protocol.ActionReactMessage, protocol.ReactMessageParams{
		MessageID: modelReply.MessageID, EmojiID: FairyPositiveReactionID,
	}, nil)
	waitUntil(t, feedbackPersistenceTimeout, func() bool {
		stats, statsErr := trace.FeedbackStats(context.Background(), time.Now().Add(-time.Hour))
		return statsErr == nil && stats.RatedOutputs == 1 && stats.Positive == 1 && stats.Negative == 0
	}, "positive model reply feedback without command reply feedback")
	requestOK(t, alice, protocol.ActionReactMessage, protocol.ReactMessageParams{
		MessageID: modelReply.MessageID, EmojiID: FairyPositiveReactionID, Remove: true,
	}, nil)
	waitUntil(t, feedbackPersistenceTimeout, func() bool {
		stats, statsErr := trace.FeedbackStats(context.Background(), time.Now().Add(-time.Hour))
		return statsErr == nil && stats.RatedOutputs == 0 && stats.Positive == 0 && stats.Negative == 0
	}, "removed model reply feedback")
	requestOK(t, alice, protocol.ActionReactMessage, protocol.ReactMessageParams{
		MessageID: modelReply.MessageID, EmojiID: FairyNegativeReactionID,
	}, nil)
	waitUntil(t, feedbackPersistenceTimeout, func() bool {
		stats, statsErr := trace.FeedbackStats(context.Background(), time.Now().Add(-time.Hour))
		return statsErr == nil && stats.RatedOutputs == 1 && stats.Positive == 0 && stats.Negative == 1
	}, "negative model reply feedback")

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

func TestRunnerRetriesReplyAcrossAuthenticatedReconnect(t *testing.T) {
	type outboundRequest struct {
		connection int
		request    protocol.Request
	}
	outbound := make(chan outboundRequest, 2)
	server := newOutboundTestServer(t, func(connection *websocket.Conn, connectionNumber int) {
		for {
			var request protocol.Request
			if err := connection.ReadJSON(&request); err != nil {
				return
			}
			switch request.Action {
			case protocol.ActionAuth, protocol.ActionUpdateProfile, protocol.ActionPing:
				_ = connection.WriteJSON(protocol.Response{Status: "ok", RetCode: 0, Echo: request.Echo})
			case protocol.ActionGetFriendRequests:
				_ = connection.WriteJSON(protocol.Response{
					Status: "ok", RetCode: 0, Echo: request.Echo, Data: []friendRequestInfo{},
				})
				if connectionNumber == 1 {
					_ = connection.WriteJSON(messageEvent{
						PostType: "message", MessageType: "private", MessageID: "inbound-reconnect-1",
						ConversationID: "private_alice_fairy", Sender: protocol.Sender{UserID: "alice", Nickname: "Alice"},
						Message: []protocol.MessageSegment{protocol.TextSegment("/fairy help")}, Timestamp: time.Now().Unix(),
					})
				}
			case protocol.ActionSendMessage:
				outbound <- outboundRequest{connection: connectionNumber, request: request}
				if connectionNumber == 1 {
					_ = connection.Close()
					return
				}
				_ = connection.WriteJSON(protocol.Response{
					Status: "ok", RetCode: 0, Echo: request.Echo,
					Data: map[string]interface{}{"message_id": "server-reconnect-reply"},
				})
			default:
				_ = connection.WriteJSON(protocol.Response{
					Status: "failed", RetCode: 400, Msg: "unexpected action", Echo: request.Echo,
				})
			}
		}
	})
	defer server.Close()

	cfg := testConfig(t)
	cfg.ServerURL = "ws" + strings.TrimPrefix(server.URL, "http")
	cfg.ReconnectMin = time.Millisecond
	cfg.ReconnectMax = 5 * time.Millisecond
	state, err := OpenStateStore(cfg.StateFile, cfg.GroupDefault)
	if err != nil {
		t.Fatal(err)
	}
	trace, err := OpenSQLiteTraceStore(cfg.TraceDB, cfg.TraceKeyFile)
	if err != nil {
		t.Fatal(err)
	}
	defer trace.Close()
	runner := NewRunner(cfg, NewEngine(cfg, state, nil), trace)
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

	var first, second outboundRequest
	select {
	case first = <-outbound:
	case <-time.After(5 * time.Second):
		t.Fatal("first outbound reply was not attempted")
	}
	select {
	case second = <-outbound:
	case <-time.After(5 * time.Second):
		t.Fatal("outbound reply was not retried after reconnect")
	}
	firstParams := decodeOutboundParams(t, first.request)
	secondParams := decodeOutboundParams(t, second.request)
	if first.connection != 1 || second.connection != 2 || firstParams.ClientMessageID == "" ||
		firstParams.ClientMessageID != secondParams.ClientMessageID {
		t.Fatalf("runner outbound attempts = %#v then %#v", first, second)
	}
	waitUntil(t, 3*time.Second, func() bool {
		stats := runner.OutboundStats()
		return stats.Delivered == 1 && stats.RetryAttempts == 1 && stats.Failed == 0 && stats.OutcomeUnknown == 0
	}, "successful retried outbound delivery")
}

func TestRunnerRetriesPendingFriendRequestAfterTransientFailure(t *testing.T) {
	var acceptAttempts atomic.Int32
	server := newOutboundTestServer(t, func(connection *websocket.Conn, _ int) {
		for {
			var request protocol.Request
			if err := connection.ReadJSON(&request); err != nil {
				return
			}
			switch request.Action {
			case protocol.ActionAuth, protocol.ActionUpdateProfile, protocol.ActionPing:
				_ = connection.WriteJSON(protocol.Response{Status: "ok", RetCode: 0, Echo: request.Echo})
			case protocol.ActionGetFriendRequests:
				pending := []friendRequestInfo{}
				if acceptAttempts.Load() < 2 {
					requestInfo := friendRequestInfo{Flag: "friend-retry-1", Status: "pending"}
					requestInfo.ToUser.UserID = "fairy"
					pending = append(pending, requestInfo)
				}
				_ = connection.WriteJSON(protocol.Response{
					Status: "ok", RetCode: 0, Echo: request.Echo, Data: pending,
				})
			case protocol.ActionFriendHandle:
				attempt := acceptAttempts.Add(1)
				if attempt == 1 {
					_ = connection.WriteJSON(protocol.Response{
						Status: "failed", RetCode: 500, Msg: "temporary failure", Echo: request.Echo,
					})
					continue
				}
				_ = connection.WriteJSON(protocol.Response{Status: "ok", RetCode: 0, Echo: request.Echo})
			default:
				_ = connection.WriteJSON(protocol.Response{
					Status: "failed", RetCode: 400, Msg: "unexpected action", Echo: request.Echo,
				})
			}
		}
	})
	defer server.Close()

	cfg := testConfig(t)
	cfg.ServerURL = "ws" + strings.TrimPrefix(server.URL, "http")
	state, err := OpenStateStore(cfg.StateFile, cfg.GroupDefault)
	if err != nil {
		t.Fatal(err)
	}
	trace, err := OpenSQLiteTraceStore(cfg.TraceDB, cfg.TraceKeyFile)
	if err != nil {
		t.Fatal(err)
	}
	defer trace.Close()
	runner := NewRunner(cfg, NewEngine(cfg, state, nil), trace)
	runner.friendSyncInterval = 10 * time.Millisecond
	runnerContext, stopRunner := context.WithCancel(context.Background())
	runnerDone := make(chan error, 1)
	go func() { runnerDone <- runner.Run(runnerContext) }()

	waitUntil(t, 3*time.Second, func() bool { return acceptAttempts.Load() >= 2 }, "retried friend acceptance")
	stopRunner()
	select {
	case err := <-runnerDone:
		if err != nil {
			t.Fatalf("runner stopped with error: %v", err)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("runner did not stop")
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
