package admin

import (
	"encoding/json"
	"io"
	"net/http"
)

func (s *Server) handleFairy(response http.ResponseWriter, request *http.Request, resource string) {
	if s.fairy == nil {
		s.writeError(response, http.StatusServiceUnavailable, "Fairy management is not configured")
		return
	}
	var body []byte
	if request.Method == http.MethodPatch || request.Method == http.MethodPost {
		request.Body = http.MaxBytesReader(response, request.Body, maxFairyAdminRequestBytes)
		var err error
		body, err = io.ReadAll(request.Body)
		if err != nil || !json.Valid(body) {
			s.writeError(response, http.StatusBadRequest, "invalid Fairy configuration")
			return
		}
	}
	status, payload, err := s.fairy.Request(request.Context(), resource, request.Method, body)
	if err != nil {
		s.writeError(response, http.StatusServiceUnavailable, "Fairy management is unavailable")
		return
	}
	if status < 100 || status > 599 {
		s.writeError(response, http.StatusBadGateway, "Fairy management returned an invalid response")
		return
	}
	if status == http.StatusTooManyRequests && (resource == "model-probe" || resource == "model-eval") {
		response.Header().Set("Retry-After", "1")
	}
	response.Header().Set("Content-Type", "application/json; charset=utf-8")
	response.WriteHeader(status)
	_, _ = response.Write(payload)
}
