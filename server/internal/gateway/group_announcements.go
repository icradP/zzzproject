package gateway

import (
	"strings"

	"github.com/icradp/zzz-im-server/internal/protocol"
	"github.com/icradp/zzz-im-server/internal/store"
)

func (g *Gateway) handleGetGroupAnnouncements(client *Client, req *protocol.Request) {
	groupID, ok := g.groupAnnouncementTarget(client, req, false)
	if !ok {
		return
	}
	announcements, err := g.store.GetGroupAnnouncements(groupID, client.userID)
	if err != nil {
		g.sendError(client, req.Echo, "failed to load group announcements")
		return
	}
	if announcements == nil {
		announcements = []*store.GroupAnnouncement{}
	}
	g.sendJSON(client, protocol.Response{Status: "ok", RetCode: 0, Data: announcements, Echo: req.Echo})
}

func (g *Gateway) handleCreateGroupAnnouncement(client *Client, req *protocol.Request) {
	groupID, ok := g.groupAnnouncementTarget(client, req, true)
	if !ok {
		return
	}
	params := req.Params.(map[string]interface{})
	content, valid := params["content"].(string)
	content = strings.TrimSpace(content)
	isPinned, pinnedOK := params["is_pinned"].(bool)
	if !valid || content == "" || len(content) > 2000 || !pinnedOK {
		g.sendError(client, req.Echo, "announcement content must be 1-2000 characters")
		return
	}
	announcement, err := g.store.CreateGroupAnnouncement(groupID, content, client.userID, isPinned)
	if err != nil {
		g.sendError(client, req.Echo, "failed to create group announcement")
		return
	}
	_ = g.store.MarkGroupAnnouncementRead(announcement.ID, client.userID)
	announcement.IsRead = true
	g.syncLegacyGroupAnnouncement(groupID)
	g.sendJSON(client, protocol.Response{Status: "ok", RetCode: 0, Data: announcement, Echo: req.Echo})
	g.publishGroupAnnouncement(client.userID, announcement)
}

func (g *Gateway) handleUpdateGroupAnnouncement(client *Client, req *protocol.Request) {
	announcement, ok := g.groupAnnouncementByID(client, req, true)
	if !ok {
		return
	}
	params := req.Params.(map[string]interface{})
	content, valid := params["content"].(string)
	content = strings.TrimSpace(content)
	isPinned, pinnedOK := params["is_pinned"].(bool)
	if !valid || content == "" || len(content) > 2000 || !pinnedOK {
		g.sendError(client, req.Echo, "announcement content must be 1-2000 characters")
		return
	}
	updated, err := g.store.UpdateGroupAnnouncement(announcement.ID, content, isPinned)
	if err != nil || updated == nil {
		g.sendError(client, req.Echo, "failed to update group announcement")
		return
	}
	updated.IsRead = true
	_ = g.store.MarkGroupAnnouncementRead(updated.ID, client.userID)
	g.syncLegacyGroupAnnouncement(updated.GroupID)
	g.sendJSON(client, protocol.Response{Status: "ok", RetCode: 0, Data: updated, Echo: req.Echo})
	g.broadcastGroupAnnouncementNotice(updated.GroupID, updated.ID, client.userID, "updated")
}

func (g *Gateway) handleDeleteGroupAnnouncement(client *Client, req *protocol.Request) {
	announcement, ok := g.groupAnnouncementByID(client, req, true)
	if !ok {
		return
	}
	deleted, err := g.store.DeleteGroupAnnouncement(announcement.ID)
	if err != nil || !deleted {
		g.sendError(client, req.Echo, "failed to delete group announcement")
		return
	}
	g.syncLegacyGroupAnnouncement(announcement.GroupID)
	g.sendJSON(client, protocol.Response{Status: "ok", RetCode: 0, Echo: req.Echo})
	g.broadcastGroupAnnouncementNotice(announcement.GroupID, announcement.ID, client.userID, "deleted")
}

func (g *Gateway) handleMarkGroupAnnouncementRead(client *Client, req *protocol.Request) {
	announcement, ok := g.groupAnnouncementByID(client, req, false)
	if !ok {
		return
	}
	if err := g.store.MarkGroupAnnouncementRead(announcement.ID, client.userID); err != nil {
		g.sendError(client, req.Echo, "failed to mark group announcement read")
		return
	}
	g.sendJSON(client, protocol.Response{Status: "ok", RetCode: 0, Echo: req.Echo})
	g.sendToUser(client.userID, protocol.NoticeEvent{
		PostType: "notice", NoticeType: protocol.NoticeTypeGroupAnnouncement,
		GroupID: announcement.GroupID, AnnouncementID: announcement.ID,
		OperatorID: client.userID, Action: "read",
	})
}

