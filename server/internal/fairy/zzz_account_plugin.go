package fairy

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"sync"
	"time"

	"github.com/icradp/zzz-im-server/internal/protocol"
	qrcode "github.com/skip2/go-qrcode"
)

const (
	ZZZAccountPluginID = "zzz-account"
	zzzAccountToolName = "zzz-account"
	zzzGachaToolName   = "zzz-gacha"
	zzzAbyssToolName   = "zzz-abyss"
	zzzLoginTimeout    = 2 * time.Minute
	zzzSyncTimeout     = 3 * time.Minute
)

type zzzAccountCommand string

const (
	zzzCommandLogin         zzzAccountCommand = "login"
	zzzCommandAccount       zzzAccountCommand = "account"
	zzzCommandGachaSync     zzzAccountCommand = "gacha_sync"
	zzzCommandGacha         zzzAccountCommand = "gacha"
	zzzCommandAbyss         zzzAccountCommand = "abyss"
	zzzCommandAbyssPrevious zzzAccountCommand = "abyss_previous"
	zzzCommandLogout        zzzAccountCommand = "logout"
)

type ZZZAccountPlugin struct {
	cfg       Config
	store     *ZZZAccountStore
	mys       zzzMYSService
	ownsStore bool

	mu           sync.Mutex
	runCtx       context.Context
	cancel       context.CancelFunc
	loginCancel  map[string]context.CancelFunc
	syncCancel   map[string]context.CancelFunc
	wg           sync.WaitGroup
	pollInterval time.Duration
	syncDelay    time.Duration
	loginTimeout time.Duration
	syncTimeout  time.Duration
}

func NewZZZAccountPlugin(cfg Config) *ZZZAccountPlugin {
	return &ZZZAccountPlugin{
		cfg: cfg, mys: newZZZMYSClient(cfg.ZZZRequestTimeout),
		loginCancel: make(map[string]context.CancelFunc), syncCancel: make(map[string]context.CancelFunc),
		pollInterval: 2 * time.Second, syncDelay: 350 * time.Millisecond,
		loginTimeout: zzzLoginTimeout, syncTimeout: zzzSyncTimeout,
	}
}

func newZZZAccountPluginWithDependencies(cfg Config, store *ZZZAccountStore, mys zzzMYSService) *ZZZAccountPlugin {
	return &ZZZAccountPlugin{
		cfg: cfg, store: store, mys: mys,
		loginCancel: make(map[string]context.CancelFunc), syncCancel: make(map[string]context.CancelFunc),
		pollInterval: 2 * time.Second, syncDelay: 350 * time.Millisecond,
		loginTimeout: zzzLoginTimeout, syncTimeout: zzzSyncTimeout,
	}
}

func (p *ZZZAccountPlugin) Name() string { return ZZZAccountPluginID }

func (p *ZZZAccountPlugin) Match(request PluginRequest) bool {
	_, ok := parseZZZAccountCommand(request.Text)
	return ok
}

func (p *ZZZAccountPlugin) MatchToolIntent(request PluginRequest) bool {
	text := strings.ToLower(request.Text)
	if !strings.Contains(text, "绝区零") && !strings.Contains(text, "zzz") && !strings.Contains(text, "抽卡") && !strings.Contains(text, "式舆") && !strings.Contains(text, "深渊") {
		return false
	}
	for _, word := range []string{"我的", "账号", "绑定", "抽卡", "调频", "式舆", "深渊", "战绩"} {
		if strings.Contains(text, word) {
			return true
		}
	}
	return false
}

func (p *ZZZAccountPlugin) Handle(context.Context, PluginRequest) (string, error) {
	return "", nil
}

func (p *ZZZAccountPlugin) Start(ctx context.Context) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.runCtx != nil {
		return nil
	}
	if p.store == nil {
		store, err := OpenZZZAccountStore(p.cfg.ZZZAccountDB, p.cfg.ZZZCredentialKeyFile)
		if err != nil {
			return err
		}
		p.store = store
		p.ownsStore = true
	}
	if p.mys == nil {
		p.mys = newZZZMYSClient(p.cfg.ZZZRequestTimeout)
	}
	p.runCtx, p.cancel = context.WithCancel(ctx)
	return nil
}

