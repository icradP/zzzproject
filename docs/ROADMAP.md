# ZZZ IM 产品路线图

## 一、产品方向

ZZZ IM 以 PWA 作为 iOS 客户端，以原生桌面端覆盖 macOS 和其他桌面平台。产品后续围绕三个方向持续建设：

1. 提升 PWA 的加载速度、加载反馈和弱网可用性。
2. 完善 IM 基础能力、群组管理和个人表达能力。
3. 在基础通信稳定后，引入 AI 好友、语音房间和视频直播房间。

规划原则：

- IM 服务端保持通用，只处理账号、关系、会话、消息、媒体和通知。
- 外部平台和 Bot 尽量通过独立适配层或独立服务接入。
- 聊天媒体和个人名片背景均支持服务端托管、客户端自定义图床和已有网络图片 URL。
- 优先完成高频基础体验，再建设装饰性和大型实时音视频功能。

## 二、第一阶段：性能与基础设施（P0）

### 1. PWA 加载体验

目标：解决 `icrad.ltd` 首次访问慢、用户不知道还需等待多久的问题。

功能范围：

- 加载页显示当前阶段，例如初始化、下载应用、加载渲染引擎、启动客户端。
- 在浏览器能够获得资源总大小时，显示已下载大小、总大小和预计进度。
- 无法准确获得总大小时，显示真实加载阶段，不使用虚假的百分比。
- 提供加载失败、超时、重试和离线提示。
- 记录关键性能指标：首屏时间、应用可交互时间、JS/WASM/字体/图片下载量和缓存命中率。
- 优化 Service Worker 缓存策略，升级时只更新发生变化的资源。

已确认的性能目标：

- 普通网络环境下，首次访问达到可交互状态不超过 8 秒。
- 静态资源缓存有效时，二次访问达到可交互状态不超过 2 秒。
- 首次和二次访问都必须有明确加载反馈。
- 监控数据能够显示主要资源体积、加载耗时和缓存命中情况。

性能验收需要固定测试设备、浏览器、网络带宽与缓存状态，避免不同环境的数据无法比较。

### 2. 媒体存储与传输优化

目标：降低表情包、图片和文件对 IM 服务器磁盘与带宽的消耗，同时允许用户选择自己的媒体托管方式。

#### 模式 A：服务端托管

适用于未配置图床、需要稳定存储或对访问权限要求较高的场景。

1. 上传前计算内容 Hash，服务端按 Hash 去重，相同文件复用同一媒体对象。
2. 图片上传时生成合适尺寸的预览图，并按策略压缩或转换格式。
3. 原图、缩略图和元数据分开管理，聊天列表优先加载缩略图。
4. 抽象媒体存储接口，支持本地磁盘和 S3 兼容对象存储。
5. 需要加速时在对象存储前接 CDN，业务代码不绑定具体供应商。

Hash 去重必须结合访问权限，不能因为文件相同而让无权限用户访问其他会话中的媒体。

当前进度（M2）：

- 新上传媒体使用“上传者 + 内容”Hash 作为媒体 ID；同一用户内去重，不跨用户复用媒体对象。
- 保持旧版 32 位媒体 ID 可访问，新版 Hash ID 使用 64 位格式。
- 并发上传相同内容时只创建一份文件和元数据。
- 服务端托管图片生成最长边 640px 的 JPEG 缩略图，原图与缩略图分离保存并通过独立 URL 访问；历史媒体无缩略图时仍可按原图访问。
- 媒体元数据记录原图尺寸，SQLite/PostgreSQL 启动时自动补齐缩略图 URL、宽高字段；聊天消息预览优先使用缩略图，打开附件仍使用原图。
- 新增对象存储适配层，依赖 `store.ObjectStorage` 接口即可接入 S3、MinIO、R2 等兼容服务，原图和缩略图使用独立对象键。

#### 模式 B：客户端自定义图床

普通客户端可以配置自己的图床服务。发送图片时由客户端直接上传到图床，ZZZ IM 服务端只接收并保存最终图片 URL，不保存图片二进制。

消息建议保存以下信息：

- 图片 HTTPS URL。
- 可选的缩略图 URL。
- 图片宽度、高度、格式、文件大小和内容 Hash。
- 图床来源类型仅保存在发送端配置中，不把访问密钥写入消息。

客户端行为：

- 接收端按普通网络图片预览，不要求了解发送方使用了哪种图床。
- 图床 Endpoint、Token、Secret 等配置只保存在客户端安全存储中。
- 上传失败时允许重试，或者临时切换到服务端托管。
- 可以在客户端保存 `Hash -> 远程 URL` 映射，避免向同一图床重复上传。

当前进度（M2 第一批）：

- 设置页支持通用 multipart 图床配置：上传 Endpoint、文件字段、鉴权 Header、鉴权 Scheme、Token 和返回 URL 的 JSON 路径。
- 非敏感配置保存在本地偏好中，Token 单独保存在客户端安全存储中。
- 仅图片使用自定义图床；语音、视频和普通文件仍由 ZZZ IM 服务端托管。
- 图床关闭时默认使用服务端托管；图床上传失败时明确报错，不自动二次上传到服务端。
- 客户端和服务端均校验外部图片必须使用 HTTPS，消息服务不下载或保存外部图片内容。

安全与可用性边界：

- 默认只接受 HTTPS 图片 URL，并设置加载超时、最大响应体和最大解码尺寸。
- 外部图片可能暴露接收者 IP、失效、限速或被替换，客户端需要显示加载失败占位和重试入口。
- 服务端不持有外部图片，因此无法保证历史图片永久可用，也无法完成服务端压缩和权限隔离。
- 图床 URL 仍需经过消息内容安全校验，避免危险协议、本地地址和异常重定向。
- PWA 直传要求图床允许来自客户端站点的 CORS 请求，否则浏览器会阻止上传。

### 3. 版本更新说明

- 客户端检测到新版本后，首次打开显示本次更新内容。
- 弹窗支持“本版本不再提示”。
- 设置页保留“更新记录”入口，用户可以再次查看。
- 更新记录由版本号管理，不能只依赖本地一次性状态。

当前进度（M3）：

- 客户端更新至 `1.1.0`，新版本首次进入会话页时显示本次更新内容。
- 用户可以选择稍后查看或对当前版本不再提示；设置页保留完整更新历史入口。
- 更新内容按版本号维护，并通过测试约束当前记录与 `pubspec.yaml` 版本一致。

## 三、第二阶段：基础通信能力（P1）

### 1. 语音消息

- 支持录音、取消、试听、发送和播放。
- 显示时长、上传状态和播放进度。
- 明确单条语音的时长及文件大小限制。
- Web、桌面端分别处理麦克风权限和后台中断。

### 2. 内置表情组

- 客户端预置常用表情组，随应用静态资源发布。
- 发送时记录表情资源 ID，不为每次发送重复上传图片。
- 资源版本变化时保持旧消息仍可正确显示。

当前进度（M3）：

- 首批内置 `zzz-core` 表情组复用客户端静态资源，不产生媒体上传和服务端文件副本。
- 消息仅保存 `pack_id`、`asset_id` 和 `version`；旧版资源映射保留后仍可渲染历史消息。
- ZZZ 服务端校验表情标识格式并生成通知摘要；不支持该扩展段的外部平台适配器降级为文本提示。

### 3. 转发与链接分享

- 支持单条消息转发、合并转发和分享普通链接。
- 链接消息显示标题、域名和可选预览信息。
- 服务端抓取链接预览时必须防范内网地址访问和恶意重定向。

### 4. 定位消息

- 支持发送当前位置或手动选择地点。
- 消息包含经纬度、地点名称和可选地图缩略图。
- 发送前明确请求定位权限，允许用户只发送地点名称而不发送精确坐标。

### 5. 戳一戳

- 作为轻量会话事件，不当作普通文本消息处理。
- 支持频率限制，避免连续触发造成骚扰。
- 是否产生推送通知由会话通知设置控制。

当前进度（M4）：

- 客户端支持录音、取消、停止、试听、重新录制、发送及播放；单条限制为 2 分钟、10 MB，进入后台时自动停止录音。
- 链接以结构化消息发送，第一版只显示 URL、发送方提供的标题和域名，服务端不抓取网页预览。
- 定位支持当前位置、手动地点名及可选坐标；只发送地点名时不暴露精确坐标，有坐标时使用 OpenStreetMap 打开。
- 支持单条转发和最多 100 条合并转发；服务端保存不可变消息快照并校验会话访问权限。
- 戳一戳作为结构化会话事件保存，按“发送者 + 会话”执行 5 秒限流，并遵循会话静音设置。

### 6. 会话来源标识简化

- 联系人和会话列表不再直接显示完整的 `ZZZ Server` 文本。
- 使用小型平台图标或简短来源标识，并提供悬停或详情说明。
- QQ、NoneBot 及未来其他平台采用同一套展示规则。

当前进度（M3）：

- 会话、联系人和群组列表已统一为紧凑平台图标，不再占用一行显示完整来源名称。
- 图标的 Tooltip 与无障碍语义仍保留完整来源名称，未知平台使用通用来源图标。

## 四、第三阶段：权限、群组与个人表达（P1-P2）

### 1. 管理员与群组权限

建议建立明确的角色模型：

- 系统管理员：管理账号、全局内容和系统配置。
- 群主：管理群组、成员、管理员和群公告。
- 群管理员：按授权执行成员管理、公告和消息管理。
- 普通成员：参与会话和使用普通群功能。

权限必须由服务端校验，不能只在客户端隐藏按钮。

当前进度（M5）：

- 群主、管理员和普通成员角色已落地，成员管理、禁言、公告、转让和解散操作均由服务端校验。
- 系统管理员继续使用独立管理端令牌，与普通 IM 用户和群角色分离。

### 2. 群公告

