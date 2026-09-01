package fairy

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestCompatibleModelUsesConfiguredEndpointAndAuthorization(t *testing.T) {
	server := httptest.NewTLSServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		if request.URL.Path != "/v1/chat/completions" {
			t.Errorf("model path = %s", request.URL.Path)
		}
		if request.Header.Get("Authorization") != "Bearer test-key" {
			t.Errorf("authorization = %q", request.Header.Get("Authorization"))
		}
		var payload struct {
			Model     string        `json:"model"`
			Messages  []ChatMessage `json:"messages"`
			MaxTokens int           `json:"max_tokens"`
		}
		if err := json.NewDecoder(request.Body).Decode(&payload); err != nil {
			t.Fatal(err)
		}
		if payload.Model != "test-model" || payload.MaxTokens != 600 || len(payload.Messages) != 1 {
			t.Errorf("model payload = %#v", payload)
		}
		response.Header().Set("Content-Type", "application/json")
		_, _ = response.Write([]byte(`{"choices":[{"message":{"role":"assistant","content":"  测试回复  "}}]}`))
	}))
	defer server.Close()

	cfg := testConfig(t)
	cfg.ModelBaseURL = server.URL + "/v1"
	cfg.ModelAPIKey = "test-key"
	cfg.ModelName = "test-model"
	model := NewCompatibleModel(cfg)
	model.client = server.Client()
	response, err := model.Complete(context.Background(), []ChatMessage{{Role: "user", Content: "你好"}})
	if err != nil {
		t.Fatal(err)
	}
	if strings.TrimSpace(response) != "测试回复" {
		t.Fatalf("model response = %q", response)
	}
}
