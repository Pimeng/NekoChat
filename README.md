# NekoChat

NekoChat 是面向 Windows 机房的 Flutter 局域网聊天工具。它不依赖中心服务器或外网，使用 UDP 发现同网段设备，并通过 WebSocket 直接发送聊天与控制消息。

## 当前 MVP

- 首次启动设置昵称、本地密码，并永久保存 UUID v4 `deviceId`
- 左上角可更换本地自定义头像、重新设置昵称；昵称与头像变更会立即重新广播，其他设备按头像哈希按需拉取，离线设备上线后补同步
- 独立窗口：私聊和群聊都可以从侧边栏右键或会话右上角“会话操作/群聊操作”打开，群聊窗口内同样支持 @ 提及与群管理操作；支持把系统文件直接拖入并发送（Windows runner 为每个视图单独注册 OLE 拖放目标）
- PBKDF2-HMAC-SHA256 + AES-256-GCM 封装随机数据库密钥；密码错误不会覆盖原身份
- UDP Multicast + Broadcast 在后台维持在线探测，逐个 IPv4 网卡收发，3 秒公告、10 秒离线；发现到的陌生设备**静默缓存、不会自动出现在联系人列表**
- 手动添加好友：在“联系人”里点“添加好友”。输入对方的**口令**可直接匹配到对方设备发起申请，也可从附近已发现设备列表直接挑选；两种方式都只需对方点“通过/拒绝”，不再核对验证码
- 口令是**随机生成、本地保存、可随时重新生成**的秘密，设置页“在线探测”里展示；明文不随公告传输，仅广播其哈希 `sha256(口令+设备号)` 供对方本地匹配。注意：口令短到能口头报读，其哈希对有心人可离线暴力破解，故只防随意窥探、不是密码学级凭证，怀疑泄露可重新生成
- **屏蔽加好友申请**（设置页“在线探测”）：开启后忽略陌生人的加好友申请；但用你口令来加你的人、以及已验证好友不受影响。与“在线探测”总开关配合用于防骚扰
- 发现来源 IP 只取 `Datagram.address`，聊天来源 IP 只取 Socket 的 `remoteAddress`
- 聊天请求、通过/拒绝、撤回发送、信任记录
- 同一设备的待处理邀请会去重；已验证设备自动恢复会话，不重复要求确认
- 收发的聊天邀请都会在 30 秒内过期：超时后待确认卡片消失，会话回到未建立状态
- WebSocket 私聊、会话校验、本地历史，以及等待接受、发送成功、拒绝和失败等消息状态
- 图片与普通文件发送：控制消息走 WebSocket，文件内容通过同一端口的 HTTP 流式传输
- 自动接收大小上限可由接收方设置；达到上限后必须由接收方明确接受，发送端不按文件大小替接收方拦截
- `Ctrl+V` 可把剪贴板中的图片或文件加入待发送区，确认后与文字一起发送；普通文本仍粘贴到输入框
- 聊天文本可选择复制；图片直接内嵌显示，右键可打开原图或所在文件夹
- 接收图片以 SHA-256 内容哈希命名并校验；相同内容即使文件名不同也只保存一份并复用路径
- 数据（身份、密钥、聊天记录、附件）默认保存在程序目录下的 `neko_chat_data`，整个文件夹拷走即可搬迁；侧栏可显示并打开该目录
- 附件找不到本地文件时会明确提示原因，本机发出的文件还可以一键“重新指定文件”重新绑定
- Windows 系统通知：聊天邀请、邀请接受、私聊消息和群聊消息；点击可回到对应会话，侧栏可发送测试通知
- 会话关闭和黑名单；对端资料卡（头像/备注/设备 ID/网络与验证状态）可从右键菜单或会话右上角“会话操作”打开
- 群创建、邀请确认、在线成员 fan-out 消息
- Owner 邀请/移除成员、改名、解散；Member 也可邀请他人入群、退出；新成员由邀请者把最新名单同步给在线成员
- 群管理员：Owner 可设/取消管理员，管理员能移除普通成员并撤回非群主消息；群成员与群操作同时出现在侧边栏群聊右键菜单
- 老板键可设置在隐藏后是否仍弹出系统通知
- 协议编解码、口令配对、密码密钥封装和会话状态机测试

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
│  ├─ fonts/installed_fonts.dart   # 运行时检测系统已安装字体（不打包字体）
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

