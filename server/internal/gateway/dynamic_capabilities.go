package gateway

import (
	"encoding/json"
	"fmt"
	"strings"

	"github.com/icradp/zzz-im-server/internal/protocol"
)

const (
	maxCapabilityPayloadBytes = 16 * 1024
	maxCapabilityVersions     = 16
	maxCapabilityComponents   = 128
	maxCapabilityVersionBytes = 32
	maxCapabilityNameBytes    = 64
	dynamicUpgradeFallback    = "此内容需要升级客户端后查看"
)

func parseClientCapabilities(value interface{}) (protocol.Capabilities, error) {
	if value == nil {
		return protocol.Capabilities{}, nil
	}
	encoded, err := json.Marshal(value)
	if err != nil || len(encoded) > maxCapabilityPayloadBytes {
		return protocol.Capabilities{}, fmt.Errorf("capabilities are invalid")
	}
	var capabilities protocol.Capabilities
	if err := json.Unmarshal(encoded, &capabilities); err != nil {
		return protocol.Capabilities{}, fmt.Errorf("capabilities are invalid")
	}
	if !validCapabilityVersion(capabilities.ProtocolVersion) {
		return protocol.Capabilities{}, fmt.Errorf("protocol_version is invalid")
	}
	dynamic := capabilities.DynamicContent
	if dynamic == nil {
		return capabilities, nil
	}
	if len(dynamic.SchemaVersions) == 0 || len(dynamic.SchemaVersions) > maxCapabilityVersions {
		return protocol.Capabilities{}, fmt.Errorf("dynamic schema_versions are invalid")
	}
	if !validCapabilityVersion(dynamic.ComponentVersion) {
		return protocol.Capabilities{}, fmt.Errorf("dynamic component_version is invalid")
	}
	if len(dynamic.Components) == 0 || len(dynamic.Components) > maxCapabilityComponents {
		return protocol.Capabilities{}, fmt.Errorf("dynamic components are invalid")
	}

	dynamic.SchemaVersions, err = normalizedCapabilityValues(
		dynamic.SchemaVersions,
		maxCapabilityVersionBytes,
		validCapabilityVersion,
	)
	if err != nil {
		return protocol.Capabilities{}, fmt.Errorf("dynamic schema_versions are invalid")
	}
	dynamic.Components, err = normalizedCapabilityValues(
		dynamic.Components,
		maxCapabilityNameBytes,
		validCapabilityName,
	)
	if err != nil {
		return protocol.Capabilities{}, fmt.Errorf("dynamic components are invalid")
	}
	return capabilities, nil
}

func negotiateCapabilities(client protocol.Capabilities) protocol.Capabilities {
	if client.ProtocolVersion != protocol.CurrentProtocolVersion {
		return protocol.Capabilities{}
	}
	result := protocol.Capabilities{ProtocolVersion: protocol.CurrentProtocolVersion}
	dynamic := client.DynamicContent
	if dynamic == nil || dynamic.ComponentVersion != protocol.CurrentDynamicComponentVersion {
		return result
	}
	schemas := intersectCapabilityValues(
		dynamic.SchemaVersions,
		protocol.CurrentServerCapabilities().DynamicContent.SchemaVersions,
	)
	if len(schemas) == 0 {
		return result
	}
	result.DynamicContent = &protocol.DynamicContentCapabilities{
		SchemaVersions:    schemas,
		ComponentVersion:  protocol.CurrentDynamicComponentVersion,
		Components:        append([]string(nil), dynamic.Components...),
		Events:            dynamic.Events,
		NodeIDPatch:       dynamic.NodeIDPatch,
		ContentOperations: dynamic.ContentOperations,
	}
	return result
}

func normalizedCapabilityValues(values []string, maxBytes int, valid func(string) bool) ([]string, error) {
	seen := make(map[string]struct{}, len(values))
	result := make([]string, 0, len(values))
	for _, value := range values {
		value = strings.TrimSpace(value)
		if len(value) == 0 || len(value) > maxBytes || !valid(value) {
			return nil, fmt.Errorf("invalid capability value")
		}
		if _, exists := seen[value]; exists {
			continue
		}
		seen[value] = struct{}{}
		result = append(result, value)
	}
	if len(result) == 0 {
		return nil, fmt.Errorf("empty capability values")
	}
	return result, nil
}

func validCapabilityVersion(value string) bool {
	if len(value) == 0 || len(value) > maxCapabilityVersionBytes {
		return false
	}
	for _, character := range value {
		if character >= 'a' && character <= 'z' || character >= 'A' && character <= 'Z' ||
			character >= '0' && character <= '9' || character == '.' || character == '-' {
			continue
		}
		return false
	}
	return true
}

func validCapabilityName(value string) bool {
	if len(value) == 0 || len(value) > maxCapabilityNameBytes {
		return false
	}
	for _, character := range value {
		if character >= 'a' && character <= 'z' || character >= 'A' && character <= 'Z' ||
			character >= '0' && character <= '9' || character == '_' || character == '-' ||
			character == '.' || character == ':' {
			continue
		}
		return false
	}
	return true
}

