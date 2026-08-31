package gateway

import (
	"net/http/httptest"
	"slices"
	"strings"
	"testing"

	"github.com/gorilla/websocket"
	"github.com/icradp/zzz-im-server/internal/store"
)

func TestGroupInvitationPermissionsAndRealtimeUpdates(t *testing.T) {
	database, websocketURL := newGroupManagementServer(t)
	owner := authenticatedGroupClient(t, websocketURL, "owner")
	admin := authenticatedGroupClient(t, websocketURL, "admin")
	member := authenticatedGroupClient(t, websocketURL, "member")
	candidate := authenticatedGroupClient(t, websocketURL, "candidate")
	_ = authenticatedGroupClient(t, websocketURL, "nonfriend")

	addTestFriend(t, database, "owner", "admin")
	addTestFriend(t, database, "owner", "member")
	addTestFriend(t, database, "owner", "candidate")

	deniedCreate := request(t, owner, "create_group", map[string]interface{}{
		"name": "Invalid group", "members": []string{"nonfriend"},
	})
	if deniedCreate["status"] == "ok" {
		t.Fatalf("group creation accepted a non-friend: %#v", deniedCreate)
	}

	created := request(t, owner, "create_group", map[string]interface{}{
		"name": "Core team", "members": []string{"admin", "member"},
	})
	assertOK(t, created)
	groupID := responseData(t, created)["group_id"].(string)
	assertGroupNotice(t, readJSON(t, admin), "group_increase", groupID, "admin", "owner")
	assertGroupNotice(t, readJSON(t, member), "group_increase", groupID, "member", "owner")
	setMemoryGroupRole(t, database, groupID, "admin", "admin")

	invited := request(t, owner, "group_invite", map[string]interface{}{
		"group_id": groupID, "members": []string{"candidate"},
	})
	assertOK(t, invited)
	for _, client := range []*websocket.Conn{owner, admin, member, candidate} {
		assertGroupNotice(t, readJSON(t, client), "group_increase", groupID, "candidate", "owner")
	}

	deniedMemberInvite := request(t, member, "group_invite", map[string]interface{}{
		"group_id": groupID, "members": []string{"nonfriend"},
	})
	if deniedMemberInvite["status"] == "ok" {
		t.Fatalf("ordinary member invited a user: %#v", deniedMemberInvite)
	}
	deniedNonfriend := request(t, owner, "group_invite", map[string]interface{}{
		"group_id": groupID, "members": []string{"nonfriend"},
	})
	if deniedNonfriend["status"] == "ok" {
		t.Fatalf("owner invited a non-friend: %#v", deniedNonfriend)
	}
	deniedUnknown := request(t, owner, "group_invite", map[string]interface{}{
		"group_id": groupID, "members": []string{"missing-account"},
	})
	if deniedUnknown["status"] == "ok" {
		t.Fatalf("owner invited an unknown account: %#v", deniedUnknown)
	}

	conversation, err := database.GetConversation(groupID)
	if err != nil {
		t.Fatal(err)
	}
	if conversation == nil || !slices.Equal(conversation.Participants, []string{"owner", "admin", "member", "candidate"}) {
		t.Fatalf("conversation participants are stale: %#v", conversation)
	}
	info := responseData(t, request(t, candidate, "get_group_info", map[string]interface{}{
		"group_id": groupID,
	}))
	if info["member_count"] != float64(4) {
		t.Fatalf("unexpected group info after invitation: %#v", info)
	}
}