func (p *ZZZAccountPlugin) Stop(ctx context.Context) error {
	p.mu.Lock()
	if p.cancel != nil {
		p.cancel()
	}
	for _, cancel := range p.loginCancel {
		cancel()
	}
	for _, cancel := range p.syncCancel {
		cancel()
	}
	p.mu.Unlock()
	done := make(chan struct{})
	go func() {
		p.wg.Wait()
		close(done)
	}()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-done:
	}
	p.mu.Lock()
	store := p.store
	ownsStore := p.ownsStore
	p.runCtx = nil
	p.cancel = nil
	p.mu.Unlock()
	if ownsStore && store != nil {
		return store.Close()
	}
	return nil
}

func (p *ZZZAccountPlugin) HandleInteractive(ctx context.Context, messenger interactiveMessenger, request PluginRequest) (bool, error) {
	command, ok := parseZZZAccountCommand(request.Text)
	if !ok {
		return false, nil
	}
	if p.store == nil || p.runCtx == nil {
		return true, errors.New("Fairy ZZZ account plugin is not running")
	}
	privateOnly := command == zzzCommandLogin || command == zzzCommandAccount || command == zzzCommandLogout
	if privateOnly && isGroupPluginRequest(request) {
		return true, p.sendText(ctx, messenger, request, "为保护账号信息，请私聊 Fairy 使用该命令。")
	}
	switch command {
	case zzzCommandLogin:
		return true, p.beginLogin(ctx, messenger, request)
	case zzzCommandAccount:
		summary, err := p.store.Summary(ctx, request.SenderID)
		if err != nil {
			return true, err
		}
		return true, p.sendText(ctx, messenger, request, formatZZZAccountSummary(summary))
	case zzzCommandGachaSync:
		return true, p.beginGachaSync(ctx, messenger, request)
	case zzzCommandGacha:
		summary, err := p.store.GachaSummary(ctx, request.SenderID)
		if errors.Is(err, ErrZZZAccountNotBound) {
			return true, p.sendText(ctx, messenger, request, zzzNotBoundText())
		}
		if err != nil {
			return true, err
		}
		return true, p.sendText(ctx, messenger, request, formatZZZGachaSummary(summary))
	case zzzCommandAbyss, zzzCommandAbyssPrevious:
		scheduleType := 1
		if command == zzzCommandAbyssPrevious {
			scheduleType = 2
		}
		return true, p.beginAbyssQuery(messenger, request, scheduleType)
	case zzzCommandLogout:
		p.cancelUserOperations(request.SenderID)
		if err := p.store.DeleteAccount(ctx, request.SenderID); err != nil {
			return true, err
		}
		return true, p.sendText(ctx, messenger, request, "已删除米游社绑定凭据和本地抽卡缓存。")
	default:
		return false, nil
	}
}

