package gateway

import (
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/gorilla/websocket"
	"github.com/icradp/zzz-im-server/internal/store"
)

func TestProfileCardsTitlesBlockingAndReports(t *testing.T) {
	database := store.NewMemoryStore()
	gateway := NewGateway(database)
	server := httptest.NewServer(gateway)
	t.Cleanup(server.Close)
	websocketURL := "ws" + strings.TrimPrefix(server.URL, "http")
	owner := authenticatedGroupClient(t, websocketURL, "owner")
	member := authenticatedGroupClient(t, websocketURL, "member")
	addTestFriend(t, database, "owner", "member")

	groupData := responseData(t, request(t, owner, "create_group", map[string]interface{}{
		"name": "Title Lab", "members": []string{"member"},
	}))
	groupID := groupData["group_id"].(string)
	_ = readJSON(t, member)

	denied := request(t, member, "grant_user_title", map[string]interface{}{
		"group_id": groupID, "user_id": "owner", "text": "Not allowed", "style": "red",
	})
	if denied["status"] == "ok" {
		t.Fatalf("ordinary member granted a title: %#v", denied)
	}
	granted := responseData(t, request(t, owner, "grant_user_title", map[string]interface{}{
		"group_id": groupID, "user_id": "member", "text": "Hollow Expert", "style": "aurora",
	}))
	if granted["scope_type"] != "group" || granted["style"] != "aurora" {
		t.Fatalf("unexpected title: %#v", granted)
	}

	profileUpdate := responseData(t, request(t, member, "update_profile", map[string]interface{}{
		"bio": "Always online", "card_background_url": "https://images.example/card.webp",
		"card_background_color": "#123abc", "card_background_sensitive": true,
		"show_mutual_groups": true, "show_account_id": false,
	}))
	if profileUpdate["bio"] != "Always online" || profileUpdate["card_background_url"] == "" ||
		profileUpdate["card_background_color"] != "#123ABC" || profileUpdate["show_account_id"] != false {
		t.Fatalf("profile fields missing: %#v", profileUpdate)
	}
	_ = readJSON(t, owner)
	invalid := request(t, member, "update_profile", map[string]interface{}{
		"card_background_url": "http://insecure.example/card.png",
	})
	if invalid["status"] == "ok" {
		t.Fatalf("insecure profile background accepted: %#v", invalid)
	}
	invalidColor := request(t, member, "update_profile", map[string]interface{}{
		"card_background_color": "red",
	})
	if invalidColor["status"] == "ok" {
		t.Fatalf("invalid profile background color accepted: %#v", invalidColor)
	}
	for _, privateURL := range []string{
		"https://localhost/card.png",
		"https://127.0.0.1/card.png",
		"https://192.168.1.2/card.png",
	} {
		response := request(t, member, "update_profile", map[string]interface{}{
			"card_background_url": privateURL,
		})
		if response["status"] == "ok" {
			t.Fatalf("private profile background accepted: %s", privateURL)
		}
	}

	profile := responseData(t, request(t, owner, "get_user", map[string]interface{}{
		"user_id": "member", "group_id": groupID,
	}))
	if _, exposed := profile["user_id"]; exposed {
		t.Fatalf("hidden account ID was exposed in profile response: %#v", profile)
	}
	titles := profile["titles"].([]interface{})
	if len(titles) != 1 || len(profile["mutual_groups"].([]interface{})) != 1 {
		t.Fatalf("profile context missing titles or mutual groups: %#v", profile)
	}

	assertOK(t, request(t, owner, "report_user", map[string]interface{}{
		"user_id": "member", "reason": "spam", "details": "Repeated links",
	}))
	reports, err := database.GetUserReports(10)
	if err != nil || len(reports) != 1 || reports[0].TargetID != "member" {
		t.Fatalf("report was not persisted: reports=%#v err=%v", reports, err)
	}
	assertOK(t, request(t, owner, "ensure_conversation", map[string]interface{}{
		"conversation_id": "private_member_owner", "type": "private",
		"participants": []string{"member", "owner"},
	}))
	if conversations := responseDataList(t, request(t, owner, "get_conversations", map[string]interface{}{})); countConversationType(conversations, "private") != 1 {
		t.Fatalf("direct conversation missing before blocking: %#v", conversations)
	}

	assertOK(t, request(t, owner, "set_user_blocked", map[string]interface{}{
		"user_id": "member", "blocked": true,
	}))
	removeNotice := readJSON(t, member)
	if removeNotice["notice_type"] != "friend_remove" || removeNotice["user_id"] != "owner" {
		t.Fatalf("unexpected remove notice after blocking: %#v", removeNotice)
	}
	blockedRequest := request(t, member, "friend_request", map[string]interface{}{
		"user_id": "owner",
	})
	if blockedRequest["status"] == "ok" {
		t.Fatalf("blocked friend request was accepted: %#v", blockedRequest)
	}
	if friends, _ := database.AreFriends("owner", "member"); friends {
		t.Fatal("blocking did not remove the friendship")
	}
	for name, connection := range map[string]*websocket.Conn{"owner": owner, "member": member} {
		if conversations := responseDataList(t, request(t, connection, "get_conversations", map[string]interface{}{})); countConversationType(conversations, "private") != 0 {
			t.Fatalf("%s retained a blocked direct conversation: %#v", name, conversations)
		}
	}
	assertOK(t, request(t, owner, "set_user_blocked", map[string]interface{}{
		"user_id": "member", "blocked": false,
	}))
	if friends, _ := database.AreFriends("owner", "member"); friends {
		t.Fatal("unblocking unexpectedly restored the friendship")
	}
	if conversations := responseDataList(t, request(t, owner, "get_conversations", map[string]interface{}{})); countConversationType(conversations, "private") != 0 {
		t.Fatalf("unblocking without re-friending restored the conversation: %#v", conversations)
	}
}

func countConversationType(conversations []interface{}, conversationType string) int {
	count := 0
	for _, raw := range conversations {
		conversation, ok := raw.(map[string]interface{})
		if ok && conversation["type"] == conversationType {
			count++
		}
	}
	return count
}