func TestGroupRemovalRolesNotificationsAndParticipantSync(t *testing.T) {
	database, websocketURL := newGroupManagementServer(t)
	owner := authenticatedGroupClient(t, websocketURL, "owner")
	admin := authenticatedGroupClient(t, websocketURL, "admin")
	member := authenticatedGroupClient(t, websocketURL, "member")
	secondAdmin := authenticatedGroupClient(t, websocketURL, "second-admin")
	for _, userID := range []string{"admin", "member", "second-admin"} {
		addTestFriend(t, database, "owner", userID)
	}

	created := request(t, owner, "create_group", map[string]interface{}{
		"name":    "Operations",
		"members": []string{"admin", "member", "second-admin"},
	})
	assertOK(t, created)
	groupID := responseData(t, created)["group_id"].(string)
	assertGroupNotice(t, readJSON(t, admin), "group_increase", groupID, "admin", "owner")
	assertGroupNotice(t, readJSON(t, member), "group_increase", groupID, "member", "owner")
	assertGroupNotice(t, readJSON(t, secondAdmin), "group_increase", groupID, "second-admin", "owner")
	setMemoryGroupRole(t, database, groupID, "admin", "admin")
	setMemoryGroupRole(t, database, groupID, "second-admin", "admin")

	for _, targetID := range []string{"owner", "second-admin"} {
		denied := request(t, admin, "group_kick", map[string]interface{}{
			"group_id": groupID, "user_id": targetID,
		})
		if denied["status"] == "ok" {
			t.Fatalf("admin removed protected role %s: %#v", targetID, denied)
		}
	}
	assertOK(t, request(t, admin, "group_kick", map[string]interface{}{
		"group_id": groupID, "user_id": "member",
	}))
	assertGroupNotice(t, readJSON(t, admin), "group_decrease", groupID, "member", "admin")
	assertGroupNotice(t, readJSON(t, owner), "group_decrease", groupID, "member", "admin")
	assertGroupNotice(t, readJSON(t, member), "group_decrease", groupID, "member", "admin")
	assertGroupNotice(t, readJSON(t, secondAdmin), "group_decrease", groupID, "member", "admin")
	assertConversationParticipants(t, database, groupID, []string{"owner", "admin", "second-admin"})

	assertOK(t, request(t, owner, "group_kick", map[string]interface{}{
		"group_id": groupID, "user_id": "second-admin",
	}))
	assertGroupNotice(t, readJSON(t, owner), "group_decrease", groupID, "second-admin", "owner")
	assertGroupNotice(t, readJSON(t, admin), "group_decrease", groupID, "second-admin", "owner")
	assertGroupNotice(t, readJSON(t, secondAdmin), "group_decrease", groupID, "second-admin", "owner")
	assertConversationParticipants(t, database, groupID, []string{"owner", "admin"})

	ownerLeave := request(t, owner, "leave_group", map[string]interface{}{"group_id": groupID})
	if ownerLeave["status"] == "ok" {
		t.Fatalf("owner left without transferring ownership: %#v", ownerLeave)
	}
	assertOK(t, request(t, admin, "leave_group", map[string]interface{}{"group_id": groupID}))
	assertGroupNotice(t, readJSON(t, admin), "group_decrease", groupID, "admin", "admin")
	assertGroupNotice(t, readJSON(t, owner), "group_decrease", groupID, "admin", "admin")
	assertConversationParticipants(t, database, groupID, []string{"owner"})

	deniedInfo := request(t, member, "get_group_info", map[string]interface{}{"group_id": groupID})
	if deniedInfo["status"] == "ok" {
		t.Fatalf("removed member retained group access: %#v", deniedInfo)
	}
}

