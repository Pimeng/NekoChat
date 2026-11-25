import 'package:material_ui/material_ui.dart';

import '../../app/app_controller.dart';
import '../../app/neko_chat_app.dart';
import '../../core/models/models.dart';
import '../../core/notifications/notification_window_channel.dart';
import '../../core/notifications/standalone_notification_controller.dart';
import '../../core/notifications/windows_toast_card.dart';
import '../chat/group_info_drawer.dart';
import '../chat/main_shell.dart';
import '../chat/mention_autocomplete.dart';
import '../chat/message_composer.dart';
import '../chat/peer_info_drawer.dart';
import '../chat/sticker_picker.dart';
import '../onboarding/auth_page.dart';
import '../settings/settings_page.dart';
import 'preview_app_controller.dart';

enum PreviewCategory {
  primitives('基础与徽标', Icons.widgets_outlined),
  sidebar('侧栏与邀请卡片', Icons.view_sidebar_outlined),
  chat('消息与输入', Icons.chat_bubble_outline),
  pages('完整页面', Icons.desktop_windows_outlined);

  const PreviewCategory(this.label, this.icon);
  final String label;
  final IconData icon;
}

class PreviewEntry {
  const PreviewEntry({
    required this.id,
    required this.name,
    required this.widgetType,
    required this.description,
    required this.category,
    required this.builder,
    this.isFullPage = false,
  });

  final String id;
  final String name;
  final String widgetType;
  final String description;
  final PreviewCategory category;
  final WidgetBuilder builder;

  /// 为 true 时单独预览会占满整个舞台区域（不包裹在居中卡片内），且在总览页中以缩略预览入口展示。
  final bool isFullPage;
}

