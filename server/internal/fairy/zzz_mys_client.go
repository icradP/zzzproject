package fairy

import (
	"bytes"
	"context"
	"crypto/md5"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"math/big"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
)

const (
	zzzMYSVersion   = "2.102.1"
	zzzMYSDSSalt    = "xV8v4Qu54lUKrEYFZkJhB8cuOh9Asafs"
	zzzMYSWebDSSalt = "yBh10ikxtLPoIhgwgPZSv5dmfaOTSJ6a"
)

type zzzMYSFailureCode string

const (
	zzzMYSFailureUnavailable zzzMYSFailureCode = "upstream_unavailable"
	zzzMYSFailureRejected    zzzMYSFailureCode = "upstream_rejected"
	zzzMYSFailureExpired     zzzMYSFailureCode = "credential_expired"
	zzzMYSFailureRisk        zzzMYSFailureCode = "risk_control"
	zzzMYSFailureRate        zzzMYSFailureCode = "rate_limited"
	zzzMYSFailureQRExpired   zzzMYSFailureCode = "qr_expired"
	zzzMYSFailureInvalid     zzzMYSFailureCode = "invalid_response"
)

type zzzMYSFailure struct {
	Code zzzMYSFailureCode
}

func (e *zzzMYSFailure) Error() string { return "Fairy MYS request failed: " + string(e.Code) }

type zzzQRLogin struct {
	Ticket   string
	URL      string
	DeviceID string
}

type zzzQRLoginStatus struct {
	Status    string
	AccountID string
	MID       string
	SToken    string
}

type zzzMYSRole struct {
	GameID   int    `json:"game_id"`
	GameBiz  string `json:"game_biz"`
	UID      string `json:"game_role_id"`
	Nickname string `json:"nickname"`
	Region   string `json:"region"`
}

type zzzAbyssSummary struct {
	UID             string `json:"uid"`
	Nickname        string `json:"nickname,omitempty"`
	ScheduleType    int    `json:"schedule_type"`
	Rating          string `json:"rating,omitempty"`
	Score           int    `json:"score"`
	MaxScore        int    `json:"max_score"`
	RankPercent     int    `json:"rank_percent"`
	CompletedLayers int    `json:"completed_layers"`
	PassedFifth     bool   `json:"passed_fifth_floor"`
	BeginTime       string `json:"begin_time,omitempty"`
	EndTime         string `json:"end_time,omitempty"`
}

type zzzGachaPage struct {
	Records []zzzGachaRecord
}

type zzzMYSService interface {
	CreateQR(context.Context) (zzzQRLogin, error)
	QueryQR(context.Context, zzzQRLogin) (zzzQRLoginStatus, error)
	ExchangeCookieToken(context.Context, zzzQRLoginStatus) (string, error)
	GameRoles(context.Context, string, string) ([]zzzMYSRole, error)
	AuthKey(context.Context, zzzAccountCredential) (string, error)
	GachaPage(context.Context, zzzAccountCredential, string, string, int, string, string) (zzzGachaPage, error)
	Abyss(context.Context, zzzAccountCredential, int) (zzzAbyssSummary, error)
}

type zzzMYSClient struct {
	client         *http.Client
	createQRURL    string
	queryQRURL     string
	cookieTokenURL string
	gameRolesURL   string
	authKeyURL     string
	gachaURL       string
	abyssURL       string
}

func newZZZMYSClient(timeout time.Duration) *zzzMYSClient {
	return &zzzMYSClient{
		client:         &http.Client{Timeout: timeout},
		createQRURL:    "https://passport-api.mihoyo.com/account/ma-cn-passport/app/createQRLogin",
		queryQRURL:     "https://passport-api.mihoyo.com/account/ma-cn-passport/app/queryQRLoginStatus",
		cookieTokenURL: "https://passport-api.mihoyo.com/account/auth/api/getCookieAccountInfoBySToken",
		gameRolesURL:   "https://api-takumi-record.mihoyo.com/game_record/card/wapi/getGameRecordCard",
		authKeyURL:     "https://api-takumi.mihoyo.com/binding/api/genAuthKey",
		gachaURL:       "https://public-operation-nap.mihoyo.com/common/gacha_record/api/getGachaLog",
		abyssURL:       "https://api-takumi-record.mihoyo.com/event/game_record_zzz/api/zzz/hadal_info_v2",
	}
}

