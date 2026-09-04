package admin

import (
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"embed"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net"
	"net/http"
	"runtime"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/icradp/zzz-im-server/internal/clientperf"
	"github.com/icradp/zzz-im-server/internal/store"
	"golang.org/x/crypto/bcrypt"
)

const (
	adminCookieName = "zzz_admin_session"
	adminSessionTTL = 12 * time.Hour
	loginWindow     = 10 * time.Minute
	loginBlockTime  = 15 * time.Minute
	maxLoginFailure = 5
)

//go:embed assets/*
var assetFiles embed.FS

// RegistrationController updates the gateway registration policy without
// exposing the configured invitation code.
type RegistrationController interface {
	RegistrationEnabled() bool
	SetInviteCode(string)
}

// MediaController removes uploaded bytes together with their metadata.
type MediaController interface {
	Delete(string) (bool, error)
}

// PerformanceController exposes anonymous, aggregate PWA startup metrics.
type PerformanceController interface {
	Snapshot() clientperf.Snapshot
}

// Config defines the dependencies and non-secret metadata for the console.
type Config struct {
	Store         store.Store
	Media         MediaController
	Registration  RegistrationController
	Performance   PerformanceController
	Fairy         FairyController
	AdminToken    string
	PublicPath    string
	StorageDriver string
	PushEnabled   bool
	StartedAt     time.Time
}

type loginState struct {
	WindowStarted time.Time
	Failures      int
	BlockedUntil  time.Time
}

// Server serves the authenticated JSON API and embedded admin application.
type Server struct {
	store            store.Store
	media            MediaController
	registration     RegistrationController
	performance      PerformanceController
	fairy            FairyController
	adminTokenDigest [sha256.Size]byte
	publicPath       string
	storageDriver    string
	pushEnabled      bool
	startedAt        time.Time

	mu            sync.Mutex
	sessions      map[[sha256.Size]byte]time.Time
	loginAttempts map[string]loginState
}

// New creates an admin server. Callers should only mount it when AdminToken is
// non-empty.
func New(config Config) *Server {
	publicPath := strings.TrimSpace(config.PublicPath)
	if !strings.HasPrefix(publicPath, "/") {
		publicPath = "/admin"
	}
	if publicPath != "/" {
		publicPath = strings.TrimRight(publicPath, "/")
	}
	startedAt := config.StartedAt
	if startedAt.IsZero() {
		startedAt = time.Now()
	}
	return &Server{
		store:            config.Store,
		media:            config.Media,
		registration:     config.Registration,
		performance:      config.Performance,
		fairy:            config.Fairy,
		adminTokenDigest: sha256.Sum256([]byte(strings.TrimSpace(config.AdminToken))),
		publicPath:       publicPath,
		storageDriver:    config.StorageDriver,
		pushEnabled:      config.PushEnabled,
		startedAt:        startedAt,
		sessions:         make(map[[sha256.Size]byte]time.Time),
		loginAttempts:    make(map[string]loginState),
	}
}

