package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
)

type probeResponse struct {
	Status    string `json:"status"`
	Connected bool   `json:"connected"`
	Ready     bool   `json:"ready"`
}

func TestProbeHandlersSeparateLivenessAndReadiness(t *testing.T) {
	var connected atomic.Bool
	var ready atomic.Bool
	mux := http.NewServeMux()
	registerProbeHandlers(mux, connected.Load, ready.Load)

	assertProbe(t, mux, "/health", http.StatusOK, probeResponse{
		Status: "connecting", Connected: false, Ready: false,
	})
	assertProbe(t, mux, "/ready", http.StatusServiceUnavailable, probeResponse{
		Status: "connecting", Connected: false, Ready: false,
	})

	connected.Store(true)
	assertProbe(t, mux, "/health", http.StatusOK, probeResponse{
		Status: "draining", Connected: true, Ready: false,
	})
	assertProbe(t, mux, "/ready", http.StatusServiceUnavailable, probeResponse{
		Status: "draining", Connected: true, Ready: false,
	})

	ready.Store(true)
	assertProbe(t, mux, "/health", http.StatusOK, probeResponse{
		Status: "ok", Connected: true, Ready: true,
	})
	assertProbe(t, mux, "/ready", http.StatusOK, probeResponse{
		Status: "ok", Connected: true, Ready: true,
	})
}

func TestProbeHandlersMethods(t *testing.T) {
	mux := http.NewServeMux()
	registerProbeHandlers(mux, func() bool { return true }, func() bool { return true })

	head := httptest.NewRecorder()
	mux.ServeHTTP(head, httptest.NewRequest(http.MethodHead, "/ready", nil))
	if head.Code != http.StatusOK || head.Body.Len() != 0 {
		t.Fatalf("HEAD /ready status=%d body=%q", head.Code, head.Body.String())
	}

	post := httptest.NewRecorder()
	mux.ServeHTTP(post, httptest.NewRequest(http.MethodPost, "/health", nil))
	if post.Code != http.StatusMethodNotAllowed || post.Header().Get("Allow") != "GET, HEAD" {
		t.Fatalf("POST /health status=%d allow=%q", post.Code, post.Header().Get("Allow"))
	}
}

func assertProbe(t *testing.T, handler http.Handler, path string, wantStatus int, want probeResponse) {
	t.Helper()
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, httptest.NewRequest(http.MethodGet, path, nil))
	if response.Code != wantStatus {
		t.Fatalf("GET %s status=%d body=%s", path, response.Code, response.Body.String())
	}
	if response.Header().Get("Cache-Control") != "no-store" {
		t.Fatalf("GET %s Cache-Control=%q", path, response.Header().Get("Cache-Control"))
	}
	var got probeResponse
	if err := json.Unmarshal(response.Body.Bytes(), &got); err != nil {
		t.Fatalf("decode GET %s: %v", path, err)
	}
	if got != want {
		t.Fatalf("GET %s response=%#v want=%#v", path, got, want)
	}
}
