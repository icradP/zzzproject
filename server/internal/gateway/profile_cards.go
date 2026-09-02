package gateway

import (
	"errors"
	"fmt"
	"net"
	"net/url"
	"strings"
	"time"

	"github.com/icradp/zzz-im-server/internal/protocol"
	"github.com/icradp/zzz-im-server/internal/store"
)

var allowedTitleStyles = map[string]bool{
	"gold": true, "red": true, "yellow": true, "aurora": true, "ember": true,
}

var allowedReportReasons = map[string]bool{
	"spam": true, "harassment": true, "impersonation": true,
	"inappropriate": true, "other": true,
}

func validProfileBackgroundURL(raw string) bool {
	if raw == "" {
		return true
	}
	if len(raw) > 2048 || raw != strings.TrimSpace(raw) {
		return false
	}
	parsed, err := url.ParseRequestURI(raw)
	if err != nil || parsed.Scheme != "https" || parsed.Host == "" || parsed.User != nil {
		return false
	}
	host := strings.TrimSuffix(strings.ToLower(parsed.Hostname()), ".")
	if host == "localhost" || strings.HasSuffix(host, ".localhost") {
		return false
	}
	if ip := net.ParseIP(host); ip != nil {
		return !ip.IsLoopback() && !ip.IsPrivate() && !ip.IsUnspecified() &&
			!ip.IsLinkLocalUnicast() && !ip.IsLinkLocalMulticast() && !ip.IsMulticast()
	}
	return true
}

func validProfileBackgroundColor(raw string) bool {
	if raw == "" {
		return true
	}
	if len(raw) != 7 || raw[0] != '#' {
		return false
	}
	for _, char := range raw[1:] {
		if !((char >= '0' && char <= '9') ||
			(char >= 'a' && char <= 'f') || (char >= 'A' && char <= 'F')) {
			return false
		}
	}
	return true
}

func protocolTitle(title *store.UserTitle) protocol.UserTitle {
	result := protocol.UserTitle{
		TitleID: title.ID, ScopeType: title.ScopeType, ScopeID: title.ScopeID,
		Text: title.Text, Style: title.Style, GrantedBy: title.GrantedBy,
		CreatedAt: title.CreatedAt.Unix(),
	}
	if title.ExpiresAt != nil {
		result.ExpiresAt = title.ExpiresAt.Unix()
	}
	return result
}

func (g *Gateway) profileUser(viewerID string, user *store.User, groupID string) protocol.User {
	visibleUserID := user.ID
	if viewerID != user.ID && !user.ShowAccountID {
		visibleUserID = ""
	}
	result := protocol.User{
		UserID: visibleUserID, Nickname: user.Nickname, Avatar: user.Avatar,
		Bio: user.Bio, CardBackgroundURL: user.CardBackgroundURL,
		CardBackgroundColor:     user.CardBackgroundColor,
		CardBackgroundSensitive: user.CardBackgroundSensitive,
		ShowMutualGroups:        user.ShowMutualGroups,
		ShowAccountID:           user.ShowAccountID, Online: user.Online,
	}
	if blocked, _ := g.store.IsUserBlocked(viewerID, user.ID); blocked {
		result.Relationship = "blocked"
	} else if blockedBy, _ := g.store.IsUserBlocked(user.ID, viewerID); blockedBy {
		result.Relationship = "blocked_by"
	} else if friends, _ := g.store.AreFriends(viewerID, user.ID); friends {
		result.Relationship = "friend"
	}
	if titles, err := g.store.GetUserTitles(user.ID, groupID); err == nil {
		result.Titles = make([]protocol.UserTitle, 0, len(titles))
		for _, title := range titles {
			result.Titles = append(result.Titles, protocolTitle(title))
		}
	}
	if user.ShowMutualGroups || viewerID == user.ID {
		result.MutualGroups = g.mutualGroups(viewerID, user.ID)
	}
	return result
}

