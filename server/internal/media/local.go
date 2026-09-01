package media

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"mime"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/icradp/zzz-im-server/internal/store"
)

// LocalStore persists media bytes on disk and metadata in the configured Store.
type LocalStore struct {
	directory string
	metadata  store.Store
	mu        sync.Mutex
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
	id := contentID(uploaderID, data)
	if _, _, err := mime.ParseMediaType(contentType); err != nil ||
		contentType == "application/octet-stream" {
		contentType = http.DetectContentType(data)
	}

	s.mu.Lock()
	defer s.mu.Unlock()
	existing, err := s.metadata.GetMedia(id)
	if err != nil {
		return nil, fmt.Errorf("load media metadata: %w", err)
	}
	if existing != nil {
		if existing.UploaderID != uploaderID {
			return nil, fmt.Errorf("media hash belongs to another uploader")
		}
		if _, err := os.Stat(filepath.Join(s.directory, id)); err != nil {
			return nil, fmt.Errorf("deduplicated media bytes are unavailable: %w", err)
		}
		return existing, nil
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

// Delete removes both the media bytes and their metadata.
func (s *LocalStore) Delete(id string) (bool, error) {
	if !validID(id) {
		return false, nil
	}
	metadata, err := s.metadata.GetMedia(id)
	if err != nil {
		return false, err
	}
	if metadata == nil {
		return false, nil
	}
	originalPath := filepath.Join(s.directory, id)
	tombstonePath := filepath.Join(s.directory, "."+id+".deleting")
	renamed := false
	if err := os.Rename(originalPath, tombstonePath); err == nil {
		renamed = true
	} else if !os.IsNotExist(err) {
		return false, fmt.Errorf("stage media deletion: %w", err)
	}
	if err := s.metadata.DeleteMedia(id); err != nil {
		if renamed {
			_ = os.Rename(tombstonePath, originalPath)
		}
		return false, fmt.Errorf("delete media metadata: %w", err)
	}
	if renamed {
		if err := os.Remove(tombstonePath); err != nil {
			return false, fmt.Errorf("delete media file: %w", err)
		}
	}
	return true, nil
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

func contentID(uploaderID string, data []byte) string {
	hash := sha256.New()
	_, _ = hash.Write([]byte(uploaderID))
	_, _ = hash.Write([]byte{0})
	_, _ = hash.Write(data)
	return hex.EncodeToString(hash.Sum(nil))
}

func validID(id string) bool {
	if len(id) != 32 && len(id) != 64 {
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