func TestGroupGovernanceAndMuteEnforcement(t *testing.T) {
	database, websocketURL := newGroupManagementServer(t)
	owner := authenticatedGroupClient(t, websocketURL, "owner")
	admin := authenticatedGroupClient(t, websocketURL, "admin")
	member := authenticatedGroupClient(t, websocketURL, "member")
	for _, userID := range []string{"admin", "member"} {
		addTestFriend(t, database, "owner", userID)
	}

	created := request(t, owner, "create_group", map[string]interface{}{
		"name": "Governance", "members": []string{"admin", "member"},
	})
	assertOK(t, created)
	groupID := responseData(t, created)["group_id"].(string)
	assertGroupNotice(t, readJSON(t, admin), "group_increase", groupID, "admin", "owner")
	assertGroupNotice(t, readJSON(t, member), "group_increase", groupID, "member", "owner")

	deniedUpdate := request(t, member, "update_group", map[string]interface{}{
		"group_id": groupID, "name": "Hijacked",
	})
	if deniedUpdate["status"] == "ok" {
		t.Fatalf("ordinary member updated the group: %#v", deniedUpdate)
	}

	assertOK(t, request(t, owner, "set_group_admin", map[string]interface{}{
		"group_id": groupID, "user_id": "admin", "enabled": true,
	}))
	assertGovernanceNotice(t, readJSON(t, owner), "group_admin", groupID, "admin", "owner")
	assertGovernanceNotice(t, readJSON(t, admin), "group_admin", groupID, "admin", "owner")
	assertGovernanceNotice(t, readJSON(t, member), "group_admin", groupID, "admin", "owner")

	assertOK(t, request(t, admin, "update_group", map[string]interface{}{
		"group_id": groupID,
		"name":     "Core operations", "avatar_url": "https://example.test/group.png",
		"announcement": "Ship carefully.",
	}))
	for _, client := range []*websocket.Conn{owner, admin, member} {
		assertGovernanceNotice(t, readJSON(t, client), "group_update", groupID, "", "admin")
	}
	info := responseData(t, request(t, member, "get_group_info", map[string]interface{}{"group_id": groupID}))
	if info["name"] != "Core operations" || info["announcement"] != "Ship carefully." || info["avatar_url"] != "https://example.test/group.png" {
		t.Fatalf("group profile was not updated: %#v", info)
	}
	members := info["members"].([]interface{})
	adminInfo := groupMemberData(t, members, "admin")
	if adminInfo["role"] != "admin" {
		t.Fatalf("administrator role missing from group info: %#v", adminInfo)
	}

	assertOK(t, request(t, admin, "group_ban", map[string]interface{}{
		"group_id": groupID, "user_id": "member", "duration": 3600,
	}))
	for _, client := range []*websocket.Conn{owner, admin, member} {
		assertGovernanceNotice(t, readJSON(t, client), "group_ban", groupID, "member", "admin")
	}
	mutedSend := request(t, member, "send_message", map[string]interface{}{
		"conversation_id": groupID,
		"message":         []map[string]interface{}{{"type": "text", "data": map[string]interface{}{"text": "blocked"}}},
	})
	if mutedSend["status"] == "ok" || !strings.Contains(mutedSend["msg"].(string), "muted until") {
		t.Fatalf("muted member sent a message: %#v", mutedSend)
	}

	assertOK(t, request(t, owner, "group_ban", map[string]interface{}{
		"group_id": groupID, "user_id": "member", "duration": 0,
	}))
	for _, client := range []*websocket.Conn{owner, admin, member} {
		assertGovernanceNotice(t, readJSON(t, client), "group_ban", groupID, "member", "owner")
	}
	assertOK(t, request(t, admin, "group_mute_all", map[string]interface{}{
		"group_id": groupID, "enabled": true,
	}))
	for _, client := range []*websocket.Conn{owner, admin, member} {
		assertGovernanceNotice(t, readJSON(t, client), "group_mute_all", groupID, "", "admin")
	}
	wholeMutedSend := request(t, member, "send_message", map[string]interface{}{
		"conversation_id": groupID,
		"message":         []map[string]interface{}{{"type": "text", "data": map[string]interface{}{"text": "still blocked"}}},
	})
	if wholeMutedSend["status"] == "ok" || !strings.Contains(wholeMutedSend["msg"].(string), "muted for all") {
		t.Fatalf("member bypassed whole-group mute: %#v", wholeMutedSend)
	}

	deniedOwnerBan := request(t, admin, "group_ban", map[string]interface{}{
		"group_id": groupID, "user_id": "owner", "duration": 60,
	})
	if deniedOwnerBan["status"] == "ok" {
		t.Fatalf("administrator muted the owner: %#v", deniedOwnerBan)
	}
}

func TestGroupOwnershipTransferAndDismissal(t *testing.T) {
	database, websocketURL := newGroupManagementServer(t)
	owner := authenticatedGroupClient(t, websocketURL, "owner")
	member := authenticatedGroupClient(t, websocketURL, "member")
	addTestFriend(t, database, "owner", "member")
	created := request(t, owner, "create_group", map[string]interface{}{
		"name": "Transfer", "members": []string{"member"},
	})
	assertOK(t, created)
	groupID := responseData(t, created)["group_id"].(string)
	assertGroupNotice(t, readJSON(t, member), "group_increase", groupID, "member", "owner")

	assertOK(t, request(t, owner, "transfer_group", map[string]interface{}{
		"group_id": groupID, "user_id": "member",
	}))
	assertGovernanceNotice(t, readJSON(t, owner), "group_transfer", groupID, "member", "owner")
	assertGovernanceNotice(t, readJSON(t, member), "group_transfer", groupID, "member", "owner")
	group, err := database.GetGroup(groupID)
	if err != nil || group == nil || group.OwnerID != "member" || groupMemberRoleForTest(t, group, "owner") != "member" || groupMemberRoleForTest(t, group, "member") != "owner" {
		t.Fatalf("ownership transfer was not persisted: %#v err=%v", group, err)
	}

	deniedDismiss := request(t, owner, "dismiss_group", map[string]interface{}{"group_id": groupID})
	if deniedDismiss["status"] == "ok" {
		t.Fatalf("former owner dismissed the group: %#v", deniedDismiss)
	}
	assertOK(t, request(t, member, "dismiss_group", map[string]interface{}{"group_id": groupID}))
	assertGovernanceNotice(t, readJSON(t, member), "group_dismiss", groupID, "", "member")
	assertGovernanceNotice(t, readJSON(t, owner), "group_dismiss", groupID, "", "member")
	if deleted, err := database.GetGroup(groupID); err != nil || deleted != nil {
		t.Fatalf("dismissed group still exists: %#v err=%v", deleted, err)
	}
	if conversation, err := database.GetConversation(groupID); err != nil || conversation != nil {
		t.Fatalf("dismissed group conversation still exists: %#v err=%v", conversation, err)
	}
}

