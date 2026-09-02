package fairy

import (
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"time"
)

const maxManagedConfigRequestBytes = 256 * 1024
const maxModelProbeRequestBytes = 1024

type AdminAPI struct {
	manager       *ConfigManager
	tokenDigest   [sha256.Size]byte
	connected     func() bool
	restart       func()
	runtime       AdminRuntime
	modelTestSlot chan struct{}
	probe         func(context.Context, Config, string) (ModelProbeResult, error)
	qualityEval   *qualityEvalJobManager
}

func NewAdminAPI(
	manager *ConfigManager,
	token string,
	connected func() bool,
	restart func(),
) *AdminAPI {
	return NewAdminAPIWithRuntimeContext(context.Background(), manager, token, connected, restart, nil)
}

func NewAdminAPIWithRuntime(
	manager *ConfigManager,
	token string,
	connected func() bool,
	restart func(),
	runtime AdminRuntime,
) *AdminAPI {
	return NewAdminAPIWithRuntimeContext(context.Background(), manager, token, connected, restart, runtime)
}

func NewAdminAPIWithRuntimeContext(
	ctx context.Context,
	manager *ConfigManager,
	token string,
	connected func() bool,
	restart func(),
	runtime AdminRuntime,
) *AdminAPI {
	if connected == nil {
		connected = func() bool { return false }
	}
	if restart == nil {
		restart = func() {}
	}
	modelTestSlot := make(chan struct{}, 1)
	return &AdminAPI{
		manager:       manager,
		tokenDigest:   sha256.Sum256([]byte(strings.TrimSpace(token))),
		connected:     connected,
		restart:       restart,
		runtime:       runtime,
		modelTestSlot: modelTestSlot,
		probe:         ProbeConfiguredModel,
		qualityEval:   newQualityEvalJobManager(ctx, modelTestSlot),
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
	switch request.URL.Path {
	case "/admin/config":
		a.serveConfig(response, request)
	case "/admin/model-probe":
		a.serveModelProbe(response, request)
	case "/admin/model-eval":
		a.serveModelEvaluation(response, request)
	default:
		a.writeError(response, http.StatusNotFound, "Fairy admin endpoint not found")
	}
	return
}

func (a *AdminAPI) serveConfig(response http.ResponseWriter, request *http.Request) {
	switch request.Method {
	case http.MethodGet:
		a.writeJSON(response, http.StatusOK, a.responsePayload(request))
	case http.MethodPatch:
		a.handleUpdate(response, request)
	default:
		response.Header().Set("Allow", "GET, PATCH")
		a.writeError(response, http.StatusMethodNotAllowed, "method not allowed")
	}
}

func (a *AdminAPI) serveModelProbe(response http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodPost {
		response.Header().Set("Allow", "POST")
		a.writeError(response, http.StatusMethodNotAllowed, "method not allowed")
		return
	}
	select {
	case a.modelTestSlot <- struct{}{}:
		defer func() { <-a.modelTestSlot }()
	default:
		a.writeModelDiagnosticBusy(response)
		return
	}
	var input struct {
		ModelID string `json:"model_id"`
	}
	request.Body = http.MaxBytesReader(response, request.Body, maxModelProbeRequestBytes)
	decoder := json.NewDecoder(request.Body)
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&input); err != nil || requireJSONEOF(decoder) != nil {
		a.writeError(response, http.StatusBadRequest, "invalid Fairy model probe")
		return
	}
	probeContext, cancel := context.WithTimeout(request.Context(), modelProbeTimeout+time.Second)
	defer cancel()
	result, err := a.probe(probeContext, a.manager.Current(), input.ModelID)
	if err != nil {
		a.writeError(response, http.StatusBadRequest, err.Error())
		return
	}
	a.writeJSON(response, http.StatusOK, result)
}

func (a *AdminAPI) serveModelEvaluation(response http.ResponseWriter, request *http.Request) {
	switch request.Method {
	case http.MethodGet:
		if request.URL.RawQuery != "" {
			a.writeError(response, http.StatusBadRequest, "invalid Fairy model evaluation query")
			return
		}
		a.writeJSON(response, http.StatusOK, a.qualityEval.Snapshot())
	case http.MethodPost:
		var input struct {
			ModelID string `json:"model_id"`
		}
		request.Body = http.MaxBytesReader(response, request.Body, maxModelProbeRequestBytes)
		decoder := json.NewDecoder(request.Body)
		decoder.DisallowUnknownFields()
		if err := decoder.Decode(&input); err != nil || requireJSONEOF(decoder) != nil {
			a.writeError(response, http.StatusBadRequest, "invalid Fairy model evaluation")
			return
		}
		job, err := a.qualityEval.Start(a.manager.Current(), input.ModelID)
		if errors.Is(err, ErrModelDiagnosticBusy) {
			a.writeModelDiagnosticBusy(response)
			return
		}
		if err != nil {
			a.writeError(response, http.StatusBadRequest, err.Error())
			return
		}
		a.writeJSON(response, http.StatusAccepted, job)
	default:
		response.Header().Set("Allow", "GET, POST")
		a.writeError(response, http.StatusMethodNotAllowed, "method not allowed")
	}
}

func (a *AdminAPI) writeModelDiagnosticBusy(response http.ResponseWriter) {
	response.Header().Set("Retry-After", "1")
	a.writeError(response, http.StatusTooManyRequests, ErrModelDiagnosticBusy.Error())
}

func (a *AdminAPI) handleUpdate(response http.ResponseWriter, request *http.Request) {
	var update ManagedConfigUpdate
	request.Body = http.MaxBytesReader(response, request.Body, maxManagedConfigRequestBytes)
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
	result, err := a.manager.UpdateWithResult(update)
	if err != nil {
		a.writeError(response, http.StatusBadRequest, err.Error())
		return
	}
	appliedLive := result.BehaviorChanged && a.runtime != nil
	if appliedLive {
		a.runtime.ApplyBehaviorConfig(result.Config)
	}
	restartScheduled := result.RestartRequired || result.BehaviorChanged && a.runtime == nil
	if !restartScheduled {
		a.manager.MarkApplied(result.Revision)
	}
	payload := a.responsePayload(request)
	payload["applied_live"] = appliedLive
	payload["restart_scheduled"] = restartScheduled
	a.writeJSON(response, http.StatusOK, payload)
	if restartScheduled {
		go a.restart()
	}
}

func (a *AdminAPI) responsePayload(request *http.Request) map[string]interface{} {
	payload := a.manager.Response(a.connected())
	result := map[string]interface{}{
		"connected":     payload.Connected,
		"config":        payload.Config,
		"config_status": payload.ConfigStatus,
		"plugins":       payload.Plugins,
	}
	if a.runtime != nil {
		result["runtime"] = a.runtime.Snapshot(request.Context())
	}
	return result
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