func (p *ZZZAccountPlugin) beginLogin(ctx context.Context, messenger interactiveMessenger, request PluginRequest) error {
	loginCtx, cancel, ok := p.reserveOperation(request.SenderID, true, p.loginTimeout)
	if !ok {
		return p.sendText(ctx, messenger, request, "已有登录二维码等待确认，请先在米游社完成扫码或等待二维码过期。")
	}
	login, err := p.mys.CreateQR(loginCtx)
	if err != nil {
		p.releaseOperation(request.SenderID, true)
		return p.sendText(ctx, messenger, request, zzzMYSUserMessage(err))
	}
	png, err := qrcode.Encode(login.URL, qrcode.Medium, 512)
	if err != nil {
		cancel()
		p.releaseOperation(request.SenderID, true)
		return fmt.Errorf("generate MYS login QR image: %w", err)
	}
	uploadCtx, uploadCancel := requestTimeout(ctx, 20*time.Second)
	upload, err := messenger.UploadFile(uploadCtx, "fairy-mys-login.png", "image", "image/png", png)
	uploadCancel()
	if err != nil {
		cancel()
		p.releaseOperation(request.SenderID, true)
		return err
	}
	segments := []protocol.MessageSegment{
		protocol.TextSegment("请使用米游社 App 扫描二维码，并在两分钟内确认登录。二维码只用于本次短期登录，不要转发给其他人。"),
		protocol.ImageSegment(upload.FileID, upload.URL),
		protocol.TextSegment("Fairy 不会要求你在聊天中粘贴 Cookie、Stoken 或密码。确认后只会保存加密凭据。"),
	}
	sendCtx, sendCancel := requestTimeout(ctx, 20*time.Second)
	err = messenger.SendSegments(sendCtx, request.ConversationID, segments)
	sendCancel()
	if err != nil {
		cancel()
		p.releaseOperation(request.SenderID, true)
		return err
	}
	p.wg.Add(1)
	go p.pollLogin(loginCtx, messenger, request, login)
	return nil
}

func (p *ZZZAccountPlugin) pollLogin(ctx context.Context, messenger interactiveMessenger, request PluginRequest, login zzzQRLogin) {
	defer p.wg.Done()
	defer p.releaseOperation(request.SenderID, true)
	ticker := time.NewTicker(p.pollInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			if errors.Is(ctx.Err(), context.DeadlineExceeded) {
				p.sendBackgroundText(messenger, request, "登录二维码已过期，请重新发送 /zzz login。")
			}
			return
		case <-ticker.C:
		}
		status, err := p.mys.QueryQR(ctx, login)
		if err != nil {
			if contextCancelled(ctx, err) {
				return
			}
			p.sendBackgroundText(messenger, request, zzzMYSUserMessage(err))
			return
		}
		switch status.Status {
		case "Created", "Scanned":
			continue
		case "Confirmed":
			if status.AccountID == "" || status.SToken == "" {
				p.sendBackgroundText(messenger, request, "米游社没有返回完整的登录凭据，请重新扫码。")
				return
			}
			p.finishLogin(ctx, messenger, request, status)
			return
		default:
			p.sendBackgroundText(messenger, request, "米游社返回了未知登录状态，请重新发送 /zzz login。")
			return
		}
	}
}

func (p *ZZZAccountPlugin) finishLogin(ctx context.Context, messenger interactiveMessenger, request PluginRequest, status zzzQRLoginStatus) {
	cookieToken, err := p.mys.ExchangeCookieToken(ctx, status)
	if err != nil {
		p.sendBackgroundText(messenger, request, zzzMYSUserMessage(err))
		return
	}
	roles, err := p.mys.GameRoles(ctx, status.AccountID, cookieToken)
	if err != nil {
		p.sendBackgroundText(messenger, request, zzzMYSUserMessage(err))
		return
	}
	var selected zzzMYSRole
	for _, role := range roles {
		if role.GameID == 8 && validZZZUID(role.UID) {
			selected = role
			break
		}
	}
	if selected.UID == "" {
		p.sendBackgroundText(messenger, request, "这个米游社账号尚未绑定国服绝区零角色，请先在米游社完成角色绑定。")
		return
	}
	account := zzzAccountCredential{
		OwnerID: request.SenderID, MYSAccountID: status.AccountID, UID: selected.UID,
		Cookie: "account_id=" + status.AccountID + ";cookie_token=" + cookieToken,
		SToken: status.SToken, MID: status.MID, UpdatedAt: time.Now(),
	}
	if err := p.store.PutAccount(ctx, account); err != nil {
		p.sendBackgroundText(messenger, request, "保存绑定失败，请稍后重试。")
		return
	}
	message := "米游社账号绑定成功。绝区零 UID：" + selected.UID
	if selected.Nickname != "" {
		message += "\n角色：" + selected.Nickname
	}
	message += "\n凭据已加密保存，不会进入模型上下文或决策链日志。"
	p.sendBackgroundText(messenger, request, message)
}

