package fairy

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/gorilla/websocket"
	"github.com/icradp/zzz-im-server/internal/protocol"
)

type recordedFeedbackOutput struct {
	messageID string
	turnID    string
	at        time.Time
}

type recordingFeedbackOutputStore struct {
	mu      sync.Mutex
	outputs []recordedFeedbackOutput
}

func (s *recordingFeedbackOutputStore) RegisterFeedbackOutput(_ context.Context, messageID, turnID string, at time.Time) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.outputs = append(s.outputs, recordedFeedbackOutput{messageID: messageID, turnID: turnID, at: at})
	return nil
}

func (s *recordingFeedbackOutputStore) snapshot() []recordedFeedbackOutput {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]recordedFeedbackOutput(nil), s.outputs...)
}

func TestReliableMessengerRetriesWithSameClientMessageID(t *testing.T) {
	requests := make(chan protocol.Request, 2)
	server := newOutboundTestServer(t, func(connection *websocket.Conn, connectionNumber int) {
		for requestNumber := 0; requestNumber < 2; requestNumber++ {
			var request protocol.Request
			if err := connection.ReadJSON(&request); err != nil {
				return
			}
			requests <- request
			if requestNumber == 1 {
				_ = connection.WriteJSON(protocol.Response{
					Status: "ok", RetCode: 0, Echo: request.Echo,
					Data: map[string]interface{}{"message_id": "server-message-retry"},
				})
			}
		}
	})
	defer server.Close()

	client := dialOutboundTestClient(t, server)
	defer client.Close()
	feedback := &recordingFeedbackOutputStore{}
	messenger := newReliableMessenger(feedback)
	messenger.maxAttempts = 2
	messenger.attemptTimeout = 40 * time.Millisecond
	messenger.retryDelay = time.Millisecond
	messenger.Attach(client)

	ctx := withTurnTraceScope(context.Background(), TurnTraceScope{TurnID: "turn-feedback-retry"})
	ctx = withFeedbackEligible(ctx)
	ctx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	if err := messenger.SendText(ctx, "private_alice_fairy", "message-1", "hello"); err != nil {
		t.Fatal(err)
	}
	first := decodeOutboundParams(t, <-requests)
	second := decodeOutboundParams(t, <-requests)
	if first.ClientMessageID == "" || first.ClientMessageID != second.ClientMessageID {
		t.Fatalf("client message IDs differ: %q and %q", first.ClientMessageID, second.ClientMessageID)
	}
	if first.ConversationID != "private_alice_fairy" || len(first.Message) != 2 ||
		first.Message[0].Type != "reply" || first.Message[1].Type != "text" {
		t.Fatalf("send params = %#v", first)
	}
	if got := messenger.Stats(); got.Delivered != 1 || got.RetryAttempts != 1 || got.Failed != 0 || got.OutcomeUnknown != 0 {
		t.Fatalf("delivery stats = %#v", got)
	}
	outputs := feedback.snapshot()
	if len(outputs) != 1 || outputs[0].messageID != "server-message-retry" || outputs[0].turnID != "turn-feedback-retry" {
		t.Fatalf("registered feedback outputs = %#v", outputs)
	}
}

func TestReliableMessengerRetriesAfterReconnectWithoutClearingNewClient(t *testing.T) {
	type receivedRequest struct {
		connection int
		request    protocol.Request
	}
	requests := make(chan receivedRequest, 2)
	server := newOutboundTestServer(t, func(connection *websocket.Conn, connectionNumber int) {
		var request protocol.Request
		if err := connection.ReadJSON(&request); err != nil {
			return
		}
		requests <- receivedRequest{connection: connectionNumber, request: request}
		if connectionNumber == 1 {
			_ = connection.Close()
			return
		}
		_ = connection.WriteJSON(protocol.Response{
			Status: "ok", RetCode: 0, Echo: request.Echo,
			Data: map[string]interface{}{"message_id": "server-message-reconnect"},
		})
	})
	defer server.Close()

	firstClient := dialOutboundTestClient(t, server)
	defer firstClient.Close()
	feedback := &recordingFeedbackOutputStore{}
	messenger := newReliableMessenger(feedback)
	messenger.maxAttempts = 2
	messenger.attemptTimeout = 250 * time.Millisecond
	messenger.retryDelay = time.Millisecond
	messenger.Attach(firstClient)

	ctx := withTurnTraceScope(context.Background(), TurnTraceScope{TurnID: "turn-feedback-reconnect"})
	ctx = withFeedbackEligible(ctx)
	ctx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	result := make(chan error, 1)
	go func() {
		result <- messenger.SendText(ctx, "private_alice_fairy", "message-1", "hello")
	}()
	first := <-requests
	if first.connection != 1 {
		t.Fatalf("first request used connection %d", first.connection)
	}
	secondClient := dialOutboundTestClient(t, server)
	defer secondClient.Close()
	messenger.Attach(secondClient)
	messenger.Detach(firstClient)

	select {
	case err := <-result:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("delivery did not resume after reconnect")
	}
	second := <-requests
	firstParams := decodeOutboundParams(t, first.request)
	secondParams := decodeOutboundParams(t, second.request)
	if second.connection != 2 || firstParams.ClientMessageID != secondParams.ClientMessageID {
		t.Fatalf("reconnect requests = %#v then %#v", first, second)
	}
	if got := messenger.Stats(); got.Delivered != 1 || got.RetryAttempts != 1 || got.Failed != 0 || got.OutcomeUnknown != 0 {
		t.Fatalf("delivery stats = %#v", got)
	}
	outputs := feedback.snapshot()
	if len(outputs) != 1 || outputs[0].messageID != "server-message-reconnect" || outputs[0].turnID != "turn-feedback-reconnect" {
		t.Fatalf("reconnected feedback outputs = %#v", outputs)
	}
}

