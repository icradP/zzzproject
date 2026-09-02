package fairy

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"log"
	"sync"
	"time"
)

var (
	ErrSchedulerClosed       = errors.New("Fairy scheduler is closed")
	ErrPendingLimit          = errors.New("Fairy global pending limit reached")
	ErrConversationPending   = errors.New("Fairy conversation pending limit reached")
	ErrTurnStoppedByUser     = errors.New("Fairy turn stopped by user")
	ErrSchedulerShuttingDown = errors.New("Fairy scheduler is shutting down")
)

type scheduledTurn struct {
	source         string
	eventID        string
	conversationID string
	priority       bool
	// retryable skips the persistent ingress claim. Its caller must coalesce
	// concurrent duplicates and provide an authoritative retry source.
	retryable bool
	run       func(context.Context)
	traceID   string
	turnID    string
}

type conversationQueue struct {
	items         []scheduledTurn
	running       bool
	controlQueued bool
	currentCancel context.CancelCauseFunc
}

type ConversationScheduler struct {
	mu                     sync.Mutex
	accepting              bool
	queues                 map[string]*conversationQueue
	pending                int
	maxPending             int
	maxConversationPending int
	turnTimeout            time.Duration
	slots                  chan struct{}
	trace                  TraceStore
	lifecycle              context.Context
	cancelLifecycle        context.CancelCauseFunc
	wait                   sync.WaitGroup
}

type SchedulerStats struct {
	Accepting       bool `json:"accepting"`
	Pending         int  `json:"pending"`
	Conversations   int  `json:"conversations"`
	Active          int  `json:"active"`
	MaxPending      int  `json:"max_pending"`
	MaxConcurrent   int  `json:"max_concurrent"`
	MaxConversation int  `json:"max_conversation_pending"`
}

func NewConversationScheduler(cfg Config, trace TraceStore) *ConversationScheduler {
	lifecycle, cancel := context.WithCancelCause(context.Background())
	return &ConversationScheduler{
		accepting:              true,
		queues:                 make(map[string]*conversationQueue),
		maxPending:             cfg.MaxPending,
		maxConversationPending: cfg.MaxConversationPending,
		turnTimeout:            cfg.TurnTimeout,
		slots:                  make(chan struct{}, cfg.MaxConcurrent),
		trace:                  trace,
		lifecycle:              lifecycle,
		cancelLifecycle:        cancel,
	}
}

func (s *ConversationScheduler) Submit(ctx context.Context, turn scheduledTurn) (bool, error) {
	if turn.source == "" || turn.eventID == "" || turn.conversationID == "" || turn.run == nil {
		return false, fmt.Errorf("invalid Fairy scheduled turn")
	}
	traceID, err := newRuntimeID("trace")
	if err != nil {
		return false, err
	}
	turn.traceID = traceID
	turnID, err := newRuntimeID("turn")
	if err != nil {
		return false, err
	}
	turn.turnID = turnID
	now := time.Now()

	s.mu.Lock()
	if !s.accepting {
		s.mu.Unlock()
		return false, ErrSchedulerClosed
	}
	queue := s.queues[turn.conversationID]
	priorityBypass := turn.priority && queue != nil && (queue.currentCancel != nil || len(queue.items) > 0) && !queue.controlQueued
	if s.pending >= s.maxPending && !priorityBypass {
		pending := s.pending
		s.mu.Unlock()
		s.appendTrace(TraceEvent{Time: now, Type: TraceAdmissionRejected, TraceID: traceID, ConversationID: turn.conversationID, Source: turn.source, Status: "global_pending_limit", Pending: pending})
		return false, ErrPendingLimit
	}
	queueDepth := 0
	if queue != nil {
		queueDepth = len(queue.items)
	}
	if queueDepth >= s.maxConversationPending && !priorityBypass {
		pending := s.pending
		s.mu.Unlock()
		s.appendTrace(TraceEvent{Time: now, Type: TraceAdmissionRejected, TraceID: traceID, ConversationID: turn.conversationID, Source: turn.source, Status: "conversation_pending_limit", QueueDepth: queueDepth, Pending: pending})
		return false, ErrConversationPending
	}
	if !turn.retryable {
		claimed, err := s.trace.ClaimIngress(ctx, turn.source, turn.eventID, now)
		if err != nil {
			s.mu.Unlock()
			return false, err
		}
		if !claimed {
			s.mu.Unlock()
			s.appendTrace(TraceEvent{Time: now, Type: TraceIngressDuplicate, TraceID: traceID, ConversationID: turn.conversationID, Source: turn.source, Status: "ignored"})
			return false, nil
		}
	}
	if queue == nil {
		queue = &conversationQueue{}
		s.queues[turn.conversationID] = queue
	}
	if turn.priority {
		if queue.currentCancel != nil {
			queue.currentCancel(ErrTurnStoppedByUser)
		}
		queue.items = append([]scheduledTurn{turn}, queue.items...)
		queue.controlQueued = true
	} else {
		queue.items = append(queue.items, turn)
	}
	s.pending++
	queueDepth = len(queue.items)
	pending := s.pending
	startActor := false
	if !queue.running {
		queue.running = true
		s.wait.Add(1)
		startActor = true
	}
	s.mu.Unlock()
	s.appendTrace(TraceEvent{Time: now, Type: TraceAdmissionAccepted, TraceID: traceID, ConversationID: turn.conversationID, Source: turn.source, Status: "admitted", QueueDepth: queueDepth, Pending: pending})
	if startActor {
		go s.runConversation(turn.conversationID, queue)
	}
	return true, nil
}

