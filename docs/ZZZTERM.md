# ZZZ Term 客户端对接说明

本文是 ZZZ Term 桌面客户端接入 ZZZ IM Server 的协议约定。ZZZ Term 是“执行端”，本地 Agent 是默认请求编排端，Fairy 或其他账号是可选的远程请求端。IM Server 只负责认证、消息持久化、实时投递和校验协议边界，不连接 SSH、不选择凭据、不执行命令，也不参与 Agent 路由。

## 1. 连接与认证

生产环境 WebSocket 地址为：

```text
wss://icrad.ltd/im/ws
```

自部署环境使用对应的 `/im/ws` 路径；不要把地址、管理 token 或账号密码放到公开登录页 URL 参数中。

ZZZ Term 使用普通 ZZZ IM 账号登录。第一次登录使用账号密码，服务端返回持久 session token；之后只保存 session token，并在每次 WebSocket 连接发送 `auth`：

```json
{
  "action": "auth",
  "params": {
    "session_token": "<session-token>",
    "user_id": "<user-id>",
    "device_id": "zzzterm-<stable-device-id>"
  },
  "echo": "auth-1"
}
```

认证成功的 `response.data` 至少包含 `user_id`、`nickname`、`avatar_url`；使用密码登录时会额外返回新的 `session_token`。登录、注册和退出也可以使用短连接执行同样的 `auth`、`register`、`logout` action。账号密码短连接使用临时 `pwa-*` 设备标识，不计入 ZZZTerm 在线审计；只有随后带 `zzzterm-*` 稳定设备标识的长连接才创建终端登录记录。收到 `post_type=notice` 且 `notice_type=friend_presence` 时，可更新 Fairy 或联系人在线状态。

连接建立后每 30 秒发送：

```json
{"action":"ping","params":{},"echo":"ping-<id>"}
```

收到相同 `echo` 的 `status=ok` 后保活。断线时指数退避重连；所有 action 都应使用唯一 `echo`，并为未完成请求设置超时。

ZZZTerm 的本地 Agent 设置保存在客户端：协议可选 OpenAI-compatible 或 Anthropic-compatible，Base URL、模型 ID 和 API Key 由用户在 ZZZTerm 设置中管理。API Key 只能进入系统安全存储，不写入 IM 消息、terminal vault、日志或服务端配置。

## 2. 消息接收与发送

收到消息事件的通用形状：

```json
{
  "post_type": "message",
  "message_type": "private",
  "message_id": "msg_...",
  "conversation_id": "private_fairy_alice",
  "sender": {"user_id":"fairy","nickname":"Fairy","avatar_url":"..."},
  "message": [{"type":"terminal_request","data":{}}],
  "timestamp_ms": 1760000000000
}
```

发送结果使用普通 `send_message` action：

```json
{
  "action": "send_message",
  "params": {
    "conversation_id": "private_fairy_alice",
    "client_message_id": "zzzterm-<request-id>-result",
    "message": [
      {"type":"text","data":{"text":"命令执行完成"}},
      {"type":"terminal_result","data":{
        "request_id":"term-...",
        "status":"completed",
        "output":"up 3 days",
        "exit_code":0
      }}
    ]
  },
  "echo": "send-1"
}
```

服务端会按“发送者 + `client_message_id`”去重。网络超时重试时必须复用相同的 `client_message_id`，不要生成第二条结果。`terminal_result` 只允许私聊。

本地 Agent 写入共享历史时会在消息段前添加：

```json
{"type":"agent_route","data":{"route":"local","role":"assistant"}}
```

`role` 可为 `user` 或 `assistant`。该标记只用于历史归属和防止服务端 Fairy 重复处理，不是服务端命令路由；消息仍按普通 IM 消息保存和投递。

ZZZTerm 的聊天输入框不提供“创建自定义气泡”入口。ZZZTerm 本地 Agent 根据模型输出选择普通文本或受控 `dynamic_content`：Markdown 节点可承载表格、代码块和长文本，`card`、`column`、`row`、`progress` 等节点用于结构化和可折叠的展示。只有 Fairy（远端 Fairy 或 ZZZTerm 本地 Agent）可以在 Agent 会话中产生这类卡片；ZZZ IM 仍允许群主和群管理员通过自己的气泡编辑器创建 `source: "user"` 卡片。

### 2.1 Dynamic Content 气泡

聊天消息可以包含一个受控的 `dynamic_content` 段。它不是新的消息系统，而是现有气泡中的一种内容：

```json
{
  "type": "dynamic_content",
  "data": {
    "id": "diagnosis-1",
    "version": "1.0",
    "source": "ai",
    "tree": {
      "id": "root",
      "type": "column",
      "children": [
        {"id": "state", "type": "status", "props": {"text": "检测中"}},
        {"id": "retry", "type": "button", "props": {"text": "重新检测"}, "events": {"click": {"action": "retry"}}}
      ]
    }
  }
}
```

