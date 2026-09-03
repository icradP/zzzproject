# Fairy Bot 服务

Fairy 是独立于 ZZZ IM 服务端运行的 Bot 进程。它使用普通账号通过 ZZZ Server WebSocket 接入；IM 服务端继续只负责账号、关系、群组、消息和通知，不持有模型密钥，也不运行 AI 推理。

Fairy 演进为受控 AI Agent Bot 的分层架构、参考覆盖审计、安全边界和实施顺序见 [FAIRY_AGENT_ARCHITECTURE.md](FAIRY_AGENT_ARCHITECTURE.md)。

## 第一阶段能力

- 首次启动使用邀请码注册 `fairy`，后续使用独立密码登录并自动重连。
- 自动接受发给 Fairy 的好友请求；成为好友后可正常私聊，也可被邀请进群。
- 私聊文本直接触发；群聊中的 `@Fairy`、Fairy 管理指令和已注册命令属于硬触发。普通群消息先经过本地 Gate，默认 `shadow` 只记录固定决策分类，不排队、不调用模型、不保存正文也不回复。
- 群主和管理员可用 `/fairy on`、`/fairy off` 控制群回复，状态保存在 Fairy 自己的数据目录。
- 群主和管理员可用 `/fairy proactive off|shadow|on` 设置群级软触发；`on` 仅允许明确触发后同一用户在 2 分钟 Focus 内继续对话，并受默认 30 秒冷却约束。Focus 冲突、过期和冷却均不会进入模型。
- 上下文只保存在进程内存中，默认 30 分钟过期、最多保留 12 条消息，不写入状态文件。溢出的早期消息会压缩为一条 `user` 角色的不可信滚动摘要，并在内存元数据中保留来源起止 ID 和数量。
- 每个会话可用 `/fairy memory on|off` 单独控制临时记忆；群聊设置仅群主和管理员可改，关闭时立即清空已有上下文，插件仍可使用。
- 来源化事实记忆与临时上下文完全分离且默认关闭。私聊用户或群管理员明确执行 `/fairy facts on` 后，只有 `/fairy remember <事实>` 提交的内容才会写入独立 `facts.db`；每条保留来源消息 ID 和创建时间，180 天过期，可分页查看、逐条删除或全部永久删除。群事实写操作仅群主和管理员可用。
- 事实召回按“私聊用户 + 会话”或群聊范围隔离，以 `user` 角色的不可信 JSON 注入，不会成为 system 指令；单范围最多 30 条、6000 字，单条最多 300 字，疑似凭据拒绝保存。关闭只停止召回，不暗中删除已有事实。
- 在调用外部模型前拦截高置信的私钥、Bearer、密码、API Key、Token 和 Cookie；被拦截内容不进入上下文、不消耗额度，也不会发送给模型供应商。
- AI 支持 OpenAI-compatible Chat Completions 与 Anthropic-compatible Messages，可按供应商动态配置；模型未配置时，帮助、群管理和 ZZZ 插件仍可使用。
- 管理后台通过回环地址代理 Fairy 自己的管理 API，可配置模型、人格、行为、上下文、额度和已注册插件。Fairy 页面按 Runtime、Models、Behavior、Plugins & Tools、Decisions 分类：运行态继续展示脱敏聚合，Decisions 则作为受管理鉴权保护的敏感数据面，按 Turn 展示 Provider 明文 thinking、Planner、Replyer、工具调用与结果。IM 核心不执行模型或插件代码。页面还提供固定合成 Agent 诊断，可验证 Planner -> Replyer 链路而不发送 IM 消息、不执行工具、不读取用户会话。
- AI 调用默认每天最多 200 次；全局总额度与各 Task 独立额度原子持久化并按 UTC 日期重置。
- `/zzz <UID>` 通过 Enka.Network 查询游戏内公开展示资料，按上游 TTL 缓存；不需要也不接收米游社 Cookie。功能与交互基准为 [ZZZeroUID](https://github.com/ZZZure/ZZZeroUID)，公开资料查询与米游社账号能力彼此隔离。
- `zzz-account` 第一版只支持国服米游社：私聊 `/zzz login` 由 Fairy 本地生成二维码并通过 ZZZ 媒体服务发送，后台轮询确认后绑定发送者自己的绝区零 UID；`/zzz gacha sync` 缓存抽卡记录，`/zzz gacha` 和 `/zzz abyss [previous]` 查询发送者本人的数据。群聊不能登录、查看账号或退出绑定。
- 米游社 Cookie 与 Stoken 使用独立随机 32-byte 密钥和 AES-256-GCM 加密，AAD 绑定 IM 用户与凭据种类；数据库和密钥均为 `0600`。凭据不进入模型、Planner、Trace、日志或管理 API，管理运行态只显示绑定数、有效数和抽卡缓存记录数。`/zzz logout` 会事务删除凭据和关联抽卡缓存。
- `zzz-profile` 已迁移到统一 Tool Pipeline：注册时校验输入/输出 Schema，执行时依次经过可见性、授权、风险、副作用、调用次数、超时、输出大小和脱敏检查。工具只返回结构化结果，模型投影会标记为不可信外部数据。
- 私聊或明确 `@Fairy` 的群消息可用包含唯一 8–10 位 UID 且同时包含“绝区零”“UID”“代理人”或“公开资料”的自然语言查询；没有关键词、包含多个 UID 或长度不合法时不会调用工具。
- 消息按会话 FIFO 执行，同一会话最多一个活跃 Turn；重复入站 message ID 会被 SQLite 幂等记录拦截，达到并发上限时进入有界队列而不是静默丢弃。
- Fairy 回复在确认超时或连接断开时会在当前进程内最多尝试 3 次；所有尝试复用同一个 `client_message_id`，服务端返回原消息而不会重复广播。私聊直接发送最终回复，不引用触发消息；群聊仍引用触发消息。回复正文可作为受限决策链事件保存在 `fairy.db`，但进程重启后不自动重放。
- 只有确认发送成功的模型最终回复可以接收显式质量反馈。用户用 `👍`（Reaction ID `76`）或 `👎`（Reaction ID `fairy-negative`）评价；改评按同一用户覆盖，取消 Reaction 删除当前匹配评价，回复被撤回后同步删除关联记录。命令、插件直出、错误和限流回复不参与统计。
- `/fairy stop` 可抢占当前会话正在执行的 Turn。关闭或管理配置重启时先停止接纳，再按超时 drain/cancel。
- `fairy.db` 保存入站去重、Turn / Model / Tool / Gate 事件、决策链和显式质量反馈并默认保留 30 天。会话标识仍使用部署随机密钥做 HMAC，Prompt 与用户原始消息正文不保存；决策链会保存 Provider 实际返回的明文 `thinking`、Planner/Replyer 输出以及不含高置信凭据的工具参数和投影结果，因此必须按敏感管理数据保护。Provider 的 `redacted_thinking` 只保存不可逆摘要式签名和“已隐藏”标记，不能恢复或伪造明文。反馈仍只保存消息与评价者的 HMAC 引用、随机 Turn ID、正负标签和时间。
- 通用 `send_message` 协议支持可选 `client_message_id`。服务端按“发送者 + 客户端消息 ID”持久化去重；相同内容重试返回原消息且不再次广播/推送，不同内容复用同一 ID 会被拒绝。Fairy 的出站消息默认携带该键。
- 普通闲聊继续只调用一次 `replyer`；配置 `planner` Task 后，明确的工具意图或 `/fairy agent <请求>` 会进入最多 4 Step 的 `planner -> tools -> replyer` Loop。Planner 只能提交原生 Tool Call 或严格 JSON Decision，不能直接发送消息或绕过 Tool Pipeline。
- Fairy 插件宿主提供 Manifest、组件注册、Capability Context、Hook/Event、依赖和最低版本检查、生命周期 disposer、卸载与热重载。`context-memory`、`fact-memory`、`self-cognition` 和旧命令插件都通过同一宿主管理；Tool Runtime 每次从当前插件快照解析工具，卸载或重载不会留下旧实例。可信编译期插件使用进程内 Runner；外部工具继续使用 MCP 子进程，管理页不允许上传或执行任意插件代码。
- Fairy 可启动显式配置的可信 MCP stdio Provider，并把获准的只读工具以 `provider-id.tool-name` 注册到同一 Tool Pipeline。存在外部工具时，自然语言请求统一先进入 Planner，避免用关键词猜测第三方工具意图；这会增加一次 Planner 调用，应计入模型额度和成本预算。
- 配置 `vision` 后，Fairy 可理解最多 4 张已校验图片；配置 `transcriber` 后，可转写 1 条不超过 10 MB / 2 分钟的服务端语音。未配置对应 Task 时不下载附件、不调用模型，也不会把图片说明文字脱离图片交给 Replyer 猜测。
- 服务端媒体只读取同源 `/files/`；外部仅接受经过 DNS、拨号、重定向、私网地址、响应大小、MIME、签名和图片尺寸检查的 HTTPS 图片，外部语音拒绝。图片 URL、字节、转写和描述正文不写入 Trace。
- 媒体分析结果作为明确的不可信 `user` 数据交给 `replyer`，不会进入 Planner 或触发 MCP Tool；疑似凭据的转写/描述会在 Replyer 前拒绝，失败 Turn 不写入上下文。
- Planner、Replyer、媒体 Task 和工具共用一个可取消 Turn；每个 Turn 最多执行 6 次工具并最多发送一次最终回复。模型额度按每次 Planner / Replyer / Vision / Transcriber 逻辑调用分别计数，Provider 内部 Retry 不重复占用该额度。
- Prompt 按 `identity`、`persona`、`platform`、`safety`、`task`、`tools`、`expression` 和 `runtime_context` 分段组装；表达档位支持 `brief / normal / detailed`。Prompt Trace 只记录 section 版本和使用部署 `trace.key` 生成的 HMAC，不记录 Prompt 正文。工具投影始终按不可信外部数据处理，最终回复还会经过空值、长度、疑似凭据和危险链接检查。
- 管理员可维护最多 64 条只读行为经验，每条包含作用域、最多 12 个关键词、场景、建议动作和观察结果。Fairy 只用用户原始文本确定性选择最多 3 条作为 advisory JSON 注入 Planner / Replyer；媒体识别文本不参与召回，聊天与模型均不能写回，自动学习固定关闭。

## 指令

当服务器存在 `fairy` 账号且尚未成为好友时，客户端会在联系人页的推荐区域显示 Fairy。可以先打开带 Bot 标识的个人名片，也可以直接发送好友请求；Fairy 在线时会自动接受。成为好友后推荐项消失，Fairy 作为普通联系人显示，并可被邀请进群。

客户端默认把 `fairy` 识别为预设 Bot。其他部署可在 ZZZ Server 连接配置的 `extra.presetBotIds` 中填写账号 ID 列表，使用逗号分隔字符串或 JSON 数组；配置空数组可关闭预设 Bot 推荐。客户端只查询账号是否存在，不要求 IM 服务端增加 Bot 管理能力。

| 指令 | 作用 |
| --- | --- |
| `/fairy help` | 查看帮助 |
| `/fairy stop` | 停止当前会话正在执行的 Fairy 任务 |
| `/fairy status` | 查看当前群开关和 AI 配置状态 |
| `/fairy clear` | 清除当前会话的临时上下文 |
| `/fairy privacy` | 查看上下文与外部模型隐私说明 |
| `/fairy memory on` | 开启当前会话的临时记忆；群聊仅管理员可改 |
| `/fairy memory off` | 关闭记忆并立即清除当前会话上下文 |
| `/fairy facts on\|off` | 明确开启或关闭当前范围的持久事实召回；群聊仅管理员可改 |
| `/fairy facts list [页码]` | 分页查看事实正文、事实 ID、来源消息和创建日期 |
| `/fairy remember <事实>` | 显式保存事实；必须先开启，群聊仅管理员可写 |
| `/fairy forget <事实ID\|all>` | 永久删除指定事实或当前范围的全部事实 |
| `/fairy quota` | 查看今日模型调用次数和剩余额度 |
| `/fairy proactive off\|shadow\|on` | 群主或管理员设置群聊软触发模式 |
| `/fairy agent <请求>` | 显式使用 Planner 处理工具型或多步骤请求；需要配置 `planner` Task |
| `/fairy on` | 群主或管理员开启群回复 |
| `/fairy off` | 群主或管理员关闭群回复 |
| `/zzz <UID>` | 查询绝区零公开展示资料 |
| `/zzz login` | 私聊发起国服米游社扫码绑定 |
| `/zzz account` | 私聊查看脱敏账号和绑定 UID |
| `/zzz gacha sync` | 同步并缓存自己的抽卡记录 |
| `/zzz gacha` | 查询自己的本地抽卡统计 |
| `/zzz abyss` | 查询自己的本期式舆防卫战 |
| `/zzz abyss previous` | 查询自己的上期式舆防卫战 |
| `/zzz logout` | 私聊删除米游社凭据和抽卡缓存 |

## 构建与部署

```bash
# 验证当前未提交的 IM Server/Fairy 代码；产物仅存于临时目录，不会发布或部署。
./deploy/zzz-im/release-native.sh validate

# 同时构建 IM Server、VAPID 和 Fairy，并在本机 Linux 容器中验证 SQLite。
./deploy/zzz-im/release-native.sh build

# 提交已推送且 CI/CD 成功后，上传产物并部署；生产机不会编译源码。
./deploy/zzz-im/release-native.sh deploy root@server.example
```

统一发布脚本在远端调用底层安装脚本，创建独立的 `zzz-fairy` 系统用户、`/var/lib/zzz-fairy` 数据目录、`/etc/zzz-im/fairy.env` 密钥文件和 `zzz-fairy.service`。`http://127.0.0.1:18081/health` 是进程存活探针，只要 HTTP 服务仍在运行就返回 `200`；`http://127.0.0.1:18081/ready` 是就绪探针，仅在 Fairy 已登录 IM 且 Scheduler 仍接纳新 Turn 时返回 `200`。部署和切流只使用 `/ready`。远端切换前会备份 IM/Fairy 二进制、环境文件和 systemd 单元；任一就绪检查失败都会回滚。

## 模型配置

首次部署可以在 `/etc/zzz-im/fairy.env` 提供模型默认值，不要提交到仓库：

```dotenv
FAIRY_MODEL_BASE_URL=https://provider.example/v1
FAIRY_MODEL_PROTOCOL=openai-compatible
FAIRY_MODEL_API_KEY=replace-with-provider-key
FAIRY_MODEL_NAME=provider-model-name
FAIRY_AI_ROLLOUT_MODE=off
FAIRY_MODEL_DAILY_LIMIT=200
FAIRY_MODEL_MAX_TOKENS=600
FAIRY_ZZZ_ACCOUNT_DB=/var/lib/zzz-fairy/zzz-accounts.db
FAIRY_ZZZ_CREDENTIAL_KEY_FILE=/var/lib/zzz-fairy/zzz-credentials.key
```

修改后执行：

```bash
sudo systemctl restart zzz-fairy
curl --fail http://127.0.0.1:18081/ready
```

部署脚本会为 IM 服务与 Fairy 生成同一个本机管理令牌。登录
`/im/admin/` 后可在 `Fairy` 页面修改配置。保存后的完整可管理配置写入
`/var/lib/zzz-fairy/config.json`，文件权限为 `0600`，并覆盖对应的环境默认值。
API Key 只允许替换或清除，GET 响应和管理页面都不会回显密钥。群聊软触发、
Focus、cooldown 和表达档位使用原子快照对新 Turn 热更新；模型路由、密钥、插件、
系统提示和其他进程配置保存后仍由 Fairy 自动重启。IM 服务不需要重启。

Fairy 页面同时支持 Provider、Model、Task 三层模型路由配置：Provider 保存协议、端点、重试策略和只写 API Key；Model 保存远端模型和价格；Task 保存最大输出、超时、独立日额度和 fallback 顺序。`openai-compatible` 在 Base URL 后调用 `/chat/completions`，`anthropic-compatible` 调用 `/v1/messages` 并使用标准 `x-api-key` 与 `anthropic-version` 头。Provider 与 Model 可以在没有 Task 时先保存、探测和质量评测；生产回复默认使用 `off`，管理员可选择 `allowlist` 只向最多 128 个指定账号灰度，或选择 `all` 向全部用户开放。`allowlist` 必须至少包含一个合法账号 ID；未获准账号仍可使用管理指令和确定性插件，私聊模型请求收到固定未开放提示，群聊模型请求静默忽略。只有存在 `replyer` Task，且其中每个 fallback 候选都通过当前版本质量语料后才会启动模型 Router。增加 `planner` 启用 Agent Loop，增加 `vision` / `transcriber` 分别启用图片理解 / 语音转写。图片可使用两种协议，语音转写当前只能绑定 OpenAI-compatible Provider。新增 Task 的推荐顺序是 `replyer`、`planner`、`vision`、`transcriber`、`utility`。全局额度限制所有逻辑调用总数，Task 额度限制对应能力；旧 v1-v4 配置中的 Task 自动继承全局额度。

每个已保存 Model 可在管理页执行一次安全连通性测试。探测只使用固定的无用户数据 Prompt，最多请求 256 个输出 Token，硬超时 30 秒且全进程最多同时运行一个；不会携带聊天、记忆、行为经验或工具数据，不计入聊天日额度，也不写 Turn Trace。结果只显示协议、Model / Provider ID、延迟、Token、按已配置价格估算的费用、固定失败分类和 HTTP 状态，不返回模型正文、供应商错误正文或密钥。未保存的 Model 或 Provider 修改必须先保存再测试。每次探测都会产生一次真实供应商请求和相应费用。Agent 诊断使用同一个诊断并发槽，固定请求 `POST /admin/agent-diagnostic`（JSON `{"case_id":"pipeline-basic"}`），生产 rollout 为 `off` 时也可以针对已保存模型建立隔离 Router；该请求不计入聊天额度，失败只返回固定状态。诊断中的 Planner 决策格式错误以及 Replyer 固定回复不匹配各自最多修复一次，修复不携带拒绝正文、不重跑已完成阶段或工具，但会产生独立供应商请求与相应费用。

受管配置当前版本为 v10，并兼容读取 v1-v9。v1-v7 中已经具备 `replyer` 路由的部署迁移为 `all`，v8-v9 按原 `ai_enabled` 迁移为 `off` 或 `all`，避免升级时改变既有生产行为；v10 同时保存兼容字段与 rollout mode，二者自相矛盾时拒绝加载。没有旧配置的新部署和仅通过环境变量提供候选模型的部署默认关闭。每次成功保存或质量资格写入都会生成单调递增的 revision 和 UTC 更新时间；管理 API 分别返回期望 revision 与已生效 `active_revision`，状态固定为 `active`、`applying` 或 `restart_pending`。热更新只有成功切换运行快照后才推进 active revision，需要重启的配置则由新进程加载后推进，不能把“已写入磁盘”误报为“已生效”。最近 50 次保存只记录 `ai_activation`、`ai_rollout`、`model_validation`、`model`、`prompt`、`behavior`、`runtime_limits`、`plugins`、`external_tools`、`behavior_experiences` 或 `none` 等固定分类，不记录配置值、Prompt、URL、密钥或用户身份；灰度账号只写入 `0600` 配置，日志只输出名单数量。

管理页还可维护只读行为经验；经验变化随完整配置受控重启，缺省字段保留现值，显式空数组清空。Live runtime 只显示经验配置数、启用数和 `auto_learning=false`，并同时显示配置 revision/生效状态、脱敏变更历史、全局额度、每个 Task 的已用/剩余/上限、出站成功/重试/失败/结果未知计数，以及最近 24 小时已评价回复数、赞、踩和正向率聚合。Model health 按 `task_id + provider_id + model_id` 汇总最近 24 小时的调用/成功/失败、fallback、repair、P50/P95、Token、费用和固定失败码，不返回远端模型名或逐请求 Trace。Recent failures 最多展示最近 24 小时内按时间倒序排列的 20 条 Model、Tool、Admission 和 Turn 失败，只包含固定失败码、配置 ID、耗时、attempt / step / fallback / repair 与有限队列数字；空状态固定返回 `recent_failures: []`。这些状态不包含经验正文、关键词、用户、会话、附件 URL、消息正文、Prompt、工具参数、供应商错误、Trace / Turn / Snapshot / Tool Call ID 或可逆的反馈标识。显式反馈当前仅用于质量观测，自动行为学习仍固定关闭。

外部工具只支持管理员预先安装到服务器的可信 MCP stdio 可执行文件；管理页不能上传二进制、源码或脚本，也不经过 shell 拼接命令。每个 Provider 必须使用绝对可执行路径、显式工具 allowlist 和环境变量名称 allowlist。凭据值只从 Fairy 进程环境继承，不写入或返回受管配置；疑似包含凭据的命令参数会被拒绝。首版只注册声明 `readOnlyHint=true` 且非 destructive、输入 Schema 能被 Fairy 严格验证的工具。启动失败不会阻止 Fairy 连接 IM；调用 timeout 或协议故障会终止子进程并进入熔断，冷却后按需重连。stderr 始终丢弃，管理运行态只显示固定状态、工具数、连续失败数和熔断时间。

MCP 子进程继承 `zzz-fairy.service` 的非特权用户、文件系统和系统调用限制，systemd 使用 control-group 统一终止并限制任务数。Provider 自身仍负责固定或 allowlist 网络端点、SSRF 防护和数据最小化；MCP 协议不是恶意代码沙箱，不应接入来源不明的程序。

## 离线评测

不依赖模型供应商的版本化评测集位于 `server/internal/fairy/testdata/eval/v1.json`，由严格 Schema 的 Go 测试读取。当前 74 条样例覆盖中英文 Gate、Prompt Injection 输入边界、凭据检测、输出链接安全、ZZZ 工具意图、Planner Decision、媒体批次和行为经验召回规则；未知字段、重复 ID 或尾随 JSON 会直接使测试失败。

```bash
cd server
go test ./internal/fairy -run TestDeterministicEvalCorpus -v
```

候选模型质量门禁使用独立的 `server/internal/fairy/testdata/quality/v1.json`。当前 5 个固定 Case 覆盖中文简洁回复、英文隐私回复、Fairy 身份、Prompt Injection 隐藏标记保护和原生 Tool Call。API Key 只能通过已经存在的 `FAIRY_EVAL_API_KEY` 进程环境变量传入，不能放在命令参数、配置文件或仓库中：

```bash
cd server
export FAIRY_EVAL_PROTOCOL=anthropic-compatible
export FAIRY_EVAL_BASE_URL=https://provider.example/anthropic
export FAIRY_EVAL_MODEL=candidate-model
# FAIRY_EVAL_API_KEY 由本机密钥管理器或 CI Secret 注入。
go run ./cmd/fairy-eval
```

JSON 报告只包含固定 Case ID、通过状态、固定失败码、调用次数、延迟、Token 和可选费用，不包含 Prompt、模型回复、Base URL、API Key 或供应商错误正文。默认门槛为 P95 不超过 30 秒、总输入不超过 10000 Token、总输出不超过 4000 Token；配置输入/输出单价和成本上限后才启用成本门禁。退出码 `0` 表示通过，`1` 表示配置或运行错误，`2` 表示质量门禁失败。

同一套质量门禁也接入服务器管理页的 Fairy Model 行。`Quality` 只能评测已保存的 Model，POST 异步启动后由页面轮询最近任务；连通性 `Test` 与质量评测共享一个诊断并发槽，冲突返回 `429` 和 `Retry-After: 1`。管理端任务使用启动时的配置快照并随 Fairy 进程取消，只返回任务状态、固定 Case 状态/失败码、P50/P95、汇总 Token 和可选费用；不返回 Provider、远端模型名、逐请求细节或模型正文。通过后写入的资格绑定质量语料版本以及 Provider/Model 的精确配置摘要，摘要包含 API Key 但摘要与密钥均不通过 API 返回；协议、URL、密钥、超时/重试、远端模型名、上下文窗口或价格变化都会自动使资格失效。评测期间配置发生变化时任务返回固定 `configuration_changed`，资格无法安全落盘时返回 `qualification_store`。

MiMo `mimo-v2.5-pro` 已于 2026-09-03 多次通过该 Anthropic-compatible 质量门禁，均为 5/5 Case 且每 Case 单次调用。生产候选验收的 256 Token 安全探针约 3.6 秒，使用 25 input / 44 output tokens；固定质量语料使用 1256 input / 518 output tokens，P50 约 3.89 秒、P95 约 10.80 秒。通过后资格已绑定 v9 revision 2 的当前 Provider/Model 配置并持久化；F5.19 部署后管理 API 将其兼容投影为 schema v10 revision 2 active，`production_ready=true`、rollout 为 `off` 且灰度名单为空，因此不会处理真实用户对话。磁盘配置保持 v9，直到下一次管理员保存才原子写为 v10。此前 64 Token 探针可能只产生 `thinking` 而没有可见文本，因而被正确归类为 `invalid_response`。套餐响应不提供可直接换算的单价，生产配置价格暂记为 0，成本门禁保持关闭。凭据只保存在生产 Fairy 的 `0600` 受管配置中，未写入仓库、管理 API 或日志。其他真实模型评测也必须使用固定合成语料，不得直接对生产用户试跑。

## 主要配置

| 环境变量 | 默认值 | 说明 |
| --- | --- | --- |
| `FAIRY_SERVER_URL` | `ws://127.0.0.1:18080/ws` | ZZZ Server WebSocket |
| `FAIRY_USER_ID` | `fairy` | Bot 普通账号 ID |
| `FAIRY_PASSWORD` | 无 | 必填，8-72 字符 |
| `FAIRY_INVITE_CODE` | 无 | 仅首次自动注册需要 |
| `FAIRY_CONFIG_FILE` | `/var/lib/zzz-fairy/config.json` | 管理页面持久化配置，权限 `0600` |
| `FAIRY_TRACE_DB` | `/var/lib/zzz-fairy/fairy.db` | 入站去重与脱敏 Turn Trace，权限 `0600` |
| `FAIRY_FACT_DB` | `/var/lib/zzz-fairy/facts.db` | 用户明确提交的来源化事实记忆，权限 `0600` |
| `FAIRY_TRACE_KEY_FILE` | `/var/lib/zzz-fairy/trace.key` | 会话标识 HMAC 密钥，首次启动随机生成，权限 `0600` |
| `FAIRY_ADMIN_TOKEN` | 无 | 本机管理 API 必填令牌，不向浏览器暴露 |
| `FAIRY_GROUP_DEFAULT_ENABLED` | `true` | 新群默认允许被提及时回复 |
| `FAIRY_GROUP_SOFT_TRIGGER` | `shadow` | 新群软触发默认模式：`off`、`shadow` 或 `on` |
| `FAIRY_FOCUS_TTL` | `2m` | 明确触发后同一群用户的软触发 Focus 时间 |
| `FAIRY_SOFT_COOLDOWN` | `30s` | 同一 Focus 内软触发回复的最短间隔 |
| `FAIRY_EXPRESSION_STYLE` | `normal` | 回复表达档位：`brief`、`normal` 或 `detailed` |
| `FAIRY_RATE_LIMIT` | `8s` | 每用户、每会话触发间隔 |
| `FAIRY_CONTEXT_TTL` | `30m` | 内存上下文过期时间 |
| `FAIRY_CONTEXT_MESSAGES` | `12` | 每会话最多上下文消息数 |
| `FAIRY_MAX_CONCURRENT` | `4` | 同时活跃的会话数上限 |
| `FAIRY_MAX_PENDING` | `256` | 全局待执行 Turn 上限 |
| `FAIRY_MAX_CONVERSATION_PENDING` | `16` | 单会话待执行 Turn 上限 |
| `FAIRY_TURN_TIMEOUT` | `60s` | 单个 Turn 硬超时 |
| `FAIRY_DRAIN_TIMEOUT` | `10s` | 退出前等待已接纳 Turn 的时间 |
| `FAIRY_AI_ROLLOUT_MODE` | 空，等效于 `off` | 生产 AI 模式：`off`、`allowlist` 或 `all` |
| `FAIRY_AI_ALLOWED_USERS` | 空 | 灰度账号 ID，使用逗号或换行分隔，最多 128 个 |
| `FAIRY_AI_ENABLED` | `false` | 旧版兼容开关；未设置 rollout mode 时 `true` 等效于 `all` |
| `FAIRY_MODEL_DAILY_LIMIT` | `200` | 每日模型调用上限，`0` 表示全部拒绝 |
| `FAIRY_MODEL_PROTOCOL` | `openai-compatible` | 旧版单模型环境配置协议；可选 `openai-compatible` 或 `anthropic-compatible` |
| `FAIRY_ZZZ_API_URL` | Enka.Network | 必须包含 `{uid}` 的 HTTPS URL 模板 |
| `FAIRY_ZZZ_PLUGIN_ENABLED` | `true` | 内置 `zzz-profile` 插件默认开关 |

MiMo `mimo-v2.5-pro` 已作为首个生产候选通过资格门禁，但套餐单价、月度预算和内容安全策略仍未确定。在这些配置明确前，生产环境应保持 `FAIRY_AI_ROLLOUT_MODE=off`；候选 Provider 可继续保存、探测和评测，但不用于用户对话。
