package store

import (
	"fmt"
	"io"
	"time"
)

// ObjectStorage defines the interface for object storage (S3, MinIO, etc.)
type ObjectStorage interface {
	// Upload uploads a file and returns its URL.
	Upload(key string, reader io.Reader, contentType string) (string, error)

	// Download downloads a file.
	Download(key string) (io.ReadCloser, error)

	// Delete deletes a file.
	Delete(key string) error

	// GetURL returns the public URL for a file.
	GetURL(key string) string
}

// S3Config holds S3/MinIO configuration.
type S3Config struct {
	Endpoint  string
	Region    string
	Bucket    string
	AccessKey string
	SecretKey string
	UseSSL    bool
	BaseURL   string // CDN base URL
}

// MediaStorage handles media file operations with object storage.
type MediaStorage struct {
	store   Store         // Metadata store (SQLite/MySQL)
	storage ObjectStorage // Object storage (S3/MinIO)
}

// NewMediaStorage creates a new media storage.
func NewMediaStorage(store Store, storage ObjectStorage) *MediaStorage {
	return &MediaStorage{
		store:   store,
		storage: storage,
	}
}

// UploadFile uploads a file to object storage and stores metadata.
func (m *MediaStorage) UploadFile(fileName, fileType, contentType string, reader io.Reader, uploaderID string) (*MediaFile, error) {
	// Generate unique key
	key := fmt.Sprintf("%s/%s/%d_%s", fileType, uploaderID, time.Now().UnixNano(), fileName)

	// Upload to object storage
	url, err := m.storage.Upload(key, reader, contentType)
	if err != nil {
		return nil, fmt.Errorf("failed to upload file: %w", err)
	}

	// Store metadata
	file := &MediaFile{
		ID:         key,
		FileName:   fileName,
		FileType:   fileType,
		MimeType:   contentType,
		URL:        url,
		UploaderID: uploaderID,
		CreatedAt:  time.Now(),
	}

	if err := m.store.StoreMedia(file); err != nil {
		return nil, fmt.Errorf("failed to store media metadata: %w", err)
	}

	return file, nil
}

// GetFile gets a file's metadata.
func (m *MediaStorage) GetFile(id string) (*MediaFile, error) {
	return m.store.GetMedia(id)
}

// GetFileURL returns the public URL for a file.
func (m *MediaStorage) GetFileURL(id string) (string, error) {
	file, err := m.store.GetMedia(id)
	if err != nil {
		return "", err
	}
	if file == nil {
		return "", fmt.Errorf("file not found: %s", id)
	}
	return file.URL, nil
}

// DeleteFile deletes a file from object storage and metadata store.
func (m *MediaStorage) DeleteFile(id string) error {
	// Delete from object storage
	if err := m.storage.Delete(id); err != nil {
		return fmt.Errorf("failed to delete from storage: %w", err)
	}

	// Delete metadata
	if err := m.store.DeleteMedia(id); err != nil {
		return fmt.Errorf("failed to delete metadata: %w", err)
	}

	return nil
}
