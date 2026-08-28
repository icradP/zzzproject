package store

import (
	"fmt"
	"sync"
	"time"
)

// MediaStore handles media file storage.
type MediaStore struct {
	mu        sync.RWMutex
	files     map[string]*MediaFile
	counter   int64
	baseURL   string
}

// NewMediaStore creates a new media store.
func NewMediaStore(baseURL string) *MediaStore {
	return &MediaStore{
		files:   make(map[string]*MediaFile),
		baseURL: baseURL,
	}
}

// StoreFile stores a media file and returns its ID and URL.
func (s *MediaStore) StoreFile(fileName, fileType, mimeType string, data []byte, uploaderID string) (string, string) {
	s.mu.Lock()
	defer s.mu.Unlock()

	s.counter++
	id := fmt.Sprintf("file_%d", s.counter)

	// In production, upload to object storage and get URL
	url := fmt.Sprintf("%s/files/%s", s.baseURL, id)

	file := &MediaFile{
		ID:         id,
		FileName:   fileName,
		FileType:   fileType,
		MimeType:   mimeType,
		Size:       int64(len(data)),
		URL:        url,
		UploaderID: uploaderID,
		CreatedAt:  time.Now(),
	}

	s.files[id] = file

	return id, url
}

// GetFile returns a media file by ID.
func (s *MediaStore) GetFile(id string) *MediaFile {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.files[id]
}

// GetFileURL returns the URL for a file.
func (s *MediaStore) GetFileURL(id string) string {
	return fmt.Sprintf("%s/files/%s", s.baseURL, id)
}

// DeleteFile deletes a media file.
func (s *MediaStore) DeleteFile(id string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.files[id]; ok {
		delete(s.files, id)
		return true
	}
	return false
}

// GetFilesByUploader returns files uploaded by a user.
func (s *MediaStore) GetFilesByUploader(uploaderID string) []*MediaFile {
	s.mu.RLock()
	defer s.mu.RUnlock()
	result := make([]*MediaFile, 0)
	for _, file := range s.files {
		if file.UploaderID == uploaderID {
			result = append(result, file)
		}
	}
	return result
}
