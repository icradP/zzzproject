package fairy

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"math"
	"math/rand"
	"sync"
	"sync/atomic"
	"time"

	"github.com/icradp/zzz-im-server/internal/protocol"
)

type Runner struct {
	cfg       Config
	engine    *Engine
	connected atomic.Bool
	workers   chan struct{}
	wait      sync.WaitGroup
}

func NewRunner(cfg Config, engine *Engine) *Runner {
	return &Runner{cfg: cfg, engine: engine, workers: make(chan struct{}, cfg.MaxConcurrent)}
}

func (r *Runner) Connected() bool { return r.connected.Load() }

func (r *Runner) Run(ctx context.Context) error {
	delay := r.cfg.ReconnectMin
	for {
		if err := ctx.Err(); err != nil {
			r.wait.Wait()
			return nil
		}
		err := r.runSession(ctx)
		r.connected.Store(false)
		if ctx.Err() != nil {
			r.wait.Wait()
			return nil
		}
		log.Printf("[fairy] session ended: %v; reconnecting in %s", err, delay)
		jitter := time.Duration(rand.Int63n(int64(delay/4 + 1)))
		select {
		case <-ctx.Done():
			r.wait.Wait()
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
	r.connected.Store(true)
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
		if err := r.acceptFriend(ctx, client, request.Flag); err != nil {
			log.Printf("[fairy] accept pending friend %s: %v", request.Flag, err)
		}
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
			r.runWorker(ctx, func(workerCtx context.Context) {
				if err := r.acceptFriend(workerCtx, client, event.Flag); err != nil {
					log.Printf("[fairy] accept friend request from %s: %v", event.UserID, err)
				}
			})
		}
	case "message":
		var event messageEvent
		if json.Unmarshal(payload, &event) == nil {
			r.runWorker(ctx, func(workerCtx context.Context) {
				r.engine.HandleMessage(workerCtx, client, event)
			})
		}
	}
}

func (r *Runner) runWorker(ctx context.Context, work func(context.Context)) {
	select {
	case r.workers <- struct{}{}:
		r.wait.Add(1)
		go func() {
			defer func() {
				<-r.workers
				r.wait.Done()
			}()
			work(ctx)
		}()
	default:
		log.Printf("[fairy] worker limit reached; event skipped")
	}
}
