package gateway

import (
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"
	"github.com/icradp/zzz-im-server/internal/store"
)

func TestGroupAnnouncementLifecyclePermissionsAndImportantPush(t *testing.T) {
	database := store.NewMemoryStore()
	pushSender := &fakePushSender{deliveries: make(chan pushDelivery, 2)}
	gateway := NewGateway(database, pushSender)
	server := httptest.NewServer(gateway)
	t.Cleanup(server.Close)
	websocketURL := "ws" + strings.TrimPrefix(server.URL, "http")
	owner := authenticatedGroupClient(t, websocketURL, "owner")
	member := authenticatedGroupClient(t, websocketURL, "member")
	addTestFriend(t, database, "owner", "member")

	assertOK(t, request(t, member, "register_push", map[string]interface{}{
		"endpoint": "https://push.example.test/member-announcements",
		"keys":     map[string]interface{}{"p256dh": "key", "auth": "auth"},
	}))
	createdGroup := responseData(t, request(t, owner, "create_group", map[string]interface{}{
		"name": "Announcements", "members": []string{"member"},
	}))
	groupID := createdGroup["group_id"].(string)
	assertGroupNotice(t, readJSON(t, member), "group_increase", groupID, "member", "owner")

	assertOK(t, request(t, member, "set_conversation_preferences", map[string]interface{}{
		"conversation_id": groupID, "is_pinned": false, "notification_level": "mentions_only",
	}))
	_ = readJSON(t, member)
	denied := request(t, member, "create_group_announcement", map[string]interface{}{
		"group_id": groupID, "content": "Not allowed", "is_pinned": false,
	})
	if denied["status"] == "ok" {
		t.Fatalf("ordinary member published an announcement: %#v", denied)
	}

	created := responseData(t, request(t, owner, "create_group_announcement", map[string]interface{}{
		"group_id": groupID, "content": "Deployment at 20:00", "is_pinned": true,
	}))
	announcementID := created["announcement_id"].(string)
	for _, client := range []*websocket.Conn{owner, member} {
		message := readJSON(t, client)
		if message["post_type"] != "message" || message["conversation_id"] != groupID {
			t.Fatalf("announcement system message missing: %#v", message)
		}
		notice := readJSON(t, client)
		if notice["notice_type"] != "group_announcement" || notice["action"] != "created" {
			t.Fatalf("announcement notice missing: %#v", notice)
		}
	}
	select {
	case delivery := <-pushSender.deliveries:
		if delivery.subscription.UserID != "member" {
			t.Fatalf("announcement push reached wrong user: %#v", delivery)
		}
	case <-time.After(time.Second):
		t.Fatal("announcement did not bypass mentions-only filtering")
	}

	announcements := responseDataList(t, request(t, member, "get_group_announcements", map[string]interface{}{
		"group_id": groupID,
	}))
	if len(announcements) != 1 || announcements[0].(map[string]interface{})["is_read"] != false {
		t.Fatalf("unexpected unread announcement list: %#v", announcements)
	}
	assertOK(t, request(t, member, "mark_group_announcement_read", map[string]interface{}{
		"announcement_id": announcementID,
	}))
	readNotice := readJSON(t, member)
	if readNotice["action"] != "read" || readNotice["announcement_id"] != announcementID {
		t.Fatalf("unexpected read notice: %#v", readNotice)
	}
	announcements = responseDataList(t, request(t, member, "get_group_announcements", map[string]interface{}{
		"group_id": groupID,
	}))
	if announcements[0].(map[string]interface{})["is_read"] != true {
		t.Fatalf("announcement read state was not persisted: %#v", announcements)
	}

	assertOK(t, request(t, owner, "update_group_announcement", map[string]interface{}{
		"announcement_id": announcementID, "content": "Deployment at 21:00", "is_pinned": false,
	}))
	for _, client := range []*websocket.Conn{owner, member} {
		notice := readJSON(t, client)
		if notice["action"] != "updated" {
			t.Fatalf("unexpected update notice: %#v", notice)
		}
	}
	announcements = responseDataList(t, request(t, member, "get_group_announcements", map[string]interface{}{
		"group_id": groupID,
	}))
	updated := announcements[0].(map[string]interface{})
	if updated["content"] != "Deployment at 21:00" || updated["is_pinned"] != false {
		t.Fatalf("announcement update missing: %#v", updated)
	}

	assertOK(t, request(t, owner, "delete_group_announcement", map[string]interface{}{
		"announcement_id": announcementID,
	}))
	for _, client := range []*websocket.Conn{owner, member} {
		if notice := readJSON(t, client); notice["action"] != "deleted" {
			t.Fatalf("unexpected delete notice: %#v", notice)
		}
	}
	announcements = responseDataList(t, request(t, member, "get_group_announcements", map[string]interface{}{
		"group_id": groupID,
	}))
	if len(announcements) != 0 {
		t.Fatalf("deleted announcement still listed: %#v", announcements)
	}
}
