package gateway

import (
	"encoding/json"
	"fmt"
	"net/url"
	"strings"
	"unicode/utf8"

	"github.com/icradp/zzz-im-server/internal/protocol"
)

const (
	maxDynamicContentBytes = 512 * 1024
	maxDynamicNodes        = 100
	maxDynamicDepth        = 10
	maxDynamicChildren     = 50
	maxDynamicTextLength   = 10000
	maxDynamicIdentifier   = 128
	maxDynamicImages       = 20
)

var allowedDynamicEvents = map[string]struct{}{
	"click":  {},
	"tap":    {},
	"submit": {},
	"change": {},
}

func validateDynamicContentSegment(segment protocol.MessageSegment) error {
	if segment.Type != "dynamic_content" {
		return nil
	}
	encoded, err := json.Marshal(segment.Data)
	if err != nil {
		return fmt.Errorf("dynamic content is not valid JSON")
	}
	if len(encoded) > maxDynamicContentBytes {
		return fmt.Errorf("dynamic content is too large")
	}
	schema, err := dynamicSchemaFromData(segment.Data)
	if err != nil {
		return err
	}
	return validateDynamicSchema(schema)
}

func validateDynamicEventSegment(segment protocol.MessageSegment) error {
	if segment.Type != "dynamic_event" {
		return nil
	}
	for _, key := range []string{"message_id", "content_id", "node_id"} {
		value, _ := segment.Data[key].(string)
		if !validDynamicIdentifier(value) {
			return fmt.Errorf("dynamic event %s is invalid", key)
		}
	}
	event, _ := segment.Data["event"].(string)
	if _, ok := allowedDynamicEvents[event]; !ok {
		return fmt.Errorf("dynamic event type is not allowed")
	}
	if action, exists := segment.Data["action"]; exists {
		value, ok := action.(string)
		if !ok || len(value) > maxDynamicIdentifier {
			return fmt.Errorf("dynamic event action is invalid")
		}
	}
	if payload, exists := segment.Data["payload"]; exists {
		if err := validateDynamicValues(payload, "payload", 0); err != nil {
			return err
		}
	}
	return nil
}

func validateDynamicUpdateSegment(segment protocol.MessageSegment) error {
	if segment.Type != "dynamic_update" {
		return nil
	}
	encoded, err := json.Marshal(segment.Data)
	if err != nil {
		return fmt.Errorf("dynamic update is not valid JSON")
	}
	if len(encoded) > maxDynamicContentBytes {
		return fmt.Errorf("dynamic update is too large")
	}
	_, _, _, err = parseDynamicUpdateData(segment.Data)
	return err
}

func dynamicSchemaFromData(data map[string]interface{}) (map[string]interface{}, error) {
	var schema map[string]interface{}
	switch nested := data["content"].(type) {
	case string:
		if err := json.Unmarshal([]byte(nested), &schema); err != nil {
			return nil, fmt.Errorf("dynamic content schema is not valid JSON")
		}
	case map[string]interface{}:
		schema = cloneDynamicMap(nested)
	default:
		switch nested := data["schema"].(type) {
		case string:
			if err := json.Unmarshal([]byte(nested), &schema); err != nil {
				return nil, fmt.Errorf("dynamic content schema is not valid JSON")
			}
		case map[string]interface{}:
			schema = cloneDynamicMap(nested)
		default:
			schema = cloneDynamicMap(data)
		}
	}
	if schema == nil {
		return nil, fmt.Errorf("dynamic content schema is not an object")
	}
	// Transport metadata may sit next to a nested schema for compact events.
	for _, key := range []string{"id", "version", "source", "tree", "fallback", "metadata"} {
		if _, exists := schema[key]; !exists {
			if value, exists := data[key]; exists {
				schema[key] = value
			}
		}
	}
	return schema, nil
}

