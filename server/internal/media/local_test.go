package media

import (
	"crypto/sha256"
	"encoding/hex"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
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

func TestLocalStoreDeduplicatesWithinUploader(t *testing.T) {
	database := store.NewMemoryStore()
	media, err := NewLocalStore(t.TempDir(), database)
	if err != nil {
		t.Fatal(err)
	}
	payload := []byte("same image")
	first, err := media.Save("first.png", "image", "image/png", payload, "alice")
	if err != nil {
		t.Fatal(err)
	}
	second, err := media.Save("second.png", "image", "image/png", payload, "alice")
	if err != nil {
		t.Fatal(err)
	}
	if first.ID != second.ID || first.URL != second.URL {
		t.Fatalf("duplicate upload was not reused: first=%#v second=%#v", first, second)
	}
	files, err := database.GetMediaFiles(10)
	if err != nil || len(files) != 1 {
		t.Fatalf("stored media=%d err=%v", len(files), err)
	}
	plainHash := sha256.Sum256(payload)
	if first.ID == hex.EncodeToString(plainHash[:]) {
		t.Fatal("media ID must include the uploader namespace")
	}
}

func TestLocalStoreDoesNotDeduplicateAcrossUploaders(t *testing.T) {
	database := store.NewMemoryStore()
	media, err := NewLocalStore(t.TempDir(), database)
	if err != nil {
		t.Fatal(err)
	}
	payload := []byte("shared bytes")
	alice, err := media.Save("image.png", "image", "image/png", payload, "alice")
	if err != nil {
		t.Fatal(err)
	}
	bob, err := media.Save("image.png", "image", "image/png", payload, "bob")
	if err != nil {
		t.Fatal(err)
	}
	if alice.ID == bob.ID {
		t.Fatalf("different uploaders shared media ID %q", alice.ID)
	}
}

func TestLocalStoreDeduplicatesConcurrentUploads(t *testing.T) {
	database := store.NewMemoryStore()
	media, err := NewLocalStore(t.TempDir(), database)
	if err != nil {
		t.Fatal(err)
	}

	const uploads = 12
	ids := make(chan string, uploads)
	errors := make(chan error, uploads)
	var workers sync.WaitGroup
	for i := 0; i < uploads; i++ {
		workers.Add(1)
		go func() {
			defer workers.Done()
			file, saveErr := media.Save(
				"concurrent.png",
				"image",
				"image/png",
				[]byte("concurrent payload"),
				"alice",
			)
			if saveErr != nil {
				errors <- saveErr
				return
			}
			ids <- file.ID
		}()
	}
	workers.Wait()
	close(ids)
	close(errors)
	for saveErr := range errors {
		t.Fatal(saveErr)
	}
	var expected string
	for id := range ids {
		if expected == "" {
			expected = id
		}
		if id != expected {
			t.Fatalf("concurrent upload IDs differ: got %q want %q", id, expected)
		}
	}
	files, err := database.GetMediaFiles(10)
	if err != nil || len(files) != 1 {
		t.Fatalf("stored media=%d err=%v", len(files), err)
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

func TestValidIDAcceptsLegacyAndHashedMediaIDs(t *testing.T) {
	if !validID(strings.Repeat("a", 32)) {
		t.Fatal("legacy 32-character ID was rejected")
	}
	if !validID(strings.Repeat("b", 64)) {
		t.Fatal("hashed 64-character ID was rejected")
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

func TestLocalStoreDeleteRemovesBytesAndMetadata(t *testing.T) {
	database := store.NewMemoryStore()
	media, err := NewLocalStore(t.TempDir(), database)
	if err != nil {
		t.Fatal(err)
	}
	file, err := media.Save("delete-me.txt", "file", "text/plain", []byte("temporary"), "alice")
	if err != nil {
		t.Fatal(err)
	}
	deleted, err := media.Delete(file.ID)
	if err != nil || !deleted {
		t.Fatalf("delete result=%v err=%v", deleted, err)
	}
	metadata, err := database.GetMedia(file.ID)
	if err != nil || metadata != nil {
		t.Fatalf("metadata after delete=%#v err=%v", metadata, err)
	}
	request := httptest.NewRequest(http.MethodGet, file.URL, nil)
	response := httptest.NewRecorder()
	media.ServeHTTP(response, request)
	if response.Code != http.StatusNotFound {
		t.Fatalf("deleted media status=%d", response.Code)
	}
	deleted, err = media.Delete(file.ID)
	if err != nil || deleted {
		t.Fatalf("second delete result=%v err=%v", deleted, err)
	}
}
