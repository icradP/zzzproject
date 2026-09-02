package fairy

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"errors"
	"fmt"
	"time"
)

const (
	feedbackMessageRefDomain = "fairy-feedback-message:v1"
	feedbackActorRefDomain   = "fairy-feedback-actor:v1"
)

func (s *SQLiteTraceStore) RegisterFeedbackOutput(ctx context.Context, messageID, turnID string, at time.Time) error {
	if !validFeedbackSourceID(messageID, 1024) || !validRuntimeID(turnID) {
		return fmt.Errorf("invalid Fairy feedback output metadata")
	}
	if at.IsZero() {
		at = time.Now()
	}
	if err := s.pruneIfDue(ctx, at); err != nil {
		return err
	}
	_, err := s.db.ExecContext(ctx, `
INSERT INTO fairy_feedback_outputs(message_ref, turn_id, created_at, expires_at)
VALUES (?, ?, ?, ?)
ON CONFLICT(message_ref) DO NOTHING`,
		s.feedbackMessageRef(messageID), turnID, at.UnixMilli(), at.Add(s.retention).UnixMilli(),
	)
	if err != nil {
		return fmt.Errorf("register Fairy feedback output: %w", err)
	}
	return nil
}

// FeedbackOutputExists reports whether a recently sent Fairy output is
// eligible for feedback. It is used to absorb the small race between the IM
// reaction notice and the asynchronous output registration.
func (s *SQLiteTraceStore) FeedbackOutputExists(ctx context.Context, messageID string) (bool, error) {
	if !validFeedbackSourceID(messageID, 1024) {
		return false, fmt.Errorf("invalid Fairy feedback output metadata")
	}
	var exists int
	err := s.db.QueryRowContext(ctx, `
SELECT 1 FROM fairy_feedback_outputs
WHERE message_ref = ? AND expires_at > ?`, s.feedbackMessageRef(messageID), time.Now().UnixMilli()).Scan(&exists)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, fmt.Errorf("find Fairy feedback output: %w", err)
	}
	return exists == 1, nil
}

func (s *SQLiteTraceStore) ApplyFeedback(
	ctx context.Context,
	messageID, actorID string,
	label FeedbackLabel,
	removed bool,
	at time.Time,
) (bool, error) {
	if !validFeedbackSourceID(messageID, 1024) || !validFeedbackSourceID(actorID, 256) || !validFeedbackLabel(label) {
		return false, fmt.Errorf("invalid Fairy feedback metadata")
	}
	if at.IsZero() {
		at = time.Now()
	}
	if err := s.pruneIfDue(ctx, at); err != nil {
		return false, err
	}
	messageRef := s.feedbackMessageRef(messageID)
	actorRef := s.feedbackActorRef(messageRef, actorID)
	transaction, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return false, fmt.Errorf("begin Fairy feedback update: %w", err)
	}
	defer transaction.Rollback()
	var exists int
	err = transaction.QueryRowContext(ctx, `
SELECT 1 FROM fairy_feedback_outputs
WHERE message_ref = ? AND expires_at > ?`, messageRef, at.UnixMilli()).Scan(&exists)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, fmt.Errorf("find Fairy feedback output: %w", err)
	}
	var result sql.Result
	if removed {
		result, err = transaction.ExecContext(ctx, `
DELETE FROM fairy_feedback_ratings
WHERE message_ref = ? AND actor_ref = ? AND label = ?`, messageRef, actorRef, string(label))
	} else {
		result, err = transaction.ExecContext(ctx, `
INSERT INTO fairy_feedback_ratings(message_ref, actor_ref, label, rated_at)
VALUES (?, ?, ?, ?)
ON CONFLICT(message_ref, actor_ref) DO UPDATE SET
    label = excluded.label,
    rated_at = excluded.rated_at`, messageRef, actorRef, string(label), at.UnixMilli())
	}
	if err != nil {
		return false, fmt.Errorf("apply Fairy feedback: %w", err)
	}
	rows, err := result.RowsAffected()
	if err != nil {
		return false, fmt.Errorf("read Fairy feedback update result: %w", err)
	}
	if err := transaction.Commit(); err != nil {
		return false, fmt.Errorf("commit Fairy feedback update: %w", err)
	}
	return rows > 0, nil
}

func (s *SQLiteTraceStore) DeleteFeedbackOutput(ctx context.Context, messageID string) (bool, error) {
	if !validFeedbackSourceID(messageID, 1024) {
		return false, fmt.Errorf("invalid Fairy feedback output metadata")
	}
	result, err := s.db.ExecContext(ctx, `DELETE FROM fairy_feedback_outputs WHERE message_ref = ?`, s.feedbackMessageRef(messageID))
	if err != nil {
		return false, fmt.Errorf("delete Fairy feedback output: %w", err)
	}
	rows, err := result.RowsAffected()
	if err != nil {
		return false, fmt.Errorf("read Fairy feedback output deletion result: %w", err)
	}
	return rows > 0, nil
}

func (s *SQLiteTraceStore) FeedbackStats(ctx context.Context, since time.Time) (FeedbackRuntimeStats, error) {
	if since.IsZero() {
		since = time.Now().Add(-24 * time.Hour)
	}
	if err := s.pruneIfDue(ctx, time.Now()); err != nil {
		return FeedbackRuntimeStats{}, err
	}
	stats := FeedbackRuntimeStats{WindowHours: 24}
	var ratedOutputs, positive, negative sql.NullInt64
	err := s.db.QueryRowContext(ctx, `
SELECT COUNT(DISTINCT ratings.message_ref),
       SUM(CASE WHEN label = 'positive' THEN 1 ELSE 0 END),
       SUM(CASE WHEN label = 'negative' THEN 1 ELSE 0 END)
FROM fairy_feedback_ratings AS ratings
JOIN fairy_feedback_outputs AS outputs ON outputs.message_ref = ratings.message_ref
WHERE ratings.rated_at >= ? AND outputs.expires_at > ?`, since.UnixMilli(), time.Now().UnixMilli()).Scan(&ratedOutputs, &positive, &negative)
	if err != nil {
		return FeedbackRuntimeStats{}, fmt.Errorf("query Fairy feedback stats: %w", err)
	}
	stats.RatedOutputs = int(ratedOutputs.Int64)
	stats.Positive = int(positive.Int64)
	stats.Negative = int(negative.Int64)
	total := stats.Positive + stats.Negative
	if total > 0 {
		stats.PositiveRate = float64(stats.Positive) / float64(total)
	}
	return stats, nil
}

func (s *SQLiteTraceStore) feedbackMessageRef(messageID string) string {
	return s.feedbackRef(feedbackMessageRefDomain, messageID)
}

func (s *SQLiteTraceStore) feedbackActorRef(messageRef, actorID string) string {
	return s.feedbackRef(feedbackActorRefDomain, messageRef+"\x00"+actorID)
}

func (s *SQLiteTraceStore) feedbackRef(domain, value string) string {
	digest := hmac.New(sha256.New, s.key)
	_, _ = digest.Write([]byte(domain))
	_, _ = digest.Write([]byte{0})
	_, _ = digest.Write([]byte(value))
	return "hmac-sha256:" + hex.EncodeToString(digest.Sum(nil))
}

func validFeedbackSourceID(value string, maxBytes int) bool {
	return value != "" && len(value) <= maxBytes
}