func validateDynamicSchema(schema map[string]interface{}) error {
	id, _ := schema["id"].(string)
	if !validDynamicIdentifier(id) {
		return fmt.Errorf("dynamic content id is invalid")
	}
	version, _ := schema["version"].(string)
	if strings.TrimSpace(version) == "" || len(version) > 32 {
		return fmt.Errorf("dynamic content version is invalid")
	}
	source, _ := schema["source"].(string)
	switch source {
	case "ai", "user", "system", "plugin", "server":
	default:
		return fmt.Errorf("dynamic content source is invalid")
	}
	tree, ok := schema["tree"].(map[string]interface{})
	if !ok {
		return fmt.Errorf("dynamic content tree is missing")
	}
	state := &dynamicValidationState{ids: make(map[string]struct{})}
	if err := validateDynamicNode(tree, "tree", 0, state); err != nil {
		return err
	}
	if fallback, exists := schema["fallback"]; exists {
		fallbackMap, ok := fallback.(map[string]interface{})
		if !ok {
			return fmt.Errorf("dynamic fallback is invalid")
		}
		content, _ := fallbackMap["content"].(string)
		if len([]rune(content)) > maxDynamicTextLength {
			return fmt.Errorf("dynamic fallback is too long")
		}
	}
	if metadata, exists := schema["metadata"]; exists {
		if err := validateDynamicValues(metadata, "metadata", 0); err != nil {
			return err
		}
	}
	return nil
}

type dynamicValidationState struct {
	ids    map[string]struct{}
	count  int
	images int
}

func validateDynamicNode(node map[string]interface{}, path string, depth int, state *dynamicValidationState) error {
	state.count++
	if state.count > maxDynamicNodes {
		return fmt.Errorf("dynamic content node limit exceeded at %s", path)
	}
	if depth > maxDynamicDepth {
		return fmt.Errorf("dynamic content tree depth exceeded at %s", path)
	}
	id, _ := node["id"].(string)
	if !validDynamicIdentifier(id) {
		return fmt.Errorf("dynamic node id is invalid at %s", path)
	}
	if _, exists := state.ids[id]; exists {
		return fmt.Errorf("dynamic node id %q is duplicated", id)
	}
	state.ids[id] = struct{}{}
	typeName, _ := node["type"].(string)
	if strings.TrimSpace(typeName) == "" || len(typeName) > 64 {
		return fmt.Errorf("dynamic node type is invalid at %s", path)
	}
	props, exists := node["props"]
	if exists {
		if _, ok := props.(map[string]interface{}); !ok {
			return fmt.Errorf("dynamic node props are invalid at %s", path)
		}
		if err := validateDynamicValues(props, path+".props", 0); err != nil {
			return err
		}
	}
	if typeName == "image" {
		state.images++
		if state.images > maxDynamicImages {
			return fmt.Errorf("dynamic content image limit exceeded at %s", path)
		}
		propsMap, _ := props.(map[string]interface{})
		if rawURL, exists := propsMap["url"]; exists {
			imageURL, ok := rawURL.(string)
			if !ok || !validDynamicHTTPSURL(imageURL) {
				return fmt.Errorf("dynamic image URL must use HTTPS")
			}
		}
	}
	if events, exists := node["events"]; exists {
		eventMap, ok := events.(map[string]interface{})
		if !ok {
			return fmt.Errorf("dynamic node events are invalid at %s", path)
		}
		for event, definition := range eventMap {
			if _, allowed := allowedDynamicEvents[event]; !allowed {
				return fmt.Errorf("dynamic event %q is not allowed", event)
			}
			definitionMap, ok := definition.(map[string]interface{})
			if !ok {
				return fmt.Errorf("dynamic event %q is invalid", event)
			}
			if action, exists := definitionMap["action"]; exists {
				value, ok := action.(string)
				if !ok || len(value) > maxDynamicIdentifier {
					return fmt.Errorf("dynamic event action is invalid")
				}
			}
		}
	}
	children, exists := node["children"]
	if !exists {
		return nil
	}
	childList, ok := children.([]interface{})
	if !ok || len(childList) > maxDynamicChildren {
		return fmt.Errorf("dynamic node children are invalid at %s", path)
	}
	for index, rawChild := range childList {
		child, ok := rawChild.(map[string]interface{})
		if !ok {
			return fmt.Errorf("dynamic child is invalid at %s.children[%d]", path, index)
		}
		if err := validateDynamicNode(child, fmt.Sprintf("%s.children[%d]", path, index), depth+1, state); err != nil {
			return err
		}
	}
	return nil
}

func validateDynamicValues(value interface{}, path string, depth int) error {
	if depth > maxDynamicDepth {
		return fmt.Errorf("dynamic value depth exceeded at %s", path)
	}
	switch current := value.(type) {
	case string:
		if len([]rune(current)) > maxDynamicTextLength {
			return fmt.Errorf("dynamic text is too long at %s", path)
		}
	case map[string]interface{}:
		for key, child := range current {
			if err := validateDynamicValues(child, path+"."+key, depth+1); err != nil {
				return err
			}
		}
	case []interface{}:
		if len(current) > maxDynamicChildren {
			return fmt.Errorf("dynamic value list is too long at %s", path)
		}
		for index, child := range current {
			if err := validateDynamicValues(child, fmt.Sprintf("%s[%d]", path, index), depth+1); err != nil {
				return err
			}
		}
	}
	return nil
}

