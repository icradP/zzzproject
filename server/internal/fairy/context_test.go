package fairy

import (
	"strings"
	"testing"
	"time"
)

func TestContextStoreCompactsOverflowWithSourceMetadata(t *testing.T) {
	store := NewContextStore(time.Hour, 4)
	now := time.Date(2026, 9, 2, 10, 0, 0, 0, time.UTC)
	for index, content := range []string{"one", "two", "three", "four", "five", "six"} {
		store.Append("conversation", now.Add(time.Duration(index)*time.Second), ChatMessage{
			Role: "user", Content: content, SourceID: "message_" + content, SourceTimeMS: now.UnixMilli(),
		})
	}
	messages := store.Snapshot("conversation", now.Add(time.Minute))
	if len(messages) != 4 {
		t.Fatalf("context length = %d, want 4", len(messages))
	}
	summary := messages[0]
	if summary.Role != "user" || !strings.HasPrefix(summary.Content, memorySummaryPrefix) {
		t.Fatalf("summary = %#v", summary)
	}
	if summary.SourceID != "message_one" || summary.SourceEndID != "message_three" || summary.SourceCount != 3 {
		t.Fatalf("summary source metadata = %#v", summary)
	}
	if messages[1].Content != "four" || messages[3].Content != "six" {
		t.Fatalf("recent context changed: %#v", messages)
	}
	if len([]rune(summary.Content)) > maxMemorySummaryRunes {
		t.Fatal("summary exceeded its rune limit")
	}
}

func TestContextSummaryRemainsOneMessageAcrossCompactions(t *testing.T) {
	store := NewContextStore(time.Hour, 3)
	now := time.Now()
	for index := 0; index < 20; index++ {
		store.Append("conversation", now.Add(time.Duration(index)*time.Second), ChatMessage{
			Role: "user", Content: strings.Repeat("content ", 80), SourceID: "source", SourceCount: 1,
		})
	}
	messages := store.Snapshot("conversation", now.Add(time.Minute))
	if len(messages) != 3 || strings.Count(messages[0].Content, memorySummaryPrefix) != 1 || messages[0].SourceCount != 18 {
		t.Fatalf("rolling summary = %#v", messages)
	}
}