func newGroupManagementServer(t *testing.T) (*store.MemoryStore, string) {
	t.Helper()
	database := store.NewMemoryStore()
	gateway := NewGateway(database)
	server := httptest.NewServer(gateway)
	t.Cleanup(server.Close)
	return database, "ws" + strings.TrimPrefix(server.URL, "http")
}

func authenticatedGroupClient(t *testing.T, websocketURL, userID string) *websocket.Conn {
	t.Helper()
	client := dialWebSocket(t, websocketURL)
	t.Cleanup(func() { _ = client.Close() })
	authenticate(t, client, userID)
	return client
}

func addTestFriend(t *testing.T, database *store.MemoryStore, left, right string) {
	t.Helper()
	if added, err := database.AddFriend(left, right); err != nil || !added {
		t.Fatalf("failed to add friendship %s/%s: added=%v err=%v", left, right, added, err)
	}
}

func setMemoryGroupRole(t *testing.T, database *store.MemoryStore, groupID, userID, role string) {
	t.Helper()
	group, err := database.GetGroup(groupID)
	if err != nil || group == nil {
		t.Fatalf("group unavailable: %#v err=%v", group, err)
	}
	for _, member := range group.Members {
		if member.UserID == userID {
			member.Role = role
			return
		}
	}
	t.Fatalf("member %s not found", userID)
}

func assertGroupNotice(t *testing.T, notice map[string]interface{}, noticeType, groupID, userID, operatorID string) {
	t.Helper()
	if notice["post_type"] != "notice" ||
		notice["notice_type"] != noticeType ||
		notice["group_id"] != groupID ||
		notice["user_id"] != userID ||
		notice["operator_id"] != operatorID {
		t.Fatalf("unexpected group notice: %#v", notice)
	}
}

func assertGovernanceNotice(t *testing.T, notice map[string]interface{}, noticeType, groupID, userID, operatorID string) {
	t.Helper()
	if notice["post_type"] != "notice" || notice["notice_type"] != noticeType || notice["group_id"] != groupID || notice["operator_id"] != operatorID {
		t.Fatalf("unexpected governance notice: %#v", notice)
	}
	if userID != "" && notice["user_id"] != userID {
		t.Fatalf("unexpected governance notice target: %#v", notice)
	}
}

func groupMemberData(t *testing.T, members []interface{}, userID string) map[string]interface{} {
	t.Helper()
	for _, raw := range members {
		member := raw.(map[string]interface{})
		if member["user_id"] == userID {
			return member
		}
	}
	t.Fatalf("group member %s not found in %#v", userID, members)
	return nil
}

func groupMemberRoleForTest(t *testing.T, group *store.Group, userID string) string {
	t.Helper()
	for _, member := range group.Members {
		if member.UserID == userID {
			return member.Role
		}
	}
	t.Fatalf("group member %s not found", userID)
	return ""
}

func assertConversationParticipants(t *testing.T, database *store.MemoryStore, groupID string, expected []string) {
	t.Helper()
	conversation, err := database.GetConversation(groupID)
	if err != nil || conversation == nil {
		t.Fatalf("conversation unavailable: %#v err=%v", conversation, err)
	}
	if !slices.Equal(conversation.Participants, expected) {
		t.Fatalf("unexpected participants: got=%v want=%v", conversation.Participants, expected)
	}
}