通过 ZZZ IM 聊天输入框创建的自定义气泡必须使用 `source: "user"`，且仅群主和群管理员可以发送。客户端只在权限已确认时显示创建入口，服务端在 `send_message` 处再次校验；普通成员即使绕过客户端直接提交也会被拒绝。`source` 为 `ai`、`system`、`plugin` 或 `server` 的内容沿用各自产生方的权限和投递路径，不受这条用户创建限制。

`tree` 只能描述 JSON/DSL 组件，客户端通过本地 Component Registry 渲染；服务端和客户端都会限制节点数、树深、文本长度、事件类型及图片 URL（仅 HTTPS）。已知字段的类型不符时整段视为无效，不能静默转成空属性。任何未知组件或无法解析的树都会优先显示 `fallback.content`，没有可用 fallback 时显示通用的不支持提示；两种情况都不会执行 Dart、Flutter 或脚本代码。

动态内容的局部变化使用 `dynamic_update` 段。它通过稳定的 `message_id`、`content_id` 和节点 ID patch 更新原消息，不会新增历史消息：

```json
{
  "type": "dynamic_update",
  "data": {
    "message_id": "msg_123",
    "content_id": "diagnosis-1",
    "patches": [
      {"operation": "update", "node_id": "state", "props": {"text": "完成"}}
    ]
  }
}
```

当内容结构整体变化时使用 `dynamic_replace`。替换必须保留相同的 `content_id`，并携带一份完整且通过校验的 Dynamic Content schema；消息 ID、文本段和同一消息中的其他内容不会变化：

```json
{
  "type": "dynamic_replace",
  "data": {
    "message_id": "msg_123",
    "content_id": "diagnosis-1",
    "content": {
      "id": "diagnosis-1",
      "version": "1.0",
      "source": "ai",
      "fallback": {"type": "text", "content": "诊断已完成"},
      "tree": {
        "id": "root",
        "type": "card",
        "props": {"title": "诊断完成"}
      }
    }
  }
}
```

当需要移除一个 Dynamic Content、但保留原消息和其他内容时使用 `dynamic_remove`：

```json
{
  "type": "dynamic_remove",
  "data": {
    "message_id": "msg_123",
    "content_id": "diagnosis-1"
  }
}
```

`dynamic_update`、`dynamic_replace` 和 `dynamic_remove` 都是对已有消息的变更，不会创建新的历史消息。服务端会把变更广播给具备相应能力的实时客户端，并把变更后的完整消息用于历史读取；不支持 Dynamic Content Operations 的旧客户端不会收到无法解释的变更段。

服务端校验并持久化更新后的原消息，然后向会话中的所有设备广播该 patch；离线客户端在历史加载时直接得到更新后的完整 `dynamic_content`。`dynamic_event` 仅携带组件交互事件，`payload` 必须是 JSON 对象。事件经过服务端校验后只向实时连接分发，不会产生空白历史消息；发送设备本身不重复收到，但同一账号的其他设备仍会收到，因此 ZZZ IM 可以把交互交给在线的 ZZZTerm 执行端。事件必须匹配目标 Bubble 中已声明的节点和 action，不能伪造任意工具调用。

交互卡片采用“事件账本与状态投影分离”的持久化约定：

1. 客户端提交 `dynamic_event`，服务端校验目标节点/action、权限和策略，并把事件写入独立账本；通用卡片不会额外产生普通聊天审计气泡。
2. 事件账本按 `(actor_id, event_id)` 幂等。客户端应为每次点击生成稳定的 `event_id`，网络重试复用同一个 ID；`counter`、`append` 等允许多次响应的 reducer 不会因为内容相同而丢弃合法事件。
3. 服务端根据 reducer 从账本重算 `metadata.interaction_state`，通过 `dynamic_replace` 更新原 Bubble。投票更新选项计数和 `progress.value`，群通知更新已阅人数，命令审批更新 `approved`、`denied` 或 `modified`；Fairy 路由由 `routing.fairy` 明确控制。

事件账本和原 Bubble 的状态投影由服务端在同一存储事务中提交；如果投影校验或数据库更新失败，事件不会单独落库。这样客户端可以安全地复用同一个 `event_id` 重试，不会出现“响应已记录但卡片仍显示旧状态”的半完成结果。