func validDynamicHTTPSURL(raw string) bool {
	if raw == "" || len(raw) > 2048 || raw != strings.TrimSpace(raw) || !utf8.ValidString(raw) {
		return false
	}
	parsed, err := url.ParseRequestURI(raw)
	return err == nil && parsed.Scheme == "https" && parsed.Host != "" && parsed.User == nil
}

func validDynamicIdentifier(value string) bool {
	return strings.TrimSpace(value) != "" && len(value) <= maxDynamicIdentifier && utf8.ValidString(value)
}

func parseDynamicUpdateData(data map[string]interface{}) (string, string, []map[string]interface{}, error) {
	if nested, ok := data["update"].(map[string]interface{}); ok {
		merged := cloneDynamicMap(nested)
		for _, key := range []string{"message_id", "content_id", "patches"} {
			if _, exists := merged[key]; !exists {
				if value, exists := data[key]; exists {
					merged[key] = value
				}
			}
		}
		data = merged
	}
	messageID, _ := data["message_id"].(string)
	contentID, _ := data["content_id"].(string)
	if !validDynamicIdentifier(messageID) || !validDynamicIdentifier(contentID) {
		return "", "", nil, fmt.Errorf("dynamic update message_id or content_id is invalid")
	}
	rawPatches, ok := data["patches"].([]interface{})
	if !ok || len(rawPatches) == 0 || len(rawPatches) > maxDynamicNodes {
		return "", "", nil, fmt.Errorf("dynamic update patches are invalid")
	}
	patches := make([]map[string]interface{}, 0, len(rawPatches))
	for index, raw := range rawPatches {
		patch, ok := raw.(map[string]interface{})
		if !ok {
			return "", "", nil, fmt.Errorf("dynamic update patch %d is invalid", index)
		}
		operation, _ := patch["operation"].(string)
		nodeID, _ := patch["node_id"].(string)
		if operation != "create" && operation != "update" && operation != "replace" && operation != "remove" {
			return "", "", nil, fmt.Errorf("dynamic update operation is invalid")
		}
		if !validDynamicIdentifier(nodeID) {
			return "", "", nil, fmt.Errorf("dynamic update node_id is invalid")
		}
		if rawIndex, exists := patch["index"]; exists {
			indexValue, ok := exactInt64(rawIndex)
			if !ok || indexValue < 0 || indexValue > maxDynamicChildren {
				return "", "", nil, fmt.Errorf("dynamic update index is invalid")
			}
		}
		if operation == "create" {
			parentID, _ := patch["parent_node_id"].(string)
			if !validDynamicIdentifier(parentID) {
				return "", "", nil, fmt.Errorf("dynamic create parent_node_id is required")
			}
		}
		if operation == "update" {
			if props, exists := patch["props"]; exists {
				if _, ok := props.(map[string]interface{}); !ok {
					return "", "", nil, fmt.Errorf("dynamic update props are invalid")
				}
				if err := validateDynamicValues(props, "patch.props", 0); err != nil {
					return "", "", nil, err
				}
			}
		}
		if operation == "create" || operation == "replace" {
			node, ok := patch["node"].(map[string]interface{})
			if !ok {
				return "", "", nil, fmt.Errorf("dynamic %s patch requires node", operation)
			}
			createdID, _ := node["id"].(string)
			if createdID != nodeID {
				return "", "", nil, fmt.Errorf("dynamic patch node id does not match node_id")
			}
		}
		patches = append(patches, patch)
	}
	return messageID, contentID, patches, nil
}

