package gateway

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"math"
	"reflect"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/icradp/zzz-im-server/internal/protocol"
	"github.com/icradp/zzz-im-server/internal/store"
)

const maxDynamicInteractionEvents = 10000

type dynamicInteractionConfig struct {
	wire                  protocol.DynamicInteractionConfig
	reducer               string
	kind                  string
	response              string
	allowChange           bool
	visibility            string
	total                 int
	quorum                int
	veto                  bool
	fairyRoute            string
	fairyThreshold        int
	progressNodeID        string
	statusNodeID          string
	progressText          string
	legacyCloseOnResponse bool
}

type dynamicInteractionReduction struct {
	state     map[string]interface{}
	counts    map[string]int
	responded int
	total     int
	status    string
	closed    bool
}

type dynamicInteractionReduceContext struct {
	config dynamicInteractionConfig
	events []*store.DynamicInteractionEvent
	total  int
	now    time.Time
}

type dynamicInteractionReducer interface {
	Name() string
	Reduce(dynamicInteractionReduceContext) (dynamicInteractionReduction, error)
}

type dynamicInteractionReducerFunc struct {
	name   string
	reduce func(dynamicInteractionReduceContext) (dynamicInteractionReduction, error)
}

func (r dynamicInteractionReducerFunc) Name() string { return r.name }

func (r dynamicInteractionReducerFunc) Reduce(ctx dynamicInteractionReduceContext) (dynamicInteractionReduction, error) {
	return r.reduce(ctx)
}

var dynamicInteractionReducers = func() map[string]dynamicInteractionReducer {
	reducers := []dynamicInteractionReducer{
		dynamicInteractionReducerFunc{name: "set_by_actor", reduce: reduceSetByActor},
		dynamicInteractionReducerFunc{name: "append", reduce: reduceAppend},
		dynamicInteractionReducerFunc{name: "counter", reduce: reduceCounter},
		dynamicInteractionReducerFunc{name: "checklist", reduce: reduceChecklist},
		dynamicInteractionReducerFunc{name: "form", reduce: reduceForm},
		dynamicInteractionReducerFunc{name: "approval_quorum", reduce: reduceApprovalQuorum},
		dynamicInteractionReducerFunc{name: "state_machine", reduce: reduceStateMachine},
		dynamicInteractionReducerFunc{name: "none", reduce: reduceNone},
	}
	result := make(map[string]dynamicInteractionReducer, len(reducers))
	for _, reducer := range reducers {
		result[reducer.Name()] = reducer
	}
	return result
}()

func parseDynamicInteractionConfig(schema map[string]interface{}) (dynamicInteractionConfig, bool, error) {
	metadata, _ := schema["metadata"].(map[string]interface{})
	raw, configured := metadata["interaction"].(map[string]interface{})
	if !configured {
		return defaultDynamicInteractionConfig(), false, nil
	}
	encoded, err := json.Marshal(raw)
	if err != nil {
		return dynamicInteractionConfig{}, false, fmt.Errorf("dynamic interaction config is invalid")
	}
	var wire protocol.DynamicInteractionConfig
	if err := json.Unmarshal(encoded, &wire); err != nil {
		return dynamicInteractionConfig{}, false, fmt.Errorf("dynamic interaction config is invalid")
	}
	config := defaultDynamicInteractionConfig()
	config.wire = wire
	config.kind = strings.ToLower(strings.TrimSpace(wire.Kind))
	config.reducer = strings.ToLower(strings.TrimSpace(wire.Reducer))
	if config.reducer == "" {
		config.reducer = legacyDynamicReducer(config.kind)
	}
	if _, ok := dynamicInteractionReducers[config.reducer]; !ok {
		return dynamicInteractionConfig{}, false, fmt.Errorf("dynamic interaction reducer %q is not supported", config.reducer)
	}
	config.response = strings.ToLower(strings.TrimSpace(wire.Policy.Response))
	if config.response == "" {
		switch config.reducer {
		case "append", "counter", "state_machine", "none":
			config.response = "many"
		default:
			config.response = "once"
		}
	}
	if config.response != "once" && config.response != "many" {
		return dynamicInteractionConfig{}, false, fmt.Errorf("dynamic interaction response policy is invalid")
	}
	if wire.Policy.AllowChange != nil {
		config.allowChange = *wire.Policy.AllowChange
	} else if wire.AllowChange != nil {
		config.allowChange = *wire.AllowChange
	}
	config.visibility = strings.ToLower(strings.TrimSpace(wire.Policy.Visibility))
	if config.visibility == "" {
		config.visibility = "public_aggregate"
	}
	switch config.visibility {
	case "public_aggregate", "public_detail", "admin_detail", "actor_only", "anonymous_aggregate":
	default:
		return dynamicInteractionConfig{}, false, fmt.Errorf("dynamic interaction visibility is invalid")
	}
	config.total = wire.Policy.Total
	if config.total <= 0 {
		config.total = wire.Total
	}
	config.quorum = wire.Policy.Quorum
	if wire.Policy.Veto != nil {
		config.veto = *wire.Policy.Veto
	}
	config.fairyRoute = strings.ToLower(strings.TrimSpace(wire.Routing.Fairy))
	if config.fairyRoute != "" {
		switch config.fairyRoute {
		case "manual", "on_close", "on_threshold", "each_event":
		default:
			return dynamicInteractionConfig{}, false, fmt.Errorf("dynamic interaction Fairy routing is invalid")
		}
	}
	config.fairyThreshold = wire.Routing.Threshold
	config.progressNodeID = wire.Projection.ProgressNodeID
	if config.progressNodeID == "" {
		config.progressNodeID = wire.ProgressNodeID
	}
	config.statusNodeID = wire.Projection.StatusNodeID
	if config.statusNodeID == "" {
		config.statusNodeID = wire.StatusNodeID
	}
	config.progressText = wire.Projection.ProgressText
	if config.progressText == "" {
		config.progressText = wire.ProgressText
	}
	if wire.CloseOnResponse != nil {
		config.legacyCloseOnResponse = *wire.CloseOnResponse
	}
	return config, true, nil
}

