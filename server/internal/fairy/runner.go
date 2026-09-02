package fairy

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"math"
	"math/rand"
	"sync/atomic"
	"time"

	"github.com/icradp/zzz-im-server/internal/protocol"
)

type Runner struct {
	cfg       Config
	engine    *Engine
	connected atomic.Bool
	scheduler *ConversationScheduler
	messenger *reliableMessenger
	feedback  FeedbackStore
}

func NewRunner(cfg Config, engine *Engine, trace TraceStore) *Runner {
	feedback, _ := trace.(FeedbackStore)
	return &Runner{
		cfg: cfg, engine: engine,
		scheduler: NewConversationScheduler(cfg, trace),
		messenger: newReliableMessenger(feedback),
		feedback:  feedback,
	}
}

func (r *Runner) Connected() bool { return r.connected.Load() }

func (r *Runner) Ready() bool {
	if r == nil || !r.connected.Load() || r.scheduler == nil {
		return false
	}
	return r.scheduler.Stats().Accepting
}

func (r *Runner) Stats() SchedulerStats { return r.scheduler.Stats() }

func (r *Runner) OutboundStats() OutboundDeliveryStats { return r.messenger.Stats() }

func (r *Runner) Run(ctx context.Context) error {
	defer r.shutdownScheduler()
	delay := r.cfg.ReconnectMin
	for {
		if err := ctx.Err(); err != nil {
			return nil
		}
		err := r.runSession(ctx)
		r.connected.Store(false)
		if ctx.Err() != nil {
			return nil
		}
		log.Printf("[fairy] session ended: %v; reconnecting in %s", err, delay)
		jitter := time.Duration(rand.Int63n(int64(delay/4 + 1)))
		select {
		case <-ctx.Done():
			return nil
		case <-time.After(delay + jitter):
		}
		delay = time.Duration(math.Min(float64(r.cfg.ReconnectMax), float64(delay*2)))
	}
}

func (r *Runner) runSession(ctx context.Context) error {
	dialCtx, cancel := requestTimeout(ctx, 15*time.Second)
	client, err := Dial(dialCtx, r.cfg.ServerURL)
	cancel()
	if err != nil {
		return err
	}
	defer client.Close()
	if err := r.authenticate(ctx, client); err != nil {
		return err
	}
	r.messenger.Attach(client)
	r.connected.Store(true)
	defer func() {
		r.connected.Store(false)
		r.messenger.Detach(client)
	}()
	log.Printf("[fairy] connected to ZZZ Server as %s", r.cfg.UserID)
	if err := r.updateProfile(ctx, client); err != nil {
		log.Printf("[fairy] update profile: %v", err)
	}
	if err := r.acceptPendingFriends(ctx, client); err != nil {
		log.Printf("[fairy] sync friend requests: %v", err)
	}

	heartbeat := time.NewTicker(30 * time.Second)
	defer heartbeat.Stop()
	for {
		select {
		case <-ctx.Done():
			r.shutdownScheduler()
			return nil
		case <-client.Done():
			return client.closeError()
		case payload := <-client.Events():
			r.dispatch(ctx, client, payload)
		case <-heartbeat.C:
			pingCtx, pingCancel := requestTimeout(ctx, 10*time.Second)
			err := client.Request(pingCtx, protocol.ActionPing, map[string]interface{}{}, nil)
			pingCancel()
			if err != nil {
				return fmt.Errorf("heartbeat failed: %w", err)
			}
		}
	}
}

