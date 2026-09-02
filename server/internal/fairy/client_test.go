package fairy

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"
	"github.com/icradp/zzz-im-server/internal/protocol"
)

func TestClientRequestRejectsCancelledContextBeforeWriting(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	client := &Client{}
	if err := client.Request(ctx, "test", nil, nil); !errors.Is(err, context.Canceled) {
		t.Fatalf("cancelled request error = %v", err)
	}
}

func TestClientSendTextIncludesClientMessageID(t *testing.T) {
	requests := make(chan protocol.Request, 1)
	upgrader := websocket.Upgrader{CheckOrigin: func(*http.Request) bool { return true }}
	server := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		connection, err := upgrader.Upgrade(response, request, nil)
		if err != nil {
			return
		}
		defer connection.Close()
		var received protocol.Request
		if err := connection.ReadJSON(&received); err != nil {
			return
		}
		requests <- received
		_ = connection.WriteJSON(protocol.Response{
			Status: "ok", RetCode: 0, Echo: received.Echo,
			Data: map[string]interface{}{"message_id": "server-message-1"},
		})
	}))
	defer server.Close()
	client, err := Dial(context.Background(), "ws"+strings.TrimPrefix(server.URL, "http"))
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()
	if err := client.SendText(context.Background(), "private-alice-fairy", "message-1", "hello"); err != nil {
		t.Fatal(err)
	}
	select {
	case request := <-requests:
		encoded, err := json.Marshal(request.Params)
		if err != nil {
			t.Fatal(err)
		}
		var params protocol.SendMessageParams
		if err := json.Unmarshal(encoded, &params); err != nil {
			t.Fatal(err)
		}
		if request.Action != protocol.ActionSendMessage || !strings.HasPrefix(params.ClientMessageID, "fairy-msg_") ||
			len(params.Message) != 2 || params.Message[0].Type != "reply" || params.Message[1].Type != "text" {
			t.Fatalf("send request = %#v, params = %#v", request, params)
		}
	case <-time.After(time.Second):
		t.Fatal("did not receive Fairy send request")
	}
}

func TestClientSendTextRejectsMissingOrInvalidServerMessageID(t *testing.T) {
	tests := []struct {
		name string
		data interface{}
	}{
		{name: "missing data", data: nil},
		{name: "missing message ID", data: map[string]interface{}{}},
		{name: "blank message ID", data: map[string]interface{}{"message_id": "  "}},
		{name: "non-string message ID", data: map[string]interface{}{"message_id": 42}},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			upgrader := websocket.Upgrader{CheckOrigin: func(*http.Request) bool { return true }}
			server := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
				connection, err := upgrader.Upgrade(response, request, nil)
				if err != nil {
					return
				}
				defer connection.Close()
				var received protocol.Request
				if err := connection.ReadJSON(&received); err != nil {
					return
				}
				payload := protocol.Response{Status: "ok", RetCode: 0, Echo: received.Echo}
				if test.data != nil {
					payload.Data = test.data
				}
				_ = connection.WriteJSON(payload)
			}))
			defer server.Close()

			client, err := Dial(context.Background(), "ws"+strings.TrimPrefix(server.URL, "http"))
			if err != nil {
				t.Fatal(err)
			}
			defer client.Close()
			err = client.SendText(context.Background(), "private-alice-fairy", "message-1", "hello")
			if err == nil || (!strings.Contains(err.Error(), "valid message ID") &&
				!strings.Contains(err.Error(), "decode send_message response data")) {
				t.Fatalf("invalid send response error = %v", err)
			}
		})
	}
}
