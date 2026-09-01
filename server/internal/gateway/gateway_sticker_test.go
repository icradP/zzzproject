package gateway

import (
	"testing"

	"github.com/icradp/zzz-im-server/internal/protocol"
)

func TestValidateStickerSegment(t *testing.T) {
	valid := protocol.MessageSegment{
		Type: "sticker",
		Data: map[string]interface{}{
			"pack_id":  "zzz-core",
			"asset_id": "corin-01",
			"version":  float64(1),
		},
	}
	if err := validateStickerSegment(valid); err != nil {
		t.Fatalf("valid sticker rejected: %v", err)
	}

	invalidCases := []protocol.MessageSegment{
		{Type: "sticker", Data: map[string]interface{}{"pack_id": "", "asset_id": "corin-01", "version": float64(1)}},
		{Type: "sticker", Data: map[string]interface{}{"pack_id": "zzz core", "asset_id": "corin-01", "version": float64(1)}},
		{Type: "sticker", Data: map[string]interface{}{"pack_id": "zzz-core", "asset_id": "../secret", "version": float64(1)}},
		{Type: "sticker", Data: map[string]interface{}{"pack_id": "zzz-core", "asset_id": "corin-01", "version": float64(1.5)}},
		{Type: "sticker", Data: map[string]interface{}{"pack_id": "zzz-core", "asset_id": "corin-01", "version": float64(1001)}},
	}
	for index, segment := range invalidCases {
		if err := validateStickerSegment(segment); err == nil {
			t.Fatalf("invalid sticker case %d was accepted", index)
		}
	}
}

func TestPushBodyIncludesStickerSummary(t *testing.T) {
	body := pushBody([]protocol.MessageSegment{
		{Type: "sticker", Data: map[string]interface{}{"pack_id": "zzz-core", "asset_id": "ellen-01", "version": float64(1)}},
	})
	if body != "[Sticker]" {
		t.Fatalf("unexpected push body %q", body)
	}
}
