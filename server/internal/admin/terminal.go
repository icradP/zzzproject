package admin

import (
	"math"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/icradp/zzz-im-server/internal/protocol"
	"github.com/icradp/zzz-im-server/internal/store"
)

const (
	defaultTerminalActivityLimit = 200
	maxTerminalActivityLimit     = 500
	maxTerminalCommandBytes      = 2048
	maxTerminalOutputBytes       = 16384
)

type terminalActivity struct {
	MessageID      string     `json:"message_id"`
	RequestID      string     `json:"request_id"`
	Kind           string     `json:"kind"`
	Timestamp      time.Time  `json:"timestamp"`
	SenderID       string     `json:"sender_id"`
	SenderNickname string     `json:"sender_nickname,omitempty"`
	ConversationID string     `json:"conversation_id"`
	Operation      string     `json:"operation,omitempty"`
	HostID         string     `json:"host_id,omitempty"`
	Command        string     `json:"command,omitempty"`
	Summary        string     `json:"summary,omitempty"`
	Status         string     `json:"status,omitempty"`
	Output         string     `json:"output,omitempty"`
	ExitCode       *int64     `json:"exit_code,omitempty"`
	ExpiresAt      *time.Time `json:"expires_at,omitempty"`
}

type terminalVaultSummary struct {
	UserID       string    `json:"user_id"`
	Nickname     string    `json:"nickname,omitempty"`
	Revision     int64     `json:"revision"`
	PayloadBytes int       `json:"payload_bytes"`
	UpdatedAt    time.Time `json:"updated_at"`
}

type terminalOverview struct {
	Requests         int `json:"requests"`
	Results          int `json:"results"`
	Pending          int `json:"pending"`
	Completed        int `json:"completed"`
	Approved         int `json:"approved"`
	Denied           int `json:"denied"`
	Failed           int `json:"failed"`
	Expired          int `json:"expired"`
	VaultsConfigured int `json:"vaults_configured"`
}

func (s *Server) handleTerminal(w http.ResponseWriter, r *http.Request) {
	limit := defaultTerminalActivityLimit
	if raw := strings.TrimSpace(r.URL.Query().Get("limit")); raw != "" {
		if parsed, err := parseAdminLimit(raw, maxTerminalActivityLimit); err == nil {
			limit = parsed
		} else {
			s.writeError(w, http.StatusBadRequest, "limit must be between 1 and 500")
			return
		}
	}
	messages, err := s.store.GetRecentMessages(limit)
	if err != nil {
		s.writeError(w, http.StatusInternalServerError, "could not load terminal activity")
		return
	}
	activities := make([]terminalActivity, 0)
	requests := make(map[string]*terminalActivity)
	results := make(map[string]terminalActivity)
	for _, message := range messages {
		if message == nil {
			continue
		}
		textSummary := terminalTextSummary(message.Segments)
		for _, segment := range message.Segments {
			if segment.Type != "terminal_request" && segment.Type != "terminal_result" {
				continue
			}
			activity, ok := terminalActivityFromSegment(message, segment, textSummary)
			if !ok {
				continue
			}
			activities = append(activities, activity)
			if activity.Kind == "request" {
				if _, exists := requests[activity.RequestID]; !exists {
					copy := activity
					requests[activity.RequestID] = &copy
				}
			} else {
				if _, exists := results[activity.RequestID]; !exists {
					results[activity.RequestID] = activity
				}
			}
		}
	}
	for index := range activities {
		activity := &activities[index]
		if activity.Kind == "request" {
			if result, ok := results[activity.RequestID]; ok {
				activity.Status = result.Status
			}
			continue
		}
		if request, ok := requests[activity.RequestID]; ok {
			activity.Operation = request.Operation
			activity.HostID = request.HostID
			activity.Command = request.Command
		}
	}
	now := time.Now()
	overview := terminalOverview{Requests: len(requests), Results: len(results)}
	for requestID, request := range requests {
		if result, ok := results[requestID]; ok {
			switch result.Status {
			case "completed":
				overview.Completed++
			case "approved":
				overview.Approved++
			case "denied":
				overview.Denied++
			case "failed":
				overview.Failed++
			case "expired":
				overview.Expired++
			}
			continue
		}
		if request.ExpiresAt != nil && request.ExpiresAt.Before(now) {
			overview.Expired++
		} else {
			overview.Pending++
		}
	}
	vaults := make([]terminalVaultSummary, 0)
	users, usersErr := s.store.GetUsers()
	if usersErr == nil {
		for _, user := range users {
			if user == nil {
				continue
			}
			vault, vaultErr := s.store.GetTerminalVault(user.ID)
			if vaultErr != nil || vault == nil {
				continue
			}
			vaults = append(vaults, terminalVaultSummary{
				UserID: user.ID, Nickname: user.Nickname, Revision: vault.Revision,
				PayloadBytes: len([]byte(vault.Payload)), UpdatedAt: vault.UpdatedAt,
			})
		}
	}
	overview.VaultsConfigured = len(vaults)
	sort.Slice(activities, func(i, j int) bool {
		return activities[i].Timestamp.After(activities[j].Timestamp)
	})
	sort.Slice(vaults, func(i, j int) bool { return vaults[i].UpdatedAt.After(vaults[j].UpdatedAt) })
	s.writeJSON(w, http.StatusOK, map[string]interface{}{
		"generated_at": time.Now(),
		"overview":     overview,
		"activities":   activities,
		"vaults":       vaults,
		"limits": map[string]int{
			"activity_limit": maxTerminalActivityLimit,
			"command_bytes":  maxTerminalCommandBytes,
			"output_bytes":   maxTerminalOutputBytes,
		},
	})
}