func (c *zzzMYSClient) CreateQR(ctx context.Context) (zzzQRLogin, error) {
	deviceID, err := secureHex(32)
	if err != nil {
		return zzzQRLogin{}, &zzzMYSFailure{Code: zzzMYSFailureUnavailable}
	}
	data, err := c.request(ctx, http.MethodPost, c.createQRURL, nil, map[string]any{}, zzzQRHeaders(deviceID))
	if err != nil {
		return zzzQRLogin{}, err
	}
	var payload struct {
		Ticket string `json:"ticket"`
		URL    string `json:"url"`
	}
	if err := json.Unmarshal(data, &payload); err != nil || payload.Ticket == "" || payload.URL == "" {
		return zzzQRLogin{}, &zzzMYSFailure{Code: zzzMYSFailureInvalid}
	}
	return zzzQRLogin{Ticket: payload.Ticket, URL: payload.URL, DeviceID: deviceID}, nil
}

func (c *zzzMYSClient) QueryQR(ctx context.Context, login zzzQRLogin) (zzzQRLoginStatus, error) {
	data, err := c.request(ctx, http.MethodPost, c.queryQRURL, nil, map[string]any{"ticket": login.Ticket}, zzzQRHeaders(login.DeviceID))
	if err != nil {
		return zzzQRLoginStatus{}, err
	}
	var payload struct {
		Status string `json:"status"`
		Tokens []struct {
			Name  string `json:"name"`
			Token string `json:"token"`
		} `json:"tokens"`
		UserInfo struct {
			AID       string `json:"aid"`
			UID       string `json:"uid"`
			AccountID string `json:"account_id"`
			MID       string `json:"mid"`
		} `json:"user_info"`
	}
	if err := json.Unmarshal(data, &payload); err != nil || payload.Status == "" {
		return zzzQRLoginStatus{}, &zzzMYSFailure{Code: zzzMYSFailureInvalid}
	}
	result := zzzQRLoginStatus{Status: payload.Status, MID: payload.UserInfo.MID}
	result.AccountID = firstNonEmpty(payload.UserInfo.AID, payload.UserInfo.UID, payload.UserInfo.AccountID)
	for _, token := range payload.Tokens {
		if token.Name == "stoken" || token.Name == "stoken_v2" {
			result.SToken = token.Token
			break
		}
	}
	if result.SToken == "" && len(payload.Tokens) > 0 {
		result.SToken = payload.Tokens[0].Token
	}
	return result, nil
}

func (c *zzzMYSClient) ExchangeCookieToken(ctx context.Context, status zzzQRLoginStatus) (string, error) {
	query := url.Values{"stoken": {status.SToken}, "uid": {status.AccountID}}
	if status.MID != "" {
		query.Set("mid", status.MID)
	}
	headers := zzzMYSHeaders()
	headers.Set("Cookie", zzzSTokenCookie(status.AccountID, status.SToken, status.MID))
	data, err := c.request(ctx, http.MethodGet, c.cookieTokenURL, query, nil, headers)
	if err != nil {
		return "", err
	}
	var payload struct {
		CookieToken string `json:"cookie_token"`
	}
	if err := json.Unmarshal(data, &payload); err != nil || payload.CookieToken == "" {
		return "", &zzzMYSFailure{Code: zzzMYSFailureInvalid}
	}
	return payload.CookieToken, nil
}

func (c *zzzMYSClient) GameRoles(ctx context.Context, accountID, cookieToken string) ([]zzzMYSRole, error) {
	query := url.Values{"uid": {accountID}}
	headers := zzzMYSHeaders()
	headers.Set("DS", zzzDS(query.Encode(), nil))
	headers.Set("Cookie", "account_id="+accountID+";cookie_token="+cookieToken)
	data, err := c.request(ctx, http.MethodGet, c.gameRolesURL, query, nil, headers)
	if err != nil {
		return nil, err
	}
	var payload struct {
		List []zzzMYSRole `json:"list"`
	}
	if err := json.Unmarshal(data, &payload); err != nil {
		return nil, &zzzMYSFailure{Code: zzzMYSFailureInvalid}
	}
	return payload.List, nil
}

