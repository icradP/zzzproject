package fairy

import (
	"context"
	"path/filepath"
	"testing"
	"time"

	"github.com/icradp/zzz-im-server/internal/protocol"
)

func TestMessageGateHardAndSoftTriggerModes(t *testing.T) {
	cfg := testConfig(t)
	state, err := OpenStateStoreWithDefaults(filepath.Join(t.TempDir(), "state.json"), true, GroupSoftShadow)
	if err != nil {
		t.Fatal(err)
	}
	gate := NewMessageGate(cfg.UserID, state)
	behavior := behaviorConfigFromConfig(cfg)
	now := time.Date(2026, 9, 2, 10, 0, 0, 0, time.UTC)

	private := testMessage("private_alice_fairy", "private", "alice", "你好")
	if decision := gate.Evaluate(private, behavior, now, true); decision.Action != GateTrigger || !decision.Hard || decision.Reason != GateReasonPrivateMessage {
		t.Fatalf("private decision = %#v", decision)
	}

	mentioned := testMessage("group_room", "group", "alice", "继续说")
	mentioned.Message = append([]protocol.MessageSegment{protocol.AtSegment("fairy")}, mentioned.Message...)
	if decision := gate.Evaluate(mentioned, behavior, now, true); decision.Action != GateTrigger || decision.Reason != GateReasonExplicitMention {
		t.Fatalf("mention decision = %#v", decision)
	}

	followUp := testMessage("group_room", "group", "alice", "还有一个问题")
	followUp.MessageID = "message_2"
	if decision := gate.Evaluate(followUp, behavior, now.Add(time.Second), false); decision.Action != GateWait || !decision.Shadow || decision.Reason != GateReasonSoftShadow {
		t.Fatalf("shadow decision = %#v", decision)
	}

	behavior.GroupSoftDefault = GroupSoftOn
	state.SetSoftDefault(GroupSoftOn)
	if decision := gate.Evaluate(followUp, behavior, now.Add(2*time.Second), true); decision.Action != GateTrigger || decision.Hard || decision.Reason != GateReasonSoftTrigger {
		t.Fatalf("soft trigger decision = %#v", decision)
	}
	followUp.MessageID = "message_3"
	if decision := gate.Evaluate(followUp, behavior, now.Add(3*time.Second), true); decision.Action != GateWait || decision.Reason != GateReasonSoftCooldown {
		t.Fatalf("cooldown decision = %#v", decision)
	}
	other := testMessage("group_room", "group", "bob", "你们在聊什么")
	other.MessageID = "message_4"
	if decision := gate.Evaluate(other, behavior, now.Add(4*time.Second), false); decision.Action != GateWait || decision.Reason != GateReasonFocusConflict {
		t.Fatalf("focus conflict decision = %#v", decision)
	}
	if decision := gate.Evaluate(followUp, behavior, now.Add(cfg.FocusTTL+3*time.Second), false); decision.Action != GateIgnore || decision.Reason != GateReasonGroupNoTrigger {
		t.Fatalf("expired focus decision = %#v", decision)
	}
}

func TestMessageGateRespectsGroupStateAndManagementCommands(t *testing.T) {
	cfg := testConfig(t)
	state, err := OpenStateStoreWithDefaults(filepath.Join(t.TempDir(), "state.json"), false, GroupSoftShadow)
	if err != nil {
		t.Fatal(err)
	}
	gate := NewMessageGate(cfg.UserID, state)
	behavior := behaviorConfigFromConfig(cfg)
	now := time.Now()

	mentioned := testMessage("group_room", "group", "alice", "你好")
	mentioned.Message = append([]protocol.MessageSegment{protocol.AtSegment("fairy")}, mentioned.Message...)
	if decision := gate.Evaluate(mentioned, behavior, now, false); decision.Reason != GateReasonGroupDisabled {
		t.Fatalf("disabled mention decision = %#v", decision)
	}
	command := testMessage("group_room", "group", "alice", "/fairy on")
	if decision := gate.Evaluate(command, behavior, now, false); decision.Action != GateTrigger || decision.Reason != GateReasonCommand {
		t.Fatalf("management decision = %#v", decision)
	}
	query := testMessage("group_room", "group", "alice", "/zzz 123456789")
	if decision := gate.Evaluate(query, behavior, now, false); decision.Reason != GateReasonGroupDisabled {
		t.Fatalf("disabled plugin decision = %#v", decision)
	}
}

func TestEngineProactiveCommandRequiresAdminAndPersists(t *testing.T) {
	cfg := testConfig(t)
	state, err := OpenStateStoreWithDefaults(cfg.StateFile, true, cfg.GroupSoftDefault)
	if err != nil {
		t.Fatal(err)
	}
	engine := NewEngine(cfg, state, nil)
	messenger := &fakeMessenger{members: []protocol.GroupMember{{UserID: "alice", Role: "member"}}}
	event := testMessage("group_room", "group", "alice", "/fairy proactive on")
	engine.HandleMessage(context.Background(), messenger, event)
	if state.GroupSoftMode("group_room") != GroupSoftShadow {
		t.Fatal("member changed proactive mode")
	}
	messenger.members[0].Role = "admin"
	event.MessageID = "message_2"
	engine.HandleMessage(context.Background(), messenger, event)
	if state.GroupSoftMode("group_room") != GroupSoftOn {
		t.Fatal("admin did not change proactive mode")
	}
	if err := state.SetGroupEnabled("group_room", false); err != nil {
		t.Fatal(err)
	}
	if state.GroupSoftMode("group_room") != GroupSoftOn {
		t.Fatal("group switch overwrote proactive mode")
	}
}