func (g *Gateway) mutualGroups(viewerID, targetID string) []protocol.Group {
	viewerGroups, viewerErr := g.store.GetUserGroups(viewerID)
	targetGroups, targetErr := g.store.GetUserGroups(targetID)
	if viewerErr != nil || targetErr != nil {
		return nil
	}
	viewerSet := make(map[string]bool, len(viewerGroups))
	for _, group := range viewerGroups {
		viewerSet[group.ID] = true
	}
	result := make([]protocol.Group, 0)
	for _, group := range targetGroups {
		if !viewerSet[group.ID] {
			continue
		}
		members, _ := g.store.GetGroupMembers(group.ID)
		result = append(result, protocol.Group{
			GroupID: group.ID, Name: group.Name, Avatar: group.Avatar,
			OwnerID: group.OwnerID, MemberCount: len(members), MuteAll: group.MuteAll,
		})
	}
	return result
}

func (g *Gateway) isEitherBlocked(firstID, secondID string) bool {
	blocked, _ := g.store.IsUserBlocked(firstID, secondID)
	if blocked {
		return true
	}
	blocked, _ = g.store.IsUserBlocked(secondID, firstID)
	return blocked
}

func (g *Gateway) handleSetUserBlocked(client *Client, req *protocol.Request) {
	if client.userID == "" {
		g.sendError(client, req.Echo, "not authenticated")
		return
	}
	params, ok := req.Params.(map[string]interface{})
	if !ok {
		g.sendError(client, req.Echo, "invalid set_user_blocked params")
		return
	}
	targetID, _ := params["user_id"].(string)
	blocked, ok := params["blocked"].(bool)
	targetID = strings.TrimSpace(targetID)
	if !ok || targetID == "" || targetID == client.userID {
		g.sendError(client, req.Echo, "valid target user and blocked state required")
		return
	}
	if target, _ := g.store.GetUser(targetID); target == nil {
		g.sendError(client, req.Echo, "user not found")
		return
	}
	if err := g.store.SetUserBlocked(client.userID, targetID, blocked); err != nil {
		g.sendError(client, req.Echo, "failed to update block state")
		return
	}
	if blocked {
		if removed, _ := g.store.RemoveFriend(client.userID, targetID); removed {
			g.sendToUser(targetID, protocol.NoticeEvent{
				PostType:   "notice",
				NoticeType: protocol.NoticeTypeFriendRemove,
				UserID:     client.userID,
			})
		}
	}
	g.sendJSON(client, protocol.Response{Status: "ok", RetCode: 0, Echo: req.Echo,
		Data: map[string]interface{}{"user_id": targetID, "blocked": blocked}})
}

func (g *Gateway) handleReportUser(client *Client, req *protocol.Request) {
	if client.userID == "" {
		g.sendError(client, req.Echo, "not authenticated")
		return
	}
	params, ok := req.Params.(map[string]interface{})
	if !ok {
		g.sendError(client, req.Echo, "invalid report_user params")
		return
	}
	targetID, _ := params["user_id"].(string)
	reason, _ := params["reason"].(string)
	details, _ := params["details"].(string)
	targetID, reason, details = strings.TrimSpace(targetID), strings.TrimSpace(reason), strings.TrimSpace(details)
	if targetID == "" || targetID == client.userID || !allowedReportReasons[reason] || len([]rune(details)) > 500 {
		g.sendError(client, req.Echo, "report target, reason, or details are invalid")
		return
	}
	if target, _ := g.store.GetUser(targetID); target == nil {
		g.sendError(client, req.Echo, "user not found")
		return
	}
	report := &store.UserReport{
		ID: fmt.Sprintf("report_%d", time.Now().UnixNano()), ReporterID: client.userID,
		TargetID: targetID, Reason: reason, Details: details, CreatedAt: time.Now(),
	}
	if err := g.store.CreateUserReport(report); err != nil {
		g.sendError(client, req.Echo, "failed to submit report")
		return
	}
	g.sendJSON(client, protocol.Response{Status: "ok", RetCode: 0, Echo: req.Echo,
		Data: map[string]interface{}{"report_id": report.ID}})
}

