package fairy

import (
	"context"
	"encoding/json"
	"math"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/icradp/zzz-im-server/internal/protocol"
)

func TestSQLiteFeedbackStorePersistsHashedReferencesAndRatingChanges(t *testing.T) {
	cfg := testConfig(t)
	messageID := "raw-output-message-93"
	aliceID := "raw-private-user-alice"
	bobID := "raw-private-user-bob"
	conversationID := "private_raw-user-alice_fairy"
	replyBody := "private Fairy reply body must never be stored"
	now := time.Now().Add(-time.Minute)

	store, err := OpenSQLiteTraceStore(cfg.TraceDB, cfg.TraceKeyFile)
	if err != nil {
		t.Fatal(err)
	}
	if err := store.RegisterFeedbackOutput(context.Background(), messageID, "turn-feedback-persist", now); err != nil {
		t.Fatal(err)
	}
	if err := store.Close(); err != nil {
		t.Fatal(err)
	}

	store, err = OpenSQLiteTraceStore(cfg.TraceDB, cfg.TraceKeyFile)
	if err != nil {
		t.Fatal(err)
	}
	changed, err := store.ApplyFeedback(context.Background(), messageID, aliceID, FeedbackPositive, false, now.Add(time.Second))
	if err != nil || !changed {
		t.Fatalf("add positive feedback: changed=%v err=%v", changed, err)
	}
	changed, err = store.ApplyFeedback(context.Background(), messageID, aliceID, FeedbackNegative, false, now.Add(2*time.Second))
	if err != nil || !changed {
		t.Fatalf("replace with negative feedback: changed=%v err=%v", changed, err)
	}
	changed, err = store.ApplyFeedback(context.Background(), messageID, aliceID, FeedbackPositive, true, now.Add(3*time.Second))
	if err != nil || changed {
		t.Fatalf("stale positive removal changed negative feedback: changed=%v err=%v", changed, err)
	}
	changed, err = store.ApplyFeedback(context.Background(), messageID, bobID, FeedbackPositive, false, now.Add(4*time.Second))
	if err != nil || !changed {
		t.Fatalf("add second actor feedback: changed=%v err=%v", changed, err)
	}

	stats, err := store.FeedbackStats(context.Background(), now.Add(-time.Minute))
	if err != nil {
		t.Fatal(err)
	}
	if stats.RatedOutputs != 1 || stats.Positive != 1 || stats.Negative != 1 || math.Abs(stats.PositiveRate-0.5) > 0.0001 {
		t.Fatalf("mixed feedback stats = %#v", stats)
	}
	changed, err = store.ApplyFeedback(context.Background(), messageID, aliceID, FeedbackNegative, true, now.Add(5*time.Second))
	if err != nil || !changed {
		t.Fatalf("remove current negative feedback: changed=%v err=%v", changed, err)
	}
	changed, err = store.ApplyFeedback(context.Background(), messageID, aliceID, FeedbackNegative, true, now.Add(6*time.Second))
	if err != nil || changed {
		t.Fatalf("repeat negative removal: changed=%v err=%v", changed, err)
	}

	var messageRef, actorRef, turnID, label string
	err = store.db.QueryRow(`
SELECT outputs.message_ref, ratings.actor_ref, outputs.turn_id, ratings.label
FROM fairy_feedback_outputs AS outputs
JOIN fairy_feedback_ratings AS ratings ON ratings.message_ref = outputs.message_ref`).Scan(
		&messageRef, &actorRef, &turnID, &label,
	)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(messageRef, "hmac-sha256:") || !strings.HasPrefix(actorRef, "hmac-sha256:") ||
		messageRef == messageID || actorRef == bobID || turnID != "turn-feedback-persist" || label != string(FeedbackPositive) {
		t.Fatalf("stored feedback metadata = ref=%q actor=%q turn=%q label=%q", messageRef, actorRef, turnID, label)
	}
	if err := store.Close(); err != nil {
		t.Fatal(err)
	}

	paths, err := filepath.Glob(cfg.TraceDB + "*")
	if err != nil {
		t.Fatal(err)
	}
	for _, path := range paths {
		data, readErr := os.ReadFile(path)
		if readErr != nil {
			t.Fatal(readErr)
		}
		for _, forbidden := range []string{messageID, aliceID, bobID, conversationID, replyBody} {
			if strings.Contains(string(data), forbidden) {
				t.Fatalf("feedback database %s contains raw private value %q", path, forbidden)
			}
		}
	}
}

func TestSQLiteFeedbackStoreIgnoresUnknownOutputsAndRecallDeletesRatings(t *testing.T) {
	cfg := testConfig(t)
	store, err := OpenSQLiteTraceStore(cfg.TraceDB, cfg.TraceKeyFile)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	now := time.Now()
	changed, err := store.ApplyFeedback(context.Background(), "not-a-fairy-output", "alice", FeedbackPositive, false, now)
	if err != nil || changed {
		t.Fatalf("unknown output feedback: changed=%v err=%v", changed, err)
	}
	if err := store.RegisterFeedbackOutput(context.Background(), "fairy-output", "turn-feedback-recall", now); err != nil {
		t.Fatal(err)
	}
	if changed, err = store.ApplyFeedback(context.Background(), "fairy-output", "alice", FeedbackPositive, false, now); err != nil || !changed {
		t.Fatalf("add feedback before recall: changed=%v err=%v", changed, err)
	}
	deleted, err := store.DeleteFeedbackOutput(context.Background(), "fairy-output")
	if err != nil || !deleted {
		t.Fatalf("delete recalled output: deleted=%v err=%v", deleted, err)
	}
	stats, err := store.FeedbackStats(context.Background(), now.Add(-time.Minute))
	if err != nil || stats.RatedOutputs != 0 || stats.Positive != 0 || stats.Negative != 0 {
		t.Fatalf("feedback remained after recall: stats=%#v err=%v", stats, err)
	}
	if changed, err = store.ApplyFeedback(context.Background(), "fairy-output", "alice", FeedbackNegative, false, now); err != nil || changed {
		t.Fatalf("recalled output accepted feedback: changed=%v err=%v", changed, err)
	}
	if deleted, err = store.DeleteFeedbackOutput(context.Background(), "fairy-output"); err != nil || deleted {
		t.Fatalf("repeat recalled output deletion: deleted=%v err=%v", deleted, err)
	}
}

