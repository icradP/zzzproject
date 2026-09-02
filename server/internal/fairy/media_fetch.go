package fairy

import (
	"bytes"
	"context"
	"fmt"
	"image"
	_ "image/gif"
	_ "image/jpeg"
	_ "image/png"
	"io"
	"mime"
	"net"
	"net/http"
	"net/url"
	"strings"
	"time"

	_ "golang.org/x/image/webp"
)

const (
	maxMediaImageBytes = 8 * 1024 * 1024
	maxMediaImageTotal = 20 * 1024 * 1024
	maxMediaAudioBytes = 10 * 1024 * 1024
	maxMediaDimension  = 8192
	maxMediaPixels     = 40_000_000
	maxMediaRedirects  = 3
	mediaFetchTimeout  = 20 * time.Second
)

type mediaFetchFailureCode string

const (
	mediaFetchInvalid     mediaFetchFailureCode = "invalid_media"
	mediaFetchUnsafe      mediaFetchFailureCode = "unsafe_url"
	mediaFetchTooLarge    mediaFetchFailureCode = "too_large"
	mediaFetchUnsupported mediaFetchFailureCode = "unsupported_type"
	mediaFetchNetwork     mediaFetchFailureCode = "network_error"
)

type mediaFetchFailure struct {
	Code  mediaFetchFailureCode
	cause error
}

func (f *mediaFetchFailure) Error() string {
	if f == nil {
		return "media fetch failed"
	}
	return "Fairy media fetch failed with " + string(f.Code)
}

func (f *mediaFetchFailure) Unwrap() error {
	if f == nil {
		return nil
	}
	return f.cause
}

type fetchedMedia struct {
	Kind     mediaInputKind
	MIMEType string
	Name     string
	Data     []byte
}

type mediaResolver func(context.Context, string) ([]net.IPAddr, error)

type mediaFetcher struct {
	serverOrigin *url.URL
	resolve      mediaResolver
	dialer       *net.Dialer
}

func newMediaFetcher(serverURL string) (*mediaFetcher, error) {
	parsed, err := url.Parse(serverURL)
	if err != nil || parsed.Host == "" || parsed.User != nil || (parsed.Scheme != "ws" && parsed.Scheme != "wss") {
		return nil, fmt.Errorf("invalid Fairy server URL for media fetcher")
	}
	scheme := "http"
	if parsed.Scheme == "wss" {
		scheme = "https"
	}
	return &mediaFetcher{
		serverOrigin: &url.URL{Scheme: scheme, Host: parsed.Host},
		resolve:      net.DefaultResolver.LookupIPAddr,
		dialer:       &net.Dialer{Timeout: 10 * time.Second, KeepAlive: 30 * time.Second},
	}, nil
}

func (f *mediaFetcher) FetchAll(ctx context.Context, summary mediaInputSummary) ([]fetchedMedia, error) {
	if err := summary.validateBatch(); err != nil {
		return nil, &mediaFetchFailure{Code: mediaFetchInvalid, cause: err}
	}
	result := make([]fetchedMedia, 0, len(summary.inputs))
	total := 0
	for _, input := range summary.inputs {
		media, err := f.Fetch(ctx, input)
		if err != nil {
			return nil, err
		}
		total += len(media.Data)
		if input.Kind == mediaInputImage && total > maxMediaImageTotal {
			return nil, &mediaFetchFailure{Code: mediaFetchTooLarge}
		}
		result = append(result, media)
	}
	return result, nil
}