func (p *ZZZAccountPlugin) beginGachaSync(ctx context.Context, messenger interactiveMessenger, request PluginRequest) error {
	account, err := p.store.Account(ctx, request.SenderID)
	if errors.Is(err, ErrZZZAccountNotBound) {
		return p.sendText(ctx, messenger, request, zzzNotBoundText())
	}
	if err != nil {
		return err
	}
	syncCtx, _, ok := p.reserveOperation(request.SenderID, false, p.syncTimeout)
	if !ok {
		return p.sendText(ctx, messenger, request, "抽卡记录正在同步，请稍后查询。")
	}
	if err := p.sendText(ctx, messenger, request, "已开始同步抽卡记录，完成后 Fairy 会在当前会话通知你。首次同步可能需要一些时间。"); err != nil {
		p.releaseOperation(request.SenderID, false)
		return err
	}
	p.wg.Add(1)
	go p.syncGacha(syncCtx, messenger, request, account)
	return nil
}

type zzzGachaPool struct {
	Name     string
	Type     string
	BaseType string
}

var zzzGachaPools = []zzzGachaPool{
	{Name: "常驻频段", Type: "1001", BaseType: "1"},
	{Name: "独家频段", Type: "2001", BaseType: "2"},
	{Name: "音擎频段", Type: "3001", BaseType: "3"},
	{Name: "邦布频段", Type: "5001", BaseType: "5"},
	{Name: "独家重映", Type: "12002", BaseType: "102"},
	{Name: "音擎回响", Type: "13002", BaseType: "103"},
}

func (p *ZZZAccountPlugin) syncGacha(ctx context.Context, messenger interactiveMessenger, request PluginRequest, account zzzAccountCredential) {
	defer p.wg.Done()
	defer p.releaseOperation(request.SenderID, false)
	authKey, err := p.mys.AuthKey(ctx, account)
	if err != nil {
		if contextCancelled(ctx, err) {
			return
		}
		p.handleCredentialFailure(ctx, request.SenderID, err)
		p.sendBackgroundText(messenger, request, zzzMYSUserMessage(err))
		return
	}
	totalAdded := 0
	for _, pool := range zzzGachaPools {
		endID := "0"
		for page := 1; page <= 100; page++ {
			result, err := p.mys.GachaPage(ctx, account, authKey, pool.Type, page, endID, pool.BaseType)
			if err != nil {
				if contextCancelled(ctx, err) {
					return
				}
				p.handleCredentialFailure(ctx, request.SenderID, err)
				p.sendBackgroundText(messenger, request, zzzMYSUserMessage(err))
				return
			}
			if len(result.Records) == 0 {
				break
			}
			for index := range result.Records {
				result.Records[index].Pool = pool.Name
			}
			added, err := p.store.AddGachaRecords(ctx, request.SenderID, account.UID, result.Records)
			if err != nil {
				if contextCancelled(ctx, err) {
					return
				}
				p.sendBackgroundText(messenger, request, "保存抽卡记录失败，请稍后重试。")
				return
			}
			totalAdded += added
			if added == 0 {
				break
			}
			endID = result.Records[len(result.Records)-1].RecordID
			if !waitZZZSyncDelay(ctx, p.syncDelay) {
				return
			}
		}
	}
	now := time.Now()
	if err := p.store.MarkGachaSynced(ctx, request.SenderID, now); err != nil {
		if contextCancelled(ctx, err) {
			return
		}
		p.sendBackgroundText(messenger, request, "抽卡记录已获取，但同步时间保存失败。")
		return
	}
	summary, err := p.store.GachaSummary(ctx, request.SenderID)
	if err != nil {
		p.sendBackgroundText(messenger, request, "抽卡记录同步完成，本次新增 "+strconvInt(totalAdded)+" 条。")
		return
	}
	p.sendBackgroundText(messenger, request, "抽卡记录同步完成，本次新增 "+strconvInt(totalAdded)+" 条。\n"+formatZZZGachaSummary(summary))
}

