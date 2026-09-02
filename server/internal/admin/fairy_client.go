package admin

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strings"
	"time"
)

type FairyController interface {
	Request(ctx context.Context, method string, body []byte) (int, []byte, error)
}

type FairyHTTPController struct {
	endpoint string
	token    string
	client   *http.Client
}

func NewFairyHTTPController(rawURL, token string) (*FairyHTTPController, error) {
	parsed, err := url.Parse(strings.TrimSpace(rawURL))
	if err != nil || parsed.Scheme != "http" || parsed.Host == "" || parsed.User != nil || parsed.RawQuery != "" || parsed.Fragment != "" {
		return nil, fmt.Errorf("Fairy admin URL must be an absolute loopback HTTP URL")
	}
	host := parsed.Hostname()
	address := net.ParseIP(host)
	if host != "localhost" && (address == nil || !address.IsLoopback()) {
		return nil, fmt.Errorf("Fairy admin URL must use a loopback host")
	}
	if strings.TrimSpace(token) == "" {
		return nil, fmt.Errorf("Fairy admin token is required")
	}
	parsed.Path = strings.TrimRight(parsed.Path, "/") + "/config"
	return &FairyHTTPController{
		endpoint: parsed.String(),
		token:    strings.TrimSpace(token),
		client: &http.Client{
			Timeout: 8 * time.Second,
			CheckRedirect: func(*http.Request, []*http.Request) error {
				return http.ErrUseLastResponse
			},
		},
	}, nil
}

func (c *FairyHTTPController) Request(ctx context.Context, method string, body []byte) (int, []byte, error) {
	if method != http.MethodGet && method != http.MethodPatch {
		return 0, nil, fmt.Errorf("unsupported Fairy admin method")
	}
	request, err := http.NewRequestWithContext(ctx, method, c.endpoint, bytes.NewReader(body))
	if err != nil {
		return 0, nil, err
	}
	request.Header.Set("Accept", "application/json")
	request.Header.Set("Authorization", "Bearer "+c.token)
	if len(body) > 0 {
		request.Header.Set("Content-Type", "application/json")
	}
	response, err := c.client.Do(request)
	if err != nil {
		return 0, nil, fmt.Errorf("contact Fairy admin service: %w", err)
	}
	defer response.Body.Close()
	payload, err := io.ReadAll(io.LimitReader(response.Body, 64*1024))
	if err != nil {
		return 0, nil, fmt.Errorf("read Fairy admin response: %w", err)
	}
	if !json.Valid(payload) {
		return 0, nil, fmt.Errorf("Fairy admin service returned invalid JSON")
	}
	return response.StatusCode, payload, nil
}
