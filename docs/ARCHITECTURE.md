# NekoChat 设计与实现说明

本文面向开发者，记录 NekoChat 的架构、网络协议、数据库结构与数据存储细节。面向使用者的介绍见仓库根目录的 [README](../README.md)。

## 架构概览

UI 仅调用 `AppController`，Socket 与数据库不会从 Widget 直接访问。侧栏把在线设备和历史私聊合并为“会话与设备”，同一个 `deviceId` 只显示一次。“关闭对话”仅关闭聊天面板，不会结束 session 或撤销信任。

SQLite 由 `DatabaseBackend` 接口打开。当前使用 `PlainSqliteBackend`，随机数据库密钥用于本地密码校验和未来加密后端的稳定接口；数据库文件本身尚未由 SQLCipher 加密。后续接入 SQLCipher 时只需替换 Backend，不需要改动 Repository、Service 或 UI。**不要把这一阶段误认为“SQLite 文件已加密”。**

## 目录结构

```text
lib/
├─ app/
│  ├─ app_controller.dart          # 应用级状态与业务编排（UI 唯一入口）
│  └─ neko_chat_app.dart           # 根 Widget、主题、窗口生命周期
├─ core/
│  ├─ boss_key/boss_key_service.dart          # 老板键隐藏/恢复
│  ├─ config/
│  │  ├─ app_paths.dart            # 数据目录解析与回退
│  │  └─ network_config.dart       # 端口、超时等网络常量
│  ├─ database/app_database.dart   # SQLite 打开与 Backend 抽象
│  ├─ files/
│  │  ├─ attachment_path.dart      # 附件相对/绝对路径解析
│  │  ├─ content_hash.dart         # SHA-256 内容哈希
│  │  └─ open_path.dart            # 打开文件/所在目录
│  ├─ fonts/
│  │  ├─ bundled_fonts.dart        # 注册随包 assets/font 下的字体（可选自带）
│  │  └─ installed_fonts.dart      # 运行时检测系统已安装字体
│  ├─ identity/
│  │  ├─ database_key_provider.dart  # 口令派生 KEK、封装数据库密钥
│  │  └─ identity_service.dart       # 身份创建与解锁
│  ├─ models/models.dart           # 领域模型
│  ├─ networking/
│  │  ├─ discovery_service.dart    # UDP 组播/广播在线探测
│  │  └─ chat_transport.dart       # WebSocket 聊天 + HTTP 文件流
│  ├─ notifications/               # 独立窗口通知与系统通知
│  ├─ protocol/protocol.dart       # 统一信封编解码、口令配对证明
│  └─ single_instance/single_instance_service.dart  # 单实例/多实例控制
├─ features/
│  ├─ chat/                        # 会话外壳、群信息、@提及、消息编辑器、拖放
│  │  ├─ chat_state_machine.dart   # 邀请/会话状态机
│  │  └─ main_shell.dart           # 侧栏 + 聊天主界面
│  ├─ common/smooth_dialog.dart    # 通用对话框动画
│  ├─ dev_preview/                 # 组件预览开发模式
│  ├─ onboarding/auth_page.dart    # 首次创建身份 / 解锁
│  └─ settings/settings_page.dart  # 设置页（在线探测、口令、接收上限等）
├─ main.dart                       # 正式入口
└─ main_preview.dart               # 组件预览入口

windows/runner/                    # Windows 原生 runner（C++）
├─ notification_window.*           # 独立通知弹窗
├─ single_instance.*               # 单实例互斥
└─ view_drop_target.*              # 每个视图单独的 OLE 拖放目标
```

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

入站消息在写入数据库前会做字段校验：昵称不超过 32 个字符、群名不超过 40 个字符、文本消息不超过 10000 个字符。附件只有在接收方自动接收或手动同意后才下载，下载流严格限制为发送方声明的字节数。

发现来源 IP 只取 `Datagram.address`，聊天来源 IP 只取 Socket 的 `remoteAddress`。

### 口令配对

口令添加时，`chat_request` 会携带 `viaPairingCode` 与口令证明 `pairingProof = sha256(口令 | requestId | 接收方设备号)`；接收方用自己的口令秘密重算比对，相符即视为“口令申请”，可穿透接收方的“屏蔽加好友申请”。口令只是“该不该让这条申请进来”的凭证，不是密码学身份证明；是否建立会话仍由接收方点“通过/拒绝”决定。

口令本身是**随机生成、本地保存、可随时重新生成**的秘密，明文不随公告传输，仅广播其哈希 `sha256(口令+设备号)` 供对方本地匹配。注意：口令短到能口头报读，其哈希对有心人可离线暴力破解，故只防随意窥探、不是密码学级凭证，怀疑泄露可重新生成。

## 数据库 Schema

