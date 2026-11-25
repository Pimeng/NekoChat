<div align="center">

<img src="assets/app.png" alt="NekoChat" width="120" />

# NekoChat

**无需服务器、不联外网的 Windows 局域网聊天工具**

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)
![Platform](https://img.shields.io/badge/platform-Windows-0078D6?logo=windows&logoColor=white)
![Flutter](https://img.shields.io/badge/Flutter-Material%203-02569B?logo=flutter&logoColor=white)
![Version](https://img.shields.io/badge/version-1.3.0-4c9a2a.svg)

</div>

<h4>NekoChat 是一款面向机房、办公室等同一局域网环境的桌面聊天工具。无需任何中心服务器，也不需要连接外网：同网段的设备通过 UDP 互相发现，聊天与文件则经 WebSocket / HTTP 直接点对点传输。开箱即用，数据全部留在本机。</h4>

## ✨ 功能特性

**发现与配对**
- UDP 组播 + 广播在后台维持在线探测，自动发现同网段的 NekoChat
- 陌生设备静默缓存、不会自动出现在会话或联系人列表；加好友统一在“联系人 → 添加好友”里手动发起
- 口令配对：告诉对方你的口令，对方即可直接向你发起申请，口令随机生成
- 可以屏蔽陌生人的加好友申请；用口令加你的人不受影响

**私聊与群聊**
- WebSocket 私聊，带等待接受 / 发送成功 / 被拒绝 / 失败等消息状态与本地历史
- 群聊支持 @ 提及、成员管理与在线成员消息广播
- 群角色：群主可设管理员、改名、解散；管理员可移除成员并撤回消息
- 消息撤回、会话关闭、黑名单，以及可查看的对端资料卡
- 私聊和群聊都能在独立窗口中打开

**文件与图片**
- 发送图片与任意文件，支持拖拽文件直接发送、`Ctrl+V` 粘贴剪贴板图片/文件
- 接收图片按内容哈希去重与校验，内嵌显示，可打开原图或所在文件夹
- 自动接收大小上限可自定义，超限需手动确认

**桌面体验**
- Windows 系统通知（聊天邀请、消息等），可选仿 Windows 样式的独立通知弹窗，点击回到对应会话
- 老板键一键隐藏窗口，并可设置隐藏后是否仍弹通知
- 本地密码解锁，PBKDF2 + AES-256-GCM 封装数据库密钥

**隐私与数据**
- 无服务器、无账号、不联外网，聊天内容只在局域网内点对点传输
- 全部数据存在程序目录旁的一个文件夹里，整体拷走即可换机

## 📦 下载与运行

前往 [Releases](https://github.com/Pimeng/NekoChat/releases) 下载压缩包，解压后运行 `neko_chat.exe` 即可，无需安装。

首次运行需要：

1. 确保互相通信的电脑在**同一局域网**，且 Windows 网络类型为**专用网络**；
2. 允许应用通过防火墙（UDP `23332`、TCP `23333`）。

## 🔧 从源码构建

需要 [Flutter](https://flutter.dev)（stable 渠道）与 Windows 桌面开发环境。

```powershell
flutter pub get
flutter run -d windows        # 运行
flutter build windows         # 构建发布版（产物在 build\windows\x64\runner\Release\）
```

常用校验：

```powershell
flutter analyze
flutter test
```

## 🧱 技术栈

Flutter / Dart（Material 3）· `dart:io`（UDP / WebSocket / HTTP 文件流）· `sqflite_common_ffi`（SQLite）· `cryptography`（PBKDF2 / AES-GCM）。

## 🔤 字体

仓库与发行版默认**不携带任何字体文件**。应用按「随包字体 → 系统已安装字体 → 系统默认」的顺序选用霞鹜文楷、MiSans、vivo Sans、Google Sans、JetBrains Mono 等；想随应用一起分发某款字体，把 `.ttf` 放进 `assets/font/` 再编译即可。详见[设计文档](docs/ARCHITECTURE.md#字体加载)。

> 这些第三方字体各自适用其原始授权，请在随包分发前确认其许可是否允许。

## 📖 文档

架构、网络协议、数据库结构与数据存储等开发细节见 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)。

## 📄 许可证

[GNU General Public License v3.0](LICENSE) 
