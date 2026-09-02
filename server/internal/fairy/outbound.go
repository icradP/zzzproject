package fairy

import (
	"context"
	"errors"
	"fmt"
	"log"
	"sync"
	"sync/atomic"
	"time"

	"github.com/icradp/zzz-im-server/internal/protocol"
)

const (
	defaultOutboundMaxAttempts    = 3
	defaultOutboundAttemptTimeout = 5 * time.Second
	defaultOutboundRetryDelay     = 100 * time.Millisecond
)

type OutboundDeliveryStats struct {
	Delivered      uint64 `json:"delivered"`
	RetryAttempts  uint64 `json:"retry_attempts"`
	Failed         uint64 `json:"failed"`
	OutcomeUnknown uint64 `json:"outcome_unknown"`
}

// reliableMessenger keeps generated replies in memory while a running Fairy
// process reconnects. Every attempt reuses one client_message_id so the IM
// server can return the original message instead of broadcasting a duplicate.
type reliableMessenger struct {
	mu      sync.Mutex
	client  *Client
	changed chan struct{}

	maxAttempts    int
	attemptTimeout time.Duration
	retryDelay     time.Duration

	delivered      atomic.Uint64
	retryAttempts  atomic.Uint64
	failed         atomic.Uint64
	outcomeUnknown atomic.Uint64
	feedback       FeedbackOutputRecorder
	now            func() time.Time
}

func newReliableMessenger(recorders ...FeedbackOutputRecorder) *reliableMessenger {
	messenger := &reliableMessenger{
		changed:        make(chan struct{}),
		maxAttempts:    defaultOutboundMaxAttempts,
		attemptTimeout: defaultOutboundAttemptTimeout,
		retryDelay:     defaultOutboundRetryDelay,
		now:            time.Now,
	}
	if len(recorders) > 0 {
		messenger.feedback = recorders[0]
	}
	return messenger
}

func (m *reliableMessenger) Attach(client *Client) {
	if m == nil || client == nil {
		return
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.client == client {
		return
	}
	m.client = client
	m.signalChangeLocked()
}

func (m *reliableMessenger) Detach(client *Client) {
	if m == nil || client == nil {
		return
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.client != client {
		return
	}
	m.client = nil
	m.signalChangeLocked()
}

func (m *reliableMessenger) signalChangeLocked() {
	close(m.changed)
	m.changed = make(chan struct{})
}

func (m *reliableMessenger) waitForClient(ctx context.Context) (*Client, error) {
	for {
		m.mu.Lock()
		client := m.client
		changed := m.changed
		m.mu.Unlock()
		if client != nil {
			return client, nil
		}
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-changed:
		}
	}
}

func (m *reliableMessenger) SendText(ctx context.Context, conversationID, messageID, text string) error {
	clientMessageID, err := newRuntimeID("fairy-msg")
	if err != nil {
		m.failed.Add(1)
		return fmt.Errorf("generate Fairy client message ID: %w", err)
	}

	feedbackTurnID, feedbackEligible := feedbackTurnIDFromContext(ctx)
	var lastErr error
	attempted := false
	for attempt := 0; attempt < m.maxAttempts; attempt++ {
		client, waitErr := m.waitForClient(ctx)
		if waitErr != nil {
			m.failed.Add(1)
			if attempted {
				m.outcomeUnknown.Add(1)
				return fmt.Errorf("deliver Fairy reply outcome unknown after %v: %w", lastErr, waitErr)
			}
			return fmt.Errorf("wait for Fairy IM connection: %w", waitErr)
		}
		if attempt > 0 {
			m.retryAttempts.Add(1)
		}
		attempted = true
		attemptCtx, cancel := requestTimeout(ctx, m.attemptTimeout)
		var serverMessageID string
		serverMessageID, err = client.sendTextWithID(attemptCtx, conversationID, messageID, text, clientMessageID)
		cancel()
		if err == nil {
			m.delivered.Add(1)
			if feedbackEligible && m.feedback != nil {
				feedbackContext, feedbackCancel := context.WithTimeout(context.Background(), 5*time.Second)
				feedbackErr := m.feedback.RegisterFeedbackOutput(feedbackContext, serverMessageID, feedbackTurnID, m.now())
				feedbackCancel()
				if feedbackErr != nil {
					log.Printf("[fairy] register eligible feedback output: %v", feedbackErr)
				}
			}
			return nil
		}
		lastErr = err
		var apiError *APIError
		if errors.As(err, &apiError) {
			m.failed.Add(1)
			return err
		}
		if attempt+1 >= m.maxAttempts || ctx.Err() != nil {
			m.failed.Add(1)
			m.outcomeUnknown.Add(1)
			return fmt.Errorf("deliver Fairy reply outcome unknown after %d attempts: %w", attempt+1, err)
		}
		if clientClosed(client) {
			m.Detach(client)
			continue
		}
		if retryErr := waitForOutboundRetry(ctx, client, m.retryDelay); retryErr != nil {
			m.failed.Add(1)
			m.outcomeUnknown.Add(1)
			return fmt.Errorf("deliver Fairy reply outcome unknown after %v: %w", lastErr, retryErr)
		}
		if clientClosed(client) {
			m.Detach(client)
		}
	}
	panic("unreachable")
}

func (m *reliableMessenger) GetGroupMembers(ctx context.Context, groupID string) ([]protocol.GroupMember, error) {
	client, err := m.waitForClient(ctx)
	if err != nil {
		return nil, fmt.Errorf("wait for Fairy IM connection: %w", err)
	}
	return client.GetGroupMembers(ctx, groupID)
}

func (m *reliableMessenger) Stats() OutboundDeliveryStats {
	if m == nil {
		return OutboundDeliveryStats{}
	}
	return OutboundDeliveryStats{
		Delivered:      m.delivered.Load(),
		RetryAttempts:  m.retryAttempts.Load(),
		Failed:         m.failed.Load(),
		OutcomeUnknown: m.outcomeUnknown.Load(),
	}
}

func clientClosed(client *Client) bool {
	select {
	case <-client.Done():
		return true
	default:
		return false
	}
}

func waitForOutboundRetry(ctx context.Context, client *Client, delay time.Duration) error {
	timer := time.NewTimer(delay)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-client.Done():
		return nil
	case <-timer.C:
		return nil
	}
}
