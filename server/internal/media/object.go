package media

import (
	"bytes"
	"fmt"
	"mime"
	"net/http"
	"sync"
	"time"

	"github.com/icradp/zzz-im-server/internal/store"
)

// ObjectStore persists media through an S3-compatible backend. The backend
// is deliberately supplied through store.ObjectStorage so deployments can
// use S3, MinIO, R2, or a test double without coupling the gateway to a
// vendor SDK.
type ObjectStore struct {
	metadata store.Store
	objects  store.ObjectStorage
	mu       sync.Mutex
}

func NewObjectStore(metadata store.Store, objects store.ObjectStorage) (*ObjectStore, error) {
	if metadata == nil || objects == nil {
		return nil, fmt.Errorf("metadata and object storage are required")
	}
	return &ObjectStore{metadata: metadata, objects: objects}, nil
}

// Save implements the gateway media uploader contract.
func (s *ObjectStore) Save(fileName, fileType, contentType string, data []byte, uploaderID string) (*store.MediaFile, error) {
	id := contentID(uploaderID, data)
	if _, _, err := mime.ParseMediaType(contentType); err != nil || contentType == "application/octet-stream" {
		contentType = http.DetectContentType(data)
	}
	thumbnail, width, height := makeThumbnail(data, contentType)

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
		return existing, nil
	}

	fileName = safeFileName(fileName)
	originalURL, err := s.objects.Upload(id, bytes.NewReader(data), contentType)
	if err != nil {
		return nil, fmt.Errorf("upload media object: %w", err)
	}
	thumbnailURL := ""
	if len(thumbnail) > 0 {
		thumbnailURL, err = s.objects.Upload(id+".thumb", bytes.NewReader(thumbnail), "image/jpeg")
		if err != nil {
			_ = s.objects.Delete(id)
			return nil, fmt.Errorf("upload media thumbnail: %w", err)
		}
	}
	metadata := &store.MediaFile{
		ID:           id,
		FileName:     fileName,
		FileType:     fileType,
		MimeType:     contentType,
		Size:         int64(len(data)),
		URL:          originalURL,
		ThumbnailURL: thumbnailURL,
		Width:        width,
		Height:       height,
		UploaderID:   uploaderID,
		CreatedAt:    time.Now(),
	}
	if err := s.metadata.StoreMedia(metadata); err != nil {
		_ = s.objects.Delete(id)
		if thumbnailURL != "" {
			_ = s.objects.Delete(id + ".thumb")
		}
		return nil, fmt.Errorf("store media metadata: %w", err)
	}
	return metadata, nil
}

// Delete removes both object variants before deleting their metadata.
func (s *ObjectStore) Delete(id string) (bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	metadata, err := s.metadata.GetMedia(id)
	if err != nil || metadata == nil {
		return metadata != nil, err
	}
	if err := s.objects.Delete(id); err != nil {
		return false, fmt.Errorf("delete media object: %w", err)
	}
	if metadata.ThumbnailURL != "" {
		if err := s.objects.Delete(id + ".thumb"); err != nil {
			return false, fmt.Errorf("delete media thumbnail: %w", err)
		}
	}
	if err := s.metadata.DeleteMedia(id); err != nil {
		return false, fmt.Errorf("delete media metadata: %w", err)
	}
	return true, nil
}

// ObjectStore does not serve bytes itself; object URLs returned by the
// backend are public (or signed) URLs and should be exposed directly.
