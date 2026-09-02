# Fairy Bot 服务

Fairy 是独立于 ZZZ IM 服务端运行的 Bot 进程。它使用普通账号通过 ZZZ Server WebSocket 接入；IM 服务端继续只负责账号、关系、群组、消息和通知，不持有模型密钥，也不运行 AI 推理。

## 第一阶段能力

- 首次启动使用邀请码注册 `fairy`，后续使用独立密码登录并自动重连。
- 自动接受发给 Fairy 的好友请求；成为好友后可正常私聊，也可被邀请进群。
- 私聊中的文本会直接触发；群聊只响应 `@Fairy`、`/fairy` 和 `/zzz`，不会读取普通群消息作为上下文。
- 群主和管理员可用 `/fairy on`、`/fairy off` 控制群回复，状态保存在 Fairy 自己的数据目录。
- 上下文只保存在进程内存中，默认 30 分钟过期、最多保留 12 条消息，不写入状态文件。
- 每个会话可用 `/fairy memory on|off` 单独控制临时记忆；群聊设置仅群主和管理员可改，关闭时立即清空已有上下文，插件仍可使用。
- 在调用外部模型前拦截高置信的私钥、Bearer、密码、API Key、Token 和 Cookie；被拦截内容不进入上下文、不消耗额度，也不会发送给模型供应商。
- AI 使用 OpenAI-compatible Chat Completions 接口，可按供应商动态配置；模型未配置时，帮助、群管理和 ZZZ 插件仍可使用。
- 管理后台通过回环地址代理 Fairy 自己的管理 API，可配置模型、人格、上下文、额度和已注册插件；IM 核心不执行模型或插件代码。
- AI 调用默认每天最多 200 次，计数持久化并按 UTC 日期重置。
- `/zzz <UID>` 通过 Enka.Network 查询游戏内公开展示资料，按上游 TTL 缓存；不需要也不接收米游社 Cookie。

## 指令

当服务器存在 `fairy` 账号且尚未成为好友时，客户端会在联系人页的推荐区域显示 Fairy。可以先打开带 Bot 标识的个人名片，也可以直接发送好友请求；Fairy 在线时会自动接受。成为好友后推荐项消失，Fairy 作为普通联系人显示，并可被邀请进群。

客户端默认把 `fairy` 识别为预设 Bot。其他部署可在 ZZZ Server 连接配置的 `extra.presetBotIds` 中填写账号 ID 列表，使用逗号分隔字符串或 JSON 数组；配置空数组可关闭预设 Bot 推荐。客户端只查询账号是否存在，不要求 IM 服务端增加 Bot 管理能力。

| 指令 | 作用 |
| --- | --- |
| `/fairy help` | 查看帮助 |
| `/fairy status` | 查看当前群开关和 AI 配置状态 |
| `/fairy clear` | 清除当前会话的临时上下文 |
| `/fairy privacy` | 查看上下文与外部模型隐私说明 |
| `/fairy memory on` | 开启当前会话的临时记忆；群聊仅管理员可改 |
| `/fairy memory off` | 关闭记忆并立即清除当前会话上下文 |
| `/fairy quota` | 查看今日模型调用次数和剩余额度 |
| `/fairy on` | 群主或管理员开启群回复 |
| `/fairy off` | 群主或管理员关闭群回复 |
| `/zzz <UID>` | 查询绝区零公开展示资料 |

## 构建与部署

```bash
# 同时构建 IM Server、VAPID 和 Fairy，并在本机 Linux 容器中验证 SQLite。
./deploy/zzz-im/release-native.sh build

# 提交已推送且 CI/CD 成功后，上传产物并部署；生产机不会编译源码。
./deploy/zzz-im/release-native.sh deploy root@server.example
```

统一发布脚本在远端调用底层安装脚本，创建独立的 `zzz-fairy` 系统用户、`/var/lib/zzz-fairy` 数据目录、`/etc/zzz-im/fairy.env` 密钥文件和 `zzz-fairy.service`。本地健康检查位于 `http://127.0.0.1:18081/health`，只有 Fairy 已登录 IM 时才返回 `200`。远端切换前会备份 IM/Fairy 二进制、环境文件和 systemd 单元；任一健康检查失败都会回滚。

## 模型配置

首次部署可以在 `/etc/zzz-im/fairy.env` 提供模型默认值，不要提交到仓库：

```dotenv
FAIRY_MODEL_BASE_URL=https://provider.example/v1
FAIRY_MODEL_API_KEY=replace-with-provider-key
FAIRY_MODEL_NAME=provider-model-name
FAIRY_MODEL_DAILY_LIMIT=200
FAIRY_MODEL_MAX_TOKENS=600
```

修改后执行：

```bash
sudo systemctl restart zzz-fairy
curl --fail http://127.0.0.1:18081/health
```

部署脚本会为 IM 服务与 Fairy 生成同一个本机管理令牌。登录
`/im/admin/` 后可在 `Fairy` 页面修改配置。保存后的完整可管理配置写入
`/var/lib/zzz-fairy/config.json`，文件权限为 `0600`，并覆盖对应的环境默认值。
API Key 只允许替换或清除，GET 响应和管理页面都不会回显密钥。保存成功后
Fairy 自动重启，IM 服务与 WebSocket 会话不需要重启。

管理页面只启停已经编译并注册的插件，不允许上传或执行任意代码。后续增加
MaiBot 风格插件时，需要先在 Fairy 插件注册表中声明 ID、描述、触发方式和配置
校验，再由管理页面展示。

## 主要配置

| 环境变量 | 默认值 | 说明 |
| --- | --- | --- |
| `FAIRY_SERVER_URL` | `ws://127.0.0.1:18080/ws` | ZZZ Server WebSocket |
| `FAIRY_USER_ID` | `fairy` | Bot 普通账号 ID |
| `FAIRY_PASSWORD` | 无 | 必填，8-72 字符 |
| `FAIRY_INVITE_CODE` | 无 | 仅首次自动注册需要 |
| `FAIRY_CONFIG_FILE` | `/var/lib/zzz-fairy/config.json` | 管理页面持久化配置，权限 `0600` |
| `FAIRY_ADMIN_TOKEN` | 无 | 本机管理 API 必填令牌，不向浏览器暴露 |
| `FAIRY_GROUP_DEFAULT_ENABLED` | `true` | 新群默认允许被提及时回复 |
| `FAIRY_RATE_LIMIT` | `8s` | 每用户、每会话触发间隔 |
| `FAIRY_CONTEXT_TTL` | `30m` | 内存上下文过期时间 |
| `FAIRY_CONTEXT_MESSAGES` | `12` | 每会话最多上下文消息数 |
| `FAIRY_MODEL_DAILY_LIMIT` | `200` | 每日模型调用上限，`0` 表示全部拒绝 |
| `FAIRY_ZZZ_API_URL` | Enka.Network | 必须包含 `{uid}` 的 HTTPS URL 模板 |
| `FAIRY_ZZZ_PLUGIN_ENABLED` | `true` | 内置 `zzz-profile` 插件默认开关 |

生产模型供应商、费用预算和内容安全服务尚未确定。在这些配置明确前，生产环境应保持模型变量为空，只运行无密钥的指令插件。
