# ZZZ Term 客户端对接说明

本文是 ZZZ Term 桌面客户端接入 ZZZ IM Server 的协议约定。ZZZ Term 是“执行端”，Fairy 或其他账号是“请求端”。IM Server 只负责认证、转发、持久化消息和校验边界，不连接 SSH、不选择凭据、不执行命令。

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

认证成功的 `response.data` 至少包含 `user_id`、`nickname`、`avatar_url`；使用密码登录时会额外返回新的 `session_token`。登录、注册和退出也可以使用短连接执行同样的 `auth`、`register`、`logout` action。收到 `post_type=notice` 且 `notice_type=friend_presence` 时，可更新 Fairy 或联系人在线状态。

连接建立后每 30 秒发送：

```json
{"action":"ping","params":{},"echo":"ping-<id>"}
```

收到相同 `echo` 的 `status=ok` 后保活。断线时指数退避重连；所有 action 都应使用唯一 `echo`，并为未完成请求设置超时。

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
2. 显示明确的 Allow / Deny 审批卡。未得到用户明确 Allow 前，不读取主机、不执行命令。
3. `run_command` 只能匹配当前客户端已经连接的 SSH 会话和完全相同的 `host_id`；不得因为请求自动新建连接、选择凭据或跳过主机密钥校验。
4. 无论拒绝、过期、执行失败还是成功，都回传一个对应的 `terminal_result`，并复用 `request_id`。

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

服务端 `/admin/` 新增 **ZZZ Term** 页面，接口为 `GET /admin/api/terminal?limit=200`。它显示最近请求/结果、状态、主机 ID、账号和有限输出，以及 vault 的 revision、更新时间和大小。该接口需要管理员 session；不会返回 vault payload，也不代表当前在线主机清单。真正的主机列表和 Allow/Deny 操作始终属于 ZZZ Term 客户端。