func (c *zzzMYSClient) AuthKey(ctx context.Context, account zzzAccountCredential) (string, error) {
	body := map[string]any{
		"auth_appid": "webview_gacha",
		"game_biz":   "nap_cn",
		"game_uid":   account.UID,
		"region":     "prod_gf_cn",
	}
	headers := zzzMYSHeaders()
	headers.Set("Cookie", zzzSTokenCookie(account.MYSAccountID, account.SToken, account.MID))
	headers.Set("DS", zzzWebDS())
	headers.Set("User-Agent", "okhttp/4.8.0")
	headers.Set("x-rpc-sys_version", "12")
	headers.Set("x-rpc-client_type", "5")
	headers.Set("x-rpc-channel", "mihoyo")
	deviceID, err := secureHex(16)
	if err != nil {
		return "", &zzzMYSFailure{Code: zzzMYSFailureUnavailable}
	}
	headers.Set("x-rpc-device_id", strings.ToUpper(deviceID))
	headers.Set("x-rpc-device_name", "Fairy")
	headers.Set("x-rpc-device_model", "Mi 10")
	data, err := c.request(ctx, http.MethodPost, c.authKeyURL, nil, body, headers)
	if err != nil {
		return "", err
	}
	var payload struct {
		AuthKey string `json:"authkey"`
	}
	if err := json.Unmarshal(data, &payload); err != nil || payload.AuthKey == "" {
		return "", &zzzMYSFailure{Code: zzzMYSFailureInvalid}
	}
	return payload.AuthKey, nil
}

func (c *zzzMYSClient) GachaPage(ctx context.Context, account zzzAccountCredential, authKey, gachaType string, page int, endID, baseType string) (zzzGachaPage, error) {
	query := url.Values{
		"authkey_ver":              {"1"},
		"sign_type":                {"2"},
		"auth_appid":               {"webview_gacha"},
		"init_log_gacha_type":      {gachaType},
		"init_log_gacha_base_type": {baseType},
		"gacha_id":                 {"2c1f5692fdfbb733a08733f9eb69d32aed1d37"},
		"timestamp":                {strconv.FormatInt(time.Now().Unix(), 10)},
		"lang":                     {"zh-cn"},
		"device_type":              {"mobile"},
		"plat_type":                {"ios"},
		"region":                   {"prod_gf_cn"},
		"authkey":                  {authKey},
		"game_biz":                 {"nap_cn"},
		"gacha_type":               {gachaType},
		"real_gacha_type":          {baseType},
		"page":                     {strconv.Itoa(page)},
		"size":                     {"20"},
		"end_id":                   {endID},
	}
	data, err := c.request(ctx, http.MethodGet, c.gachaURL, query, nil, zzzMYSHeaders())
	if err != nil {
		return zzzGachaPage{}, err
	}
	var payload struct {
		List []struct {
			ID       string `json:"id"`
			ItemID   string `json:"item_id"`
			Name     string `json:"name"`
			ItemType string `json:"item_type"`
			RankType string `json:"rank_type"`
			Time     string `json:"time"`
		} `json:"list"`
	}
	if err := json.Unmarshal(data, &payload); err != nil {
		return zzzGachaPage{}, &zzzMYSFailure{Code: zzzMYSFailureInvalid}
	}
	result := zzzGachaPage{Records: make([]zzzGachaRecord, 0, len(payload.List))}
	for _, record := range payload.List {
		if record.ID == "" {
			continue
		}
		result.Records = append(result.Records, zzzGachaRecord{
			RecordID: record.ID, ItemID: record.ItemID, Name: record.Name,
			ItemType: record.ItemType, RankType: record.RankType, Time: record.Time,
		})
	}
	return result, nil
}