卡片行为在 `metadata.interaction` 中声明：`reducer` 可取 `set_by_actor`、`append`、`counter`、`checklist`、`form`、`approval_quorum`、`state_machine` 或 `none`；`policy` 支持 `response`、`allow_change`、`visibility`、`expires_at_ms`、`audience`、`allow_agent`、`total`、`quorum`、`veto` 和状态转换；`routing.fairy` 可取 `manual`、`each_event`、`on_close`、`on_threshold`；`projection` 指定进度和状态节点。旧版 `kind/total/progress_node_id/status_node_id/close_on_response` 字段继续兼容。

动作进度投影是通用能力，不属于审批专属。事件定义可以在顶层或 `projection` 中声明：`progress`/`progress_value` 为绝对进度，`progress_delta`/`increment` 为增量，`progress_node_id`/`progress_target` 指定目标进度节点，`total` 用于把一次动作归一化为 `1/total`。因此 `set_property`、`toggle`、`mark_read`、业务自定义动作以及 `set_status`/审批动作都可以推进进度；动作名称本身不会触发进度。未声明这些字段的旧 `set_status` 和审批卡片继续按旧规则推进一步。客户端和服务端使用相同的声明计算投影，保证即时反馈与持久化结果一致。

详情通过 `get_dynamic_interactions` 查询。服务端按 `visibility` 过滤参与者、payload 和事件明细后才返回客户端：`public_aggregate`、`anonymous_aggregate` 只返回聚合状态，`public_detail` 返回公开明细，`admin_detail` 只对群主/管理员和卡片作者开放，`actor_only` 只返回当前用户的记录。客户端不得根据隐藏字段自行推断参与者。

这样所有成员看到的是同一个持久化 Bubble 状态，而不是各设备各自的临时按钮状态。交互结果可以由 Fairy、ZZZTerm 本地 Agent 或管理员继续消费；命令执行仍必须回到 ZZZTerm 本地 Allow/Deny 审批边界，服务器不执行命令。

需要支持网络重试的动态更新应额外携带 `client_message_id`（沿用发送者维度的 1-128 位客户端请求 ID）：

```json
{
  "client_message_id": "zzzterm-update-<operation-id>"
}
```

服务端会按“发送账号 + `client_message_id` + 更新请求指纹”做幂等处理。相同 ID 和相同 patch 的重试只返回原更新结果，不会再次应用 `create/remove` 或重复广播；相同 ID 对应不同 patch 会返回冲突错误。客户端重试时必须复用原 ID，新的独立更新必须生成新的 ID。

### 2.2 旧业务消息段兼容层

客户端可以通过 `ImMessageContentAdapterRegistry` 将既有业务消息段映射为 `ImDynamicContent`，再交给同一套 Component Registry 和 Runtime 渲染。该转换只发生在显示层，不修改服务端保存的原消息段，也不改变旧客户端的协议行为。

ZZZTerm 当前注册了以下适配：

| 原消息段 | Dynamic Business Component | 用途 |
| --- | --- | --- |
| `terminal_request` | `zzzterm_terminal_request` | 计划、命令修改、允许与拒绝 |
| `terminal_result` | `zzzterm_terminal_result` | 状态、退出码和折叠的终端输出 |

普通文本仍使用现有文本 Renderer。`text + terminal_request`、`text + terminal_result` 以及原生 `dynamic_content` 都由同一个 `ImMessageBubble` 组合，统一保留头像、方向、回复引用、反应、时间和发送状态。业务组件只负责气泡内部内容，不允许绕过本地命令审批或执行脚本代码。

旧 `terminal_request` 段经过 Adapter 后使用稳定的显示身份：`content_id = legacy:<message_id>:<segment_index>`，节点 ID 为 `terminal-request-<request_id>`。远端交互可用 `click/approve`、`tap/deny` 或 `change/modify` 事件组合；ZZZTerm 只接受当前账号在同一会话中的事件，并仍通过本地审批状态机执行命令。

## 3. `terminal_request` 请求段

Fairy 当前支持三种操作：

| `operation` | 必填字段 | 语义 |
| --- | --- | --- |
| `list_hosts` | `request_id`, `expires_at` | 请求客户端返回已配置主机的公开摘要 |
| `get_host` | 上述字段 + `host_id` | 请求指定主机的公开连接信息，不返回密码/私钥 |
| `run_command` | 上述字段 + `host_id`, `command` | 在已经建立的 SSH 会话执行命令 |

示例：

```json
{
  "type": "terminal_request",
  "data": {
    "request_id": "term-01J...",
    "operation": "run_command",
    "host_id": "prod-web-1",
    "command": "uptime",
    "expires_at": 1760000123456
  }
}
```

`request_id` 只能由字母、数字、`.`、`:`、`-`、`_` 组成，最长 128 字节。`command` 最长 8192 字节；服务端会拒绝包含明显密码、Token、Cookie、私钥等高风险凭据的 Fairy 命令。`expires_at` 必须在当前时间前后允许窗口内，Fairy 默认设置为 2 分钟。

