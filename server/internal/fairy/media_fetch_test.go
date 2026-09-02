package fairy

import (
	"bytes"
	"context"
	"errors"
	"image"
	"image/color"
	"image/png"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestMediaFetcherReadsValidatedServerMedia(t *testing.T) {
	imageData := testPNG(t, 2, 3)
	audioData := append([]byte{0x1a, 0x45, 0xdf, 0xa3}, bytes.Repeat([]byte{0}, 32)...)
	server := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		switch request.URL.Path {
		case "/files/image/photo.png":
			response.Header().Set("Content-Type", "image/png")
			_, _ = response.Write(imageData)
		case "/files/audio/voice.webm":
			response.Header().Set("Content-Type", "audio/webm; codecs=opus")
			_, _ = response.Write(audioData)
		default:
			http.NotFound(response, request)
		}
	}))
	defer server.Close()
	fetcher, err := newMediaFetcher("ws" + strings.TrimPrefix(server.URL, "http") + "/ws")
	if err != nil {
		t.Fatal(err)
	}

	imageResult, err := fetcher.Fetch(context.Background(), mediaInput{Kind: mediaInputImage, URL: "/files/image/photo.png"})
	if err != nil || imageResult.MIMEType != "image/png" || !bytes.Equal(imageResult.Data, imageData) {
		t.Fatalf("image result=%#v err=%v", imageResult, err)
	}
	audioResult, err := fetcher.Fetch(context.Background(), mediaInput{
		Kind: mediaInputRecord, URL: "/files/audio/voice.webm", DurationMS: 1000,
	})
	if err != nil || audioResult.MIMEType != "audio/webm" || !bytes.Equal(audioResult.Data, audioData) {
		t.Fatalf("audio result=%#v err=%v", audioResult, err)
	}
}

func TestMediaFetcherBlocksUnsafeTargetsAndRedirects(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		if request.URL.Path == "/files/redirect" {
			http.Redirect(response, request, "/admin/config", http.StatusFound)
			return
		}
		http.NotFound(response, request)
	}))
	defer server.Close()
	fetcher, err := newMediaFetcher("ws" + strings.TrimPrefix(server.URL, "http") + "/ws")
	if err != nil {
		t.Fatal(err)
	}
	fetcher.resolve = func(context.Context, string) ([]net.IPAddr, error) {
		return []net.IPAddr{{IP: net.ParseIP("127.0.0.1")}}, nil
	}

	tests := []mediaInput{
		{Kind: mediaInputImage, URL: server.URL + "/admin/config"},
		{Kind: mediaInputRecord, URL: "https://public.example/voice.webm"},
		{Kind: mediaInputImage, URL: "http://public.example/photo.png"},
		{Kind: mediaInputImage, URL: "https://public.example/photo.png"},
		{Kind: mediaInputImage, URL: "/files/redirect"},
	}
	for _, input := range tests {
		_, err := fetcher.Fetch(context.Background(), input)
		var failure *mediaFetchFailure
		if !errors.As(err, &failure) || failure.Code != mediaFetchUnsafe {
			t.Errorf("Fetch(%q) error = %v", input.URL, err)
		}
	}
}

func TestMediaFetcherBlocksRedirectToDifferentLocalPort(t *testing.T) {
	targetHits := 0
	target := httptest.NewTLSServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		targetHits++
		response.Header().Set("Content-Type", "image/png")
		_, _ = response.Write(testPNG(t, 2, 2))
	}))
	defer target.Close()
	source := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		http.Redirect(response, request, target.URL+"/files/private.png", http.StatusFound)
	}))
	defer source.Close()
	fetcher, err := newMediaFetcher("ws" + strings.TrimPrefix(source.URL, "http") + "/ws")
	if err != nil {
		t.Fatal(err)
	}
	_, err = fetcher.Fetch(context.Background(), mediaInput{Kind: mediaInputImage, URL: "/files/redirect"})
	var failure *mediaFetchFailure
	if !errors.As(err, &failure) || failure.Code != mediaFetchUnsafe || targetHits != 0 {
		t.Fatalf("cross-port redirect error=%v target_hits=%d", err, targetHits)
	}
}

func TestMediaFetcherRejectsTypeAndBatchLimits(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		response.Header().Set("Content-Type", "text/html")
		_, _ = response.Write([]byte("<html>not media</html>"))
	}))
	defer server.Close()
	fetcher, err := newMediaFetcher("ws" + strings.TrimPrefix(server.URL, "http") + "/ws")
	if err != nil {
		t.Fatal(err)
	}
	_, err = fetcher.Fetch(context.Background(), mediaInput{Kind: mediaInputImage, URL: "/files/not-image"})
	var failure *mediaFetchFailure
	if !errors.As(err, &failure) || failure.Code != mediaFetchUnsupported {
		t.Fatalf("unsupported image error = %v", err)
	}
	tooMany := mediaInputSummary{images: maxMediaImages + 1}
	for range maxMediaImages + 1 {
		tooMany.inputs = append(tooMany.inputs, mediaInput{Kind: mediaInputImage, URL: "/files/image.png"})
	}
	if _, err := fetcher.FetchAll(context.Background(), tooMany); !errors.As(err, &failure) || failure.Code != mediaFetchInvalid {
		t.Fatalf("batch error = %v", err)
	}
}

func TestMediaFetcherRejectsCombinedImageSize(t *testing.T) {
	imageData := testPNG(t, 2, 2)
	imageData = append(imageData, bytes.Repeat([]byte{0}, 7*1024*1024-len(imageData))...)
	server := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		response.Header().Set("Content-Type", "image/png")
		_, _ = response.Write(imageData)
	}))
	defer server.Close()
	fetcher, err := newMediaFetcher("ws" + strings.TrimPrefix(server.URL, "http") + "/ws")
	if err != nil {
		t.Fatal(err)
	}
	summary := mediaInputSummary{images: 3, inputs: []mediaInput{
		{Kind: mediaInputImage, URL: "/files/a.png"},
		{Kind: mediaInputImage, URL: "/files/b.png"},
		{Kind: mediaInputImage, URL: "/files/c.png"},
	}}
	_, err = fetcher.FetchAll(context.Background(), summary)
	var failure *mediaFetchFailure
	if !errors.As(err, &failure) || failure.Code != mediaFetchTooLarge {
		t.Fatalf("combined image limit error = %v", err)
	}
}

func testPNG(t *testing.T, width, height int) []byte {
	t.Helper()
	canvas := image.NewRGBA(image.Rect(0, 0, width, height))
	canvas.Set(0, 0, color.RGBA{R: 255, A: 255})
	var output bytes.Buffer
	if err := png.Encode(&output, canvas); err != nil {
		t.Fatal(err)
	}
	return output.Bytes()
}
