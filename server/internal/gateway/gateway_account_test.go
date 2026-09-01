package gateway

import (
	"encoding/base64"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/icradp/zzz-im-server/internal/store"
)

type registrationMediaUploader struct {
	data       []byte
	uploaderID string
}

func (u *registrationMediaUploader) Save(
	fileName, fileType, contentType string,
	data []byte,
	uploaderID string,
) (*store.MediaFile, error) {
	u.data = append([]byte(nil), data...)
	u.uploaderID = uploaderID
	return &store.MediaFile{
		ID: "registration-avatar", URL: "/files/registration-avatar/" + fileName,
		FileName: fileName, FileType: fileType, MimeType: contentType,
		UploaderID: uploaderID, Size: int64(len(data)),
	}, nil
}

func TestAccountProfileAndGroupFlow(t *testing.T) {
	database := store.NewMemoryStore()
	gateway := NewGateway(database)
	gateway.SetInviteCode("diaogan")
	server := httptest.NewServer(gateway)
	t.Cleanup(server.Close)
	websocketURL := "ws" + strings.TrimPrefix(server.URL, "http")

	alice := dialWebSocket(t, websocketURL)
	t.Cleanup(func() { _ = alice.Close() })
	registered := request(t, alice, "register", map[string]interface{}{
		"user_id":     "alice-account",
		"password":    "correct horse battery staple",
		"nickname":    "Alice",
		"invite_code": "diaogan",
	})
	aliceSession := responseData(t, registered)["session_token"].(string)
	if aliceSession == "" {
		t.Fatal("registration did not return a session token")
	}

	bob := dialWebSocket(t, websocketURL)
	t.Cleanup(func() { _ = bob.Close() })
	bobRegistered := request(t, bob, "register", map[string]interface{}{
		"user_id":     "bob-account",
		"password":    "correct horse battery staple",
		"invite_code": "diaogan",
	})
	bobSession := responseData(t, bobRegistered)["session_token"].(string)

	login := request(t, alice, "auth", map[string]interface{}{
		"user_id":  "alice-account",
		"password": "correct horse battery staple",
	})
	if responseData(t, login)["session_token"] == "" {
		t.Fatal("password login did not return a session token")
	}
	assertOK(t, request(t, alice, "auth", map[string]interface{}{
		"session_token": aliceSession,
	}))
	assertOK(t, request(t, bob, "auth", map[string]interface{}{
		"session_token": bobSession,
	}))

	profile := request(t, alice, "update_profile", map[string]interface{}{
		"nickname":   "Alice Updated",
		"avatar_url": "/files/alice-avatar",
	})
	if responseData(t, profile)["nickname"] != "Alice Updated" {
		t.Fatalf("profile was not updated: %#v", profile)
	}
	if _, err := database.AddFriend("alice-account", "bob-account"); err != nil {
		t.Fatal(err)
	}

	group := request(t, alice, "create_group", map[string]interface{}{
		"name":    "Test Group",
		"members": []string{"bob-account"},
	})
	groupID, _ := responseData(t, group)["group_id"].(string)
	if groupID == "" {
		t.Fatal("group creation returned no id")
	}
	_ = readJSON(t, bob)
	info := request(t, bob, "get_group_info", map[string]interface{}{"group_id": groupID})
	if len(responseData(t, info)["members"].([]interface{})) != 2 {
		t.Fatalf("unexpected group members: %#v", info)
	}

	// A new gateway instance simulates a server restart while sharing the
	// persistent store. The original account session must remain valid.
	restartedGateway := NewGateway(database)
	restartedServer := httptest.NewServer(restartedGateway)
	t.Cleanup(restartedServer.Close)
	restartedURL := "ws" + strings.TrimPrefix(restartedServer.URL, "http")
	restartedClient := dialWebSocket(t, restartedURL)
	t.Cleanup(func() { _ = restartedClient.Close() })
	assertOK(t, request(t, restartedClient, "auth", map[string]interface{}{
		"session_token": aliceSession,
	}))

	logoutClient := dialWebSocket(t, restartedURL)
	t.Cleanup(func() { _ = logoutClient.Close() })
	assertOK(t, request(t, logoutClient, "logout", map[string]interface{}{
		"session_token": aliceSession,
	}))
	denied := request(t, logoutClient, "auth", map[string]interface{}{
		"session_token": aliceSession,
	})
	if denied["status"] == "ok" {
		t.Fatalf("revoked session was accepted: %#v", denied)
	}
}