func defaultDynamicInteractionConfig() dynamicInteractionConfig {
	return dynamicInteractionConfig{
		reducer:     "none",
		response:    "many",
		allowChange: true,
		visibility:  "public_aggregate",
		veto:        true,
	}
}

func legacyDynamicReducer(kind string) string {
	switch kind {
	case "vote", "read", "ack":
		return "set_by_actor"
	case "approval":
		return "approval_quorum"
	default:
		return "none"
	}
}

func dynamicInteractionSchema(target *store.Message, contentID string) (map[string]interface{}, dynamicInteractionConfig, bool, error) {
	if target == nil {
		return nil, dynamicInteractionConfig{}, false, nil
	}
	for _, segment := range target.Segments {
		if segment.Type != "dynamic_content" {
			continue
		}
		schema, err := dynamicSchemaFromData(segment.Data)
		if err != nil {
			return nil, dynamicInteractionConfig{}, false, err
		}
		if schema["id"] != contentID {
			continue
		}
		config, configured, err := parseDynamicInteractionConfig(schema)
		return schema, config, configured, err
	}
	return nil, dynamicInteractionConfig{}, false, nil
}

func validateDynamicInteractionPolicy(
	config dynamicInteractionConfig,
	configured bool,
	events []*store.DynamicInteractionEvent,
	candidate *store.DynamicInteractionEvent,
	groupRole string,
	isAuthor bool,
	now time.Time,
) error {
	if !configured {
		return nil
	}
	policy := config.wire.Policy
	if policy.ExpiresAtMS > 0 && now.UnixMilli() >= policy.ExpiresAtMS {
		return fmt.Errorf("dynamic interaction has expired")
	}
	if candidate.ActorKind == "agent" && !policy.AllowAgent {
		return fmt.Errorf("dynamic interaction does not allow Agent actors")
	}
	if !dynamicAudienceAllows(policy.Audience, candidate.ActorKind, groupRole, isAuthor) {
		return fmt.Errorf("dynamic interaction audience does not include this actor")
	}
	actorEvents := 0
	for _, event := range events {
		if event.ActorID == candidate.ActorID {
			actorEvents++
		}
	}
	if policy.MaxResponsesPerActor > 0 && actorEvents >= policy.MaxResponsesPerActor {
		return fmt.Errorf("dynamic interaction response limit reached")
	}
	if config.response == "once" && actorEvents > 0 && !config.allowChange {
		return fmt.Errorf("dynamic interaction response cannot be changed")
	}
	return nil
}

func dynamicAudienceAllows(audience []string, actorKind, groupRole string, isAuthor bool) bool {
	if len(audience) == 0 {
		return true
	}
	for _, value := range audience {
		switch strings.ToLower(strings.TrimSpace(value)) {
		case "all", "members":
			return true
		case "users":
			if actorKind == "user" {
				return true
			}
		case "agents":
			if actorKind == "agent" {
				return true
			}
		case "admins":
			if groupRole == "owner" || groupRole == "admin" {
				return true
			}
		case "owner":
			if groupRole == "owner" || isAuthor {
				return true
			}
		}
	}
	return false
}