func (r *Runner) authenticate(ctx context.Context, client *Client) error {
	authCtx, cancel := requestTimeout(ctx, 15*time.Second)
	var authenticated authResult
	err := client.Request(authCtx, protocol.ActionAuth, protocol.AuthParams{
		UserID: r.cfg.UserID, Password: r.cfg.Password, DeviceID: r.cfg.DeviceID,
	}, &authenticated)
	cancel()
	if err == nil {
		return nil
	}
	var apiError *APIError
	if !errors.As(err, &apiError) || apiError.Message != "invalid credentials" {
		return err
	}
	if r.cfg.InviteCode == "" {
		return fmt.Errorf("Fairy account login failed and FAIRY_INVITE_CODE is empty: %w", err)
	}
	registerCtx, registerCancel := requestTimeout(ctx, 30*time.Second)
	var registered authResult
	registerErr := client.Request(registerCtx, protocol.ActionRegister, protocol.RegisterParams{
		UserID:     r.cfg.UserID,
		Password:   r.cfg.Password,
		Nickname:   r.cfg.Nickname,
		InviteCode: r.cfg.InviteCode,
		Avatar:     r.cfg.AvatarURL,
	}, &registered)
	registerCancel()
	if registerErr != nil {
		return fmt.Errorf("register Fairy account: %w", registerErr)
	}
	if registered.SessionToken == "" {
		return fmt.Errorf("register Fairy account returned no session token")
	}
	sessionCtx, sessionCancel := requestTimeout(ctx, 15*time.Second)
	defer sessionCancel()
	return client.Request(sessionCtx, protocol.ActionAuth, protocol.AuthParams{
		SessionToken: registered.SessionToken,
		DeviceID:     r.cfg.DeviceID,
	}, &authenticated)
}

func (r *Runner) updateProfile(ctx context.Context, client *Client) error {
	requestCtx, cancel := requestTimeout(ctx, 15*time.Second)
	defer cancel()
	return client.Request(requestCtx, protocol.ActionUpdateProfile, protocol.UpdateProfileParams{
		Nickname: r.cfg.Nickname,
		Avatar:   r.cfg.AvatarURL,
		Bio:      r.cfg.Bio,
	}, nil)
}

func (r *Runner) acceptPendingFriends(ctx context.Context, client *Client) error {
	requestCtx, cancel := requestTimeout(ctx, 15*time.Second)
	defer cancel()
	var pending []friendRequestInfo
	if err := client.Request(requestCtx, protocol.ActionGetFriendRequests, map[string]interface{}{}, &pending); err != nil {
		return err
	}
	for _, request := range pending {
		if request.Status != "pending" || request.ToUser.UserID != r.cfg.UserID {
			continue
		}
		r.submitFriendRequest(ctx, client, request.Flag)
	}
	return nil
}

func (r *Runner) acceptFriend(ctx context.Context, client *Client, flag string) error {
	requestCtx, cancel := requestTimeout(ctx, 15*time.Second)
	defer cancel()
	return client.Request(requestCtx, protocol.ActionFriendHandle, protocol.FriendHandleParams{
		Flag: flag, Action: "accept",
	}, nil)
}

func (r *Runner) dispatch(ctx context.Context, client *Client, payload json.RawMessage) {
	switch decodePostType(payload) {
	case "request":
		var event requestEvent
		if json.Unmarshal(payload, &event) == nil && event.RequestType == "friend" && event.Flag != "" {
			r.submitFriendRequest(ctx, client, event.Flag)
		}
	case "message":
		var event messageEvent
		if json.Unmarshal(payload, &event) == nil {
			decision := r.engine.PreviewGate(event)
			if decision.Action != GateTrigger {
				r.engine.TraceGateIngress(ctx, event, decision)
				return
			}
			priority := isStopCommand(event, r.cfg.UserID)
			accepted, err := r.scheduler.Submit(ctx, scheduledTurn{
				source:         "zzz-message",
				eventID:        event.MessageID,
				conversationID: event.ConversationID,
				priority:       priority,
				run: func(turnContext context.Context) {
					r.engine.HandleMessage(turnContext, r.messenger, event)
				},
			})
			if err != nil {
				log.Printf("[fairy] message admission rejected: %v", err)
			} else if !accepted {
				log.Printf("[fairy] duplicate message ignored")
			}
		}
	case "notice":
		var event protocol.NoticeEvent
		if json.Unmarshal(payload, &event) == nil {
			r.handleFeedbackNotice(ctx, event)
		}
	}
}

