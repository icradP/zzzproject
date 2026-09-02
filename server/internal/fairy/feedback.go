package fairy

import (
	"context"
	"time"
)

const (
	FairyPositiveReactionID = "76"
	FairyNegativeReactionID = "fairy-negative"
)

type FeedbackLabel string

const (
	FeedbackPositive FeedbackLabel = "positive"
	FeedbackNegative FeedbackLabel = "negative"
)

type FeedbackRuntimeStats struct {
	WindowHours  int     `json:"window_hours"`
	RatedOutputs int     `json:"rated_outputs"`
	Positive     int     `json:"positive"`
	Negative     int     `json:"negative"`
	PositiveRate float64 `json:"positive_rate"`
}

type FeedbackOutputRecorder interface {
	RegisterFeedbackOutput(ctx context.Context, messageID, turnID string, at time.Time) error
}

type FeedbackStore interface {
	FeedbackOutputRecorder
	ApplyFeedback(ctx context.Context, messageID, actorID string, label FeedbackLabel, removed bool, at time.Time) (bool, error)
	DeleteFeedbackOutput(ctx context.Context, messageID string) (bool, error)
	FeedbackStats(ctx context.Context, since time.Time) (FeedbackRuntimeStats, error)
}

type FeedbackStatsReader interface {
	FeedbackStats(ctx context.Context, since time.Time) (FeedbackRuntimeStats, error)
}

type feedbackEligibleContextKey struct{}

func withFeedbackEligible(ctx context.Context) context.Context {
	return context.WithValue(ctx, feedbackEligibleContextKey{}, true)
}

func feedbackTurnIDFromContext(ctx context.Context) (string, bool) {
	eligible, _ := ctx.Value(feedbackEligibleContextKey{}).(bool)
	if !eligible {
		return "", false
	}
	scope, ok := turnTraceScopeFromContext(ctx)
	if !ok || !validRuntimeID(scope.TurnID) {
		return "", false
	}
	return scope.TurnID, true
}

func feedbackLabelForReaction(emojiID string) (FeedbackLabel, bool) {
	switch emojiID {
	case FairyPositiveReactionID:
		return FeedbackPositive, true
	case FairyNegativeReactionID:
		return FeedbackNegative, true
	default:
		return "", false
	}
}

func validFeedbackLabel(label FeedbackLabel) bool {
	return label == FeedbackPositive || label == FeedbackNegative
}