func (c *zzzMYSClient) Abyss(ctx context.Context, account zzzAccountCredential, scheduleType int) (zzzAbyssSummary, error) {
	query := url.Values{
		"role_id":       {account.UID},
		"server":        {"prod_gf_cn"},
		"schedule_type": {strconv.Itoa(scheduleType)},
	}
	headers := zzzMYSHeaders()
	headers.Del("x-rpc-client_type")
	headers.Set("x-rpc-page", "v1.0.14_#/zzz")
	headers.Set("x-rpc-platform", "2")
	headers.Set("Referer", "https://act.mihoyo.com/")
	headers.Set("Origin", "https://act.mihoyo.com")
	headers.Set("Cookie", account.Cookie)
	data, err := c.request(ctx, http.MethodGet, c.abyssURL, query, nil, headers)
	if err != nil {
		return zzzAbyssSummary{}, err
	}
	var payload struct {
		Nickname string `json:"nick_name"`
		Hadal    struct {
			PassedFifth bool   `json:"pass_fifth_floor"`
			BeginTime   string `json:"begin_time"`
			EndTime     string `json:"end_time"`
			Brief       struct {
				Layers      int    `json:"cur_period_zone_layer_count"`
				Score       int    `json:"score"`
				MaxScore    int    `json:"max_score"`
				RankPercent int    `json:"rank_percent"`
				Rating      string `json:"rating"`
			} `json:"brief"`
		} `json:"hadal_info_v2"`
	}
	if err := json.Unmarshal(data, &payload); err != nil {
		return zzzAbyssSummary{}, &zzzMYSFailure{Code: zzzMYSFailureInvalid}
	}
	return zzzAbyssSummary{
		UID: account.UID, Nickname: payload.Nickname, ScheduleType: scheduleType,
		Rating: payload.Hadal.Brief.Rating, Score: payload.Hadal.Brief.Score,
		MaxScore: payload.Hadal.Brief.MaxScore, RankPercent: payload.Hadal.Brief.RankPercent,
		CompletedLayers: payload.Hadal.Brief.Layers, PassedFifth: payload.Hadal.PassedFifth,
		BeginTime: payload.Hadal.BeginTime, EndTime: payload.Hadal.EndTime,
	}, nil
}

type zzzMYSEnvelope struct {
	RetCode int             `json:"retcode"`
	Message string          `json:"message"`
	Data    json.RawMessage `json:"data"`
}

func (c *zzzMYSClient) request(ctx context.Context, method, endpoint string, query url.Values, body any, headers http.Header) (json.RawMessage, error) {
	parsed, err := url.Parse(endpoint)
	if err != nil || parsed.Scheme != "https" && parsed.Scheme != "http" {
		return nil, &zzzMYSFailure{Code: zzzMYSFailureUnavailable}
	}
	if query != nil {
		parsed.RawQuery = query.Encode()
	}
	var reader io.Reader
	if body != nil {
		encoded, err := json.Marshal(body)
		if err != nil {
			return nil, &zzzMYSFailure{Code: zzzMYSFailureInvalid}
		}
		reader = bytes.NewReader(encoded)
	}
	request, err := http.NewRequestWithContext(ctx, method, parsed.String(), reader)
	if err != nil {
		return nil, &zzzMYSFailure{Code: zzzMYSFailureUnavailable}
	}
	request.Header = headers.Clone()
	request.Header.Set("Accept", "application/json")
	if body != nil {
		request.Header.Set("Content-Type", "application/json")
	}
	response, err := c.client.Do(request)
	if err != nil {
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		return nil, &zzzMYSFailure{Code: zzzMYSFailureUnavailable}
	}
	defer response.Body.Close()
	if response.StatusCode == http.StatusTooManyRequests {
		return nil, &zzzMYSFailure{Code: zzzMYSFailureRate}
	}
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return nil, &zzzMYSFailure{Code: zzzMYSFailureUnavailable}
	}
	encoded, err := io.ReadAll(io.LimitReader(response.Body, 2*1024*1024+1))
	if err != nil || len(encoded) > 2*1024*1024 {
		return nil, &zzzMYSFailure{Code: zzzMYSFailureInvalid}
	}
	var envelope zzzMYSEnvelope
	if err := json.Unmarshal(encoded, &envelope); err != nil {
		return nil, &zzzMYSFailure{Code: zzzMYSFailureInvalid}
	}
	if envelope.RetCode != 0 {
		return nil, &zzzMYSFailure{Code: classifyZZZMYSRetCode(envelope.RetCode)}
	}
	if len(envelope.Data) == 0 || string(envelope.Data) == "null" {
		return nil, &zzzMYSFailure{Code: zzzMYSFailureInvalid}
	}
	return append(json.RawMessage(nil), envelope.Data...), nil
}

func classifyZZZMYSRetCode(code int) zzzMYSFailureCode {
	switch code {
	case -100, 10001, 1008, 10101:
		return zzzMYSFailureExpired
	case -106:
		return zzzMYSFailureQRExpired
	case 1034, 10035, 10041:
		return zzzMYSFailureRisk
	case -110, 429:
		return zzzMYSFailureRate
	default:
		return zzzMYSFailureRejected
	}
}

