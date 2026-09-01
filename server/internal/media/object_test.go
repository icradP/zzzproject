package media

import (
	"bytes"
	"io"
	"strings"
	"testing"

	"github.com/icradp/zzz-im-server/internal/store"
)

type fakeObjectStorage struct {
	objects map[string][]byte
}

func newFakeObjectStorage() *fakeObjectStorage {
	return &fakeObjectStorage{objects: make(map[string][]byte)}
}

func (f *fakeObjectStorage) Upload(key string, reader io.Reader, _ string) (string, error) {
	data, err := io.ReadAll(reader)
	if err != nil {
		return "", err
	}
	f.objects[key] = append([]byte(nil), data...)
	return "https://cdn.example/" + key, nil
}

func (f *fakeObjectStorage) Download(key string) (io.ReadCloser, error) {
	data, ok := f.objects[key]
	if !ok {
		return nil, io.EOF
	}
	return io.NopCloser(bytes.NewReader(data)), nil
}

func (f *fakeObjectStorage) Delete(key string) error {
	delete(f.objects, key)
	return nil
}

func (f *fakeObjectStorage) GetURL(key string) string {
	return "https://cdn.example/" + key
}

func TestObjectStoreSavesAndDeletesThumbnail(t *testing.T) {
	objects := newFakeObjectStorage()
	media, err := NewObjectStore(store.NewMemoryStore(), objects)
	if err != nil {
		t.Fatal(err)
	}
	file, err := media.Save("large.png", "image", "image/png", testPNG(t, 1200, 800), "alice")
	if err != nil {
		t.Fatal(err)
	}
	if file.ThumbnailURL == "" || !strings.Contains(file.ThumbnailURL, ".thumb") {
		t.Fatalf("missing object thumbnail URL: %#v", file)
	}
	if _, ok := objects.objects[file.ID]; !ok {
		t.Fatal("original object was not uploaded")
	}
	if _, ok := objects.objects[file.ID+".thumb"]; !ok {
		t.Fatal("thumbnail object was not uploaded")
	}
	deleted, err := media.Delete(file.ID)
	if err != nil || !deleted {
		t.Fatalf("delete result=%v err=%v", deleted, err)
	}
	if len(objects.objects) != 0 {
		t.Fatalf("objects remain after delete: %#v", objects.objects)
	}
}