func (r *Runner) handleFeedbackNotice(ctx context.Context, event protocol.NoticeEvent) {
	if r.feedback == nil || event.MessageID == "" {
		return
	}
	switch event.NoticeType {
	case protocol.NoticeTypeMessageReaction:
		if event.UserID == "" || event.UserID == r.cfg.UserID {
			return
		}
		label, ok := feedbackLabelForReaction(event.EmojiID)
		if !ok {
			return
		}
		feedbackContext, cancel := requestTimeout(ctx, 100*time.Millisecond)
		exists, err := r.feedbackOutputExists(feedbackContext, event.MessageID)
		cancel()
		if err != nil {
			return
		}
		if !exists {
			go r.applyFeedbackEventually(event, label)
			return
		}
		feedbackContext, cancel = requestTimeout(ctx, 5*time.Second)
		defer cancel()
		if _, err := r.feedback.ApplyFeedback(feedbackContext, event.MessageID, event.UserID, label, event.Removed, time.Now()); err != nil {
			log.Printf("[fairy] apply explicit reply feedback: %v", err)
		}
	case protocol.NoticeTypeFriendRecall, protocol.NoticeTypeGroupRecall:
		feedbackContext, cancel := requestTimeout(ctx, 5*time.Second)
		defer cancel()
		if _, err := r.feedback.DeleteFeedbackOutput(feedbackContext, event.MessageID); err != nil {
			log.Printf("[fairy] delete recalled reply feedback: %v", err)
		}
	}
}

type feedbackOutputAvailability interface {
	FeedbackOutputExists(context.Context, string) (bool, error)
}

func (r *Runner) feedbackOutputExists(ctx context.Context, messageID string) (bool, error) {
	checker, ok := r.feedback.(feedbackOutputAvailability)
	if !ok {
		return true, nil
	}
	return checker.FeedbackOutputExists(ctx, messageID)
}

func (r *Runner) applyFeedbackEventually(event protocol.NoticeEvent, label FeedbackLabel) {
	feedbackContext, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := r.waitForFeedbackOutput(feedbackContext, event.MessageID); err != nil {
		return
	}
	if _, err := r.feedback.ApplyFeedback(feedbackContext, event.MessageID, event.UserID, label, event.Removed, time.Now()); err != nil {
		log.Printf("[fairy] apply explicit reply feedback: %v", err)
	}
}

func (r *Runner) waitForFeedbackOutput(ctx context.Context, messageID string) error {
	ticker := time.NewTicker(25 * time.Millisecond)
	defer ticker.Stop()
	for {
		exists, err := r.feedbackOutputExists(ctx, messageID)
		if err != nil || exists {
			return err
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-ticker.C:
		}
	}
}

func (r *Runner) submitFriendRequest(ctx context.Context, client *Client, flag string) {
	accepted, err := r.scheduler.Submit(ctx, scheduledTurn{
		source:         "zzz-friend-request",
		eventID:        flag,
		conversationID: "control:friend-requests",
		run: func(turnContext context.Context) {
			if err := r.acceptFriend(turnContext, client, flag); err != nil && turnContext.Err() == nil {
				log.Printf("[fairy] accept friend request: %v", err)
			}
		},
	})
	if err != nil {
		log.Printf("[fairy] friend request admission rejected: %v", err)
	} else if !accepted {
		log.Printf("[fairy] duplicate friend request ignored")
	}
}

func (r *Runner) shutdownScheduler() {
	shutdownContext, cancel := context.WithTimeout(context.Background(), r.cfg.DrainTimeout)
	defer cancel()
	if err := r.scheduler.Shutdown(shutdownContext); err != nil {
		log.Printf("[fairy] scheduler drain ended: %v", err)
	}
}
