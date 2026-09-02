package admin

import (
	"encoding/json"
	"io"
	"net/http"
)

func (s *Server) handleFairyConfig(response http.ResponseWriter, request *http.Request) {
	if s.fairy == nil {
		s.writeError(response, http.StatusServiceUnavailable, "Fairy management is not configured")
		return
	}
	var body []byte
	if request.Method == http.MethodPatch {
		request.Body = http.MaxBytesReader(response, request.Body, 32*1024)
		var err error
		body, err = io.ReadAll(request.Body)
		if err != nil || !json.Valid(body) {
			s.writeError(response, http.StatusBadRequest, "invalid Fairy configuration")
			return
		}
	}
	status, payload, err := s.fairy.Request(request.Context(), request.Method, body)
	if err != nil {
		s.writeError(response, http.StatusServiceUnavailable, "Fairy management is unavailable")
		return
	}
	if status < 100 || status > 599 {
		s.writeError(response, http.StatusBadGateway, "Fairy management returned an invalid response")
		return
	}
	response.Header().Set("Content-Type", "application/json; charset=utf-8")
	response.WriteHeader(status)
	_, _ = response.Write(payload)
}
