# NekoChat

NekoChat 是面向 Windows 机房的 Flutter 局域网聊天工具。它不依赖中心服务器或外网，使用 UDP 发现同网段设备，并通过 WebSocket 直接发送聊天与控制消息。

## 当前 MVP

- 首次启动设置昵称、本地密码，并永久保存 UUID v4 `deviceId`
- PBKDF2-HMAC-SHA256 + AES-256-GCM 封装随机数据库密钥；密码错误不会覆盖原身份
- UDP Multicast + Broadcast 自动发现，逐个 IPv4 网卡收发，3 秒公告、10 秒离线
- 发现来源 IP 只取 `Datagram.address`，聊天来源 IP 只取 Socket 的 `remoteAddress`
- 聊天请求、双方一致的 6 位人工确认码、接受/拒绝、信任记录
- 同一设备的待处理邀请会去重；已验证设备自动恢复会话，不重复要求验证码
- WebSocket 私聊、会话校验、本地历史，以及等待接受、发送成功、拒绝和失败等消息状态
- 图片与普通文件发送：控制消息走 WebSocket，文件内容通过同一端口的 HTTP 流式传输
- 10 MB 以下附件自动接收；10 MB 及以上必须由接收方明确接受后才开始传输，单文件上限 512 MB
- `Ctrl+V` 可直接发送剪贴板中的图片或文件；普通文本仍粘贴到输入框
- 聊天文本可选择复制；图片直接内嵌显示，右键可打开原图或所在文件夹
- Windows 系统通知：聊天邀请、邀请接受、私聊消息和群聊消息；点击可回到对应会话，侧栏可发送测试通知
- 会话关闭和黑名单
- 群创建、邀请确认、在线成员 fan-out 消息
- Owner 邀请/移除成员、改名、解散；Member 退出
- 协议编解码、验证码、密码密钥封装和会话状态机测试

## 技术栈

- Flutter stable / Dart，Material 3
- `dart:io`：UDP、WebSocket 与 HTTP 文件流
- `sqflite_common_ffi`：Windows SQLite
- `cryptography`：PBKDF2、AES-GCM
- `uuid`：设备、请求、会话、消息和群 ID
- `logging`：关键网络和状态日志
- `file_picker` / `mime` / `url_launcher`：附件选择、类型识别与本地打开

SQLite 由 `DatabaseBackend` 接口打开。当前 MVP 使用 `PlainSqliteBackend`，随机数据库密钥用于本地密码校验和未来加密后端的稳定接口；数据库文件本身尚未由 SQLCipher 加密。后续接入 SQLCipher 时只需替换 Backend，不需要改动 Repository、Service 或 UI。不要把这一阶段误认为“SQLite 文件已加密”。

## 目录结构

```text
lib/
├─ app/
│  ├─ app_controller.dart
│  └─ neko_chat_app.dart
├─ core/
│  ├─ config/network_config.dart
│  ├─ database/app_database.dart
│  ├─ identity/
│  ├─ models/models.dart
│  ├─ networking/
│  │  ├─ discovery_service.dart
│  │  └─ chat_transport.dart
│  └─ protocol/protocol.dart
├─ features/
│  ├─ chat/
│  │  ├─ chat_state_machine.dart
│  │  └─ main_shell.dart
│  └─ onboarding/auth_page.dart
└─ main.dart
```

UI 仅调用 `AppController`；Socket 与数据库不会从 Widget 直接访问。侧栏把在线设备和历史私聊合并为“会话与设备”，同一个 deviceId 只显示一次。“关闭对话”仅关闭聊天面板，不会结束 session 或撤销信任。

## 网络协议

统一信封：

```json
{
  "protocolVersion": 1,
  "type": "message",
  "payload": {}
}
```

当前消息类型：

- `announce`
- `chat_request` / `chat_accept` / `chat_reject`
- `message` / `session_close`
- `file_offer` / `file_accept` / `file_reject`
- `group_invite` / `group_invite_response`
- `group_message` / `group_update`
- `group_file_offer`
- `error`

未知 `type` 被忽略；非版本 1 消息被拒绝。未建立的 `sessionId` 不会自动生成会话。发现端口为 UDP `23332`，聊天和文件服务共用 TCP `23333`。文件邀请只允许对应来源 IP 下载，成功传输后权限立即失效，未使用的邀请 10 分钟后自动过期。发现公告会从每个可用 IPv4 地址分别发送到组播地址、全局广播地址和常见机房 `/24` 定向广播地址，以兼容多网卡和不转发组播的交换网络。Windows 防火墙需要允许应用在专用网络通信。

验证码由以下输入稳定计算并格式化成 `123 456`：

```text
requestId | requesterDeviceId | recipientDeviceId
```

它只用于人工核对，不是密码学身份证明。

## 数据库 Schema

- `local_identities(device_id, display_name, created_at, last_login_at)`
- `trusted_peers(device_id, display_name, last_known_ip, verified_at, blocked)`
- `chats(chat_id, peer_device_id, peer_display_name, session_id, state, created_at, last_message_at)`
- `messages(message_id, chat_id, group_id, sender_device_id, content, timestamp, status, kind, file_name, file_path, file_size, mime_type, transfer_id)`
- `groups(group_id, name, owner_device_id, created_at)`
- `group_members(group_id, device_id, display_name, role)`
- `group_invites(invite_id, group_id, inviter_device_id, status, created_at)`
- `settings(key, value)`

应用数据位于系统的 Application Support 目录。

## 构建与测试

```powershell
flutter pub get
flutter analyze
flutter test
flutter build windows
```

运行：

```powershell
flutter run -d windows
```

机房联调时至少使用两台电脑，并确认它们在同一局域网、Windows 网络类型为“专用网络”，且 UDP 23332 与 TCP 23333 未被防火墙拦截。

## MVP 实现顺序

1. 模型、身份、密钥提供者与数据库
2. 协议信封、验证码与会话状态机
3. UDP 发现与在线状态
4. WebSocket 传输和邀请流程
5. 私聊历史、关闭与黑名单
6. 群邀请、成员管理与 fan-out 消息
7. Material 3 桌面界面
8. 静态分析、单元测试、Windows 构建和双机联调

## 明确边界

当前版本是纯实时 LAN Chat：对方离线时消息标记失败，不做离线队列。附件也只在发送方在线且邀请有效时可接收，不提供断点续传。未实现公网服务器、账号系统、TLS、E2EE、云同步、NAT 穿透、语音和视频。