func (s *Server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	s.setSecurityHeaders(w)
	if strings.HasPrefix(r.URL.Path, "/admin/api/") {
		s.serveAPI(w, r)
		return
	}
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		w.Header().Set("Allow", http.MethodGet+", "+http.MethodHead)
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	asset := ""
	switch r.URL.Path {
	case "/admin/", "/admin/index.html":
		asset = "assets/index.html"
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
	case "/admin/assets/app.css":
		asset = "assets/app.css"
		w.Header().Set("Content-Type", "text/css; charset=utf-8")
	case "/admin/assets/app.js":
		asset = "assets/app.js"
		w.Header().Set("Content-Type", "application/javascript; charset=utf-8")
	default:
		http.NotFound(w, r)
		return
	}
	content, err := assetFiles.ReadFile(asset)
	if err != nil {
		http.Error(w, "admin asset unavailable", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Cache-Control", "no-cache")
	w.WriteHeader(http.StatusOK)
	if r.Method == http.MethodGet {
		_, _ = w.Write(content)
	}
}

func (s *Server) serveAPI(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	path := strings.TrimPrefix(r.URL.Path, "/admin/api")
	if path == "/session" && r.Method == http.MethodPost {
		s.handleLogin(w, r)
		return
	}
	if !s.authorized(r) {
		s.writeError(w, http.StatusUnauthorized, "admin authentication required")
		return
	}

	if r.Method == http.MethodPatch || r.Method == http.MethodDelete || r.Method == http.MethodPost {
		if r.Header.Get("X-ZZZ-Admin") != "1" {
			s.writeError(w, http.StatusForbidden, "missing admin request header")
			return
		}
	}

	switch {
	case path == "/session" && r.Method == http.MethodGet:
		s.writeJSON(w, http.StatusOK, map[string]interface{}{"authenticated": true})
	case path == "/session" && r.Method == http.MethodDelete:
		s.handleLogout(w, r)
	case path == "/overview" && r.Method == http.MethodGet:
		s.handleOverview(w)
	case path == "/users" && r.Method == http.MethodGet:
		s.handleUsers(w)
	case path == "/users" && r.Method == http.MethodPatch:
		s.handleUpdateUser(w, r)
	case path == "/users/password" && r.Method == http.MethodPatch:
		s.handleResetPassword(w, r)
	case path == "/titles" && r.Method == http.MethodGet:
		s.handleTitles(w, r)
	case path == "/titles" && r.Method == http.MethodPost:
		s.handleGrantTitle(w, r)
	case path == "/titles" && r.Method == http.MethodDelete:
		s.handleRevokeTitle(w, r)
	case path == "/reports" && r.Method == http.MethodGet:
		s.handleReports(w)
	case path == "/groups" && r.Method == http.MethodGet:
		s.handleGroups(w)
	case path == "/groups" && r.Method == http.MethodDelete:
		s.handleDeleteGroup(w, r)
	case path == "/conversations" && r.Method == http.MethodGet:
		s.handleConversations(w)
	case path == "/conversations" && r.Method == http.MethodDelete:
		s.handleDeleteConversation(w, r)
	case path == "/messages" && r.Method == http.MethodGet:
		s.handleMessages(w)
	case path == "/messages" && r.Method == http.MethodDelete:
		s.handleDeleteMessage(w, r)
	case path == "/media" && r.Method == http.MethodGet:
		s.handleMedia(w)
	case path == "/media" && r.Method == http.MethodDelete:
		s.handleDeleteMedia(w, r)
	case path == "/terminal" && r.Method == http.MethodGet:
		s.handleTerminal(w, r)
	case path == "/settings/registration" && r.Method == http.MethodGet:
		s.handleRegistrationSettings(w)
	case path == "/settings/registration" && r.Method == http.MethodPatch:
		s.handleUpdateRegistration(w, r)
	case path == "/fairy/config" && (r.Method == http.MethodGet || r.Method == http.MethodPatch):
		s.handleFairy(w, r, "config")
	case path == "/fairy/model-probe" && r.Method == http.MethodPost:
		s.handleFairy(w, r, "model-probe")
	case path == "/fairy/model-eval" && (r.Method == http.MethodGet || r.Method == http.MethodPost):
		s.handleFairy(w, r, "model-eval")
	case path == "/fairy/agent-diagnostic" && r.Method == http.MethodPost:
		s.handleFairy(w, r, "agent-diagnostic")
	case path == "/fairy/decision-chains" && r.Method == http.MethodGet:
		s.handleFairy(w, r, "decision-chains")
	default:
		w.Header().Set("Allow", s.allowedMethods(path))
		s.writeError(w, http.StatusNotFound, "admin endpoint not found")
	}
}

func (s *Server) handleLogin(w http.ResponseWriter, r *http.Request) {
	ip := clientIP(r)
	if retryAfter, blocked := s.loginBlocked(ip); blocked {
		w.Header().Set("Retry-After", fmt.Sprintf("%d", int(retryAfter.Seconds())+1))
		s.writeError(w, http.StatusTooManyRequests, "too many login attempts")
		return
	}
	var body struct {
		Token string `json:"token"`
	}
	if err := decodeJSON(w, r, &body); err != nil {
		s.writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	provided := sha256.Sum256([]byte(strings.TrimSpace(body.Token)))
	if subtle.ConstantTimeCompare(provided[:], s.adminTokenDigest[:]) != 1 {
		s.recordLoginFailure(ip)
		time.Sleep(150 * time.Millisecond)
		s.writeError(w, http.StatusUnauthorized, "invalid admin token")
		return
	}

	s.clearLoginFailures(ip)
	raw, digest, err := newSessionToken()
	if err != nil {
		s.writeError(w, http.StatusInternalServerError, "could not start admin session")
		return
	}
	expiresAt := time.Now().Add(adminSessionTTL)
	s.mu.Lock()
	s.sessions[digest] = expiresAt
	s.pruneSessionsLocked(time.Now())
	s.mu.Unlock()
	http.SetCookie(w, s.sessionCookie(r, raw, expiresAt, int(adminSessionTTL.Seconds())))
	s.writeJSON(w, http.StatusOK, map[string]interface{}{"authenticated": true, "expires_at": expiresAt})
}

func (s *Server) handleLogout(w http.ResponseWriter, r *http.Request) {
	if cookie, err := r.Cookie(adminCookieName); err == nil {
		digest := sha256.Sum256([]byte(cookie.Value))
		s.mu.Lock()
		delete(s.sessions, digest)
		s.mu.Unlock()
	}
	http.SetCookie(w, s.sessionCookie(r, "", time.Unix(1, 0), -1))
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleOverview(w http.ResponseWriter) {
	stats, err := s.store.GetServerStats()
	if err != nil {
		log.Printf("[admin] stats failed: %v", err)
		s.writeError(w, http.StatusInternalServerError, "could not load server statistics")
		return
	}
	performance := clientperf.Snapshot{}
	if s.performance != nil {
		performance = s.performance.Snapshot()
	}
	s.writeJSON(w, http.StatusOK, map[string]interface{}{
		"stats":       stats,
		"performance": performance,
		"service": map[string]interface{}{
			"storage_driver":       s.storageDriver,
			"push_enabled":         s.pushEnabled,
			"registration_enabled": s.registration.RegistrationEnabled(),
			"started_at":           s.startedAt,
			"uptime_seconds":       int64(time.Since(s.startedAt).Seconds()),
			"go_version":           runtime.Version(),
		},
		"generated_at": time.Now(),
	})
}

func (s *Server) handleUsers(w http.ResponseWriter) {
	users, err := s.store.GetUsers()
	if err != nil {
		log.Printf("[admin] users failed: %v", err)
		s.writeError(w, http.StatusInternalServerError, "could not load users")
		return
	}
	sort.Slice(users, func(i, j int) bool {
		if users[i].Online != users[j].Online {
			return users[i].Online
		}
		return users[i].CreatedAt.After(users[j].CreatedAt)
	})
	s.writeJSON(w, http.StatusOK, map[string]interface{}{"users": users})
}

func (s *Server) handleUpdateUser(w http.ResponseWriter, r *http.Request) {
	var body struct {
		UserID   string `json:"user_id"`
		Nickname string `json:"nickname"`
	}
	if err := decodeJSON(w, r, &body); err != nil {
		s.writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	body.UserID = strings.TrimSpace(body.UserID)
	body.Nickname = strings.TrimSpace(body.Nickname)
	if body.UserID == "" || body.Nickname == "" || len(body.Nickname) > 64 {
		s.writeError(w, http.StatusBadRequest, "user_id and a 1-64 character nickname are required")
		return
	}
	user, err := s.store.GetUser(body.UserID)
	if err != nil || user == nil {
		s.writeError(w, http.StatusNotFound, "user not found")
		return
	}
	user.Nickname = body.Nickname
	if err := s.store.SetUser(user); err != nil {
		log.Printf("[admin] user update failed: %v", err)
		s.writeError(w, http.StatusInternalServerError, "could not update user")
		return
	}
	s.writeJSON(w, http.StatusOK, map[string]interface{}{"user": user})
}

func (s *Server) handleResetPassword(w http.ResponseWriter, r *http.Request) {
	var body struct {
		UserID         string `json:"user_id"`
		Password       string `json:"password"`
		RevokeSessions *bool  `json:"revoke_sessions"`
	}
	if err := decodeJSON(w, r, &body); err != nil {
		s.writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	body.UserID = strings.TrimSpace(body.UserID)
	if body.UserID == "" || len(body.Password) < 8 || len(body.Password) > 72 {
		s.writeError(w, http.StatusBadRequest, "user_id and an 8-72 character password are required")
		return
	}
	user, err := s.store.GetUser(body.UserID)
	if err != nil || user == nil {
		s.writeError(w, http.StatusNotFound, "user not found")
		return
	}
	passwordHash, err := bcrypt.GenerateFromPassword([]byte(body.Password), bcrypt.DefaultCost)
	if err != nil {
		s.writeError(w, http.StatusBadRequest, "password could not be secured")
		return
	}
	originalHash := user.PasswordHash
	user.PasswordHash = string(passwordHash)
	if err := s.store.SetUser(user); err != nil {
		log.Printf("[admin] password reset failed: %v", err)
		s.writeError(w, http.StatusInternalServerError, "could not reset password")
		return
	}
	revokeSessions := body.RevokeSessions == nil || *body.RevokeSessions
	if revokeSessions {
		if err := s.store.DeleteSessionsForUser(user.ID); err != nil {
			user.PasswordHash = originalHash
			_ = s.store.SetUser(user)
			log.Printf("[admin] session revocation failed: %v", err)
			s.writeError(w, http.StatusInternalServerError, "could not revoke account sessions")
			return
		}
	}
	s.writeJSON(w, http.StatusOK, map[string]interface{}{
		"user_id": user.ID, "sessions_revoked": revokeSessions,
	})
}

func (s *Server) handleTitles(w http.ResponseWriter, r *http.Request) {
	userID := strings.TrimSpace(r.URL.Query().Get("user_id"))
	if userID == "" {
		s.writeError(w, http.StatusBadRequest, "user_id is required")
		return
	}
	if user, _ := s.store.GetUser(userID); user == nil {
		s.writeError(w, http.StatusNotFound, "user not found")
		return
	}
	titles, err := s.store.GetUserTitles(userID, "")
	if err != nil {
		s.writeError(w, http.StatusInternalServerError, "could not load titles")
		return
	}
	s.writeJSON(w, http.StatusOK, map[string]interface{}{"titles": titles})
}

func (s *Server) handleGrantTitle(w http.ResponseWriter, r *http.Request) {
	var body struct {
		UserID    string `json:"user_id"`
		Text      string `json:"text"`
		Style     string `json:"style"`
		ExpiresAt string `json:"expires_at"`
	}
	if err := decodeJSON(w, r, &body); err != nil {
		s.writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	body.UserID = strings.TrimSpace(body.UserID)
	body.Text = strings.TrimSpace(body.Text)
	body.Style = strings.TrimSpace(body.Style)
	styles := map[string]bool{"gold": true, "red": true, "yellow": true, "aurora": true, "ember": true}
	if body.UserID == "" || len([]rune(body.Text)) == 0 || len([]rune(body.Text)) > 24 || !styles[body.Style] {
		s.writeError(w, http.StatusBadRequest, "user_id, a 1-24 character title, and a supported style are required")
		return
	}
	if user, _ := s.store.GetUser(body.UserID); user == nil {
		s.writeError(w, http.StatusNotFound, "user not found")
		return
	}
	var expiresAt *time.Time
	if strings.TrimSpace(body.ExpiresAt) != "" {
		parsed, err := time.Parse(time.RFC3339, body.ExpiresAt)
		if err != nil || !parsed.After(time.Now()) {
			s.writeError(w, http.StatusBadRequest, "expires_at must be a future RFC3339 time")
			return
		}
		expiresAt = &parsed
	}
	title := &store.UserTitle{
		ID: fmt.Sprintf("title_%d", time.Now().UnixNano()), UserID: body.UserID,
		ScopeType: "system", Text: body.Text, Style: body.Style,
		GrantedBy: "system-admin", ExpiresAt: expiresAt, CreatedAt: time.Now(),
	}
	if err := s.store.GrantUserTitle(title); err != nil {
		if errors.Is(err, store.ErrActiveTitleLimit) {
			s.writeError(w, http.StatusConflict, err.Error())
			return
		}
		log.Printf("[admin] title grant failed: %v", err)
		s.writeError(w, http.StatusInternalServerError, "could not grant title")
		return
	}
	s.writeJSON(w, http.StatusCreated, map[string]interface{}{"title": title})
}

func (s *Server) handleRevokeTitle(w http.ResponseWriter, r *http.Request) {
	var body struct {
		TitleID string `json:"title_id"`
	}
	if err := decodeJSON(w, r, &body); err != nil {
		s.writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	deleted, err := s.store.DeleteUserTitle(strings.TrimSpace(body.TitleID))
	if err != nil {
		s.writeError(w, http.StatusInternalServerError, "could not revoke title")
		return
	}
	if !deleted {
		s.writeError(w, http.StatusNotFound, "title not found")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleReports(w http.ResponseWriter) {
	reports, err := s.store.GetUserReports(500)
	if err != nil {
		s.writeError(w, http.StatusInternalServerError, "could not load reports")
		return
	}
	s.writeJSON(w, http.StatusOK, map[string]interface{}{"reports": reports})
}

func (s *Server) handleGroups(w http.ResponseWriter) {
	groups, err := s.store.GetGroups()
	if err != nil {
		log.Printf("[admin] groups failed: %v", err)
		s.writeError(w, http.StatusInternalServerError, "could not load groups")
		return
	}
	sort.Slice(groups, func(i, j int) bool { return groups[i].CreatedAt.After(groups[j].CreatedAt) })
	s.writeJSON(w, http.StatusOK, map[string]interface{}{"groups": groups})
}

func (s *Server) handleDeleteGroup(w http.ResponseWriter, r *http.Request) {
	var body struct {
		GroupID string `json:"group_id"`
	}
	if err := decodeJSON(w, r, &body); err != nil {
		s.writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	group, err := s.store.GetGroup(strings.TrimSpace(body.GroupID))
	if err != nil || group == nil {
		s.writeError(w, http.StatusNotFound, "group not found")
		return
	}
	if err := s.store.DeleteGroup(group.ID); err != nil {
		log.Printf("[admin] group deletion failed: %v", err)
		s.writeError(w, http.StatusInternalServerError, "could not delete group")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleConversations(w http.ResponseWriter) {
	conversations, err := s.store.GetConversations()
	if err != nil {
		log.Printf("[admin] conversations failed: %v", err)
		s.writeError(w, http.StatusInternalServerError, "could not load conversations")
		return
	}
	sort.Slice(conversations, func(i, j int) bool {
		return conversations[i].CreatedAt.After(conversations[j].CreatedAt)
	})
	s.writeJSON(w, http.StatusOK, map[string]interface{}{"conversations": conversations})
}

func (s *Server) handleDeleteConversation(w http.ResponseWriter, r *http.Request) {
	var body struct {
		ConversationID string `json:"conversation_id"`
	}
	if err := decodeJSON(w, r, &body); err != nil {
		s.writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	conversation, err := s.store.GetConversation(strings.TrimSpace(body.ConversationID))
	if err != nil || conversation == nil {
		s.writeError(w, http.StatusNotFound, "conversation not found")
		return
	}
	if conversation.Type == "group" {
		s.writeError(w, http.StatusConflict, "delete group conversations from the groups page")
		return
	}
	if err := s.store.DeleteConversation(conversation.ID); err != nil {
		log.Printf("[admin] conversation deletion failed: %v", err)
		s.writeError(w, http.StatusInternalServerError, "could not delete conversation")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleMessages(w http.ResponseWriter) {
	messages, err := s.store.GetRecentMessages(500)
	if err != nil {
		log.Printf("[admin] messages failed: %v", err)
		s.writeError(w, http.StatusInternalServerError, "could not load messages")
		return
	}
	s.writeJSON(w, http.StatusOK, map[string]interface{}{"messages": messages})
}

func (s *Server) handleDeleteMessage(w http.ResponseWriter, r *http.Request) {
	var body struct {
		MessageID string `json:"message_id"`
	}
	if err := decodeJSON(w, r, &body); err != nil {
		s.writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	body.MessageID = strings.TrimSpace(body.MessageID)
	if body.MessageID == "" {
		s.writeError(w, http.StatusBadRequest, "message_id is required")
		return
	}
	deleted, err := s.store.DeleteMessage(body.MessageID)
	if err != nil {
		log.Printf("[admin] message deletion failed: %v", err)
		s.writeError(w, http.StatusInternalServerError, "could not delete message")
		return
	}
	if !deleted {
		s.writeError(w, http.StatusNotFound, "message not found")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleMedia(w http.ResponseWriter) {
	files, err := s.store.GetMediaFiles(500)
	if err != nil {
		log.Printf("[admin] media failed: %v", err)
		s.writeError(w, http.StatusInternalServerError, "could not load media")
		return
	}
	s.writeJSON(w, http.StatusOK, map[string]interface{}{"media": files})
}

func (s *Server) handleDeleteMedia(w http.ResponseWriter, r *http.Request) {
	var body struct {
		MediaID string `json:"media_id"`
	}
	if err := decodeJSON(w, r, &body); err != nil {
		s.writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	body.MediaID = strings.TrimSpace(body.MediaID)
	if body.MediaID == "" {
		s.writeError(w, http.StatusBadRequest, "media_id is required")
		return
	}
	if s.media == nil {
		s.writeError(w, http.StatusServiceUnavailable, "media deletion is unavailable")
		return
	}
	deleted, err := s.media.Delete(body.MediaID)
	if err != nil {
		log.Printf("[admin] media deletion failed: %v", err)
		s.writeError(w, http.StatusInternalServerError, "could not delete media")
		return
	}
	if !deleted {
		s.writeError(w, http.StatusNotFound, "media not found")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleRegistrationSettings(w http.ResponseWriter) {
	s.writeJSON(w, http.StatusOK, map[string]interface{}{
		"enabled":      s.registration.RegistrationEnabled(),
		"runtime_only": true,
	})
}

func (s *Server) handleUpdateRegistration(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Enabled    bool   `json:"enabled"`
		InviteCode string `json:"invite_code"`
	}
	if err := decodeJSON(w, r, &body); err != nil {
		s.writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	body.InviteCode = strings.TrimSpace(body.InviteCode)
	if !body.Enabled {
		s.registration.SetInviteCode("")
	} else if body.InviteCode != "" {
		if len(body.InviteCode) < 4 || len(body.InviteCode) > 128 {
			s.writeError(w, http.StatusBadRequest, "invite code must be 4-128 characters")
			return
		}
		s.registration.SetInviteCode(body.InviteCode)
	} else if !s.registration.RegistrationEnabled() {
		s.writeError(w, http.StatusBadRequest, "invite code is required when enabling registration")
		return
	}
	s.writeJSON(w, http.StatusOK, map[string]interface{}{
		"enabled":      s.registration.RegistrationEnabled(),
		"runtime_only": true,
	})
}

func (s *Server) authorized(r *http.Request) bool {
	cookie, err := r.Cookie(adminCookieName)
	if err != nil || cookie.Value == "" {
		return false
	}
	digest := sha256.Sum256([]byte(cookie.Value))
	now := time.Now()
	s.mu.Lock()
	defer s.mu.Unlock()
	expiresAt, ok := s.sessions[digest]
	if !ok || !expiresAt.After(now) {
		delete(s.sessions, digest)
		return false
	}
	return true
}

func (s *Server) loginBlocked(ip string) (time.Duration, bool) {
	now := time.Now()
	s.mu.Lock()
	defer s.mu.Unlock()
	state, ok := s.loginAttempts[ip]
	if !ok || !state.BlockedUntil.After(now) {
		return 0, false
	}
	return time.Until(state.BlockedUntil), true
}

func (s *Server) recordLoginFailure(ip string) {
	now := time.Now()
	s.mu.Lock()
	defer s.mu.Unlock()
	state := s.loginAttempts[ip]
	if state.WindowStarted.IsZero() || now.Sub(state.WindowStarted) > loginWindow {
		state = loginState{WindowStarted: now}
	}
	state.Failures++
	if state.Failures >= maxLoginFailure {
		state.BlockedUntil = now.Add(loginBlockTime)
	}
	s.loginAttempts[ip] = state
	if len(s.loginAttempts) > 1024 {
		for key, attempt := range s.loginAttempts {
			if now.Sub(attempt.WindowStarted) > loginWindow && !attempt.BlockedUntil.After(now) {
				delete(s.loginAttempts, key)
			}
		}
	}
}

func (s *Server) clearLoginFailures(ip string) {
	s.mu.Lock()
	delete(s.loginAttempts, ip)
	s.mu.Unlock()
}

func (s *Server) pruneSessionsLocked(now time.Time) {
	for digest, expiresAt := range s.sessions {
		if !expiresAt.After(now) {
			delete(s.sessions, digest)
		}
	}
}

func (s *Server) sessionCookie(r *http.Request, value string, expires time.Time, maxAge int) *http.Cookie {
	return &http.Cookie{
		Name:     adminCookieName,
		Value:    value,
		Path:     s.publicPath,
		Expires:  expires,
		MaxAge:   maxAge,
		HttpOnly: true,
		Secure:   r.TLS != nil || strings.EqualFold(r.Header.Get("X-Forwarded-Proto"), "https"),
		SameSite: http.SameSiteStrictMode,
	}
}

func (s *Server) setSecurityHeaders(w http.ResponseWriter) {
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("Referrer-Policy", "no-referrer")
	w.Header().Set("X-Frame-Options", "DENY")
	w.Header().Set("Permissions-Policy", "camera=(), microphone=(), geolocation=()")
	w.Header().Set("Content-Security-Policy", "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data: https:; connect-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'")
}

func (s *Server) allowedMethods(path string) string {
	switch path {
	case "/session":
		return "GET, POST, DELETE"
	case "/users", "/settings/registration", "/fairy/config":
		return "GET, PATCH"
	case "/fairy/model-probe":
		return "POST"
	case "/fairy/model-eval":
		return "GET, POST"
	case "/fairy/agent-diagnostic":
		return "POST"
	case "/fairy/decision-chains":
		return "GET"
	case "/users/password":
		return "PATCH"
	case "/titles":
		return "GET, POST, DELETE"
	case "/reports":
		return "GET"
	case "/groups", "/conversations", "/messages", "/media":
		return "GET, DELETE"
	case "/overview":
		return "GET"
	case "/terminal":
		return "GET"
	default:
		return ""
	}
}

func (s *Server) writeError(w http.ResponseWriter, status int, message string) {
	s.writeJSON(w, status, map[string]interface{}{"error": message})
}

func (s *Server) writeJSON(w http.ResponseWriter, status int, value interface{}) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(value)
}

func decodeJSON(w http.ResponseWriter, r *http.Request, destination interface{}) error {
	r.Body = http.MaxBytesReader(w, r.Body, 16*1024)
	decoder := json.NewDecoder(r.Body)
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(destination); err != nil {
		return fmt.Errorf("invalid request body")
	}
	return nil
}

func clientIP(r *http.Request) string {
	if value := strings.TrimSpace(r.Header.Get("X-Real-IP")); net.ParseIP(value) != nil {
		return value
	}
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err == nil {
		return host
	}
	return r.RemoteAddr
}

func newSessionToken() (string, [sha256.Size]byte, error) {
	var bytes [32]byte
	if _, err := rand.Read(bytes[:]); err != nil {
		return "", [sha256.Size]byte{}, err
	}
	raw := base64.RawURLEncoding.EncodeToString(bytes[:])
	return raw, sha256.Sum256([]byte(raw)), nil
}