func applyDynamicUpdateToSegments(segments []protocol.MessageSegment, data map[string]interface{}) ([]protocol.MessageSegment, string, error) {
	messageID, contentID, patches, err := parseDynamicUpdateData(data)
	if err != nil {
		return nil, "", err
	}
	dynamicIndex := -1
	var schema map[string]interface{}
	for index, segment := range segments {
		if segment.Type != "dynamic_content" {
			continue
		}
		candidate, candidateErr := dynamicSchemaFromData(segment.Data)
		if candidateErr != nil {
			return nil, "", candidateErr
		}
		if candidate["id"] != contentID {
			continue
		}
		if dynamicIndex >= 0 {
			return nil, "", fmt.Errorf("dynamic update content_id is ambiguous")
		}
		dynamicIndex = index
		schema = candidate
	}
	if dynamicIndex < 0 {
		return nil, "", fmt.Errorf("dynamic update target content was not found")
	}
	updated, err := applyDynamicPatches(schema, patches)
	if err != nil {
		return nil, "", err
	}
	if err := validateDynamicSchema(updated); err != nil {
		return nil, "", err
	}
	result := append([]protocol.MessageSegment(nil), segments...)
	result[dynamicIndex] = protocol.DynamicContentSegment(updated)
	return result, messageID, nil
}

func applyDynamicPatches(schema map[string]interface{}, patches []map[string]interface{}) (map[string]interface{}, error) {
	result := cloneDynamicMap(schema)
	root, ok := result["tree"].(map[string]interface{})
	if !ok {
		return nil, fmt.Errorf("dynamic content tree is missing")
	}
	for _, patch := range patches {
		operation, _ := patch["operation"].(string)
		nodeID, _ := patch["node_id"].(string)
		switch operation {
		case "update":
			node, _, _, found := findDynamicNode(root, nodeID)
			if !found {
				return nil, fmt.Errorf("dynamic node %q was not found", nodeID)
			}
			if props, ok := patch["props"].(map[string]interface{}); ok {
				current, _ := node["props"].(map[string]interface{})
				merged := cloneDynamicMap(current)
				for key, value := range props {
					merged[key] = value
				}
				node["props"] = merged
			}
		case "replace":
			replacement, _ := patch["node"].(map[string]interface{})
			_, parent, index, found := findDynamicNode(root, nodeID)
			if !found {
				return nil, fmt.Errorf("dynamic node %q was not found", nodeID)
			}
			replacement = cloneDynamicMap(replacement)
			if parent == nil {
				root = replacement
				continue
			}
			children, _ := parent["children"].([]interface{})
			children[index] = replacement
			parent["children"] = children
		case "remove":
			_, parent, index, found := findDynamicNode(root, nodeID)
			if !found {
				return nil, fmt.Errorf("dynamic node %q was not found", nodeID)
			}
			if parent == nil {
				return nil, fmt.Errorf("the dynamic root node cannot be removed")
			}
			children, _ := parent["children"].([]interface{})
			parent["children"] = append(children[:index], children[index+1:]...)
		case "create":
			parentID, _ := patch["parent_node_id"].(string)
			created, _ := patch["node"].(map[string]interface{})
			if _, _, _, found := findDynamicNode(root, nodeID); found {
				return nil, fmt.Errorf("dynamic node %q already exists", nodeID)
			}
			parent, _, _, found := findDynamicNode(root, parentID)
			if !found {
				return nil, fmt.Errorf("dynamic parent node %q was not found", parentID)
			}
			children, _ := parent["children"].([]interface{})
			created = cloneDynamicMap(created)
			insertAt := len(children)
			if rawIndex, exists := patch["index"]; exists {
				value, _ := exactInt64(rawIndex)
				if value < int64(insertAt) {
					insertAt = int(value)
				}
			}
			children = append(children, nil)
			copy(children[insertAt+1:], children[insertAt:])
			children[insertAt] = created
			parent["children"] = children
		}
	}
	result["tree"] = root
	return result, nil
}

func findDynamicNode(root map[string]interface{}, targetID string) (map[string]interface{}, map[string]interface{}, int, bool) {
	id, _ := root["id"].(string)
	if id == targetID {
		return root, nil, -1, true
	}
	children, _ := root["children"].([]interface{})
	for index, rawChild := range children {
		child, ok := rawChild.(map[string]interface{})
		if !ok {
			continue
		}
		if found, parent, childIndex, ok := findDynamicNode(child, targetID); ok {
			if parent == nil {
				return found, root, index, true
			}
			return found, parent, childIndex, true
		}
	}
	return nil, nil, -1, false
}

func cloneDynamicMap(value map[string]interface{}) map[string]interface{} {
	if value == nil {
		return map[string]interface{}{}
	}
	encoded, err := json.Marshal(value)
	if err != nil {
		return map[string]interface{}{}
	}
	var cloned map[string]interface{}
	if err := json.Unmarshal(encoded, &cloned); err != nil || cloned == nil {
		return map[string]interface{}{}
	}
	return cloned
}
