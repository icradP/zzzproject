package fairy

import (
	"context"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/icradp/zzz-im-server/internal/protocol"
)

func TestMediaInputSummaryRecognizesOnlySupportedFirstStageKinds(t *testing.T) {
	segments := []protocol.MessageSegment{
		protocol.ImageSegment("image.png", "/files/image.png"),
		protocol.RecordSegment("voice.webm", "/files/voice.webm"),
		protocol.VideoSegment("video.mp4", "/files/video.mp4"),
		protocol.FileSegment("notes.txt", "/files/notes.txt"),
	}
	summary := summarizeMediaInputs(segments)
	if summary.images != 1 || summary.records != 1 || !summary.present() {
		t.Fatalf("media summary = %#v", summary)
	}
}

func TestMediaInputGateAndSchedulerPrefilter(t *testing.T) {
	cfg := testConfig(t)
	state, err := OpenStateStoreWithDefaults(filepath.Join(t.TempDir(), "state.json"), true, GroupSoftShadow)
	if err != nil {
		t.Fatal(err)
	}
	gate := NewMessageGate(cfg.UserID, state)
	behavior := behaviorConfigFromConfig(cfg)

	private := testMessage("private_alice_fairy", "private", "alice", "")
	private.Message = []protocol.MessageSegment{protocol.ImageSegment("image.png", "/files/image.png")}
	if !isMessageCandidate(private, cfg.UserID) {
		t.Fatal("private image was filtered before the scheduler")
	}
	if decision := gate.Evaluate(private, behavior, cfgNow(), false); decision.Action != GateTrigger || decision.Reason != GateReasonPrivateMessage {
		t.Fatalf("private image gate decision = %#v", decision)
	}

	group := testMessage("group_room", "group", "alice", "")
	group.Message = []protocol.MessageSegment{protocol.ImageSegment("image.png", "/files/image.png")}
	if isMessageCandidate(group, cfg.UserID) {
		t.Fatal("unmentioned group image entered the scheduler")
	}
	group.Message = append([]protocol.MessageSegment{protocol.AtSegment(cfg.UserID)}, group.Message...)
	if !isMessageCandidate(group, cfg.UserID) {
		t.Fatal("mentioned group image was filtered before the scheduler")
	}
	if decision := gate.Evaluate(group, behavior, cfgNow(), false); decision.Action != GateTrigger || decision.Reason != GateReasonExplicitMention {
		t.Fatalf("mentioned group image gate decision = %#v", decision)
	}
}

func TestEngineDoesNotSendMediaOrCaptionToTextModel(t *testing.T) {
	for _, testCase := range []struct {
		name      string
		segment   protocol.MessageSegment
		text      string
		wantReply string
	}{
		{name: "image with caption", segment: protocol.ImageSegment("image.png", "https://images.example/image.png"), text: "这张图是什么？", wantReply: "图片理解"},
		{name: "voice only", segment: protocol.RecordSegment("voice.webm", "/files/voice.webm"), wantReply: "语音转写"},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			cfg := testConfig(t)
			state, err := OpenStateStore(filepath.Join(t.TempDir(), "state.json"), true)
			if err != nil {
				t.Fatal(err)
			}
			model := &fakeModel{response: "model must not be called"}
			engine := NewEngine(cfg, state, model)
			messenger := &fakeMessenger{}
			event := testMessage("private_alice_fairy", "private", "alice", testCase.text)
			event.Message = append(event.Message, testCase.segment)

			engine.HandleMessage(context.Background(), messenger, event)
			if len(model.requests) != 0 {
				t.Fatalf("media reached text model: %#v", model.requests)
			}
			if messenger.replyCount() != 1 || !strings.Contains(messenger.lastReply().text, testCase.wantReply) ||
				!strings.Contains(messenger.lastReply().text, "未下载") || !strings.Contains(messenger.lastReply().text, "未调用 AI") {
				t.Fatalf("media reply = %#v", messenger.replies)
			}
		})
	}
}

func cfgNow() time.Time {
	return time.Date(2026, 9, 2, 10, 0, 0, 0, time.UTC)
}