func applyDynamicInteraction(
	target *store.Message,
	contentID string,
	events []*store.DynamicInteractionEvent,
	total int,
	now time.Time,
) ([]protocol.MessageSegment, protocol.MessageSegment, dynamicInteractionReduction, bool, error) {
	result := dynamicInteractionReduction{}
	if target == nil {
		return nil, protocol.MessageSegment{}, result, false, nil
	}
	for index, segment := range target.Segments {
		if segment.Type != "dynamic_content" {
			continue
		}
		schema, err := dynamicSchemaFromData(segment.Data)
		if err != nil {
			return nil, protocol.MessageSegment{}, result, false, err
		}
		if schema["id"] != contentID {
			continue
		}
		config, configured, err := parseDynamicInteractionConfig(schema)
		if err != nil {
			return nil, protocol.MessageSegment{}, result, false, err
		}
		if !configured || config.reducer == "none" {
			return append([]protocol.MessageSegment(nil), target.Segments...), protocol.MessageSegment{}, result, false, nil
		}
		if config.total > 0 {
			total = config.total
		}
		result, err = dynamicInteractionReducers[config.reducer].Reduce(dynamicInteractionReduceContext{
			config: config,
			events: events,
			total:  total,
			now:    now,
		})
		if err != nil {
			return nil, protocol.MessageSegment{}, result, false, err
		}
		metadata, _ := schema["metadata"].(map[string]interface{})
		metadata = cloneDynamicMap(metadata)
		metadata["interaction_state"] = result.state
		schema["metadata"] = metadata
		root, ok := schema["tree"].(map[string]interface{})
		if !ok {
			return nil, protocol.MessageSegment{}, result, false, fmt.Errorf("dynamic content tree is missing")
		}
		updateInteractionProjection(root, config, result)
		if err := validateDynamicSchema(schema); err != nil {
			return nil, protocol.MessageSegment{}, result, false, err
		}
		updatedSegments := append([]protocol.MessageSegment(nil), target.Segments...)
		updatedSegments[index] = protocol.DynamicContentSegment(schema)
		return updatedSegments, protocol.DynamicReplaceSegment(target.ID, contentID, schema), result, true, nil
	}
	return append([]protocol.MessageSegment(nil), target.Segments...), protocol.MessageSegment{}, result, false, nil
}

// applyDynamicActionProjection handles cards that use declarative component
// actions without opting into an interaction reducer. The same action is
// applied locally for instant feedback and persisted here so the card remains
// convergent after history reload or on another device.
func applyDynamicActionProjection(
	target *store.Message,
	contentID, eventName, action string,
	payload map[string]interface{},
) ([]protocol.MessageSegment, protocol.MessageSegment, bool, error) {
	if target == nil {
		return nil, protocol.MessageSegment{}, false, nil
	}
	for index, segment := range target.Segments {
		if segment.Type != "dynamic_content" {
			continue
		}
		schema, err := dynamicSchemaFromData(segment.Data)
		if err != nil {
			return nil, protocol.MessageSegment{}, false, err
		}
		if schema["id"] != contentID {
			continue
		}
		updated, changed, err := applyDynamicActionToSchema(schema, eventName, action, payload)
		if err != nil {
			return nil, protocol.MessageSegment{}, false, err
		}
		if !changed {
			return append([]protocol.MessageSegment(nil), target.Segments...), protocol.MessageSegment{}, false, nil
		}
		if err := validateDynamicSchema(updated); err != nil {
			return nil, protocol.MessageSegment{}, false, err
		}
		segments := append([]protocol.MessageSegment(nil), target.Segments...)
		segments[index] = protocol.DynamicContentSegment(updated)
		return segments, protocol.DynamicReplaceSegment(target.ID, contentID, updated), true, nil
	}
	return append([]protocol.MessageSegment(nil), target.Segments...), protocol.MessageSegment{}, false, nil
}

