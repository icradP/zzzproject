package media

import (
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/icradp/zzz-im-server/internal/store"
)

func TestLocalStoreSaveAndServe(t *testing.T) {
	database := store.NewMemoryStore()
	media, err := NewLocalStore(t.TempDir(), database)
	if err != nil {
		t.Fatal(err)
	}
	payload := []byte("image payload")
	file, err := media.Save("preview.png", "image", "image/png", payload, "alice")
	if err != nil {
		t.Fatal(err)
	}

	server := httptest.NewServer(media)
	t.Cleanup(server.Close)
	response, err := http.Get(server.URL + file.URL)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	got, err := io.ReadAll(response.Body)
	if err != nil {
		t.Fatal(err)
	}
	if response.StatusCode != http.StatusOK || string(got) != string(payload) {
		t.Fatalf("unexpected response status=%d body=%q", response.StatusCode, got)
	}
	if response.Header.Get("Content-Type") != "image/png" ||
		response.Header.Get("Accept-Ranges") != "bytes" {
		t.Fatalf("unexpected media headers: %#v", response.Header)
	}
}

func TestLocalStoreRejectsInvalidIDs(t *testing.T) {
	media, err := NewLocalStore(t.TempDir(), store.NewMemoryStore())
	if err != nil {
		t.Fatal(err)
	}
	request := httptest.NewRequest(http.MethodGet, "/files/../../secret", nil)
	response := httptest.NewRecorder()
	media.ServeHTTP(response, request)
	if response.Code != http.StatusNotFound {
		t.Fatalf("expected 404, got %d", response.Code)
	}
}

func TestLocalStoreServesSVGAsAttachment(t *testing.T) {
	database := store.NewMemoryStore()
	media, err := NewLocalStore(t.TempDir(), database)
	if err != nil {
		t.Fatal(err)
	}
	file, err := media.Save(
		"active.svg",
		"image",
		"image/svg+xml",
		[]byte(`<svg xmlns="http://www.w3.org/2000/svg"><script/></svg>`),
		"alice",
	)
	if err != nil {
		t.Fatal(err)
	}

	request := httptest.NewRequest(http.MethodGet, file.URL, nil)
	response := httptest.NewRecorder()
	media.ServeHTTP(response, request)
	if disposition := response.Header().Get("Content-Disposition"); !strings.HasPrefix(disposition, "attachment;") {
		t.Fatalf("expected attachment disposition, got %q", disposition)
	}
}