/// 每次 build 时动态构建目录，确保修改任何组件或预览用例后 Flutter 热重载立即生效。
List<PreviewEntry> buildPreviewCatalog(
  PreviewAppController controller, {
  required void Function(String message) onAction,
}) {
  Future<void> noopMessage(ChatMessage _) async {}

  return [
    // ==================== 基础与徽标 ====================
    PreviewEntry(
      id: 'avatars',
      name: '用户头像',
      widgetType: 'ProfileAvatar / NamedAvatar',
      description: '本机头像与对端头像，无图片路径时自动回退到昵称首字符。',
      category: PreviewCategory.primitives,
      builder: (_) => Wrap(
        spacing: 20,
        runSpacing: 16,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          _LabeledSample(
            label: 'ProfileAvatar (r=23)',
            child: ProfileAvatar(
              identity: PreviewFixtures.localIdentity(),
              imagePath: null,
              radius: 23,
            ),
          ),
          _LabeledSample(
            label: 'ProfileAvatar (r=36)',
            child: ProfileAvatar(
              identity: PreviewFixtures.localIdentity(),
              imagePath: null,
              radius: 36,
            ),
          ),
          const _LabeledSample(
            label: 'NamedAvatar (中文)',
            child: NamedAvatar(imagePath: null, name: '林晓猫', radius: 22),
          ),
          const _LabeledSample(
            label: 'NamedAvatar (英文)',
            child: NamedAvatar(imagePath: null, name: 'alice', radius: 22),
          ),
          const _LabeledSample(
            label: 'NamedAvatar (空字符串)',
            child: NamedAvatar(imagePath: null, name: '', radius: 22),
          ),
        ],
      ),
    ),
    PreviewEntry(
      id: 'role-tag',
      name: '群角色徽标',
      widgetType: 'RoleTag',
      description: '群聊消息昵称旁显示的角色标签：群主、管理员、成员。',
      category: PreviewCategory.primitives,
      builder: (_) => const Wrap(
        spacing: 16,
        runSpacing: 12,
        children: [
          _LabeledSample(
            label: 'owner',
            child: RoleTag(role: GroupRole.owner),
          ),
          _LabeledSample(
            label: 'admin',
            child: RoleTag(role: GroupRole.admin),
          ),
          _LabeledSample(
            label: 'member',
            child: RoleTag(role: GroupRole.member),
          ),
        ],
      ),
    ),
    PreviewEntry(
      id: 'windows-toast',
      name: '独立 Windows 通知弹窗',
      widgetType: 'WindowsNotificationSurface',
      description: '默认停靠在屏幕右下角的仿 Windows 11 样式独立通知组件，支持浅色、深色、多条堆叠与实时弹窗测试。',
      category: PreviewCategory.primitives,
      builder: (_) => AnimatedBuilder(
        animation: controller,
        builder: (context, _) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 10,
              runSpacing: 10,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                FilledButton.icon(
                  onPressed: () {
                    controller.showTestNotification();
                    onAction('已触发独立测试通知（${controller.notificationAnchor.label}）');
                  },
                  icon: const Icon(Icons.notifications_active_outlined, size: 18),
                  label: Text('弹出测试通知（${controller.notificationAnchor.label}）'),
                ),
                OutlinedButton.icon(
                  onPressed: () {
                    controller.showStackedTestNotifications();
                    onAction('已触发多条堆叠测试通知');
                  },
                  icon: const Icon(Icons.layers_outlined, size: 18),
                  label: const Text('弹出多条堆叠'),
                ),
                TextButton.icon(
                  onPressed: () {
                    controller.clearPreviewNotifications();
                    onAction('已关闭全部预览通知弹窗');
                  },
                  icon: const Icon(Icons.close_rounded, size: 18),
                  label: const Text('关闭弹窗'),
                ),
                const SizedBox(width: 8),
                SegmentedButton<NotificationAnchor>(
                  showSelectedIcon: false,
                  segments: [
                    for (final anchor in NotificationAnchor.values)
                      ButtonSegment<NotificationAnchor>(
                        value: anchor,
                        label: Text(anchor.label),
                      ),
                  ],
                  selected: {controller.notificationAnchor},
                  onSelectionChanged: (selection) {
                    controller.setNotificationAnchor(selection.first);
                    onAction('已切换弹窗位置为：${selection.first.label}');
                  },
                ),
              ],
            ),
            const SizedBox(height: 18),
            Wrap(
              spacing: 24,
              runSpacing: 20,
              children: [
                _LabeledSample(
                  label: '浅色 · 单条通知',
                  child: WindowsNotificationSurface(
                    showShadow: true,
                    items: [
                      StandaloneNotificationItem(
                        identifier: 'preview-light-1',
                        title: '林晓猫',
                        body: '刚把设计稿发到群里了，有空帮我看看右下角弹窗样式～',
                        timestamp: DateTime(2026, 11, 22, 10, 30),
                        onClick: () {},
                      ),
                    ],
                    onItemTap: (id) => onAction('点击通知: $id'),
                    onItemDismiss: (id) => onAction('关闭通知: $id'),
                    onDismissAll: () => onAction('关闭全部通知'),
                  ),
                ),
                _LabeledSample(
                  label: '深色 · 单条通知',
                  child: WindowsNotificationSurface(
                    darkMode: true,
                    showShadow: true,
                    items: [
                      StandaloneNotificationItem(
                        identifier: 'preview-dark-1',
                        title: '产品研发交流群',
                        body: '阿橙：新版本构建已经通过，准备打包发布。',
                        timestamp: DateTime(2026, 11, 22, 10, 31),
                        onClick: () {},
                      ),
                    ],
                    onItemTap: (id) => onAction('点击通知: $id'),
                    onItemDismiss: (id) => onAction('关闭通知: $id'),
                    onDismissAll: () => onAction('关闭全部通知'),
                  ),
                ),
                _LabeledSample(
                  label: '浅色 · 多条堆叠',
                  child: WindowsNotificationSurface(
                    showShadow: true,
                    items: [
                      StandaloneNotificationItem(
                        identifier: 'preview-stack-1',
                        title: '林晓猫',
                        body: '收到，我马上去看！',
                        timestamp: DateTime(2026, 11, 22, 10, 32),
                        onClick: () {},
                      ),
                      StandaloneNotificationItem(
                        identifier: 'preview-stack-2',
                        title: 'NekoChat 群聊邀请',
                        body: '阿橙 邀请你加入「周末桌游小队」',
                        timestamp: DateTime(2026, 11, 22, 10, 31),
                        onClick: () {},
                      ),
                    ],
                    onItemTap: (id) => onAction('点击通知: $id'),
                    onItemDismiss: (id) => onAction('关闭通知: $id'),
                    onDismissAll: () => onAction('全部清除'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
    PreviewEntry(
      id: 'unread-badge',
      name: '未读消息徽标',
      widgetType: 'UnreadBadge',
      description: '红色圆角未读计数，超过 99 自动显示为 99+。',
      category: PreviewCategory.primitives,
      builder: (_) => const Wrap(
        spacing: 20,
        runSpacing: 12,
        children: [
          _LabeledSample(label: 'count = 1', child: UnreadBadge(count: 1)),
          _LabeledSample(label: 'count = 12', child: UnreadBadge(count: 12)),
          _LabeledSample(label: 'count = 99', child: UnreadBadge(count: 99)),
          _LabeledSample(label: 'count = 128', child: UnreadBadge(count: 128)),
        ],
      ),
    ),
    PreviewEntry(
      id: 'conversation-meta',
      name: '会话时间与未读组合',
      widgetType: 'ConversationMeta',
      description: '会话条目右侧的最近消息时间与未读数徽标。',
      category: PreviewCategory.primitives,
      builder: (_) => Wrap(
        spacing: 28,
        runSpacing: 16,
        children: [
          _LabeledSample(
            label: '今天 + 未读',
            child: ConversationMeta(time: DateTime.now(), unreadCount: 5),
          ),
          _LabeledSample(
            label: '历史日期 + 99+',
            child: ConversationMeta(
              time: DateTime(2026, 5, 18, 9, 45),
              unreadCount: 120,
            ),
          ),
          _LabeledSample(
            label: '仅时间（无未读）',
            child: ConversationMeta(time: DateTime.now(), unreadCount: 0),
          ),
        ],
      ),
    ),
    PreviewEntry(
      id: 'section-titles',
      name: '分组标题与空提示',
      widgetType: 'SectionTitle / SettingsSectionTitle / EmptyHint',
      description: '侧栏分组标题、设置页分组标题、空列表提示与底部版本号。',
      category: PreviewCategory.primitives,
      builder: (_) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SectionTitle(title: '会话'),
          SectionTitle(
            title: '群聊（带右侧操作按钮）',
            trailing: IconButton(
              tooltip: '创建群聊',
              onPressed: () => onAction('点击了创建群聊按钮'),
              icon: const Icon(Icons.add, size: 20),
            ),
          ),
          const Divider(),
          const SettingsSectionTitle('设置页分组标题（在线探测 / 隐私 / 存储）'),
          const Divider(),
          const EmptyHint(
            icon: Icons.person_add_alt_1,
            text: '还没有会话\n到“联系人”里点“添加好友”开始聊天',
          ),
          const EmptyHint(icon: Icons.groups_outlined, text: '还没有群聊'),
          const Divider(),
          const SettingsVersionFooter(),
        ],
      ),
    ),

    // ==================== 侧栏与邀请卡片 ====================
    PreviewEntry(
      id: 'identity-header',
      name: '本机身份顶栏',
      widgetType: 'IdentityHeader',
      description: '侧边栏顶部展示本机昵称、设备号、编辑入口与全局未读总数。',
      category: PreviewCategory.sidebar,
      builder: (_) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _SubHeading('有未读消息 (15 条)'),
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: IdentityHeader(
              controller: controller,
              unreadCount: 15,
              onTap: () => onAction('点击了 IdentityHeader（编辑个人资料）'),
            ),
          ),
          const SizedBox(height: 16),
          const _SubHeading('无未读消息'),
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: IdentityHeader(
              controller: controller,
              unreadCount: 0,
              onTap: () => onAction('点击了 IdentityHeader'),
            ),
          ),
        ],
      ),
    ),
    PreviewEntry(
      id: 'unified-peer-tile',
      name: '会话列表项',
      widgetType: 'UnifiedPeerTile',
      description: '会话列表中的私聊条目：在线已验证（选中）、离线历史会话、等待确认与已拉黑等状态。',
      category: PreviewCategory.sidebar,
      builder: (_) {
        final peers = PreviewFixtures.peers();
        final chats = PreviewFixtures.chats();
        final trusted = PreviewFixtures.trustedPeers();
        return Column(
          children: [
            UnifiedPeerTile(
              entry: UnifiedPeerEntry(
                deviceId: peers[0].deviceId,
                displayName: '晓猫（前端）',
                originalDisplayName: peers[0].displayName,
                peer: peers[0],
                chat: chats[0],
                trustedPeer: trusted[peers[0].deviceId],
              ),
              selected: true,
              onTap: () => onAction('选中在线会话：晓猫（前端）'),
              onSecondaryTapDown: (_) => onAction('右键点击：晓猫（前端）'),
            ),
            const Divider(height: 1),
            UnifiedPeerTile(
              entry: UnifiedPeerEntry(
                deviceId: peers[2].deviceId,
                displayName: peers[2].displayName,
                originalDisplayName: peers[2].displayName,
                peer: peers[2],
                chat: chats[1].copyWith(unreadCount: 2),
                trustedPeer: trusted[peers[2].deviceId],
              ),
              selected: false,
              onTap: () => onAction('查看离线会话历史：蓝猫测试机'),
              onSecondaryTapDown: (_) => onAction('右键点击：蓝猫测试机'),
            ),
            const Divider(height: 1),
            UnifiedPeerTile(
              entry: UnifiedPeerEntry(
                deviceId: 'neko-pending-peer',
                displayName: '银渐层工作站',
                originalDisplayName: '银渐层工作站',
                peer: DiscoveredPeer(
                  deviceId: 'neko-pending-peer',
                  displayName: '银渐层工作站',
                  ip: '192.168.10.77',
                  port: 23333,
                  lastSeen: PreviewFixtures.baseTime,
                  trusted: false,
                  online: true,
                ),
                chat: const ChatSummary(
                  chatId: 'chat-pending',
                  peerDeviceId: 'neko-pending-peer',
                  displayName: '银渐层工作站',
                  state: ChatSessionState.pendingOutgoing,
                ),
                trustedPeer: null,
              ),
              selected: false,
              onTap: () => onAction('等待对方确认'),
              onSecondaryTapDown: (_) {},
            ),
            const Divider(height: 1),
            UnifiedPeerTile(
              entry: UnifiedPeerEntry(
                deviceId: peers[3].deviceId,
                displayName: peers[3].displayName,
                originalDisplayName: peers[3].displayName,
                peer: peers[3],
                chat: null,
                trustedPeer: trusted[peers[3].deviceId],
              ),
              selected: false,
              onTap: () {},
              onSecondaryTapDown: (_) => onAction('右键点击已拉黑设备'),
            ),
          ],
        );
      },
    ),
    PreviewEntry(
      id: 'chat-request-card',
      name: '聊天邀请卡片',
      widgetType: 'ChatRequestCard',
      description: '好友申请卡片，支持“收到的申请”和“发出的等待确认”两种形态；通过/拒绝即可。',
      category: PreviewCategory.sidebar,
      builder: (_) => Wrap(
        spacing: 16,
        runSpacing: 16,
        children: [
          SizedBox(
            width: 320,
            child: ChatRequestCard(
              controller: controller,
              request: PreviewFixtures.incomingRequest(),
            ),
          ),
          SizedBox(
            width: 320,
            child: ChatRequestCard(
              controller: controller,
              request: PreviewFixtures.outgoingRequest(),
            ),
          ),
        ],
      ),
    ),
    PreviewEntry(
      id: 'group-invite-card',
      name: '群邀请卡片',
      widgetType: 'GroupInviteCard',
      description: '展示邀请人、群名与来源主机，提供拒绝/接受操作。',
      category: PreviewCategory.sidebar,
      builder: (_) => SizedBox(
        width: 340,
        child: GroupInviteCard(
          controller: controller,
          invitation: PreviewFixtures.groupInvitation(),
        ),
      ),
    ),
    PreviewEntry(
      id: 'group-info-drawer',
      name: '群聊右侧悬浮面板',
      widgetType: 'GroupInfoDrawer',
      description: '群聊右侧悬浮信息面板，集成成员网格、成员管理、群资料备注与解散/退出。',
      category: PreviewCategory.sidebar,
      builder: (_) => AnimatedBuilder(
        animation: controller,
        builder: (_, _) {
          final group = controller.groups.firstOrNull;
          if (group == null) {
            return const Text('示例群聊已解散，点击右上角「重置数据」恢复');
          }
          return SizedBox(
            height: 600,
            child: Align(
              alignment: Alignment.topRight,
              child: GroupInfoDrawer(
                controller: controller,
                group: group,
                onClose: () => onAction('关闭群聊悬浮面板'),
                onOpenInWindow: () async => onAction('独立窗口打开：${group.name}'),
                onMentionMember: (name) => onAction('@ 提及 $name'),
              ),
            ),
          );
        },
      ),
    ),
    PreviewEntry(
      id: 'peer-info-drawer',
      name: '单聊右侧悬浮面板',
      widgetType: 'PeerInfoDrawer',
      description: '单聊右侧悬浮信息面板，集成联系人资料、原地备注编辑、独立窗口、关闭对话、取消验证与拉黑管理。',
      category: PreviewCategory.sidebar,
      builder: (_) => AnimatedBuilder(
        animation: controller,
        builder: (_, _) {
          final chat = controller.chats.firstOrNull;
          if (chat == null) {
            return const Text('示例单聊已关闭，点击右上角「重置数据」恢复');
          }
          return SizedBox(
            height: 600,
            child: Align(
              alignment: Alignment.topRight,
              child: PeerInfoDrawer(
                controller: controller,
                chat: chat,
                onClose: () => onAction('关闭单聊悬浮面板'),
                onOpenInWindow: () async =>
                    onAction('独立窗口打开：${chat.displayName}'),
              ),
            ),
          );
        },
      ),
    ),

    // ==================== 消息与输入 ====================
    PreviewEntry(
      id: 'message-bubble',
      name: '消息气泡（全状态）',
      widgetType: 'MessageBubble',
      description: '覆盖收/发文本、群角色标签、@提及高亮、引用回复、跳转高亮以及各类文件状态。',
      category: PreviewCategory.chat,
      builder: (_) {
        final now = PreviewFixtures.baseTime;
        final quoted = ChatMessage(
          messageId: 'q-1',
          chatId: 'c-1',
          senderDeviceId: PreviewFixtures.aliceDeviceId,
          content: '今天下午 3 点做组件库视觉走查，记得把暗角和间距调一下。',
          timestamp: now.subtract(const Duration(minutes: 10)),
          status: MessageStatus.sent,
        );
        return SelectionArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              MessageBubble(
                message: quoted,
                mine: false,
                senderName: '晓猫（前端）',
                senderRole: GroupRole.admin,
                missingHint: '',
                onOpen: noopMessage,
                onOpenFolder: noopMessage,
                onAccept: noopMessage,
                onReject: noopMessage,
                onRetry: noopMessage,
                onRelocate: noopMessage,
                onReply: () => onAction('引用该消息'),
                onCopy: () async => onAction('复制消息文本'),
              ),
              MessageBubble(
                message: ChatMessage(
                  messageId: 'b-reply',
                  chatId: 'c-1',
                  senderDeviceId: PreviewFixtures.localDeviceId,
                  content: '收到！已经接好 Flutter 组件预览模式，改完样式保存直接热重载。',
                  timestamp: now.subtract(const Duration(minutes: 8)),
                  status: MessageStatus.sent,
                  replyToMessageId: quoted.messageId,
                  replyToSenderId: quoted.senderDeviceId,
                  replyToPreview: quoted.content,
                ),
                mine: true,
                senderName: '我',
                headerName: '橘猫工程师',
                senderRole: GroupRole.owner,
                replySenderName: '晓猫（前端）',
                resolveMessage: (id) => id == quoted.messageId ? quoted : null,
                onJumpToReply: (_) => onAction('跳转到被引用消息'),
                missingHint: '',
                onOpen: noopMessage,
                onOpenFolder: noopMessage,
                onAccept: noopMessage,
                onReject: noopMessage,
                onRetry: noopMessage,
                onRelocate: noopMessage,
              ),
              MessageBubble(
                message: ChatMessage(
                  messageId: 'b-mention',
                  chatId: 'c-1',
                  senderDeviceId: PreviewFixtures.bobDeviceId,
                  content: '@橘猫工程师 这条是带 @提及 高亮和定位跳转高亮的消息气泡效果！',
                  timestamp: now.subtract(const Duration(minutes: 6)),
                  status: MessageStatus.sent,
                  mentions: const [PreviewFixtures.localDeviceId],
                ),
                mine: false,
                senderName: '三花开发机',
                mentioned: true,
                highlighted: true,
                missingHint: '',
                onOpen: noopMessage,
                onOpenFolder: noopMessage,
                onAccept: noopMessage,
                onReject: noopMessage,
                onRetry: noopMessage,
                onRelocate: noopMessage,
              ),
              MessageBubble(
                message: ChatMessage(
                  messageId: 'b-file-await',
                  chatId: 'c-1',
                  senderDeviceId: PreviewFixtures.aliceDeviceId,
                  content: '',
                  timestamp: now.subtract(const Duration(minutes: 5)),
                  status: MessageStatus.awaitingAcceptance,
                  kind: MessageKind.file,
                  fileName: 'design_tokens_v3.fig',
                  fileSize: 42 * 1024 * 1024,
                  mimeType: 'application/octet-stream',
                ),
                mine: false,
                senderName: '晓猫（前端）',
                missingHint: '',
                onOpen: noopMessage,
                onOpenFolder: noopMessage,
                onAccept: (m) async => onAction('接受文件：${m.fileName}'),
                onReject: (m) async => onAction('拒绝文件：${m.fileName}'),
                onRetry: noopMessage,
                onRelocate: noopMessage,
              ),
              MessageBubble(
                message: ChatMessage(
                  messageId: 'b-file-missing',
                  chatId: 'c-1',
                  senderDeviceId: PreviewFixtures.localDeviceId,
                  content: '',
                  timestamp: now.subtract(const Duration(minutes: 3)),
                  status: MessageStatus.sent,
                  kind: MessageKind.file,
                  fileName: 'build_artifact.zip',
                  filePath: r'C:\nonexistent\build_artifact.zip',
                  fileSize: 6 * 1024 * 1024,
                ),
                mine: true,
                senderName: '我',
                showHeader: false,
                missingHint: '原始文件不在原位置，无法帮你找到',
                onOpen: noopMessage,
                onOpenFolder: noopMessage,
                onAccept: noopMessage,
                onReject: noopMessage,
                onRetry: noopMessage,
                onRelocate: (m) async => onAction('重新指定文件：${m.fileName}'),
              ),
              MessageBubble(
                message: ChatMessage(
                  messageId: 'b-failed',
                  chatId: 'c-1',
                  senderDeviceId: PreviewFixtures.localDeviceId,
                  content: '对端离线导致发送失败的消息状态展示',
                  timestamp: now.subtract(const Duration(minutes: 1)),
                  status: MessageStatus.failed,
                ),
                mine: true,
                senderName: '我',
                showHeader: false,
                missingHint: '',
                onOpen: noopMessage,
                onOpenFolder: noopMessage,
                onAccept: noopMessage,
                onReject: noopMessage,
                onRetry: noopMessage,
                onRelocate: noopMessage,
              ),
            ],
          ),
        );
      },
    ),
    PreviewEntry(
      id: 'recall-notice',
      name: '撤回提示条',
      widgetType: 'RecallNotice',
      description: '消息撤回后的居中灰色提示，支持引用跳转时的高亮背景。',
      category: PreviewCategory.chat,
      builder: (_) => const Column(
        children: [
          RecallNotice(text: '你撤回了一条消息', highlighted: false),
          RecallNotice(text: '管理员 林晓猫 撤回了一条消息', highlighted: true),
        ],
      ),
    ),
    PreviewEntry(
      id: 'reply-banner',
      name: '引用回复横幅',
      widgetType: 'ReplyBanner',
      description: '输入框上方的引用横幅，展示文本、图片或文件图标摘要。',
      category: PreviewCategory.chat,
      builder: (_) => Column(
        children: [
          ReplyBanner(
            senderName: '晓猫（前端）',
            message: ChatMessage(
              messageId: 'r-text',
              chatId: 'c-1',
              senderDeviceId: PreviewFixtures.aliceDeviceId,
              content: '这是一条较长的文本消息，用于预览引用横幅的单行省略截断效果。',
              timestamp: PreviewFixtures.baseTime,
              status: MessageStatus.sent,
            ),
            onCancel: () => onAction('取消文本引用'),
          ),
          ReplyBanner(
            senderName: '三花开发机',
            message: ChatMessage(
              messageId: 'r-img',
              chatId: 'c-1',
              senderDeviceId: PreviewFixtures.bobDeviceId,
              content: '',
              timestamp: PreviewFixtures.baseTime,
              status: MessageStatus.sent,
              kind: MessageKind.image,
              fileName: 'screenshot_preview.png',
            ),
            onCancel: () => onAction('取消图片引用'),
          ),
          ReplyBanner(
            senderName: '蓝猫测试机',
            message: ChatMessage(
              messageId: 'r-file',
              chatId: 'c-1',
              senderDeviceId: PreviewFixtures.carolDeviceId,
              content: '',
              timestamp: PreviewFixtures.baseTime,
              status: MessageStatus.sent,
              kind: MessageKind.file,
              fileName: 'test_report_2026.pdf',
            ),
            onCancel: () => onAction('取消文件引用'),
          ),
        ],
      ),
    ),
    PreviewEntry(
      id: 'pending-attachments',
      name: '待发送附件栏',
      widgetType: 'PendingAttachments / PendingAttachmentChip',
      description: '可交互移除单个附件，并支持一键恢复示例附件。',
      category: PreviewCategory.chat,
      builder: (_) => _PendingAttachmentsDemo(onAction: onAction),
    ),
    PreviewEntry(
      id: 'message-composer',
      name: '消息输入框',
      widgetType: 'MessageComposer',
      description: '支持 Enter 发送、Ctrl+Enter 换行，同时展示在线启用与离线禁用态。',
      category: PreviewCategory.chat,
      builder: (_) => _MessageComposerDemo(onAction: onAction),
    ),
    PreviewEntry(
      id: 'sticker-picker',
      name: '表情与收藏面板',
      widgetType: 'StickerPickerPanel',
      description: '支持常用 Emoji、收藏表情网格、拖动排序与右键管理。',
      category: PreviewCategory.chat,
      builder: (_) => ListenableBuilder(
        listenable: controller,
        builder: (context, _) => StickerPickerPanel(
          stickers: controller.favoriteStickers,
          onSelectSticker: (sticker) async =>
              onAction('发送收藏表情：${sticker.fileName}'),
          onPickStickers: () async {
            onAction('点击添加本地表情');
            return 0;
          },
          onRemoveSticker: (sticker) async {
            await controller.removeFavoriteSticker(sticker);
            onAction('移出收藏表情：${sticker.fileName}');
          },
          onReorderStickers: (oldIndex, newIndex) async {
            await controller.reorderFavoriteStickers(oldIndex, newIndex);
            onAction('调整表情顺序：$oldIndex -> $newIndex');
          },
          onEditStickerRemark: (sticker) async {
            final result = await showStickerRemarkDialog(context, sticker);
            if (result != null) {
              await controller.setFavoriteStickerRemark(sticker, result.remark);
              onAction(
                result.remark == null
                    ? '清除表情备注：${sticker.fileName}'
                    : '设置表情备注：${result.remark}',
              );
            }
          },
          onSelectEmoji: (emoji) => onAction('插入 Emoji：$emoji'),
        ),
      ),
    ),
    PreviewEntry(
      id: 'mention-autocomplete',
      name: '群聊 @提及 自动补全',
      widgetType: 'MentionAutocomplete',
      description: '输入 @ 触发群成员候选列表，支持上下方向键、Enter 选中与 Esc 关闭。',
      category: PreviewCategory.chat,
      builder: (_) => _MentionAutocompleteDemo(onAction: onAction),
    ),
    PreviewEntry(
      id: 'file-drop-overlay',
      name: '文件拖放遮罩层',
      widgetType: 'FileDropOverlay',
      description: '拖入文件到会话窗口时显示的全屏提示层（待松开 / 发送中）。',
      category: PreviewCategory.chat,
      builder: (_) => Wrap(
        spacing: 16,
        runSpacing: 16,
        children: [
          _OverlayPreviewBox(
            label: 'sending = false（松开发送）',
            child: const FileDropOverlay(sending: false),
          ),
          _OverlayPreviewBox(
            label: 'sending = true（正在发送）',
            child: const FileDropOverlay(sending: true),
          ),
        ],
      ),
    ),
    PreviewEntry(
      id: 'top-right-snackbar',
      name: '右上角浮动提示条',
      widgetType: 'TopRightSnackBar',
      description: '桌面端主窗口右上角的轻量通知气泡。',
      category: PreviewCategory.chat,
      builder: (_) => Wrap(
        spacing: 16,
        runSpacing: 12,
        children: [
          TopRightSnackBar(
            message: '热重载完成，所有组件已实时刷新',
            icon: Icons.bolt,
            onClose: () => onAction('关闭提示条'),
          ),
          TopRightSnackBar(
            message: '已将 未知访客机 加入黑名单',
            icon: Icons.block,
            onClose: () => onAction('关闭黑名单提示'),
          ),
        ],
      ),
    ),

    // ==================== 完整页面 ====================
    PreviewEntry(
      id: 'main-shell',
      name: '主界面（可交互）',
      widgetType: 'MainShell',
      description: '完整桌面主壳，包含可拖拽/收起侧边栏、私聊/群聊切换、发消息、引用与撤回。',
      category: PreviewCategory.pages,
      isFullPage: true,
      builder: (_) => AnimatedBuilder(
        animation: controller,
        builder: (_, _) => MainShell(
          controller: controller,
          openConversationWindow: (_, _, conversationId) async {
            onAction('预览模式：模拟在独立窗口打开会话 $conversationId');
          },
        ),
      ),
    ),
    PreviewEntry(
      id: 'welcome-pane',
      name: '欢迎空白面板',
      widgetType: 'WelcomePane',
      description: '未选择任何会话时右侧内容区展示的欢迎页与本机设备 ID 卡片。',
      category: PreviewCategory.pages,
      isFullPage: true,
      builder: (_) => Scaffold(body: WelcomePane(controller: controller)),
    ),
    PreviewEntry(
      id: 'friend-requests-pane',
      name: '新朋友审批面板',
      widgetType: 'FriendRequestsPane',
      description: '联系人页“新朋友”右侧审批区，集中展示收发中的好友申请。',
      category: PreviewCategory.pages,
      isFullPage: true,
      builder: (_) => AnimatedBuilder(
        animation: controller,
        builder: (_, _) => Scaffold(
          body: FriendRequestsPane(
            controller: controller,
            requests: controller.chatRequests.values.toList(),
          ),
        ),
      ),
    ),
    PreviewEntry(
      id: 'group-notifications-pane',
      name: '群通知审批面板',
      widgetType: 'GroupNotificationsPane',
      description: '联系人页“群通知”右侧审批区，集中处理收到的局域网群聊邀请。',
      category: PreviewCategory.pages,
      isFullPage: true,
      builder: (_) => AnimatedBuilder(
        animation: controller,
        builder: (_, _) => Scaffold(
          body: GroupNotificationsPane(
            controller: controller,
            invitations: controller.groupInvitations.values.toList(),
          ),
        ),
      ),
    ),
    PreviewEntry(
      id: 'contact-detail-pane',
      name: '联系人详情面板',
      widgetType: 'ContactDetailPane',
      description: '点击已验证联系人后展示的资料卡，支持发消息、修改备注与拉黑/解除拉黑。',
      category: PreviewCategory.pages,
      isFullPage: true,
      builder: (_) => AnimatedBuilder(
        animation: controller,
        builder: (_, _) {
          final trusted =
              controller.trustedPeers[PreviewFixtures.aliceDeviceId];
          if (trusted == null) {
            return const Scaffold(
              body: Center(child: Text('该示例联系人已取消验证，点击右上角「重置数据」可恢复')),
            );
          }
          final peer = controller.peers
              .where((p) => p.deviceId == trusted.deviceId)
              .firstOrNull;
          return Scaffold(
            body: ContactDetailPane(
              controller: controller,
              trustedPeer: trusted,
              discoveredPeer: peer,
              onStartChat: () => onAction('点击了发消息：${trusted.displayName}'),
              onEditRemark: () => onAction('点击了修改备注：${trusted.displayName}'),
              onToggleBlock: () =>
                  controller.setBlocked(trusted.deviceId, !trusted.blocked),
              onRevokeVerification: () =>
                  controller.revokePeerVerification(trusted.deviceId),
            ),
          );
        },
      ),
    ),
    PreviewEntry(
      id: 'auth-page',
      name: '创建身份 / 解锁页',
      widgetType: 'AuthPage',
      description: '可在首次创建身份（setup）、输入密码解锁（locked）和错误提示状态间实时切换。',
      category: PreviewCategory.pages,
      isFullPage: true,
      builder: (_) => const _AuthPageDemo(),
    ),
    PreviewEntry(
      id: 'settings-page',
      name: '设置页面（可交互）',
      widgetType: 'SettingsPage',
      description: '完整设置页，可交互切换开关、测试上限校验弹窗和进入老板键快捷键录制页。',
      category: PreviewCategory.pages,
      isFullPage: true,
      builder: (_) => AnimatedBuilder(
        animation: controller,
        builder: (_, _) => SettingsPage(controller: controller),
      ),
    ),
    PreviewEntry(
      id: 'boss-key-shortcut-page',
      name: '老板键快捷键录制页',
      widgetType: 'BossKeyShortcutPage',
      description: '按下任意“修饰键 + 普通键”即可实时预览快捷键录制效果。',
      category: PreviewCategory.pages,
      isFullPage: true,
      builder: (_) => BossKeyShortcutPage(controller: controller),
    ),
    PreviewEntry(
      id: 'blocked-peers-page',
      name: '黑名单管理页',
      widgetType: 'BlockedPeersPage',
      description: '集中展示所有已拉黑联系人，支持确认后一键解除拉黑及空态预览。',
      category: PreviewCategory.pages,
      isFullPage: true,
      builder: (_) => BlockedPeersPage(controller: controller),
    ),
    PreviewEntry(
      id: 'boot-page',
      name: '启动加载页',
      widgetType: 'BootPage',
      description: '应用初始化读取本地身份时的等待界面。',
      category: PreviewCategory.pages,
      isFullPage: true,
      builder: (_) => const BootPage(),
    ),
    PreviewEntry(
      id: 'fatal-page',
      name: '致命错误页',
      widgetType: 'FatalPage',
      description: '启动阶段发生不可恢复异常时的兜底错误卡片。',
      category: PreviewCategory.pages,
      isFullPage: true,
      builder: (_) => const FatalPage(
        message: '示例错误：无法读取本地身份密钥文件（database-key.json 格式损坏）',
      ),
    ),
  ];
}