func applyDynamicActionToSchema(
	schema map[string]interface{},
	eventName, action string,
	payload map[string]interface{},
) (map[string]interface{}, bool, error) {
	updated := cloneDynamicMap(schema)
	root, ok := updated["tree"].(map[string]interface{})
	if !ok {
		return nil, false, fmt.Errorf("dynamic content tree is missing")
	}
	node, _, _, found := findDynamicNodeByEvent(root, eventName, action)
	if !found {
		return updated, false, nil
	}
	events, _ := node["events"].(map[string]interface{})
	definition, _ := events[eventName].(map[string]interface{})
	actionName := strings.ToLower(strings.TrimSpace(action))
	targetID, _ := definition["target"].(string)
	if targetID == "" {
		switch actionName {
		case "set_progress", "increment_progress":
			targetID = firstDynamicNodeID(root, "progress")
		case "set_status":
			targetID = firstDynamicNodeID(root, "status")
			if targetID == "" {
				targetID = firstDynamicNodeID(root, "progress")
			}
		case "approve", "approved", "allow", "confirm", "confirmed", "yes", "complete", "completed", "reject", "rejected", "deny", "denied", "no", "cancel", "cancelled":
			targetID = firstDynamicNodeID(root, "status")
			if targetID == "" {
				targetID = firstDynamicNodeID(root, "progress")
			}
		}
	}
	if targetID == "" {
		return updated, false, nil
	}
	target, _, _, found := findDynamicNode(root, targetID)
	if !found {
		if actionName == "set_status" || strings.HasPrefix(actionName, "approve") || strings.HasPrefix(actionName, "reject") {
			targetID = firstDynamicNodeID(root, "progress")
			target, _, _, found = findDynamicNode(root, targetID)
		}
		if !found {
			return nil, false, fmt.Errorf("dynamic action target %q was not found", targetID)
		}
	}
	props := cloneDynamicMap(asDynamicMap(target["props"]))
	target["props"] = props
	changed := false
	set := func(key string, value interface{}) {
		if !reflect.DeepEqual(props[key], value) {
			props[key] = value
			changed = true
		}
	}
	value, hasValue := definition["value"]
	if !hasValue {
		value, hasValue = payload["value"]
	}
	switch actionName {
	case "toggle":
		property := dynamicString(definition["property"], "value")
		set(property, props[property] != true)
	case "set_property", "set_value", "set_status":
		if !hasValue {
			value = true
			hasValue = true
		}
		property := dynamicString(definition["property"], "text")
		if actionName == "set_value" {
			property = dynamicString(definition["property"], "value")
		}
		if nodeType, _ := target["type"].(string); nodeType == "progress" && actionName == "set_status" {
			progress, ok := dynamicActionNumber(value)
			if !ok {
				current, _ := dynamicActionNumber(props["value"])
				progress = current + 0.1
			}
			if progress > 1 {
				progress /= 100
			}
			progress = math.Max(0, math.Min(1, progress))
			set("value", progress)
			if _, exists := props["text"]; exists {
				set("text", fmt.Sprintf("%.0f%%", progress*100))
			}
		} else {
			set(property, value)
		}
	case "set_progress", "increment_progress":
		progress, ok := dynamicActionNumber(value)
		if !ok {
			return updated, false, nil
		}
		if actionName == "increment_progress" {
			current, _ := dynamicActionNumber(props["value"])
			progress += current
		}
		if progress > 1 {
			progress /= 100
		}
		progress = math.Max(0, math.Min(1, progress))
		set("value", progress)
		if _, exists := props["text"]; exists {
			set("text", fmt.Sprintf("%.0f%%", progress*100))
		}
	case "approve", "approved", "allow", "confirm", "confirmed", "yes", "complete", "completed", "reject", "rejected", "deny", "denied", "no", "cancel", "cancelled":
		label := "Approved"
		if isNegativeInteractionAction(actionName) {
			label = "Rejected"
		}
		set("text", label)
	}
	// Status and approval actions commonly target a separate status label. Keep
	// an adjacent progress node convergent as well, even when the action does
	// not explicitly name it. This is intentionally a small declarative step,
	// not a second event or a hidden command execution.
	if actionName == "set_status" || isPositiveInteractionAction(actionName) || isNegativeInteractionAction(actionName) {
		if targetType, _ := target["type"].(string); targetType != "progress" {
			if progressID := firstDynamicNodeID(root, "progress"); progressID != "" {
				progressNode, _, _, found := findDynamicNode(root, progressID)
				if found {
					progressProps := cloneDynamicMap(asDynamicMap(progressNode["props"]))
					progressNode["props"] = progressProps
					current, _ := dynamicActionNumber(progressProps["value"])
					step, hasStep := dynamicActionNumber(definition["progress"])
					if !hasStep {
						step, hasStep = dynamicActionNumber(definition["progress_value"])
					}
					if !hasStep && actionName == "set_status" {
						// A numeric status value is an explicit progress target;
						// textual statuses advance one unit (or one of total).
						step, hasStep = dynamicActionNumber(value)
					}
					if !hasStep || actionName != "set_status" {
						step, hasStep = dynamicActionNumber(definition["increment"])
					}
					if hasStep && actionName != "set_status" {
						step += current
					} else if hasStep && actionName == "set_status" {
						if _, numericStatus := dynamicActionNumber(value); !numericStatus {
							step += current
						}
					} else {
						step = current + 0.1
						if total, ok := dynamicActionNumber(definition["total"]); ok && total > 0 {
							step = current + 1/total
						}
					}
					if step > 1 {
						step /= 100
					}
					step = math.Max(0, math.Min(1, step))
					if !reflect.DeepEqual(progressProps["value"], step) {
						progressProps["value"] = step
						changed = true
					}
					if _, exists := progressProps["text"]; exists {
						text := fmt.Sprintf("%.0f%%", step*100)
						if !reflect.DeepEqual(progressProps["text"], text) {
							progressProps["text"] = text
							changed = true
						}
					}
				}
			}
		}
	}
	return updated, changed, nil
}