func parseAdminLimit(raw string, max int) (int, error) {
	value, err := strconv.Atoi(raw)
	if err != nil || value < 1 || value > max {
		return 0, strconv.ErrSyntax
	}
	return value, nil
}

func terminalActivityFromSegment(message *store.Message, segment protocol.MessageSegment, summary string) (terminalActivity, bool) {
	requestID := terminalString(segment.Data, "request_id")
	if requestID == "" || message.ID == "" {
		return terminalActivity{}, false
	}
	activity := terminalActivity{
		MessageID: message.ID, RequestID: requestID, Timestamp: message.Timestamp,
		SenderID: message.SenderID, SenderNickname: message.SenderNickname,
		ConversationID: message.ConversationID, Summary: summary,
	}
	if segment.Type == "terminal_request" {
		activity.Kind = "request"
		activity.Operation = terminalString(segment.Data, "operation")
		activity.HostID = terminalString(segment.Data, "host_id")
		activity.Command = truncateTerminal(terminalString(segment.Data, "command"), maxTerminalCommandBytes)
		if expiresAt, ok := terminalInt64(segment.Data, "expires_at"); ok && expiresAt > 0 {
			expires := time.UnixMilli(expiresAt)
			activity.ExpiresAt = &expires
		}
		return activity, activity.Operation != ""
	}
	activity.Kind = "result"
	activity.Status = terminalString(segment.Data, "status")
	activity.Output = truncateTerminal(terminalString(segment.Data, "output"), maxTerminalOutputBytes)
	if exitCode, ok := terminalInt64(segment.Data, "exit_code"); ok {
		activity.ExitCode = &exitCode
	}
	return activity, activity.Status != ""
}

func terminalTextSummary(segments []protocol.MessageSegment) string {
	parts := make([]string, 0, 1)
	for _, segment := range segments {
		if segment.Type != "text" {
			continue
		}
		if text := strings.TrimSpace(terminalString(segment.Data, "text")); text != "" {
			parts = append(parts, text)
		}
	}
	return truncateTerminal(strings.Join(parts, "\n"), maxTerminalOutputBytes)
}

func terminalString(data map[string]interface{}, key string) string {
	value, _ := data[key].(string)
	return strings.TrimSpace(value)
}

func terminalInt64(data map[string]interface{}, key string) (int64, bool) {
	switch value := data[key].(type) {
	case int:
		return int64(value), true
	case int64:
		return value, true
	case float64:
		if value < math.MinInt64 || value > math.MaxInt64 || value != math.Trunc(value) {
			return 0, false
		}
		return int64(value), true
	case float32:
		converted := float64(value)
		if converted < math.MinInt64 || converted > math.MaxInt64 || converted != math.Trunc(converted) {
			return 0, false
		}
		return int64(value), true
	default:
		return 0, false
	}
}

func truncateTerminal(value string, maxBytes int) string {
	if len([]byte(value)) <= maxBytes {
		return value
	}
	result := []rune(value)
	for len([]byte(string(result))) > maxBytes-3 && len(result) > 0 {
		result = result[:len(result)-1]
	}
	return string(result) + "..."
}