class _LabeledSample extends StatelessWidget {
  const _LabeledSample({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      child,
      const SizedBox(height: 6),
      Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    ],
  );
}

class _SubHeading extends StatelessWidget {
  const _SubHeading(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(
      text,
      style: Theme.of(context).textTheme.labelMedium?.copyWith(
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    ),
  );
}

class _OverlayPreviewBox extends StatelessWidget {
  const _OverlayPreviewBox({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _SubHeading(label),
      Container(
        width: 340,
        height: 200,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Theme.of(context).dividerColor),
        ),
        child: Stack(
          children: [
            const Center(child: Text('底层会话内容占位')),
            child,
          ],
        ),
      ),
    ],
  );
}

class _PendingAttachmentsDemo extends StatefulWidget {
  const _PendingAttachmentsDemo({required this.onAction});
  final void Function(String message) onAction;

  @override
  State<_PendingAttachmentsDemo> createState() =>
      _PendingAttachmentsDemoState();
}

class _PendingAttachmentsDemoState extends State<_PendingAttachmentsDemo> {
  late List<PendingAttachment> _items;

  @override
  void initState() {
    super.initState();
    _items = List<PendingAttachment>.from(
      PreviewFixtures.pendingAttachments(),
    );
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (_items.isNotEmpty)
        PendingAttachments(
          attachments: _items,
          onRemove: (item) {
            setState(() => _items.remove(item));
            widget.onAction('已移除附件：${item.fileName}');
          },
        )
      else
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 12),
          child: Text('所有示例附件已移除'),
        ),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: () => setState(
            () => _items = List<PendingAttachment>.from(
              PreviewFixtures.pendingAttachments(),
            ),
          ),
          icon: const Icon(Icons.refresh, size: 18),
          label: const Text('恢复示例附件'),
        ),
      ),
    ],
  );
}