func (s *ConversationScheduler) Cancel(conversationID string, cause error) bool {
	if cause == nil {
		cause = context.Canceled
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	queue := s.queues[conversationID]
	if queue == nil || queue.currentCancel == nil {
		return false
	}
	queue.currentCancel(cause)
	return true
}

func (s *ConversationScheduler) Stats() SchedulerStats {
	s.mu.Lock()
	defer s.mu.Unlock()
	return SchedulerStats{
		Accepting:       s.accepting,
		Pending:         s.pending,
		Conversations:   len(s.queues),
		Active:          len(s.slots),
		MaxPending:      s.maxPending,
		MaxConcurrent:   cap(s.slots),
		MaxConversation: s.maxConversationPending,
	}
}

func (s *ConversationScheduler) CloseAdmission() {
	s.mu.Lock()
	s.accepting = false
	s.mu.Unlock()
}

func (s *ConversationScheduler) Shutdown(ctx context.Context) error {
	s.CloseAdmission()
	done := make(chan struct{})
	go func() {
		s.wait.Wait()
		close(done)
	}()
	select {
	case <-done:
		return nil
	case <-ctx.Done():
		s.cancelLifecycle(ErrSchedulerShuttingDown)
		<-done
		return ctx.Err()
	}
}

func (s *ConversationScheduler) runConversation(conversationID string, queue *conversationQueue) {
	defer s.wait.Done()
	select {
	case s.slots <- struct{}{}:
		defer func() { <-s.slots }()
	case <-s.lifecycle.Done():
		s.discardQueue(conversationID, queue)
		return
	}
	for {
		turn, turnContext, finish, ok := s.nextTurn(conversationID, queue)
		if !ok {
			return
		}
		s.appendTrace(TraceEvent{Time: time.Now(), Type: TraceTurnStarted, TraceID: turn.traceID, TurnID: turn.turnID, ConversationID: conversationID, Source: turn.source, Status: "running"})
		turn.run(turnContext)
		cause := finish()
		eventType := TraceTurnCompleted
		status := "completed"
		switch {
		case errors.Is(cause, ErrTurnStoppedByUser):
			eventType = TraceTurnCancelled
			status = "user_cancelled"
		case errors.Is(cause, context.DeadlineExceeded):
			eventType = TraceTurnTimedOut
			status = "deadline_exceeded"
		case cause != nil:
			eventType = TraceTurnCancelled
			status = "runtime_cancelled"
		}
		s.appendTrace(TraceEvent{Time: time.Now(), Type: eventType, TraceID: turn.traceID, TurnID: turn.turnID, ConversationID: conversationID, Source: turn.source, Status: status})
	}
}

func (s *ConversationScheduler) nextTurn(conversationID string, queue *conversationQueue) (scheduledTurn, context.Context, func() error, bool) {
	s.mu.Lock()
	if s.lifecycle.Err() != nil {
		s.pending -= len(queue.items)
		queue.items = nil
		queue.running = false
		delete(s.queues, conversationID)
		s.mu.Unlock()
		return scheduledTurn{}, nil, nil, false
	}
	if len(queue.items) == 0 {
		queue.running = false
		delete(s.queues, conversationID)
		s.mu.Unlock()
		return scheduledTurn{}, nil, nil, false
	}
	turn := queue.items[0]
	queue.items = queue.items[1:]
	if turn.priority {
		queue.controlQueued = false
	}
	s.pending--
	baseContext, cancelCause := context.WithCancelCause(s.lifecycle)
	turnContext, cancelTimeout := context.WithTimeoutCause(baseContext, s.turnTimeout, context.DeadlineExceeded)
	turnContext = withTurnTraceScope(turnContext, TurnTraceScope{
		TraceID: turn.traceID, TurnID: turn.turnID, ConversationID: conversationID, Source: turn.source,
	})
	queue.currentCancel = cancelCause
	s.mu.Unlock()
	finish := func() error {
		s.mu.Lock()
		cause := context.Cause(turnContext)
		queue.currentCancel = nil
		s.mu.Unlock()
		cancelTimeout()
		cancelCause(nil)
		return cause
	}
	return turn, turnContext, finish, true
}

func (s *ConversationScheduler) discardQueue(conversationID string, queue *conversationQueue) {
	s.mu.Lock()
	s.pending -= len(queue.items)
	queue.items = nil
	queue.running = false
	delete(s.queues, conversationID)
	s.mu.Unlock()
}

func (s *ConversationScheduler) appendTrace(event TraceEvent) {
	traceContext, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := s.trace.Append(traceContext, event); err != nil {
		log.Printf("[fairy] append trace event %s: %v", event.Type, err)
	}
}

func newRuntimeID(prefix string) (string, error) {
	value := make([]byte, 16)
	if _, err := rand.Read(value); err != nil {
		return "", fmt.Errorf("generate Fairy %s ID: %w", prefix, err)
	}
	return prefix + "_" + hex.EncodeToString(value), nil
}
