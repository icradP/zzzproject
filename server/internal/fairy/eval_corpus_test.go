package fairy

import (
	"bytes"
	_ "embed"
	"encoding/json"
	"errors"
	"io"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/icradp/zzz-im-server/internal/protocol"
)

const deterministicEvalCorpusVersion = 1

//go:embed testdata/eval/v1.json
var deterministicEvalCorpusJSON []byte

type deterministicEvalCorpus struct {
	Version          int                  `json:"version"`
	Gate             []evalGateCase       `json:"gate"`
	Credentials      []evalCredentialCase `json:"credentials"`
	OutputPolicy     []evalOutputCase     `json:"output_policy"`
	ZZZIntent        []evalZZZIntentCase  `json:"zzz_intent"`
	PlannerDecisions []evalPlannerCase    `json:"planner_decisions"`
	MediaBatches     []evalMediaBatchCase `json:"media_batches"`
	BehaviorRecall   []evalBehaviorCase   `json:"behavior_recall"`
}

type evalGateCase struct {
	ID               string `json:"id"`
	MessageType      string `json:"message_type"`
	Text             string `json:"text"`
	SenderID         string `json:"sender_id"`
	Mention          bool   `json:"mention"`
	MediaKind        string `json:"media_kind"`
	GroupEnabled     *bool  `json:"group_enabled"`
	SoftMode         string `json:"soft_mode"`
	FocusSender      string `json:"focus_sender"`
	CommitSoftBefore bool   `json:"commit_soft_before"`
	InvalidField     string `json:"invalid_field"`
	Expected         struct {
		Action string `json:"action"`
		Reason string `json:"reason"`
		Hard   bool   `json:"hard"`
		Shadow bool   `json:"shadow"`
	} `json:"expected"`
}

type evalCredentialCase struct {
	ID        string `json:"id"`
	Text      string `json:"text"`
	Sensitive bool   `json:"sensitive"`
}

type evalOutputCase struct {
	ID           string `json:"id"`
	Text         string `json:"text"`
	MaxRunes     int    `json:"max_runes"`
	ExpectedText string `json:"expected_text"`
	ExpectedCode string `json:"expected_code"`
}

type evalZZZIntentCase struct {
	ID          string `json:"id"`
	Text        string `json:"text"`
	DirectMatch bool   `json:"direct_match"`
	UID         string `json:"uid"`
	AgentIntent bool   `json:"agent_intent"`
}

type evalPlannerCase struct {
	ID             string `json:"id"`
	Response       string `json:"response"`
	Valid          bool   `json:"valid"`
	ExpectedAction string `json:"expected_action"`
}

type evalMediaBatchCase struct {
	ID         string `json:"id"`
	Images     int    `json:"images"`
	Records    int    `json:"records"`
	MissingURL bool   `json:"missing_url"`
	Present    bool   `json:"present"`
	Valid      bool   `json:"valid"`
}

type evalBehaviorCase struct {
	ID          string                     `json:"id"`
	MessageType string                     `json:"message_type"`
	Text        string                     `json:"text"`
	Experiences []BehaviorExperienceConfig `json:"experiences"`
	ExpectedIDs []string                   `json:"expected_ids"`
}

func TestDeterministicEvalCorpus(t *testing.T) {
	corpus := loadDeterministicEvalCorpus(t)
	seen := make(map[string]string)
	claim := func(suite, id string) {
		t.Helper()
		if id == "" {
			t.Fatalf("%s eval case has an empty id", suite)
		}
		if previous, exists := seen[id]; exists {
			t.Fatalf("duplicate eval id %q in %s and %s", id, previous, suite)
		}
		seen[id] = suite
	}

	runGateEvals(t, corpus.Gate, claim)
	runCredentialEvals(t, corpus.Credentials, claim)
	runOutputPolicyEvals(t, corpus.OutputPolicy, claim)
	runZZZIntentEvals(t, corpus.ZZZIntent, claim)
	runPlannerDecisionEvals(t, corpus.PlannerDecisions, claim)
	runMediaBatchEvals(t, corpus.MediaBatches, claim)
	runBehaviorRecallEvals(t, corpus.BehaviorRecall, claim)
}

func loadDeterministicEvalCorpus(t *testing.T) deterministicEvalCorpus {
	t.Helper()
	decoder := json.NewDecoder(bytes.NewReader(deterministicEvalCorpusJSON))
	decoder.DisallowUnknownFields()
	var corpus deterministicEvalCorpus
	if err := decoder.Decode(&corpus); err != nil {
		t.Fatalf("decode deterministic eval corpus: %v", err)
	}
	if err := ensureEvalJSONEOF(decoder); err != nil {
		t.Fatal(err)
	}
	if corpus.Version != deterministicEvalCorpusVersion {
		t.Fatalf("eval corpus version=%d want=%d", corpus.Version, deterministicEvalCorpusVersion)
	}
	if len(corpus.Gate) == 0 || len(corpus.Credentials) == 0 || len(corpus.OutputPolicy) == 0 ||
		len(corpus.ZZZIntent) == 0 || len(corpus.PlannerDecisions) == 0 || len(corpus.MediaBatches) == 0 ||
		len(corpus.BehaviorRecall) == 0 {
		t.Fatal("every deterministic eval suite must contain cases")
	}
	return corpus
}

