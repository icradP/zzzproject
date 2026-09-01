package media

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"image"
	"image/color"
	_ "image/gif"
	"image/jpeg"
	_ "image/png"
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
	thumbnailTemporaryName := ""
	committed := false
	thumbnailCommitted := false
	finalPath := filepath.Join(s.directory, id)
	thumbnailPath := filepath.Join(s.directory, id+".thumb")
	defer func() {
		_ = temporary.Close()
		if !committed {
			_ = os.Remove(temporaryName)
		}
		if thumbnailTemporaryName != "" && !thumbnailCommitted {
			_ = os.Remove(thumbnailTemporaryName)
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
	if err := os.Rename(temporaryName, finalPath); err != nil {
		return nil, fmt.Errorf("commit media file: %w", err)
	}
	committed = true
	if len(thumbnail) > 0 {
		thumbnailTemporary, err := os.CreateTemp(s.directory, ".thumbnail-*")
		if err != nil {
			_ = os.Remove(finalPath)
			committed = false
			return nil, fmt.Errorf("create thumbnail file: %w", err)
		}
		thumbnailTemporaryName = thumbnailTemporary.Name()
		if err := thumbnailTemporary.Chmod(0o640); err != nil {
			_ = thumbnailTemporary.Close()
			_ = os.Remove(finalPath)
			committed = false
			return nil, err
		}
		if _, err := thumbnailTemporary.Write(thumbnail); err != nil {
			_ = thumbnailTemporary.Close()
			_ = os.Remove(finalPath)
			committed = false
			return nil, fmt.Errorf("write thumbnail file: %w", err)
		}
		if err := thumbnailTemporary.Close(); err != nil {
			_ = os.Remove(finalPath)
			committed = false
			return nil, err
		}
		if err := os.Rename(thumbnailTemporaryName, thumbnailPath); err != nil {
			_ = os.Remove(finalPath)
			committed = false
			return nil, fmt.Errorf("commit thumbnail file: %w", err)
		}
		thumbnailCommitted = true
	}

	fileName = safeFileName(fileName)
	metadata := &store.MediaFile{
		ID:         id,
		FileName:   fileName,
		FileType:   fileType,
		MimeType:   contentType,
		Size:       int64(len(data)),
		URL:        "/files/" + id + "/" + url.PathEscape(fileName),
		Width:      width,
		Height:     height,
		UploaderID: uploaderID,
		CreatedAt:  time.Now(),
	}
	if len(thumbnail) > 0 {
		metadata.ThumbnailURL = "/files/" + id + "/thumb/" + url.PathEscape(fileName) + ".jpg"
	}
	if err := s.metadata.StoreMedia(metadata); err != nil {
		_ = os.Remove(finalPath)
		if thumbnailCommitted {
			_ = os.Remove(thumbnailPath)
		}
		return nil, fmt.Errorf("store media metadata: %w", err)
	}
	return metadata, nil
}

// Delete removes both the media bytes and their metadata.
func (s *LocalStore) Delete(id string) (bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
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
	thumbnailPath := filepath.Join(s.directory, id+".thumb")
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
	if err := os.Remove(thumbnailPath); err != nil && !os.IsNotExist(err) {
		return false, fmt.Errorf("delete media thumbnail: %w", err)
	}
	return true, nil
}

func (s *LocalStore) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	parts := strings.Split(strings.TrimPrefix(r.URL.Path, "/files/"), "/")
	if len(parts) == 0 {
		http.NotFound(w, r)
		return
	}
	id := parts[0]
	if !validID(id) {
		http.NotFound(w, r)
		return
	}
	metadata, err := s.metadata.GetMedia(id)
	if err != nil || metadata == nil {
		http.NotFound(w, r)
		return
	}
	isThumbnail := len(parts) > 1 && parts[1] == "thumb"
	path := filepath.Join(s.directory, id)
	contentType := metadata.MimeType
	fileName := metadata.FileName
	if isThumbnail {
		thumbnailPath := filepath.Join(s.directory, id+".thumb")
		if _, err := os.Stat(thumbnailPath); err == nil {
			path = thumbnailPath
			contentType = "image/jpeg"
			fileName = "thumb-" + metadata.FileName
		}
	}
	file, err := os.Open(path)
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
	w.Header().Set("Content-Type", contentType)
	w.Header().Set("Cache-Control", "public, max-age=31536000, immutable")
	disposition := "attachment"
	if (strings.HasPrefix(contentType, "image/") &&
		contentType != "image/svg+xml") ||
		strings.HasPrefix(contentType, "audio/") ||
		strings.HasPrefix(contentType, "video/") {
		disposition = "inline"
	}
	w.Header().Set(
		"Content-Disposition",
		mime.FormatMediaType(disposition, map[string]string{"filename": fileName}),
	)
	http.ServeContent(w, r, fileName, info.ModTime(), file)
}

const maxThumbnailEdge = 640
const maxDecodedImagePixels int64 = 64 * 1024 * 1024

// makeThumbnail returns a JPEG preview and the original image dimensions. A
// malformed image or unsupported format simply has no preview; the original
// upload remains valid and available.
func makeThumbnail(data []byte, contentType string) ([]byte, int, int) {
	if !strings.HasPrefix(contentType, "image/") || contentType == "image/svg+xml" {
		return nil, 0, 0
	}
	config, _, err := image.DecodeConfig(bytes.NewReader(data))
	if err != nil {
		return nil, 0, 0
	}
	width, height := config.Width, config.Height
	if width <= 0 || height <= 0 {
		return nil, 0, 0
	}
	if int64(width) > maxDecodedImagePixels/int64(height) {
		return nil, width, height
	}
	imageData, _, err := image.Decode(bytes.NewReader(data))
	if err != nil {
		return nil, width, height
	}
	bounds := imageData.Bounds()
	dstWidth, dstHeight := width, height
	if width > maxThumbnailEdge || height > maxThumbnailEdge {
		scale := float64(maxThumbnailEdge) / float64(width)
		if height > width {
			scale = float64(maxThumbnailEdge) / float64(height)
		}
		dstWidth = max(1, int(float64(width)*scale))
		dstHeight = max(1, int(float64(height)*scale))
	}
	dst := image.NewRGBA(image.Rect(0, 0, dstWidth, dstHeight))
	for y := 0; y < dstHeight; y++ {
		sourceY := bounds.Min.Y + y*height/dstHeight
		for x := 0; x < dstWidth; x++ {
			sourceX := bounds.Min.X + x*width/dstWidth
			converted := color.NRGBAModel.Convert(imageData.At(sourceX, sourceY)).(color.NRGBA)
			alpha := uint32(converted.A)
			// Composite transparent pixels against white for predictable JPEG previews.
			r := uint8((uint32(converted.R)*alpha + 255*(255-alpha)) / 255)
			g := uint8((uint32(converted.G)*alpha + 255*(255-alpha)) / 255)
			b := uint8((uint32(converted.B)*alpha + 255*(255-alpha)) / 255)
			dst.SetRGBA(x, y, color.RGBA{R: r, G: g, B: b, A: 255})
		}
	}
	var encoded bytes.Buffer
	if err := jpeg.Encode(&encoded, dst, &jpeg.Options{Quality: 82}); err != nil {
		return nil, width, height
	}
	return encoded.Bytes(), width, height
}

func max(a, b int) int {
	if a > b {
		return a
	}
	return b
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
