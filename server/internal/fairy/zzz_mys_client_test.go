package fairy

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestZZZMYSClientProtocol(t *testing.T) {
	const (
		accountID   = "123456789"
		stoken      = "v2_stoken-secret"
		cookieToken = "cookie-secret"
		authKey     = "authkey-secret"
	)
	server := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		response.Header().Set("Content-Type", "application/json")
		write := func(data any) {
			if err := json.NewEncoder(response).Encode(map[string]any{"retcode": 0, "message": "OK", "data": data}); err != nil {
				t.Error(err)
			}
		}
		switch request.URL.Path {
		case "/create":
			if request.Method != http.MethodPost || request.Header.Get("x-rpc-app_id") != "ddxf5dufpuyo" || len(request.Header.Get("x-rpc-device_id")) != 64 {
				t.Errorf("invalid QR create request: %#v", request.Header)
			}
			write(map[string]any{"ticket": "ticket", "url": "https://example.test/qr?ticket=ticket"})
		case "/query":
			write(map[string]any{
				"status":    "Confirmed",
				"tokens":    []map[string]string{{"name": "stoken_v2", "token": stoken}},
				"user_info": map[string]string{"aid": accountID, "mid": "mid-value"},
			})
		case "/cookie":
			if request.URL.Query().Get("stoken") != stoken || !strings.Contains(request.Header.Get("Cookie"), stoken) {
				t.Error("cookie-token request did not carry the stoken")
			}
			write(map[string]string{"cookie_token": cookieToken})
		case "/roles":
			if !strings.Contains(request.Header.Get("Cookie"), cookieToken) || request.Header.Get("DS") == "" {
				t.Error("role request did not carry cookie token and DS")
			}
			write(map[string]any{"list": []map[string]any{{"game_id": 8, "game_biz": "nap_cn", "game_role_id": "27280531", "nickname": "Belle"}}})
		case "/authkey":
			if !strings.Contains(request.Header.Get("Cookie"), stoken) || request.Header.Get("DS") == "" {
				t.Error("authkey request did not carry stoken and DS")
			}
			write(map[string]string{"authkey": authKey})
		case "/gacha":
			if request.URL.Query().Get("authkey") != authKey || request.URL.Query().Get("gacha_type") != "2001" {
				t.Errorf("invalid gacha query: %s", request.URL.RawQuery)
			}
			write(map[string]any{"list": []map[string]string{{
				"id": "100", "item_id": "1", "name": "Ellen", "item_type": "角色", "rank_type": "4", "time": "2026-01-01 00:00:00",
			}}})
		case "/abyss":
			if !strings.Contains(request.Header.Get("Cookie"), cookieToken) || request.URL.Query().Get("schedule_type") != "2" {
				t.Error("invalid abyss request")
			}
			write(map[string]any{
				"nick_name": "Belle",
				"hadal_info_v2": map[string]any{
					"pass_fifth_floor": true, "begin_time": "begin", "end_time": "end",
					"brief": map[string]any{"cur_period_zone_layer_count": 5, "score": 42000, "max_score": 50000, "rank_percent": 10, "rating": "S"},
				},
			})
		default:
			http.NotFound(response, request)
		}
	}))
	defer server.Close()

	client := newZZZMYSClient(5 * time.Second)
	client.createQRURL = server.URL + "/create"
	client.queryQRURL = server.URL + "/query"
	client.cookieTokenURL = server.URL + "/cookie"
	client.gameRolesURL = server.URL + "/roles"
	client.authKeyURL = server.URL + "/authkey"
	client.gachaURL = server.URL + "/gacha"
	client.abyssURL = server.URL + "/abyss"
	ctx := context.Background()

	login, err := client.CreateQR(ctx)
	if err != nil {
		t.Fatal(err)
	}
	status, err := client.QueryQR(ctx, login)
	if err != nil || status.AccountID != accountID || status.SToken != stoken {
		t.Fatalf("QueryQR() = %#v, %v", status, err)
	}
	token, err := client.ExchangeCookieToken(ctx, status)
	if err != nil || token != cookieToken {
		t.Fatalf("ExchangeCookieToken() = %q, %v", token, err)
	}
	roles, err := client.GameRoles(ctx, accountID, token)
	if err != nil || len(roles) != 1 || roles[0].UID != "27280531" {
		t.Fatalf("GameRoles() = %#v, %v", roles, err)
	}
	account := zzzAccountCredential{MYSAccountID: accountID, UID: roles[0].UID, Cookie: "account_id=" + accountID + ";cookie_token=" + token, SToken: stoken, MID: status.MID}
	key, err := client.AuthKey(ctx, account)
	if err != nil || key != authKey {
		t.Fatalf("AuthKey() = %q, %v", key, err)
	}
	page, err := client.GachaPage(ctx, account, key, "2001", 1, "0", "2")
	if err != nil || len(page.Records) != 1 || page.Records[0].Name != "Ellen" {
		t.Fatalf("GachaPage() = %#v, %v", page, err)
	}
	abyss, err := client.Abyss(ctx, account, 2)
	if err != nil || abyss.Score != 42000 || !abyss.PassedFifth {
		t.Fatalf("Abyss() = %#v, %v", abyss, err)
	}
}

func TestZZZMYSClientDoesNotExposeResponseOrRequestSecretsInErrors(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		_ = json.NewEncoder(response).Encode(map[string]any{
			"retcode": 10001, "message": "cookie-secret from upstream", "data": map[string]any{},
		})
	}))
	defer server.Close()
	client := newZZZMYSClient(time.Second)
	client.cookieTokenURL = server.URL
	_, err := client.ExchangeCookieToken(context.Background(), zzzQRLoginStatus{
		AccountID: "123456789", MID: "mid-secret", SToken: "stoken-secret",
	})
	if err == nil {
		t.Fatal("ExchangeCookieToken() unexpectedly succeeded")
	}
	for _, secret := range []string{"cookie-secret", "mid-secret", "stoken-secret"} {
		if strings.Contains(err.Error(), secret) {
			t.Fatalf("error exposed %q: %v", secret, err)
		}
	}
	if !isZZZMYSFailure(err, zzzMYSFailureExpired) {
		t.Fatalf("error = %v, want credential_expired", err)
	}
}
