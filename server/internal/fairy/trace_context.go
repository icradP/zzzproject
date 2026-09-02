package fairy

import "context"

type turnTraceContextKey struct{}

type TurnTraceScope struct {
	TraceID        string
	TurnID         string
	ConversationID string
	Source         string
}

func withTurnTraceScope(ctx context.Context, scope TurnTraceScope) context.Context {
	return context.WithValue(ctx, turnTraceContextKey{}, scope)
}

func turnTraceScopeFromContext(ctx context.Context) (TurnTraceScope, bool) {
	scope, ok := ctx.Value(turnTraceContextKey{}).(TurnTraceScope)
	return scope, ok
}
