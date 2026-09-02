# Fairy AI Agent Bot 架构设计

## 一、文档状态

本文是 Fairy 从当前线性 Bot 演进为受控 AI Agent Bot 的确定版架构。运行和部署方式仍见 [FAIRY.md](FAIRY.md)，产品优先级仍见 [ROADMAP.md](ROADMAP.md)。

设计基线：

- 当前 Fairy 代码：`server/internal/fairy`
- [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)：本地工作区 `../ref/deepseek-harness`，固定提交 `4e84901e6471`
- [MaiBot](https://github.com/Mai-with-u/MaiBot)：本地工作区 `../ref/MaiBot`，固定提交 `ed8493cb741f`
- 本地研究笔记（不进入产品发布制品）：`../ref/deepseek-harness-architecture-notes.md` 与 `../ref/maibot-architecture-notes.md`

本文只确定架构，不表示所有能力已经实现。实施顺序见“十五、落地阶段”。

## 二、覆盖结论

### 1. 现有参考是否足够

结论分两层：

1. **足够设计 Fairy 的 Agent 核心**：DSH 覆盖生命周期、Inbox、Turn / Step、模型 Adapter、Tool Pipeline、Session、Prompt、取消和回放；MaiBot 覆盖 Provider / Model / Task、Planner / Replyer、群聊行为、人格和记忆。
2. **不足以单独覆盖生产级 IM Agent Bot**：两者都不能替代 ZZZ 自己的消息投递语义、安全威胁模型、观测标准、评测体系和生产运维设计。

因此不再继续寻找第三个大型 Agent 框架。缺口用更窄、更权威的参考补齐：

- ZZZ IM 协议与本地 OneBot / NoneBot 资料：平台事件、消息 ID、回复和群权限。
- [OWASP Agentic AI Threats and Mitigations](https://genai.owasp.org/resource/agentic-ai-threats-and-mitigations/)：Prompt Injection、Excessive Agency、数据泄漏、工具滥用和供应链威胁。
- [OpenTelemetry GenAI Semantic Conventions](https://opentelemetry.io/docs/specs/semconv/gen-ai/)：模型、Agent 和工具 Trace 的字段语义。
- [Model Context Protocol](https://modelcontextprotocol.io/specification/latest)：可信外部 Tool Provider 的 stdio 协议；F5.2 使用官方 Go SDK 实现。
- Fairy 自己的 golden conversations、对抗样例和并发测试：行为质量不能由框架替代。

### 2. 覆盖矩阵

| 领域 | DSH | MaiBot | ZZZ / 补充参考 | 结论 |
| --- | --- | --- | --- | --- |
| Agent 生命周期、取消、静止 | 强 | 部分 | Go context / systemd | 已覆盖 |
| Inbox、Turn / Step、并发顺序 | 强 | 强 | ZZZ message ID | 已覆盖 |
| 模型 Adapter 与调用快照 | 强 | 强 | OpenAI / Anthropic-compatible API | 已覆盖 |
| Provider / Model / Task 路由 | 部分 | 强 | Fairy 配置 | 已覆盖 |
| Planner / Replyer 与聊天行为 | 执行内核 | 强 | Fairy 产品规则 | 已覆盖 |
| Tool Schema、策略、审批、超时 | 强 | 强 | OWASP | 已覆盖 |
| Prompt、上下文、压缩 | 强 | 强 | Fairy 隐私策略 | 已覆盖 |
| 人格、Focus、行为门控 | 非核心 | 强 | 群聊触发规则 | 已覆盖 |
| 长期记忆、行为学习 | 部分 | 强 | 用户同意和删除规则 | 延后但有参考 |
| IM 去重、投递不确定性、重连 | 非重点 | 非重点 | ZZZ / OneBot | 必须自行设计 |
| 内容安全与 Agent 威胁模型 | 工具安全强 | 部分 | OWASP | 必须补策略 |
| Trace 与指标 | 强 | 部分 | OpenTelemetry | 已覆盖 |
| 行为评测、回归与红队 | 测试很多 | 部分 | Fairy eval corpus | 必须自行建设 |
| 多实例、高可用和灾难恢复 | 非重点 | 非重点 | Fairy 运维 | 后续自行设计 |
| 外部插件协议和隔离 | Cordis 进程内 | 多来源插件 | MCP / 独立进程 | 内置 Tool + F5.2 MCP stdio 已实现 |
| 语音、图片、定位等 IM 多模态 | 图片较强 | 多模态任务 | ZZZ 消息段 | 图片 / 语音已实现，其他按需推进 |

参考覆盖已经足够开始实现，但不能把“参考项目有该模块”当作 Fairy 的验收标准。Fairy 的验收以本文不变式、安全规则和 eval 结果为准。

## 三、产品定位

Fairy 是 ZZZ IM 中的 AI 好友与受控 Agent Bot：

- 作为普通账号通过公开 WebSocket 协议连接 ZZZ IM。
- 支持私聊和加入群聊；群聊默认只响应明确提及或指令。
- 能进行日常对话，也能通过受限工具完成查询和后续明确授权的操作。
- 确定性命令不依赖模型，模型不可用时仍可工作。
- 所有副作用都经过 Tool Pipeline 或 Output Policy。
- 默认不持久化私聊和群聊正文，不允许跨会话泄漏上下文。

Fairy 不是：

- ZZZ IM Server 内置的推理模块。
- 负责管理 QQ、NoneBot 或其他平台接入的服务端中台。
- 可任意访问文件、数据库、网络和管理 API 的通用自动化 Agent。
- 默认在群聊中自主插话、后台长期执行任务或代表用户产生外部写入的机器人。
- 可以从管理网页上传并执行任意代码的插件宿主。

## 四、系统边界

### 1. ZZZ IM Server

继续只负责账号、关系、群组、消息、媒体、通知和通用协议：

- 不保存模型 API Key。
- 不组装 Prompt，不执行模型或 Fairy 工具。
- 不管理外部平台 Adapter。
- 管理后台只通过回环管理 API 透明代理 Fairy 配置和脱敏状态。

允许为所有客户端增加通用协议能力，例如 `send_message.client_message_id` 幂等键；这不是 Bot 专用控制面。

### 2. Fairy 进程

Fairy 自己拥有：

- ZZZ Adapter 与登录重连。
- Ingress 去重和 Conversation Scheduler。
- Agent Runtime、Gate、Context Surface 和 Prompt。
- Model Router、Planner、Replyer 和 Tool Pipeline。
- Bot 配置、额度、脱敏 Trace、健康状态和管理 API。

### 3. 客户端和外部平台

普通客户端继续自行配置和组合外部平台来源。未来 Fairy 若需要接入其他平台，使用独立 Adapter 或独立进程将事件规范化后提交给 Runtime，不要求 ZZZ IM Server 管理这些平台。

## 五、总体架构

```text
ZZZ WebSocket
  -> ZZZ Adapter
  -> Ingress Normalizer
       -> message-id dedupe
       -> trigger prefilter
       -> bounded admission
  -> Conversation Scheduler
       -> one FIFO inbox per conversation
       -> one active Turn per conversation
       -> global active-conversation limit
  -> Agent Runtime
       -> Gate Pipeline
       -> Context Surface
       -> Prompt Assembler
       -> Chat mode: Replyer
       -> Agent mode: Planner -> Tool Pipeline -> Planner -> Replyer
       -> Output Policy
  -> ZZZ Adapter send

Cross-cutting services:
  Model Router | Tool Registry | Agent Scope | Trace Store
  Quota/Budget | Safety Policy | Runtime Config Snapshot | Admin API
```

采用轻量 Go 接口和中间件，不在 Go 中重写 Cordis。模块必须有明确的 `Start` / `Close` 或 disposer，所有 goroutine、timer 和在途请求都归属于可取消、可等待的生命周期。

## 六、消息接入与调度

### 1. 规范化事件

Adapter 将平台事件转换为统一 `InboundEvent`：

```go
type InboundEvent struct {
    Source         string
    EventID        string
    ConversationID string
    SenderID       string
    Kind           string
    Timestamp      time.Time
    Segments       []MessageSegment
}
```

`EventID` 在 ZZZ Adapter 中使用服务端 `message_id`。身份必须包含 Source namespace，防止多个平台的相同账号 ID 或会话 ID 冲突。

### 2. 去重与投递

- 已处理的 `source + event_id` 必须幂等忽略。
- 去重记录只保存事件 ID、状态和过期时间，不保存消息正文。
- WebSocket 重连后收到重复事件不能再次调用模型或工具。
- 好友请求等控制事件使用独立 control lane，但同样按 flag / event ID 幂等。

`send_message` 已增加可选 `client_message_id`。服务端按“发送者 + 客户端消息 ID”持久化唯一约束，并保存会话和消息段指纹：相同请求重试返回原消息，不再次广播或推送；同一键对应不同请求时明确返回冲突。旧客户端省略该字段时保持原行为。

Fairy 出站默认生成该幂等键。F5.6 起，发送确认超时或 WebSocket 在确认前断开时，会在当前进程内最多尝试 3 次，并在重连后继续使用同一个 `client_message_id`；明确的 API 拒绝不会重试。回复正文只存在于当前 Turn 内存，不写入 outbox 文件，进程重启后不自动重放。副作用工具同样不得因模型 Retry 或进程重启自动重放。

### 3. Conversation Scheduler

当前 `Runner.runWorker()` 会为消息直接启动 goroutine，同一会话可能乱序，达到全局并发上限时还会直接跳过事件。目标调度规则：

1. 每个 conversation 有 FIFO Inbox。
2. 每个 conversation 同时最多一个活跃 Turn。
3. `MaxConcurrent` 限制活跃会话数，不限制一个无队列的随机消息集合。
4. 全局繁忙时保留已接纳的有界队列，不静默丢消息。
5. 队列溢出时记录 `admission_rejected`，并最多发送一次繁忙提示。
6. `/fairy stop` 走优先控制路径，可取消当前 Turn。

首版新消息语义：

- 当前无 Turn：创建新 Turn。
- 当前有 Turn：作为 FIFO `followup` 排入下一个 Turn。
- 不在首版把普通消息 `steer` 进正在运行的模型 Step。
- 管理指令也遵守会话顺序，只有 stop / cancel 可抢占。

## 七、Agent 生命周期

### 1. Agent 与 Turn

一个 conversation 对应一个可按 TTL 回收的 `ConversationAgent`。Agent 持有 Inbox、Context Surface、Scope 和当前 Turn；不持有全局模型客户端或全局插件状态。

```text
Idle
  -> Admitted
  -> Gated
  -> Planning / Replying
  -> ExecutingTool -> Planning
  -> Sending
  -> Completed

任意运行状态 -> Cancelling -> Cancelled
任意运行状态 -> Failed / TimedOut
```

一个 Turn 可以包含多个 Step。一个 Step 是一次模型请求及其工具调用结果。

### 2. 取消和静止

- Turn 持有统一 `context.Context` 和 cancel cause。
- Model、Tool、backoff、send 和异步任务都必须观察该 Context。
- 取消后停止创建新 Step，但等待已启动任务退出。
- 只有达到静止状态后才释放 Agent Scope、重载冲突配置或退出进程。
- 已产生副作用的 Tool 不因 Retry 自动重放。

### 3. 资源上限

首版默认约束：

- Planner 最多 4 个 Step。
- 每 Turn 最多 6 个 Tool Call。
- 单工具最长 15 秒。
- 整个 Turn 最长 60 秒。
- 最终可见回复默认最多一次。
- 模型和工具输出分别设置字节、字符和 Token 上限。

这些值进入配置并由 Runtime 强制，而不是只写在 Prompt 中。

## 八、模型系统

### 1. 三层配置

采用 MaiBot 的职责分层与 DSH 的 Adapter 快照：

```text
Provider -> Model -> Task
```

- Provider：协议类型、Base URL、凭据引用、Header、timeout、retry policy。
- Model：Provider 引用、真实 model ID、上下文窗口、能力、价格和默认参数。
- Task：候选模型、选择策略、最大输出、硬超时和预算。

首批 Task：

- `planner`：选择工具或输出回复意图。
- `replyer`：生成最终用户可见文本。
- `vision`：理解经过本地边界校验的图片。
- `transcriber`：转写经过本地边界校验的语音。
- `utility`：摘要、标题等低风险辅助任务。

`vision` 和 `transcriber` 已在 F5.3 接入；后续只按真实需求增加 `embedding` 和 `moderation`，不预先创建空任务。

### 2. 调用快照

一次模型调用从能力解析到完成始终持有不可变 `ProviderSnapshot`：

- Provider endpoint 和认证配置。
- Model 能力、上下文窗口和默认参数。
- Task 选择结果与 Retry Policy。
- Prompt 版本和 Tool Schema 版本。

配置热更新只影响后续调用，不能让一个请求前后使用不同配置世代。

### 3. Retry 与 fallback

- 同模型只对明确可重试的 timeout、429 和部分 5xx 做有限 Retry。
- Retry 使用指数退避、jitter 和可取消等待。
- `sequential` 是默认跨模型策略：主模型失败后依次尝试备用模型。
- 鉴权、无效参数、内容拒绝和安全策略拒绝不跨模型重试。
- 已流出用户可见内容或结果不确定时不自动切换模型重新生成。
- 每次尝试都写脱敏 Trace，并计入独立的 attempt / token / cost 统计。

### 4. Chat 与 Agent 模式

为控制成本和延迟，不要求每条闲聊固定调用两次模型：

- 确定性命令：直接执行，不调用模型。
- 普通闲聊：`replyer` 单次调用。
- 需要工具或复杂行动：`planner -> tools -> replyer`。
- 以后可由 Profile 强制所有自然语言进入 Planner，但必须先经过成本与质量评测。

Planner 和 Replyer 是独立 Task，即使暂时指向同一个 Model，也不能共享职责 Prompt。

## 九、Prompt 与上下文

### 1. Prompt Sections

System Prompt 拆成有稳定 ID 和顺序的 section：

- `identity`：Fairy 身份和产品边界。
- `persona`：语气、语言和表达档位。
- `platform`：私聊 / 群聊、引用和消息段规则。
- `safety`：隐私、拒绝和工具安全规则。
- `task`：Planner 或 Replyer 职责。
- `tools`：当前 Agent Scope 可见的工具。
- `runtime_context`：当前时间、群角色等动态信息。

每次请求 Trace 记录 section 版本和内容 HMAC，不默认记录完整 Prompt。

### 2. Context Surface

Context Surface 是本次模型可见的结构化历史，不等同于持久化聊天数据库：

- 只收录明确触发 Fairy 的消息。
- 群聊未提及 Fairy 的普通消息默认不进入 Surface。
- 保存 role、source message ID、segments、Tool Call / Result 和时间。
- 按 Token 预算保留最近消息，必要时生成带来源范围的摘要。
- 摘要不能覆盖未闭合的 Tool Call，也不能丢失当前回复目标。

### 3. 隐私与回放取舍

Fairy 保留当前默认：聊天正文只在内存 Context Surface 中按 TTL 存在，不写入状态文件或管理 Trace。

因此：

- 可以持久化 Turn、模型、工具、耗时、错误、Token 和消息 ID 等元数据。
- 默认不能跨进程重启精确回放模型上下文。
- 进程崩溃后的未完成 Turn 标记为 aborted，不自动恢复副作用。
- 将来若提供持久记忆，必须由用户或群管理员明确开启，支持查看来源、清除和退出。

这是一项有意的隐私选择，不追求照搬 DSH 的全量 durable replay。

## 十、Planner、Replyer 与行为

### 1. Planner

Planner 只输出结构化 Decision：

- `call_tools`
- `respond`
- `wait`
- `stop`

工具参数必须来自模型原生 Tool Call 或严格结构化输出，不用正则从自然语言提取 JSON。Planner 不直接发送消息。

### 2. Replyer

Replyer 接收 Planner 的回复意图、必要上下文和已投影工具结果，只生成候选文本。Output Policy 再负责：

- 空响应和长度检查。
- 敏感信息与危险链接检查。
- 引用目标和消息段构造。
- 最多一次最终发送。
- 发送结果与服务器 message ID Trace。

### 3. Gate 与 Focus

Gate 在模型前执行并返回 `trigger / wait / ignore / reject` 及原因：

- 硬触发：私聊、@Fairy、`/fairy` 和已注册命令。
- 硬抑制：无效事件、Fairy 自身消息、空文本和已关闭群中的非管理请求。
- 当前软信号：群内明确触发后，同一用户在 Focus TTL 内继续发送普通文本。
- 软抑制：`off`、`shadow`、Focus 缺失/过期、其他用户 Focus 冲突和 cooldown。

群聊软触发默认运行 `shadow`，只写固定 Gate action/reason，不真正回复。群主或管理员可按群设为 `off / shadow / on`；只有 `on` 才让通过 Focus 和 cooldown 的软触发进入 Scheduler。

### 4. 人格与行为学习

- 人格首先是版本化配置，不由模型自动改写。
- 表达档位先做 `brief / normal / detailed` 等确定性配置。
- 管理员审查的只读经验召回已在 F5.5 实现；F5.8 已增加显式赞/踩质量观测，但自动行为经验学习、场景聚类和自动写回仍关闭。
- 没有稳定 Trace 和成功指标前，不持久化模型自我总结出的行为经验。

## 十一、Tool 与插件

### 1. Tool Contract

```go
type ToolSpec struct {
    Name        string
    Description string
    InputSchema json.RawMessage
    OutputSchema json.RawMessage
    Risk        RiskLevel
    Concurrency ToolConcurrency
    Idempotency ToolIdempotency
}
```

Tool 返回规范化结构，再分别投影为模型内容、UI presentation 和脱敏 Trace。不能只返回随意拼接的字符串。

### 2. 执行流水线

```text
resolve tool
  -> validate arguments
  -> scope visibility
  -> user/group authorization
  -> risk and confirmation policy
  -> rate/quota/timeout
  -> execute
  -> validate output
  -> redact and size-limit
  -> trace
  -> model/UI projection
```

工具策略只能逐步收紧，不能由下游重新放宽。

### 3. 并发和副作用

- 首版所有工具默认串行。
- 纯只读查询以后可标记 `parallel`，但结果仍按模型调用顺序提交。
- 消息发送、账号和群管理工具必须 `exclusive`。
- 有副作用工具必须声明幂等策略；结果不确定时不自动重放。
- Planner 不能访问未注册的 HTTP、文件、数据库或 IM API。

### 4. 插件形态

分阶段支持：

1. 编译期 Go Tool Provider：首版，现有 `zzz-profile` 迁移到统一 Registry，同时保留 `/zzz` 直接命令。
2. 可信独立进程 / MCP Provider：F5.2 已本地实现，包含显式配置、双层能力 allowlist、超时、熔断和进程生命周期。
3. WASM 沙箱：只有出现不可信第三方插件需求时再评估。

不使用 Go `plugin` 从管理网页加载任意动态库。Agent Scope 是可见性边界，不是恶意代码沙箱。

## 十二、安全设计

当前凭据正则拦截只能作为第一层，不能代表完整内容安全。Fairy 需要覆盖：

| 威胁 | 控制 |
| --- | --- |
| 直接 Prompt Injection | 系统规则、结构化 Decision、工具 allowlist、输出检查 |
| 工具结果中的间接注入 | 工具内容标记为不可信数据，不把其指令提升为系统规则 |
| Excessive Agency | 最小工具集、风险分级、确认、Step / Tool / 时间上限 |
| 跨会话数据泄漏 | Agent Scope、Source namespace、Context 分区、禁止默认跨会话记忆 |
| 凭据和隐私泄漏 | 输入凭据检测、参数脱敏、日志 HMAC 标识、密钥只写不读 |
| SSRF / 任意网络访问 | Tool 内固定或 allowlist endpoint、DNS / redirect / private IP 校验 |
| 资源耗尽 | Admission、队列、Token、并发、每日预算和响应体上限 |
| 插件供应链 | 内置签入源码；外部进程显式配置和能力清单；禁止网页上传执行 |
| 重复副作用 | 入站去重、Tool 幂等声明、出站 `client_message_id` |
| 模型供应商故障或越界 | Task fallback、hard timeout、安全拒绝不 fallback、完整失败 Trace |

生产启用 AI 前必须明确：模型供应商、月度预算、输入输出内容安全策略、数据是否用于供应商训练、日志保留和用户告知。

## 十三、Trace、指标与评测

### 1. Trace

每个 Turn 记录：

- `trace_id`、`turn_id`、`step`。
- Source、使用部署密钥 HMAC 后的 conversation / user 标识。
- 入站 Event ID、Gate 决策和 admission 结果。
- Task、Provider、Model、配置 snapshot ID 和 Prompt version。
- 每次 LLM attempt 的状态、耗时、Token、费用和错误码。
- Tool Call ID、工具名、风险、策略结果、耗时和结果状态。
- Output send 的 client message ID、服务器 message ID 或 unknown outcome。

默认不记录 API Key、Authorization、Cookie、完整工具敏感参数和聊天正文。字段命名尽量映射 OpenTelemetry GenAI 语义，存储实现保持可替换。

### 2. 管理指标

管理面板优先展示：

- Agent 在线和队列状态。
- Provider / Model 健康、延迟、错误率和 fallback。
- Task Token、费用和每日 / 月度预算。
- Tool 调用量、成功率、拒绝和 timeout。
- Gate 原因、群聊 shadow 结果和 admission rejection。
- 最近 24 小时最多 20 条脱敏失败摘要和配置版本；仅展示固定失败码、配置 ID、耗时、attempt / step / fallback 与有限队列数字。

管理面板默认不提供查看完整私聊内容的入口。

### 3. Eval Corpus

Fairy 必须有独立于模型供应商的版本化评测集：

- 中英文普通对话、人格和拒答边界。
- `/fairy`、`/zzz` 等确定性命令。
- 自然语言 Tool 选择、参数和无关工具不误触发。
- Prompt Injection、间接注入、凭据、恶意链接和越权请求。
- 私聊 / 群聊隔离、普通群消息忽略和群权限。
- 重复 Event ID、快速连续消息、取消、重连和顺序。
- 429 / timeout / 5xx、fallback、空响应和超长响应。
- Token、费用和 P50 / P95 延迟。

F5.4 已加入第一版确定性评测集 `server/internal/fairy/testdata/eval/v1.json`，F5.5 扩展为 74 条 Gate、安全、工具意图、Planner Decision、媒体边界和行为经验召回样例。严格 JSON loader 会拒绝未知字段、重复 ID 和尾随值。F5.9 另加入候选模型质量集 `server/internal/fairy/testdata/quality/v1.json`，通过 OpenAI-compatible 或 Anthropic-compatible Adapter 实际检查中英文、身份、Prompt Injection 和原生 Tool Call，并对 P95、Token 和可选成本执行机器可判定门禁。

质量报告只允许固定 Case ID、通过状态、固定失败码、调用次数、延迟、Token 和可选费用；Prompt、模型正文、Base URL、API Key 与供应商错误正文不能进入 stdout、stderr 或报告。API Key 只能由 `FAIRY_EVAL_API_KEY` 进程环境提供。门禁退出码固定为通过 `0`、配置或运行错误 `1`、质量不达标 `2`，供本地发布流程或 CI 直接判定。

测试分层：

1. 纯单元测试：Gate、Router、Schema、Policy、Projection。
2. Fake Model / Fake Tool 的完整 Turn golden trace。
3. ZZZ Gateway + Fairy 的协议集成测试。
4. 真实供应商的受控离线 eval，不向真实用户发送。
5. `icrad.ltd` 双账号 smoke，仅使用专用测试会话。

任何跨会话泄漏、未授权副作用、重复发送或确定性命令回归都属于发布阻断问题。

## 十四、数据、配置与运维

### 1. 数据分层

- `config.json`：运行配置与只写密钥，保持 `0600` 原子替换。
- `state.json`：现有群开关、记忆开关、全局额度和按 Task 额度；继续兼容 state v1 旧文件。
- `fairy.db`：Fairy 本地 SQLite，仅保存去重和脱敏 Turn / Model / Tool / Gate Trace，默认 30 天清理，不接入 IM Server Store。
- 内存 Context Surface：默认聊天正文和在途 Tool 结果，按 TTL 清理。

使用同仓库已有 SQLite 驱动，生产机只接收本地 / CI 构建的 Linux x86-64 制品，不在生产机编译。

### 2. 配置与热更新

- 配置先完整校验，再原子生成 `RuntimeConfigSnapshot`。
- 群聊软触发默认值、Focus TTL、cooldown 和表达档位使用原子快照，对新 Turn 热更新。
- 模型路由、密钥、Prompt、工具开关和调度参数仍通过受控重启应用。
- 账号、Server URL、存储路径和进程级安全参数继续受控重启。
- 在途 Turn 固定使用创建时 snapshot。
- 每次修改保留版本、时间和脱敏审计，不返回模型密钥。

### 3. 单实例与高可用

近期保持一个 Fairy 身份一个 systemd 实例：

- `/health` 表示进程存活。
- `/ready` 表示 IM 已登录且 Scheduler 可接纳；模型未配置时仍可处于 plugin-ready。
- 停止时先关闭 admission，再 drain 或取消 Turn，最后断开 WebSocket。
- 备份配置、状态和 Fairy 本地数据库。

在没有 bot-identity lease、共享 Inbox 和幂等出站前，不运行同一 Fairy 账号的多个副本。吞吐量出现真实瓶颈后再设计多实例。

## 十五、落地阶段

### F0：顺序、去重与 Turn Trace

状态：已完成本地实现与专项测试，尚未发布到生产环境。

- 用 Conversation Scheduler 替换消息直接 `runWorker()`。
- 实现 per-conversation FIFO、单活跃 Turn、bounded admission 和取消 / drain。
- 入站 message ID 去重。
- 增加 Trace envelope、测试用内存实现和生产 SQLite 实现；SQLite 只保存脱敏元数据。
- 将现有 `Engine.HandleMessage()` 包入 Turn，不改变现有命令和回复行为。

验收：同会话顺序稳定；达到并发上限不静默丢消息；重复事件不重复调用；重启无遗留 worker。

### F1：Model Router（进行中，核心实现已完成）

- 已完成 Provider / Model / Task 配置、v1 旧配置迁移和 `0600` 原子持久化。
- 已完成 OpenAI-compatible 与 Anthropic-compatible Adapter、不可变调用快照和结构化 Failure。
- 已完成可取消 Retry、`sequential` fallback、Token / cost Trace 及字段校验。
- 已完成管理面板的 Provider、Model、Task 编辑、候选模型顺序调整和只写密钥。
- MiMo `mimo-v2.5-pro` 已完成一次本地隔离回归；尚待完成 CI 制品发布、生产外部模型配置和费用预算确认。
- 管理页已增加只针对已保存 Model 的安全探测；固定 Prompt、单请求、单并发和 30 秒硬超时，不接触用户上下文且不返回模型正文。

验收：主模型故障可控切换；安全拒绝不切换；在途请求不受配置更新污染。

### F2：Tool Pipeline（已本地实现、待发布）

- 已实现 ToolSpec、不可变 Registry、严格 object Schema、Scope、Policy、可取消 timeout、输出限制和脱敏 Trace。
- `zzz-profile` 已作为低风险只读工具接入统一 Pipeline，同时保留 `/zzz` 直接命令；高置信自然语言 UID 查询使用同一路径。
- Tool Session 首版强制串行，`exclusive` 等待可取消；副作用工具必须声明幂等类型，默认策略不授权副作用。
- 已增加通用 `send_message.client_message_id`：按发送者唯一持久化，相同请求返回原消息且不再次投递，不同请求复用同一键返回冲突。
- Memory、SQLite、Postgres 实现均已完成；SQLite/Postgres 跨重启、Gateway 不重复广播和 Fairy 出站携带幂等键均有测试，CI 使用临时 Postgres 服务验证真实唯一约束。

验收：自然语言可正确调用 ZZZ 查询；无关对话不调用；timeout 和结果不确定不会重复副作用。

### F3：Planner / Replyer Agent Loop（已本地实现、待发布）

- 已实现 `call_tools`、`respond`、`wait`、`stop` 的严格 Planner Decision、OpenAI / Anthropic-compatible 原生 Tool Call，以及最多 4 Planner Step / 6 Tool Call / 单 Turn timeout。
- 普通 Chat mode 保持一次 Replyer 调用；工具意图和显式 `/fairy agent` 使用 Tool-aware Agent mode，且只有同时配置 `planner` 和 `replyer` Task 才会启用。
- Prompt 已按稳定 section ID 组装，Model Trace 使用部署 `trace.key` 记录 section 版本和内容 HMAC 而不保存正文；Context Surface 只在内存中按会话保存成功 Turn，并携带来源 message ID / 时间元数据；工具结果用不可信数据边界传递给 Replyer。
- Output Policy 已限制空响应、长度、疑似凭据、危险协议、私网/本机链接和双向文字控制符；Replyer 返回 Tool Call 会被拒绝，每 Turn 只有一个最终发送点。
- Fake Model golden trace、原生 Tool Call Provider 往返、越权工具、严格 JSON、Step 上限、额度中断、取消、输出安全和跨会话隔离测试已完成。

验收：Planner 不能绕过 Tool Pipeline；每 Turn 最多一个最终回复；跨会话隔离通过对抗测试。以上已在本地自动化测试中通过，生产模型真实质量评测和发布仍待执行。

### F4：行为与管理面板（已本地实现、待发布）

- 已实现模型前确定性 Gate、固定 `trigger / wait / ignore / reject` 与受限 reason；群聊默认 `shadow`，群管理员可按群设置 `off / shadow / on`。
- 已实现按群、按用户的 2 分钟 Focus 与软触发 cooldown；私聊、明确 @ 和指令等硬触发不受软抑制影响。
- 已加入 `brief / normal / detailed` 表达 section，并确保一个 Turn 使用同一行为配置快照。
- Context 溢出改为内存滚动摘要，摘要以 `user` 角色标记为不可信派生数据，并携带来源起止 ID 和来源数量；正文和摘要均不进入 Trace。
- 管理面板已增加 Scheduler、24 小时 Trace、Tool Policy、Gate action、Token、成本和当日逻辑调用额度，只返回聚合元数据。
- 群聊软触发默认值、Focus、cooldown 和表达档位保存后热更新；其他配置继续受控重启。受管配置升级为 v3，并兼容读取 v1/v2。

验收：每次触发或忽略可解释；默认不主动插话；管理面板不暴露聊天正文。

### F5：可选记忆与外部扩展

- 用户可查看、清除和禁用的来源化事实记忆。（事实记忆闭环已本地实现、待发布）
- 可信独立进程 / MCP Tool Provider。（F5.2 已本地实现、待发布）
- 语音、图片等独立 Task。（F5.3 核心已本地实现、待发布）
- `/health` / `/ready` 运行契约与版本化确定性 Eval Corpus。（F5.4 已本地实现、待发布）
- 行为经验只读召回。（F5.5 已本地实现、待发布）；自动反馈学习最后评估。
- 复用服务端幂等键的可靠出站投递。（F5.6 已本地实现、待发布）
- 已保存模型的安全连通性探测。（F5.7 已本地实现、待发布）
- 成功模型回复的显式赞/踩质量反馈闭环。（F5.8 已本地实现、待发布）；自动学习仍关闭。
- 版本化候选模型质量门禁。（F5.9 已本地实现、待发布）；不使用真实用户数据。
- 管理页异步质量评测任务。（F5.10 已本地实现、待发布）；只使用已保存模型配置。
- 按 Task、Provider 和 Model 聚合的 24 小时健康观测。（F5.11 已本地实现、待发布）；只读取脱敏 Model Attempt Trace。
- 最近 24 小时 Model、Tool、Admission 和 Turn 脱敏失败摘要。（F5.12 已本地实现、待发布）；最多 20 条且不返回可关联身份。
- 配置 revision、生效状态与脱敏变更审计。（F5.13 已本地实现、待发布）；区分期望配置与实际运行配置。
- 旧版单模型环境变量支持 `FAIRY_MODEL_PROTOCOL`，可直接选择 OpenAI-compatible 或 Anthropic-compatible Provider（F5.14）。

### 发布状态（2026-09-03）

F0-F5.14 已随提交 `a787ce8` 推送并部署到 `icrad.ltd`。本地静态 Linux x86_64 构建、Alpine SQLite/Fairy lifecycle smoke、GitHub Actions CI/CD（Go、Flutter/PWA、Docker、Pages）和远端 `/ready`、管理 API schema v7 验收均通过。生产 Fairy 当前保持无模型配置；MiMo `mimo-v2.5-pro` 只作为隔离候选模型完成质量评测，未写入生产环境。

F5.15 完善连接恢复退避：拨号或认证持续失败仍按指数退避并封顶；已完成认证的会话断开后，下一次重连从最小延迟重新开始，避免历史故障延迟短暂断线恢复。退避倍增在到达上限前显式截断，避免时长溢出。提交 `5778987` 已通过 CI/CD、本地静态制品 smoke 和生产部署验收；生产日志确认已认证连接断开后按最小 `2s` 重连。

F5.16 将好友请求与不可重放的聊天事件分开处理：聊天 Event ID 继续持久去重；好友请求由 IM Server pending 列表提供权威状态，Fairy 进程内只合并同一 flag 的并发处理，并在认证后及在线周期内补偿同步。接受动作失败后会释放占位，允许后续重新提交，避免“先认领、后失败”导致请求永久滞留。

事实记忆第一阶段只接受用户或群管理员通过指令显式写入，不做模型自动抽取。正文保存在 Fairy 独立的 `facts.db`，默认关闭，私聊按用户与会话双重隔离、群聊按群隔离；每条记录来源消息、创建和过期时间，支持分页查看、逐条删除和全部真实删除。召回内容以 `user` 角色的不可信 JSON 注入，不参与 system Prompt HMAC，不写入 Trace，管理页只展示聚合数量。

F5.2 使用官方 Go MCP SDK 启动管理员预装的可信 stdio Provider。配置只允许绝对命令路径、参数数组、工作目录、环境变量名称 allowlist 和工具 allowlist，不允许 shell 拼接或网页上传代码；环境变量值不进入配置 API。只有明确只读、非破坏且 Schema 兼容的工具才注册到统一 Tool Pipeline。timeout 或协议错误关闭子进程并打开熔断，Provider 故障不阻止 Fairy 启动；stderr、命令参数和工具正文不进入管理运行态。

F5.3 增加 `vision` 与 `transcriber` 两个独立 Task。服务端媒体只允许同源 `/files/`，外部只接受经过 DNS、实际拨号、重定向和私网地址检查的 HTTPS 图片；随后继续校验字节上限、MIME、文件签名和图片解码尺寸。最多处理 4 张图片或 1 条语音，禁止图音混发。`vision` 使用校验后图片的内联 data URL，`transcriber` 使用 multipart；两者沿用 Model Router 的 timeout、Retry、fallback 和脱敏 Trace。

媒体派生正文只作为明确不可信的 `user` 数据交给 Replyer，不进入 Planner，即使已配置外部 MCP 也不能由图片文字或转写触发工具。事实召回在任何媒体下载和模型调用前 fail closed；疑似凭据的派生正文会终止 Turn，且不会进入上下文。媒体 URL、原始字节和派生正文均不写入 Trace；成功 Turn 的不可信媒体结果只按现有 TTL 保留在内存 Context Surface。全局与 Task UTC 日额度在同一状态写入中原子扣减；v1-v4 受管配置中缺少的 Task 额度自动继承全局额度。视频、普通文件、批量 OCR 和自动学习仍未进入实现。

F5.4 将存活和就绪语义拆开：`/health` 在进程 HTTP 服务存活时始终返回 `200`，`/ready` 只有在 IM 已登录且 Scheduler admission 开启时返回 `200`，连接中或 draining 返回 `503`。部署脚本和 Linux smoke 只以 `/ready` 作为切流门槛。第一版确定性 Eval Corpus 与代码一同版本化并进入普通 Go 测试及 Alpine 全量 Fairy 测试；中文凭据标签和 OpenAI、GitHub、Slack、AWS 高置信 Token 前缀也纳入输入与输出拦截回归。

F5.5 增加管理员审查的只读行为经验：最多配置 64 条，每条最多 12 个关键词，并限定 `all / private / group` 作用域。召回只匹配本次用户原始文本，按关键词命中数、最长关键词和稳定 ID 排序后取最多 3 条；图片描述和语音转写不能触发。选中内容作为明确 advisory JSON 进入 Planner / Replyer 的独立 Prompt section，不携带关键词或 scope，不进入 Trace；模型和聊天没有写入接口，`auto_learning` 固定为 false。受管配置升级到 v6，兼容读取 v1-v5，经验修改采用受控重启。

同阶段 Model Router 增加 Anthropic-compatible Messages Adapter，覆盖 system 提升、图片 base64、`tool_use / tool_result`、Token、停止原因和失败分类；Provider 返回的 `thinking / redacted_thinking` 块不会成为回复或上下文。`transcriber` 仍只允许 OpenAI-compatible Provider。MiMo `mimo-v2.5-pro` 已用专用本地配置完成 5 次隔离 Eval，验证中英文、身份、Prompt Injection 和原生 Tool Call；生产环境仍未启用模型。

F5.6 将 Engine 的出站消息统一交给 Runner 生命周期内的可靠投递器。逻辑回复只生成一次随机 `client_message_id`；确认超时、响应解码失败或连接断开属于结果未知，可在同一连接或下一条已认证连接上重试，最多 3 次。收到服务器 API 错误属于明确失败，不重试。管理运行态只显示成功、重试、失败和结果未知的进程内累计数量，不包含消息正文、会话或账号标识。

F5.7 为已保存的单个 Model 增加安全连通性探测。管理员只能提交 `model_id`，服务端使用固定的无用户数据 Prompt，最多 256 个输出 Token、单次供应商请求、全进程单并发和 30 秒硬超时；聊天、事实记忆、行为经验、工具和会话标识都不进入请求。探测不占聊天日额度且不写 Trace，但会产生真实供应商费用。管理结果只包含协议、Model / Provider ID、延迟、Token、估算费用、固定失败分类和 HTTP 状态，不包含模型回复或供应商错误正文。MiMo 复测表明 64 Token 仍可能全部用于 `thinking` 而没有可见文本；调整为 256 Token 后，Fairy 自身探测约 2.7 秒完成，使用 25 input / 48 output tokens。

F5.8 只为已经获得 IM Server `message_id` 的成功模型最终回复登记反馈资格。`👍` 使用稳定 Reaction ID `76`，`👎` 使用 `fairy-negative`；其他 Reaction、Fairy 自己的 Reaction、命令、插件直出、错误和限流回复均忽略。同一输出和评价者只保留一个标签，改评覆盖，取消只删除当前匹配标签，旧标签的迟到删除不能误删新标签；回复 Recall 会删除资格映射并级联删除评价。

反馈表只保存部署 HMAC 密钥生成的输出消息引用和评价者引用、随机 Turn ID、`positive` / `negative` 标签及时间，默认 30 天清理。原始 message/user/conversation ID、回复正文和会话正文都不落盘，管理 API 只返回最近 24 小时已评价回复数、赞、踩和正向率聚合。该信号当前只用于人工质量观察，不允许自动改写行为经验、Prompt、模型路由或工具策略。

F5.9 增加独立 `fairy-eval` 命令和严格版本化质量语料。每次运行只向指定候选模型发送固定合成 Prompt，不读取聊天、事实记忆、行为经验、Trace 或生产配置；同一套 Runner 支持 OpenAI-compatible 与 Anthropic-compatible，并汇总真实未截断延迟、尝试次数、Token 和可选费用。MiMo `mimo-v2.5-pro` 已在本地通过 5/5 Case：1256 input / 403 output tokens，P50 约 3.3 秒、P95 约 6.9 秒；套餐单价未知，成本门禁保持关闭。该结果不授权生产启用模型，生产提升仍需要已批准的配置、预算和发布流程。

F5.10 将 F5.9 Runner 接入 Fairy 管理面板。管理员只能对已保存的 Model 启动异步固定 5 Case 任务；任务使用启动时的配置快照，随 Fairy 进程生命周期取消，并与 F5.7 连通性探测共享单一诊断槽。管理 API 只保留最近任务，输出任务状态、Model 配置 ID、固定 Case 状态/失败码、P50/P95、汇总 Token 和可选费用；Provider、远端模型名、逐请求尝试/延迟/费用、Prompt、正文、URL、密钥和供应商错误均不进入该投影。

F5.11 复用 `model_attempt` 脱敏 Trace，在读取最近 24 小时运行态时按 `task_id + provider_id + model_id` 单遍聚合 attempts、completed、failed、fallback attempts、P50/P95、输入/输出 Token、费用和固定失败码。管理页只展示这些配置 ID 与聚合值，不返回远端模型名、逐请求记录、Trace/Turn/Snapshot ID、会话身份、Prompt、正文或供应商错误；空数据稳定序列化为 `model_health: []`。该观测不新增表、不调用模型，也不改变路由或自动学习状态。

F5.12 从现有脱敏 Trace 投影最近 24 小时最多 20 条失败摘要，按事件时间和本地序号倒序稳定排列，覆盖 Model failure、Tool failure、Admission rejection 和 Turn timeout。投影只允许固定失败码、Task / Provider / Model / Tool 配置 ID、耗时、attempt / step / fallback 与有限队列数字；存量 Tool payload 必须通过严格字段校验，非法记录 fail closed。管理 API 不返回 Trace / Turn / Snapshot / Tool Call ID、会话标识、正文、Prompt、工具参数或供应商错误，空数据稳定序列化为 `recent_failures: []`。管理页使用独立横向滚动表格展示这些摘要；该功能不新增表、不调用模型，也不改变路由、行为经验或自动学习状态。

F5.13 将受管配置升级到 v7，并兼容读取 v1-v6。每次成功保存生成单调递增 revision、UTC 更新时间和固定分类审计；ConfigManager 分别维护期望配置与 active 配置，热更新成功后才确认 active revision，需要重启的变更在新进程实际加载前保持 `restart_pending`。管理 API 只暴露 schema、期望/生效 revision、`active / applying / restart_pending` 状态和最近 50 条变更分类；审计不保存或返回配置值、Prompt、URL、密钥和用户身份。非法 v7 revision 或审计元数据会 fail closed，避免篡改后的配置被静默接纳。

验收：记忆可追溯和删除；外部插件故障不拖垮主进程；未授权能力不可见。

## 十六、必须保持的不变式

1. IM Server 不运行模型或 Fairy 插件，也不持有模型密钥。
2. 同一 conversation 同时最多一个活跃 Turn。
3. 重复入站 Event ID 不产生第二次模型调用或副作用。
4. 所有副作用只经过 Tool Pipeline 或 Output Policy。
5. 在途 Turn 始终使用同一配置和 Provider snapshot。
6. 已经开始的副作用工具不会因 Retry 或重启自动重放。
7. 默认不持久化聊天正文，也不允许跨会话共享 Context。
8. 群聊未明确触发的普通消息默认不进入模型上下文。
9. 管理 API 和 Trace 永不回显密钥、Cookie 或完整敏感参数。
10. Scope 只控制能力可见性；不可信插件必须进程或沙箱隔离。
11. 生产机不编译源码，只运行本地 / CI 产物。
12. 未通过安全、顺序、重复发送和跨会话隔离 eval，不启用生产 AI。
13. 媒体 URL、原始字节和模型派生正文不进入 Trace，媒体派生内容不能进入 Planner 或触发 Tool。
14. 行为经验只能由管理员显式维护，模型与聊天不能写入；媒体派生文本不能触发经验召回。
15. 同一逻辑回复的所有发送尝试必须复用同一个 `client_message_id`；进程重启不能自动重放回复正文。
16. 显式质量反馈只能作为脱敏观测信号；原始身份和正文不得落盘，也不得直接触发自动学习或运行配置变更。
17. 好友请求接受失败不能因入站去重永久丢失；只有 IM Server 的 pending 状态决定是否还需重试。
18. Model health 只能由已校验的固定字段 Trace 聚合；观测结果不得反向改变路由、行为经验或自动学习状态。
19. Recent failures 只能投影固定字段且最多保留 20 条；任何非法存量字段必须 fail closed，不能通过失败详情恢复用户、会话、正文、Prompt、工具参数或内部 Trace 标识。
20. 配置 revision 只有在对应运行快照实际生效后才能成为 active revision；审计只允许固定分类，不能记录配置值或身份信息。

## 十七、当前尚需产品确认

架构本身已经可以开始 F0；以下决策在对应阶段前确认即可：

1. 生产模型供应商、候选模型和月度费用上限。
2. 输入 / 输出内容安全采用供应商服务、本地模型还是组合策略。
3. 脱敏 Trace 的默认保留期和管理员可见范围。
4. 群聊 soft-trigger 是否永远按群 opt-in，还是评测后允许全局默认。
5. 持久事实记忆是否进入产品，以及用户查看、导出和删除入口。
6. 哪些外部 Tool Provider 可以被视为可信，是否需要 MCP。