func (p *ZZZAccountPlugin) beginAbyssQuery(messenger interactiveMessenger, request PluginRequest, scheduleType int) error {
	p.mu.Lock()
	runCtx := p.runCtx
	p.mu.Unlock()
	if runCtx == nil {
		return errors.New("Fairy ZZZ account plugin is not running")
	}
	p.wg.Add(1)
	go func() {
		defer p.wg.Done()
		ctx, cancel := context.WithTimeout(runCtx, 20*time.Second)
		defer cancel()
		account, err := p.store.Account(ctx, request.SenderID)
		if errors.Is(err, ErrZZZAccountNotBound) {
			p.sendBackgroundText(messenger, request, zzzNotBoundText())
			return
		}
		if err != nil {
			p.sendBackgroundText(messenger, request, "读取绝区零绑定失败，请稍后再试。")
			return
		}
		result, err := p.mys.Abyss(ctx, account, scheduleType)
		if err != nil {
			if contextCancelled(ctx, err) {
				return
			}
			p.handleCredentialFailure(ctx, request.SenderID, err)
			p.sendBackgroundText(messenger, request, zzzMYSUserMessage(err))
			return
		}
		current, err := p.store.Summary(ctx, request.SenderID)
		if err != nil || !current.Bound || current.UID != account.UID {
			return
		}
		p.sendBackgroundText(messenger, request, formatZZZAbyssSummary(result))
	}()
	return nil
}

func (p *ZZZAccountPlugin) reserveOperation(ownerID string, login bool, timeout time.Duration) (context.Context, context.CancelFunc, bool) {
	p.mu.Lock()
	defer p.mu.Unlock()
	operations := p.syncCancel
	if login {
		operations = p.loginCancel
	}
	if _, exists := operations[ownerID]; exists || p.runCtx == nil {
		return nil, nil, false
	}
	ctx, cancel := context.WithTimeout(p.runCtx, timeout)
	operations[ownerID] = cancel
	return ctx, cancel, true
}

func (p *ZZZAccountPlugin) releaseOperation(ownerID string, login bool) {
	p.mu.Lock()
	operations := p.syncCancel
	if login {
		operations = p.loginCancel
	}
	if cancel := operations[ownerID]; cancel != nil {
		cancel()
		delete(operations, ownerID)
	}
	p.mu.Unlock()
}

func (p *ZZZAccountPlugin) cancelUserOperations(ownerID string) {
	p.mu.Lock()
	if cancel := p.loginCancel[ownerID]; cancel != nil {
		cancel()
		delete(p.loginCancel, ownerID)
	}
	if cancel := p.syncCancel[ownerID]; cancel != nil {
		cancel()
		delete(p.syncCancel, ownerID)
	}
	p.mu.Unlock()
}

func (p *ZZZAccountPlugin) handleCredentialFailure(ctx context.Context, ownerID string, err error) {
	if isZZZMYSFailure(err, zzzMYSFailureExpired) {
		_ = p.store.MarkInvalid(ctx, ownerID)
	}
}

func (p *ZZZAccountPlugin) sendText(ctx context.Context, messenger interactiveMessenger, request PluginRequest, text string) error {
	replyTo := ""
	if isGroupPluginRequest(request) {
		replyTo = request.MessageID
	}
	sendCtx, cancel := requestTimeout(ctx, 20*time.Second)
	defer cancel()
	return messenger.SendText(sendCtx, request.ConversationID, replyTo, text)
}

func (p *ZZZAccountPlugin) sendBackgroundText(messenger interactiveMessenger, request PluginRequest, text string) {
	p.mu.Lock()
	runCtx := p.runCtx
	p.mu.Unlock()
	if runCtx == nil || strings.TrimSpace(text) == "" {
		return
	}
	ctx, cancel := context.WithTimeout(runCtx, 20*time.Second)
	defer cancel()
	if err := p.sendText(ctx, messenger, request, text); err != nil && ctx.Err() == nil {
		// Do not include upstream or credential material in asynchronous errors.
		return
	}
}