func (g *Gateway) handleGrantUserTitle(client *Client, req *protocol.Request) {
	if client.userID == "" {
		g.sendError(client, req.Echo, "not authenticated")
		return
	}
	params, ok := req.Params.(map[string]interface{})
	if !ok {
		g.sendError(client, req.Echo, "invalid grant_user_title params")
		return
	}
	groupID, _ := params["group_id"].(string)
	targetID, _ := params["user_id"].(string)
	text, _ := params["text"].(string)
	style, _ := params["style"].(string)
	groupID, targetID, text, style = strings.TrimSpace(groupID), strings.TrimSpace(targetID), strings.TrimSpace(text), strings.TrimSpace(style)
	if groupID == "" || targetID == "" || len([]rune(text)) == 0 || len([]rune(text)) > 24 || !allowedTitleStyles[style] {
		g.sendError(client, req.Echo, "group title fields are invalid")
		return
	}
	if !g.isGroupAdmin(groupID, client.userID) {
		g.sendError(client, req.Echo, "group manager permission required")
		return
	}
	if member, _ := g.store.IsGroupMember(groupID, targetID); !member {
		g.sendError(client, req.Echo, "target user is not a group member")
		return
	}
	var expiresAt *time.Time
	if raw, exists := params["expires_at"]; exists && raw != nil && raw != "" {
		parsed, valid := parseTitleExpiration(raw)
		if !valid {
			g.sendError(client, req.Echo, "title expiration must be a future RFC3339 time")
			return
		}
		expiresAt = &parsed
	}
	title := &store.UserTitle{
		ID: fmt.Sprintf("title_%d", time.Now().UnixNano()), UserID: targetID,
		ScopeType: "group", ScopeID: groupID, Text: text, Style: style,
		GrantedBy: client.userID, ExpiresAt: expiresAt, CreatedAt: time.Now(),
	}
	if err := g.store.GrantUserTitle(title); err != nil {
		if errors.Is(err, store.ErrActiveTitleLimit) {
			g.sendError(client, req.Echo, err.Error())
			return
		}
		g.sendError(client, req.Echo, "failed to grant title")
		return
	}
	g.sendJSON(client, protocol.Response{Status: "ok", RetCode: 0, Echo: req.Echo, Data: protocolTitle(title)})
}

func parseTitleExpiration(raw interface{}) (time.Time, bool) {
	var parsed time.Time
	switch value := raw.(type) {
	case string:
		parsed, _ = time.Parse(time.RFC3339, value)
	case float64:
		parsed = time.Unix(int64(value), 0)
	}
	return parsed, parsed.After(time.Now())
}

func (g *Gateway) handleRevokeUserTitle(client *Client, req *protocol.Request) {
	if client.userID == "" {
		g.sendError(client, req.Echo, "not authenticated")
		return
	}
	params, ok := req.Params.(map[string]interface{})
	if !ok {
		g.sendError(client, req.Echo, "invalid revoke_user_title params")
		return
	}
	groupID, _ := params["group_id"].(string)
	targetID, _ := params["user_id"].(string)
	titleID, _ := params["title_id"].(string)
	if !g.isGroupAdmin(groupID, client.userID) {
		g.sendError(client, req.Echo, "group manager permission required")
		return
	}
	titles, _ := g.store.GetUserTitles(targetID, groupID)
	allowed := false
	for _, title := range titles {
		if title.ID == titleID && title.ScopeType == "group" && title.ScopeID == groupID {
			allowed = true
			break
		}
	}
	if !allowed {
		g.sendError(client, req.Echo, "group title not found")
		return
	}
	deleted, err := g.store.DeleteUserTitle(titleID)
	if err != nil || !deleted {
		g.sendError(client, req.Echo, "failed to revoke title")
		return
	}
	g.sendJSON(client, protocol.Response{Status: "ok", RetCode: 0, Echo: req.Echo})
}