func TestSQLiteFeedbackStoreReportsOutputAvailability(t *testing.T) {
	cfg := testConfig(t)
	store, err := OpenSQLiteTraceStore(cfg.TraceDB, cfg.TraceKeyFile)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	now := time.Now()
	exists, err := store.FeedbackOutputExists(context.Background(), "missing-output")
	if err != nil || exists {
		t.Fatalf("missing feedback output = exists:%v err:%v", exists, err)
	}
	if err := store.RegisterFeedbackOutput(context.Background(), "available-output", "turn-feedback-available", now); err != nil {
		t.Fatal(err)
	}
	exists, err = store.FeedbackOutputExists(context.Background(), "available-output")
	if err != nil || !exists {
		t.Fatalf("registered feedback output = exists:%v err:%v", exists, err)
	}
}

func TestSQLiteFeedbackStorePrunesExpiredOutputs(t *testing.T) {
	cfg := testConfig(t)
	store, err := OpenSQLiteTraceStore(cfg.TraceDB, cfg.TraceKeyFile)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	store.retention = time.Minute
	old := time.Now().Add(-2 * time.Minute)
	if err := store.RegisterFeedbackOutput(context.Background(), "expired-output", "turn-feedback-expired", old); err != nil {
		t.Fatal(err)
	}
	store.nextCleanupAt = time.Time{}
	if _, err := store.FeedbackStats(context.Background(), time.Now().Add(-time.Hour)); err != nil {
		t.Fatal(err)
	}
	var outputs int
	if err := store.db.QueryRow(`SELECT COUNT(*) FROM fairy_feedback_outputs`).Scan(&outputs); err != nil {
		t.Fatal(err)
	}
	if outputs != 0 {
		t.Fatalf("expired feedback outputs = %d", outputs)
	}
}

func TestRunnerDispatchHandlesOnlyEligibleExplicitFeedback(t *testing.T) {
	cfg := testConfig(t)
	store, err := OpenSQLiteTraceStore(cfg.TraceDB, cfg.TraceKeyFile)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	runner := NewRunner(cfg, nil, store)
	defer runner.shutdownScheduler()
	now := time.Now()
	if err := store.RegisterFeedbackOutput(context.Background(), "eligible-output", "turn-feedback-runner", now); err != nil {
		t.Fatal(err)
	}

	dispatchFeedbackNotice(t, runner, protocol.NoticeEvent{
		PostType: "notice", NoticeType: protocol.NoticeTypeMessageReaction,
		MessageID: "not-eligible", UserID: "alice", EmojiID: FairyPositiveReactionID,
	})
	dispatchFeedbackNotice(t, runner, protocol.NoticeEvent{
		PostType: "notice", NoticeType: protocol.NoticeTypeMessageReaction,
		MessageID: "eligible-output", UserID: "alice", EmojiID: "66",
	})
	dispatchFeedbackNotice(t, runner, protocol.NoticeEvent{
		PostType: "notice", NoticeType: protocol.NoticeTypeMessageReaction,
		MessageID: "eligible-output", UserID: cfg.UserID, EmojiID: FairyPositiveReactionID,
	})
	assertFeedbackStats(t, store, 0, 0, 0)

	dispatchFeedbackNotice(t, runner, protocol.NoticeEvent{
		PostType: "notice", NoticeType: protocol.NoticeTypeMessageReaction,
		MessageID: "eligible-output", UserID: "alice", EmojiID: FairyPositiveReactionID,
	})
	assertFeedbackStats(t, store, 1, 1, 0)
	dispatchFeedbackNotice(t, runner, protocol.NoticeEvent{
		PostType: "notice", NoticeType: protocol.NoticeTypeMessageReaction,
		MessageID: "eligible-output", UserID: "alice", EmojiID: FairyNegativeReactionID,
	})
	dispatchFeedbackNotice(t, runner, protocol.NoticeEvent{
		PostType: "notice", NoticeType: protocol.NoticeTypeMessageReaction,
		MessageID: "eligible-output", UserID: "alice", EmojiID: FairyPositiveReactionID, Removed: true,
	})
	assertFeedbackStats(t, store, 1, 0, 1)
	dispatchFeedbackNotice(t, runner, protocol.NoticeEvent{
		PostType: "notice", NoticeType: protocol.NoticeTypeFriendRecall, MessageID: "eligible-output",
	})
	assertFeedbackStats(t, store, 0, 0, 0)
}

func dispatchFeedbackNotice(t *testing.T, runner *Runner, event protocol.NoticeEvent) {
	t.Helper()
	payload, err := json.Marshal(event)
	if err != nil {
		t.Fatal(err)
	}
	runner.dispatch(context.Background(), nil, payload)
}

func assertFeedbackStats(t *testing.T, store *SQLiteTraceStore, outputs, positive, negative int) {
	t.Helper()
	stats, err := store.FeedbackStats(context.Background(), time.Now().Add(-time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	if stats.RatedOutputs != outputs || stats.Positive != positive || stats.Negative != negative {
		t.Fatalf("feedback stats = %#v, want outputs=%d positive=%d negative=%d", stats, outputs, positive, negative)
	}
}
