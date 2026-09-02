package fairy

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestModelRouterVisionUsesInlineValidatedImage(t *testing.T) {
	server := httptest.NewTLSServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		if request.URL.Path != "/v1/chat/completions" {
			t.Errorf("vision path = %s", request.URL.Path)
		}
		var payload struct {
			Model    string `json:"model"`
			Messages []struct {
				Role    string      `json:"role"`
				Content interface{} `json:"content"`
			} `json:"messages"`
		}
		if err := json.NewDecoder(request.Body).Decode(&payload); err != nil {
			t.Fatal(err)
		}
		if payload.Model != "primary-remote" || len(payload.Messages) != 2 {
			t.Errorf("vision payload = %#v", payload)
		}
		parts, ok := payload.Messages[1].Content.([]interface{})
		if !ok || len(parts) != 2 {
			t.Fatalf("vision content = %#v", payload.Messages[1].Content)
		}
		imagePart, _ := parts[1].(map[string]interface{})
		imageURL, _ := imagePart["image_url"].(map[string]interface{})
		if value, _ := imageURL["url"].(string); !strings.HasPrefix(value, "data:image/png;base64,") {
			t.Errorf("vision image URL = %q", value)
		}
		_, _ = response.Write([]byte(`{"choices":[{"message":{"role":"assistant","content":"一张红色测试图"},"finish_reason":"stop"}],"usage":{"prompt_tokens":8,"completion_tokens":4}}`))
	}))
	defer server.Close()

	cfg := modelRouterTestConfig(t, server.URL+"/v1", 0)
	cfg.ModelTasks = append(cfg.ModelTasks, ModelTaskConfig{
		ID: VisionTaskID, Strategy: SequentialModelStrategy, CandidateModels: []string{"primary"},
		MaxOutputTokens: 300, Timeout: 5 * time.Second,
	})
	trace := newMemoryTraceStore()
	router, err := NewModelRouter(cfg, trace)
	if err != nil {
		t.Fatal(err)
	}
	router.clients["provider"] = server.Client()
	result, err := router.CompleteRequest(context.Background(), ModelRequest{
		TaskID: VisionTaskID,
		Messages: []ChatMessage{
			{Role: "system", Content: "Describe the image safely."},
			{Role: "user", Content: "What is visible?"},
		},
		Images: []ModelBinaryInput{{MIMEType: "image/png", Name: "photo.png", Data: []byte("validated-image")}},
	})
	if err != nil || result.Text != "一张红色测试图" {
		t.Fatalf("vision result=%#v err=%v", result, err)
	}
	if len(trace.events) != 1 || trace.events[0].TaskID != VisionTaskID || trace.events[0].InputTokens != 8 || trace.events[0].OutputTokens != 4 {
		t.Fatalf("vision trace = %#v", trace.events)
	}
}

func TestModelRouterTranscriberUsesMultipartAndTrace(t *testing.T) {
	server := httptest.NewTLSServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		if request.URL.Path != "/v1/audio/transcriptions" {
			t.Errorf("transcription path = %s", request.URL.Path)
		}
		if err := request.ParseMultipartForm(maxMediaAudioBytes + 1024); err != nil {
			t.Fatal(err)
		}
		if request.FormValue("model") != "primary-remote" || request.FormValue("response_format") != "json" {
			t.Errorf("transcription form model=%q format=%q", request.FormValue("model"), request.FormValue("response_format"))
		}
		file, header, err := request.FormFile("file")
		if err != nil {
			t.Fatal(err)
		}
		defer file.Close()
		body, _ := io.ReadAll(file)
		if header.Filename != "voice.webm" || header.Header.Get("Content-Type") != "audio/webm" || string(body) != "audio-bytes" {
			t.Errorf("transcription file=%#v body=%q", header, body)
		}
		_, _ = response.Write([]byte(`{"text":"明天上午提醒我开会","usage":{"input_tokens":12,"output_tokens":6}}`))
	}))
	defer server.Close()

	cfg := modelRouterTestConfig(t, server.URL+"/v1", 0)
	cfg.ModelTasks = append(cfg.ModelTasks, ModelTaskConfig{
		ID: TranscriberTaskID, Strategy: SequentialModelStrategy, CandidateModels: []string{"primary"},
		MaxOutputTokens: 600, Timeout: 5 * time.Second,
	})
	trace := newMemoryTraceStore()
	router, err := NewModelRouter(cfg, trace)
	if err != nil {
		t.Fatal(err)
	}
	router.clients["provider"] = server.Client()
	text, err := router.Transcribe(context.Background(), ModelBinaryInput{
		MIMEType: "audio/webm", Name: "voice.webm", Data: []byte("audio-bytes"),
	})
	if err != nil || text != "明天上午提醒我开会" {
		t.Fatalf("transcription=%q err=%v", text, err)
	}
	if len(trace.events) != 1 || trace.events[0].TaskID != TranscriberTaskID || trace.events[0].InputTokens != 12 || trace.events[0].OutputTokens != 6 {
		t.Fatalf("transcriber trace = %#v", trace.events)
	}
}

func TestModelRequestRejectsMediaOutsideVisionTask(t *testing.T) {
	err := validateModelRequest(ModelRequest{
		TaskID: ReplyerTaskID, Messages: []ChatMessage{{Role: "user", Content: "hello"}},
		Images: []ModelBinaryInput{{MIMEType: "image/png", Data: []byte("image")}},
	})
	if err == nil {
		t.Fatal("image was accepted by the replyer task")
	}
}

func TestModelRouterTranscriberRetriesThenFallsBack(t *testing.T) {
	var models []string
	server := httptest.NewTLSServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		if err := request.ParseMultipartForm(maxMediaAudioBytes + 1024); err != nil {
			t.Fatal(err)
		}
		model := request.FormValue("model")
		models = append(models, model)
		if model == "primary-remote" {
			http.Error(response, `{"error":"temporary"}`, http.StatusBadGateway)
			return
		}
		_, _ = response.Write([]byte(`{"text":"fallback transcript","usage":{"input_tokens":4,"output_tokens":2}}`))
	}))
	defer server.Close()

	cfg := modelRouterTestConfig(t, server.URL+"/v1", 1)
	cfg.ModelTasks = append(cfg.ModelTasks, ModelTaskConfig{
		ID: TranscriberTaskID, Strategy: SequentialModelStrategy, CandidateModels: []string{"primary", "fallback"},
		MaxOutputTokens: 600, Timeout: 5 * time.Second,
	})
	trace := newMemoryTraceStore()
	router, err := NewModelRouter(cfg, trace)
	if err != nil {
		t.Fatal(err)
	}
	router.clients["provider"] = server.Client()
	router.wait = func(context.Context, time.Duration) error { return nil }
	router.jitter = func(time.Duration) time.Duration { return 0 }
	text, err := router.Transcribe(context.Background(), ModelBinaryInput{
		MIMEType: "audio/webm", Name: "voice.webm", Data: []byte("audio-bytes"),
	})
	if err != nil || text != "fallback transcript" || strings.Join(models, ",") != "primary-remote,primary-remote,fallback-remote" {
		t.Fatalf("transcription=%q models=%v err=%v", text, models, err)
	}
	if len(trace.events) != 3 || trace.events[0].Attempt != 1 || trace.events[1].Attempt != 2 ||
		trace.events[2].ModelID != "fallback" || !trace.events[2].Fallback || trace.events[2].Status != "completed" {
		t.Fatalf("transcriber fallback trace = %#v", trace.events)
	}
}
