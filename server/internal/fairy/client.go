package fairy

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"sync"
	"sync/atomic"
	"time"

	"github.com/gorilla/websocket"
	"github.com/icradp/zzz-im-server/internal/protocol"
)

var ErrClientClosed = errors.New("Fairy IM client is closed")

type APIError struct {
	Action  string
	RetCode int
	Message string
}

func (e *APIError) Error() string {
	if e.Message == "" {
		return fmt.Sprintf("%s failed with retcode %d", e.Action, e.RetCode)
	}
	return fmt.Sprintf("%s failed: %s", e.Action, e.Message)
}

type apiResponse struct {
	Status  string          `json:"status"`
	RetCode int             `json:"retcode"`
	Data    json.RawMessage `json:"data"`
	Msg     string          `json:"msg"`
	Echo    string          `json:"echo"`
}

type pendingResult struct {
	payload []byte
	err     error
}

// Client is a small concurrent request/event client for the ZZZ Server
// WebSocket protocol. A single reader dispatches echoed responses while
// unsolicited message/request events remain available through Events().
type Client struct {
	connection *websocket.Conn
	writeMu    sync.Mutex
	pendingMu  sync.Mutex
	pending    map[string]chan pendingResult
	events     chan json.RawMessage
	done       chan struct{}
	closeOnce  sync.Once
	echo       atomic.Uint64
	readErrMu  sync.Mutex
	readErr    error
}

func Dial(ctx context.Context, serverURL string) (*Client, error) {
	connection, _, err := websocket.DefaultDialer.DialContext(ctx, serverURL, nil)
	if err != nil {
		return nil, fmt.Errorf("connect to ZZZ Server: %w", err)
	}
	connection.SetReadLimit(30 * 1024 * 1024)
	client := &Client{
		connection: connection,
		pending:    make(map[string]chan pendingResult),
		events:     make(chan json.RawMessage, 128),
		done:       make(chan struct{}),
	}
	go client.readLoop()
	return client, nil
}

func (c *Client) Events() <-chan json.RawMessage { return c.events }
func (c *Client) Done() <-chan struct{}          { return c.done }

func (c *Client) Request(ctx context.Context, action string, params interface{}, result interface{}) error {
	echo := fmt.Sprintf("fairy-%d", c.echo.Add(1))
	responseChannel := make(chan pendingResult, 1)
	c.pendingMu.Lock()
	select {
	case <-c.done:
		c.pendingMu.Unlock()
		return c.closeError()
	default:
	}
	c.pending[echo] = responseChannel
	c.pendingMu.Unlock()

	request := protocol.Request{Action: action, Params: params, Echo: echo}
	c.writeMu.Lock()
	writeDeadline := time.Now().Add(15 * time.Second)
	if deadline, ok := ctx.Deadline(); ok && deadline.Before(writeDeadline) {
		writeDeadline = deadline
	}
	_ = c.connection.SetWriteDeadline(writeDeadline)
	err := c.connection.WriteJSON(request)
	c.writeMu.Unlock()
	if err != nil {
		c.removePending(echo)
		return fmt.Errorf("write %s request: %w", action, err)
	}

	select {
	case <-ctx.Done():
		c.removePending(echo)
		return fmt.Errorf("wait for %s response: %w", action, ctx.Err())
	case pending := <-responseChannel:
		if pending.err != nil {
			return pending.err
		}
		var response apiResponse
		if err := json.Unmarshal(pending.payload, &response); err != nil {
			return fmt.Errorf("decode %s response: %w", action, err)
		}
		if response.Status != "ok" || response.RetCode != 0 {
			return &APIError{Action: action, RetCode: response.RetCode, Message: response.Msg}
		}
		if result != nil && len(response.Data) > 0 && string(response.Data) != "null" {
			if err := json.Unmarshal(response.Data, result); err != nil {
				return fmt.Errorf("decode %s response data: %w", action, err)
			}
		}
		return nil
	}
}

func (c *Client) SendText(ctx context.Context, conversationID, messageID, text string) error {
	segments := make([]protocol.MessageSegment, 0, 2)
	if messageID != "" {
		segments = append(segments, protocol.ReplySegment(messageID))
	}
	segments = append(segments, protocol.TextSegment(text))
	return c.Request(ctx, protocol.ActionSendMessage, protocol.SendMessageParams{
		ConversationID: conversationID,
		Message:        segments,
	}, nil)
}

func (c *Client) GetGroupMembers(ctx context.Context, groupID string) ([]protocol.GroupMember, error) {
	var response struct {
		Members []protocol.GroupMember `json:"members"`
	}
	err := c.Request(ctx, protocol.ActionGetGroupInfo, map[string]interface{}{"group_id": groupID}, &response)
	return response.Members, err
}

func (c *Client) Close() error {
	c.finish(ErrClientClosed)
	return c.connection.Close()
}

func (c *Client) readLoop() {
	for {
		_, payload, err := c.connection.ReadMessage()
		if err != nil {
			c.finish(fmt.Errorf("read ZZZ Server event: %w", err))
			return
		}
		var envelope struct {
			Echo string `json:"echo"`
		}
		if err := json.Unmarshal(payload, &envelope); err != nil {
			continue
		}
		if envelope.Echo != "" && c.deliverResponse(envelope.Echo, payload) {
			continue
		}
		select {
		case c.events <- append(json.RawMessage(nil), payload...):
		case <-c.done:
			return
		}
	}
}

func (c *Client) deliverResponse(echo string, payload []byte) bool {
	c.pendingMu.Lock()
	responseChannel, exists := c.pending[echo]
	if exists {
		delete(c.pending, echo)
	}
	c.pendingMu.Unlock()
	if exists {
		responseChannel <- pendingResult{payload: append([]byte(nil), payload...)}
	}
	return exists
}

func (c *Client) removePending(echo string) {
	c.pendingMu.Lock()
	delete(c.pending, echo)
	c.pendingMu.Unlock()
}

func (c *Client) finish(err error) {
	c.closeOnce.Do(func() {
		c.readErrMu.Lock()
		c.readErr = err
		c.readErrMu.Unlock()
		close(c.done)
		c.pendingMu.Lock()
		for echo, responseChannel := range c.pending {
			delete(c.pending, echo)
			responseChannel <- pendingResult{err: err}
		}
		c.pendingMu.Unlock()
	})
}

func (c *Client) closeError() error {
	c.readErrMu.Lock()
	defer c.readErrMu.Unlock()
	if c.readErr != nil {
		return c.readErr
	}
	return ErrClientClosed
}

type messageEvent struct {
	PostType       string                    `json:"post_type"`
	MessageType    string                    `json:"message_type"`
	MessageID      string                    `json:"message_id"`
	ConversationID string                    `json:"conversation_id"`
	Sender         protocol.Sender           `json:"sender"`
	Message        []protocol.MessageSegment `json:"message"`
	Timestamp      int64                     `json:"timestamp"`
}

type requestEvent struct {
	PostType    string `json:"post_type"`
	RequestType string `json:"request_type"`
	UserID      string `json:"user_id"`
	Comment     string `json:"comment"`
	Flag        string `json:"flag"`
}

type friendRequestInfo struct {
	Flag   string `json:"flag"`
	Status string `json:"status"`
	ToUser struct {
		UserID string `json:"user_id"`
	} `json:"to_user"`
}

type authResult struct {
	UserID       string `json:"user_id"`
	SessionToken string `json:"session_token"`
}

func requestTimeout(parent context.Context, duration time.Duration) (context.Context, context.CancelFunc) {
	if duration <= 0 {
		duration = 15 * time.Second
	}
	return context.WithTimeout(parent, duration)
}