class _MessageComposerDemo extends StatefulWidget {
  const _MessageComposerDemo({required this.onAction});
  final void Function(String message) onAction;

  @override
  State<_MessageComposerDemo> createState() => _MessageComposerDemoState();
}

class _MessageComposerDemoState extends State<_MessageComposerDemo> {
  final _enabledController = TextEditingController(
    text: '支持 Enter 发送，Ctrl + Enter 换行',
  );
  final _disabledController = TextEditingController();

  @override
  void dispose() {
    _enabledController.dispose();
    _disabledController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const _SubHeading('启用状态（在线）'),
      MessageComposer(
        controller: _enabledController,
        enabled: true,
        onSend: () {
          final text = _enabledController.text.trim();
          if (text.isEmpty) return;
          widget.onAction('发送消息：$text');
          _enabledController.clear();
        },
      ),
      const SizedBox(height: 16),
      const _SubHeading('禁用状态（对方离线）'),
      MessageComposer(
        controller: _disabledController,
        enabled: false,
        onSend: () {},
      ),
    ],
  );
}

class _MentionAutocompleteDemo extends StatefulWidget {
  const _MentionAutocompleteDemo({required this.onAction});
  final void Function(String message) onAction;

  @override
  State<_MentionAutocompleteDemo> createState() =>
      _MentionAutocompleteDemoState();
}