- 群主或有权限的管理员可以发布、编辑和撤回公告。
- 公告作为独立结构保存，同时在群内生成系统消息。
- 支持置顶、已读状态和历史公告列表。

当前进度（M5）：

- 公告使用独立记录和已读状态表保存，支持发布、编辑、删除、置顶、历史列表和旧公告迁移。
- 发布公告时会生成群系统消息；群主和管理员可管理公告，普通成员仅可查看和标记已读。

### 3. 屏蔽与通知策略

每个私聊或群组建议提供三个档位：

1. 正常通知：普通消息和 `@` 消息均通知。
2. 仅 `@` 通知：普通消息静默，仅 `@我` 或指定重要事件通知。
3. 完全屏蔽：所有消息和 `@` 均不通知，但消息仍正常同步并保留未读状态。

好友请求属于会话外系统事件，不受会话通知档位影响；隐藏会话作为独立能力处理，不与通知策略绑定。

当前进度（M5）：

- 会话偏好已升级为 `normal`、`mentions_only`、`muted` 三档，并兼容旧客户端的 `is_muted` 字段。
- `mentions_only` 只推送 `@我`、`@全体` 和群公告；`muted` 不推送该会话的任何消息或公告。
- 三个档位均正常同步消息和累计未读数，好友请求通知不受会话设置影响。

### 4. 用户称号

- 支持系统或群组范围内的称号。
- 支持金、红、黄等预设颜色，以及有限的动态渐变样式。
- 动态效果需要提供“减少动画”选项，并限制样式数量以保证可读性和性能。
- 明确称号的授予者、有效期和展示场景。

当前进度（M6，已随 1.4.0 上线）：

- 支持系统和群组两种作用域，记录授予者、有效期、创建时间，并由存储层限制每名用户所有作用域合计最多 5 个生效称号。
- 提供金、红、黄、极光和余烬五种固定样式；群主和管理员可在群成员名片中授予或撤销群称号，系统称号由独立管理端管理。
- 群称号只在对应群上下文展示；动态样式遵循系统“减少动画”和客户端背景动画设置。

### 5. 个人名片

参考 Telegram 和 Discord，但保持 ZZZ IM 自己的视觉语言：

- 头像、昵称、账号、简介、称号和共同群组。
- 可设置名片背景图或主题背景。
- 提供添加好友、发消息、屏蔽和举报入口。
- 背景图在客户端压缩，并遵守敏感内容标记与隐私设置。

当前进度（M6，已随 1.4.0 上线）：

- 联系人和群成员均先打开响应式个人名片，展示头像、昵称、账号、简介、当前上下文称号和共同群组。
- 名片提供发消息、添加好友、屏蔽/取消屏蔽和举报；屏蔽会解除好友关系，并由服务端阻止后续好友请求和私聊消息。
- 用户可控制是否向他人展示共同群组，并可把背景标记为敏感内容；敏感背景默认遮挡，需主动点击后显示。
- 背景支持直接填写 HTTPS 图片地址、任意 `#RRGGBB` 纯色，或选择本地图片后由客户端压缩为最长 `1600×900`、质量 82 的 JPEG。
- 选择本地背景时，已启用客户端图床则直传图床，未启用时默认上传到 ZZZ IM 服务端；接收端统一按普通网络图片预览。
- 个人资料加载和背景上传不会初始化敏感内容检测器，也不会触发下载 ONNX 模型；检测器仍只在用户开启检测功能并实际需要检测时按需加载。

## 五、第四阶段：AI 与实时房间（P2-P3）

### 1. Fairy AI 好友

目标：提供名为 `Fairy` 的预设 AI 好友，既可私聊，也可作为成员加入群组。

建议架构：

- Fairy 作为独立 Bot 服务运行，并以普通 Bot 账号接入 ZZZ IM。
- IM 服务端只负责投递消息、权限和会话，不直接承载 AI 推理逻辑。
- Bot 服务提供插件系统、上下文管理、群聊触发规则、限流和管理开关。
- 群内默认仅在被提及或满足明确触发条件时回复，避免干扰正常聊天。

参考项目：

