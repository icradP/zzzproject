package fairy

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"time"
)

type persistedState struct {
	Version    int                   `json:"version"`
	Groups     map[string]groupState `json:"groups"`
	QuotaDate  string                `json:"quota_date,omitempty"`
	QuotaCalls int                   `json:"quota_calls,omitempty"`
}

type groupState struct {
	Enabled bool `json:"enabled"`
}

// StateStore persists management switches and the daily model-call counter.
// Conversation content is deliberately never written to this file.
type StateStore struct {
	mu           sync.Mutex
	path         string
	groupDefault bool
	state        persistedState
}

func OpenStateStore(path string, groupDefault bool) (*StateStore, error) {
	store := &StateStore{
		path:         path,
		groupDefault: groupDefault,
		state: persistedState{
			Version: 1,
			Groups:  make(map[string]groupState),
		},
	}
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return store, nil
	}
	if err != nil {
		return nil, fmt.Errorf("read Fairy state: %w", err)
	}
	if err := json.Unmarshal(data, &store.state); err != nil {
		return nil, fmt.Errorf("decode Fairy state: %w", err)
	}
	if store.state.Version != 1 {
		return nil, fmt.Errorf("unsupported Fairy state version %d", store.state.Version)
	}
	if store.state.Groups == nil {
		store.state.Groups = make(map[string]groupState)
	}
	return store, nil
}

func (s *StateStore) GroupEnabled(groupID string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	state, exists := s.state.Groups[groupID]
	if !exists {
		return s.groupDefault
	}
	return state.Enabled
}

func (s *StateStore) SetGroupEnabled(groupID string, enabled bool) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	previous, existed := s.state.Groups[groupID]
	s.state.Groups[groupID] = groupState{Enabled: enabled}
	if err := s.saveLocked(); err != nil {
		if existed {
			s.state.Groups[groupID] = previous
		} else {
			delete(s.state.Groups, groupID)
		}
		return err
	}
	return nil
}

// TakeModelCall atomically reserves one call from the UTC daily quota.
func (s *StateStore) TakeModelCall(now time.Time, limit int) (used int, allowed bool, err error) {
	if limit <= 0 {
		return 0, false, nil
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	previousDate := s.state.QuotaDate
	previousCalls := s.state.QuotaCalls
	date := now.UTC().Format("2006-01-02")
	if s.state.QuotaDate != date {
		s.state.QuotaDate = date
		s.state.QuotaCalls = 0
	}
	if s.state.QuotaCalls >= limit {
		return s.state.QuotaCalls, false, nil
	}
	s.state.QuotaCalls++
	if err := s.saveLocked(); err != nil {
		s.state.QuotaDate = previousDate
		s.state.QuotaCalls = previousCalls
		return previousCalls, false, err
	}
	return s.state.QuotaCalls, true, nil
}

func (s *StateStore) saveLocked() error {
	directory := filepath.Dir(s.path)
	if err := os.MkdirAll(directory, 0o750); err != nil {
		return fmt.Errorf("create Fairy state directory: %w", err)
	}
	data, err := json.MarshalIndent(s.state, "", "  ")
	if err != nil {
		return fmt.Errorf("encode Fairy state: %w", err)
	}
	temporary, err := os.CreateTemp(directory, ".fairy-state-*")
	if err != nil {
		return fmt.Errorf("create temporary Fairy state: %w", err)
	}
	temporaryName := temporary.Name()
	cleanup := func() {
		_ = temporary.Close()
		_ = os.Remove(temporaryName)
	}
	if err := temporary.Chmod(0o600); err != nil {
		cleanup()
		return err
	}
	if _, err := temporary.Write(append(data, '\n')); err != nil {
		cleanup()
		return err
	}
	if err := temporary.Sync(); err != nil {
		cleanup()
		return err
	}
	if err := temporary.Close(); err != nil {
		_ = os.Remove(temporaryName)
		return err
	}
	if err := os.Rename(temporaryName, s.path); err != nil {
		_ = os.Remove(temporaryName)
		return fmt.Errorf("replace Fairy state: %w", err)
	}
	return nil
}