func (p *ZZZAccountPlugin) Tools() []Tool {
	return []Tool{
		&zzzAccountScopedTool{plugin: p},
		&zzzGachaScopedTool{plugin: p},
		&zzzAbyssScopedTool{plugin: p},
	}
}

func (p *ZZZAccountPlugin) Stats(ctx context.Context) (ZZZAccountStoreStats, error) {
	p.mu.Lock()
	store := p.store
	running := p.runCtx != nil
	p.mu.Unlock()
	if store == nil || !running {
		return ZZZAccountStoreStats{}, errors.New("Fairy ZZZ account store is unavailable")
	}
	return store.Stats(ctx)
}

func parseZZZAccountCommand(text string) (zzzAccountCommand, bool) {
	fields := strings.Fields(strings.TrimSpace(strings.ToLower(text)))
	if len(fields) < 2 || fields[0] != "/zzz" {
		return "", false
	}
	switch fields[1] {
	case "login":
		return zzzCommandLogin, len(fields) == 2
	case "account":
		return zzzCommandAccount, len(fields) == 2
	case "logout":
		return zzzCommandLogout, len(fields) == 2
	case "gacha":
		if len(fields) == 2 {
			return zzzCommandGacha, true
		}
		return zzzCommandGachaSync, len(fields) == 3 && fields[2] == "sync"
	case "abyss":
		if len(fields) == 2 {
			return zzzCommandAbyss, true
		}
		return zzzCommandAbyssPrevious, len(fields) == 3 && fields[2] == "previous"
	default:
		return "", false
	}
}

func validZZZUID(uid string) bool {
	if len(uid) < 8 || len(uid) > 10 {
		return false
	}
	for _, character := range uid {
		if character < '0' || character > '9' {
			return false
		}
	}
	return true
}

func isGroupPluginRequest(request PluginRequest) bool {
	return request.MessageType == "group" || strings.HasPrefix(request.ConversationID, "group_")
}

func zzzNotBoundText() string {
	return "尚未绑定米游社账号，请私聊 Fairy 发送 /zzz login。不要在聊天中粘贴 Cookie 或密码。"
}

func formatZZZAccountSummary(summary ZZZAccountSummary) string {
	if !summary.Bound {
		return zzzNotBoundText()
	}
	state := "有效"
	if summary.State != "valid" {
		state = "已失效，请重新登录"
	}
	return "米游社账号：" + maskZZZAccountID(summary.MYSAccountID) +
		"\n绝区零 UID：" + summary.UID + "\n凭据状态：" + state
}

func maskZZZAccountID(value string) string {
	runes := []rune(value)
	if len(runes) <= 4 {
		return "****"
	}
	return string(runes[:2]) + strings.Repeat("*", len(runes)-4) + string(runes[len(runes)-2:])
}

func formatZZZGachaSummary(summary ZZZGachaSummary) string {
	if summary.Total == 0 {
		return "UID " + summary.UID + " 暂无本地抽卡记录，请先发送 /zzz gacha sync。"
	}
	lines := []string{
		"UID " + summary.UID + " 抽卡统计",
		"总计 " + strconvInt(summary.Total) + " 抽，S 级 " + strconvInt(summary.SRank) + " 个",
	}
	for _, pool := range summary.PoolCounts {
		lines = append(lines, pool.Pool+"："+strconvInt(pool.Total)+" 抽，S 级 "+strconvInt(pool.SRank)+"，距上个 S "+strconvInt(pool.SinceSRank)+" 抽")
	}
	if !summary.SyncedAt.IsZero() {
		lines = append(lines, "同步时间："+summary.SyncedAt.Local().Format("2006-01-02 15:04"))
	}
	return strings.Join(lines, "\n")
}

