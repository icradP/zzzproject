package fairy

import (
	"fmt"
	"math"
	"strings"

	"github.com/icradp/zzz-im-server/internal/protocol"
)

type mediaInputKind string

const (
	mediaInputImage  mediaInputKind = "image"
	mediaInputRecord mediaInputKind = "record"
	maxMediaImages                  = 4
)

type mediaInput struct {
	Kind       mediaInputKind
	URL        string
	Name       string
	MIMEType   string
	Size       int64
	DurationMS int64
}

type mediaInputSummary struct {
	images  int
	records int
	inputs  []mediaInput
}

func summarizeMediaInputs(segments []protocol.MessageSegment) mediaInputSummary {
	var summary mediaInputSummary
	for _, segment := range segments {
		switch segment.Type {
		case "image":
			summary.images++
			summary.inputs = append(summary.inputs, mediaInputFromSegment(mediaInputImage, segment))
		case "record":
			summary.records++
			summary.inputs = append(summary.inputs, mediaInputFromSegment(mediaInputRecord, segment))
		}
	}
	return summary
}

func (s mediaInputSummary) present() bool {
	return s.images > 0 || s.records > 0
}

func (s mediaInputSummary) unavailableReply() string {
	switch {
	case s.images > 0 && s.records > 0:
		return "Fairy 暂未启用图片理解和语音转写。本次未下载附件，也未调用 AI。"
	case s.records > 0:
		return "Fairy 暂未启用语音转写。本次未下载语音，也未调用 AI。"
	default:
		return "Fairy 暂未启用图片理解。本次未下载图片，也未调用 AI。"
	}
}

func (s mediaInputSummary) validateBatch() error {
	switch {
	case s.images > 0 && s.records > 0:
		return fmt.Errorf("mixed image and voice input is not supported")
	case s.images > maxMediaImages:
		return fmt.Errorf("at most %d images are supported", maxMediaImages)
	case s.records > 1:
		return fmt.Errorf("only one voice message is supported")
	}
	for _, input := range s.inputs {
		if strings.TrimSpace(input.URL) == "" {
			return fmt.Errorf("media URL is required")
		}
	}
	return nil
}

func mediaInputFromSegment(kind mediaInputKind, segment protocol.MessageSegment) mediaInput {
	return mediaInput{
		Kind:       kind,
		URL:        mediaString(segment.Data, "url"),
		Name:       mediaString(segment.Data, "name"),
		MIMEType:   mediaString(segment.Data, "mime_type"),
		Size:       mediaInt64(segment.Data["size"]),
		DurationMS: mediaInt64(segment.Data["duration_ms"]),
	}
}

func mediaString(data map[string]interface{}, key string) string {
	value, _ := data[key].(string)
	return strings.TrimSpace(value)
}

func mediaInt64(value interface{}) int64 {
	switch number := value.(type) {
	case int:
		return int64(number)
	case int64:
		return number
	case float64:
		if number >= 0 && number <= math.MaxInt64 && number == math.Trunc(number) {
			return int64(number)
		}
	}
	return 0
}
