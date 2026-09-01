package fairy

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"
)

type PluginRequest struct {
	Text           string
	ConversationID string
	MessageType    string
	SenderID       string
	SenderNickname string
}

type Plugin interface {
	Name() string
	Match(request PluginRequest) bool
	Handle(ctx context.Context, request PluginRequest) (string, error)
}

type zzzCacheEntry struct {
	text      string
	expiresAt time.Time
}

// ZZZPlugin provides a read-only public-profile lookup inspired by
// ZZZeroUID. It uses Enka.Network's public ZZZ endpoint by default, sends no
// HoYoLAB cookies, and respects the upstream response TTL.
type ZZZPlugin struct {
	endpoint string
	client   *http.Client
	now      func() time.Time
	mu       sync.Mutex
	cache    map[string]zzzCacheEntry
}

func NewZZZPlugin(cfg Config) *ZZZPlugin {
	return &ZZZPlugin{
		endpoint: cfg.ZZZAPIURL,
		client:   &http.Client{Timeout: cfg.ZZZRequestTimeout},
		now:      time.Now,
		cache:    make(map[string]zzzCacheEntry),
	}
}

func (p *ZZZPlugin) Name() string { return "zzz-profile" }

func (p *ZZZPlugin) Match(request PluginRequest) bool {
	_, ok := zzzUIDFromCommand(request.Text)
	return ok
}

func (p *ZZZPlugin) Handle(ctx context.Context, request PluginRequest) (string, error) {
	uid, ok := zzzUIDFromCommand(request.Text)
	if !ok {
		return "", nil
	}
	p.mu.Lock()
	if cached, exists := p.cache[uid]; exists && p.now().Before(cached.expiresAt) {
		p.mu.Unlock()
		return cached.text, nil
	}
	p.mu.Unlock()

	endpoint := strings.Replace(p.endpoint, "{uid}", uid, 1)
	httpRequest, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint, nil)
	if err != nil {
		return "", err
	}
	httpRequest.Header.Set("Accept", "application/json")
	httpRequest.Header.Set("User-Agent", "ZZZ-IM-Fairy/1.0 (https://github.com/icradP/zzzproject)")
	response, err := p.client.Do(httpRequest)
	if err != nil {
		return "", fmt.Errorf("查询绝区零公开资料失败: %w", err)
	}
	defer response.Body.Close()
	body, err := io.ReadAll(io.LimitReader(response.Body, 2*1024*1024))
	if err != nil {
		return "", err
	}
	if response.StatusCode == http.StatusBadRequest || response.StatusCode == http.StatusNotFound {
		return "没有找到这个 UID 的公开展示资料，请确认 UID 正确并已在游戏内开启角色展示。", nil
	}
	if response.StatusCode == http.StatusTooManyRequests {
		return "公开资料服务当前请求较多，请稍后再试。", nil
	}
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return "", fmt.Errorf("绝区零公开资料服务返回 HTTP %d", response.StatusCode)
	}
	var data enkaZZZResponse
	if err := json.Unmarshal(body, &data); err != nil {
		return "", fmt.Errorf("解析绝区零公开资料失败: %w", err)
	}
	text := formatZZZProfile(uid, data)
	ttl := time.Duration(data.TTL) * time.Second
	if ttl < time.Minute {
		ttl = time.Minute
	}
	if ttl > 30*time.Minute {
		ttl = 30 * time.Minute
	}
	p.mu.Lock()
	p.cache[uid] = zzzCacheEntry{text: text, expiresAt: p.now().Add(ttl)}
	p.mu.Unlock()
	return text, nil
}

type enkaZZZResponse struct {
	UID        interface{} `json:"uid"`
	TTL        int         `json:"ttl"`
	PlayerInfo struct {
		SocialDetail struct {
			Desc          string `json:"Desc"`
			ProfileDetail struct {
				Nickname string      `json:"Nickname"`
				Level    interface{} `json:"Level"`
				Title    interface{} `json:"Title"`
			} `json:"ProfileDetail"`
			MedalList []json.RawMessage `json:"MedalList"`
		} `json:"SocialDetail"`
		ShowcaseDetail struct {
			AvatarList []struct {
				ID          interface{} `json:"Id"`
				Level       interface{} `json:"Level"`
				TalentLevel interface{} `json:"TalentLevel"`
			} `json:"AvatarList"`
		} `json:"ShowcaseDetail"`
	} `json:"PlayerInfo"`
}

func formatZZZProfile(uid string, data enkaZZZResponse) string {
	profile := data.PlayerInfo.SocialDetail.ProfileDetail
	nickname := strings.TrimSpace(profile.Nickname)
	if nickname == "" {
		nickname = "未公开昵称"
	}
	var output strings.Builder
	fmt.Fprintf(&output, "绝区零公开资料\n%s · UID %s", nickname, uid)
	if level := jsonScalar(profile.Level); level != "" {
		fmt.Fprintf(&output, " · 绳网等级 %s", level)
	}
	if description := strings.TrimSpace(data.PlayerInfo.SocialDetail.Desc); description != "" {
		fmt.Fprintf(&output, "\n签名：%s", limitRunes(description, 160))
	}
	avatars := data.PlayerInfo.ShowcaseDetail.AvatarList
	if len(avatars) > 0 {
		fmt.Fprintf(&output, "\n公开代理人：%d 位", len(avatars))
		for index, avatar := range avatars {
			if index >= 6 {
				break
			}
			fmt.Fprintf(&output, "\n- ID %s", jsonScalar(avatar.ID))
			if level := jsonScalar(avatar.Level); level != "" {
				fmt.Fprintf(&output, " · Lv.%s", level)
			}
			if cinema := jsonScalar(avatar.TalentLevel); cinema != "" && cinema != "0" {
				fmt.Fprintf(&output, " · 影画 %s", cinema)
			}
		}
	} else {
		output.WriteString("\n未公开代理人展示。")
	}
	output.WriteString("\n数据来源：Enka.Network，仅查询游戏内公开展示信息。")
	return output.String()
}

func zzzUIDFromCommand(text string) (string, bool) {
	fields := strings.Fields(strings.TrimSpace(text))
	if len(fields) < 2 {
		return "", false
	}
	command := strings.ToLower(fields[0])
	if command != "/zzz" && command != "zzz" && command != "zzz查询" && command != "绝区零查询" {
		return "", false
	}
	uid := fields[len(fields)-1]
	if len(uid) != 9 && len(uid) != 10 {
		return "", false
	}
	for _, character := range uid {
		if character < '0' || character > '9' {
			return "", false
		}
	}
	return uid, true
}

func jsonScalar(value interface{}) string {
	switch typed := value.(type) {
	case string:
		return typed
	case float64:
		return strconv.FormatFloat(typed, 'f', -1, 64)
	case json.Number:
		return typed.String()
	default:
		return ""
	}
}

func limitRunes(value string, maximum int) string {
	runes := []rune(value)
	if len(runes) <= maximum {
		return value
	}
	return string(runes[:maximum]) + "..."
}