func zzzQRHeaders(deviceID string) http.Header {
	headers := make(http.Header)
	headers.Set("x-rpc-device_id", deviceID)
	headers.Set("User-Agent", "HYPContainer/1.3.3.182")
	headers.Set("x-rpc-app_id", "ddxf5dufpuyo")
	headers.Set("x-rpc-client_type", "3")
	return headers
}

func zzzMYSHeaders() http.Header {
	headers := make(http.Header)
	headers.Set("x-rpc-app_version", zzzMYSVersion)
	headers.Set("X-Requested-With", "com.mihoyo.hyperion")
	headers.Set("User-Agent", "Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 Mobile Safari/537.36 miHoYoBBS/"+zzzMYSVersion)
	headers.Set("x-rpc-client_type", "5")
	headers.Set("Referer", "https://webstatic.mihoyo.com/")
	headers.Set("Origin", "https://webstatic.mihoyo.com/")
	return headers
}

func zzzSTokenCookie(accountID, stoken, mid string) string {
	cookie := "stuid=" + accountID + ";stoken=" + stoken
	if mid != "" {
		cookie += ";mid=" + mid
	}
	return cookie
}

func zzzDS(query string, body any) string {
	timestamp := strconv.FormatInt(time.Now().Unix(), 10)
	randomNumber := secureInt(100000, 200000)
	bodyJSON := ""
	if body != nil {
		if encoded, err := json.Marshal(body); err == nil {
			bodyJSON = string(encoded)
		}
	}
	digest := md5.Sum([]byte("salt=" + zzzMYSDSSalt + "&t=" + timestamp + "&r=" + randomNumber + "&b=" + bodyJSON + "&q=" + query))
	return timestamp + "," + randomNumber + "," + hex.EncodeToString(digest[:])
}

func zzzWebDS() string {
	timestamp := strconv.FormatInt(time.Now().Unix(), 10)
	randomValue := secureAlphaNumeric(6)
	digest := md5.Sum([]byte("salt=" + zzzMYSWebDSSalt + "&t=" + timestamp + "&r=" + randomValue))
	return timestamp + "," + randomValue + "," + hex.EncodeToString(digest[:])
}

func secureHex(bytesCount int) (string, error) {
	data := make([]byte, bytesCount)
	if _, err := io.ReadFull(rand.Reader, data); err != nil {
		return "", err
	}
	return hex.EncodeToString(data), nil
}

func secureInt(minimum, maximum int64) string {
	span := big.NewInt(maximum - minimum + 1)
	value, err := rand.Int(rand.Reader, span)
	if err != nil {
		return strconv.FormatInt(minimum, 10)
	}
	return strconv.FormatInt(value.Int64()+minimum, 10)
}

func secureAlphaNumeric(length int) string {
	const alphabet = "abcdefghijklmnopqrstuvwxyz0123456789"
	result := make([]byte, length)
	for index := range result {
		value, err := rand.Int(rand.Reader, big.NewInt(int64(len(alphabet))))
		if err != nil {
			result[index] = alphabet[index%len(alphabet)]
			continue
		}
		result[index] = alphabet[value.Int64()]
	}
	return string(result)
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			return value
		}
	}
	return ""
}

func isZZZMYSFailure(err error, code zzzMYSFailureCode) bool {
	var failure *zzzMYSFailure
	return errors.As(err, &failure) && failure.Code == code
}

func zzzMYSUserMessage(err error) string {
	var failure *zzzMYSFailure
	if !errors.As(err, &failure) {
		return "米游社服务暂时不可用，请稍后再试。"
	}
	switch failure.Code {
	case zzzMYSFailureExpired:
		return "米游社登录已失效，请私聊发送 /zzz login 重新绑定。"
	case zzzMYSFailureRisk:
		return "米游社触发了安全验证，请稍后重试或在米游社 App 内完成验证。"
	case zzzMYSFailureRate:
		return "米游社请求过于频繁，请稍后再试。"
	case zzzMYSFailureQRExpired:
		return "登录二维码已过期，请重新发送 /zzz login。"
	default:
		return "米游社服务暂时不可用，请稍后再试。"
	}
}

var _ zzzMYSService = (*zzzMYSClient)(nil)