class _MentionAutocompleteDemoState extends State<_MentionAutocompleteDemo> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _triggerAt();
  }

  void _triggerAt() {
    _controller.value = const TextEditingValue(
      text: '麻烦看一下 @',
      selection: TextSelection.collapsed(offset: 7),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        children: [
          const Text('提示：在下方输入 @ 即可过滤群成员'),
          const Spacer(),
          TextButton.icon(
            onPressed: _triggerAt,
            icon: const Icon(Icons.alternate_email, size: 18),
            label: const Text('触发 @ 候选'),
          ),
        ],
      ),
      const SizedBox(height: 8),
      MentionAutocomplete(
        controller: _controller,
        focusNode: _focusNode,
        enabled: true,
        loadCandidates: () async => PreviewFixtures.mentionCandidates(),
        onSend: () {
          final text = _controller.text.trim();
          if (text.isEmpty) return;
          widget.onAction('群聊发送：$text');
          _controller.clear();
        },
      ),
    ],
  );
}

class _AuthPageDemo extends StatefulWidget {
  const _AuthPageDemo();

  @override
  State<_AuthPageDemo> createState() => _AuthPageDemoState();
}

class _AuthPageDemoState extends State<_AuthPageDemo> {
  late final PreviewAppController _authController;
  bool _showError = false;