func TestReliableMessengerDoesNotRegisterNonModelReplyForFeedback(t *testing.T) {
	server := newOutboundTestServer(t, func(connection *websocket.Conn, _ int) {
		var request protocol.Request
		if err := connection.ReadJSON(&request); err != nil {
			return
		}
		_ = connection.WriteJSON(protocol.Response{
			Status: "ok", RetCode: 0, Echo: request.Echo,
			Data: map[string]interface{}{"message_id": "server-command-message"},
		})
	})
	defer server.Close()
	client := dialOutboundTestClient(t, server)
	defer client.Close()
	feedback := &recordingFeedbackOutputStore{}
	messenger := newReliableMessenger(feedback)
	messenger.Attach(client)
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	if err := messenger.SendText(ctx, "private_alice_fairy", "message-1", "command reply"); err != nil {
		t.Fatal(err)
	}
	if outputs := feedback.snapshot(); len(outputs) != 0 {
		t.Fatalf("non-model reply registered for feedback: %#v", outputs)
	}
}

func TestReliableMessengerDoesNotRetryDefinitiveAPIError(t *testing.T) {
	var requests atomic.Int64
	server := newOutboundTestServer(t, func(connection *websocket.Conn, connectionNumber int) {
		var request protocol.Request
		if err := connection.ReadJSON(&request); err != nil {
			return
		}
		requests.Add(1)
		_ = connection.WriteJSON(protocol.Response{
			Status: "failed", RetCode: 403, Msg: "message rejected", Echo: request.Echo,
		})
	})
	defer server.Close()

	client := dialOutboundTestClient(t, server)
	defer client.Close()
	messenger := newReliableMessenger()
	messenger.Attach(client)
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	err := messenger.SendText(ctx, "private_alice_fairy", "message-1", "hello")
	var apiError *APIError
	if !errors.As(err, &apiError) || apiError.RetCode != 403 {
		t.Fatalf("delivery error = %v", err)
	}
	if requests.Load() != 1 {
		t.Fatalf("request count = %d", requests.Load())
	}
	if got := messenger.Stats(); got.Delivered != 0 || got.RetryAttempts != 0 || got.Failed != 1 || got.OutcomeUnknown != 0 {
		t.Fatalf("delivery stats = %#v", got)
	}
}

func TestReliableMessengerBoundsUnknownOutcomeRetries(t *testing.T) {
	requests := make(chan protocol.Request, 3)
	server := newOutboundTestServer(t, func(connection *websocket.Conn, connectionNumber int) {
		for requestNumber := 0; requestNumber < 3; requestNumber++ {
			var request protocol.Request
			if err := connection.ReadJSON(&request); err != nil {
				return
			}
			requests <- request
		}
	})
	defer server.Close()

	client := dialOutboundTestClient(t, server)
	defer client.Close()
	messenger := newReliableMessenger()
	messenger.maxAttempts = 3
	messenger.attemptTimeout = 30 * time.Millisecond
	messenger.retryDelay = time.Millisecond
	messenger.Attach(client)
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	err := messenger.SendText(ctx, "private_alice_fairy", "message-1", "hello")
	if err == nil || !strings.Contains(err.Error(), "outcome unknown after 3 attempts") {
		t.Fatalf("delivery error = %v", err)
	}
	first := decodeOutboundParams(t, <-requests)
	second := decodeOutboundParams(t, <-requests)
	third := decodeOutboundParams(t, <-requests)
	if first.ClientMessageID == "" || first.ClientMessageID != second.ClientMessageID ||
		first.ClientMessageID != third.ClientMessageID {
		t.Fatalf("bounded retry client message IDs = %q, %q, %q", first.ClientMessageID, second.ClientMessageID, third.ClientMessageID)
	}
	if got := messenger.Stats(); got.Delivered != 0 || got.RetryAttempts != 2 || got.Failed != 1 || got.OutcomeUnknown != 1 {
		t.Fatalf("delivery stats = %#v", got)
	}
}

func TestReliableMessengerCancellationBeforeConnectionIsNotOutcomeUnknown(t *testing.T) {
	messenger := newReliableMessenger()
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
	defer cancel()
	err := messenger.SendText(ctx, "private_alice_fairy", "message-1", "hello")
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("delivery error = %v", err)
	}
	if got := messenger.Stats(); got.Delivered != 0 || got.RetryAttempts != 0 || got.Failed != 1 || got.OutcomeUnknown != 0 {
		t.Fatalf("delivery stats = %#v", got)
	}
}

func newOutboundTestServer(t *testing.T, handle func(*websocket.Conn, int)) *httptest.Server {
	t.Helper()
	upgrader := websocket.Upgrader{CheckOrigin: func(*http.Request) bool { return true }}
	var connections atomic.Int64
	return httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		connection, err := upgrader.Upgrade(response, request, nil)
		if err != nil {
			return
		}
		defer connection.Close()
		handle(connection, int(connections.Add(1)))
	}))
}

func dialOutboundTestClient(t *testing.T, server *httptest.Server) *Client {
	t.Helper()
	client, err := Dial(context.Background(), "ws"+strings.TrimPrefix(server.URL, "http"))
	if err != nil {
		t.Fatal(err)
	}
	return client
}

func decodeOutboundParams(t *testing.T, request protocol.Request) protocol.SendMessageParams {
	t.Helper()
	encoded, err := json.Marshal(request.Params)
	if err != nil {
		t.Fatal(err)
	}
	var params protocol.SendMessageParams
	if err := json.Unmarshal(encoded, &params); err != nil {
		t.Fatal(err)
	}
	return params
}