入站消息在写入数据库前会做字段校验：昵称不超过 32 个字符、群名不超过 40 个字符、文本消息不超过 10000 个字符。附件只有在接收方自动接收或手动同意后才下载，下载流严格限制为发送方声明的字节数。

口令添加时，`chat_request` 会携带 `viaPairingCode` 与口令证明 `pairingProof = sha256(口令 | requestId | 接收方设备号)`；接收方用自己的口令秘密重算比对，相符即视为“口令申请”，可穿透接收方的“屏蔽加好友申请”。口令只是“该不该让这条申请进来”的凭证，不是密码学身份证明；是否建立会话仍由接收方点“通过/拒绝”决定。

## 数据库 Schema

- `local_identities(device_id, display_name, created_at, last_login_at)`
- `trusted_peers(device_id, display_name, last_known_ip, verified_at, blocked)`
- `chats(chat_id, peer_device_id, peer_display_name, session_id, state, created_at, last_message_at, unread_count, last_message_preview)`
- `messages(message_id, chat_id, group_id, sender_device_id, content, timestamp, status, kind, file_name, file_path, file_size, mime_type, transfer_id, file_hash, reply_to_message_id, reply_to_sender_id, reply_to_preview, mentions)`
- `groups(group_id, name, owner_device_id, created_at, last_message_at, unread_count, last_message_preview)`
- `group_members(group_id, device_id, display_name, role)`
- `group_invites(invite_id, group_id, inviter_device_id, status, created_at)`
- `settings(key, value)`

## 数据位置

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

组件预览开发模式（展示所有组件并支持 Flutter 热重载 `r` / 热重启 `R`，不占用本地数据库与网络端口）：

```powershell
flutter run -d windows -t lib/main_preview.dart
# 若已有 NekoChat 实例正在运行，可附加多实例参数并行启动预览：
flutter run -d windows -t lib/main_preview.dart -a --allow-multiple-instances
# 或通过编译宏启动：
flutter run -d windows --dart-define=COMPONENT_PREVIEW=true
```

机房联调时至少使用两台电脑，并确认它们在同一局域网、Windows 网络类型为“专用网络”，且 UDP 23332 与 TCP 23333 未被防火墙拦截。

## MVP 实现顺序

1. 模型、身份、密钥提供者与数据库
2. 协议信封、口令配对与会话状态机
3. UDP 发现与在线状态
4. WebSocket 传输和邀请流程
5. 私聊历史、关闭与黑名单
6. 群邀请、成员管理与 fan-out 消息
7. Material 3 桌面界面
8. 静态分析、单元测试、Windows 构建和双机联调

## 明确边界

当前版本是纯实时 LAN Chat：对方离线时消息标记失败，不做离线队列。附件也只在发送方在线且邀请有效时可接收，不提供断点续传。未实现公网服务器、账号系统、TLS、E2EE、云同步、NAT 穿透、语音和视频。

## 开源协议

本项目采用 **GNU General Public License v3.0**（GPLv3）发布，完整条款见 [LICENSE](LICENSE)。

这意味着你可以自由使用、修改和分发本软件，但任何基于本项目的衍生作品在分发时也必须以 GPLv3 开源，并附带对应的源代码。

> 字体说明：应用**不打包**任何第三方字体，仓库也不包含字体文件。外观设置里的霞鹜文楷、MiSans、vivo Sans、Google Sans、JetBrains Mono 等仅在**本机已安装**该字体时才可选用并生效（运行时按系统 Fonts 目录检测，未安装则自动回退系统默认）。因此这些字体各自的授权与本项目 GPLv3 无关，发行版里也不会夹带它们。