func formatZZZAbyssSummary(summary zzzAbyssSummary) string {
	period := "本期"
	if summary.ScheduleType == 2 {
		period = "上期"
	}
	lines := []string{period + "式舆防卫战 · UID " + summary.UID}
	if summary.Nickname != "" {
		lines = append(lines, "角色："+summary.Nickname)
	}
	if summary.Rating == "" && summary.Score == 0 && summary.CompletedLayers == 0 {
		return strings.Join(append(lines, "暂无挑战数据。"), "\n")
	}
	lines = append(lines,
		"评级："+summary.Rating,
		"得分："+strconvInt(summary.Score)+" / "+strconvInt(summary.MaxScore),
		"完成层数："+strconvInt(summary.CompletedLayers),
	)
	if summary.RankPercent > 0 {
		lines = append(lines, "排名百分比："+strconvInt(summary.RankPercent)+"%")
	}
	return strings.Join(lines, "\n")
}

func strconvInt(value int) string { return fmt.Sprintf("%d", value) }

func waitZZZSyncDelay(ctx context.Context, delay time.Duration) bool {
	timer := time.NewTimer(delay)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return false
	case <-timer.C:
		return true
	}
}

type zzzAccountScopedTool struct{ plugin *ZZZAccountPlugin }

func (t *zzzAccountScopedTool) Spec() ToolSpec {
	return scopedZZZToolSpec(zzzAccountToolName, "Show the current sender's masked MYS account binding.", 5*time.Second, `{
        "type":"object","properties":{},"additionalProperties":false
    }`, `{
        "type":"object","properties":{
            "status":{"type":"string","pattern":"^(ok|not_bound)$"},
            "account":{"type":"object"}
        },"required":["status"],"additionalProperties":false
    }`)
}

func (t *zzzAccountScopedTool) Execute(context.Context, json.RawMessage) (json.RawMessage, error) {
	return nil, errors.New("scoped Fairy tool execution is required")
}

func (t *zzzAccountScopedTool) ExecuteScoped(ctx context.Context, scope ToolScope, _ json.RawMessage) (json.RawMessage, error) {
	summary, err := t.plugin.store.Summary(ctx, scope.SenderID)
	if err != nil {
		return nil, err
	}
	if !summary.Bound {
		return json.Marshal(map[string]any{"status": "not_bound"})
	}
	return json.Marshal(map[string]any{"status": "ok", "account": summary})
}

func (t *zzzAccountScopedTool) Project(output json.RawMessage) (ToolProjection, error) {
	var data struct {
		Status  string            `json:"status"`
		Account ZZZAccountSummary `json:"account"`
	}
	if err := json.Unmarshal(output, &data); err != nil {
		return ToolProjection{}, err
	}
	text := zzzNotBoundText()
	if data.Status == "ok" {
		text = formatZZZAccountSummary(data.Account)
	}
	return ToolProjection{ModelText: text, UserText: text}, nil
}

type zzzGachaScopedTool struct{ plugin *ZZZAccountPlugin }

func (t *zzzGachaScopedTool) Spec() ToolSpec {
	return scopedZZZToolSpec(zzzGachaToolName, "Read the current sender's locally cached ZZZ gacha summary.", 5*time.Second, `{
        "type":"object","properties":{},"additionalProperties":false
    }`, `{
        "type":"object","properties":{
            "status":{"type":"string","pattern":"^(ok|not_bound)$"},
            "summary":{"type":"object"}
        },"required":["status"],"additionalProperties":false
    }`)
}

func (t *zzzGachaScopedTool) Execute(context.Context, json.RawMessage) (json.RawMessage, error) {
	return nil, errors.New("scoped Fairy tool execution is required")
}

func (t *zzzGachaScopedTool) ExecuteScoped(ctx context.Context, scope ToolScope, _ json.RawMessage) (json.RawMessage, error) {
	summary, err := t.plugin.store.GachaSummary(ctx, scope.SenderID)
	if errors.Is(err, ErrZZZAccountNotBound) {
		return json.Marshal(map[string]any{"status": "not_bound"})
	}
	if err != nil {
		return nil, err
	}
	return json.Marshal(map[string]any{"status": "ok", "summary": summary})
}