- `local_identities(device_id, display_name, created_at, last_login_at)`
- `trusted_peers(device_id, display_name, last_known_ip, verified_at, blocked)`
- `chats(chat_id, peer_device_id, peer_display_name, session_id, state, created_at, last_message_at, unread_count, last_message_preview)`
- `messages(message_id, chat_id, group_id, sender_device_id, content, timestamp, status, kind, file_name, file_path, file_size, mime_type, transfer_id, file_hash, reply_to_message_id, reply_to_sender_id, reply_to_preview, mentions)`
- `groups(group_id, name, owner_device_id, created_at, last_message_at, unread_count, last_message_preview)`
- `group_members(group_id, device_id, display_name, role)`
- `group_invites(invite_id, group_id, inviter_device_id, status, created_at)`
- `settings(key, value)`

## 数据存储与搬迁

数据与程序放在一起，默认保存到 `<程序目录>/neko_chat_data/`：

- `database-key.json`：PBKDF2-HMAC-SHA256 派生 KEK、AES-256-GCM 封装后的数据库密钥
- `neko_chat.db`：身份、信任、会话、消息和群组
- `received_files/`、`received_images/`：接收到的附件
- `profile/`、`avatars/`：本机头像与其他设备同步过来的头像

把这个文件夹连同程序一起拷到别的电脑即可带走全部数据。侧栏底部的“数据文件夹”会显示当前路径，点击可直接打开该目录。文件夹不能叫 `data`，那是 Flutter 存放 `flutter_assets` 的目录。

如果程序目录不可写（例如安装到 `C:\Program Files` 且当前用户没有提权），会自动回退到系统的 Application Support 目录，程序仍可正常运行。首次使用程序目录时，若发现旧版本留在 Application Support 中的身份和聊天记录，会把密钥和数据库拷贝过来，原目录保留不删。

开发时 `flutter build windows` 的产物在 `build\windows\x64\runner\Debug\`，所以调试数据也在那里，`flutter clean` 会一并清除；发布时把整个 Release 目录打包分发即可。

附件在数据库里保存的是相对数据目录的路径（例如 `received_images/ab12….png`），所以把数据目录整体搬到另一台电脑、或换到别的盘符后，历史附件依然能打开。升级前写入的绝对路径可以继续正常使用。

发送时你自己挑选的原始文件位于数据目录之外，无法用相对路径表达，仍按绝对路径记录。换机后这类记录会失效，聊天里会直接显示“原始文件不在原位置，无法帮你找到”，并提供“重新指定文件”按钮让你把该条记录重新指向本机的文件；数据目录内的副本若被删除或移动，则提示“本地文件已被移动或删除，无法打开”。重新指定后按新位置解析，若指向数据目录内还会自动改为相对路径，之后再搬迁依然有效。

## 字体加载

应用不把字体写死在包里，运行时按三级优先级决定用哪款字体：**随包字体 > 系统已安装字体 > 系统默认**。

- 随包字体：`assets/font/` 已在 `pubspec.yaml` 中登记为打包资源目录。编译前把字体 `.ttf` 放进去就会一起打包，启动时由 [`bundled_fonts.dart`](../lib/core/fonts/bundled_fonts.dart) 用 `FontLoader` 按真实族名注册。
- 系统已安装字体：未随包时，[`installed_fonts.dart`](../lib/core/fonts/installed_fonts.dart) 扫描系统 Fonts 目录按文件名检测是否安装，命中则直接引用系统字体。
- 以上都没有则回退系统默认。

设置页的字体下拉只列出当前可用（随包或已安装）的字体。可识别的文件名前缀：`lxgwwenkai` / `misans` / `vivosans` / `googlesans` / `jetbrainsmono`。

## 组件预览与联调

组件预览开发模式展示所有组件并支持 Flutter 热重载 `r` / 热重启 `R`，不占用本地数据库与网络端口：

```powershell
flutter run -d windows -t lib/main_preview.dart
# 若已有 NekoChat 实例正在运行，可附加多实例参数并行启动预览：
flutter run -d windows -t lib/main_preview.dart -a --allow-multiple-instances
# 或通过编译宏启动：
flutter run -d windows --dart-define=COMPONENT_PREVIEW=true
```

机房联调时至少使用两台电脑，并确认它们在同一局域网、Windows 网络类型为“专用网络”，且 UDP 23332 与 TCP 23333 未被防火墙拦截。

## 实现顺序

1. 模型、身份、密钥提供者与数据库
2. 协议信封、口令配对与会话状态机
3. UDP 发现与在线状态
4. WebSocket 传输和邀请流程
5. 私聊历史、关闭与黑名单
6. 群邀请、成员管理与 fan-out 消息
7. Material 3 桌面界面
8. 静态分析、单元测试、Windows 构建和双机联调

## 能力边界

当前版本是纯实时 LAN Chat：对方离线时消息标记失败，不做离线队列。附件也只在发送方在线且邀请有效时可接收，不提供断点续传。未实现公网服务器、账号系统、TLS、E2EE、云同步、NAT 穿透、语音和视频。