func intersectCapabilityValues(left, right []string) []string {
	allowed := make(map[string]struct{}, len(right))
	for _, value := range right {
		allowed[value] = struct{}{}
	}
	result := make([]string, 0, len(left))
	for _, value := range left {
		if _, exists := allowed[value]; exists {
			result = append(result, value)
		}
	}
	return result
}

func hasCapabilitySensitiveSegment(segments []protocol.MessageSegment) bool {
	for _, segment := range segments {
		switch segment.Type {
		case "dynamic_content", "dynamic_update", "dynamic_replace", "dynamic_remove", "dynamic_event":
			return true
		}
	}
	return false
}

func segmentsForClient(capabilities protocol.Capabilities, segments []protocol.MessageSegment) ([]protocol.MessageSegment, bool) {
	if !hasCapabilitySensitiveSegment(segments) {
		return segments, true
	}
	dynamic := capabilities.DynamicContent
	result := make([]protocol.MessageSegment, 0, len(segments))
	for _, segment := range segments {
		switch segment.Type {
		case "dynamic_content":
			if supportsDynamicContentSegment(dynamic, segment) {
				result = append(result, segment)
			} else {
				result = append(result, dynamicFallbackSegment(segment))
			}
		case "dynamic_update":
			if dynamic == nil || !dynamic.NodeIDPatch {
				return nil, false
			}
			result = append(result, segment)
		case "dynamic_replace":
			if dynamic == nil || !dynamic.ContentOperations {
				return nil, false
			}
			replacement, err := dynamicReplacementSegment(segment)
			if err != nil || !supportsDynamicContentSegment(dynamic, replacement) {
				return nil, false
			}
			result = append(result, segment)
		case "dynamic_remove":
			if dynamic == nil || !dynamic.ContentOperations {
				return nil, false
			}
			result = append(result, segment)
		case "dynamic_event":
			if dynamic == nil || !dynamic.Events {
				return nil, false
			}
			result = append(result, segment)
		default:
			result = append(result, segment)
		}
	}
	return result, true
}

func dynamicReplacementSegment(segment protocol.MessageSegment) (protocol.MessageSegment, error) {
	_, _, content, err := parseDynamicReplaceData(segment.Data)
	if err != nil {
		return protocol.MessageSegment{}, err
	}
	return protocol.DynamicContentSegment(content), nil
}

func clientMessageSegments(client *Client, segments []protocol.MessageSegment) []protocol.MessageSegment {
	result, deliver := segmentsForClient(client.capabilities, segments)
	if !deliver {
		return []protocol.MessageSegment{}
	}
	return result
}

func marshalClientEvent(client *Client, event protocol.MessageEvent) ([]byte, bool) {
	segments, deliver := segmentsForClient(client.capabilities, event.Message)
	if !deliver {
		return nil, false
	}
	event.Message = segments
	data, err := json.Marshal(event)
	if err != nil {
		return nil, false
	}
	return data, true
}

func supportsDynamicContentSegment(capabilities *protocol.DynamicContentCapabilities, segment protocol.MessageSegment) bool {
	if capabilities == nil {
		return false
	}
	schema, err := dynamicSchemaFromData(segment.Data)
	if err != nil || !containsCapability(capabilities.SchemaVersions, stringValue(schema["version"])) {
		return false
	}
	if capabilities.ComponentVersion != protocol.CurrentDynamicComponentVersion {
		return false
	}
	components := make(map[string]struct{}, len(capabilities.Components))
	for _, component := range capabilities.Components {
		components[component] = struct{}{}
	}
	return dynamicTreeUsesOnlyComponents(schema["tree"], components)
}

func dynamicTreeUsesOnlyComponents(value interface{}, components map[string]struct{}) bool {
	node, ok := value.(map[string]interface{})
	if !ok {
		return false
	}
	typeName, _ := node["type"].(string)
	if _, supported := components[typeName]; !supported {
		return false
	}
	children, _ := node["children"].([]interface{})
	for _, child := range children {
		if !dynamicTreeUsesOnlyComponents(child, components) {
			return false
		}
	}
	return true
}

func dynamicFallbackSegment(segment protocol.MessageSegment) protocol.MessageSegment {
	text := dynamicUpgradeFallback
	if schema, err := dynamicSchemaFromData(segment.Data); err == nil {
		if fallback, ok := schema["fallback"].(map[string]interface{}); ok {
			if content, ok := fallback["content"].(string); ok && strings.TrimSpace(content) != "" {
				text = content
			}
		}
	}
	return protocol.TextSegment(text)
}

func containsCapability(values []string, target string) bool {
	for _, value := range values {
		if value == target {
			return true
		}
	}
	return false
}

func stringValue(value interface{}) string {
	result, _ := value.(string)
	return result
}