客户端收到请求后必须：

1. 检查 `message_type=private`、请求来源是否为本账号授权的 Fairy、`request_id` 是否已处理以及 `expires_at` 是否仍有效。
2. `list_hosts` 和 `get_host` 是只读的主机发现操作，可由客户端自动回传公开摘要；不要因为 Fairy 在 ZZZ IM 中发起普通对话或主机查询而要求用户点击确认。
3. 只有 `run_command` 需要显示明确的 Allow / Deny 审批卡。未得到用户明确 Allow 前，不执行命令。
4. `run_command` 只能匹配当前客户端已经连接的 SSH 会话和完全相同的 `host_id`；不得因为请求自动新建连接、选择凭据或跳过主机密钥校验。
5. 无论拒绝、过期、执行失败还是成功，都回传一个对应的 `terminal_result`，并复用 `request_id`。

## 4. `terminal_result` 结果段

```json
{
  "type": "terminal_result",
  "data": {
    "request_id": "term-01J...",
    "status": "completed",
    "output": "up 3 days, 4:12",
    "exit_code": 0
  }
}
```

允许的 `status`：

| 状态 | 使用时机 |
| --- | --- |
| `approved` | 用户已 Allow，客户端开始处理（可选的中间结果） |
| `completed` | 操作完成；`output` 可包含有限 stdout/stderr 摘要 |
| `failed` | SSH 或命令执行失败；不要把私钥、环境变量或凭据放进 output |
| `denied` | 用户点击 Deny |
| `expired` | 收到时已过期或本地审批超时 |

`output` 最长 64 KiB。建议客户端在 UI 中再限制为 16 KiB 预览，并提供复制前的二次确认。结果消息中的 `text` 是给人看的摘要，结构化状态必须以 `terminal_result.data.status` 为准。

## 5. Terminal Vault

Vault 用来同步 ZZZ Term 的主机配置。它是账号级、客户端加密的 opaque envelope，服务端永远不解析：

### 读取

```json
{"action":"get_terminal_vault","params":{},"echo":"vault-get-1"}
```

成功返回：

```json
{
  "status":"ok",
  "retcode":0,
  "data": {
    "payload":"<base64-or-json-envelope>",
    "revision":3,
    "updated_at":"2026-09-04T08:00:00Z"
  },
  "echo":"vault-get-1"
}
```

没有 vault 时返回 `data: {"revision":0}`。客户端负责使用本地密钥和 AES-256-GCM（或同等强度的 AEAD）加密/解密；AAD 至少绑定 IM `user_id`、凭据种类和 envelope 版本。不要把明文密码、私钥、Cookie 或解密密钥发送给 IM Server。

### 乐观锁写入

```json
{
  "action":"put_terminal_vault",
  "params": {
    "payload":"<new-encrypted-envelope>",
    "expected_revision":3
  },
  "echo":"vault-put-1"
}
```

成功后 revision 变为 4。若返回 `retcode=409`，先重新读取当前 vault，向用户提示“其他设备已更新”，再决定合并或覆盖；不要盲目重试旧 revision。单个 payload 最大 4 MiB。

### 删除

```json
{"action":"delete_terminal_vault","params":{},"echo":"vault-delete-1"}
```

删除只会删除服务端 envelope；客户端仍应清理本地明文缓存、密钥和已断开的 SSH 会话。

## 6. 安全和生命周期要求

- ZZZ Term 不应实现服务端管理 token，也不应调用 `/admin` API。管理员页面只能查看终端活动和 vault 元数据，不能代替用户审批。
- 任何外部平台或 Fairy 产生的请求都按不可信输入处理。严格校验 schema、长度、状态转换和 request ID 幂等性。
- 默认拒绝群聊中的终端段；服务端会拒绝群聊 `terminal_request`/`terminal_result`。
- 应在本地保存最近处理过的 request ID，并在重启后避免重复执行；服务端消息历史可作为审计，但不是执行锁。
- 输出中隐藏环境变量、访问令牌、Cookie、私钥、连接字符串和个人数据；发生错误时回传固定错误分类，而不是上游库完整异常。
- 用户退出登录时撤销 session、清理 vault 本地密钥并断开 SSH。重新登录后需要重新解密或恢复 vault。

## 7. 管理面板

服务端 `/admin/` 新增 **ZZZ Term** 页面，接口为 `GET /admin/api/terminal?limit=200`。它只读显示最近 ZZZTerm 登录连接、请求/结果、状态、主机 ID、账号和有限输出，以及 vault 的 revision、更新时间和大小。该接口需要管理员 session；不会返回 vault payload，也不代表当前在线主机清单。真正的主机列表和 Allow/Deny 操作始终属于 ZZZ Term 客户端。