func findDynamicNodeByEvent(root map[string]interface{}, eventName, action string) (map[string]interface{}, map[string]interface{}, int, bool) {
	if events, ok := root["events"].(map[string]interface{}); ok {
		if definition, ok := events[eventName].(map[string]interface{}); ok {
			if expected, _ := definition["action"].(string); expected == action {
				return root, nil, -1, true
			}
		}
	}
	children, _ := root["children"].([]interface{})
	for index, child := range children {
		childMap, ok := child.(map[string]interface{})
		if !ok {
			continue
		}
		if foundNode, parent, childIndex, found := findDynamicNodeByEvent(childMap, eventName, action); found {
			if parent == nil {
				return foundNode, root, index, true
			}
			return foundNode, parent, childIndex, true
		}
	}
	return nil, nil, -1, false
}

func firstDynamicNodeID(root map[string]interface{}, typeName string) string {
	if nodeType, _ := root["type"].(string); nodeType == typeName {
		id, _ := root["id"].(string)
		return id
	}
	children, _ := root["children"].([]interface{})
	for _, child := range children {
		childMap, ok := child.(map[string]interface{})
		if !ok {
			continue
		}
		if id := firstDynamicNodeID(childMap, typeName); id != "" {
			return id
		}
	}
	return ""
}

func asDynamicMap(value interface{}) map[string]interface{} {
	if result, ok := value.(map[string]interface{}); ok {
		return result
	}
	return map[string]interface{}{}
}

func dynamicString(value interface{}, fallback string) string {
	if result, ok := value.(string); ok && strings.TrimSpace(result) != "" {
		return strings.TrimSpace(result)
	}
	return fallback
}

func dynamicActionNumber(value interface{}) (float64, bool) {
	switch typed := value.(type) {
	case float64:
		return typed, !math.IsNaN(typed) && !math.IsInf(typed, 0)
	case float32:
		return float64(typed), true
	case int:
		return float64(typed), true
	case int64:
		return float64(typed), true
	case json.Number:
		parsed, err := typed.Float64()
		return parsed, err == nil
	case string:
		parsed, err := strconv.ParseFloat(strings.TrimSpace(typed), 64)
		return parsed, err == nil
	default:
		return 0, false
	}
}

func reduceSetByActor(ctx dynamicInteractionReduceContext) (dynamicInteractionReduction, error) {
	latest := latestInteractionEventsByActor(ctx.events)
	counts := make(map[string]int)
	responses := make(map[string]interface{})
	for actorID, event := range latest {
		value := dynamicInteractionValue(event)
		if value == "" {
			value = ctx.config.kind
		}
		counts[value]++
		responses[actorID] = value
	}
	responded, total := len(latest), normalizedInteractionTotal(ctx.total, len(latest))
	state := baseInteractionState(ctx, responded, total, false, "active", counts)
	if ctx.config.visibility == "public_detail" {
		state["responses"] = responses
	}
	return dynamicInteractionReduction{state: state, counts: counts, responded: responded, total: total, status: "active"}, nil
}