func (g *Gateway) groupAnnouncementTarget(client *Client, req *protocol.Request, requireManager bool) (string, bool) {
	if client.userID == "" {
		g.sendError(client, req.Echo, "not authenticated")
		return "", false
	}
	params, ok := req.Params.(map[string]interface{})
	if !ok {
		g.sendError(client, req.Echo, "invalid group announcement params")
		return "", false
	}
	groupID, _ := params["group_id"].(string)
	member, err := g.store.IsGroupMember(groupID, client.userID)
	if groupID == "" || err != nil || !member {
		g.sendError(client, req.Echo, "group access denied")
		return "", false
	}
	if requireManager && !g.isGroupAdmin(groupID, client.userID) {
		g.sendError(client, req.Echo, "group permission denied")
		return "", false
	}
	return groupID, true
}

func (g *Gateway) groupAnnouncementByID(client *Client, req *protocol.Request, requireManager bool) (*store.GroupAnnouncement, bool) {
	if client.userID == "" {
		g.sendError(client, req.Echo, "not authenticated")
		return nil, false
	}
	params, ok := req.Params.(map[string]interface{})
	if !ok {
		g.sendError(client, req.Echo, "invalid group announcement params")
		return nil, false
	}
	id, _ := params["announcement_id"].(string)
	announcement, err := g.store.GetGroupAnnouncement(id)
	if id == "" || err != nil || announcement == nil {
		g.sendError(client, req.Echo, "group announcement not found")
		return nil, false
	}
	member, err := g.store.IsGroupMember(announcement.GroupID, client.userID)
	if err != nil || !member {
		g.sendError(client, req.Echo, "group access denied")
		return nil, false
	}
	if requireManager && !g.isGroupAdmin(announcement.GroupID, client.userID) {
		g.sendError(client, req.Echo, "group permission denied")
		return nil, false
	}
	return announcement, true
}

func (g *Gateway) syncLegacyGroupAnnouncement(groupID string) {
	group, err := g.store.GetGroup(groupID)
	if err != nil || group == nil {
		return
	}
	announcements, err := g.store.GetGroupAnnouncements(groupID, "")
	if err != nil {
		return
	}
	content := ""
	if len(announcements) > 0 {
		content = announcements[0].Content
	}
	_ = g.store.UpdateGroup(groupID, group.Name, group.Avatar, content, group.MuteAll)
}

func (g *Gateway) publishGroupAnnouncement(authorID string, announcement *store.GroupAnnouncement) {
	user, _ := g.store.GetUser(authorID)
	nickname := authorID
	avatar := ""
	if user != nil {
		nickname = user.Nickname
		avatar = user.Avatar
	}
	segments := []protocol.MessageSegment{{
		Type: "system",
		Data: map[string]interface{}{
			"text":            "Group announcement: " + announcement.Content,
			"event":           "group_announcement",
			"announcement_id": announcement.ID,
		},
	}}
	message, err := g.store.StoreMessage(announcement.GroupID, authorID, nickname, segments)
	if err == nil {
		g.broadcastToConversation(announcement.GroupID, protocol.MessageEvent{
			PostType: "message", MessageType: "group", MessageID: message.ID,
			ConversationID: announcement.GroupID,
			Sender:         protocol.Sender{UserID: authorID, Nickname: nickname, Avatar: avatar},
			Message:        segments, Timestamp: message.Timestamp.Unix(),
		}, "")
		g.pushToConversation(announcement.GroupID, message, authorID, true)
	}
	g.broadcastGroupAnnouncementNotice(announcement.GroupID, announcement.ID, authorID, "created")
}

func (g *Gateway) broadcastGroupAnnouncementNotice(groupID, announcementID, operatorID, action string) {
	g.broadcastToConversation(groupID, protocol.NoticeEvent{
		PostType: "notice", NoticeType: protocol.NoticeTypeGroupAnnouncement,
		GroupID: groupID, AnnouncementID: announcementID,
		OperatorID: operatorID, Action: action,
	}, "")
}