func (f *mediaFetcher) Fetch(ctx context.Context, input mediaInput) (fetchedMedia, error) {
	limit := maxMediaImageBytes
	if input.Kind == mediaInputRecord {
		limit = maxMediaAudioBytes
		if input.DurationMS > int64((2*time.Minute)/time.Millisecond) {
			return fetchedMedia{}, &mediaFetchFailure{Code: mediaFetchTooLarge}
		}
	}
	if input.Size > int64(limit) {
		return fetchedMedia{}, &mediaFetchFailure{Code: mediaFetchTooLarge}
	}
	target, err := f.resolveInputURL(input)
	if err != nil {
		return fetchedMedia{}, err
	}
	fetchContext, cancel := context.WithTimeout(ctx, mediaFetchTimeout)
	defer cancel()
	transport := &http.Transport{
		Proxy:                  nil,
		DialContext:            f.dialContext,
		ForceAttemptHTTP2:      true,
		TLSHandshakeTimeout:    10 * time.Second,
		ResponseHeaderTimeout:  10 * time.Second,
		IdleConnTimeout:        30 * time.Second,
		MaxResponseHeaderBytes: 64 * 1024,
	}
	defer transport.CloseIdleConnections()
	client := &http.Client{
		Transport: transport,
		CheckRedirect: func(request *http.Request, previous []*http.Request) error {
			if len(previous) >= maxMediaRedirects {
				return fmt.Errorf("too many media redirects")
			}
			return f.validateAbsoluteTarget(input.Kind, request.URL)
		},
	}
	request, err := http.NewRequestWithContext(fetchContext, http.MethodGet, target.String(), nil)
	if err != nil {
		return fetchedMedia{}, &mediaFetchFailure{Code: mediaFetchInvalid, cause: err}
	}
	request.Header.Set("Accept", mediaAcceptHeader(input.Kind))
	request.Header.Set("User-Agent", "ZZZ-IM-Fairy/2.0")
	response, err := client.Do(request)
	if err != nil {
		code := mediaFetchNetwork
		if strings.Contains(err.Error(), "unsafe") || strings.Contains(err.Error(), "private") || strings.Contains(err.Error(), "redirect") {
			code = mediaFetchUnsafe
		}
		return fetchedMedia{}, &mediaFetchFailure{Code: code, cause: err}
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return fetchedMedia{}, &mediaFetchFailure{Code: mediaFetchNetwork}
	}
	if response.ContentLength > int64(limit) {
		return fetchedMedia{}, &mediaFetchFailure{Code: mediaFetchTooLarge}
	}
	data, err := io.ReadAll(io.LimitReader(response.Body, int64(limit)+1))
	if err != nil {
		return fetchedMedia{}, &mediaFetchFailure{Code: mediaFetchNetwork, cause: err}
	}
	if len(data) == 0 {
		return fetchedMedia{}, &mediaFetchFailure{Code: mediaFetchInvalid}
	}
	if len(data) > limit {
		return fetchedMedia{}, &mediaFetchFailure{Code: mediaFetchTooLarge}
	}
	mimeType, err := validateFetchedMedia(input.Kind, response.Header.Get("Content-Type"), data)
	if err != nil {
		return fetchedMedia{}, err
	}
	name := strings.TrimSpace(input.Name)
	if name == "" {
		name = mediaFileName(input.Kind, mimeType)
	}
	return fetchedMedia{Kind: input.Kind, MIMEType: mimeType, Name: safeMediaUploadName(name, mimeType), Data: data}, nil
}

func (f *mediaFetcher) resolveInputURL(input mediaInput) (*url.URL, error) {
	raw := input.URL
	if raw == "" || len(raw) > 2048 || raw != strings.TrimSpace(raw) {
		return nil, &mediaFetchFailure{Code: mediaFetchInvalid}
	}
	if strings.HasPrefix(raw, "/files/") {
		parsed, err := url.ParseRequestURI(raw)
		if err != nil || parsed.IsAbs() || parsed.Host != "" || parsed.RawQuery != "" || parsed.Fragment != "" {
			return nil, &mediaFetchFailure{Code: mediaFetchInvalid}
		}
		return f.serverOrigin.ResolveReference(parsed), nil
	}
	parsed, err := url.ParseRequestURI(raw)
	if err != nil || parsed.Host == "" || parsed.User != nil || parsed.Fragment != "" {
		return nil, &mediaFetchFailure{Code: mediaFetchInvalid}
	}
	sameOrigin := sameURLOrigin(parsed, f.serverOrigin)
	if !sameOrigin && input.Kind == mediaInputRecord {
		return nil, &mediaFetchFailure{Code: mediaFetchUnsafe}
	}
	if err := f.validateAbsoluteTarget(input.Kind, parsed); err != nil {
		return nil, &mediaFetchFailure{Code: mediaFetchUnsafe, cause: err}
	}
	return parsed, nil
}

func (f *mediaFetcher) validateAbsoluteTarget(kind mediaInputKind, target *url.URL) error {
	if target == nil || target.Host == "" || target.User != nil || target.Fragment != "" {
		return fmt.Errorf("invalid media target")
	}
	if sameURLOrigin(target, f.serverOrigin) {
		if !strings.HasPrefix(target.EscapedPath(), "/files/") || target.RawQuery != "" {
			return fmt.Errorf("unsafe server media target")
		}
		return nil
	}
	if kind != mediaInputImage || target.Scheme != "https" {
		return fmt.Errorf("unsafe media target")
	}
	return nil
}

