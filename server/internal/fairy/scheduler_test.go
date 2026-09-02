package fairy

import (
	"context"
	"errors"
	"reflect"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

type memoryTraceStore struct {
	mu      sync.Mutex
	claimed map[string]struct{}
	events  []TraceEvent
}

func newMemoryTraceStore() *memoryTraceStore {
	return &memoryTraceStore{claimed: make(map[string]struct{})}
}

func (s *memoryTraceStore) ClaimIngress(_ context.Context, source, eventID string, _ time.Time) (bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	key := source + "\x00" + eventID
	if _, exists := s.claimed[key]; exists {
		return false, nil
	}
	s.claimed[key] = struct{}{}
	return true, nil
}

func (s *memoryTraceStore) Append(_ context.Context, event TraceEvent) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.events = append(s.events, event)
	return nil
}

func (*memoryTraceStore) Close() error { return nil }

func TestConversationSchedulerRunsOneConversationInFIFOOrder(t *testing.T) {
	cfg := testConfig(t)
	cfg.MaxConcurrent = 2
	scheduler := NewConversationScheduler(cfg, newMemoryTraceStore())
	firstStarted := make(chan struct{})
	releaseFirst := make(chan struct{})
	var mu sync.Mutex
	var order []int

	for index := 1; index <= 3; index++ {
		index := index
		accepted, err := scheduler.Submit(context.Background(), scheduledTurn{
			source:         "test",
			eventID:        runtimeEventID(index),
			conversationID: "conversation-a",
			run: func(context.Context) {
				mu.Lock()
				order = append(order, index)
				mu.Unlock()
				if index == 1 {
					close(firstStarted)
					<-releaseFirst
				}
			},
		})
		if err != nil || !accepted {
			t.Fatalf("submit %d: accepted=%v err=%v", index, accepted, err)
		}
		if index == 1 {
			waitForSignal(t, firstStarted, time.Second, "first turn start")
		}
	}
	close(releaseFirst)
	shutdownSchedulerForTest(t, scheduler)
	mu.Lock()
	defer mu.Unlock()
	if !reflect.DeepEqual(order, []int{1, 2, 3}) {
		t.Fatalf("turn order = %v", order)
	}
}

func TestRunnerReadyRequiresConnectionAndOpenAdmission(t *testing.T) {
	runner := NewRunner(testConfig(t), nil, newMemoryTraceStore())
	if runner.Ready() {
		t.Fatal("disconnected runner reported ready")
	}
	runner.connected.Store(true)
	if !runner.Ready() {
		t.Fatal("connected runner with open admission did not report ready")
	}
	runner.scheduler.CloseAdmission()
	if runner.Ready() {
		t.Fatal("runner with closed admission reported ready")
	}
}

func TestConversationSchedulerRunsDifferentConversationsWithGlobalLimit(t *testing.T) {
	cfg := testConfig(t)
	cfg.MaxConcurrent = 2
	scheduler := NewConversationScheduler(cfg, newMemoryTraceStore())
	started := make(chan struct{}, 3)
	release := make(chan struct{})
	var active atomic.Int32
	var maximum atomic.Int32

	for index := 1; index <= 3; index++ {
		index := index
		accepted, err := scheduler.Submit(context.Background(), scheduledTurn{
			source:         "test",
			eventID:        runtimeEventID(index),
			conversationID: "conversation-" + runtimeEventID(index),
			run: func(context.Context) {
				current := active.Add(1)
				for previous := maximum.Load(); current > previous && !maximum.CompareAndSwap(previous, current); previous = maximum.Load() {
				}
				started <- struct{}{}
				<-release
				active.Add(-1)
			},
		})
		if err != nil || !accepted {
			t.Fatalf("submit %d: accepted=%v err=%v", index, accepted, err)
		}
	}
	waitForSignal(t, started, time.Second, "first concurrent turn")
	waitForSignal(t, started, time.Second, "second concurrent turn")
	select {
	case <-started:
		t.Fatal("third conversation started above MaxConcurrent")
	case <-time.After(100 * time.Millisecond):
	}
	close(release)
	shutdownSchedulerForTest(t, scheduler)
	if maximum.Load() != 2 {
		t.Fatalf("maximum active conversations = %d, want 2", maximum.Load())
	}
}