func reduceAppend(ctx dynamicInteractionReduceContext) (dynamicInteractionReduction, error) {
	total := normalizedInteractionTotal(ctx.total, len(ctx.events))
	state := baseInteractionState(ctx, len(ctx.events), total, false, "active", nil)
	if len(ctx.events) > 0 {
		state["last_action"] = dynamicInteractionValue(ctx.events[len(ctx.events)-1])
	}
	if ctx.config.visibility == "public_detail" {
		entries := make([]interface{}, 0, len(ctx.events))
		for _, event := range ctx.events {
			entries = append(entries, dynamicInteractionEventDetail(event))
		}
		state["entries"] = entries
	}
	return dynamicInteractionReduction{state: state, responded: len(ctx.events), total: total, status: "active"}, nil
}

func reduceCounter(ctx dynamicInteractionReduceContext) (dynamicInteractionReduction, error) {
	events := ctx.events
	if ctx.config.response == "once" {
		latest := latestInteractionEventsByActor(ctx.events)
		events = make([]*store.DynamicInteractionEvent, 0, len(latest))
		for _, event := range latest {
			events = append(events, event)
		}
	}
	counts := make(map[string]int)
	for _, event := range events {
		value := dynamicInteractionValue(event)
		if value == "" {
			value = "count"
		}
		counts[value]++
	}
	total := normalizedInteractionTotal(ctx.total, len(events))
	state := baseInteractionState(ctx, len(events), total, false, "active", counts)
	state["count"] = len(events)
	return dynamicInteractionReduction{state: state, counts: counts, responded: len(events), total: total, status: "active"}, nil
}

func reduceChecklist(ctx dynamicInteractionReduceContext) (dynamicInteractionReduction, error) {
	latest := make(map[string]*store.DynamicInteractionEvent)
	for _, event := range ctx.events {
		item := dynamicPayloadString(event.Payload, "item_id")
		if item == "" {
			item = dynamicInteractionValue(event)
		}
		latest[event.ActorID+"\x00"+item] = event
	}
	items := make(map[string]int)
	actors := make(map[string]struct{})
	for key, event := range latest {
		item := key[strings.IndexByte(key, 0)+1:]
		completed, exists := event.Payload["completed"].(bool)
		if !exists {
			completed = isPositiveInteractionAction(event.Action)
		}
		if completed {
			items[item]++
		}
		actors[event.ActorID] = struct{}{}
	}
	total := normalizedInteractionTotal(ctx.total, len(actors))
	state := baseInteractionState(ctx, len(actors), total, false, "active", items)
	state["items"] = items
	return dynamicInteractionReduction{state: state, counts: items, responded: len(actors), total: total, status: "active"}, nil
}

func reduceForm(ctx dynamicInteractionReduceContext) (dynamicInteractionReduction, error) {
	latest := latestInteractionEventsByActor(ctx.events)
	total := normalizedInteractionTotal(ctx.total, len(latest))
	state := baseInteractionState(ctx, len(latest), total, false, "active", nil)
	if ctx.config.visibility == "public_detail" {
		responses := make(map[string]interface{}, len(latest))
		for actorID, event := range latest {
			responses[actorID] = cloneDynamicMap(event.Payload)
		}
		state["responses"] = responses
	}
	return dynamicInteractionReduction{state: state, responded: len(latest), total: total, status: "active"}, nil
}

func reduceApprovalQuorum(ctx dynamicInteractionReduceContext) (dynamicInteractionReduction, error) {
	latest := latestInteractionEventsByActor(ctx.events)
	counts := make(map[string]int)
	responses := make(map[string]interface{})
	approved, rejected := 0, 0
	for actorID, event := range latest {
		value := dynamicInteractionValue(event)
		counts[value]++
		responses[actorID] = value
		if isPositiveInteractionAction(value) {
			approved++
		} else if isNegativeInteractionAction(value) {
			rejected++
		}
	}
	total := normalizedInteractionTotal(ctx.total, len(latest))
	quorum := ctx.config.quorum
	if quorum <= 0 {
		quorum = total
	}
	status, closed := "pending", false
	if ctx.config.legacyCloseOnResponse && len(latest) > 0 {
		last := ctx.events[len(ctx.events)-1]
		if dynamicInteractionValue(last) != "modify" {
			closed = true
			if isNegativeInteractionAction(dynamicInteractionValue(last)) {
				status = "rejected"
			} else {
				status = "approved"
			}
		}
	} else if ctx.config.veto && rejected > 0 {
		status, closed = "rejected", true
	} else if approved >= quorum {
		status, closed = "approved", true
	}
	state := baseInteractionState(ctx, len(latest), total, closed, status, counts)
	state["approved"] = approved
	state["rejected"] = rejected
	state["quorum"] = quorum
	if ctx.config.visibility == "public_detail" {
		state["responses"] = responses
	}
	return dynamicInteractionReduction{state: state, counts: counts, responded: len(latest), total: total, status: status, closed: closed}, nil
}