func (f *mediaFetcher) dialContext(ctx context.Context, network, address string) (net.Conn, error) {
	host, port, err := net.SplitHostPort(address)
	if err != nil {
		return nil, err
	}
	allowPrivate := strings.EqualFold(strings.TrimSuffix(host, "."), strings.TrimSuffix(f.serverOrigin.Hostname(), ".")) &&
		port == mediaOriginPort(f.serverOrigin)
	addresses := make([]net.IPAddr, 0, 1)
	if parsed := net.ParseIP(host); parsed != nil {
		addresses = append(addresses, net.IPAddr{IP: parsed})
	} else {
		addresses, err = f.resolve(ctx, host)
		if err != nil {
			return nil, err
		}
	}
	for _, candidate := range addresses {
		if !allowPrivate && unsafeMediaIP(candidate.IP) {
			continue
		}
		return f.dialer.DialContext(ctx, network, net.JoinHostPort(candidate.IP.String(), port))
	}
	return nil, fmt.Errorf("unsafe or unresolved media address")
}

func mediaOriginPort(origin *url.URL) string {
	if origin.Port() != "" {
		return origin.Port()
	}
	if origin.Scheme == "https" {
		return "443"
	}
	return "80"
}

func unsafeMediaIP(ip net.IP) bool {
	return ip == nil || !ip.IsGlobalUnicast() || ip.IsPrivate() || ip.IsLoopback() ||
		ip.IsLinkLocalUnicast() || ip.IsLinkLocalMulticast() || ip.IsUnspecified() || ip.IsMulticast()
}

func sameURLOrigin(left, right *url.URL) bool {
	return left != nil && right != nil && strings.EqualFold(left.Scheme, right.Scheme) && strings.EqualFold(left.Host, right.Host)
}

func validateFetchedMedia(kind mediaInputKind, contentType string, data []byte) (string, error) {
	headerType, _, _ := mime.ParseMediaType(contentType)
	detected := http.DetectContentType(data)
	if kind == mediaInputImage {
		if !allowedImageMIME(detected) {
			return "", &mediaFetchFailure{Code: mediaFetchUnsupported}
		}
		config, _, err := image.DecodeConfig(bytes.NewReader(data))
		if err != nil || config.Width <= 0 || config.Height <= 0 || config.Width > maxMediaDimension || config.Height > maxMediaDimension ||
			int64(config.Width)*int64(config.Height) > maxMediaPixels {
			return "", &mediaFetchFailure{Code: mediaFetchUnsupported, cause: err}
		}
		return detected, nil
	}
	if !allowedAudioMIME(headerType) || !matchesAudioSignature(headerType, data) {
		return "", &mediaFetchFailure{Code: mediaFetchUnsupported}
	}
	return headerType, nil
}

func allowedImageMIME(value string) bool {
	switch value {
	case "image/jpeg", "image/png", "image/gif", "image/webp":
		return true
	default:
		return false
	}
}

func allowedAudioMIME(value string) bool {
	switch value {
	case "audio/webm", "audio/ogg", "audio/mpeg", "audio/mp4", "audio/wav", "audio/x-wav":
		return true
	default:
		return false
	}
}

func matchesAudioSignature(mimeType string, data []byte) bool {
	switch mimeType {
	case "audio/webm":
		return len(data) >= 4 && bytes.Equal(data[:4], []byte{0x1a, 0x45, 0xdf, 0xa3})
	case "audio/ogg":
		return len(data) >= 4 && string(data[:4]) == "OggS"
	case "audio/mpeg":
		return len(data) >= 3 && string(data[:3]) == "ID3" || len(data) >= 2 && data[0] == 0xff && data[1]&0xe0 == 0xe0
	case "audio/mp4":
		return len(data) >= 12 && string(data[4:8]) == "ftyp"
	case "audio/wav", "audio/x-wav":
		return len(data) >= 12 && string(data[:4]) == "RIFF" && string(data[8:12]) == "WAVE"
	default:
		return false
	}
}

func mediaAcceptHeader(kind mediaInputKind) string {
	if kind == mediaInputRecord {
		return "audio/webm,audio/ogg,audio/mpeg,audio/mp4,audio/wav"
	}
	return "image/jpeg,image/png,image/gif,image/webp"
}

func mediaFileName(kind mediaInputKind, mimeType string) string {
	extension := map[string]string{
		"image/jpeg": ".jpg", "image/png": ".png", "image/gif": ".gif", "image/webp": ".webp",
		"audio/webm": ".webm", "audio/ogg": ".ogg", "audio/mpeg": ".mp3", "audio/mp4": ".m4a",
		"audio/wav": ".wav", "audio/x-wav": ".wav",
	}[mimeType]
	prefix := "image"
	if kind == mediaInputRecord {
		prefix = "audio"
	}
	return prefix + extension
}
