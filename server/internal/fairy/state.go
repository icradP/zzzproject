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
	Version           int                   `json:"version"`
	Groups            map[string]groupState `json:"groups"`
	ContextDisabled   map[string]bool       `json:"context_disabled,omitempty"`
	FactMemoryEnabled map[string]bool       `json:"fact_memory_enabled,omitempty"`
	QuotaDate         string                `json:"quota_date,omitempty"`
	QuotaCalls        int                   `json:"quota_calls,omitempty"`
	TaskQuotaDates    map[string]string     `json:"task_quota_dates,omitempty"`
	TaskQuotaCalls    map[string]int        `json:"task_quota_calls,omitempty"`
}

type groupState struct {
	Enabled         bool          `json:"enabled"`
	SoftTriggerMode GroupSoftMode `json:"soft_trigger_mode,omitempty"`
}

// StateStore persists management switches and the daily model-call counter.
// Conversation content is deliberately never written to this file.
type StateStore struct {
	mu           sync.Mutex
	path         string
	groupDefault bool
	softDefault  GroupSoftMode
	state        persistedState
}

func OpenStateStore(path string, groupDefault bool) (*StateStore, error) {
	return OpenStateStoreWithDefaults(path, groupDefault, GroupSoftShadow)
}

func OpenStateStoreWithDefaults(path string, groupDefault bool, softDefault GroupSoftMode) (*StateStore, error) {
	if !validGroupSoftMode(softDefault) {
		return nil, fmt.Errorf("invalid Fairy group soft-trigger default %q", softDefault)
	}
	store := &StateStore{
		path:         path,
		groupDefault: groupDefault,
		softDefault:  softDefault,
		state: persistedState{
			Version:        1,
			Groups:         make(map[string]groupState),
			TaskQuotaDates: make(map[string]string),
			TaskQuotaCalls: make(map[string]int),
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
	if store.state.TaskQuotaDates == nil {
		store.state.TaskQuotaDates = make(map[string]string)
	}
	if store.state.TaskQuotaCalls == nil {
		store.state.TaskQuotaCalls = make(map[string]int)
	}
	for groupID, state := range store.state.Groups {
		if state.SoftTriggerMode != "" && !validGroupSoftMode(state.SoftTriggerMode) {
			return nil, fmt.Errorf("invalid Fairy group soft-trigger mode for %s", groupID)
		}
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
	next := previous
	next.Enabled = enabled
	s.state.Groups[groupID] = next
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

func (s *StateStore) GroupSoftMode(groupID string) GroupSoftMode {
	s.mu.Lock()
	defer s.mu.Unlock()
	state, exists := s.state.Groups[groupID]
	if !exists || state.SoftTriggerMode == "" {
		return s.softDefault
	}
	return state.SoftTriggerMode
}

func (s *StateStore) SetGroupSoftMode(groupID string, mode GroupSoftMode) error {
	if !validGroupSoftMode(mode) {
		return fmt.Errorf("invalid Fairy group soft-trigger mode %q", mode)
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	previous, existed := s.state.Groups[groupID]
	next := previous
	if !existed {
		next.Enabled = s.groupDefault
	}
	next.SoftTriggerMode = mode
	s.state.Groups[groupID] = next
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

func (s *StateStore) SetSoftDefault(mode GroupSoftMode) {
	if !validGroupSoftMode(mode) {
		return
	}
	s.mu.Lock()
	s.softDefault = mode
	s.mu.Unlock()
}

func (s *StateStore) ContextEnabled(conversationID string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return !s.state.ContextDisabled[conversationID]
}

func (s *StateStore) SetContextEnabled(conversationID string, enabled bool) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.state.ContextDisabled == nil {
		s.state.ContextDisabled = make(map[string]bool)
	}
	previous, existed := s.state.ContextDisabled[conversationID]
	if enabled {
		delete(s.state.ContextDisabled, conversationID)
	} else {
		s.state.ContextDisabled[conversationID] = true
	}
	if err := s.saveLocked(); err != nil {
		if existed {
			s.state.ContextDisabled[conversationID] = previous
		} else {
			delete(s.state.ContextDisabled, conversationID)
		}
		return err
	}
	return nil
}

func (s *StateStore) FactMemoryEnabled(scope FactScope) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.state.FactMemoryEnabled[factScopeStateKey(scope)]
}

func (s *StateStore) SetFactMemoryEnabled(scope FactScope, enabled bool) error {
	if err := validateFactScope(scope); err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.state.FactMemoryEnabled == nil {
		s.state.FactMemoryEnabled = make(map[string]bool)
	}
	key := factScopeStateKey(scope)
	previous, existed := s.state.FactMemoryEnabled[key]
	if enabled {
		s.state.FactMemoryEnabled[key] = true
	} else {
		delete(s.state.FactMemoryEnabled, key)
	}
	if err := s.saveLocked(); err != nil {
		if existed {
			s.state.FactMemoryEnabled[key] = previous
		} else {
			delete(s.state.FactMemoryEnabled, key)
		}
		return err
	}
	return nil
}

func (s *StateStore) FactMemoryEnabledScopeCount() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	count := 0
	for _, enabled := range s.state.FactMemoryEnabled {
		if enabled {
			count++
		}
	}
	return count
}

// ModelQuotaStatus reports the current UTC day's usage without reserving a call
// or changing the persisted counter.
func (s *StateStore) ModelQuotaStatus(now time.Time, limit int) (used, remaining int) {
	if limit <= 0 {
		return 0, 0
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.state.QuotaDate == now.UTC().Format("2006-01-02") {
		used = s.state.QuotaCalls
	}
	if used > limit {
		used = limit
	}
	return used, limit - used
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

// TaskModelQuotaStatus reports one task's current UTC-day usage.
func (s *StateStore) TaskModelQuotaStatus(now time.Time, taskID string, limit int) (used, remaining int) {
	if limit <= 0 {
		return 0, 0
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.state.TaskQuotaDates[taskID] == now.UTC().Format("2006-01-02") {
		used = s.state.TaskQuotaCalls[taskID]
	}
	if used > limit {
		used = limit
	}
	return used, limit - used
}

// TakeTaskModelCall atomically reserves one call from both the global and task
// UTC daily quotas. Neither counter changes when either quota is exhausted or
// persistence fails.
func (s *StateStore) TakeTaskModelCall(now time.Time, globalLimit int, taskID string, taskLimit int) (globalUsed, taskUsed int, allowed bool, err error) {
	if globalLimit <= 0 || taskLimit <= 0 {
		return 0, 0, false, nil
	}
	if !validTraceLabel(taskID) {
		return 0, 0, false, fmt.Errorf("invalid Fairy model task ID")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	date := now.UTC().Format("2006-01-02")
	if s.state.QuotaDate == date {
		globalUsed = s.state.QuotaCalls
	}
	if s.state.TaskQuotaDates[taskID] == date {
		taskUsed = s.state.TaskQuotaCalls[taskID]
	}
	if globalUsed >= globalLimit || taskUsed >= taskLimit {
		return globalUsed, taskUsed, false, nil
	}

	previousDate, previousCalls := s.state.QuotaDate, s.state.QuotaCalls
	previousTaskDate, taskDateExisted := s.state.TaskQuotaDates[taskID]
	previousTaskCalls, taskCallsExisted := s.state.TaskQuotaCalls[taskID]
	s.state.QuotaDate, s.state.QuotaCalls = date, globalUsed+1
	s.state.TaskQuotaDates[taskID], s.state.TaskQuotaCalls[taskID] = date, taskUsed+1
	if err := s.saveLocked(); err != nil {
		s.state.QuotaDate, s.state.QuotaCalls = previousDate, previousCalls
		if taskDateExisted {
			s.state.TaskQuotaDates[taskID] = previousTaskDate
		} else {
			delete(s.state.TaskQuotaDates, taskID)
		}
		if taskCallsExisted {
			s.state.TaskQuotaCalls[taskID] = previousTaskCalls
		} else {
			delete(s.state.TaskQuotaCalls, taskID)
		}
		return globalUsed, taskUsed, false, err
	}
	return globalUsed + 1, taskUsed + 1, true, nil
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