func reduceStateMachine(ctx dynamicInteractionReduceContext) (dynamicInteractionReduction, error) {
	current := strings.TrimSpace(ctx.config.wire.Policy.InitialState)
	if current == "" {
		current = "open"
	}
	for _, event := range ctx.events {
		next := dynamicInteractionValue(event)
		if next == "" {
			continue
		}
		if transitions := ctx.config.wire.Policy.Transitions; len(transitions) > 0 {
			allowed := transitions[current]
			if !containsDynamicString(allowed, next) {
				return dynamicInteractionReduction{}, fmt.Errorf("dynamic state transition %q to %q is not allowed", current, next)
			}
		}
		current = next
	}
	closed := current == "closed" || current == "completed" || current == "cancelled"
	total := normalizedInteractionTotal(ctx.total, len(ctx.events))
	state := baseInteractionState(ctx, len(ctx.events), total, closed, current, nil)
	state["current"] = current
	return dynamicInteractionReduction{state: state, responded: len(ctx.events), total: total, status: current, closed: closed}, nil
}

func reduceNone(ctx dynamicInteractionReduceContext) (dynamicInteractionReduction, error) {
	return dynamicInteractionReduction{}, nil
}

func baseInteractionState(ctx dynamicInteractionReduceContext, responded, total int, closed bool, status string, counts map[string]int) map[string]interface{} {
	state := map[string]interface{}{
		"version":       "1.0",
		"reducer":       ctx.config.reducer,
		"responded":     responded,
		"total":         total,
		"closed":        closed,
		"status":        status,
		"updated_at_ms": ctx.now.UnixMilli(),
	}
	if len(counts) > 0 {
		state["counts"] = counts
	}
	return state
}

func latestInteractionEventsByActor(events []*store.DynamicInteractionEvent) map[string]*store.DynamicInteractionEvent {
	latest := make(map[string]*store.DynamicInteractionEvent)
	for _, event := range events {
		latest[event.ActorID] = event
	}
	return latest
}

func dynamicInteractionValue(event *store.DynamicInteractionEvent) string {
	if event == nil {
		return ""
	}
	if option := dynamicPayloadString(event.Payload, "option"); option != "" {
		return option
	}
	if value := dynamicPayloadString(event.Payload, "value"); value != "" {
		return value
	}
	return strings.TrimSpace(event.Action)
}

func dynamicPayloadString(payload map[string]interface{}, key string) string {
	if payload == nil {
		return ""
	}
	value, _ := payload[key].(string)
	return strings.TrimSpace(value)
}

func dynamicInteractionEventDetail(event *store.DynamicInteractionEvent) map[string]interface{} {
	return map[string]interface{}{
		"event_id":       event.EventID,
		"node_id":        event.NodeID,
		"event":          event.Event,
		"action":         event.Action,
		"payload":        event.Payload,
		"actor_id":       event.ActorID,
		"actor_nickname": event.ActorNickname,
		"actor_kind":     event.ActorKind,
		"created_at_ms":  event.CreatedAt.UnixMilli(),
	}
}

func normalizedInteractionTotal(configured, observed int) int {
	if configured < observed {
		configured = observed
	}
	if configured < 1 {
		configured = 1
	}
	return configured
}

func isPositiveInteractionAction(value string) bool {
	switch strings.ToLower(strings.TrimSpace(value)) {
	case "approve", "approved", "allow", "confirm", "confirmed", "yes", "complete", "completed", "checked", "true":
		return true
	default:
		return false
	}
}

func isNegativeInteractionAction(value string) bool {
	switch strings.ToLower(strings.TrimSpace(value)) {
	case "reject", "rejected", "deny", "denied", "no", "cancel", "cancelled", "false":
		return true
	default:
		return false
	}
}

func containsDynamicString(values []string, target string) bool {
	for _, value := range values {
		if value == target {
			return true
		}
	}
	return false
}