func runBehaviorRecallEvals(t *testing.T, cases []evalBehaviorCase, claim func(string, string)) {
	t.Helper()
	for _, testCase := range cases {
		testCase := testCase
		claim("behavior_recall", testCase.ID)
		t.Run("behavior_recall/"+testCase.ID, func(t *testing.T) {
			got := selectBehaviorExperiences(testCase.Experiences, testCase.MessageType, testCase.Text)
			ids := make([]string, len(got))
			for index := range got {
				ids[index] = got[index].ID
			}
			if strings.Join(ids, ",") != strings.Join(testCase.ExpectedIDs, ",") {
				t.Fatalf("selected IDs=%v want=%v", ids, testCase.ExpectedIDs)
			}
		})
	}
}

func ensureEvalJSONEOF(decoder *json.Decoder) error {
	var trailing interface{}
	if err := decoder.Decode(&trailing); !errors.Is(err, io.EOF) {
		if err == nil {
			return errors.New("deterministic eval corpus contains trailing JSON")
		}
		return err
	}
	return nil
}

func runGateEvals(t *testing.T, cases []evalGateCase, claim func(string, string)) {
	t.Helper()
	for _, testCase := range cases {
		testCase := testCase
		claim("gate", testCase.ID)
		t.Run("gate/"+testCase.ID, func(t *testing.T) {
			groupEnabled := true
			if testCase.GroupEnabled != nil {
				groupEnabled = *testCase.GroupEnabled
			}
			softMode := GroupSoftShadow
			if testCase.SoftMode != "" {
				softMode = GroupSoftMode(testCase.SoftMode)
			}
			state, err := OpenStateStoreWithDefaults(filepath.Join(t.TempDir(), "state.json"), groupEnabled, softMode)
			if err != nil {
				t.Fatal(err)
			}
			gate := NewMessageGate("fairy", state)
			now := time.Date(2026, time.September, 2, 12, 0, 0, 0, time.UTC)
			conversationID := "private_alice_fairy"
			if testCase.MessageType == "group" {
				conversationID = "group_eval"
			}
			if testCase.FocusSender != "" {
				seed := evalMessageEvent(testCase.ID+"-focus", conversationID, "group", testCase.FocusSender, "seed focus", true, "")
				decision := gate.Evaluate(seed, BehaviorConfig{GroupSoftDefault: softMode, FocusTTL: 2 * time.Minute, SoftCooldown: 30 * time.Second}, now, true)
				if decision.Action != GateTrigger {
					t.Fatalf("focus seed decision=%#v", decision)
				}
				if testCase.CommitSoftBefore {
					soft := evalMessageEvent(testCase.ID+"-soft", conversationID, "group", testCase.FocusSender, "follow up", false, "")
					if decision := gate.Evaluate(soft, BehaviorConfig{GroupSoftDefault: softMode, FocusTTL: 2 * time.Minute, SoftCooldown: 30 * time.Second}, now.Add(time.Second), true); decision.Action != GateTrigger {
						t.Fatalf("soft seed decision=%#v", decision)
					}
				}
			}
			senderID := testCase.SenderID
			if senderID == "" {
				senderID = "alice"
			}
			event := evalMessageEvent(testCase.ID, conversationID, testCase.MessageType, senderID, testCase.Text, testCase.Mention, testCase.MediaKind)
			switch testCase.InvalidField {
			case "sender_id":
				event.Sender.UserID = ""
			case "conversation_id":
				event.ConversationID = ""
			case "message_id":
				event.MessageID = ""
			case "":
			default:
				t.Fatalf("unknown invalid_field %q", testCase.InvalidField)
			}
			got := gate.Evaluate(event, BehaviorConfig{GroupSoftDefault: softMode, FocusTTL: 2 * time.Minute, SoftCooldown: 30 * time.Second}, now.Add(2*time.Second), false)
			want := GateDecision{Action: GateAction(testCase.Expected.Action), Reason: testCase.Expected.Reason, Hard: testCase.Expected.Hard, Shadow: testCase.Expected.Shadow}
			if got != want {
				t.Fatalf("decision=%#v want=%#v", got, want)
			}
		})
	}
}

