package push

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"net/url"

	webpush "github.com/SherClockHolmes/webpush-go"
	"github.com/icradp/zzz-im-server/internal/store"
)

// Service sends standards-based Web Push notifications using VAPID.
type Service struct {
	publicKey  string
	privateKey string
	subject    string
}

func NewService(publicKey, privateKey, subject string) *Service {
	return &Service{
		publicKey:  publicKey,
		privateKey: privateKey,
		subject:    subject,
	}
}

func (s *Service) Enabled() bool {
	return s != nil && s.publicKey != "" && s.privateKey != "" && s.subject != ""
}

func (s *Service) PublicKey() string {
	if !s.Enabled() {
		return ""
	}
	return s.publicKey
}

// Send returns expired=true when the push provider has invalidated the endpoint.
func (s *Service) Send(
	ctx context.Context,
	subscription *store.PushSubscription,
	payload []byte,
) (expired bool, err error) {
	if !s.Enabled() {
		return false, fmt.Errorf("web push is not configured")
	}
	if err := validateEndpoint(subscription.Endpoint); err != nil {
		return false, err
	}

	response, err := webpush.SendNotificationWithContext(
		ctx,
		payload,
		&webpush.Subscription{
			Endpoint: subscription.Endpoint,
			Keys: webpush.Keys{
				P256dh: subscription.P256DH,
				Auth:   subscription.Auth,
			},
		},
		&webpush.Options{
			Subscriber:      s.subject,
			VAPIDPublicKey:  s.publicKey,
			VAPIDPrivateKey: s.privateKey,
			TTL:             24 * 60 * 60,
			Urgency:         webpush.UrgencyNormal,
		},
	)
	if err != nil {
		return false, err
	}
	defer response.Body.Close()
	_, _ = io.Copy(io.Discard, response.Body)

	if response.StatusCode == http.StatusNotFound || response.StatusCode == http.StatusGone {
		return true, nil
	}
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return false, fmt.Errorf("web push provider returned status %d", response.StatusCode)
	}
	return false, nil
}

func validateEndpoint(endpoint string) error {
	parsed, err := url.ParseRequestURI(endpoint)
	if err != nil || parsed.Scheme != "https" || parsed.Host == "" || parsed.User != nil {
		return fmt.Errorf("invalid Web Push endpoint")
	}
	return nil
}
