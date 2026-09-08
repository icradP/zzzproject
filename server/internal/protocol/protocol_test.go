package protocol

import (
	"encoding/json"
	"testing"
)

func TestAuthParamsOmitsAbsentCapabilities(t *testing.T) {
	encoded, err := json.Marshal(AuthParams{UserID: "alice", DeviceID: "test"})
	if err != nil {
		t.Fatal(err)
	}
	var decoded map[string]interface{}
	if err := json.Unmarshal(encoded, &decoded); err != nil {
		t.Fatal(err)
	}
	if _, exists := decoded["capabilities"]; exists {
		t.Fatalf("zero-value auth advertised invalid capabilities: %s", encoded)
	}
}

func TestAuthParamsEncodesAdvertisedCapabilities(t *testing.T) {
	capabilities := CurrentServerCapabilities()
	encoded, err := json.Marshal(AuthParams{
		UserID:       "alice",
		DeviceID:     "test",
		Capabilities: &capabilities,
	})
	if err != nil {
		t.Fatal(err)
	}
	var decoded map[string]interface{}
	if err := json.Unmarshal(encoded, &decoded); err != nil {
		t.Fatal(err)
	}
	advertised, ok := decoded["capabilities"].(map[string]interface{})
	if !ok || advertised["protocol_version"] != CurrentProtocolVersion {
		t.Fatalf("auth capabilities were not encoded: %s", encoded)
	}
}