func TestConversationSchedulerReturnsExplicitQueueLimitErrors(t *testing.T) {
	t.Run("conversation", func(t *testing.T) {
		cfg := testConfig(t)
		cfg.MaxConcurrent = 1
		cfg.MaxPending = 10
		cfg.MaxConversationPending = 1
		scheduler := NewConversationScheduler(cfg, newMemoryTraceStore())
		started := make(chan struct{})
		release := make(chan struct{})
		submitBlockingTurn(t, scheduler, "event-1", "conversation-a", started, release)
		waitForSignal(t, started, time.Second, "blocking turn")
		accepted, err := scheduler.Submit(context.Background(), noOpTurn("event-2", "conversation-a"))
		if err != nil || !accepted {
			t.Fatalf("queue first pending turn: accepted=%v err=%v", accepted, err)
		}
		accepted, err = scheduler.Submit(context.Background(), noOpTurn("event-3", "conversation-a"))
		if accepted || !errors.Is(err, ErrConversationPending) {
			t.Fatalf("conversation overflow: accepted=%v err=%v", accepted, err)
		}
		close(release)
		shutdownSchedulerForTest(t, scheduler)
	})

	t.Run("global", func(t *testing.T) {
		cfg := testConfig(t)
		cfg.MaxConcurrent = 1
		cfg.MaxPending = 1
		cfg.MaxConversationPending = 1
		scheduler := NewConversationScheduler(cfg, newMemoryTraceStore())
		started := make(chan struct{})
		release := make(chan struct{})
		submitBlockingTurn(t, scheduler, "event-1", "conversation-a", started, release)
		waitForSignal(t, started, time.Second, "blocking turn")
		accepted, err := scheduler.Submit(context.Background(), noOpTurn("event-2", "conversation-b"))
		if err != nil || !accepted {
			t.Fatalf("queue global pending turn: accepted=%v err=%v", accepted, err)
		}
		accepted, err = scheduler.Submit(context.Background(), noOpTurn("event-3", "conversation-c"))
		if accepted || !errors.Is(err, ErrPendingLimit) {
			t.Fatalf("global overflow: accepted=%v err=%v", accepted, err)
		}
		close(release)
		shutdownSchedulerForTest(t, scheduler)
	})
}

func TestConversationSchedulerDeduplicatesIngress(t *testing.T) {
	cfg := testConfig(t)
	scheduler := NewConversationScheduler(cfg, newMemoryTraceStore())
	var calls atomic.Int32
	turn := scheduledTurn{
		source:         "test",
		eventID:        "same-event",
		conversationID: "conversation-a",
		run:            func(context.Context) { calls.Add(1) },
	}
	accepted, err := scheduler.Submit(context.Background(), turn)
	if err != nil || !accepted {
		t.Fatalf("first submit: accepted=%v err=%v", accepted, err)
	}
	accepted, err = scheduler.Submit(context.Background(), turn)
	if err != nil || accepted {
		t.Fatalf("duplicate submit: accepted=%v err=%v", accepted, err)
	}
	shutdownSchedulerForTest(t, scheduler)
	if calls.Load() != 1 {
		t.Fatalf("turn calls = %d, want 1", calls.Load())
	}
}

func TestConversationSchedulerAllowsRetryableControlIngress(t *testing.T) {
	cfg := testConfig(t)
	scheduler := NewConversationScheduler(cfg, newMemoryTraceStore())
	var calls atomic.Int32
	turn := scheduledTurn{
		source:         "test-control",
		eventID:        "retryable-event",
		conversationID: "control:test",
		retryable:      true,
		run:            func(context.Context) { calls.Add(1) },
	}
	for attempt := 0; attempt < 2; attempt++ {
		accepted, err := scheduler.Submit(context.Background(), turn)
		if err != nil || !accepted {
			t.Fatalf("submit %d: accepted=%v err=%v", attempt+1, accepted, err)
		}
	}
	shutdownSchedulerForTest(t, scheduler)
	if calls.Load() != 2 {
		t.Fatalf("retryable turn calls = %d, want 2", calls.Load())
	}
}