- [MaiBot](https://github.com/Mai-with-u/MaiBot)：参考 Bot 服务、人格和群聊交互设计。
- [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)：参考会话事件、作用域、核心服务和 Tool Runtime 设计。
- [ZZZeroUID](https://github.com/ZZZure/ZZZeroUID)：作为 Fairy 插件参考，通过 UID 查询绝区零相关信息。

需要提前明确：AI 模型来源、费用预算、上下文保存周期、隐私策略、群管理权限和内容安全策略。

当前进度（M7 第一阶段，已上线）：

- Fairy 已实现为独立 Go 进程，通过普通账号注册、认证和自动重连接入 ZZZ Server；IM 服务端不持有模型密钥，也不运行推理。
- 自动接受好友请求，支持私聊和群成员场景；群聊只在 `@Fairy`、`/fairy` 或 `/zzz` 指令触发，普通群消息不会进入上下文。
- 群主和管理员可按群开启或关闭回复；开关、每日调用计数由 Fairy 独立持久化，会话内容不写入状态文件。
- 对话上下文第一阶段默认只保存在内存中，30 分钟过期、每会话最多 12 条；AI 每日默认上限 200 次，均可由部署环境调整。
- AI 对话使用可选的 OpenAI-compatible 配置，不绑定模型供应商；未配置模型时，帮助、群管理和 ZZZ 插件仍可工作。
- 首个 ZZZ 插件支持 `/zzz <UID>` 查询 Enka.Network 中的游戏公开展示资料，遵循上游 TTL 缓存，不接收米游社 Cookie。
- 已提供独立 systemd 单元、部署脚本和只在成功登录 IM 后返回 `200` 的本地健康检查。
- `icrad.ltd` 已运行 Fairy 普通账号和独立服务；生产模型变量暂时保持为空，在确定供应商、预算和内容安全策略前不会产生 AI 调用费用。

当前进度（M7 第二阶段，已随 1.5.0 上线）：

- ZZZ Server 客户端默认把 `fairy` 作为预设 Bot 账号，也可通过连接配置的 `extra.presetBotIds` 调整或关闭。
- 仅当对应账号实际存在且尚未成为好友时，联系人页才显示 Fairy 推荐项；其他部署无该账号时不显示，成为好友后也不会重复出现。
- 推荐项支持打开个人名片或直接发送好友请求；Bot 身份在推荐项、普通联系人和个人名片中保持一致标识。
- 多来源组合仓库会为推荐账号添加来源命名空间，查询资料和发送好友请求都路由到账号所属来源。

当前进度（M7 第三阶段，Fairy 服务已上线）：

- `/fairy privacy` 说明消息触发范围、内存上下文的条数与过期时间，以及状态文件不保存消息正文的边界。
- `/fairy memory on|off` 支持按会话控制临时记忆；私聊用户可自行设置，群聊仅群主和管理员可改，关闭后立即清空已有上下文且不影响指令插件。
- `/fairy quota` 和 `/fairy status` 展示当日模型调用次数与剩余额度；查询本身不会占用额度。
- 外部模型调用前会拦截高置信的私钥、Bearer、密码、API Key、Token 和 Cookie。被拦截内容不写入上下文、不扣减额度，也不会发送给模型供应商。
- 生产环境仍未配置 AI 模型，Fairy 继续以无模型费用的指令和 ZZZ 插件模式运行。

当前进度（M7 第四阶段，Fairy 管理与插件注册表）：

- IM 管理后台增加独立 Fairy 配置页，覆盖 OpenAI-compatible 模型、系统提示词、上下文、限流、额度和并发设置。
- Fairy 通过回环地址上的令牌认证管理 API 自行校验和持久化配置；IM 服务只透明转发，不解析或存储模型密钥，不执行 Bot 或插件逻辑。
- API Key 为只写字段，管理 API 仅返回是否已配置；配置文件使用原子替换和 `0600` 权限，失败不会改变当前配置。
- 已建立内置插件注册表，管理页可启停已注册的 `zzz-profile` 插件并配置其公开资料上游；暂不允许从网页上传或执行任意插件代码。
- 保存配置后 Fairy 自动重启应用完整配置，核心 IM 服务保持在线。

当前进度（M7 Agent 化 F0，已本地实现、待发布）：

- 确定版架构见 [FAIRY_AGENT_ARCHITECTURE.md](FAIRY_AGENT_ARCHITECTURE.md)。DSH 与 MaiBot 已足够覆盖 Agent 内核和聊天行为；IM 投递、安全、观测和评测分别由 ZZZ / OneBot、OWASP Agentic AI、OpenTelemetry GenAI 和 Fairy 自有 eval corpus 补齐。
- 已用有界 Conversation Scheduler 替换直接并发 worker，实现 per-conversation FIFO、单活跃 Turn、跨会话并发上限和明确的队列溢出错误；已接纳消息不会因 worker 满载被静默跳过。
- ZZZ 消息 ID 和好友请求 flag 使用 Fairy 本地 SQLite 持久化去重；`/fairy stop` 可抢占当前 Turn，信号退出和管理配置重启均先停止 admission，再 drain 或取消。
- Turn Trace 只保存事件类型、随机 Trace / Turn ID、队列计数、固定状态和 HMAC 会话引用；不持久化消息正文、昵称、账号 ID、模型密钥或 Cookie。
- FIFO、跨会话并发、队列边界、重启去重、stop、shutdown 和取消后不发送错误回复已有 Go 测试；当前只完成本地代码与测试，尚未部署到 `icrad.ltd`。
- 后续按 Model Router、Tool Pipeline、Planner / Replyer、行为门控、可选记忆和外部 Tool Provider 的顺序推进，不在 Go 中重写完整 Cordis。
- 默认继续不持久化聊天正文；生产 AI 仍需先确认模型供应商、预算、内容安全和评测门槛。

当前进度（M7 Agent 化 F1，核心实现已完成、待发布）：

- Fairy 已支持 Provider / Model / Task 结构化配置；版本 1 的单模型配置会自动迁移，管理 API 保留旧字段投影以兼容旧客户端。
- Model Router 已实现 OpenAI-compatible 与 Anthropic-compatible 调用、不可变配置快照、有限重试、可取消退避和按顺序 fallback；鉴权、无效参数、内容拒绝不会重试或切换模型。
- 每次模型尝试只记录脱敏的 Task、Provider、Model、snapshot、耗时、Token、成本和失败分类；Trace 不包含 Prompt、密钥或会话明文。
- Fairy 管理页已支持多个 Provider、Model、Task 的增删改、候选模型 fallback 顺序调整和密钥只写；配置请求/响应上限已提升到 `256 KiB`。
- 当前仍只完成本地代码、专项测试和浏览器预览，尚未生成或部署生产制品；生产模型变量继续保持为空。

当前进度（M7 Agent 化 F2，已本地实现、待发布）：

- 已实现 `ToolSpec`、不可变 Registry、严格 object Schema、Agent Scope、allowlist、风险与副作用策略、单 Turn 调用上限、可取消 timeout、输出校验/大小限制和脱敏投影。
- 首版 Tool Session 强制串行执行；`exclusive` 工具跨会话互斥且等待锁时仍响应取消和超时。副作用工具必须声明幂等类型，默认策略只允许低风险只读工具。
- `zzz-profile` 已迁移为低风险只读工具，同时保留 `/zzz <UID>`；包含唯一合法 UID 和明确 ZZZ 关键词的自然语言请求可确定性调用，无关键词、多个 UID 和普通聊天不会误触发。
- Tool Trace 仅记录 Call ID、工具名、风险、策略结论、Step、耗时、结果状态/字节数和固定失败分类；不保存 UID、完整参数、上游响应或聊天正文。
- 通用 `send_message.client_message_id` 已在 Memory、SQLite、Postgres 和 Gateway 实现。相同发送者/键/请求返回原消息且不重复广播推送，请求不一致时拒绝；SQLite 重启去重已有测试，Fairy 出站默认生成客户端消息 ID。
- F2 单元、Gateway WebSocket 集成、SQLite/Postgres 重启和脱敏 Trace 测试已通过；CI 的 Go job 已加入临时 Postgres 服务。尚未生成或部署生产制品。结构化 Planner、模型原生 Tool Call 和多 Step Agent Loop 属于 F3，当前自然语言工具选择仅限高置信确定性规则。

当前进度（M7 Agent 化 F3，已本地实现、待发布）：

- OpenAI-compatible Adapter 已支持原生 Function Tool Call、严格请求/响应边界、Planner JSON 响应模式、`finish_reason` 内容拒绝/截断处理，以及结构错误时的受控 fallback；Anthropic-compatible Adapter 已支持 Messages、`tool_use / tool_result` 和对应停止原因。
- 已实现 `call_tools`、`respond`、`wait`、`stop` 四类 Planner Decision；文本 Decision 必须是无 Markdown 包装、无未知字段、无尾随值的严格 JSON，工具参数只能来自原生 Tool Call 或严格 JSON object。
- Agent Loop 最多 4 个 Planner Step，并复用 F2 Tool Session 的 6 次调用上限、可见性、授权、风险、副作用、timeout 和串行策略。Planner 对隐藏或不存在工具的请求只会得到固定失败码，无法直接执行能力。
- 普通闲聊保持一次 `replyer` 调用；已配置 `planner` 时，工具意图和 `/fairy agent <请求>` 才进入 Agent mode。管理面板按 `replyer -> planner -> utility` 创建默认 Task，并分别显示 AI / Planner 状态。
- Prompt 已拆为稳定 ID 的 `identity`、`persona`、`platform`、`safety`、`task`、`tools`、`runtime_context` sections；Model Trace 使用部署 `trace.key` 记录 section 版本和 HMAC，不保存 Prompt 正文。内存 Context Surface 带来源消息元数据、按会话隔离且只在成功回复后提交。
- Replyer 不允许提交 Tool Call；最终文本统一执行空值、长度、疑似凭据、危险协议、私网/本机链接和双向文字控制符检查。每 Turn 的可见最终回复最多一次，取消后不发送错误回复。
- 模型额度改为按实际 Planner / Replyer 逻辑调用逐次扣减；Provider 内部 Retry 不重复扣减。Fake Model golden trace、越权工具、Step 上限、会话隔离、取消、输出安全、额度中断和原生 Tool Call 协议测试已通过。尚未生成或部署生产制品，生产模型仍未配置。

当前进度（M7 Agent 化 F4，已本地实现、待发布）：

- 模型前 Gate 返回固定 `trigger / wait / ignore / reject` 和受限 reason；私聊、明确 `@Fairy` 与指令为硬触发，普通群消息默认 `shadow`，不排队、不调用模型、不保存正文、不发送回复。
- 群主和管理员可用 `/fairy proactive off|shadow|on` 按群控制软触发。`on` 只允许明确触发后同一用户在 Focus TTL 内继续对话，并受 cooldown 约束；硬触发不受这些软抑制影响。
- 新增 `brief / normal / detailed` 表达档位；每个 Turn 固定使用开始时的行为快照。群聊软触发默认值、Focus、cooldown 和表达档位可热更新，模型、密钥、插件、Prompt 和调度配置仍受控重启。
- 内存 Context 溢出不再直接丢弃，而是压缩为带不可信标记的 `user` 摘要，保留来源起止 ID 和数量；摘要和聊天正文均不写入状态文件或 Trace。
- Fairy 管理页新增 Scheduler、Tool Policy、当日模型额度，以及近 24 小时 Model / Tool / Gate / Token / cost 聚合；管理响应不包含聊天正文、Prompt 正文、用户 ID 或会话 ID。
- 受管配置升级为 v3 并兼容读取 v1/v2；Gate、状态保留、上下文压缩、Trace 聚合和行为热更新专项测试已加入。当前仍未提交、推送、构建发布制品或部署，生产模型继续未配置。

当前进度（M7 Agent 化 F5.1，来源化事实记忆已本地实现、待发布）：

- 新增权限 `0600` 的独立 `facts.db`；事实记忆默认关闭，只接受 `/fairy remember` 显式写入，不进行模型自动抽取。单条、单 scope 数量/字符、TTL 和疑似凭据均有固定限制。
- 私聊事实按“用户 + 会话”隔离，群事实按群隔离；群内开启、关闭、写入和删除仅群主或管理员可执行，群成员可查看本群事实。`/fairy facts list [页码]` 展示事实 ID、正文、来源消息和日期，`/fairy forget <id|all>` 执行真实删除。
- 关闭事实记忆只停止召回、不隐式删除；事实以 `user` 角色的明确不可信 JSON 区段注入 Planner / Replyer，不能提升为 system 指令，也不进入 Prompt Trace。读取失败时本次 AI 调用 fail closed。
- 管理运行态只暴露事实总数、已有 scope 数和已开启 scope 数，不返回事实正文、用户或会话标识。SQLite 重启、TTL、容量、凭据拦截、跨用户/跨群隔离、群权限、删除、Prompt 注入和并发测试已加入。
- 语音和图片 Task 已在 F5.3 完成核心本地实现；行为经验只读召回已在 F5.5 完成，显式质量反馈聚合已在 F5.8 完成，自动反馈学习继续关闭。当前未提交、推送或部署。

当前进度（M7 Agent 化 F5.2，可信独立进程 / MCP Tool Provider 已本地实现、待发布）：

- 使用官方 Go MCP SDK 接入 stdio Provider；命令必须是绝对路径，参数不经过 shell，子进程只继承管理员列出的环境变量名称。管理配置升级为 v4 并兼容读取 v1-v3，API 不保存或返回环境变量值，疑似凭据参数直接拒绝。
- Provider 与远端工具使用双层 allowlist。只有明确 `readOnlyHint=true`、未声明 destructive、名称合法且输入 Schema 属于 Fairy 支持子集的工具才以 `provider-id.tool-name` 注册；未授权、可写或 Schema 不兼容的能力不会进入 Planner definitions。
- 外部工具复用现有 Tool Pipeline 的可见性、低风险只读策略、输入/输出 Schema、调用次数、timeout、大小、敏感投影和脱敏 Trace。MCP 结果先正规化为固定不可信 JSON；非文本内容、危险资源链接、空结果和超大结果均拒绝。
- Provider 启动失败不阻止 Fairy 主进程；调用 timeout 或协议错误会关闭会话、终止子进程并打开熔断器，冷却后按需重连。stderr 直接丢弃，关闭时显式回收会话，systemd control-group 和 TasksMax 作为异常退出兜底。
- Fairy 管理页新增外部 Provider 编辑器和固定运行态表格，只展示状态、工具数、连续失败数和熔断截止时间。配置外部工具后普通自然语言请求进入 Planner；生产启用前必须把增加的模型调用纳入预算。
- 已加入真实 stdio 子进程的握手、分页发现、allowlist、只读/破坏性声明、Schema 拒绝、启动失败、timeout、熔断恢复、超大输出、stderr 背压、危险链接和进程退出测试。生产尚未安装或启用任何外部 Provider。
- 当前工作树已完成 Linux amd64 静态 Server、VAPID 和 Fairy 构建，并在 Alpine amd64 中验证 SQLite、Fairy 实际注册登录、受管配置 API 以及真实 MCP stdio 发现/调用/熔断恢复。发布脚本已把这些检查固化为后续每次候选构建的强制 smoke；本阶段仍未提交、推送或部署。

当前进度（M7 Agent 化 F5.3，图片理解与语音转写核心已本地实现、待发布）：

- 已建立只识别消息段类型的 `Media Input` 前置边界。私聊图片/语音和群内明确 `@Fairy` 的媒体消息可以进入 Gate；普通群媒体不会越过现有触发策略。
- `vision` 可通过 OpenAI-compatible Chat Completions 或 Anthropic-compatible Messages 接收校验后的内联图片；`transcriber` 只允许 OpenAI-compatible `/audio/transcriptions` multipart 转写语音。两者复用 Provider 的 timeout、有限 Retry、顺序 fallback 和脱敏 Model Trace。
- 单次最多 4 张图片或 1 条语音，禁止图音混发；图片单张最多 8 MB、合计最多 20 MB、最长边 8192 像素且总像素不超过 4000 万，语音最多 10 MB / 2 分钟。当前支持 JPEG、PNG、GIF、WebP，以及 WebM、Ogg、MP3、M4A、WAV。
- 服务端托管媒体只允许从已配置 ZZZ Server 的 `/files/` 读取；外部只允许 HTTPS 图片，外部语音拒绝。DNS 解析、实际拨号和每次重定向都阻断私网、回环、链路本地等地址，并限制响应头、正文、类型、签名和图片解码尺寸。
- 未配置对应 Task 时保持零下载、零模型调用。事实记忆读取在媒体下载前 fail closed；图片或转写结果被包装为明确的不可信 `user` 数据，只进入 `replyer`，即使存在外部 MCP 也不会进入 Planner 或触发 Tool。
- 全局日额度继续作为总闸门，`replyer`、`planner`、`vision`、`transcriber` 等 Task 另有独立 UTC 日额度；两层计数原子持久化。管理页可分别配置并查看各 Task 已用/剩余额度，旧 v1-v4 配置自动继承全局上限。
- 图片 URL、原始字节、转写/描述正文均不写入 Trace；模型 Trace 只保留固定 Task、Provider、Model、耗时、Token、费用和失败分类。视频、普通文件和批量 OCR 仍不处理。
- 管理页已验证 Provider / Model / Task 保存后受控重启与重新载入，Task 独立额度能在 Live runtime 正确显示。Fairy、Store、Gateway 竞态测试通过；当前工作树已生成 Linux amd64 静态 Server、VAPID、Fairy 和测试制品，并在 Alpine amd64 中通过完整 Fairy 测试、SQLite 注册登录、管理 API、VAPID、权限和优雅退出 smoke。systemd 单元也已通过 `systemd-analyze verify`；发布脚本现将完整 Fairy 测试纳入 Alpine 门禁。
- 行为经验只读召回已在 F5.5 落地；自动反馈学习继续延后。当前聊天协议没有稳定的正负反馈事件和成功指标，在建立显式反馈、删除机制和离线 eval 前不允许模型自动生成或持久化行为经验。
- F5.3 当前仍未提交、推送或部署，生产模型与媒体模型均未配置。

当前进度（M7 Agent 化 F5.4，运行契约与确定性评测已本地实现、待发布）：

- Fairy 探针按架构拆分：`/health` 只表示进程 HTTP 服务存活，`/ready` 要求已登录 IM 且 Scheduler 仍接纳新 Turn；连接中和 draining 的 `/ready` 返回 `503`。部署脚本与 Linux smoke 已改为只用 `/ready` 判断可切流。
- 新增版本化 `testdata/eval/v1.json`，F5.5 扩展后当前 74 条严格 JSON 样例覆盖中英文 Gate、Prompt Injection 输入边界、凭据检测、危险输出链接、ZZZ 工具意图、Planner Decision、媒体批次和行为经验召回。重复 ID、未知字段和尾随 JSON 都会阻断测试。
- 凭据防护新增中文密码、口令、密钥和令牌标签，并识别 OpenAI、GitHub、Slack、AWS 常见高置信 Token 前缀；普通密码咨询、策略说明和短 Token 不误拦截。
- 自动行为学习继续保持关闭。真实模型的人格、拒答、质量、Token、费用和延迟评测仍需等待生产候选供应商与预算确认，并只在专用测试账号离线执行。
- F5.4 当前未提交、推送或部署。

当前进度（M7 Agent 化 F5.5，只读行为经验与 MiMo 候选接入已本地实现、待发布）：

- 管理员可配置最多 64 条 `场景 -> 建议动作 -> 观察结果`，每条限定作用域并包含最多 12 个关键词。Fairy 只按本次用户原始文本确定性召回最多 3 条；排序依次采用关键词命中数、最长关键词和稳定 ID。
- 经验以 advisory JSON 注入 Planner / Replyer，不包含召回关键词或 scope，不写入 Trace；图片描述和语音转写不参与匹配。模型与聊天没有经验写入接口，自动反馈学习固定关闭。
- 受管配置升级为 v6 并兼容 v1-v5。管理页支持经验增删、启停、作用域和内容编辑；运行态只显示配置数、启用数与自动学习关闭。经验修改需要 Fairy 受控重启，不混入行为热更新。
- Model Router 新增 Anthropic-compatible Messages Adapter，覆盖 system/messages、图片、原生 Tool Call、`tool_result`、Token 与停止原因。MiMo 返回的 thinking 块被丢弃；语音转写在配置阶段禁止绑定 Anthropic Provider。
- 已从本地 CC Switch 读取非敏感 MiMo 元数据，并用进程环境变量完成 `mimo-v2.5-pro` 隔离 Eval。5 次调用覆盖中英文、Fairy 身份、Prompt Injection 和原生 Tool Call，总计 1247 input / 386 output tokens，P50 约 5.2 秒、P95 约 13.4 秒；套餐单价未知，因此不估算费用。
- 发布脚本新增 `validate`，只验证当前工作树且不发布产物。F5.5 当前工作树已通过 Go test/vet、静态 Linux amd64 交叉编译，以及 Alpine 中 IM + SQLite + Fairy 就绪、管理 API、文件权限、MCP 测试和优雅退出的完整 lifecycle smoke；`build/deploy` 仍只从已提交 HEAD 构建。
- 当前未提交、推送或部署，生产 Fairy 仍未启用外部模型；M8 继续暂停。

当前进度（M7 Agent 化 F5.6，可靠出站投递已本地实现、待发布）：

- Engine 回复改由 Runner 生命周期内的可靠投递器发送。确认超时、响应异常或 WebSocket 在确认前断开时，同一逻辑回复可在当前连接或下一条已认证连接上继续尝试，总尝试次数最多 3 次。
- 每次重试都复用最初生成的 `client_message_id`，与服务端已实现的“发送者 + 客户端消息 ID + 内容指纹”持久化去重闭环配合，不会二次广播或推送。服务器明确返回 API 错误时不重试。
- 回复正文只保留在当前 Turn 内存，不新增持久 outbox，进程重启后不自动重放。管理运行态只公开成功、重试、失败和结果未知累计数，不返回消息、会话、账号或幂等键。
- 专项测试覆盖同连接确认超时、断线后换连接、旧连接解绑竞态、明确拒绝不重试和连接前取消；当前未提交、推送或部署。

当前进度（M7 Agent 化 F5.7，安全模型探测已本地实现、待发布）：

- Fairy 本机管理 API 和 IM 管理代理新增单模型探测端点；只接受严格的 `{model_id}`，请求上限 1 KiB，要求管理鉴权，全进程最多同时探测一个模型。
- 探测只读取已保存配置并固定使用无用户数据 Prompt、256 输出 Token 上限、单次供应商请求和 30 秒硬超时；不读取聊天、事实记忆、行为经验或工具数据，不占聊天日额度，也不写 Turn Trace。
- 管理页每个 Model 增加 `Test`、Ready / 固定失败状态、延迟、Token 和估算费用。模型或 Provider 有未保存修改时要求先保存，避免误测旧配置；回复正文、供应商错误正文和密钥均不返回或展示。
- OpenAI-compatible 与 Anthropic-compatible 请求契约、鉴权、401 / 429 / 5xx 分类、非法/超大请求、未授权、单并发和不泄密测试已通过。MiMo `mimo-v2.5-pro` 复测发现 64 Token 可能全部用于 `thinking` 并得到 `invalid_response`；上限调整为 256 Token 后，Fairy 自身真实探测约 2.7 秒完成，使用 25 input / 48 output tokens。
- 管理页已在 1440×1000 和 390×844 实际浏览器中验证，无横向溢出、控件重叠或控制台错误。当前未提交、推送或部署，生产 Fairy 仍未启用外部模型；M8 继续暂停。

当前进度（M7 Agent 化 F5.8，显式质量反馈闭环已本地实现、待发布）：

- 只有成功发送并取得服务端 `message_id` 的模型最终回复登记为可评价输出；命令、插件直出、错误和限流回复不登记。`👍`（`76`）映射为 positive，`👎`（`fairy-negative`）映射为 negative，其他 Reaction 和 Fairy 自己的 Reaction 忽略。
- 同一输出与评价者采用 upsert：改评覆盖，取消只删除当前匹配标签，旧标签的迟到取消不会删除新标签。Fairy 输出被 Recall 后删除资格映射并级联删除全部评价。
- SQLite 只保存输出消息与评价者的 HMAC 引用、随机 Turn ID、标签和时间，默认保留 30 天；不保存原始消息/用户/会话 ID、回复正文或会话正文。管理运行态只返回最近 24 小时已评价回复数、赞、踩和正向率聚合。
- Gateway WebSocket 集成、重试/重连最终消息关联、SQLite 重启持久性、隐私字节扫描、Recall 级联、Runtime 聚合和 Flutter 稳定 Reaction ID 均有回归测试。管理页已在 1440×1000 与 390×844 实测，无横向溢出、统计项重叠或控制台错误。
- 显式反馈当前只提供人工质量观察，不写回行为经验、Prompt、模型路由或工具策略；自动行为学习继续关闭。当前未提交、推送或部署，生产 Fairy 仍未启用外部模型；M8 继续暂停。

当前进度（M7 Agent 化 F5.9，候选模型质量门禁已本地实现、待发布）：

- 新增独立 `fairy-eval` 命令和严格版本化的 5 Case 质量语料，覆盖中文简洁回复、英文隐私回复、Fairy 身份、Prompt Injection 隐藏标记保护和原生 Tool Call；支持 OpenAI-compatible 与 Anthropic-compatible。
- 门禁按真实 `time.Duration` 判定 P95，并限制总输入/输出 Token；配置单价和成本上限后可增加成本门槛。退出码固定为通过 `0`、配置或运行错误 `1`、门禁失败 `2`，可直接接入后续 CI 候选发布。
- API Key 只允许从 `FAIRY_EVAL_API_KEY` 进程环境读取。JSON 报告不包含 Prompt、模型正文、Base URL、API Key、供应商错误正文或真实用户数据，只输出固定 Case ID、固定失败码、尝试次数、延迟、Token 和可选费用。
- 已从本机 CC Switch 将 MiMo 凭据直接注入单次进程环境完成 `mimo-v2.5-pro` 实测，未回显或落盘密钥。5/5 Case 通过且均为单次调用，总计 1256 input / 403 output tokens，P50 约 3.3 秒、P95 约 6.9 秒；套餐单价未知，成本门禁保持关闭。
- 全量 Go test/vet/race、凭据扫描、差异检查和 Linux x86_64 `release-native.sh validate` 均通过。自动行为学习继续关闭；当前未提交、推送或部署，生产 Fairy 仍未启用外部模型；M8 继续暂停。

当前进度（M7 Agent 化 F5.10，管理面板质量评测已本地实现、待发布）：

- Fairy 本机管理 API 与 IM 管理代理新增质量评测 GET/POST；只能评测已保存的 Model，POST 异步启动固定 5 Case，GET 返回最近任务，任务使用配置快照并随 Fairy 进程生命周期取消。
- F5.7 连通性探测和质量评测共享单个诊断并发槽；冲突统一返回 `429` 与 `Retry-After: 1`。输入仍限制为严格 `{model_id}`、1 KiB、管理鉴权，不接受 Prompt 或运行参数。
- 管理投影只返回任务状态、Model 配置 ID、固定 Case 状态/失败码、P50/P95、汇总 Token 和可选费用；不返回 Provider、远端模型名、逐请求尝试/延迟/费用、Prompt、模型正文、Base URL、API Key 或供应商错误正文。
- 每个 Model 行新增 `Quality` 和脱敏结果；有未保存 Model/Provider 修改时禁用评测。页面通过单一计时器轮询，离开 Fairy 页面后停止；刷新页面可恢复 Fairy 进程内的最近任务。
- 已用本地 IM、Fairy 和假 OpenAI Provider 在 1280px 桌面与 390×844 移动视口验证 `idle -> running -> passed`、刷新恢复、按钮状态、无横向溢出及无控制台错误。Linux smoke 已覆盖 GET `idle` 与 POST `running` 契约。
- 全量 Go test/vet/race、凭据扫描、差异检查和最终 Linux x86_64 `release-native.sh validate` 均通过；为避免 Apple Silicon 上 x86 模拟导致已发送 Reaction 的反馈落库断言偶发超时，集成测试只将该异步持久化等待预算由 3 秒调整为 8 秒，统计断言保持不变。
- 自动行为学习继续关闭；当前未提交、推送或部署，生产 Fairy 仍未启用外部模型；M8 继续暂停。

当前进度（M7 Agent 化 F5.11，模型健康观测已本地实现、待发布）：

- 复用现有脱敏 `model_attempt` Trace，按最近 24 小时 `task_id + provider_id + model_id` 聚合 attempts/completed/failed、fallback、P50/P95、输入/输出 Token、费用和固定失败码；不新增数据库表，也不产生模型请求。
- 存量 Trace 的模型 ID、状态、失败码、耗时、Token 和费用必须通过固定字段校验；结果按 Task、Provider、Model 稳定排序，空状态固定为 `model_health: []`。
- 管理页 Live runtime 新增可横向滚动的 Model health 表，展示 Healthy / Degraded / Failing、成功率与聚合指标；不返回远端模型名、逐请求 Trace、Trace/Turn/Snapshot ID、会话身份、Prompt、正文、密钥或供应商错误。
- 已用本地 IM、Fairy 和合成 Trace 在 1280px 桌面与 390×844 移动视口验证数据态和空状态；页面无全局横向溢出，浏览器控制台无警告或错误。Linux smoke 已加入 `model_health: []` 契约断言。
- 已从本机 CC Switch 将 MiMo 凭据仅注入单次测试进程完成 `mimo-v2.5-pro` 复测：5/5 质量 Case 通过，1576 input / 430 output tokens，P50 约 6.4 秒、P95 约 8.8 秒；256 Token 探针约 7.3 秒并通过。凭据未回显或落盘，生产模型仍未配置。
- 全量 Go test/vet/race、凭据扫描、差异检查和 Linux x86-64 `release-native.sh validate` 已通过；静态制品仅用于本地 Alpine smoke，没有发布或上传。
- 自动行为学习继续关闭；当前未提交、推送或部署，M8 继续暂停。

当前进度（M7 Agent 化 F5.12，最近脱敏失败摘要已本地实现、待发布）：

- 复用现有脱敏 Trace，投影最近 24 小时最多 20 条失败摘要并按时间倒序展示，覆盖 Model failure、Tool failure、Admission rejection 和 Turn timeout；不新增数据库表，也不产生模型请求。
- 摘要只允许固定失败码、Task / Provider / Model / Tool 配置 ID、耗时、attempt / step / fallback 与有限队列数字。Trace / Turn / Snapshot / Tool Call ID、会话身份、消息正文、Prompt、工具参数和供应商错误均不返回；非法存量 Tool payload 会 fail closed。
- 管理页 Live runtime 新增独立横向滚动的 Recent failures 表；空状态固定为 `recent_failures: []`。已在 1280x900 桌面与 390x844 移动视口验证四类数据态和空状态，页面无全局横向溢出，失败码保持单行且表格不会挤压页面。
- 专项测试覆盖四类映射、时间排序、20 条上限、隐私字段扫描和非法 Tool 失败码；Linux smoke 已加入 `recent_failures: []` 契约断言。
- 全量 Go test/vet/race、JavaScript 语法、凭据扫描、差异检查和 Linux x86_64 `release-native.sh validate` 均已通过；验证制品只存在于临时目录，没有发布或上传。
- 自动行为学习继续关闭；当前未提交、推送或部署，生产 Fairy 仍未启用外部模型；M8 继续暂停。

当前进度（M7 Agent 化 F5.13，配置修订与生效状态已本地实现、待发布）：

- 受管配置升级为 v7 并兼容读取 v1-v6；每次成功保存生成单调递增 revision、UTC 更新时间和固定分类审计，非法 v7 revision 或审计元数据 fail closed。
- ConfigManager 分别维护期望配置与 active 配置。热更新成功后才推进 active revision；模型、Prompt、插件等需要重启的变更，在新进程实际加载前保持 `restart_pending`，避免把持久化成功误报为运行态生效。
- 管理 API 与 Fairy 页面展示 schema、期望/生效 revision、`active / applying / restart_pending` 状态及最近 50 条变更分类。审计只允许固定分类，不记录配置值、Prompt、URL、密钥或用户身份；移动端表格使用独立横向滚动。
- 已在本地验证 Environment baseline、热更新、重启 pending、重启后 active 和审计保留流程；1280x900 与 390x844 视口均无全局横向溢出。刷新管理数据后保存提示会按实际配置状态复位，不再残留旧的 `Restart scheduled`。
- 从本机 CC Switch 向单次测试进程注入 MiMo 凭据完成 `mimo-v2.5-pro` 复测，密钥未回显或落盘。256 Token 探针约 3.7 秒并通过；5/5 质量 Case 通过，总计 1576 input / 291 output tokens，P50 约 3.4 秒、P95 约 8.2 秒。该结果不代表生产已启用模型。
- 自动行为学习继续关闭；当前未提交、推送或部署，M8 继续暂停。

当前进度（M7 Agent 化 F5.14，候选模型启动配置完善，已发布）：

- 旧版单模型环境配置新增 `FAIRY_MODEL_PROTOCOL`，默认 `openai-compatible`，也可直接选择 `anthropic-compatible`；这样无需把 API Key 写入受管配置即可启动 Anthropic-compatible Provider（包括 MiMo）。
- 回归测试覆盖旧版配置迁移到 Anthropic Messages `/v1/messages`、`x-api-key` 和 `anthropic-version` 头，并确认 MiMo 的 `thinking` 块不会泄露到最终回复。
- 提交 `a787ce8` 已推送到 `origin/master`；GitHub Actions CI/CD 运行 `33680330700` 已通过，包含 Go、Flutter/PWA、Docker 和 Pages 发布。
- `release-native.sh deploy root@119.23.212.96` 已从该提交构建静态 Linux x86_64 制品，在 Alpine 完成 SQLite/Fairy lifecycle smoke，并通过远端校验和与回滚保护部署；生产 `zzz-im`、`zzz-fairy` 均为 active，Fairy `/ready` 和管理 API schema v7 已验收。
- 生产仍未启用 MiMo 或其他外部模型；候选模型只完成隔离评测，启用前仍需明确月度额度、内容安全策略和正式授权。M8 继续暂停。

当前进度（M7 Agent 化 F5.15，连接恢复退避完善，已部署）：

- Fairy 在拨号或认证持续失败时继续使用有上限的指数退避，避免服务器故障期间形成重连风暴。
- 一旦某次会话完成认证，后续断线会把重连等待恢复到最小值；旧故障累计的高退避不再延迟短暂网络中断后的恢复。
- 退避计算增加上限前溢出保护，并由单元测试覆盖首次、连续、封顶、下限、成功会话重置和最大时长边界；已有断线后可靠出站重试集成测试继续通过。
- 提交 `5778987` 已推送；GitHub Actions CI/CD 运行 `33682397809` 已通过，随后由 `release-native.sh` 从已提交版本构建静态 Linux x86_64 制品并部署到生产。
- 本地与远端 Server/Fairy 制品哈希一致，`zzz-im`、`zzz-fairy` 均为 active，Fairy `/ready` 返回 ready；生产日志确认已认证会话断开后按最小 `2s` 重连。模型仍未配置，外部工具为 0，自动学习保持关闭，M8 继续暂停。

当前进度（M7 Agent 化 F5.16，好友请求最终一致处理，已部署）：

- 修复好友请求在接受动作临时失败后仍被持久入站去重标记拦截、重连时无法再次处理的问题。
- 聊天消息继续按 Event ID 持久去重；好友请求改由 IM Server 的 pending 列表作为权威重试源，Fairy 仅在进程内合并同一 flag 的并发任务，不把失败任务永久标记为已完成。
- 每次认证后立即同步 pending 请求，在线期间每 30 秒执行补偿同步；失败任务释放进程内占位，后续同步可以重新提交，同时仍受 Scheduler 全局、单队列和 Turn timeout 限制。
- 集成测试使用真实 WebSocket 客户端模拟首次 `friend_request_handle` 临时失败，并验证无需断开连接即可自动重试成功；专项测试同时覆盖 retryable 控制任务和进程内并发去重。
- 提交 `9cfe7d7` 已推送，GitHub Actions CI/CD 运行 `33683640671` 已通过；本地静态 Linux x86_64 构建与 Alpine 全量 Fairy smoke 均覆盖新重试流程。
- 生产部署通过远端校验和与回滚保护；本地/远端 Server 和 Fairy 制品哈希一致，两个服务均为 active，`/ready` 与管理 API schema v7 验收通过。模型仍未配置，外部工具为 0，自动学习保持关闭，M8 继续暂停。

当前进度（M7 Agent 化 F5.17，显式生产 AI 启停，已部署）：

- 受管配置升级为 v8，新增独立 `ai_enabled` 生产总开关；新配置和仅通过环境变量提供候选模型的部署默认关闭，v1-v7 中已存在 `replyer` 路由的部署迁移后保持原有启用行为。
- Provider / Model 可以在关闭状态且没有 Task 时保存；安全连通性探测与固定质量评测不受生产开关影响。生产开启仍强制要求有效 `replyer` Task，关闭时 Fairy 不创建用户对话 Model Router。
- AI 启停需要受控重启，并通过 revision、`active_revision`、`restart_pending` 与固定 `ai_activation` 分类审计；API Key 继续只写，管理响应不回显密钥。
- 管理页新增 `Production AI replies` 开关、已配置/开启/待重启状态和未保存修改提示；离开页面或关闭窗口前会阻止未确认的配置丢失。
- 已从本机 CCSwitch 向单次测试进程注入 MiMo `mimo-v2.5-pro` 配置：256 Token 探针约 2.26 秒并通过；5/5 固定质量 Case 通过，1256 input / 457 output tokens，P50 约 4.2 秒、P95 约 9.6 秒。凭据未回显或写入仓库、日志和生产配置。
- 提交 `79b7eab` 已推送，GitHub Actions CI/CD 运行 `33686827904` 已通过；本地静态 Linux x86_64 构建和 Alpine SQLite/Fairy lifecycle smoke 均通过。
- `release-native.sh deploy root@119.23.212.96` 已从提交 `79b7eab` 构建并部署静态制品，生产服务器未参与编译；本地/远端 Server、Fairy 和 VAPID 制品哈希一致，`zzz-im`、`zzz-fairy` 均为 active，`/ready` 和管理页新资产验收通过。
- F5.17 部署检查点的生产管理 API 为 schema v8，`ai_enabled=false`、`model_configured=false`、外部工具为 0，密钥不回显且自动行为学习关闭；当时生产 MiMo 尚未配置或启用。M8 继续暂停。

当前进度（M7 Agent 化 F5.18，生产模型准入资格已部署并完成首个生产候选验收）：

- 受管配置升级为 v9；质量评测通过后持久化模型资格，并绑定当前语料版本以及 Provider/Model 的精确配置摘要。摘要包含 API Key 以保证换钥即失效，但摘要和密钥都不通过管理 API 返回。
- 首次开启生产 AI，以及 AI 已开启时修改模型路由，都要求 `replyer` 的所有 fallback 候选通过当前质量语料；URL、协议、密钥、超时/重试、远端模型名、上下文窗口或价格变化会自动清除不再匹配的资格。
- 异步评测使用启动时快照；完成前配置发生变化返回 `configuration_changed`，资格持久化失败返回 `qualification_store`。资格写入使用独立 `model_validation` 审计分类，并保持热更新与重启修订状态的一致性。
- v8 已启用部署升级后保持运行兼容，但取得资格前不能修改生产模型路由；新部署仍默认关闭 AI。M8 继续暂停。
- 实现提交 `b2f7009` 与空集合兼容修复 `ed900ef` 已推送；GitHub Actions CI/CD 运行 `33690542568`、`33691267095` 均通过。`release-native.sh` 从本地构建并验证静态 Linux x86_64 制品后部署 `ed900ef79667`，生产服务器未参与编译；本地与远端 Server/Fairy 制品 SHA-256 一致，两个服务均为 active。
- 生产已保存 MiMo `mimo-v2.5-pro` Anthropic-compatible 候选及 `replyer` 路由，Provider 超时 45 秒、重试 1 次、退避 500ms，Model 上下文 128000，Task 最大输出 600 Token、日额度 200；`ai_enabled=false`，不会处理真实用户对话。
- 生产 256 Token 安全探针约 3.6 秒通过，使用 25 input / 44 output tokens；固定质量语料 5/5 Case 通过，使用 1256 input / 518 output tokens，P50 约 3.89 秒、P95 约 10.80 秒。资格已持久化到 schema v9 revision 2，`production_ready=true`、无未取得资格的 `replyer` 候选。
- 管理 API 未返回 API Key 或资格摘要，Fairy 日志未发现敏感字段，受管配置权限保持 `0600`。套餐单价未知，输入/输出价格暂记为 0，成本门禁未启用；在明确启用生产回复前仍需确认预算与运行策略。M8 继续暂停。

当前进度（M7 Agent 化 F5.19，生产 AI 受控灰度已部署，生产保持关闭）：

- 生产 AI 从单一总开关扩展为 `off / allowlist / all` 三档。`allowlist` 最多接受 128 个经过账号 ID 校验和去重的账号，空名单或非法账号 fail closed；环境变量支持 `FAIRY_AI_ROLLOUT_MODE` 与逗号/换行分隔的 `FAIRY_AI_ALLOWED_USERS`。
- 受管配置升级为 v10 并兼容 v1-v9：v1-v7 具备 `replyer` 的旧部署迁移为 `all`，v8-v9 按原 `ai_enabled` 迁移为 `off` 或 `all`；v10 中 `ai_enabled` 与 rollout mode 自相矛盾时拒绝加载。名单只保存在 Fairy 的 `0600` 配置中，日志只记录数量，固定审计分类为 `ai_rollout`。
- 灰度账号可进入 Replyer、Planner、Vision 和 Transcriber；未获准账号仍可使用 `/fairy` 管理指令与确定性插件。其私聊模型请求返回固定未开放提示，群聊模型请求静默忽略，且门控发生在任何媒体下载或模型调用前。
- Fairy 管理页用 rollout 选择器和账号名单编辑器替代全局复选框，空名单在浏览器和服务端双重拦截。已在真实本地 IM + Fairy schema v10 环境验证 1440x900 与 390x844 布局、三种控件状态、无横向溢出和无控制台错误。
- 全量 Go test/vet/race、JavaScript/发布脚本静态检查，以及本地 Linux x86_64 交叉编译与 Alpine SQLite/Fairy lifecycle smoke 均通过。实现提交 `0ad94dc` 已推送，GitHub Actions CI/CD 运行 `33694897420` 成功；本地构建的 release `0ad94dc3ffe5` 已通过校验和与回滚保护部署，生产机未参与编译。
- 生产 `zzz-im`、`zzz-fairy` 均为 active，Fairy `/ready` 通过；管理 API 将原 v9 revision 2 文件兼容投影为 schema v10 revision 2 active，资格 1/1 保留且 `production_ready=true`。生产 rollout 仍为 `off`、名单为空、Model Router 未启动；磁盘配置继续保持 v9 与 `0600`，直到下一次管理员保存才写为 v10。M8 继续暂停。

当前进度（M7 Agent 化 F5.20，固定合成 Agent 诊断已部署，生产 rollout 保持关闭）：

- 管理端新增固定 `pipeline-basic` 诊断请求，实际运行 Planner -> Replyer 链路；不接受自定义 Prompt，不读取用户聊天、事实记忆或行为经验，不执行工具、不发送 IM 消息，也不占用聊天日额度。
- Agent 诊断与 Model Probe / Quality Eval 共用单诊断并发槽；生产 rollout 为 `off` 时，针对已保存模型建立临时隔离 Router，诊断结束后不会改变用户消息运行态。管理响应只返回固定场景、状态、耗时和经过 Output Policy 的短回复。
- 已通过无模型、错误场景、并发冲突、工具/额度隔离和关闭 rollout 隔离 Router 测试，并完成 Fairy/Admin 回归、JavaScript 静态检查与差异检查。
- 已从本机 CC Switch 向一次性测试进程注入 MiMo `mimo-v2.5-pro` 配置完成真实验证：5/5 固定质量 Case 通过，使用 1576 input / 364 output tokens，P50 约 5.24 秒、P95 约 8.57 秒；256 Token 安全探针约 1.83 秒通过，使用 25 input / 28 output tokens；在仅配置 `replyer` 的隔离快照中派生 `planner` 并完成实际 Planner -> Replyer 诊断，耗时约 11.7 秒。凭据未回显、落盘或写入生产配置。
- 实现修复提交 `68a17f4` 已推送，GitHub Actions CI/CD 运行 `33698441254` 成功；`release-native.sh deploy root@119.23.212.96` 从本地构建并部署 release `68a17f4c2bea`，生产服务器未参与编译。远端 Agent 诊断返回 HTTP 200 `passed`（约 30.2 秒），`zzz-im`、`zzz-fairy` 均为 active，`/ready` 通过。
- 生产管理 API schema v10 revision 2 active，MiMo 资格 1/1 保留且 `production_ready=true`；`ai_enabled=false`、`model_enabled=false`、rollout 为 `off`，因此不会处理真实用户对话。M8 继续暂停。

当前进度（M7 Agent 化 F5.21，Agent 全路由资格门禁已部署，生产 rollout 保持关闭）：

- 生产准入从仅检查 `replyer` 扩展为同时检查已配置的 `replyer` 与 `planner` 全部候选模型；同一模型被两个 Task 复用时只检查一次，候选顺序保持稳定。
- 管理 API 新增 `agent_configured` 与 `unqualified_production_models`，并保留 `unqualified_replyer_models` 兼容旧管理端；管理页区分 Planner 未配置、已配置但 rollout 关闭、以及生产运行三种状态。
- 首次开启生产 AI，或已开启时修改模型路由，都会拒绝任何未通过当前固定质量语料的 Planner 候选。关闭 rollout 时仍可安全保存 Planner 配置、运行探针、质量评测和固定 Agent 诊断。
- 当前只覆盖 Planner / Replyer Agent 路由；Vision / Transcriber 后续必须使用与媒体能力匹配的独立质量语料，不能直接复用文本与 Tool Call 语料作为生产准入依据。
- 实现提交 `84bca4a` 已推送，GitHub Actions CI/CD 运行 `33700083319` 全部成功；本地提交态构建与 Alpine SQLite/Fairy lifecycle smoke 通过后，release `84bca4ac8a45` 已按哈希校验和回滚保护部署，生产服务器未编译源码。
- 生产受管配置已升级到 schema v10 revision 3 active，同一 MiMo `mimo-v2.5-pro` 资格被 `replyer` 与新增 `planner` 共同复用；`production_ready=true`、`agent_configured=true`，且无未取得资格的生产候选。保存触发的 Fairy 受控重启完成，`zzz-im`、`zzz-fairy` 与 `/ready` 均正常。
- 配置后的固定 Agent 诊断最终返回 HTTP 200 `passed`，耗时约 22.6 秒。首次诊断出现一次脱敏 `planner / invalid_response` 并返回 502，随后 Planner/Replyer 链路成功；该偶发结构化响应问题继续通过 Model Health 观测。`ai_enabled=false`、`model_enabled=false`、`agent_enabled=false`、rollout 为 `off`，不会处理真实用户 AI 消息。M8 继续暂停。

当前进度（M7 Agent 化 F5.22，严格 Agent 诊断契约已部署，生产 rollout 保持关闭）：

- 固定 `pipeline-basic` 诊断不再以“最终存在文本”作为通过条件。Planner 必须独立接收严格 JSON 决策请求，Replyer 必须独立接收固定确认句请求，并精确返回 `Fairy Agent diagnostic passed.`；协议泄露、错误正文、Tool Call 或空回复都会被拒绝。
- Planner 与 Replyer 使用相互隔离的消息历史，Replyer 不会看到 Planner 的 JSON 指令，但仍接收 Planner 产生的 `reply_intent`。诊断继续保持无工具、无用户聊天、无 IM 出站消息且不占聊天日额度。
- 回归测试覆盖 Planner -> Replyer 调用顺序、阶段 Prompt 隔离、Replyer 历史替换、工具与额度不变，以及错误回复和协议泄露拒绝。`go test ./...`、`go vet ./...`、管理端 JavaScript 静态检查、差异检查、Linux x86-64 静态构建和 Alpine SQLite/Fairy lifecycle smoke 均通过。
- 实现提交 `71fe982`、`b2616f9` 已推送，CI/CD #103 成功；release `b2616f9bfc4c` 已按校验和与回滚保护部署，生产服务器未编译源码。生产严格诊断返回 HTTP 200 `passed`，回复精确匹配，耗时约 7.878 秒。
- 生产保持 schema v10 revision 3 active，`production_ready=true`、`agent_configured=true`；`ai_enabled=false`、`agent_enabled=false`、rollout 为 `off`。MiMo 偶发 `planner / invalid_response` 仍作为 Model Health 风险继续观测，不影响当前关闭状态。M8 继续暂停。

当前进度（M7 Agent 化 F5.23，Agent 结构化响应单次修复已部署，生产 rollout 保持关闭）：

- 每个 Planner Step 对 `invalid_response` 或 Planner 决策格式错误最多执行一次独立修复；认证失败、内容拒绝、取消、超时和额度拒绝不进入修复。修复发生在任何新 Tool Call 前，使用独立版本化 Prompt，不携带被拒绝的模型正文，也不会重放已经执行的工具。
- 固定严格诊断的 Replyer 在供应商返回无效响应或未精确匹配确认句时最多修复一次；修复只重试 Replyer，不重跑 Planner 或工具。普通聊天 Replyer 没有固定答案契约，不因文案差异重复调用模型。生产会话内的修复作为独立模型请求扣减对应额度；固定诊断仍不占聊天额度，但会产生独立供应商请求与费用。
- Model Attempt Trace 新增脱敏 `repair` 标记；Model Health 按 Task / Provider / Model 聚合 Repair 次数，Recent Failures 标记失败是否发生在修复请求。管理页增加独立 `Repair` 列，未写入拒绝正文、Prompt、供应商错误或用户身份。
- Planner/Replyer 修复、工具不重放、Prompt 隔离、额度、非法元数据和 Trace 聚合专项测试连续 10 次通过；全量 `go test ./...`、`go vet ./...`、JavaScript 与差异检查通过。MiMo 严格诊断本地连续 3 次通过，约为 18.7、16.1、12.3 秒。
- 实现提交 `2f612c2` 已推送，GitHub Actions CI/CD 运行 `33705851757` 成功；release `2f612c2de710` 已由本地构建静态 Linux x86-64 制品、通过 Alpine smoke 后按哈希校验和回滚保护部署，生产服务器未编译源码。`zzz-im`、`zzz-fairy` 均为 active，本地与远端制品哈希一致，`/health`、`/ready` 和生产固定严格诊断均通过。
- 管理页已使用生产脱敏 Model Health 数据在 1440x1000 与 390x844 视口验收；Repair 列与模型行对齐，移动端表格独立横向滚动，页面无全局横向溢出或控制台错误。生产保持 schema v10 revision 3 active，`production_ready=true`、`agent_configured=true`；`ai_enabled=false`、`agent_enabled=false`、rollout 为 `off`。M8 继续暂停。

当前进度（M7 Agent 化 F5.24，决策链、插件宿主与管理信息架构已部署）：

- 以 DSH 的会话事件流为数据骨架、MaiBot 的推理浏览体验为展示参考，新增按 Turn 串联 Admission、Gate、Planner、Replyer、模型调用、工具调用/结果和最终状态的决策链。Provider 明确返回的 `thinking` 原样保存；`redacted_thinking` 不可恢复明文，只保存不可逆摘要式签名和“已隐藏”标记。
- 新增 Fairy 本机管理 API `GET /admin/decision-chains` 和 IM 管理代理 `GET /admin/api/fairy/decision-chains`；管理页 Decisions 分类每 5 秒刷新，桌面端采用会话列表与详情双栏，移动端自动切为单栏。该页面属于敏感管理数据面，只通过既有管理鉴权开放。
- Fairy 管理页由单一长页面拆为 Runtime、Models、Behavior、Plugins & Tools、Decisions 横向分类；窄屏分类栏独立横向滚动，不制造页面级横向溢出。
- 新增插件 Manifest、组件注册、Capability Context、Hook/Event Bus、依赖与最低版本排序、生命周期 disposer、卸载和热重载。可信编译期插件使用进程内 Runner；宿主保留隔离 Runner 注入边界，外部工具继续使用既有 MCP 子进程和 Tool Runtime 安全层，不开放网页上传或执行任意插件代码。
- `context-memory`、`fact-memory`、`self-cognition` 已迁为内置插件；命令、Prompt 和 Tool 从宿主当前运行快照动态解析，插件卸载后立即不可见，重载不会继续调用旧实例。Manifest 默认启用值仅在没有显式配置时生效。
- 私聊 Fairy 的最终回复不再引用触发消息；群聊仍保留引用，后续平台 Adapter 可在插件业务配置中覆盖引用策略。
- `zzz-profile` 的功能与交互基准固定为 [ZZZeroUID](https://github.com/ZZZure/ZZZeroUID)（审计基线 `063856f0cf812365890e74536f3ec82d5fd075d8`）。已按参考实现将 UID 输入、命令解析与 Tool Schema 统一为 8–10 位，并补充真实 8 位 UID `27280531` 穿过 Tool Runtime 的回归；当前仍是只读公开资料查询子集。
- 后续按独立组件增量迁移 `uid-binding`、`profile-summary`、`character-detail`、`gacha`、`daily-note`、`abyss` 与 `admin/config`；其中 UID 绑定必须使用 Fairy 自有持久化和 IM 用户作用域，不能依赖参考项目的 `gsuid_core.GsBind`。
- 实现提交 `a3ba133` 已包含在 release `f3801659b43b` 中部署；决策链、插件宿主与分类管理页面已随本地静态 Linux x86-64 制品上线，生产服务器未编译源码。M8 继续暂停。

当前进度（M7 Agent 化 F5.25，米游社账号、抽卡与式舆能力已部署）：

- 新增独立 `zzz-account` 插件，第一版限定国服米游社，支持 `/zzz login`、`/zzz account`、`/zzz gacha sync`、`/zzz gacha`、`/zzz abyss [previous]` 与 `/zzz logout`。扫码二维码由 Fairy 本地生成并上传到现有 ZZZ 媒体服务，确认轮询和首次抽卡同步均脱离单 Turn 在插件生命周期内后台执行。
- 账号库使用独立 SQLite 文件；Cookie 与 Stoken 分字段采用 AES-256-GCM 加密，随机 32-byte 密钥不复用 Trace Key，AAD 绑定 IM `owner_id` 和凭据类型，数据库与密钥权限均为 `0600`。聊天、模型、Planner、Trace、日志和管理 API 均不接收或返回明文凭据。
- 个人账号、抽卡和式舆 Tool 使用运行时注入的 `ToolScope.SenderID`，Schema 不存在 `owner_id` 参数，群聊查询也只能读取发送者本人；登录、账号信息和退出绑定只允许私聊。管理运行态仅增加绑定数、有效数和缓存记录数聚合。
- 已按 `gsuid_core` 扫码登录链路和 `ZZZeroUID` 的 AuthKey、调频记录、`hadal_info_v2` 协议实现固定上游客户端；上游响应正文不进入错误或日志，凭据失效、风控、限流和二维码过期只映射为固定错误文案。
- 本地全量 `go test ./...`、`go vet ./...`、CI 同范围 `-race` 与 Linux x86-64 `release-native.sh validate` 均已通过；加密落盘、错误脱敏、本地 PNG 二维码、私聊边界、后台同步和跨用户 Tool 作用域均有专项回归。
- 移动底栏提交 `0c35e1a` 与 Fairy 米游社实现提交 `f380165` 已推送，GitHub Actions CI/CD 运行 `33732277256` 成功；release `f3801659b43b` 已由本地构建静态 Linux x86-64 制品、通过 Alpine smoke 后按哈希校验和回滚保护部署，生产服务器未编译源码。
- 生产 `zzz-im`、`zzz-fairy` 均为 active，Fairy `/ready` 与 `zzz-account` 插件运行态通过；账号库及独立 32-byte 凭据密钥均为 `0600`。`icrad.ltd` PWA 已原子切换到同名 release，核心 JavaScript 哈希与 CI Pages 制品一致。部署保留既有 schema v10 revision 4 受管配置：`production_ready=true`、`agent_enabled=true`、rollout 为 `all`。M8 继续暂停。

### M1-M7 使用体验修复批次（已完成并上线）

M8 暂停期间，优先处理生产使用中确认的以下问题：

1. 用户头像和名片背景默认支持上传到 ZZZ IM 服务端；同时保留填写 HTTPS 链接和使用客户端已配置图床的方式。名片背景新增任意纯色选项。
2. 个人名片头像保持原始宽高比显示，不再放大裁切主体。
3. 点击联系人默认进入对应私聊会话；联系人条目右侧滑动后显示操作按钮，并通过按钮打开个人名片。
4. 创建群聊未设置头像时，客户端使用群成员头像集合生成组合群头像，且成员资料变化后可以更新。
5. 用户可以选择是否在个人名片中公开账号 ID；关闭后其他用户不可从名片接口或名片 UI 看到该字段，但不改变内部路由标识。
6. 称号取消背景底色和胶囊外观，颜色或动态效果只作用于文字本身。
7. 转发消息中的发送者账号 ID 使用消息快照中的昵称展示；昵称缺失时再使用账号 ID 作为兜底。
8. 解除屏蔽不会自动恢复好友关系；解除后对方不应继续留在好友联系人列表，重新成为好友必须重新发起好友请求。
9. 修复 PWA 录音发送，包括安全上下文、浏览器麦克风权限、Web 录音格式和上传流程。
10. 修复 PWA 定位发送，包括浏览器定位权限、失败反馈，以及手动地点名称的可用兜底。

本批次完成条件：每项均具备对应的服务端或 Flutter 回归测试，通过完整 CI/CD，并在 `icrad.ltd` 的 PWA 与至少一个桌面端完成关键流程验证。

完成记录（2026-09-02）：

- 主批次提交为 `0353341`，生产验证发现的服务端媒体相对 URL 补全修复为 `fd8e376`。
- `go test ./...`、Flutter 全量 103 个测试、Flutter 静态分析、release Web 构建及 Wasm dry-run 均通过。
- GitHub Actions CI/CD 运行 `33585689164` 与 `33586992943` 均通过，覆盖 Flutter、Go、容器构建和 GitHub Pages 部署。
- `icrad.ltd` 已完成服务端背景上传、纯色背景、账号 ID 隐藏、好友请求通知、无头像建群、WebM 语音、手动定位以及 Block/Unblock 关系语义的生产 WSS smoke。
- PWA 已部署为 `fd8e376-root`；公网资源清单版本为 `9009ed8366356fda`，构建总量 `60,260,007` bytes，首页、IM、Fairy 和 Nginx 健康检查正常。
- M8 继续暂停，下一批工作以实际使用反馈为准，不在本批次中恢复实时音视频开发。

### M1-M7 使用体验修复第二批（已本地实现、待发布）

1. 群聊输入框输入 `@` 后按当前群成员实时补全，可按昵称或账号过滤；ZZZ Server 发送原生 `at + text` 消息段，缺少结构化提及能力的平台 Adapter 降级为普通文本。
2. 手机比例下 Messages 标题/联系人入口与会话列表支持上下互换，选择保存在本地；宽屏布局保持不变。
3. 群成员列表头像可点击并打开对应成员名片。

本批次已增加 Flutter 组件测试和 ZZZ Server 消息段测试；当前尚未提交、推送或部署，M8 继续暂停。

### 2. 语音房间

- 支持在私聊或群聊中发起临时语音房间。
- 包含加入/离开、静音、成员列表、主持人和邀请能力。
- 技术上优先采用 WebRTC，并评估 TURN 与 SFU 服务的带宽成本。

当前执行状态（暂停）：

- 已完成现有消息协议、服务端网关、会话权限和 Flutter 聊天页面的接入点审计。
- 尚未提交语音房间、WebRTC 信令、TURN 或 SFU 相关代码，也未产生新增实时音视频服务费用。
- M8 暂停实施；下一优先级切换为汇总和修复 M1-M7 实际使用中发现的体验问题，问题清单确认后再更新执行顺序。

### 3. 视频与直播房间

- 支持私聊和群聊中发起视频通话或直播房间。
- 区分小规模视频通话与一对多直播，两者的服务端架构和成本不同。
- 第一版应限制分辨率、房间人数和持续时间，并具备主持、禁言、踢出和举报能力。
- 在开发前先完成带宽成本、移动端耗电和 iOS PWA 后台限制验证。

## 六、推荐落地顺序

| 里程碑 | 内容 | 状态 | 原因 |
| --- | --- | --- | --- |
| M1 | PWA 加载反馈、性能监控、缓存优化 | 已上线，持续固定环境采样验收 | 当前最直接影响访问和留存的问题 |
| M2 | 双媒体通道、Hash 去重、缩略图、压缩 | 已完成 | 为语音、名片背景和后续媒体能力打基础 |
| M3 | 更新说明、内置表情、来源标识简化 | 已上线 | 改善版本感知、消息表达和多平台列表密度 |
| M4 | 语音消息、转发与链接分享、定位、戳一戳 | 已上线 | 完善日常通信能力 |
| M5 | 管理员角色、群公告、屏蔽策略 | 已完成，随 1.3.0 发布 | 建立群组治理和通知规则 |
| M6 | 称号和个人名片 | 已上线，随 1.4.0 发布 | 在权限与媒体能力稳定后扩展个人表达 |
| M7 | Fairy AI 好友与 ZZZ 插件 | Agent F0-F5.23 已部署；F5.24 决策链、插件宿主和管理分类已本地实现、待发布；生产 rollout 保持 `off` | 以独立 Bot 服务接入，控制对核心 IM 的影响 |
| M8 | 语音房间、视频和直播房间 | 已完成接入点审计，暂停实施 | 先处理 M1-M7 实际使用体验问题，再恢复实时房间建设 |

## 七、产品决策

### 已确认

1. 本文档作为正式路线图纳入项目仓库版本管理。
2. PWA 普通网络首次可交互目标为 8 秒以内，二次访问目标为 2 秒以内。
3. 客户端允许配置自己的图床；客户端直传，服务端仅保存远程图片 URL，不保存图片文件。
4. 服务端托管媒体继续作为默认回退方案。
5. 自定义图床上传失败时不自动回退，避免重复上传；用户可关闭图床后改用服务端托管重试。
6. 链接分享第一版不由服务端抓取网页预览，客户端展示 URL、标题和域名，避免引入 SSRF 风险。
7. 定位消息第一版不绑定商业地图 SDK；保存地点名及可选坐标，有坐标时使用 OpenStreetMap 打开。
8. 单条语音暂定限制为 2 分钟、10 MB，戳一戳暂定按“发送者 + 会话”限制为每 5 秒一次。
9. 完全静音仍同步消息并累计未读数，且不推送群公告；“仅提醒”会推送 `@我`、`@全体` 和群公告。
10. 好友请求属于会话外事件，不受私聊或群聊通知档位影响。
11. 暂不新增服务端“隐藏会话”状态；本地隐藏与通知策略保持独立。
12. 系统管理员使用独立管理端令牌，不赋予普通 IM 用户读取私聊内容的能力。
13. 个人名片背景与聊天图片的普通客户端图床配置共用；未配置图床时由 ZZZ IM 服务端默认托管，接收端统一按网络图片显示。
14. Fairy 以普通账号接入，客户端仅在账号存在且未成为好友时推荐；其他部署可以配置或关闭预设 Bot 列表。

### 待确认

1. 服务端托管媒体的保留期限、单文件大小限制和用户存储配额。
2. Fairy 生产环境使用的模型供应商、月度费用预算和内容安全服务；明确前保持插件模式，不启用 AI 对话。
3. 音视频房间的最大人数、清晰度和月度带宽预算。