  @override
  void initState() {
    super.initState();
    _authController = PreviewAppController(initialStage: AppStage.setup);
  }

  @override
  void dispose() {
    _authController.dispose();
    super.dispose();
  }

  void _switchStage(AppStage nextStage) {
    setState(() {
      _authController.stage = nextStage;
      _authController.errorMessage = _showError ? '示例校验错误：密码错误或长度不足' : null;
    });
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Material(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Wrap(
            spacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SegmentedButton<AppStage>(
                segments: const [
                  ButtonSegment(
                    value: AppStage.setup,
                    label: Text('创建身份 (setup)'),
                  ),
                  ButtonSegment(
                    value: AppStage.locked,
                    label: Text('解锁 (locked)'),
                  ),
                ],
                selected: {_authController.stage},
                onSelectionChanged: (selection) =>
                    _switchStage(selection.first),
              ),
              FilterChip(
                label: const Text('模拟错误提示'),
                selected: _showError,
                onSelected: (value) {
                  setState(() {
                    _showError = value;
                    _authController.errorMessage = value
                        ? '示例校验错误：密码错误或长度不足'
                        : null;
                  });
                },
              ),
            ],
          ),
        ),
      ),
      const Divider(height: 1),
      Expanded(
        child: AnimatedBuilder(
          animation: _authController,
          builder: (_, _) =>
              AuthPage(controller: _authController, windowControls: false),
        ),
      ),
    ],
  );
}