func (t *zzzGachaScopedTool) Project(output json.RawMessage) (ToolProjection, error) {
	var data struct {
		Status  string          `json:"status"`
		Summary ZZZGachaSummary `json:"summary"`
	}
	if err := json.Unmarshal(output, &data); err != nil {
		return ToolProjection{}, err
	}
	text := zzzNotBoundText()
	if data.Status == "ok" {
		text = formatZZZGachaSummary(data.Summary)
	}
	return ToolProjection{ModelText: text, UserText: text}, nil
}

type zzzAbyssScopedTool struct{ plugin *ZZZAccountPlugin }

func (t *zzzAbyssScopedTool) Spec() ToolSpec {
	return scopedZZZToolSpec(zzzAbyssToolName, "Query the current sender's current or previous ZZZ Shiyu Defense record.", 15*time.Second, `{
        "type":"object","properties":{"schedule_type":{"type":"integer","minimum":1,"maximum":2}},
        "required":["schedule_type"],"additionalProperties":false
    }`, `{
        "type":"object","properties":{
            "status":{"type":"string","pattern":"^(ok|not_bound)$"},
            "summary":{"type":"object"}
        },"required":["status"],"additionalProperties":false
    }`)
}

func (t *zzzAbyssScopedTool) Execute(context.Context, json.RawMessage) (json.RawMessage, error) {
	return nil, errors.New("scoped Fairy tool execution is required")
}

func (t *zzzAbyssScopedTool) ExecuteScoped(ctx context.Context, scope ToolScope, arguments json.RawMessage) (json.RawMessage, error) {
	var input struct {
		ScheduleType int `json:"schedule_type"`
	}
	if err := json.Unmarshal(arguments, &input); err != nil {
		return nil, err
	}
	account, err := t.plugin.store.Account(ctx, scope.SenderID)
	if errors.Is(err, ErrZZZAccountNotBound) {
		return json.Marshal(map[string]any{"status": "not_bound"})
	}
	if err != nil {
		return nil, err
	}
	summary, err := t.plugin.mys.Abyss(ctx, account, input.ScheduleType)
	if err != nil {
		t.plugin.handleCredentialFailure(ctx, scope.SenderID, err)
		return nil, err
	}
	return json.Marshal(map[string]any{"status": "ok", "summary": summary})
}

func (t *zzzAbyssScopedTool) Project(output json.RawMessage) (ToolProjection, error) {
	var data struct {
		Status  string          `json:"status"`
		Summary zzzAbyssSummary `json:"summary"`
	}
	if err := json.Unmarshal(output, &data); err != nil {
		return ToolProjection{}, err
	}
	text := zzzNotBoundText()
	if data.Status == "ok" {
		text = formatZZZAbyssSummary(data.Summary)
	}
	return ToolProjection{ModelText: text, UserText: text}, nil
}

func scopedZZZToolSpec(name, description string, timeout time.Duration, inputSchema, outputSchema string) ToolSpec {
	return ToolSpec{
		Name: name, Description: description,
		InputSchema: json.RawMessage(inputSchema), OutputSchema: json.RawMessage(outputSchema),
		Risk: RiskLow, Concurrency: ToolSerial, Idempotency: ToolReadOnly,
		Timeout: timeout, MaxInputBytes: 1024, MaxOutputBytes: 64 * 1024,
	}
}

var _ InteractivePlugin = (*ZZZAccountPlugin)(nil)
var _ PluginLifecycle = (*ZZZAccountPlugin)(nil)
var _ PluginToolProvider = (*ZZZAccountPlugin)(nil)
var _ ToolIntentMatcher = (*ZZZAccountPlugin)(nil)
var _ ScopedTool = (*zzzAccountScopedTool)(nil)
var _ ScopedTool = (*zzzGachaScopedTool)(nil)
var _ ScopedTool = (*zzzAbyssScopedTool)(nil)