func TestRegistrationRequiresConfiguredInviteCode(t *testing.T) {
	database := store.NewMemoryStore()
	gateway := NewGateway(database)
	gateway.SetInviteCode("diaogan")
	server := httptest.NewServer(gateway)
	t.Cleanup(server.Close)
	websocketURL := "ws" + strings.TrimPrefix(server.URL, "http")

	client := dialWebSocket(t, websocketURL)
	t.Cleanup(func() { _ = client.Close() })
	denied := request(t, client, "register", map[string]interface{}{
		"user_id":     "invite-test",
		"password":    "correct horse battery staple",
		"invite_code": "wrong-code",
	})
	if denied["status"] == "ok" {
		t.Fatalf("registration accepted an invalid invite: %#v", denied)
	}
	if user, _ := database.GetUser("invite-test"); user != nil {
		t.Fatal("invalid invitation created an account")
	}
	tooLong := request(t, client, "register", map[string]interface{}{
		"user_id":     "long-password",
		"password":    strings.Repeat("x", 73),
		"invite_code": "diaogan",
	})
	if tooLong["status"] == "ok" {
		t.Fatalf("registration accepted a password beyond bcrypt limits: %#v", tooLong)
	}
	if user, _ := database.GetUser("long-password"); user != nil {
		t.Fatal("invalid password created an account")
	}

	registered := request(t, client, "register", map[string]interface{}{
		"user_id":     "invite-test",
		"password":    "correct horse battery staple",
		"invite_code": "diaogan",
	})
	assertOK(t, registered)

	loginClient := dialWebSocket(t, websocketURL)
	t.Cleanup(func() { _ = loginClient.Close() })
	assertOK(t, request(t, loginClient, "auth", map[string]interface{}{
		"user_id":  "invite-test",
		"password": "correct horse battery staple",
	}))
}

func TestRegistrationPersistsBuiltInAndUploadedAvatars(t *testing.T) {
	database := store.NewMemoryStore()
	uploader := &registrationMediaUploader{}
	gateway := NewGateway(database)
	gateway.SetInviteCode("diaogan")
	gateway.SetMediaUploader(uploader)
	server := httptest.NewServer(gateway)
	t.Cleanup(server.Close)
	websocketURL := "ws" + strings.TrimPrefix(server.URL, "http")

	builtInClient := dialWebSocket(t, websocketURL)
	t.Cleanup(func() { _ = builtInClient.Close() })
	builtIn := request(t, builtInClient, "register", map[string]interface{}{
		"user_id": "avatar-built-in", "password": "correct horse battery staple",
		"invite_code": "diaogan", "avatar_url": "assets/characters/Belle.png",
	})
	assertOK(t, builtIn)
	if responseData(t, builtIn)["avatar_url"] != "assets/characters/Belle.png" {
		t.Fatalf("built-in avatar was not returned: %#v", builtIn)
	}
	storedBuiltIn, _ := database.GetUser("avatar-built-in")
	if storedBuiltIn == nil || storedBuiltIn.Avatar != "assets/characters/Belle.png" {
		t.Fatalf("built-in avatar was not persisted: %#v", storedBuiltIn)
	}

	uploadClient := dialWebSocket(t, websocketURL)
	t.Cleanup(func() { _ = uploadClient.Close() })
	png, err := base64.StdEncoding.DecodeString(
		"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=",
	)
	if err != nil {
		t.Fatal(err)
	}
	uploaded := request(t, uploadClient, "register", map[string]interface{}{
		"user_id": "avatar-upload", "password": "correct horse battery staple",
		"invite_code": "diaogan", "avatar_file": base64.StdEncoding.EncodeToString(png),
		"avatar_file_name": "profile.png", "avatar_mime_type": "image/png",
	})
	assertOK(t, uploaded)
	if responseData(t, uploaded)["avatar_url"] != "/files/registration-avatar/profile.png" {
		t.Fatalf("uploaded avatar URL was not returned: %#v", uploaded)
	}
	storedUpload, _ := database.GetUser("avatar-upload")
	if storedUpload == nil || storedUpload.Avatar != "/files/registration-avatar/profile.png" {
		t.Fatalf("uploaded avatar was not persisted: %#v", storedUpload)
	}
	if uploader.uploaderID != "avatar-upload" || string(uploader.data) != string(png) {
		t.Fatalf("unexpected avatar upload: uploader=%q bytes=%d", uploader.uploaderID, len(uploader.data))
	}
}

func TestProfileUpdateRefreshesDirectConversationIdentity(t *testing.T) {
	database := store.NewMemoryStore()
	gateway := NewGateway(database)
	server := httptest.NewServer(gateway)
	t.Cleanup(server.Close)
	websocketURL := "ws" + strings.TrimPrefix(server.URL, "http")

	alice := dialWebSocket(t, websocketURL)
	bob := dialWebSocket(t, websocketURL)
	t.Cleanup(func() { _ = alice.Close() })
	t.Cleanup(func() { _ = bob.Close() })
	authenticate(t, alice, "alice")
	authenticate(t, bob, "bob")
	if _, err := database.AddFriend("alice", "bob"); err != nil {
		t.Fatal(err)
	}
	assertOK(t, request(t, alice, "ensure_conversation", map[string]interface{}{
		"conversation_id": "private_alice_bob_profile", "type": "private",
		"title": "Old Bob", "avatar_url": "/files/old-bob",
		"participants": []string{"alice", "bob"},
	}))

	updated := request(t, bob, "update_profile", map[string]interface{}{
		"nickname": "Bob Updated", "avatar_url": "/files/new-bob",
	})
	assertOK(t, updated)
	notice := readJSON(t, alice)
	if notice["notice_type"] != "profile_update" ||
		notice["nickname"] != "Bob Updated" || notice["avatar_url"] != "/files/new-bob" {
		t.Fatalf("unexpected profile update notice: %#v", notice)
	}
	conversations := responseDataList(t, request(t, alice, "get_conversations", map[string]interface{}{}))
	conversation := conversations[0].(map[string]interface{})
	if conversation["title"] != "Bob Updated" || conversation["avatar_url"] != "/files/new-bob" {
		t.Fatalf("direct conversation kept stale profile data: %#v", conversation)
	}
}
