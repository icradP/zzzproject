package media

import (
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"mime"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/icradp/zzz-im-server/internal/store"
)

// LocalStore persists media bytes on disk and metadata in the configured Store.
type LocalStore struct {
	directory string
	metadata  store.Store
}

func NewLocalStore(directory string, metadata store.Store) (*LocalStore, error) {
	absolute, err := filepath.Abs(directory)
	if err != nil {
		return nil, err
	}
	if err := os.MkdirAll(absolute, 0o750); err != nil {
		return nil, fmt.Errorf("create media directory: %w", err)
	}
	return &LocalStore{directory: absolute, metadata: metadata}, nil
}

func (s *LocalStore) Save(
	fileName, fileType, contentType string,
	data []byte,
	uploaderID string,
) (*store.MediaFile, error) {
	id, err := randomID()
	if err != nil {
		return nil, err
	}
	if _, _, err := mime.ParseMediaType(contentType); err != nil ||
		contentType == "application/octet-stream" {
		contentType = http.DetectContentType(data)
	}

	temporary, err := os.CreateTemp(s.directory, ".upload-*")
	if err != nil {
		return nil, fmt.Errorf("create media file: %w", err)
	}
	temporaryName := temporary.Name()
	committed := false
	defer func() {
		_ = temporary.Close()
		if !committed {
			_ = os.Remove(temporaryName)
		}
	}()
	if err := temporary.Chmod(0o640); err != nil {
		return nil, err
	}
	if _, err := temporary.Write(data); err != nil {
		return nil, fmt.Errorf("write media file: %w", err)
	}
	if err := temporary.Close(); err != nil {
		return nil, err
	}
	finalPath := filepath.Join(s.directory, id)
	if err := os.Rename(temporaryName, finalPath); err != nil {
		return nil, fmt.Errorf("commit media file: %w", err)
	}
	committed = true

	fileName = safeFileName(fileName)
	metadata := &store.MediaFile{
		ID:         id,
		FileName:   fileName,
		FileType:   fileType,
		MimeType:   contentType,
		Size:       int64(len(data)),
		URL:        "/files/" + id + "/" + url.PathEscape(fileName),
		UploaderID: uploaderID,
		CreatedAt:  time.Now(),
	}
	if err := s.metadata.StoreMedia(metadata); err != nil {
		_ = os.Remove(finalPath)
		return nil, fmt.Errorf("store media metadata: %w", err)
	}
	return metadata, nil
}

func (s *LocalStore) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	id := strings.SplitN(strings.TrimPrefix(r.URL.Path, "/files/"), "/", 2)[0]
	if !validID(id) {
		http.NotFound(w, r)
		return
	}
	metadata, err := s.metadata.GetMedia(id)
	if err != nil || metadata == nil {
		http.NotFound(w, r)
		return
	}
	file, err := os.Open(filepath.Join(s.directory, id))
	if err != nil {
		http.NotFound(w, r)
		return
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		http.NotFound(w, r)
		return
	}

	w.Header().Set("Access-Control-Allow-Origin", "*")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("Content-Type", metadata.MimeType)
	disposition := "attachment"
	if (strings.HasPrefix(metadata.MimeType, "image/") &&
		metadata.MimeType != "image/svg+xml") ||
		strings.HasPrefix(metadata.MimeType, "audio/") ||
		strings.HasPrefix(metadata.MimeType, "video/") {
		disposition = "inline"
	}
	w.Header().Set(
		"Content-Disposition",
		mime.FormatMediaType(disposition, map[string]string{"filename": metadata.FileName}),
	)
	http.ServeContent(w, r, metadata.FileName, info.ModTime(), file)
}

func randomID() (string, error) {
	raw := make([]byte, 16)
	if _, err := rand.Read(raw); err != nil {
		return "", err
	}
	return hex.EncodeToString(raw), nil
}

func validID(id string) bool {
	if len(id) != 32 {
		return false
	}
	_, err := hex.DecodeString(id)
	return err == nil
}

func safeFileName(value string) string {
	value = strings.TrimSpace(filepath.Base(value))
	if value == "" || value == "." {
		return "file"
	}
	return value
}
