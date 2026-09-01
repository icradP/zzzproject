package fairy

import (
	"sync"
	"time"
)

type ChatMessage struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}

type contextEntry struct {
	messages  []ChatMessage
	updatedAt time.Time
}

// ContextStore keeps only explicitly triggered conversation turns in memory.
// Entries expire and are never serialized to the Fairy state file.
type ContextStore struct {
	mu          sync.Mutex
	ttl         time.Duration
	maxMessages int
	entries     map[string]contextEntry
}

func NewContextStore(ttl time.Duration, maxMessages int) *ContextStore {
	return &ContextStore{
		ttl:         ttl,
		maxMessages: maxMessages,
		entries:     make(map[string]contextEntry),
	}
}

func (s *ContextStore) Append(key string, now time.Time, messages ...ChatMessage) []ChatMessage {
	s.mu.Lock()
	defer s.mu.Unlock()
	entry := s.entries[key]
	if entry.updatedAt.IsZero() || now.Sub(entry.updatedAt) > s.ttl {
		entry.messages = nil
	}
	entry.messages = append(entry.messages, messages...)
	if overflow := len(entry.messages) - s.maxMessages; overflow > 0 {
		entry.messages = append([]ChatMessage(nil), entry.messages[overflow:]...)
	}
	entry.updatedAt = now
	s.entries[key] = entry
	return append([]ChatMessage(nil), entry.messages...)
}

func (s *ContextStore) Clear(key string) {
	s.mu.Lock()
	delete(s.entries, key)
	s.mu.Unlock()
}

func (s *ContextStore) Prune(now time.Time) {
	s.mu.Lock()
	defer s.mu.Unlock()
	for key, entry := range s.entries {
		if now.Sub(entry.updatedAt) > s.ttl {
			delete(s.entries, key)
		}
	}
}