func TestConversationSchedulerStopCancelsAndRunsBeforeFollowups(t *testing.T) {
	cfg := testConfig(t)
	scheduler := NewConversationScheduler(cfg, newMemoryTraceStore())
	started := make(chan struct{})
	var mu sync.Mutex
	var actions []string
	record := func(action string) {
		mu.Lock()
		actions = append(actions, action)
		mu.Unlock()
	}
	accepted, err := scheduler.Submit(context.Background(), scheduledTurn{
		source:         "test",
		eventID:        "current",
		conversationID: "conversation-a",
		run: func(ctx context.Context) {
			record("current-start")
			close(started)
			<-ctx.Done()
			record("current-cancelled")
		},
	})
	if err != nil || !accepted {
		t.Fatalf("submit current: accepted=%v err=%v", accepted, err)
	}
	waitForSignal(t, started, time.Second, "current turn")
	accepted, err = scheduler.Submit(context.Background(), scheduledTurn{
		source: "test", eventID: "followup", conversationID: "conversation-a",
		run: func(context.Context) { record("followup") },
	})
	if err != nil || !accepted {
		t.Fatalf("submit followup: accepted=%v err=%v", accepted, err)
	}
	accepted, err = scheduler.Submit(context.Background(), scheduledTurn{
		source: "test", eventID: "stop", conversationID: "conversation-a", priority: true,
		run: func(context.Context) { record("stop") },
	})
	if err != nil || !accepted {
		t.Fatalf("submit stop: accepted=%v err=%v", accepted, err)
	}
	shutdownSchedulerForTest(t, scheduler)
	mu.Lock()
	defer mu.Unlock()
	want := []string{"current-start", "current-cancelled", "stop", "followup"}
	if !reflect.DeepEqual(actions, want) {
		t.Fatalf("actions = %v, want %v", actions, want)
	}
}

func TestConversationSchedulerShutdownCancelsActiveAndDiscardsPending(t *testing.T) {
	cfg := testConfig(t)
	cfg.MaxConcurrent = 1
	scheduler := NewConversationScheduler(cfg, newMemoryTraceStore())
	started := make(chan struct{})
	cause := make(chan error, 1)
	accepted, err := scheduler.Submit(context.Background(), scheduledTurn{
		source:         "test",
		eventID:        "current",
		conversationID: "conversation-a",
		run: func(ctx context.Context) {
			close(started)
			<-ctx.Done()
			cause <- context.Cause(ctx)
		},
	})
	if err != nil || !accepted {
		t.Fatalf("submit current: accepted=%v err=%v", accepted, err)
	}
	waitForSignal(t, started, time.Second, "current turn")
	var pendingRan atomic.Bool
	accepted, err = scheduler.Submit(context.Background(), scheduledTurn{
		source: "test", eventID: "pending", conversationID: "conversation-a",
		run: func(context.Context) { pendingRan.Store(true) },
	})
	if err != nil || !accepted {
		t.Fatalf("submit pending: accepted=%v err=%v", accepted, err)
	}
	shutdownContext, cancel := context.WithTimeout(context.Background(), 30*time.Millisecond)
	defer cancel()
	if err := scheduler.Shutdown(shutdownContext); !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("shutdown error = %v", err)
	}
	if received := <-cause; !errors.Is(received, ErrSchedulerShuttingDown) {
		t.Fatalf("active turn cause = %v", received)
	}
	if pendingRan.Load() {
		t.Fatal("pending turn ran after forced shutdown")
	}
}

func submitBlockingTurn(t *testing.T, scheduler *ConversationScheduler, eventID, conversationID string, started chan<- struct{}, release <-chan struct{}) {
	t.Helper()
	accepted, err := scheduler.Submit(context.Background(), scheduledTurn{
		source: "test", eventID: eventID, conversationID: conversationID,
		run: func(context.Context) {
			close(started)
			<-release
		},
	})
	if err != nil || !accepted {
		t.Fatalf("submit blocking turn: accepted=%v err=%v", accepted, err)
	}
}

func noOpTurn(eventID, conversationID string) scheduledTurn {
	return scheduledTurn{
		source: "test", eventID: eventID, conversationID: conversationID,
		run: func(context.Context) {},
	}
}

func shutdownSchedulerForTest(t *testing.T, scheduler *ConversationScheduler) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	if err := scheduler.Shutdown(ctx); err != nil {
		t.Fatalf("shutdown scheduler: %v", err)
	}
}

func waitForSignal(t *testing.T, signal <-chan struct{}, timeout time.Duration, description string) {
	t.Helper()
	select {
	case <-signal:
	case <-time.After(timeout):
		t.Fatalf("timed out waiting for %s", description)
	}
}

func runtimeEventID(index int) string {
	return time.Unix(int64(index), 0).UTC().Format("150405")
}
