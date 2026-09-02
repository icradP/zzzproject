package fairy

import (
	"crypto/sha256"
	"crypto/subtle"
	"encoding/json"
	"net/http"
	"strings"
)

type AdminAPI struct {
	manager     *ConfigManager
	tokenDigest [sha256.Size]byte
	connected   func() bool
	restart     func()
}

func NewAdminAPI(
	manager *ConfigManager,
	token string,
	connected func() bool,
	restart func(),
) *AdminAPI {
	if connected == nil {
		connected = func() bool { return false }
	}
	if restart == nil {
		restart = func() {}
	}
	return &AdminAPI{
		manager:     manager,
		tokenDigest: sha256.Sum256([]byte(strings.TrimSpace(token))),
		connected:   connected,
		restart:     restart,
	}
}

func (a *AdminAPI) ServeHTTP(response http.ResponseWriter, request *http.Request) {
	response.Header().Set("Cache-Control", "no-store")
	response.Header().Set("Content-Type", "application/json; charset=utf-8")
	response.Header().Set("X-Content-Type-Options", "nosniff")
	if !a.authorized(request) {
		a.writeError(response, http.StatusUnauthorized, "Fairy admin authentication required")
		return
	}
	if request.URL.Path != "/admin/config" {
		a.writeError(response, http.StatusNotFound, "Fairy admin endpoint not found")
		return
	}
	switch request.Method {
	case http.MethodGet:
		a.writeJSON(response, http.StatusOK, a.manager.Response(a.connected()))
	case http.MethodPatch:
		a.handleUpdate(response, request)
	default:
		response.Header().Set("Allow", "GET, PATCH")
		a.writeError(response, http.StatusMethodNotAllowed, "method not allowed")
	}
}

func (a *AdminAPI) handleUpdate(response http.ResponseWriter, request *http.Request) {
	var update ManagedConfigUpdate
	request.Body = http.MaxBytesReader(response, request.Body, 32*1024)
	decoder := json.NewDecoder(request.Body)
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&update); err != nil {
		a.writeError(response, http.StatusBadRequest, "invalid Fairy configuration")
		return
	}
	if err := requireJSONEOF(decoder); err != nil {
		a.writeError(response, http.StatusBadRequest, "invalid Fairy configuration")
		return
	}
	if _, err := a.manager.Update(update); err != nil {
		a.writeError(response, http.StatusBadRequest, err.Error())
		return
	}
	payload := a.manager.Response(a.connected())
	a.writeJSON(response, http.StatusOK, map[string]interface{}{
		"connected":         payload.Connected,
		"config":            payload.Config,
		"plugins":           payload.Plugins,
		"restart_scheduled": true,
	})
	go a.restart()
}

func (a *AdminAPI) authorized(request *http.Request) bool {
	header := strings.TrimSpace(request.Header.Get("Authorization"))
	if !strings.HasPrefix(header, "Bearer ") {
		return false
	}
	provided := sha256.Sum256([]byte(strings.TrimSpace(strings.TrimPrefix(header, "Bearer "))))
	return subtle.ConstantTimeCompare(provided[:], a.tokenDigest[:]) == 1
}

func (a *AdminAPI) writeError(response http.ResponseWriter, status int, message string) {
	a.writeJSON(response, status, map[string]interface{}{"error": message})
}

func (a *AdminAPI) writeJSON(response http.ResponseWriter, status int, value interface{}) {
	response.WriteHeader(status)
	_ = json.NewEncoder(response).Encode(value)
}