func evalMessageEvent(id, conversationID, messageType, senderID, text string, mention bool, mediaKind string) messageEvent {
	segments := make([]protocol.MessageSegment, 0, 3)
	if mention {
		segments = append(segments, protocol.AtSegment("fairy"))
	}
	if text != "" {
		segments = append(segments, protocol.TextSegment(text))
	}
	if mediaKind != "" {
		segments = append(segments, protocol.MessageSegment{Type: mediaKind, Data: map[string]interface{}{
			"url": "https://media.example.test/input",
		}})
	}
	return messageEvent{
		PostType: "message", MessageType: messageType, MessageID: id,
		ConversationID: conversationID, Sender: protocol.Sender{UserID: senderID}, Message: segments,
	}
}

func runCredentialEvals(t *testing.T, cases []evalCredentialCase, claim func(string, string)) {
	t.Helper()
	for _, testCase := range cases {
		testCase := testCase
		claim("credentials", testCase.ID)
		t.Run("credentials/"+testCase.ID, func(t *testing.T) {
			if got := containsSensitiveCredential(testCase.Text); got != testCase.Sensitive {
				t.Fatalf("sensitive=%v want=%v", got, testCase.Sensitive)
			}
		})
	}
}

func runOutputPolicyEvals(t *testing.T, cases []evalOutputCase, claim func(string, string)) {
	t.Helper()
	for _, testCase := range cases {
		testCase := testCase
		claim("output_policy", testCase.ID)
		t.Run("output_policy/"+testCase.ID, func(t *testing.T) {
			output, err := ApplyOutputPolicy(testCase.Text, testCase.MaxRunes)
			if testCase.ExpectedCode == "" {
				if err != nil || output != testCase.ExpectedText {
					t.Fatalf("output=%q err=%v want=%q", output, err, testCase.ExpectedText)
				}
				return
			}
			var failure *AgentFailure
			if !errors.As(err, &failure) || string(failure.Code) != testCase.ExpectedCode || output != "" {
				t.Fatalf("output=%q failure=%#v err=%v", output, failure, err)
			}
		})
	}
}

func runZZZIntentEvals(t *testing.T, cases []evalZZZIntentCase, claim func(string, string)) {
	t.Helper()
	plugin := NewZZZPlugin(testConfig(t))
	for _, testCase := range cases {
		testCase := testCase
		claim("zzz_intent", testCase.ID)
		t.Run("zzz_intent/"+testCase.ID, func(t *testing.T) {
			uid, direct := zzzUIDFromRequest(testCase.Text)
			intent := plugin.MatchToolIntent(PluginRequest{Text: testCase.Text})
			if direct != testCase.DirectMatch || uid != testCase.UID || intent != testCase.AgentIntent {
				t.Fatalf("direct=%v uid=%q intent=%v", direct, uid, intent)
			}
		})
	}
}

func runPlannerDecisionEvals(t *testing.T, cases []evalPlannerCase, claim func(string, string)) {
	t.Helper()
	for _, testCase := range cases {
		testCase := testCase
		claim("planner_decisions", testCase.ID)
		t.Run("planner_decisions/"+testCase.ID, func(t *testing.T) {
			decision, err := decodePlannerDecision(testCase.Response)
			if !testCase.Valid {
				if err == nil {
					t.Fatalf("invalid decision decoded as %#v", decision)
				}
				return
			}
			if err != nil || string(decision.Action) != testCase.ExpectedAction {
				t.Fatalf("decision=%#v err=%v", decision, err)
			}
		})
	}
}

func runMediaBatchEvals(t *testing.T, cases []evalMediaBatchCase, claim func(string, string)) {
	t.Helper()
	for _, testCase := range cases {
		testCase := testCase
		claim("media_batches", testCase.ID)
		t.Run("media_batches/"+testCase.ID, func(t *testing.T) {
			segments := make([]protocol.MessageSegment, 0, testCase.Images+testCase.Records)
			for index := 0; index < testCase.Images; index++ {
				segments = append(segments, evalMediaSegment("image", index, testCase.MissingURL))
			}
			for index := 0; index < testCase.Records; index++ {
				segments = append(segments, evalMediaSegment("record", index+testCase.Images, testCase.MissingURL))
			}
			summary := summarizeMediaInputs(segments)
			if summary.present() != testCase.Present || (summary.validateBatch() == nil) != testCase.Valid {
				t.Fatalf("present=%v validate=%v", summary.present(), summary.validateBatch())
			}
		})
	}
}

func evalMediaSegment(kind string, index int, missingURL bool) protocol.MessageSegment {
	url := "https://media.example.test/input"
	if missingURL && index == 0 {
		url = ""
	}
	return protocol.MessageSegment{Type: kind, Data: map[string]interface{}{"url": url}}
}