func updateInteractionProjection(root map[string]interface{}, config dynamicInteractionConfig, result dynamicInteractionReduction) {
	var firstProgress, firstStatus map[string]interface{}
	var visit func(map[string]interface{})
	visit = func(node map[string]interface{}) {
		props, _ := node["props"].(map[string]interface{})
		if props == nil {
			props = map[string]interface{}{}
			node["props"] = props
		}
		typeName, _ := node["type"].(string)
		if typeName == "progress" && firstProgress == nil {
			firstProgress = node
		}
		if typeName == "status" && firstStatus == nil {
			firstStatus = node
		}
		option, _ := props["option"].(string)
		if option == "" {
			option, _ = props["vote_option"].(string)
		}
		if option != "" {
			props["count"] = result.counts[option]
		}
		children, _ := node["children"].([]interface{})
		for _, child := range children {
			if childMap, ok := child.(map[string]interface{}); ok {
				visit(childMap)
			}
		}
	}
	visit(root)
	progress := findNodeByID(root, config.progressNodeID)
	if progress == nil {
		progress = firstProgress
	}
	if progress != nil {
		props, _ := progress["props"].(map[string]interface{})
		if props == nil {
			props = map[string]interface{}{}
			progress["props"] = props
		}
		props["value"] = float64(result.responded) / float64(normalizedInteractionTotal(result.total, result.responded))
		props["text"] = formatInteractionProgress(config.progressText, result.responded, result.total)
	}
	status := findNodeByID(root, config.statusNodeID)
	if status == nil {
		status = firstStatus
	}
	if status != nil && result.status != "" {
		props, _ := status["props"].(map[string]interface{})
		if props == nil {
			props = map[string]interface{}{}
			status["props"] = props
		}
		props["status"] = result.status
		props["text"] = result.status
	}
}

func findNodeByID(root map[string]interface{}, id string) map[string]interface{} {
	if id == "" {
		return nil
	}
	if rootID, _ := root["id"].(string); rootID == id {
		return root
	}
	children, _ := root["children"].([]interface{})
	for _, child := range children {
		childMap, ok := child.(map[string]interface{})
		if !ok {
			continue
		}
		if found := findNodeByID(childMap, id); found != nil {
			return found
		}
	}
	return nil
}

func formatInteractionProgress(template string, responded, total int) string {
	if template == "" {
		template = "%d/%d"
	}
	if strings.Contains(template, "%d") {
		return fmt.Sprintf(template, responded, total)
	}
	return fmt.Sprintf("%d/%d", responded, total)
}

func dynamicInteractionEventID(conversationID, actorID string, data map[string]interface{}) string {
	if eventID, _ := data["event_id"].(string); validDynamicIdentifier(eventID) {
		return eventID
	}
	encoded := fmt.Sprintf("%s\x00%s\x00%s\x00%s\x00%s\x00%v", conversationID, actorID,
		data["message_id"], data["content_id"], data["node_id"], data)
	digest := sha256.Sum256([]byte(encoded))
	return "legacy-dynamic-event-" + hex.EncodeToString(digest[:])
}

func sameDynamicInteractionEvent(existing, candidate *store.DynamicInteractionEvent) bool {
	return existing != nil && candidate != nil &&
		existing.EventID == candidate.EventID &&
		existing.ConversationID == candidate.ConversationID &&
		existing.MessageID == candidate.MessageID &&
		existing.ContentID == candidate.ContentID &&
		existing.NodeID == candidate.NodeID &&
		existing.Event == candidate.Event &&
		existing.Action == candidate.Action &&
		reflect.DeepEqual(existing.Payload, candidate.Payload)
}

func existingDynamicInteractionEvent(events []*store.DynamicInteractionEvent, actorID, eventID string) *store.DynamicInteractionEvent {
	for _, event := range events {
		if event.ActorID == actorID && event.EventID == eventID {
			return event
		}
	}
	return nil
}

func dynamicInteractionTotal(database store.Store, conversationID string) int {
	conversation, err := database.GetConversation(conversationID)
	if err != nil || conversation == nil {
		return 1
	}
	if conversation.Type == "group" {
		members, err := database.GetGroupMembers(conversationID)
		if err == nil && len(members) > 0 {
			return len(members)
		}
	}
	if len(conversation.Participants) > 0 {
		return len(conversation.Participants)
	}
	return 1
}

func interactionCount(value interface{}) int {
	if number, ok := value.(float64); ok {
		return int(number)
	}
	if number, ok := value.(int); ok {
		return number
	}
	if text, ok := value.(string); ok {
		parsed, _ := strconv.Atoi(text)
		return parsed
	}
	return 0
}

func sortedDynamicInteractionEvents(events []*store.DynamicInteractionEvent) {
	sort.SliceStable(events, func(i, j int) bool {
		if events[i].CreatedAt.Equal(events[j].CreatedAt) {
			return events[i].EventID < events[j].EventID
		}
		return events[i].CreatedAt.Before(events[j].CreatedAt)
	})
}
