package fairy

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
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
	if err := ctx.Err(); err != nil {
		return fmt.Errorf("start %s request: %w", action, err)
	}
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
	if err := ctx.Err(); err != nil {
		c.writeMu.Unlock()
		c.removePending(echo)
		return fmt.Errorf("start %s request: %w", action, err)
	}
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
	return c.SendSegments(ctx, conversationID, segments)
}

func (c *Client) SendSegments(ctx context.Context, conversationID string, segments []protocol.MessageSegment) error {
	clientMessageID, err := newRuntimeID("fairy-msg")
	if err != nil {
		return fmt.Errorf("generate Fairy client message ID: %w", err)
	}
	_, err = c.sendSegmentsWithID(ctx, conversationID, segments, clientMessageID)
	return err
}

func (c *Client) sendTextWithID(ctx context.Context, conversationID, messageID, text, clientMessageID string) (string, error) {
	segments := make([]protocol.MessageSegment, 0, 2)
	if messageID != "" {
		segments = append(segments, protocol.ReplySegment(messageID))
	}
	segments = append(segments, protocol.TextSegment(text))
	return c.sendSegmentsWithID(ctx, conversationID, segments, clientMessageID)
}

func (c *Client) sendSegmentsWithID(ctx context.Context, conversationID string, segments []protocol.MessageSegment, clientMessageID string) (string, error) {
	if len(segments) == 0 {
		return "", errors.New("Fairy message requires at least one segment")
	}
	var result struct {
		MessageID string `json:"message_id"`
	}
	if err := c.Request(ctx, protocol.ActionSendMessage, protocol.SendMessageParams{
		ConversationID:  conversationID,
		Message:         segments,
		ClientMessageID: clientMessageID,
	}, &result); err != nil {
		return "", err
	}
	result.MessageID = strings.TrimSpace(result.MessageID)
	if result.MessageID == "" || len(result.MessageID) > 1024 {
		return "", fmt.Errorf("send_message response did not contain a valid message ID")
	}
	return result.MessageID, nil
}

type UploadedFile struct {
	FileID       string `json:"file_id"`
	URL          string `json:"url"`
	ThumbnailURL string `json:"thumbnail_url"`
	MIMEType     string `json:"mime_type"`
	Size         int64  `json:"size"`
	Width        int    `json:"width"`
	Height       int    `json:"height"`
}

func (c *Client) UploadFile(ctx context.Context, fileName, fileType, mimeType string, data []byte) (UploadedFile, error) {
	if len(data) == 0 {
		return UploadedFile{}, errors.New("cannot upload an empty Fairy file")
	}
	var result UploadedFile
	err := c.Request(ctx, protocol.ActionUploadFile, protocol.UploadFileParams{
		File:     base64.StdEncoding.EncodeToString(data),
		FileName: fileName,
		FileType: fileType,
		MimeType: mimeType,
	}, &result)
	if err != nil {
		return UploadedFile{}, err
	}
	if strings.TrimSpace(result.FileID) == "" || strings.TrimSpace(result.URL) == "" {
		return UploadedFile{}, errors.New("upload_file response did not contain file metadata")
	}
	return result, nil
}

func (c *Client) GetGroupMembers(ctx context.Context, groupID string) ([]protocol.GroupMember, error) {
	var response struct {
		Members []protocol.GroupMember `json:"members"`
	}
	err := c.Request(ctx, protocol.ActionGetGroupInfo, map[string]interface{}{"group_id": groupID}, &response)
	return response.Members, err
}

// The methods below intentionally mirror ordinary account actions. Fairy has
// no privileged server API; all permission checks are performed by the same IM
// gateway handlers used for human accounts.
func (c *Client) CreateGroup(ctx context.Context, name string, memberIDs []string) (protocol.Group, error) {
	var group protocol.Group
	err := c.Request(ctx, protocol.ActionCreateGroup, protocol.CreateGroupParams{Name: name, Members: memberIDs}, &group)
	return group, err
}

func (c *Client) InviteGroupMembers(ctx context.Context, groupID string, memberIDs []string) error {
	return c.Request(ctx, protocol.ActionGroupInvite, protocol.GroupInviteParams{GroupID: groupID, Members: memberIDs}, nil)
}

func (c *Client) CreateGroupAnnouncement(ctx context.Context, groupID, content string, pinned bool) (map[string]interface{}, error) {
	var announcement map[string]interface{}
	err := c.Request(ctx, protocol.ActionCreateGroupAnnouncement, protocol.GroupAnnouncementParams{
		GroupID: groupID, Content: content, IsPinned: pinned,
	}, &announcement)
	return announcement, err
}

func (c *Client) SendFriendRequest(ctx context.Context, userID, comment string) error {
	return c.Request(ctx, protocol.ActionFriendRequest, protocol.FriendRequestParams{UserID: userID, Comment: comment}, nil)
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
