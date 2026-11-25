import 'dart:async';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:multiview_desktop/multiview_desktop.dart';

import '../../app/app_controller.dart';
import '../../core/config/network_config.dart';
import '../../core/models/models.dart';
import '../../core/protocol/protocol.dart';
import '../../core/text/pinyin_search.dart';
import '../common/neko_context_menu.dart';
import '../common/smooth_dialog.dart';
import '../settings/settings_page.dart';
import 'group_info_drawer.dart';
import 'message_composer.dart';
import 'mention_autocomplete.dart';
import 'peer_info_drawer.dart';
import 'sticker_picker.dart';
import 'view_drop_service.dart';

final Map<String, int> _detachedConversationWindowIds = {};

Future<void> openConversationInWindow(
  BuildContext context,
  AppController controller,
  String conversationId,
) async {
  final existingId = _detachedConversationWindowIds[conversationId];
  if (existingId != null &&
      MultiViewDesktop.allWindowViewIds.contains(existingId)) {
    final window = MultiViewDesktop.fromId(existingId);
    await window.show();
    await window.focus();
    return;
  }
  _detachedConversationWindowIds.remove(conversationId);

  final title = _conversationWindowTitle(controller, conversationId);
  if (title == null) return;
  final parentTheme = Theme.of(context);
  try {
    final viewId = await openWindow(
      (_, publicId) => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: parentTheme,
        home: _DetachedConversationWindow(
          controller: controller,
          conversationId: conversationId,
          viewId: publicId,
        ),
      ),
      options: WindowOptions(
        title: '$title - NekoChat',
        size: const Size(920, 720),
        minimumSize: const Size(640, 480),
        // Flutter 3.47+ 使用 material_ui 时 multiview_desktop 会回退到 WidgetsApp，
        // 提供 pageRouteBuilder 避免触发 WidgetsApp 路由断言异常。
        shellOverrides: ViewShellOverrides(
          pageRouteBuilder:
              <T>(RouteSettings settings, WidgetBuilder builder) =>
                  PageRouteBuilder<T>(
                    settings: settings,
                    pageBuilder: (context, _, _) => builder(context),
                  ),
        ),
      ),
      parentContext: context,
    );
    _detachedConversationWindowIds[conversationId] = viewId;
  } on Object catch (error) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('无法打开独立会话窗口：$error')));
  }
}

/// 独立窗口的标题；会话不存在时返回 null。
String? _conversationWindowTitle(
  AppController controller,
  String conversationId,
) {
  final groupId = conversationId.startsWith('group:')
      ? conversationId.substring('group:'.length)
      : null;
  if (groupId != null) {
    final group = controller.groups
        .where((value) => value.groupId == groupId)
        .firstOrNull;
    if (group == null) return null;
    return controller.groupDisplayName(group.groupId, group.name);
  }
  final chat = controller.chats
      .where((value) => value.chatId == conversationId)
      .firstOrNull;
  if (chat == null) return null;
  return controller.peerDisplayName(chat.peerDeviceId, chat.displayName);
}

typedef ConversationWindowOpener = Future<void> Function(
  BuildContext context,
  AppController controller,
  String conversationId,
);

class MainShell extends StatefulWidget {
  const MainShell({
    super.key,
    required this.controller,
    this.openConversationWindow = openConversationInWindow,
  });
  final AppController controller;
  final ConversationWindowOpener openConversationWindow;

  @override
  State<MainShell> createState() => _MainShellState();
}

enum _MainNavTab { messages, contacts, settings }

enum _ContactsSubTab { friends, groups }

enum _ContactDetailMode { none, friendRequests, groupNotifications, peer }

class _MainShellState extends State<MainShell> {
  static const _navRailWidth = 60.0;
  static const _defaultSidebarWidth = 320.0;
  static const _minimumSidebarWidth = 240.0;
  static const _maximumSidebarWidth = 480.0;
  static const _collapseSnapThreshold = 100.0;
  static const _expandSnapThreshold = 130.0;
  static const _sidebarResizeHandleWidth = 12.0;
  static const _sidebarAnimationDuration = Duration(milliseconds: 240);

  final Map<String, TextEditingController> _composers = {};
  final Map<String, List<PendingAttachment>> _pendingAttachments = {};
  double _sidebarWidth = _defaultSidebarWidth;
  double _dragTargetWidth = _defaultSidebarWidth;
  bool _sidebarVisible = true;
  bool _sidebarMounted = true;
  bool _resizingSidebar = false;
  bool _hoveringResizeHandle = false;
  _MainNavTab _navTab = _MainNavTab.messages;
  _ContactsSubTab _contactsSubTab = _ContactsSubTab.friends;
  _ContactDetailMode _contactDetailMode = _ContactDetailMode.none;
  SettingsSection _settingsSection = SettingsSection.lan;
  String? _selectedContactDeviceId;
  bool _verifiedExpanded = true;
  bool _blockedExpanded = false;
  bool _groupDrawerOpen = false;
  String? _groupDrawerGroupId;
  bool _peerDrawerOpen = false;
  String? _peerDrawerChatId;
  Widget? _cachedDrawer;

  TextEditingController _composerFor(String conversationId) =>
      _composers.putIfAbsent(conversationId, TextEditingController.new);

  List<PendingAttachment> _pendingFor(String conversationId) =>
      _pendingAttachments.putIfAbsent(conversationId, () => []);

  void _startResizingSidebar(DragStartDetails details) {
    setState(() {
      _resizingSidebar = true;
      _dragTargetWidth = _sidebarVisible ? _sidebarWidth : 0;
    });
  }

  void _resizeSidebar(DragUpdateDetails details) {
    setState(() {
      _dragTargetWidth = (_dragTargetWidth + details.delta.dx).clamp(
        0.0,
        _maximumSidebarWidth,
      );
      if (_sidebarVisible) {
        if (_dragTargetWidth < _collapseSnapThreshold) {
          _sidebarVisible = false;
          _sidebarMounted = false;
        } else {
          _sidebarWidth = _dragTargetWidth.clamp(
            _minimumSidebarWidth,
            _maximumSidebarWidth,
          );
        }
      } else if (_dragTargetWidth >= _expandSnapThreshold) {
        _sidebarMounted = true;
        _sidebarVisible = true;
        _sidebarWidth = _dragTargetWidth.clamp(
          _minimumSidebarWidth,
          _maximumSidebarWidth,
        );
      }
    });
  }

  void _stopResizingSidebar([DragEndDetails? details]) {
    if (!_resizingSidebar) return;
    setState(() {
      _resizingSidebar = false;
      if (!_sidebarVisible) {
        _sidebarMounted = false;
      }
    });
  }

  @override
  void dispose() {
    for (final composer in _composers.values) {
      composer.dispose();
    }
    super.dispose();
  }

  List<ChatRequest> _visibleChatRequests(AppController controller) =>
      controller.chatRequests.values
          .where(
            (request) =>
                request.incoming ||
                controller.trustedPeers[request.peerDeviceId] == null,
          )
          .toList();

  /// 打开与已验证联系人的会话：已有会话直接进入，否则在对方在线时恢复已验证会话。
  /// 这里不会“添加好友”，好友申请统一从“联系人 → 添加好友”发起。
  Future<void> _openChatWithPeer(
    AppController controller,
    String deviceId,
  ) async {
    final existingChat = controller.chats
        .where((chat) => chat.peerDeviceId == deviceId)
        .firstOrNull;
    final peer = controller.peers
        .where((value) => value.deviceId == deviceId)
        .firstOrNull;
    if (existingChat != null &&
        (existingChat.state == ChatSessionState.active ||
            peer?.online != true)) {
      await controller.selectChat(existingChat.chatId);
    } else if (peer != null && peer.online) {
      await controller.requestChat(peer);
      final updatedChat = controller.chats
          .where((chat) => chat.peerDeviceId == deviceId)
          .firstOrNull;
      if (updatedChat != null) {
        await controller.selectChat(updatedChat.chatId);
      }
    } else if (existingChat != null) {
      await controller.selectChat(existingChat.chatId);
    }
    if (!mounted) return;
    setState(() => _navTab = _MainNavTab.messages);
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    return Scaffold(
      body: SafeArea(
        child: Stack(
          children: [
            Row(
              children: [
                RepaintBoundary(
                  child: SizedBox(
                    width: _navRailWidth,
                    child: _buildNavRail(controller),
                  ),
                ),
                const VerticalDivider(width: 1),
                AnimatedContainer(
                  key: const ValueKey('sidebar-animation'),
                  width: _sidebarVisible ? _sidebarWidth : 0,
                  duration: _resizingSidebar
                      ? Duration.zero
                      : _sidebarAnimationDuration,
                  curve: Curves.easeInOutCubic,
                  onEnd: () {
                    if (!_resizingSidebar &&
                        !_sidebarVisible &&
                        _sidebarMounted) {
                      setState(() => _sidebarMounted = false);
                    }
                  },
                  child: ClipRect(
                    child: _sidebarMounted
                        ? OverflowBox(
                            alignment: Alignment.centerLeft,
                            minWidth: _sidebarWidth,
                            maxWidth: _sidebarWidth,
                            child: RepaintBoundary(
                              child: _buildSidebar(controller),
                            ),
                          )
                        : const SizedBox.shrink(),
                  ),
                ),
                AnimatedContainer(
                  width: _sidebarVisible ? 1 : 0,
                  duration: _resizingSidebar
                      ? Duration.zero
                      : _sidebarAnimationDuration,
                  curve: Curves.easeInOutCubic,
                  color: Theme.of(context).dividerColor,
                ),
                Expanded(
                  child: RepaintBoundary(child: _buildContent(controller)),
                ),
              ],
            ),
            Positioned(
              key: const ValueKey('sidebar-resize-handle'),
              top: 0,
              bottom: 0,
              left:
                  _navRailWidth +
                  1 +
                  (_sidebarVisible ? _sidebarWidth : 0) -
                  (_sidebarResizeHandleWidth - 1) / 2,
              width: _sidebarResizeHandleWidth,
              child: MouseRegion(
                cursor: SystemMouseCursors.resizeColumn,
                onEnter: (_) => setState(() => _hoveringResizeHandle = true),
                onExit: (_) => setState(() => _hoveringResizeHandle = false),
                child: Semantics(
                  label: '调整侧边栏宽度',
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onHorizontalDragStart: _startResizingSidebar,
                    onHorizontalDragUpdate: _resizeSidebar,
                    onHorizontalDragEnd: _stopResizingSidebar,
                    onHorizontalDragCancel: _stopResizingSidebar,
                    child: Center(
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 120),
                        width: (_hoveringResizeHandle || _resizingSidebar)
                            ? 2
                            : 0,
                        color: Theme.of(
                          context,
                        ).colorScheme.primary.withValues(alpha: .55),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Positioned.fill(child: _buildRootDrawerOverlay(controller)),
            Positioned(
              top: 14,
              right: 18,
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 260),
                reverseDuration: const Duration(milliseconds: 180),
                switchInCurve: const Cubic(0.16, 1.0, 0.3, 1.0),
                switchOutCurve: Curves.easeInOutCubic,
                transitionBuilder: (child, animation) => FadeTransition(
                  opacity: animation,
                  child: SlideTransition(
                    position: Tween<Offset>(
                      begin: const Offset(0, -0.25),
                      end: Offset.zero,
                    ).animate(animation),
                    child: child,
                  ),
                ),
                child: controller.topRightMessage != null
                    ? TopRightSnackBar(
                        key: ValueKey(controller.topRightMessage),
                        message: controller.topRightMessage!,
                        icon: controller.topRightIcon,
                        onClose: controller.clearTopRightMessage,
                      )
                    : const SizedBox.shrink(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNavRail(AppController controller) {
    final colorScheme = Theme.of(context).colorScheme;
    final identity = controller.identity!;
    final totalUnread =
        controller.chats.fold<int>(0, (sum, chat) => sum + chat.unreadCount) +
        controller.groups.fold<int>(
          0,
          (sum, group) => sum + group.unreadCount,
        );
    final pendingApprovals =
        _visibleChatRequests(controller).length +
        controller.groupInvitations.length;

    return Material(
      color: colorScheme.surfaceContainerLow,
      child: Column(
        children: [
          const SizedBox(height: 14),
          Tooltip(
            message: '编辑头像和昵称',
            child: InkWell(
              borderRadius: BorderRadius.circular(24),
              onTap: () => _showProfileEditor(controller),
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: ProfileAvatar(
                  identity: identity,
                  imagePath: controller.profileAvatarPath,
                  radius: 19,
                ),
              ),
            ),
          ),
          const SizedBox(height: 18),
          _NavRailButton(
            key: const ValueKey('nav-rail-messages'),
            tooltip: '消息',
            icon: _navTab == _MainNavTab.messages
                ? Icons.chat_bubble
                : Icons.chat_bubble_outline,
            selected: _navTab == _MainNavTab.messages,
            badgeCount: totalUnread,
            onTap: () => setState(() {
              _navTab = _MainNavTab.messages;
              if (!_sidebarVisible) {
                _sidebarMounted = true;
                _sidebarVisible = true;
              }
            }),
          ),
          const SizedBox(height: 8),
          _NavRailButton(
            key: const ValueKey('nav-rail-contacts'),
            tooltip: '联系人',
            icon: _navTab == _MainNavTab.contacts
                ? Icons.people
                : Icons.people_outline,
            selected: _navTab == _MainNavTab.contacts,
            badgeCount: pendingApprovals,
            onTap: () => setState(() {
              _navTab = _MainNavTab.contacts;
              if (!_sidebarVisible) {
                _sidebarMounted = true;
                _sidebarVisible = true;
              }
            }),
          ),
          const SizedBox(height: 8),
          _NavRailButton(
            key: const ValueKey('nav-rail-search'),
            tooltip: '搜索联系人或群聊',
            icon: Icons.search,
            selected: false,
            badgeCount: 0,
            onTap: () => _showGlobalSearch(controller),
          ),
          const SizedBox(height: 8),
          _NavRailButton(
            key: const ValueKey('nav-rail-create-group'),
            tooltip: '创建群聊',
            icon: Icons.group_add_outlined,
            selected: false,
            badgeCount: 0,
            onTap: () => _showCreateGroup(controller),
          ),
          const Spacer(),
          _NavRailButton(
            key: const ValueKey('nav-rail-settings'),
            tooltip: '设置',
            icon: _navTab == _MainNavTab.settings
                ? Icons.settings
                : Icons.settings_outlined,
            selected: _navTab == _MainNavTab.settings,
            badgeCount: 0,
            onTap: () => setState(() {
              _navTab = _MainNavTab.settings;
              if (!_sidebarVisible) {
                _sidebarMounted = true;
                _sidebarVisible = true;
              }
            }),
          ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }

  Future<void> _showGlobalSearch(AppController controller) async {
    await showNekoDialog<void>(
      context: context,
      builder: (dialogContext) => _GlobalSearchDialog(
        controller: controller,
        onSelectPeer: (entry) async {
          Navigator.pop(dialogContext);
          final chat = entry.chat;
          if (chat != null) {
            await controller.selectChat(chat.chatId);
            if (mounted) setState(() => _navTab = _MainNavTab.messages);
            return;
          }
          // 搜索结果只包含联系人与会话；添加好友统一在“联系人 → 添加好友”里发起。
          if (entry.trustedPeer != null && !entry.trustedPeer!.blocked) {
            await _openChatWithPeer(controller, entry.deviceId);
          }
        },
        onSelectGroup: (group) async {
          Navigator.pop(dialogContext);
          await controller.selectGroup(group.groupId);
          if (mounted) setState(() => _navTab = _MainNavTab.messages);
        },
      ),
    );
  }

  Widget _buildSidebar(AppController controller) {
    return Material(
      key: const ValueKey('sidebar-content'),
      color: Theme.of(context).colorScheme.surface,
      child: Column(
        children: [
          if (controller.errorMessage != null)
            MaterialBanner(
              content: Text(controller.errorMessage!),
              actions: [
                TextButton(
                  onPressed: controller.clearError,
                  child: const Text('关闭'),
                ),
              ],
            ),
          Expanded(
            child: ClipRect(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 220),
                reverseDuration: const Duration(milliseconds: 120),
                switchInCurve: const Cubic(0.16, 1.0, 0.3, 1.0),
                switchOutCurve: Curves.easeOut,
                transitionBuilder: (child, animation) => FadeTransition(
                  opacity: animation,
                  child: SlideTransition(
                    position: Tween<Offset>(
                      begin: const Offset(0.06, 0),
                      end: Offset.zero,
                    ).animate(animation),
                    child: child,
                  ),
                ),
                child: switch (_navTab) {
                  _MainNavTab.messages => KeyedSubtree(
                    key: const ValueKey('sidebar-tab-messages'),
                    child: _buildMessagesSidebar(controller),
                  ),
                  _MainNavTab.contacts => KeyedSubtree(
                    key: const ValueKey('sidebar-tab-contacts'),
                    child: _buildContactsSidebar(controller),
                  ),
                  _MainNavTab.settings => KeyedSubtree(
                    key: const ValueKey('sidebar-tab-settings'),
                    child: _buildSettingsSidebar(controller),
                  ),
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMessagesSidebar(AppController controller) {
    final groups = controller.groups;

    final items = <({int timestamp, Widget tile})>[
      for (final entry in _conversationEntries(controller))
        (
          timestamp:
              entry.chat?.lastMessageAt?.millisecondsSinceEpoch ??
              entry.chat?.createdAt?.millisecondsSinceEpoch ??
              0,
          tile: UnifiedPeerTile(
            entry: entry,
            selected:
                entry.chat != null &&
                controller.selectedChatId == entry.chat!.chatId,
            onSecondaryTapDown: (details) =>
                _showPeerContextMenu(controller, entry, details),
            // 会话列表只负责打开已有会话；添加好友统一走“联系人 → 添加好友”。
            onTap: () async {
              final chat = entry.chat;
              if (chat != null) {
                await controller.selectChat(chat.chatId);
              }
            },
          ),
        ),
      for (final group in groups)
        (
          timestamp:
              group.lastMessageAt?.millisecondsSinceEpoch ??
              group.createdAt.millisecondsSinceEpoch,
          tile: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onSecondaryTapDown: (details) =>
                _showGroupContextMenu(controller, group, details),
            child: ListTile(
              selected: controller.selectedGroupId == group.groupId,
              leading: const CircleAvatar(
                child: Icon(Icons.groups, size: 20),
              ),
              title: Text(
                controller.groupDisplayName(group.groupId, group.name),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                _groupListSubtitle(controller, group),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: group.unreadCount > 0 || group.lastMessageAt != null
                  ? ConversationMeta(
                      time: group.lastMessageAt,
                      unreadCount: group.unreadCount,
                    )
                  : null,
              onTap: () => controller.selectGroup(group.groupId),
            ),
          ),
        ),
    ]..sort((a, b) => b.timestamp.compareTo(a.timestamp));

    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 6),
      children: [
        if (items.isEmpty)
          const EmptyHint(
            icon: Icons.person_add_alt_1,
            text: '还没有会话\n到“联系人”里点“添加好友”开始聊天',
          )
        else
          for (final item in items) item.tile,
      ],
    );
  }

  Widget _buildContactsSidebar(AppController controller) {
    final visibleRequests = _visibleChatRequests(controller);
    final groupInviteCount = controller.groupInvitations.length;
    final peersById = {for (final peer in controller.peers) peer.deviceId: peer};
    final chatsByPeer = {
      for (final chat in controller.chats) chat.peerDeviceId: chat,
    };

    final verifiedContacts =
        controller.trustedPeers.values
            .where((trusted) => !trusted.blocked)
            .toList()
          ..sort((a, b) {
            final aOnline = peersById[a.deviceId]?.online == true ? 0 : 1;
            final bOnline = peersById[b.deviceId]?.online == true ? 0 : 1;
            if (aOnline != bOnline) return aOnline.compareTo(bOnline);
            return controller
                .peerDisplayName(a.deviceId, a.displayName)
                .compareTo(
                  controller.peerDisplayName(b.deviceId, b.displayName),
                );
          });
    final onlineVerifiedCount = verifiedContacts
        .where((trusted) => peersById[trusted.deviceId]?.online == true)
        .length;

    final blockedPeers = controller.blockedPeers;

    final groups = controller.groups;

    return Column(
      children: [
        ListTile(
          key: const ValueKey('contacts-nav-friend-requests'),
          dense: true,
          selected: _contactDetailMode == _ContactDetailMode.friendRequests,
          title: const Text('新朋友'),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (visibleRequests.isNotEmpty)
                UnreadBadge(count: visibleRequests.length),
              const SizedBox(width: 4),
              const Icon(Icons.chevron_right, size: 18),
            ],
          ),
          onTap: () => setState(() {
            _contactDetailMode = _ContactDetailMode.friendRequests;
            _selectedContactDeviceId = null;
          }),
        ),
        ListTile(
          key: const ValueKey('contacts-nav-group-notifications'),
          dense: true,
          selected: _contactDetailMode == _ContactDetailMode.groupNotifications,
          title: const Text('群通知'),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (groupInviteCount > 0) UnreadBadge(count: groupInviteCount),
              const SizedBox(width: 4),
              const Icon(Icons.chevron_right, size: 18),
            ],
          ),
          onTap: () => setState(() {
            _contactDetailMode = _ContactDetailMode.groupNotifications;
            _selectedContactDeviceId = null;
          }),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
          child: SizedBox(
            width: double.infinity,
            child: SegmentedButton<_ContactsSubTab>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(
                  value: _ContactsSubTab.friends,
                  label: Text('好友'),
                ),
                ButtonSegment(
                  value: _ContactsSubTab.groups,
                  label: Text('群聊'),
                ),
              ],
              selected: {_contactsSubTab},
              onSelectionChanged: (selection) =>
                  setState(() => _contactsSubTab = selection.first),
            ),
          ),
        ),
        Expanded(
          child: _contactsSubTab == _ContactsSubTab.friends
              ? ListView(
                  key: const ValueKey('contacts-friends-list'),
                  padding: const EdgeInsets.only(bottom: 16),
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                      child: SizedBox(
                        width: double.infinity,
                        child: FilledButton.tonalIcon(
                          onPressed: () => _showAddFriendDialog(controller),
                          icon: const Icon(Icons.person_add_alt_1, size: 18),
                          label: const Text('添加好友'),
                        ),
                      ),
                    ),
                    _ContactGroupHeader(
                      title: '已验证联系人',
                      countLabel:
                          '$onlineVerifiedCount/${verifiedContacts.length}',
                      expanded: _verifiedExpanded,
                      onTap: () => setState(
                        () => _verifiedExpanded = !_verifiedExpanded,
                      ),
                    ),
                    if (_verifiedExpanded) ...[
                      if (verifiedContacts.isEmpty)
                        const EmptyHint(
                          icon: Icons.verified_user_outlined,
                          text: '暂无已验证联系人',
                        )
                      else
                        for (final trusted in verifiedContacts)
                          _buildVerifiedContactTile(
                            controller,
                            trusted: trusted,
                            peer: peersById[trusted.deviceId],
                            chat: chatsByPeer[trusted.deviceId],
                          ),
                    ],
                    if (blockedPeers.isNotEmpty) ...[
                      _ContactGroupHeader(
                        title: '黑名单',
                        countLabel: '${blockedPeers.length}',
                        expanded: _blockedExpanded,
                        onTap: () => setState(
                          () => _blockedExpanded = !_blockedExpanded,
                        ),
                      ),
                      if (_blockedExpanded)
                        for (final trusted in blockedPeers)
                          _buildVerifiedContactTile(
                            controller,
                            trusted: trusted,
                            peer: peersById[trusted.deviceId],
                            chat: chatsByPeer[trusted.deviceId],
                          ),
                    ],
                  ],
                )
              : ListView(
                  key: const ValueKey('contacts-groups-list'),
                  padding: const EdgeInsets.only(bottom: 16),
                  children: [
                    if (groups.isEmpty)
                      const EmptyHint(icon: Icons.groups_outlined, text: '还没有群聊')
                    else
                      for (final group in groups)
                        GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onSecondaryTapDown: (details) =>
                              _showGroupContextMenu(controller, group, details),
                          child: ListTile(
                            dense: true,
                            leading: const CircleAvatar(
                              radius: 18,
                              child: Icon(Icons.groups, size: 19),
                            ),
                            title: Text(
                              controller.groupDisplayName(
                                group.groupId,
                                group.name,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              group.ownerDeviceId ==
                                      controller.identity?.deviceId
                                  ? '我创建的群聊'
                                  : '已加入的群聊',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            trailing: const Icon(Icons.chevron_right, size: 18),
                            onTap: () async {
                              await controller.selectGroup(group.groupId);
                              if (!mounted) return;
                              setState(() => _navTab = _MainNavTab.messages);
                            },
                          ),
                        ),
                  ],
                ),
        ),
      ],
    );
  }

  Future<void> _showAddFriendDialog(AppController controller) async {
    final result = await showNekoDialog<_AddFriendResult>(
      context: context,
      builder: (dialogContext) => _AddFriendDialog(controller: controller),
    );
    if (result == null) return;
    await controller.requestChat(
      result.peer,
      viaPairingCode: result.viaPairingCode,
      code: result.code,
    );
    if (!mounted) return;
    setState(() {
      _navTab = _MainNavTab.contacts;
      _contactsSubTab = _ContactsSubTab.friends;
      _contactDetailMode = _ContactDetailMode.friendRequests;
      _selectedContactDeviceId = null;
    });
  }

  Widget _buildVerifiedContactTile(
    AppController controller, {
    required TrustedPeer trusted,
    required DiscoveredPeer? peer,
    required ChatSummary? chat,
  }) {
    final originalName = peer?.displayName ?? trusted.displayName;
    final displayName = controller.peerDisplayName(
      trusted.deviceId,
      originalName,
    );
    final online = peer?.online == true;
    final selected =
        _contactDetailMode == _ContactDetailMode.peer &&
        _selectedContactDeviceId == trusted.deviceId;
    final entry = UnifiedPeerEntry(
      deviceId: trusted.deviceId,
      displayName: displayName,
      originalDisplayName: originalName,
      peer: peer,
      chat: chat,
      trustedPeer: trusted,
      avatarPath: controller.peerAvatarPath(trusted.deviceId),
    );
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onSecondaryTapDown: (details) =>
          _showPeerContextMenu(controller, entry, details),
      child: ListTile(
        dense: true,
        selected: selected,
        leading: Stack(
          children: [
            NamedAvatar(
              imagePath: entry.avatarPath,
              name: displayName,
              radius: 18,
            ),
            Positioned(
              right: 0,
              bottom: 0,
              child: Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: online ? Colors.green : Colors.grey,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: Theme.of(context).colorScheme.surface,
                    width: 1.5,
                  ),
                ),
              ),
            ),
          ],
        ),
        title: Row(
          children: [
            Flexible(
              child: Text(displayName, overflow: TextOverflow.ellipsis),
            ),
            if (!trusted.blocked) ...[
              const SizedBox(width: 4),
              const Icon(Icons.verified, color: Colors.blue, size: 15),
            ],
          ],
        ),
        subtitle: Text(
          trusted.blocked
              ? '已拉黑'
              : (online ? '在线 · ${peer!.ip}' : '离线 · ${trusted.lastKnownIp}'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        onTap: () => setState(() {
          _contactDetailMode = _ContactDetailMode.peer;
          _selectedContactDeviceId = trusted.deviceId;
        }),
      ),
    );
  }

  Widget _buildSettingsSidebar(AppController controller) {
    return ListView(
      key: const ValueKey('settings-sidebar-list'),
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        const SectionTitle(title: '设置'),
        for (final section in SettingsSection.values)
          ListTile(
            key: ValueKey('settings-nav-${section.name}'),
            dense: true,
            selected: _settingsSection == section,
            leading: Icon(section.icon, size: 20),
            title: Text(section.title),
            subtitle: Text(
              section.subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            onTap: () => setState(() => _settingsSection = section),
          ),
      ],
    );
  }

  Widget _buildContent(AppController controller) {
    final child = switch (_navTab) {
      _MainNavTab.messages => _buildMessagesContent(controller),
      _MainNavTab.contacts => KeyedSubtree(
        key: ValueKey(
          'content-contacts-${_contactDetailMode.name}-${_selectedContactDeviceId ?? ''}',
        ),
        child: _buildContactsContent(controller),
      ),
      _MainNavTab.settings => SettingsSectionPane(
        key: const ValueKey('content-settings'),
        controller: controller,
        section: _settingsSection,
      ),
    };
    return ClipRect(
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 240),
        reverseDuration: const Duration(milliseconds: 120),
        switchInCurve: const Cubic(0.16, 1.0, 0.3, 1.0),
        switchOutCurve: Curves.easeOut,
        transitionBuilder: (widget, animation) {
          final isIncoming = widget.key == child.key;
          if (!isIncoming) {
            return FadeTransition(opacity: animation, child: widget);
          }
          return FadeTransition(
            opacity: CurvedAnimation(
              parent: animation,
              curve: const Interval(0.0, 0.75, curve: Curves.easeOut),
            ),
            child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, 0.035),
                end: Offset.zero,
              ).animate(animation),
              child: ScaleTransition(
                scale: Tween<double>(begin: 0.988, end: 1.0).animate(animation),
                child: widget,
              ),
            ),
          );
        },
        child: child,
      ),
    );
  }

  Widget _buildContactsContent(AppController controller) {
    switch (_contactDetailMode) {
      case _ContactDetailMode.friendRequests:
        return FriendRequestsPane(
          controller: controller,
          requests: _visibleChatRequests(controller),
        );
      case _ContactDetailMode.groupNotifications:
        return GroupNotificationsPane(
          controller: controller,
          invitations: controller.groupInvitations.values.toList(),
        );
      case _ContactDetailMode.peer:
        final deviceId = _selectedContactDeviceId;
        final trusted = deviceId == null
            ? null
            : controller.trustedPeers[deviceId];
        if (deviceId != null && trusted != null) {
          final peer = controller.peers
              .where((value) => value.deviceId == deviceId)
              .firstOrNull;
          final originalName = peer?.displayName ?? trusted.displayName;
          final displayName = controller.peerDisplayName(
            deviceId,
            originalName,
          );
          return ContactDetailPane(
            controller: controller,
            trustedPeer: trusted,
            discoveredPeer: peer,
            onStartChat: () => _openChatWithPeer(controller, deviceId),
            onEditRemark: () =>
                _showPeerRemark(context, controller, deviceId, originalName),
            onToggleBlock: () async {
              if (trusted.blocked) {
                if (await _confirmUnblockPeer(displayName)) {
                  await controller.setBlocked(deviceId, false);
                }
              } else if (await _confirmBlockPeer(displayName)) {
                await controller.setBlocked(deviceId, true);
              }
            },
            onRevokeVerification: () async {
              if (await _confirmRevokeVerification(displayName)) {
                await controller.revokePeerVerification(deviceId);
                if (mounted) {
                  setState(() {
                    _contactDetailMode = _ContactDetailMode.none;
                    _selectedContactDeviceId = null;
                  });
                }
              }
            },
          );
        }
        return const _ContactsPlaceholderPane();
      case _ContactDetailMode.none:
        return const _ContactsPlaceholderPane();
    }
  }

  Widget _buildMessagesContent(AppController controller) {
    if (controller.selectedChatId != null) {
      final chat = controller.chats
          .where((value) => value.chatId == controller.selectedChatId)
          .firstOrNull;
      if (chat != null) {
        final online = _peerOnline(controller, chat.peerDeviceId);
        final conversationId = chat.chatId;
        final originalDisplayName =
            controller.peers
                .where((peer) => peer.deviceId == chat.peerDeviceId)
                .firstOrNull
                ?.displayName ??
            chat.displayName;
        final displayName = controller.peerDisplayName(
          chat.peerDeviceId,
          originalDisplayName,
        );
        final drawerOpen = _peerDrawerOpen && _peerDrawerChatId == chat.chatId;
        return _ConversationPane(
          key: ValueKey('content-chat-${chat.chatId}'),
          conversationId: conversationId,
          title: displayName,
          subtitle: [
            if (displayName != originalDisplayName) '原名：$originalDisplayName',
            online ? '在线' : '离线 · 消息不会离线排队',
          ].join(' · '),
          messages: controller.messages,
          localDeviceId: controller.identity!.deviceId,
          peerName: (deviceId) =>
              deviceId == chat.peerDeviceId ? displayName : '我',
          composer: _composerFor(conversationId),
          pendingAttachments: _pendingFor(conversationId),
          enabled: online && chat.state == ChatSessionState.active,
          isGroup: false,
          senderHeaderFor: (deviceId) =>
              deviceId == controller.identity!.deviceId
              ? controller.identity!.displayName
              : displayName,
          avatarPathFor: (deviceId) => deviceId == controller.identity!.deviceId
              ? controller.profileAvatarPath
              : controller.peerAvatarPath(deviceId),
          onSend: (text, attachments) => controller.sendMessageWithAttachments(
            conversationId: conversationId,
            content: text,
            attachments: attachments,
          ),
          onPickAttachments: controller.pickAttachments,
          onDropFiles: (paths) => controller.sendDroppedFiles(
            conversationId: conversationId,
            filePaths: paths,
          ),
          onReadClipboardAttachments: controller.readClipboardAttachments,
          onOpenAttachment: controller.openAttachment,
          onOpenAttachmentFolder: controller.openAttachmentFolder,
          onAcceptFile: controller.acceptIncomingFile,
          onRejectFile: controller.rejectIncomingFile,
          onRetryFile: controller.retryFileDownload,
          onRelocateFile: controller.relocateAttachment,
          missingHintFor: controller.attachmentMissingHint,
          replyingTo: controller.replyingTo,
          onCancelReply: controller.cancelReply,
          onCopyMessage: controller.copyMessage,
          onReplyMessage: controller.beginReply,
          canRecallMessage: controller.canRecallMessage,
          onRecallMessage: controller.recallMessage,
          recallNoticeFor: controller.recallNotice,
          favoriteStickers: controller.favoriteStickers,
          onPickFavoriteStickers: controller.pickAndAddFavoriteStickers,
          onSendFavoriteSticker: (sticker) => controller.sendFavoriteSticker(
            sticker,
            conversationId: conversationId,
          ),
          onRemoveFavoriteSticker: controller.removeFavoriteSticker,
          onReorderFavoriteStickers: controller.reorderFavoriteStickers,
          onSetFavoriteStickerRemark: controller.setFavoriteStickerRemark,
          stickerSuggestionsEnabled: controller.stickerSuggestionsEnabled,
          sendOnCtrlEnter: controller.sendOnCtrlEnter,
          onSendOnCtrlEnterChanged: controller.setSendOnCtrlEnter,
          onAddMessageToStickers: controller.addMessageToFavoriteStickers,
          actions: [
            IconButton(
              tooltip: '会话操作',
              onPressed: () => setState(() {
                if (drawerOpen) {
                  _peerDrawerOpen = false;
                } else {
                  _groupDrawerOpen = false;
                  _peerDrawerChatId = chat.chatId;
                  _peerDrawerOpen = true;
                }
              }),
              icon: Icon(
                Icons.more_horiz,
                color: drawerOpen
                    ? Theme.of(context).colorScheme.primary
                    : null,
              ),
            ),
          ],
        );
      }
    }
    if (controller.selectedGroupId != null) {
      final group = controller.groups
          .where((value) => value.groupId == controller.selectedGroupId)
          .firstOrNull;
      if (group != null) {
        final conversationId = 'group:${group.groupId}';
        final composer = _composerFor(conversationId);
        final displayName = controller.groupDisplayName(
          group.groupId,
          group.name,
        );
        final drawerOpen =
            _groupDrawerOpen && _groupDrawerGroupId == group.groupId;
        return _ConversationPane(
          key: ValueKey('content-group-${group.groupId}'),
          conversationId: conversationId,
          title: displayName,
          subtitle: [
            if (displayName != group.name) '原群名：${group.name}',
            '局域网实时群聊 · 离线成员不会收到消息',
          ].join(' · '),
          messages: controller.messages,
          localDeviceId: controller.identity!.deviceId,
          peerName: (deviceId) {
            if (deviceId == controller.identity!.deviceId) return '我';
            final originalName =
                controller.peers
                    .where((peer) => peer.deviceId == deviceId)
                    .firstOrNull
                    ?.displayName ??
                controller.trustedPeers[deviceId]?.displayName ??
                '群成员';
            return controller.peerDisplayName(deviceId, originalName);
          },
          composer: composer,
          pendingAttachments: _pendingFor(conversationId),
          enabled: true,
          isGroup: true,
          avatarPathFor: (deviceId) => deviceId == controller.identity!.deviceId
              ? controller.profileAvatarPath
              : controller.peerAvatarPath(deviceId),
          senderRoleFor: (deviceId) =>
              controller.groupMemberRole(group.groupId, deviceId),
          senderHeaderFor: (deviceId) {
            if (deviceId == controller.identity!.deviceId) {
              return controller.identity!.displayName;
            }
            final originalName =
                controller.peers
                    .where((peer) => peer.deviceId == deviceId)
                    .firstOrNull
                    ?.displayName ??
                controller.trustedPeers[deviceId]?.displayName ??
                '群成员';
            return controller.peerDisplayName(deviceId, originalName);
          },
          onSend: (text, attachments) => controller.sendMessageWithAttachments(
            conversationId: conversationId,
            content: text,
            attachments: attachments,
          ),
          onPickAttachments: controller.pickAttachments,
          onDropFiles: (paths) => controller.sendDroppedFiles(
            conversationId: conversationId,
            filePaths: paths,
          ),
          onReadClipboardAttachments: controller.readClipboardAttachments,
          onOpenAttachment: controller.openAttachment,
          onOpenAttachmentFolder: controller.openAttachmentFolder,
          onAcceptFile: controller.acceptIncomingFile,
          onRejectFile: controller.rejectIncomingFile,
          onRetryFile: controller.retryFileDownload,
          onRelocateFile: controller.relocateAttachment,
          missingHintFor: controller.attachmentMissingHint,
          replyingTo: controller.replyingTo,
          onCancelReply: controller.cancelReply,
          onCopyMessage: controller.copyMessage,
          onReplyMessage: controller.beginReply,
          canRecallMessage: controller.canRecallMessage,
          onRecallMessage: controller.recallMessage,
          recallNoticeFor: controller.recallNotice,
          favoriteStickers: controller.favoriteStickers,
          onPickFavoriteStickers: controller.pickAndAddFavoriteStickers,
          onSendFavoriteSticker: (sticker) => controller.sendFavoriteSticker(
            sticker,
            conversationId: conversationId,
          ),
          onRemoveFavoriteSticker: controller.removeFavoriteSticker,
          onReorderFavoriteStickers: controller.reorderFavoriteStickers,
          onSetFavoriteStickerRemark: controller.setFavoriteStickerRemark,
          stickerSuggestionsEnabled: controller.stickerSuggestionsEnabled,
          sendOnCtrlEnter: controller.sendOnCtrlEnter,
          onSendOnCtrlEnterChanged: controller.setSendOnCtrlEnter,
          onAddMessageToStickers: controller.addMessageToFavoriteStickers,
          onMention: (name) => _insertMention(composer, name),
          loadMentionCandidates: () async {
            final members = await controller.groupMembers(group.groupId);
            return [
              for (final member in members)
                if (member.deviceId != controller.identity!.deviceId)
                  MentionCandidate(
                    deviceId: member.deviceId,
                    displayName: controller.peerDisplayName(
                      member.deviceId,
                      member.displayName,
                    ),
                    insertionName: member.displayName,
                    originalName:
                        controller.peerRemarks.containsKey(member.deviceId)
                        ? member.displayName
                        : null,
                  ),
            ];
          },
          actions: [
            IconButton(
              tooltip: '群聊操作',
              onPressed: () => setState(() {
                if (drawerOpen) {
                  _groupDrawerOpen = false;
                } else {
                  _peerDrawerOpen = false;
                  _groupDrawerGroupId = group.groupId;
                  _groupDrawerOpen = true;
                }
              }),
              icon: Icon(
                Icons.more_horiz,
                color: drawerOpen
                    ? Theme.of(context).colorScheme.primary
                    : null,
              ),
            ),
          ],
        );
      }
    }
    return WelcomePane(
      key: const ValueKey('content-welcome'),
      controller: controller,
    );
  }

  /// 全窗口级别的右侧悬浮面板（遮罩覆盖导航栏、侧边栏与聊天区，沉浸感更强）。
  Widget _buildRootDrawerOverlay(AppController controller) {
    Widget? activeDrawer;
    if (_navTab == _MainNavTab.messages) {
      if (_peerDrawerOpen &&
          controller.selectedChatId != null &&
          _peerDrawerChatId == controller.selectedChatId) {
        final chat = controller.chats
            .where((value) => value.chatId == controller.selectedChatId)
            .firstOrNull;
        if (chat != null) {
          activeDrawer = PeerInfoDrawer(
            key: ValueKey('root-peer-drawer-${chat.chatId}'),
            controller: controller,
            chat: chat,
            onClose: () => setState(() => _peerDrawerOpen = false),
            onOpenInWindow: () =>
                openConversationInWindow(context, controller, chat.chatId),
          );
        }
      } else if (_groupDrawerOpen &&
          controller.selectedGroupId != null &&
          _groupDrawerGroupId == controller.selectedGroupId) {
        final group = controller.groups
            .where((value) => value.groupId == controller.selectedGroupId)
            .firstOrNull;
        if (group != null) {
          final composer = _composerFor('group:${group.groupId}');
          activeDrawer = GroupInfoDrawer(
            key: ValueKey('root-group-drawer-${group.groupId}'),
            controller: controller,
            group: group,
            onClose: () => setState(() => _groupDrawerOpen = false),
            onOpenInWindow: () => widget.openConversationWindow(
              context,
              controller,
              'group:${group.groupId}',
            ),
            onMentionMember: (name) => _insertMention(composer, name),
          );
        }
      }
    }
    if (activeDrawer != null) {
      _cachedDrawer = activeDrawer;
    }
    return _FloatingDrawerOverlay(
      open: activeDrawer != null,
      onDismiss: () => setState(() {
        _peerDrawerOpen = false;
        _groupDrawerOpen = false;
      }),
      drawer: activeDrawer ?? _cachedDrawer ?? const SizedBox.shrink(),
    );
  }

  Future<void> _showProfileEditor(AppController controller) async {
    var displayName = controller.identity!.displayName;
    String? errorText;
    var saving = false;
    await showNekoDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('编辑个人资料'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ProfileAvatar(
                  identity: controller.identity!,
                  imagePath: controller.profileAvatarPath,
                  radius: 46,
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  alignment: WrapAlignment.center,
                  children: [
                    OutlinedButton.icon(
                      onPressed: saving
                          ? null
                          : () async {
                              try {
                                await controller.pickProfileAvatar();
                                if (dialogContext.mounted) {
                                  setDialogState(() => errorText = null);
                                }
                              } on Object catch (error) {
                                if (dialogContext.mounted) {
                                  setDialogState(
                                    () => errorText = _profileError(error),
                                  );
                                }
                              }
                            },
                      icon: const Icon(Icons.photo_camera_outlined),
                      label: Text(
                        controller.profileAvatarPath == null ? '选择头像' : '更换头像',
                      ),
                    ),
                    if (controller.profileAvatarPath != null)
                      TextButton.icon(
                        onPressed: saving
                            ? null
                            : () async {
                                await controller.removeProfileAvatar();
                                if (dialogContext.mounted) {
                                  setDialogState(() => errorText = null);
                                }
                              },
                        icon: const Icon(Icons.delete_outline),
                        label: const Text('恢复默认'),
                      ),
                  ],
                ),
                const SizedBox(height: 18),
                TextFormField(
                  initialValue: displayName,
                  autofocus: true,
                  maxLength: NetworkConfig.maxDisplayNameLength,
                  decoration: InputDecoration(
                    labelText: '昵称',
                    prefixIcon: const Icon(Icons.badge_outlined),
                    errorText: errorText,
                  ),
                  onChanged: (value) => displayName = value,
                  onFieldSubmitted: saving
                      ? null
                      : (value) => _saveProfileName(
                          dialogContext,
                          controller,
                          value,
                          setDialogState,
                          (value) => saving = value,
                          (message) => errorText = message,
                        ),
                ),
                const Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '头像与昵称会同步给局域网内的其他设备；对端离线时会在其上线后补同步。',
                    style: TextStyle(fontSize: 12, color: Colors.black54),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: saving ? null : () => Navigator.pop(dialogContext),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: saving
                  ? null
                  : () => _saveProfileName(
                      dialogContext,
                      controller,
                      displayName,
                      setDialogState,
                      (value) => saving = value,
                      (message) => errorText = message,
                    ),
              child: saving
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('保存'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _saveProfileName(
    BuildContext dialogContext,
    AppController controller,
    String value,
    StateSetter setDialogState,
    ValueChanged<bool> setSaving,
    ValueChanged<String?> setError,
  ) async {
    if (!isValidDisplayName(value)) {
      setDialogState(() => setError('昵称长度应为 1～32 个字符'));
      return;
    }
    setDialogState(() => setSaving(true));
    try {
      await controller.setDisplayName(value);
      if (dialogContext.mounted) Navigator.pop(dialogContext);
    } on Object catch (error) {
      if (dialogContext.mounted) {
        setDialogState(() {
          setSaving(false);
          setError(_profileError(error));
        });
      }
    }
  }

  String _profileError(Object error) => error is ArgumentError
      ? error.message?.toString() ?? '个人资料无效'
      : '保存失败：$error';

  /// 把“@昵称 ”插到输入框光标处。
  static void _insertMention(TextEditingController composer, String name) {
    final value = composer.value;
    final selection = value.selection.isValid
        ? value.selection
        : TextSelection.collapsed(offset: value.text.length);
    final mention = '@$name ';
    final updated = value.text.replaceRange(
      selection.start,
      selection.end,
      mention,
    );
    composer.value = value.copyWith(
      text: updated,
      selection: TextSelection.collapsed(
        offset: selection.start + mention.length,
      ),
      composing: TextRange.empty,
    );
  }

  Future<void> _showCreateGroup(AppController controller) async {
    var name = '';
    final available = controller.peers
        .where((peer) => peer.online && peer.trusted)
        .toList();
    final selected = <String>{};
    final create = await showNekoDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('创建群聊'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextFormField(
                  autofocus: true,
                  maxLength: 40,
                  decoration: const InputDecoration(labelText: '群名称'),
                  onChanged: (value) => name = value,
                ),
                const SizedBox(height: 10),
                const Text('邀请已验证且在线的设备'),
                const SizedBox(height: 6),
                if (available.isEmpty)
                  const Text('暂无可邀请设备', style: TextStyle(color: Colors.grey))
                else
                  SizedBox(
                    height: 180,
                    child: ListView(
                      children: [
                        for (final peer in available)
                          CheckboxListTile(
                            value: selected.contains(peer.deviceId),
                            title: Text(
                              controller.peerDisplayName(
                                peer.deviceId,
                                peer.displayName,
                              ),
                            ),
                            subtitle: Text(
                              controller.peerRemarks.containsKey(peer.deviceId)
                                  ? '${peer.displayName} · ${peer.ip}'
                                  : peer.ip,
                            ),
                            onChanged: (value) => setDialogState(
                              () => value == true
                                  ? selected.add(peer.deviceId)
                                  : selected.remove(peer.deviceId),
                            ),
                          ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('创建'),
            ),
          ],
        ),
      ),
    );
    if (create == true && name.trim().isNotEmpty) {
      final group = await controller.createGroup(
        name,
        available.where((peer) => selected.contains(peer.deviceId)).toList(),
      );
      await controller.selectGroup(group.groupId);
    }
  }

  static Future<void> _showInviteMembers(
    BuildContext context,
    AppController controller,
    ChatGroup group,
  ) async {
    final existingIds = (await controller.groupMembers(
      group.groupId,
    )).map((member) => member.deviceId).toSet();
    if (!context.mounted) return;
    final available = controller.peers
        .where(
          (peer) =>
              peer.online &&
              peer.trusted &&
              !existingIds.contains(peer.deviceId),
        )
        .toList();
    final peer = await showNekoDialog<DiscoveredPeer>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('邀请成员'),
        children: available.isEmpty
            ? [
                const Padding(
                  padding: EdgeInsets.all(20),
                  child: Text('暂无已验证且在线的设备'),
                ),
              ]
            : [
                for (final value in available)
                  SimpleDialogOption(
                    onPressed: () => Navigator.pop(dialogContext, value),
                    child: ListTile(
                      leading: const Icon(Icons.person_add),
                      title: Text(
                        controller.peerDisplayName(
                          value.deviceId,
                          value.displayName,
                        ),
                      ),
                      subtitle: Text(
                        controller.peerRemarks.containsKey(value.deviceId)
                            ? '${value.displayName} · ${value.ip}'
                            : value.ip,
                      ),
                    ),
                  ),
              ],
      ),
    );
    if (peer != null) await controller.inviteToGroup(group, peer);
  }

  static Future<void> _showGroupMembers(
    BuildContext context,
    AppController controller,
    ChatGroup group,
  ) async {
    final members = await controller.groupMembers(group.groupId);
    if (!context.mounted) return;
    final myRole = members
        .where((member) => member.deviceId == controller.identity!.deviceId)
        .firstOrNull
        ?.role;
    final isOwner = myRole == GroupRole.owner;
    final isAdmin = myRole == GroupRole.admin;
    await showNekoDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(
            '${controller.groupDisplayName(group.groupId, group.name)} · 群成员',
          ),
          content: SizedBox(
            width: 440,
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final member in members)
                  ListTile(
                    leading: NamedAvatar(
                      imagePath: controller.peerAvatarPath(member.deviceId),
                      name: controller.peerDisplayName(
                        member.deviceId,
                        member.displayName,
                      ),
                    ),
                    title: Text(
                      controller.peerDisplayName(
                        member.deviceId,
                        member.displayName,
                      ),
                    ),
                    subtitle: Text(
                      [
                        if (controller.peerRemarks.containsKey(member.deviceId))
                          '原名：${member.displayName}',
                        _groupRoleLabel(member.role),
                      ].join(' · '),
                    ),
                    trailing: member.deviceId == controller.identity!.deviceId
                        ? null
                        : Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                tooltip: '修改人员备注',
                                onPressed: () async {
                                  await _showPeerRemark(
                                    context,
                                    controller,
                                    member.deviceId,
                                    member.displayName,
                                  );
                                  if (dialogContext.mounted) {
                                    setDialogState(() {});
                                  }
                                },
                                icon: const Icon(Icons.edit_note_outlined),
                              ),
                              if (isOwner && member.role != GroupRole.owner)
                                IconButton(
                                  tooltip:
                                      member.role == GroupRole.admin
                                      ? '取消管理员'
                                      : '设为管理员',
                                  onPressed: () async {
                                    await controller.setGroupMemberRole(
                                      group,
                                      member,
                                      member.role == GroupRole.admin
                                          ? GroupRole.member
                                          : GroupRole.admin,
                                    );
                                    if (dialogContext.mounted) {
                                      Navigator.pop(dialogContext);
                                    }
                                  },
                                  icon: Icon(
                                    member.role == GroupRole.admin
                                        ? Icons.remove_moderator_outlined
                                        : Icons.add_moderator_outlined,
                                  ),
                                ),
                              if ((isOwner ||
                                      (isAdmin &&
                                          member.role == GroupRole.member)) &&
                                  member.role != GroupRole.owner)
                                IconButton(
                                  tooltip: '移除成员',
                                  onPressed: () async {
                                    await controller.removeGroupMember(
                                      group,
                                      member,
                                    );
                                    if (dialogContext.mounted) {
                                      Navigator.pop(dialogContext);
                                    }
                                  },
                                  icon: const Icon(
                                    Icons.person_remove_outlined,
                                  ),
                                ),
                            ],
                          ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('关闭'),
            ),
          ],
        ),
      ),
    );
  }

  static Future<void> _showRenameGroup(
    BuildContext context,
    AppController controller,
    ChatGroup group,
  ) async {
    var name = group.name;
    final accepted = await showNekoDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('修改群名'),
        content: TextFormField(
          initialValue: name,
          autofocus: true,
          maxLength: 40,
          decoration: const InputDecoration(labelText: '群名称'),
          onChanged: (value) => name = value,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (accepted == true) await controller.renameGroup(group, name);
  }

  static Future<void> _showPeerRemark(
    BuildContext context,
    AppController controller,
    String deviceId,
    String originalName,
  ) => _showRemarkEditor(
    context: context,
    title: '人员备注',
    originalName: originalName,
    currentRemark: controller.peerRemarks[deviceId],
    onSave: (value) => controller.setPeerRemark(deviceId, value),
  );

  /// 对端资料卡：头像、昵称/备注、设备与网络状态。入口在右键菜单和会话右上角。
  Future<void> _showPeerInfo(
    AppController controller,
    String deviceId, {
    String? fallbackName,
  }) async {
    final peer = controller.peers
        .where((value) => value.deviceId == deviceId)
        .firstOrNull;
    final trusted = controller.trustedPeers[deviceId];
    final originalName =
        peer?.displayName ?? trusted?.displayName ?? fallbackName ?? '未知设备';
    final displayName = controller.peerDisplayName(deviceId, originalName);
    final remark = controller.peerRemarks[deviceId];
    final rows = <(IconData, String, String)>[
      (Icons.badge_outlined, '昵称', originalName),
      if (remark != null) (Icons.edit_note_outlined, '备注', remark),
      (Icons.fingerprint, '设备 ID', deviceId),
      (Icons.lan_outlined, '网络', peer?.ip ?? '离线'),
      (
        Icons.wifi_tethering,
        '在线状态',
        peer?.online == true ? '在线' : '离线',
      ),
      (
        Icons.verified_user_outlined,
        '验证状态',
        trusted == null ? '未验证' : (trusted.blocked ? '已拉黑' : '已验证'),
      ),
      if (peer != null) (Icons.settings_ethernet, '端口', '${peer.port}'),
    ];
    if (!mounted) return;
    await showNekoDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('人员资料'),
        content: SizedBox(
          width: 400,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: NamedAvatar(
                  imagePath: controller.peerAvatarPath(deviceId),
                  name: displayName,
                  radius: 36,
                ),
              ),
              const SizedBox(height: 12),
              Center(
                child: Text(
                  displayName,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              const SizedBox(height: 16),
              for (final row in rows)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(row.$1, size: 18, color: Colors.grey),
                      const SizedBox(width: 10),
                      SizedBox(
                        width: 72,
                        child: Text(
                          row.$2,
                          style: const TextStyle(color: Colors.grey),
                        ),
                      ),
                      Expanded(
                        child: SelectableText(
                          row.$3,
                          style: const TextStyle(fontWeight: FontWeight.w500),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        actions: [
          if (trusted != null)
            TextButton(
              onPressed: () async {
                Navigator.pop(dialogContext);
                if (await _confirmRevokeVerification(displayName)) {
                  await controller.revokePeerVerification(deviceId);
                }
              },
              child: const Text('取消验证'),
            ),
          if (trusted?.blocked == true)
            FilledButton.tonal(
              onPressed: () async {
                Navigator.pop(dialogContext);
                if (await _confirmUnblockPeer(displayName)) {
                  await controller.setBlocked(deviceId, false);
                }
              },
              child: const Text('解除拉黑'),
            ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Future<void> _showPeerContextMenu(
    AppController controller,
    UnifiedPeerEntry entry,
    TapDownDetails details,
  ) async {
    final isBlocked = entry.trustedPeer?.blocked == true;
    final action = await showNekoContextMenu<_PeerContextAction>(
      context: context,
      position: details.globalPosition,
      width: 164,
      items: [
        NekoContextMenuItem(
          value: _PeerContextAction.openInWindow,
          enabled: entry.chat != null,
          icon: Icons.open_in_new,
          label: '在独立窗口打开',
        ),
        const NekoContextMenuItem(
          value: _PeerContextAction.info,
          icon: Icons.badge_outlined,
          label: '查看资料',
        ),
        const NekoContextMenuItem(
          value: _PeerContextAction.remark,
          icon: Icons.drive_file_rename_outline,
          label: '修改备注',
        ),
        NekoContextMenuItem(
          value: _PeerContextAction.delete,
          enabled: entry.chat != null,
          hasDividerBefore: true,
          destructive: true,
          icon: Icons.delete_outline,
          label: '删除对话',
        ),
        if (entry.trustedPeer != null)
          const NekoContextMenuItem(
            value: _PeerContextAction.revokeVerification,
            icon: Icons.gpp_bad_outlined,
            label: '取消验证',
          ),
        NekoContextMenuItem(
          value: _PeerContextAction.block,
          enabled: entry.trustedPeer != null,
          destructive: !isBlocked,
          icon: isBlocked ? Icons.check_circle_outline : Icons.block,
          label: isBlocked ? '解除拉黑' : '拉黑此人',
        ),
      ],
    );
    if (action == null || !mounted) return;
    switch (action) {
      case _PeerContextAction.openInWindow:
        final chat = entry.chat;
        if (chat != null) {
          await widget.openConversationWindow(context, controller, chat.chatId);
        }
      case _PeerContextAction.info:
        await _showPeerInfo(
          controller,
          entry.deviceId,
          fallbackName: entry.originalDisplayName,
        );
      case _PeerContextAction.remark:
        await _showPeerRemark(
          context,
          controller,
          entry.deviceId,
          entry.originalDisplayName,
        );
      case _PeerContextAction.delete:
        final chat = entry.chat;
        if (chat != null && await _confirmDeleteChat(entry.displayName)) {
          await controller.deleteChat(chat);
          final composer = _composers.remove(chat.chatId);
          composer?.dispose();
          _pendingAttachments.remove(chat.chatId);
        }
      case _PeerContextAction.revokeVerification:
        if (await _confirmRevokeVerification(entry.displayName)) {
          await controller.revokePeerVerification(entry.deviceId);
        }
      case _PeerContextAction.block:
        if (entry.trustedPeer?.blocked == true) {
          if (await _confirmUnblockPeer(entry.displayName)) {
            await controller.setBlocked(entry.deviceId, false);
          }
        } else if (await _confirmBlockPeer(entry.displayName)) {
          await controller.setBlocked(entry.deviceId, true);
        }
    }
  }

  Future<bool> _confirmDeleteChat(String displayName) async =>
      await showNekoDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('删除对话？'),
          content: Text('将删除与“$displayName”的本地聊天记录，此操作无法撤销。已接收的文件不会被删除。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('删除'),
            ),
          ],
        ),
      ) ??
      false;

  Future<bool> _confirmBlockPeer(String displayName) async =>
      await showNekoDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('拉黑此人？'),
          content: Text('拉黑“$displayName”后，将不再接受此人的聊天请求和消息。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('拉黑'),
            ),
          ],
        ),
      ) ??
      false;

  Future<bool> _confirmUnblockPeer(String displayName) async =>
      await showNekoDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('解除拉黑？'),
          content: Text('解除对“$displayName”的拉黑后，将重新接受此人的聊天请求和消息。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('解除拉黑'),
            ),
          ],
        ),
      ) ??
      false;

  Future<bool> _confirmRevokeVerification(String displayName) async =>
      await showNekoDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('取消验证？'),
          content: Text('取消对“$displayName”的验证后，对方将移出已验证联系人，下次聊天需重新发起好友申请并通过。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('取消验证'),
            ),
          ],
        ),
      ) ??
      false;

  static Future<void> _showGroupRemark(
    BuildContext context,
    AppController controller,
    ChatGroup group,
  ) => _showRemarkEditor(
    context: context,
    title: '群聊备注',
    originalName: group.name,
    currentRemark: controller.groupRemarks[group.groupId],
    onSave: (value) => controller.setGroupRemark(group.groupId, value),
  );

  /// 侧边栏群聊右键菜单，复用会话内已有的群操作。
  Future<void> _showGroupContextMenu(
    AppController controller,
    ChatGroup group,
    TapDownDetails details,
  ) async {
    final isOwner = group.ownerDeviceId == controller.identity!.deviceId;
    final action = await showNekoContextMenu<_GroupContextAction>(
      context: context,
      position: details.globalPosition,
      width: 164,
      items: [
        const NekoContextMenuItem(
          value: _GroupContextAction.openInWindow,
          icon: Icons.open_in_new,
          label: '在独立窗口打开',
        ),
        const NekoContextMenuItem(
          value: _GroupContextAction.members,
          icon: Icons.people_outline,
          label: '群成员',
        ),
        NekoContextMenuItem(
          value: _GroupContextAction.remark,
          icon: Icons.drive_file_rename_outline,
          label: controller.groupRemarks.containsKey(group.groupId)
              ? '修改群聊备注'
              : '添加群聊备注',
        ),
        const NekoContextMenuItem(
          value: _GroupContextAction.invite,
          icon: Icons.person_add_alt_1,
          label: '邀请在线成员',
        ),
        if (isOwner)
          const NekoContextMenuItem(
            value: _GroupContextAction.rename,
            icon: Icons.edit_outlined,
            label: '修改群名',
          ),
        NekoContextMenuItem(
          value: _GroupContextAction.leave,
          hasDividerBefore: true,
          destructive: true,
          icon: isOwner ? Icons.delete_outline : Icons.logout,
          label: isOwner ? '解散群聊' : '退出群聊',
        ),
      ],
    );
    if (action == null || !mounted) return;
    switch (action) {
      case _GroupContextAction.openInWindow:
        await widget.openConversationWindow(
          context,
          controller,
          'group:${group.groupId}',
        );
      case _GroupContextAction.members:
        await _showGroupMembers(context, controller, group);
      case _GroupContextAction.remark:
        await _showGroupRemark(context, controller, group);
      case _GroupContextAction.invite:
        await _showInviteMembers(context, controller, group);
      case _GroupContextAction.rename:
        await _showRenameGroup(context, controller, group);
      case _GroupContextAction.leave:
        await _confirmLeaveGroup(context, controller, group);
    }
  }

  static Future<void> _showRemarkEditor({
    required BuildContext context,
    required String title,
    required String originalName,
    required String? currentRemark,
    required Future<void> Function(String value) onSave,
  }) async {
    var remark = currentRemark ?? '';
    final accepted = await showNekoDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 400,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('原始名称：$originalName'),
              const SizedBox(height: 14),
              TextFormField(
                initialValue: remark,
                autofocus: true,
                maxLength: NetworkConfig.maxRemarkLength,
                decoration: const InputDecoration(
                  labelText: '备注',
                  hintText: '留空即清除备注',
                ),
                onChanged: (value) => remark = value,
                onFieldSubmitted: (_) => Navigator.pop(dialogContext, true),
              ),
              const Text(
                '备注只保存在本机，不会发送给对方。',
                style: TextStyle(color: Colors.black54, fontSize: 12),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (accepted == true) await onSave(remark);
  }

  static Future<void> _confirmLeaveGroup(
    BuildContext context,
    AppController controller,
    ChatGroup group,
  ) async {
    final isOwner = group.ownerDeviceId == controller.identity!.deviceId;
    final accepted = await showNekoDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(isOwner ? '解散群聊？' : '退出群聊？'),
        content: Text(
          isOwner ? '群聊将从在线成员的设备上移除，此操作无法撤销。' : '退出后需要群主再次邀请才能加入。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(isOwner ? '解散' : '退出'),
          ),
        ],
      ),
    );
    if (accepted == true) await controller.leaveOrDisbandGroup(group);
  }
}

class IdentityHeader extends StatelessWidget {
  const IdentityHeader({
    super.key,
    required this.controller,
    required this.onTap,
    this.unreadCount = 0,
  });
  final AppController controller;
  final VoidCallback onTap;
  final int unreadCount;
  @override
  Widget build(BuildContext context) {
    final identity = controller.identity!;
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.fromLTRB(18, 18, 14, 14),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.primaryContainer
              .withValues(alpha: .45),
        ),
        child: Row(
          children: [
            ProfileAvatar(
              identity: identity,
              imagePath: controller.profileAvatarPath,
              radius: 23,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    identity.displayName,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    '设备 ${identity.deviceId.substring(0, 8)}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            Tooltip(
              message: '编辑头像和昵称',
              child: Icon(
                Icons.edit_outlined,
                size: 20,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
            if (unreadCount > 0) ...[
              const SizedBox(width: 10),
              Tooltip(
                message: '有 $unreadCount 条未读消息',
                child: UnreadBadge(count: unreadCount),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class ProfileAvatar extends StatelessWidget {
  const ProfileAvatar({
    super.key,
    required this.identity,
    required this.imagePath,
    required this.radius,
  });

  final LocalIdentity identity;
  final String? imagePath;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final path = imagePath;
    final fallback = CircleAvatar(
      radius: radius,
      backgroundColor: Theme.of(context).colorScheme.primary,
      foregroundColor: Theme.of(context).colorScheme.onPrimary,
      child: Text(_avatarText(identity.displayName)),
    );
    if (path == null || !File(path).existsSync()) return fallback;
    return ClipOval(
      child: Image.file(
        File(path),
        width: radius * 2,
        height: radius * 2,
        cacheWidth: (radius * 4).round(),
        cacheHeight: (radius * 4).round(),
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => fallback,
      ),
    );
  }
}

/// “添加好友”的选择结果：选中的设备、是否走口令路径、口令原文（口令路径才有）。
class _AddFriendResult {
  const _AddFriendResult({
    required this.peer,
    required this.viaPairingCode,
    this.code,
  });
  final DiscoveredPeer peer;
  final bool viaPairingCode;
  final String? code;
}

/// “添加好友”对话框：底层仍自动发现设备，但陌生设备不再自动出现在联系人列表。
/// 可输入对方的口令精确匹配设备后添加，或直接从已发现设备列表挑选；
/// 两种方式都只需对方“通过/拒绝”。
class _AddFriendDialog extends StatefulWidget {
  const _AddFriendDialog({required this.controller});

  final AppController controller;

  @override
  State<_AddFriendDialog> createState() => _AddFriendDialogState();
}

class _AddFriendDialogState extends State<_AddFriendDialog> {
  final _codeController = TextEditingController();

  /// 冷却倒计时期间每秒重建一次，让“X 秒后可重试”及时解除。
  Timer? _cooldownTicker;

  @override
  void dispose() {
    _cooldownTicker?.cancel();
    _codeController.dispose();
    super.dispose();
  }

  /// 只有存在冷却中的设备时才跑定时器，避免无谓重建（也避免测试里 pumpAndSettle 卡住）。
  void _syncCooldownTicker(bool active) {
    if (active) {
      _cooldownTicker ??= Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    } else {
      _cooldownTicker?.cancel();
      _cooldownTicker = null;
    }
  }

  String _cooldownLabel(Duration duration) {
    final seconds = (duration.inMilliseconds / 1000).ceil();
    return seconds >= 60
        ? '${(seconds / 60).ceil()} 分钟后可重试'
        : '$seconds 秒后可重试';
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('添加好友'),
      content: SizedBox(
        width: 380,
        child: ListenableBuilder(
          listenable: controller,
          builder: (context, _) {
            final rawInput = _codeController.text.trim();
            final candidates = controller.discoverableCandidates;
            // 口令路径：输入非空时，在已发现设备里找口令哈希相符的那一台。
            final matched = rawInput.isEmpty
                ? null
                : candidates
                      .where((peer) => controller.pairingCodeMatches(
                            peer,
                            rawInput,
                          ))
                      .firstOrNull;
            // 加好友限频：对冷却中的设备禁用按钮并显示倒计时。
            final cooldowns = <String, Duration>{
              for (final peer in candidates)
                peer.deviceId: controller.friendRequestCooldown(peer.deviceId),
            };
            final matchedCooldown = matched == null
                ? Duration.zero
                : (cooldowns[matched.deviceId] ?? Duration.zero);
            _syncCooldownTicker(
              cooldowns.values.any((duration) => duration > Duration.zero),
            );
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.vpn_key_outlined, size: 20),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('我的口令', style: theme.textTheme.labelMedium),
                            const SizedBox(height: 2),
                            Text(
                              controller.myPairingCode,
                              style: theme.textTheme.titleMedium?.copyWith(
                                letterSpacing: 1,
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        tooltip: '复制口令',
                        onPressed: controller.copyPairingCode,
                        icon: const Icon(Icons.copy, size: 18),
                      ),
                      TextButton.icon(
                        onPressed: controller.regeneratePairingCode,
                        icon: const Icon(Icons.refresh, size: 16),
                        label: const Text('重新生成'),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    '把口令告诉对方（共 ${AppController.pairingWordCount} 个词，可点左侧按钮复制），对方用它加你时可穿透你的“屏蔽加好友申请”。',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: _codeController,
                  autofocus: true,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    labelText:
                        '输入对方口令（${AppController.pairingWordCount} 个词，空格可不输）',
                    prefixIcon: const Icon(Icons.vpn_key),
                    border: const OutlineInputBorder(),
                    suffixIcon: _codeController.text.isEmpty
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.clear),
                            onPressed: () =>
                                setState(() => _codeController.clear()),
                          ),
                  ),
                ),
                if (rawInput.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  if (matched != null)
                    Card(
                      margin: EdgeInsets.zero,
                      color: theme.colorScheme.primaryContainer,
                      child: ListTile(
                        dense: true,
                        leading: NamedAvatar(
                          imagePath: controller.peerAvatarPath(
                            matched.deviceId,
                          ),
                          name: matched.displayName,
                          radius: 18,
                        ),
                        title: Text(
                          matched.displayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text('口令匹配 · ${matched.ip}'),
                        trailing: matchedCooldown > Duration.zero
                            ? Text(
                                _cooldownLabel(matchedCooldown),
                                style: theme.textTheme.labelSmall,
                              )
                            : FilledButton(
                                onPressed: () => Navigator.of(context).pop(
                                  _AddFriendResult(
                                    peer: matched,
                                    viaPairingCode: true,
                                    code: rawInput,
                                  ),
                                ),
                                child: const Text('加好友'),
                              ),
                      ),
                    )
                  else
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text(
                        '没有在线设备匹配该口令，确认口令正确且对方在线。',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.error,
                        ),
                      ),
                    ),
                ],
                const Divider(height: 24),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '附近设备（直接添加，等对方通过）',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 220),
                  child: candidates.isEmpty
                      ? const EmptyHint(
                          icon: Icons.wifi_find_outlined,
                          text: '附近暂无可添加的设备\n确认对方已打开 NekoChat 且在同一局域网',
                        )
                      : ListView.builder(
                          shrinkWrap: true,
                          itemCount: candidates.length,
                          itemBuilder: (context, index) {
                            final peer = candidates[index];
                            return ListTile(
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              leading: NamedAvatar(
                                imagePath: controller.peerAvatarPath(
                                  peer.deviceId,
                                ),
                                name: peer.displayName,
                                radius: 18,
                              ),
                              title: Text(
                                peer.displayName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Text(
                                peer.ip,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              trailing:
                                  (cooldowns[peer.deviceId] ?? Duration.zero) >
                                      Duration.zero
                                  ? Text(
                                      _cooldownLabel(
                                        cooldowns[peer.deviceId]!,
                                      ),
                                      style: theme.textTheme.labelSmall,
                                    )
                                  : FilledButton.tonal(
                                      onPressed: () =>
                                          Navigator.of(context).pop(
                                            _AddFriendResult(
                                              peer: peer,
                                              viaPairingCode: false,
                                            ),
                                          ),
                                      child: const Text('加好友'),
                                    ),
                            );
                          },
                        ),
                ),
              ],
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}

/// 对端头像：同步到本地就显示图片，否则回退到昵称首字母。
class NamedAvatar extends StatelessWidget {
  const NamedAvatar({
    super.key,
    required this.imagePath,
    required this.name,
    this.radius = 20,
  });

  final String? imagePath;
  final String name;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final path = imagePath;
    final fallback = CircleAvatar(
      radius: radius,
      child: Text(_avatarText(name)),
    );
    if (path == null || !File(path).existsSync()) return fallback;
    return ClipOval(
      child: Image.file(
        File(path),
        width: radius * 2,
        height: radius * 2,
        cacheWidth: (radius * 4).round(),
        cacheHeight: (radius * 4).round(),
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => fallback,
      ),
    );
  }
}

/// 群成员角色标签（群主/管理员），用于消息昵称前的小徽标。
class RoleTag extends StatelessWidget {
  const RoleTag({super.key, required this.role});
  final GroupRole role;

  @override
  Widget build(BuildContext context) {
    final (Color background, Color foreground) = switch (role) {
      GroupRole.owner => (
        const Color(0xFFFFE9B8),
        const Color(0xFF8A5A00),
      ),
      GroupRole.admin => (
        Theme.of(context).colorScheme.tertiaryContainer,
        Theme.of(context).colorScheme.onTertiaryContainer,
      ),
      GroupRole.member => (
        Theme.of(context).colorScheme.surfaceContainerHighest,
        Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(
        _groupRoleLabel(role),
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: foreground,
        ),
      ),
    );
  }
}

/// 未读消息徽标，样式参考聊天软件的红色圆角计数。
class UnreadBadge extends StatelessWidget {
  const UnreadBadge({super.key, required this.count});
  final int count;

  @override
  Widget build(BuildContext context) => Container(
    constraints: const BoxConstraints(minWidth: 22),
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.error,
      borderRadius: BorderRadius.circular(11),
    ),
    child: Text(
      count > 99 ? '99+' : '$count',
      textAlign: TextAlign.center,
      style: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w600,
        color: Theme.of(context).colorScheme.onError,
      ),
    ),
  );
}

/// 会话条目右侧的最近消息时间与未读徽标。
class ConversationMeta extends StatelessWidget {
  const ConversationMeta({
    super.key,
    required this.time,
    required this.unreadCount,
  });
  final DateTime? time;
  final int unreadCount;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.end,
    children: [
      if (time != null)
        Text(
          _friendlyTime(time!),
          style: Theme.of(context).textTheme.labelSmall,
        ),
      if (unreadCount > 0) ...[
        const SizedBox(height: 4),
        UnreadBadge(count: unreadCount),
      ],
    ],
  );
}

class SectionTitle extends StatelessWidget {
  const SectionTitle({super.key, required this.title, this.trailing});
  final String title;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 18, 8, 6),
    child: Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: Theme.of(context).textTheme.labelLarge
                ?.copyWith(color: Theme.of(context).colorScheme.primary),
          ),
        ),
        ?trailing,
      ],
    ),
  );
}

class EmptyHint extends StatelessWidget {
  const EmptyHint({super.key, required this.icon, required this.text});
  final IconData icon;
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
    child: Row(
      children: [
        Icon(icon, size: 18, color: Colors.grey),
        const SizedBox(width: 8),
        Expanded(
          child: Text(text, style: const TextStyle(color: Colors.grey)),
        ),
      ],
    ),
  );
}

class UnifiedPeerEntry {
  const UnifiedPeerEntry({
    required this.deviceId,
    required this.displayName,
    required this.originalDisplayName,
    required this.peer,
    required this.chat,
    required this.trustedPeer,
    this.avatarPath,
  });

  final String deviceId;
  final String displayName;
  final String originalDisplayName;
  final DiscoveredPeer? peer;
  final ChatSummary? chat;
  final TrustedPeer? trustedPeer;
  final String? avatarPath;
}

class UnifiedPeerTile extends StatelessWidget {
  const UnifiedPeerTile({
    super.key,
    required this.entry,
    required this.selected,
    required this.onTap,
    required this.onSecondaryTapDown,
  });
  final UnifiedPeerEntry entry;
  final bool selected;
  final VoidCallback onTap;
  final GestureTapDownCallback onSecondaryTapDown;

  @override
  Widget build(BuildContext context) {
    final peer = entry.peer;
    final chat = entry.chat;
    final blocked = entry.trustedPeer?.blocked == true;
    final online = peer?.online == true;
    final pending =
        chat?.state == ChatSessionState.pendingIncoming ||
        chat?.state == ChatSessionState.pendingOutgoing;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onSecondaryTapDown: onSecondaryTapDown,
      child: ListTile(
        selected: selected,
        enabled: !blocked && (online || chat != null),
        leading: Stack(
          children: [
            NamedAvatar(
              imagePath: entry.avatarPath,
              name: entry.displayName,
            ),
            Positioned(
              right: 0,
              bottom: 0,
              child: Container(
                width: 11,
                height: 11,
                decoration: BoxDecoration(
                  color: online ? Colors.green : Colors.grey,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: Theme.of(context).colorScheme.surface,
                    width: 2,
                  ),
                ),
              ),
            ),
          ],
        ),
        title: Row(
          children: [
            Flexible(
              child: Text(entry.displayName, overflow: TextOverflow.ellipsis),
            ),
            if (entry.trustedPeer != null && !blocked) ...[
              const SizedBox(width: 4),
              const Icon(Icons.verified, color: Colors.blue, size: 16),
            ],
          ],
        ),
        subtitle: Text(
          _peerListSubtitle(entry),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: pending
            ? const SizedBox.square(
                dimension: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : (chat?.unreadCount ?? 0) > 0 || chat?.lastMessageAt != null
            ? ConversationMeta(
                time: chat?.lastMessageAt,
                unreadCount: chat?.unreadCount ?? 0,
              )
            : Icon(
                chat?.state == ChatSessionState.active
                    ? Icons.chat_bubble_outline
                    : Icons.chevron_right,
                size: 20,
              ),
        onTap: onTap,
      ),
    );
  }
}

enum _PeerContextAction {
  openInWindow,
  info,
  remark,
  delete,
  revokeVerification,
  block,
}

enum _GroupContextAction { openInWindow, members, remark, invite, rename, leave }

class ChatRequestCard extends StatelessWidget {
  const ChatRequestCard({
    super.key,
    required this.controller,
    required this.request,
  });
  final AppController controller;
  final ChatRequest request;
  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    color: Theme.of(context).colorScheme.secondaryContainer
        .withValues(alpha: .55),
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            request.incoming
                ? '${controller.peerDisplayName(request.peerDeviceId, request.displayName)} 请求与你聊天'
                : '等待 ${controller.peerDisplayName(request.peerDeviceId, request.displayName)} 确认',
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 5),
          Text('设备：${request.peerDeviceId.substring(0, 8)}…'),
          Text('网络：${request.ip}'),
          if (request.viaPairingCode) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(
                  Icons.vpn_key,
                  size: 16,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 6),
                const Text('通过口令添加', style: TextStyle(fontSize: 13)),
              ],
            ),
          ],
          if (request.incoming) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => controller.rejectChatRequest(request),
                    child: const Text('拒绝'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton(
                    onPressed: () => controller.acceptChatRequest(request),
                    child: const Text('通过'),
                  ),
                ),
              ],
            ),
          ] else ...[
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: () => controller.cancelChatRequest(request),
              icon: const Icon(Icons.cancel_outlined, size: 18),
              label: const Text('取消发送'),
            ),
          ],
        ],
      ),
    ),
  );
}

class GroupInviteCard extends StatelessWidget {
  const GroupInviteCard({
    super.key,
    required this.controller,
    required this.invitation,
  });
  final AppController controller;
  final GroupInvitation invitation;
  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '${controller.peerDisplayName(invitation.inviterDeviceId, invitation.inviterDisplayName)} '
            '邀请你加入',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          Text(
            controller.groupDisplayName(
              invitation.groupId,
              invitation.groupName,
            ),
            style: Theme.of(context).textTheme.titleMedium,
          ),
          Text(
            '${_machine(invitation.ip)} · ${invitation.ip}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () =>
                      controller.respondToGroupInvitation(invitation, false),
                  child: const Text('拒绝'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton(
                  onPressed: () =>
                      controller.respondToGroupInvitation(invitation, true),
                  child: const Text('接受'),
                ),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

class _DetachedConversationWindow extends StatefulWidget {
  const _DetachedConversationWindow({
    required this.controller,
    required this.conversationId,
    required this.viewId,
  });

  final AppController controller;
  final String conversationId;

  /// 该独立窗口的公开 viewId，用于给原生层登记拖放目标。
  final int viewId;

  @override
  State<_DetachedConversationWindow> createState() =>
      _DetachedConversationWindowState();
}

class _DetachedConversationWindowState
    extends State<_DetachedConversationWindow> {
  final _composer = TextEditingController();
  final List<PendingAttachment> _pendingAttachments = [];
  List<ChatMessage> _messages = const [];
  ChatMessage? _replyingTo;
  int _refreshGeneration = 0;
  bool _infoDrawerOpen = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_handleControllerChanged);
    unawaited(
      widget.controller.setConversationWindowOpen(widget.conversationId, true),
    );
    _refreshMessages();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_handleControllerChanged);
    unawaited(
      widget.controller.setConversationWindowOpen(widget.conversationId, false),
    );
    _composer.dispose();
    super.dispose();
  }

  void _handleControllerChanged() {
    if (mounted) setState(() {});
    _refreshMessages();
  }

  Future<void> _refreshMessages() async {
    final generation = ++_refreshGeneration;
    final messages = await widget.controller.loadMessagesForConversation(
      widget.conversationId,
    );
    if (!mounted || generation != _refreshGeneration) return;
    setState(() => _messages = messages);
  }

  Future<void> _send(String text, List<PendingAttachment> attachments) async {
    final reply = _replyingTo;
    await widget.controller.sendMessageWithAttachmentsTo(
      conversationId: widget.conversationId,
      content: text,
      attachments: attachments,
      reply: reply,
    );
    if (mounted && identical(_replyingTo, reply)) {
      setState(() => _replyingTo = null);
    }
    await _refreshMessages();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final identity = controller.identity;
    if (identity == null) return _missingConversation();
    final localDeviceId = identity.deviceId;

    final groupId = widget.conversationId.startsWith('group:')
        ? widget.conversationId.substring('group:'.length)
        : null;
    final group = groupId == null
        ? null
        : controller.groups
              .where((value) => value.groupId == groupId)
              .firstOrNull;
    final chat = groupId != null
        ? null
        : controller.chats
              .where((value) => value.chatId == widget.conversationId)
              .firstOrNull;
    if (group == null && chat == null) return _missingConversation();
    final isGroup = group != null;

    final title = isGroup
        ? controller.groupDisplayName(group.groupId, group.name)
        : controller.peerDisplayName(chat!.peerDeviceId, chat.displayName);
    final peer = isGroup
        ? null
        : controller.peers
              .where((value) => value.deviceId == chat!.peerDeviceId)
              .firstOrNull;
    final enabled =
        isGroup ||
        (peer?.online == true && chat!.state == ChatSessionState.active);

    String headerName(String deviceId) {
      if (deviceId == localDeviceId) return identity.displayName;
      if (!isGroup) return title;
      final originalName =
          controller.peers
              .where((value) => value.deviceId == deviceId)
              .firstOrNull
              ?.displayName ??
          controller.trustedPeers[deviceId]?.displayName ??
          '群成员';
      return controller.peerDisplayName(deviceId, originalName);
    }

    Future<void> dropFiles(List<String> paths) async {
      await controller.sendDroppedFiles(
        conversationId: widget.conversationId,
        filePaths: paths,
      );
      await _refreshMessages();
    }

    return Scaffold(
      body: SafeArea(
        child: Stack(
          fit: StackFit.expand,
          children: [
            _ViewDropArea(
              viewId: widget.viewId,
              enabled: enabled,
              onDropFiles: dropFiles,
              child: _ConversationPane(
            conversationId: widget.conversationId,
            title: title,
            subtitle: isGroup
                ? [
                    if (title != group.name) '原群名：${group.name}',
                    '局域网实时群聊 · 离线成员不会收到消息',
                  ].join(' · ')
                : [
                    if (title != chat!.displayName) '原名：${chat.displayName}',
                    peer?.online == true ? '${peer!.ip} · 在线' : '离线',
                  ].join(' · '),
            messages: _messages,
            localDeviceId: localDeviceId,
            peerName: (deviceId) =>
                deviceId == localDeviceId ? '我' : headerName(deviceId),
            composer: _composer,
            pendingAttachments: _pendingAttachments,
            enabled: enabled,
            useDesktopDrop: false,
            isGroup: isGroup,
            senderHeaderFor: headerName,
            senderRoleFor: isGroup
                ? (deviceId) =>
                      controller.groupMemberRole(group.groupId, deviceId)
                : null,
            avatarPathFor: (deviceId) =>
                deviceId == localDeviceId
                ? controller.profileAvatarPath
                : controller.peerAvatarPath(deviceId),
            onSend: _send,
            onPickAttachments: controller.pickAttachments,
            onDropFiles: dropFiles,
            onReadClipboardAttachments: controller.readClipboardAttachments,
            onOpenAttachment: controller.openAttachment,
            onOpenAttachmentFolder: controller.openAttachmentFolder,
            onAcceptFile: controller.acceptIncomingFile,
            onRejectFile: controller.rejectIncomingFile,
            onRetryFile: controller.retryFileDownload,
            onRelocateFile: controller.relocateAttachment,
            missingHintFor: controller.attachmentMissingHint,
            replyingTo: _replyingTo,
            onCancelReply: () => setState(() => _replyingTo = null),
            onCopyMessage: controller.copyMessage,
            onReplyMessage: (message) => setState(
              () =>
                  _replyingTo = identical(_replyingTo, message) ? null : message,
            ),
            canRecallMessage: controller.canRecallMessage,
            onRecallMessage: controller.recallMessage,
            recallNoticeFor: controller.recallNotice,
            favoriteStickers: controller.favoriteStickers,
            onPickFavoriteStickers: controller.pickAndAddFavoriteStickers,
            onSendFavoriteSticker: (sticker) async {
              final reply = _replyingTo;
              if (reply != null && mounted) {
                setState(() => _replyingTo = null);
              }
              await controller.sendFavoriteSticker(
                sticker,
                conversationId: widget.conversationId,
                reply: reply,
              );
            },
            onRemoveFavoriteSticker: controller.removeFavoriteSticker,
            onReorderFavoriteStickers: controller.reorderFavoriteStickers,
            onSetFavoriteStickerRemark: controller.setFavoriteStickerRemark,
            stickerSuggestionsEnabled: controller.stickerSuggestionsEnabled,
            sendOnCtrlEnter: controller.sendOnCtrlEnter,
            onSendOnCtrlEnterChanged: controller.setSendOnCtrlEnter,
            onAddMessageToStickers: controller.addMessageToFavoriteStickers,
            onMention: isGroup
                ? (name) => _MainShellState._insertMention(_composer, name)
                : null,
            loadMentionCandidates: isGroup
                  ? () async {
                    final members = await controller.groupMembers(
                      group.groupId,
                    );
                    return [
                      for (final member in members)
                        if (member.deviceId != localDeviceId)
                          MentionCandidate(
                            deviceId: member.deviceId,
                            displayName: controller.peerDisplayName(
                              member.deviceId,
                              member.displayName,
                            ),
                            insertionName: member.displayName,
                            originalName:
                                controller.peerRemarks.containsKey(
                                  member.deviceId,
                                )
                                ? member.displayName
                                : null,
                          ),
                    ];
                  }
                : null,
            actions: [
              IconButton(
                tooltip: isGroup ? '群聊操作' : '会话操作',
                onPressed: () =>
                    setState(() => _infoDrawerOpen = !_infoDrawerOpen),
                icon: Icon(
                  Icons.more_horiz,
                  color: _infoDrawerOpen
                      ? Theme.of(context).colorScheme.primary
                      : null,
                ),
              ),
            ],
            headerLeftPadding: 22,
          ),
        ),
            if (isGroup || chat != null)
              Positioned.fill(
                child: _FloatingDrawerOverlay(
                  open: _infoDrawerOpen,
                  onDismiss: () => setState(() => _infoDrawerOpen = false),
                  drawer: isGroup
                      ? GroupInfoDrawer(
                          controller: controller,
                          group: group,
                          onClose: () =>
                              setState(() => _infoDrawerOpen = false),
                          onAfterLeaveOrDisband: () async {
                            if (!context.mounted) return;
                            if (!controller.groups.any(
                              (item) => item.groupId == group.groupId,
                            )) {
                              await MultiViewDesktop.of(context).closeWindow();
                            }
                          },
                          onMentionMember: (name) =>
                              _MainShellState._insertMention(_composer, name),
                        )
                      : PeerInfoDrawer(
                          controller: controller,
                          chat: chat!,
                          onClose: () =>
                              setState(() => _infoDrawerOpen = false),
                          onAfterClose: () async {
                            if (!context.mounted) return;
                            await MultiViewDesktop.of(context).closeWindow();
                          },
                        ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _missingConversation() =>
      const Scaffold(body: Center(child: Text('这个会话已不存在')));
}

/// 独立窗口的文件拖放层：监听原生 per-view 拖放事件并显示提示。
class _ViewDropArea extends StatefulWidget {
  const _ViewDropArea({
    required this.viewId,
    required this.enabled,
    required this.onDropFiles,
    required this.child,
  });

  final int viewId;
  final bool enabled;
  final Future<void> Function(List<String> paths) onDropFiles;
  final Widget child;

  @override
  State<_ViewDropArea> createState() => _ViewDropAreaState();
}

class _ViewDropAreaState extends State<_ViewDropArea> {
  final _service = ViewDropService.instance;
  bool _dragging = false;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _service.addListener(widget.viewId, _handleEvent);
    unawaited(_registerDropTarget());
  }

  /// 原生窗口可能比 Dart 视图稍晚就绪，失败时重试几次。
  Future<void> _registerDropTarget() async {
    for (var attempt = 0; attempt < 5; attempt++) {
      if (await _service.register(widget.viewId)) return;
      await Future<void>.delayed(const Duration(milliseconds: 100));
      if (!mounted) return;
    }
  }

  @override
  void dispose() {
    _service.removeListener(widget.viewId, _handleEvent);
    unawaited(_service.unregister(widget.viewId));
    super.dispose();
  }

  void _handleEvent(ViewDropEvent event) {
    if (!mounted) return;
    switch (event.type) {
      case ViewDropEventType.entered:
        if (!widget.enabled || _sending || _dragging) return;
        setState(() => _dragging = true);
      case ViewDropEventType.exited:
        if (!_dragging) return;
        setState(() => _dragging = false);
      case ViewDropEventType.dropped:
        if (_dragging) setState(() => _dragging = false);
        if (!widget.enabled || _sending) return;
        unawaited(_send(event.paths));
    }
  }

  Future<void> _send(List<String> paths) async {
    if (!widget.enabled || _sending) return;
    setState(() => _sending = true);
    try {
      await widget.onDropFiles(paths);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      widget.child,
      if (_dragging || _sending) FileDropOverlay(sending: _sending),
    ],
  );
}

class _ConversationPane extends StatefulWidget {
  const _ConversationPane({
    super.key,
    required this.conversationId,
    required this.title,
    required this.subtitle,
    required this.messages,
    required this.localDeviceId,
    required this.peerName,
    required this.composer,
    required this.pendingAttachments,
    required this.enabled,
    required this.onSend,
    required this.onPickAttachments,
    required this.onDropFiles,
    required this.onReadClipboardAttachments,
    required this.onOpenAttachment,
    required this.onOpenAttachmentFolder,
    required this.onAcceptFile,
    required this.onRejectFile,
    required this.onRetryFile,
    required this.onRelocateFile,
    required this.missingHintFor,
    required this.actions,
    this.replyingTo,
    this.onCancelReply,
    this.onCopyMessage,
    this.onReplyMessage,
    this.canRecallMessage,
    this.onRecallMessage,
    this.recallNoticeFor,
    this.onMention,
    this.loadMentionCandidates,
    this.headerLeftPadding = 22,
    this.useDesktopDrop = true,
    this.isGroup = false,
    this.senderHeaderFor,
    this.senderRoleFor,
    this.avatarPathFor,
    this.favoriteStickers = const [],
    this.onPickFavoriteStickers,
    this.onSendFavoriteSticker,
    this.onRemoveFavoriteSticker,
    this.onReorderFavoriteStickers,
    this.onSetFavoriteStickerRemark,
    this.stickerSuggestionsEnabled = true,
    this.sendOnCtrlEnter = false,
    this.onSendOnCtrlEnterChanged,
    this.onAddMessageToStickers,
  });
  final String conversationId;
  final String title;
  final String subtitle;
  final List<ChatMessage> messages;
  final String localDeviceId;
  final String Function(String) peerName;
  final TextEditingController composer;
  final List<PendingAttachment> pendingAttachments;
  final bool enabled;

  /// 主窗口使用 desktop_drop；独立窗口改用原生 per-view 拖放，避免重复注册。
  final bool useDesktopDrop;

  /// 发送输入框里的文字与待发送附件。
  final Future<void> Function(String text, List<PendingAttachment> attachments)
  onSend;

  /// 打开文件选择框 / 读取剪贴板，返回待暂存的附件。
  final Future<List<PendingAttachment>> Function() onPickAttachments;
  final Future<void> Function(List<String> paths) onDropFiles;
  final Future<List<PendingAttachment>> Function() onReadClipboardAttachments;
  final Future<void> Function(ChatMessage) onOpenAttachment;
  final Future<void> Function(ChatMessage) onOpenAttachmentFolder;
  final Future<void> Function(ChatMessage) onAcceptFile;
  final Future<void> Function(ChatMessage) onRejectFile;
  final Future<void> Function(ChatMessage) onRetryFile;
  final Future<void> Function(ChatMessage) onRelocateFile;
  final String Function(ChatMessage) missingHintFor;
  final List<Widget> actions;

  /// 当前引用的消息，非空时输入框上方展示引用横幅。
  final ChatMessage? replyingTo;
  final VoidCallback? onCancelReply;
  final Future<void> Function(ChatMessage)? onCopyMessage;
  final void Function(ChatMessage)? onReplyMessage;
  final bool Function(ChatMessage)? canRecallMessage;
  final Future<void> Function(ChatMessage)? onRecallMessage;
  final String Function(ChatMessage)? recallNoticeFor;

  /// 右键“@TA”时把昵称插进输入框。
  final void Function(String name)? onMention;

  /// 群聊输入 @ 时加载候选成员；私聊为空，不启用候选菜单。
  final Future<List<MentionCandidate>> Function()? loadMentionCandidates;
  final double headerLeftPadding;

  /// 群聊会为每条消息显示发送者昵称与角色标签（群主/管理员）。
  final bool isGroup;
  final String Function(String deviceId)? senderHeaderFor;
  final GroupRole? Function(String deviceId)? senderRoleFor;
  final String? Function(String deviceId)? avatarPathFor;
  final List<FavoriteSticker> favoriteStickers;
  final Future<int> Function()? onPickFavoriteStickers;
  final Future<void> Function(FavoriteSticker sticker)? onSendFavoriteSticker;
  final Future<void> Function(FavoriteSticker sticker)? onRemoveFavoriteSticker;
  final Future<void> Function(int oldIndex, int newIndex)?
  onReorderFavoriteStickers;
  final Future<void> Function(FavoriteSticker sticker, String? remark)?
  onSetFavoriteStickerRemark;
  final bool stickerSuggestionsEnabled;
  final bool sendOnCtrlEnter;
  final ValueChanged<bool>? onSendOnCtrlEnterChanged;
  final Future<bool> Function(ChatMessage message)? onAddMessageToStickers;

  @override
  State<_ConversationPane> createState() => _ConversationPaneState();
}

class _ConversationPaneState extends State<_ConversationPane> {
  final ScrollController _scroll = ScrollController();
  final Map<String, GlobalKey> _messageKeys = {};

  /// 输入框焦点。引用回复后把光标送回输入框，方便立刻打字。
  final FocusNode _composerFocus = FocusNode();
  Timer? _highlightTimer;
  String? _highlightedMessageId;
  bool _draggingFiles = false;
  bool _sendingDroppedFiles = false;

  /// 消息右键菜单（文字/图片/文件统一自绘）。
  OverlayEntry? _fallbackMenu;

  /// 表情与收藏表情弹出面板。
  final GlobalKey _stickerButtonKey = GlobalKey();
  GlobalKey<StickerPickerOverlayState>? _stickerPickerKey;
  OverlayEntry? _stickerPickerOverlay;
  StickerPickerTab _stickerPickerTab = StickerPickerTab.favorites;
  String? _dismissedStickerQuery;

  /// 各气泡当前的文本选区，右键「复制选中」时读取。
  final Map<String, String?> _selectedTexts = {};

  /// 记录已展示过的消息 ID，仅对新发出或新收到的消息播放轻快入场动画。
  final Set<String> _knownMessageIds = {};
  final Set<String> _enteringMessageIds = {};

  @override
  void initState() {
    super.initState();
    for (final message in widget.messages) {
      _knownMessageIds.add(message.messageId);
    }
  }

  @override
  void didUpdateWidget(covariant _ConversationPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.conversationId != widget.conversationId) {
      _removeStickerPicker();
      _knownMessageIds
        ..clear()
        ..addAll(widget.messages.map((m) => m.messageId));
      _enteringMessageIds.clear();
      return;
    }
    if (!widget.enabled) {
      _removeStickerPicker();
    } else if (_stickerPickerOverlay != null &&
        oldWidget.favoriteStickers != widget.favoriteStickers) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _stickerPickerOverlay?.mounted == true) {
          _stickerPickerOverlay?.markNeedsBuild();
        }
      });
    }
    for (final message in widget.messages) {
      if (_knownMessageIds.add(message.messageId)) {
        _enteringMessageIds.add(message.messageId);
      }
    }
  }

  @override
  void dispose() {
    _highlightTimer?.cancel();
    _removeFallbackMenu();
    _removeStickerPicker();
    _composerFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _removeStickerPicker() {
    final entry = _stickerPickerOverlay;
    _stickerPickerOverlay = null;
    _stickerPickerKey = null;
    if (entry != null && entry.mounted) {
      entry.remove();
    }
  }

  void _dismissStickerPicker() {
    final state = _stickerPickerKey?.currentState;
    if (state != null) {
      state.close();
    } else {
      _removeStickerPicker();
    }
  }

  void _toggleStickerPicker() {
    if (_stickerPickerOverlay != null) {
      _dismissStickerPicker();
      return;
    }
    _removeFallbackMenu();
    final overlay = Overlay.of(context);
    final overlayKey = GlobalKey<StickerPickerOverlayState>();
    late final OverlayEntry entry;

    void hardRemove() {
      if (entry.mounted) entry.remove();
      if (identical(_stickerPickerOverlay, entry)) {
        _stickerPickerOverlay = null;
        _stickerPickerKey = null;
      }
    }

    void dismiss() {
      final state = overlayKey.currentState;
      if (state != null) {
        state.close();
      } else {
        hardRemove();
      }
    }

    entry = OverlayEntry(
      builder: (overlayContext) {
        final screen = MediaQuery.sizeOf(overlayContext);
        final renderBox =
            _stickerButtonKey.currentContext?.findRenderObject() as RenderBox?;
        final anchor = renderBox == null
            ? Offset(20, screen.height - 72)
            : renderBox.localToGlobal(Offset.zero);
        return StickerPickerOverlay(
          key: overlayKey,
          anchor: anchor,
          onDismiss: dismiss,
          onClosed: hardRemove,
          child: StickerPickerPanel(
            stickers: widget.favoriteStickers,
            initialTab: _stickerPickerTab,
            onTabChanged: (tab) => _stickerPickerTab = tab,
            onPickStickers: () async =>
                await widget.onPickFavoriteStickers?.call() ?? 0,
            onRemoveSticker: (sticker) async =>
                await widget.onRemoveFavoriteSticker?.call(sticker),
            onReorderStickers: widget.onReorderFavoriteStickers,
            onEditStickerRemark: widget.onSetFavoriteStickerRemark == null
                ? null
                : (sticker) async {
                    dismiss();
                    final result = await showStickerRemarkDialog(
                      context,
                      sticker,
                    );
                    if (result != null) {
                      await widget.onSetFavoriteStickerRemark!(
                        sticker,
                        result.remark,
                      );
                    }
                  },
            onSelectSticker: (sticker) async {
              dismiss();
              await widget.onSendFavoriteSticker?.call(sticker);
            },
            onSelectEmoji: _insertEmoji,
          ),
        );
      },
    );
    _stickerPickerKey = overlayKey;
    _stickerPickerOverlay = entry;
    overlay.insert(entry);
  }

  void _insertEmoji(String emoji) {
    final value = widget.composer.value;
    final selection = value.selection.isValid
        ? value.selection
        : TextSelection.collapsed(offset: value.text.length);
    final updatedText = value.text.replaceRange(
      selection.start,
      selection.end,
      emoji,
    );
    widget.composer.value = value.copyWith(
      text: updatedText,
      selection: TextSelection.collapsed(offset: selection.start + emoji.length),
      composing: TextRange.empty,
    );
  }

  void _removeFallbackMenu() {
    _fallbackMenu?.remove();
    _fallbackMenu = null;
  }

  /// 消息右键菜单：文字、图片、文件气泡统一使用这一套精致自绘菜单。
  ///
  /// 遮罩覆盖全屏，点击任意空白处或在其它地方右键均立即关闭；
  /// 样式对齐现代桌面聊天应用（深色圆角浮层 + 紧凑图标文字项 + 悬浮动效）。
  void _showFallbackMenu(
    BuildContext context,
    Offset position,
    List<ChatContextMenuItem> Function(VoidCallback dismiss) buildItems,
  ) {
    _removeFallbackMenu();
    final overlay = Overlay.of(context);
    final menuKey = GlobalKey<NekoContextMenuOverlayState>();
    late final OverlayEntry entry;
    // 收起动画播完后真正把浮层从 Overlay 移除；重复调用安全。
    void hardRemove() {
      if (entry.mounted) entry.remove();
      if (identical(_fallbackMenu, entry)) _fallbackMenu = null;
    }

    // 关闭入口：先让浮层反向播放收起动画，动画结束后再移除。
    void dismiss() {
      final state = menuKey.currentState;
      if (state != null) {
        state.close();
      } else {
        hardRemove();
      }
    }

    final items = buildItems(dismiss);
    if (items.isEmpty) return;

    entry = OverlayEntry(
      builder: (context) => NekoContextMenuOverlay(
        key: menuKey,
        position: position,
        width: 152,
        items: [
          for (final item in items)
            NekoContextMenuItem<void>(
              label: item.label,
              icon: item.icon,
              onTap: item.onTap,
              hasDividerBefore: item.hasDividerBefore,
            ),
        ],
        onDismiss: dismiss,
        onClosed: hardRemove,
      ),
    );
    _fallbackMenu = entry;
    overlay.insert(entry);
  }

  /// 把光标移到输入框末尾并聚焦，避免接着输入时插到文字中间。
  ///
  /// 选择菜单收起时可能把焦点抢回去，所以下一帧再补一次请求。
  void _focusComposer() {
    if (!mounted) return;
    _composerFocus.requestFocus();
    widget.composer.selection = TextSelection.collapsed(
      offset: widget.composer.text.length,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _composerFocus.requestFocus();
      widget.composer.selection = TextSelection.collapsed(
        offset: widget.composer.text.length,
      );
    });
  }

  /// 引用某条消息，并立刻聚焦输入框。
  void _handleReply(ChatMessage message) {
    widget.onReplyMessage?.call(message);
    _focusComposer();
  }

  /// 发送前把附件与文字一起交给控制器，文字先发、附件按顺序跟在后面。
  Future<void> _handleSend() async {
    final text = widget.composer.text;
    final attachments = List<PendingAttachment>.of(widget.pendingAttachments);
    if (text.trim().isEmpty && attachments.isEmpty) return;
    widget.composer.clear();
    if (mounted) setState(widget.pendingAttachments.clear);
    await widget.onSend(text, attachments);
  }

  /// 把新附件追加到待发送区域，同一路径不重复添加。
  void _addAttachments(List<PendingAttachment> attachments) {
    if (attachments.isEmpty || !mounted) return;
    setState(() {
      for (final attachment in attachments) {
        if (widget.pendingAttachments.any(
          (value) => value.path == attachment.path,
        )) {
          continue;
        }
        widget.pendingAttachments.add(attachment);
      }
    });
  }

  Future<void> _pickAttachments() async {
    _addAttachments(await widget.onPickAttachments());
  }

  /// 文件拖入后不进入待发送区，直接绑定当前会话并按拖入顺序发送。
  Future<void> _sendDroppedFiles(DropDoneDetails details) async {
    if (_sendingDroppedFiles || !widget.enabled) return;
    final paths = [
      for (final item in details.files)
        if (item is! DropItemDirectory) item.path,
    ];
    if (paths.isEmpty) {
      if (mounted) setState(() => _draggingFiles = false);
      return;
    }
    setState(() {
      _draggingFiles = false;
      _sendingDroppedFiles = true;
    });
    try {
      await widget.onDropFiles(paths);
    } finally {
      if (mounted) setState(() => _sendingDroppedFiles = false);
    }
  }

  void _setDraggingFiles(bool value) {
    if (!mounted || _draggingFiles == value || _sendingDroppedFiles) return;
    setState(() => _draggingFiles = value);
  }

  /// 剪贴板里有附件时只暂存，不插入文字，也不直接发送。
  Future<bool> _pasteAttachments() async {
    final attachments = await widget.onReadClipboardAttachments();
    if (attachments.isEmpty) return false;
    _addAttachments(attachments);
    return true;
  }

  void _removeAttachment(PendingAttachment attachment) {
    setState(() => widget.pendingAttachments.remove(attachment));
  }

  GlobalKey _keyFor(String messageId) =>
      _messageKeys.putIfAbsent(messageId, () => GlobalKey());

  /// 点击引用块时定位到被引用的原消息。
  ///
  /// ListView 是懒加载的，远处的消息还没挂载，`ensureVisible` 找不到它。
  /// 先用当前可见气泡的平均高度估算目标位置跳一次，估算偏差再按视口顺序
  /// 逐步逼近（顺序推进不会来回闪烁），对齐后短暂高亮目标气泡。
  Future<void> _jumpToMessage(String messageId) async {
    final index = widget.messages.indexWhere(
      (message) => message.messageId == messageId,
    );
    if (index < 0 || !_scroll.hasClients) return;
    final target = widget.messages.length - 1 - index;
    final position = _scroll.position;

    _scroll.jumpTo(
      _estimatedOffsetFor(target)
          .clamp(position.minScrollExtent, position.maxScrollExtent),
    );
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;

    for (var attempt = 0; attempt < 40; attempt++) {
      if (_messageKeys[messageId]?.currentContext != null) break;
      final range = _builtReverseIndexRange();
      if (range == null) break;
      final step = position.viewportDimension * 0.8;
      final next = target > range.max
          ? position.pixels + step
          : position.pixels - step;
      final clamped = next.clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      );
      if (clamped == position.pixels) break;
      _scroll.jumpTo(clamped);
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
    }

    final targetContext = _messageKeys[messageId]?.currentContext;
    if (targetContext == null || !targetContext.mounted) return;
    await Scrollable.ensureVisible(
      targetContext,
      alignment: 0.5,
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
    );
    if (!mounted) return;
    _highlightTimer?.cancel();
    setState(() => _highlightedMessageId = messageId);
    _highlightTimer = Timer(const Duration(milliseconds: 1600), () {
      if (mounted) setState(() => _highlightedMessageId = null);
    });
  }

  /// 用当前可见气泡的平均高度估算某个反转索引对应的滚动偏移。
  double _estimatedOffsetFor(int target) {
    final position = _scroll.position;
    final range = _builtReverseIndexRange();
    final visible = range == null ? 0 : range.max - range.min + 1;
    // 没有已挂载气泡时用一个经验高度兜底。
    final extent = visible > 0 ? position.viewportDimension / visible : 96.0;
    return target * extent - position.viewportDimension / 2;
  }

  /// 已挂载消息在反转列表中的索引范围，null 表示当前没有挂载任何气泡。
  ({int min, int max})? _builtReverseIndexRange() {
    final length = widget.messages.length;
    int? min;
    int? max;
    for (var index = 0; index < length; index++) {
      final id = widget.messages[index].messageId;
      if (_messageKeys[id]?.currentContext == null) continue;
      final reverseIndex = length - 1 - index;
      min = min == null || reverseIndex < min ? reverseIndex : min;
      max = max == null || reverseIndex > max ? reverseIndex : max;
    }
    return min == null ? null : (min: min, max: max!);
  }

  @override
  Widget build(BuildContext context) {
    final messages = widget.messages;
    final messagesById = {
      for (final message in messages) message.messageId: message,
    };
    final content = Column(
      children: [
        Container(
          height: 68,
          padding: EdgeInsets.only(left: widget.headerLeftPadding, right: 22),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            border: Border(
              bottom: BorderSide(color: Theme.of(context).dividerColor),
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      widget.subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              ...widget.actions,
            ],
          ),
        ),
        Expanded(
          child: messages.isEmpty
              ? const Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.chat_bubble_outline,
                        size: 42,
                        color: Colors.grey,
                      ),
                      SizedBox(height: 12),
                      Text('还没有消息，打个招呼吧', style: TextStyle(color: Colors.grey)),
                    ],
                  ),
                )
              : RepaintBoundary(
                  child: ListView.builder(
                  key: PageStorageKey(widget.conversationId),
                  controller: _scroll,
                  reverse: true,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  itemCount: messages.length,
                  itemBuilder: (context, reverseIndex) {
                    final message =
                        messages[messages.length - 1 - reverseIndex];
                    final mine = message.senderDeviceId == widget.localDeviceId;
                    final mentioned = message.mentionsDevice(
                      widget.localDeviceId,
                    );
                    if (message.isRecalled) {
                      return RecallNotice(
                        key: _keyFor(message.messageId),
                        text:
                            widget.recallNoticeFor?.call(message) ?? '一条消息已撤回',
                        highlighted: _highlightedMessageId == message.messageId,
                      );
                    }
                    final bubble = MessageBubble(
                      key: _keyFor(message.messageId),
                      message: message,
                      mine: mine,
                      senderName: widget.peerName(message.senderDeviceId),
                      headerName:
                          widget.senderHeaderFor?.call(message.senderDeviceId) ??
                          widget.peerName(message.senderDeviceId),
                      senderRole: widget.isGroup
                          ? widget.senderRoleFor?.call(message.senderDeviceId)
                          : null,
                      avatarPath: widget.avatarPathFor?.call(
                        message.senderDeviceId,
                      ),
                      showHeader: widget.isGroup || !mine,
                      mentioned: mentioned,
                      highlighted: _highlightedMessageId == message.messageId,
                      replySenderName: message.replyToSenderId == null
                          ? null
                          : widget.peerName(message.replyToSenderId!),
                      resolveMessage: (id) => messagesById[id],
                      onJumpToReply: (id) => unawaited(_jumpToMessage(id)),
                      missingHint: widget.missingHintFor(message),
                      onOpen: widget.onOpenAttachment,
                      onOpenFolder: widget.onOpenAttachmentFolder,
                      onAccept: widget.onAcceptFile,
                      onReject: widget.onRejectFile,
                      onRetry: widget.onRetryFile,
                      onRelocate: widget.onRelocateFile,
                      onReply: widget.onReplyMessage == null
                          ? null
                          : () => _handleReply(message),
                      onCopy: widget.onCopyMessage == null
                          ? null
                          : () => widget.onCopyMessage!(message),
                      onMention: message.senderDeviceId == widget.localDeviceId
                          ? null
                          : widget.onMention == null
                          ? null
                          : () => widget.onMention!(
                              widget.peerName(message.senderDeviceId),
                            ),
                      onRecall:
                          widget.canRecallMessage?.call(message) == true &&
                              widget.onRecallMessage != null
                          ? () => widget.onRecallMessage!(message)
                          : null,
                      onAddToStickers:
                          message.kind == MessageKind.image &&
                              widget.onAddMessageToStickers != null
                          ? () => widget.onAddMessageToStickers!(message)
                          : null,
                      onShowFallbackMenu: _showFallbackMenu,
                      onSelectionChanged: (text) =>
                          _selectedTexts[message.messageId] = text,
                      selectedText: () => _selectedTexts[message.messageId],
                    );
                    if (_enteringMessageIds.contains(message.messageId)) {
                      return _AnimatedMessageEntrance(
                        key: ValueKey('enter-${message.messageId}'),
                        mine: mine,
                        onCompleted: () =>
                            _enteringMessageIds.remove(message.messageId),
                        child: bubble,
                      );
                    }
                    return bubble;
                  },
                  ),
                ),
        ),
        Container(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 14),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            border: Border(
              top: BorderSide(
                color: Theme.of(
                  context,
                ).colorScheme.outlineVariant.withValues(alpha: 0.55),
              ),
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedSize(
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOutCubic,
                alignment: Alignment.bottomCenter,
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 150),
                  switchInCurve: Curves.easeOutCubic,
                  switchOutCurve: Curves.easeInCubic,
                  child: widget.replyingTo != null
                      ? ReplyBanner(
                          key: ValueKey('reply-${widget.replyingTo!.messageId}'),
                          message: widget.replyingTo!,
                          senderName:
                              widget.replyingTo!.senderDeviceId ==
                                  widget.localDeviceId
                              ? '我'
                              : widget.peerName(
                                  widget.replyingTo!.senderDeviceId,
                                ),
                          onCancel: widget.onCancelReply,
                        )
                      : const SizedBox.shrink(),
                ),
              ),
              AnimatedSize(
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOutCubic,
                alignment: Alignment.bottomCenter,
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 150),
                  switchInCurve: Curves.easeOutCubic,
                  switchOutCurve: Curves.easeInCubic,
                  child: widget.pendingAttachments.isNotEmpty
                      ? PendingAttachments(
                          key: const ValueKey('pending-attachments'),
                          attachments: widget.pendingAttachments,
                          onRemove: _removeAttachment,
                        )
                      : const SizedBox.shrink(),
                ),
              ),
              ValueListenableBuilder<TextEditingValue>(
                valueListenable: widget.composer,
                builder: (context, value, _) {
                  final query = value.text.trim();
                  final matches =
                      widget.enabled &&
                          widget.stickerSuggestionsEnabled &&
                          widget.pendingAttachments.isEmpty &&
                          query != _dismissedStickerQuery
                      ? matchStickersByRemark(widget.favoriteStickers, query)
                      : const <FavoriteSticker>[];
                  return AnimatedSize(
                    duration: const Duration(milliseconds: 180),
                    curve: Curves.easeOutCubic,
                    alignment: Alignment.bottomCenter,
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 150),
                      switchInCurve: Curves.easeOutCubic,
                      switchOutCurve: Curves.easeInCubic,
                      child: matches.isNotEmpty
                          ? QuickStickerSuggestionBar(
                              key: const ValueKey('quick-stickers-bar'),
                              stickers: matches,
                              onSelect: (sticker) async {
                                widget.composer.clear();
                                if (mounted) {
                                  setState(() => _dismissedStickerQuery = null);
                                }
                                await widget.onSendFavoriteSticker?.call(
                                  sticker,
                                );
                              },
                              onDismiss: () => setState(
                                () => _dismissedStickerQuery = query,
                              ),
                            )
                          : const SizedBox.shrink(),
                    ),
                  );
                },
              ),
              Row(
                children: [
                  IconButton(
                    key: _stickerButtonKey,
                    tooltip: '表情与收藏',
                    visualDensity: VisualDensity.compact,
                    onPressed: widget.enabled ? _toggleStickerPicker : null,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    icon: const Icon(
                      Icons.sentiment_satisfied_alt_outlined,
                      size: 20,
                    ),
                  ),
                  const SizedBox(width: 2),
                  IconButton(
                    tooltip: '添加图片或文件',
                    visualDensity: VisualDensity.compact,
                    onPressed: widget.enabled ? _pickAttachments : null,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    icon: const Icon(Icons.attach_file, size: 20),
                  ),
                ],
              ),
              const SizedBox(height: 2),
              widget.loadMentionCandidates == null
                  ? MessageComposer(
                      controller: widget.composer,
                      focusNode: _composerFocus,
                      enabled: widget.enabled,
                      hasAttachments: widget.pendingAttachments.isNotEmpty,
                      sendOnCtrlEnter: widget.sendOnCtrlEnter,
                      onSendOnCtrlEnterChanged: widget.onSendOnCtrlEnterChanged,
                      onSend: () => unawaited(_handleSend()),
                      onPasteAttachments: _pasteAttachments,
                    )
                  : MentionAutocomplete(
                      controller: widget.composer,
                      focusNode: _composerFocus,
                      enabled: widget.enabled,
                      hasAttachments: widget.pendingAttachments.isNotEmpty,
                      sendOnCtrlEnter: widget.sendOnCtrlEnter,
                      onSendOnCtrlEnterChanged: widget.onSendOnCtrlEnterChanged,
                      onSend: () => unawaited(_handleSend()),
                      onPasteAttachments: _pasteAttachments,
                      loadCandidates: widget.loadMentionCandidates!,
                    ),
            ],
          ),
        ),
      ],
    );
    if (!widget.useDesktopDrop) return content;
    return DropTarget(
      enable: widget.enabled,
      onDragEntered: (_) => _setDraggingFiles(true),
      onDragExited: (_) => _setDraggingFiles(false),
      onDragDone: (details) => unawaited(_sendDroppedFiles(details)),
      child: Stack(
        fit: StackFit.expand,
        children: [
          content,
          if (_draggingFiles || _sendingDroppedFiles)
            FileDropOverlay(sending: _sendingDroppedFiles),
        ],
      ),
    );
  }
}

/// 拖放文件到会话时的全屏提示层。
class FileDropOverlay extends StatelessWidget {
  const FileDropOverlay({super.key, required this.sending});
  final bool sending;

  @override
  Widget build(BuildContext context) => Positioned.fill(
    child: IgnorePointer(
      child: Container(
        key: const ValueKey('file-drop-overlay'),
        color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.88),
        alignment: Alignment.center,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 22),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.primaryContainer,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: Theme.of(context).colorScheme.primary,
              width: 2,
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                sending ? Icons.upload_file : Icons.file_download_outlined,
                size: 44,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(height: 12),
              Text(
                sending ? '正在发送文件…' : '松开发送文件',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              if (!sending) ...[
                const SizedBox(height: 4),
                Text(
                  '支持同时拖入多个文件，将立即发送',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ],
          ),
        ),
      ),
    ),
  );
}

/// 输入框上方的待发送附件区域：图片显示缩略图，其他文件显示文件名。
class PendingAttachments extends StatelessWidget {
  const PendingAttachments({
    super.key,
    required this.attachments,
    required this.onRemove,
  });

  final List<PendingAttachment> attachments;
  final void Function(PendingAttachment) onRemove;

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(bottom: 8),
    padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(10),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              Icons.attach_file,
              size: 15,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(width: 6),
            Text(
              '待发送 ${attachments.length} 个附件，将与文字一起发出',
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ],
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 74,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: attachments.length,
            separatorBuilder: (_, _) => const SizedBox(width: 8),
            itemBuilder: (context, index) => PendingAttachmentChip(
              attachment: attachments[index],
              onRemove: () => onRemove(attachments[index]),
            ),
          ),
        ),
      ],
    ),
  );
}

class PendingAttachmentChip extends StatelessWidget {
  const PendingAttachmentChip({
    super.key,
    required this.attachment,
    required this.onRemove,
  });

  final PendingAttachment attachment;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Tooltip(
      message:
          '${attachment.fileName}\n${AppController.formatFileSize(attachment.fileSize)}',
      child: Container(
        width: 88,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: colorScheme.surface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: colorScheme.outlineVariant),
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (attachment.isImage)
              Image.file(
                File(attachment.path),
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => _filePreview(context),
              )
            else
              _filePreview(context),
            Positioned(
              top: 2,
              right: 2,
              child: _RemoveAttachmentButton(onPressed: onRemove),
            ),
          ],
        ),
      ),
    );
  }

  Widget _filePreview(BuildContext context) => Padding(
    // 顶部留出空间，避免文字顶到右上角的移除按钮。
    padding: const EdgeInsets.fromLTRB(6, 20, 6, 4),
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(
          Icons.insert_drive_file_outlined,
          size: 22,
          color: Theme.of(context).colorScheme.outline,
        ),
        const SizedBox(height: 4),
        Text(
          attachment.fileName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.labelSmall,
        ),
      ],
    ),
  );
}

class _RemoveAttachmentButton extends StatelessWidget {
  const _RemoveAttachmentButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.black54,
    shape: const CircleBorder(),
    child: InkWell(
      customBorder: const CircleBorder(),
      onTap: onPressed,
      child: const Tooltip(
        message: '移除附件',
        child: Padding(
          padding: EdgeInsets.all(3),
          child: Icon(Icons.close, size: 13, color: Colors.white),
        ),
      ),
    ),
  );
}

class ReplyBanner extends StatelessWidget {
  const ReplyBanner({
    super.key,
    required this.message,
    required this.senderName,
    this.onCancel,
  });

  /// 被引用的原消息，用于展示图片缩略图或文件图标。
  final ChatMessage message;
  final String senderName;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    final leading = _quoteLeading(context, message, size: 32);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(10, 6, 4, 6),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        // 左侧是一整条竖线，不加圆角，避免圆角把竖线截断。
        border: Border(
          left: BorderSide(
            color: Theme.of(context).colorScheme.primary,
            width: 3,
          ),
        ),
      ),
      child: Row(
        children: [
          Icon(
            Icons.reply,
            size: 18,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(width: 8),
          if (leading != null) ...[leading, const SizedBox(width: 8)],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '引用 $senderName',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
                Text(
                  AppController.replyPreview(message),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: '取消引用',
            onPressed: onCancel,
            icon: const Icon(Icons.close, size: 18),
          ),
        ],
      ),
    );
  }
}

/// 引用内容左侧的缩略图：图片显示缩略图，文件显示图标，文本返回 null。
///
/// 被引用的图片只有在本机已经收到时才能预览，否则退回文件名。
Widget? _quoteLeading(
  BuildContext context,
  ChatMessage message, {
  required double size,
}) {
  final outline = Theme.of(context).colorScheme.outline;
  switch (message.kind) {
    case MessageKind.image:
      final path = message.filePath;
      if (path != null && File(path).existsSync()) {
        return ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: Image.file(
            File(path),
            width: size,
            height: size,
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) =>
                Icon(Icons.image_outlined, size: size, color: outline),
          ),
        );
      }
      return Icon(Icons.image_outlined, size: size, color: outline);
    case MessageKind.file:
      return Icon(Icons.insert_drive_file_outlined, size: size, color: outline);
    case MessageKind.text:
      return null;
  }
}

class MessageBubble extends StatelessWidget {
  const MessageBubble({
    super.key,
    required this.message,
    required this.mine,
    required this.senderName,
    required this.missingHint,
    required this.onOpen,
    required this.onOpenFolder,
    required this.onAccept,
    required this.onReject,
    required this.onRetry,
    required this.onRelocate,
    this.headerName,
    this.senderRole,
    this.avatarPath,
    this.showHeader = true,
    this.mentioned = false,
    this.highlighted = false,
    this.replySenderName,
    this.onReply,
    this.onCopy,
    this.onMention,
    this.onRecall,
    this.onAddToStickers,
    this.resolveMessage,
    this.onJumpToReply,
    this.onShowFallbackMenu,
    this.onSelectionChanged,
    this.selectedText,
  });

  /// 气泡内文本选区变化时回调，便于右键菜单「复制」只复制选中的片段。
  final ValueChanged<String?>? onSelectionChanged;

  /// 读取当前气泡内选中的文本，没有选区时返回 null。
  final String? Function()? selectedText;
  final ChatMessage message;
  final bool mine;
  final String senderName;

  /// 消息头像上方显示的昵称；缺省时回退到 [senderName]。
  final String? headerName;

  /// 群聊里的角色标签（群主/管理员），私聊为 null。
  final GroupRole? senderRole;

  /// 发送者头像本地路径，为空时回退到首字母。
  final String? avatarPath;

  /// 是否显示昵称/角色这一行。私聊里自己的消息不显示。
  final bool showHeader;
  final String missingHint;
  final Future<void> Function(ChatMessage) onOpen;
  final Future<void> Function(ChatMessage) onOpenFolder;
  final Future<void> Function(ChatMessage) onAccept;
  final Future<void> Function(ChatMessage) onReject;
  final Future<void> Function(ChatMessage) onRetry;
  final Future<void> Function(ChatMessage) onRelocate;

  /// 本条消息是否 @ 了本机用户。
  final bool mentioned;

  /// 从引用跳转过来后短暂高亮，方便找到目标。
  final bool highlighted;

  /// 引用块显示的发送者昵称，消息没有引用时为 null。
  final String? replySenderName;
  final VoidCallback? onReply;
  final Future<void> Function()? onCopy;
  final VoidCallback? onMention;
  final Future<void> Function()? onRecall;
  final Future<void> Function()? onAddToStickers;

  /// 按消息 id 找到本地的原消息，用于在引用块里展示图片缩略图。
  final ChatMessage? Function(String messageId)? resolveMessage;

  /// 点击引用块时跳到被引用的原消息。
  final void Function(String messageId)? onJumpToReply;

  /// 纯图片气泡没有可选中的文字，框架的选择工具栏不会弹出，
  /// 把菜单项交给面板用叠加层自绘。
  final void Function(
    BuildContext context,
    Offset position,
    List<ChatContextMenuItem> Function(VoidCallback dismiss) buildItems,
  )?
  onShowFallbackMenu;

  /// 气泡里是否存在可被选中的文字。
  ///
  /// 图片消息且本地已经有文件时，气泡里只有图片（时间等元信息不可选），
  /// 此时需要走自绘菜单。
  bool get _hasSelectableContent {
    final path = message.filePath;
    final hasLocalFile = path != null && File(path).existsSync();
    return !(message.kind == MessageKind.image && hasLocalFile);
  }

  @override
  Widget build(BuildContext context) => Listener(
    behavior: HitTestBehavior.translucent,
    onPointerDown: (event) {
      if ((event.buttons & kSecondaryMouseButton) != 0) {
        _showOwnMenu(context, event.position);
      }
    },
    child: GestureDetector(
      behavior: HitTestBehavior.translucent,
      onSecondaryTapDown: (details) =>
          _showOwnMenu(context, details.globalPosition),
      child: _buildRow(context),
    ),
  );

  Widget _buildRow(BuildContext context) => AnimatedContainer(
    // 整行高亮：从引用跳转过来时给这一行铺底色，比只描气泡边框更容易定位。
    duration: const Duration(milliseconds: 220),
    width: double.infinity,
    margin: const EdgeInsets.only(bottom: 10),
    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
    decoration: BoxDecoration(
      color: highlighted
          ? Theme.of(context).colorScheme.primary.withValues(alpha: .12)
          : Colors.transparent,
      borderRadius: BorderRadius.circular(12),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: mine
          ? MainAxisAlignment.end
          : MainAxisAlignment.start,
      children: [
        if (!mine) ...[
          _headerAvatar(context),
          const SizedBox(width: 8),
        ],
        Flexible(
          child: Column(
            crossAxisAlignment: mine
                ? CrossAxisAlignment.end
                : CrossAxisAlignment.start,
            children: [
              if (showHeader) _header(context),
              _hasSelectableContent
                  // 文字气泡保留拖选文本的能力；框架自带的选择工具栏不再弹出，
                  // 右键统一由整行的监听弹出同一套自绘菜单。
                  ? SelectionArea(
                      contextMenuBuilder: (_, _) => const SizedBox.shrink(),
                      onSelectionChanged: (content) =>
                          onSelectionChanged?.call(content?.plainText),
                      child: _buildBubble(context),
                    )
                  : _buildBubble(context),
            ],
          ),
        ),
        if (mine) ...[
          const SizedBox(width: 8),
          _headerAvatar(context),
        ],
      ],
    ),
  );

  /// 头像列。使用 [avatarPath] 渲染同步到的头像，缺失时回退到昵称首字母。
  Widget _headerAvatar(BuildContext context) => NamedAvatar(
    imagePath: avatarPath,
    name: headerName ?? senderName,
    radius: 16,
  );

  /// 气泡上方的昵称与角色标签。
  Widget _header(BuildContext context) => Padding(
    padding: const EdgeInsets.only(left: 2, right: 2, bottom: 2),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (senderRole != null) ...[
          RoleTag(role: senderRole!),
          const SizedBox(width: 6),
        ],
        Text(
          headerName ?? senderName,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: mine
                ? Theme.of(context).colorScheme.onSurfaceVariant
                : Theme.of(context).colorScheme.primary,
          ),
        ),
        if (mentioned) ...[
          const SizedBox(width: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.errorContainer,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              '@我',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: Theme.of(context).colorScheme.onErrorContainer,
              ),
            ),
          ),
        ],
      ],
    ),
  );

  /// 气泡本体。昵称与角色已经渲染在气泡上方，这里只放内容与时间。
  Widget _buildBubble(BuildContext context) => Container(
    constraints: const BoxConstraints(maxWidth: 560),
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    decoration: BoxDecoration(
      color: mine
          ? Theme.of(context).colorScheme.primaryContainer
          : Theme.of(context).colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(14),
      border: mentioned
          ? Border.all(color: Theme.of(context).colorScheme.error, width: 1.6)
          : null,
    ),
    child: Column(
      crossAxisAlignment: mine
          ? CrossAxisAlignment.end
          : CrossAxisAlignment.start,
      children: [
        if (message.isReply) _unselectable(_buildQuoted(context)),
        if (message.kind == MessageKind.text)
          Text(
            message.content,
            textAlign: mine ? TextAlign.right : TextAlign.left,
          )
        else
          _buildAttachment(context),
        const SizedBox(height: 4),
        _unselectable(
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _time(message.timestamp),
                style: Theme.of(context).textTheme.labelSmall,
              ),
              if (mine) ...[
                const SizedBox(width: 5),
                Icon(
                  _statusIcon(message.status),
                  size: 13,
                  color:
                      message.status == MessageStatus.failed ||
                          message.status == MessageStatus.rejected
                      ? Theme.of(context).colorScheme.error
                      : null,
                ),
                if (message.kind != MessageKind.text) ...[
                  const SizedBox(width: 4),
                  Text(
                    _statusLabel(message.status, mine: mine),
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                ],
              ],
            ],
          ),
        ),
      ],
    ),
  );

  Widget _buildAttachment(BuildContext context) {
    final path = message.filePath;
    final hasLocalFile = path != null && File(path).existsSync();
    final canDecide =
        !mine && message.status == MessageStatus.awaitingAcceptance;
    final canRetry = !mine && message.status == MessageStatus.failed;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 360),
      child: Column(
        crossAxisAlignment: mine
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        children: [
          if (message.kind == MessageKind.image && hasLocalFile)
            ClipRRect(
              borderRadius: BorderRadius.circular(9),
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: 360,
                  maxHeight: 360,
                ),
                child: Image.file(
                  File(path),
                  fit: BoxFit.contain,
                  errorBuilder: (_, _, _) => const SizedBox.shrink(),
                ),
              ),
            ),
          if (message.kind != MessageKind.image || !hasLocalFile)
            Row(
              mainAxisSize: MainAxisSize.min,
              textDirection: mine ? TextDirection.rtl : TextDirection.ltr,
              children: [
                Icon(
                  message.kind == MessageKind.image
                      ? Icons.image_outlined
                      : Icons.insert_drive_file_outlined,
                  size: 34,
                ),
                const SizedBox(width: 10),
                Flexible(
                  child: Column(
                    crossAxisAlignment: mine
                        ? CrossAxisAlignment.end
                        : CrossAxisAlignment.start,
                    children: [
                      Text(
                        message.fileName ?? message.content,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        textAlign: mine ? TextAlign.right : TextAlign.left,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      _unselectable(
                        Text(
                          AppController.formatFileSize(message.fileSize ?? 0),
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          if (canDecide) ...[
            const SizedBox(height: 10),
            _unselectable(
              Text(
                '这是一个大文件，接受后才会开始传输。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                OutlinedButton(
                  onPressed: () => onReject(message),
                  child: const Text('拒绝'),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: () => onAccept(message),
                  icon: const Icon(Icons.download, size: 18),
                  label: const Text('接受并下载'),
                ),
              ],
            ),
          ] else if (message.status == MessageStatus.rejected) ...[
            const SizedBox(height: 8),
            Text(
              mine ? '对方已拒收，请重新发送。' : '已拒收，如需接收请让对方重新发送。',
              textAlign: mine ? TextAlign.right : TextAlign.left,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ] else if (message.status == MessageStatus.pending && !mine) ...[
            const SizedBox(height: 8),
            const Row(
              children: [
                SizedBox.square(
                  dimension: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                SizedBox(width: 8),
                Text('正在接收…'),
              ],
            ),
          ] else if (canRetry) ...[
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () => onRetry(message),
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('重试接收'),
            ),
          ] else if (!hasLocalFile && message.status == MessageStatus.sent) ...[
            const SizedBox(height: 8),
            Text(
              missingHint,
              textAlign: mine ? TextAlign.right : TextAlign.left,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
            if (mine) ...[
              const SizedBox(height: 6),
              OutlinedButton.icon(
                onPressed: () => onRelocate(message),
                icon: const Icon(Icons.link, size: 18),
                label: const Text('重新指定文件'),
              ),
            ],
          ] else if (message.kind == MessageKind.file &&
              hasLocalFile &&
              message.status == MessageStatus.sent) ...[
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: () => onOpen(message),
              icon: const Icon(Icons.open_in_new, size: 18),
              label: const Text('打开文件'),
            ),
          ],
        ],
      ),
    );
  }

  /// 引用块：展示被引用消息的发送者、摘要，图片还能直接看到缩略图。
  /// 点击后跳回被引用的原消息。
  Widget _buildQuoted(BuildContext context) {
    final quoted = resolveMessage?.call(message.replyToMessageId!);
    final leading = quoted == null
        ? null
        : _quoteLeading(context, quoted, size: 44);
    return GestureDetector(
      onTap: onJumpToReply == null
          ? null
          : () => onJumpToReply!(message.replyToMessageId!),
      child: MouseRegion(
        cursor: onJumpToReply == null
            ? MouseCursor.defer
            : SystemMouseCursors.click,
        child: Container(
          margin: const EdgeInsets.only(bottom: 6),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest
                .withValues(alpha: .7),
            // 左侧是一整条竖线，不加圆角，避免圆角把竖线截断。
            border: Border(
              left: BorderSide(
                color: Theme.of(context).colorScheme.primary,
                width: 3,
              ),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (leading != null) ...[leading, const SizedBox(width: 8)],
              Flexible(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      replySenderName ?? '被引用的消息',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                    Text(
                      message.replyToPreview ?? '',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 图片/文字气泡的右键入口：把菜单项交给面板渲染。
  void _showOwnMenu(BuildContext context, Offset position) {
    final handler = onShowFallbackMenu;
    if (handler == null) return;
    handler(context, position, _fallbackMenuItems);
  }

  /// 右键菜单项：对齐现代桌面聊天应用（图 2 样式），包含图标、悬浮和分割线。
  List<ChatContextMenuItem> _fallbackMenuItems(VoidCallback dismiss) {
    final selection = selectedText?.call();
    final hasSelection = selection != null && selection.trim().isNotEmpty;
    return [
      if (message.kind == MessageKind.image &&
          _hasLocalAttachment &&
          onAddToStickers != null)
        ChatContextMenuItem(
          icon: Icons.add_reaction_outlined,
          label: '添加到表情',
          onTap: () {
            dismiss();
            unawaited(onAddToStickers!());
          },
        ),
      ChatContextMenuItem(
        icon: Icons.copy_rounded,
        label: hasSelection ? '复制选中' : '复制',
        onTap: () {
          dismiss();
          if (hasSelection) {
            unawaited(Clipboard.setData(ClipboardData(text: selection)));
          } else {
            unawaited(onCopy?.call() ?? Future<void>.value());
          }
        },
      ),
      if (onReply != null)
        ChatContextMenuItem(
          icon: Icons.format_quote_rounded,
          label: '引用回复',
          onTap: () {
            dismiss();
            onReply!();
          },
        ),
      if (onMention != null)
        ChatContextMenuItem(
          icon: Icons.alternate_email_rounded,
          label: '@$senderName',
          onTap: () {
            dismiss();
            onMention!();
          },
        ),
      if (_hasLocalAttachment) ...[
        ChatContextMenuItem(
          hasDividerBefore: true,
          icon: message.kind == MessageKind.image
              ? Icons.image_outlined
              : Icons.insert_drive_file_outlined,
          label: message.kind == MessageKind.image ? '打开图片' : '打开文件',
          onTap: () {
            dismiss();
            unawaited(onOpen(message));
          },
        ),
        ChatContextMenuItem(
          icon: Icons.folder_open_outlined,
          label: '打开所在文件夹',
          onTap: () {
            dismiss();
            unawaited(onOpenFolder(message));
          },
        ),
      ],
      if (onRecall != null)
        ChatContextMenuItem(
          hasDividerBefore: true,
          icon: Icons.undo_rounded,
          label: '撤回',
          onTap: () {
            dismiss();
            unawaited(onRecall!());
          },
        ),
    ];
  }

  bool get _hasLocalAttachment {
    final path = message.filePath;
    return path != null && File(path).existsSync();
  }
}

class ChatContextMenuItem {
  const ChatContextMenuItem({
    required this.label,
    required this.icon,
    required this.onTap,
    this.hasDividerBefore = false,
  });

  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final bool hasDividerBefore;
}

class RecallNotice extends StatelessWidget {
  const RecallNotice({
    super.key,
    required this.text,
    required this.highlighted,
  });

  final String text;
  final bool highlighted;

  @override
  Widget build(BuildContext context) => AnimatedContainer(
    duration: const Duration(milliseconds: 220),
    width: double.infinity,
    margin: const EdgeInsets.only(bottom: 12),
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    color: highlighted
        ? Theme.of(context).colorScheme.primary.withValues(alpha: .08)
        : Colors.transparent,
    alignment: Alignment.center,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest
            .withValues(alpha: .55),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        text,
        style: Theme.of(context).textTheme.labelMedium
            ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
    ),
  );
}

/// 把元信息（昵称、时间、引用摘要等）排除在文本选择之外，
/// 这样「全选」只会选中真正的消息内容。
Widget _unselectable(Widget child) => SelectionContainer.disabled(child: child);

class TopRightSnackBar extends StatelessWidget {
  const TopRightSnackBar({
    super.key,
    required this.message,
    required this.icon,
    required this.onClose,
  });

  final String message;
  final IconData icon;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) => Material(
    elevation: 8,
    color: Theme.of(context).colorScheme.inverseSurface,
    borderRadius: BorderRadius.circular(10),
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 420),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 6, 10),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 20,
              color: Theme.of(context).colorScheme.onInverseSurface,
            ),
            const SizedBox(width: 10),
            Flexible(
              child: Text(
                message,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onInverseSurface,
                ),
              ),
            ),
            IconButton(
              tooltip: '关闭',
              onPressed: onClose,
              icon: Icon(
                Icons.close,
                size: 18,
                color: Theme.of(context).colorScheme.onInverseSurface,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _FloatingDrawerOverlay extends StatefulWidget {
  const _FloatingDrawerOverlay({
    required this.open,
    required this.onDismiss,
    required this.drawer,
  });

  final bool open;
  final VoidCallback onDismiss;
  final Widget drawer;

  @override
  State<_FloatingDrawerOverlay> createState() => _FloatingDrawerOverlayState();
}

class _FloatingDrawerOverlayState extends State<_FloatingDrawerOverlay>
    with SingleTickerProviderStateMixin {
  static const Curve _openCurve = Cubic(0.16, 1.0, 0.3, 1.0);
  static const Curve _closeCurve = Curves.easeOutCubic;

  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 280),
    reverseDuration: const Duration(milliseconds: 220),
  );
  late final Animation<double> _scrimFade = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOut,
    reverseCurve: Curves.easeOut,
  );
  late final Animation<Offset> _slide =
      Tween<Offset>(begin: const Offset(1.04, 0), end: Offset.zero).animate(
        CurvedAnimation(
          parent: _controller,
          curve: _openCurve,
          reverseCurve: _closeCurve,
        ),
      );

  @override
  void initState() {
    super.initState();
    if (widget.open) {
      _controller.value = 1.0;
    }
    _controller.addStatusListener(_handleStatusChanged);
  }

  @override
  void didUpdateWidget(covariant _FloatingDrawerOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.open && !oldWidget.open) {
      _controller.forward();
    } else if (!widget.open && oldWidget.open) {
      _controller.reverse();
    }
  }

  void _handleStatusChanged(AnimationStatus status) {
    if (status == AnimationStatus.dismissed && mounted) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    _controller.removeStatusListener(_handleStatusChanged);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.open && _controller.isDismissed) {
      return const IgnorePointer(child: SizedBox.shrink());
    }
    return IgnorePointer(
      ignoring: !widget.open,
      child: ClipRect(
        child: Stack(
          fit: StackFit.expand,
          children: [
            FadeTransition(
              opacity: _scrimFade,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: widget.open ? widget.onDismiss : null,
                child: const ColoredBox(color: Colors.black12),
              ),
            ),
            Positioned(
              top: 10,
              right: 12,
              bottom: 12,
              child: SlideTransition(
                position: _slide,
                child: widget.drawer,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AnimatedMessageEntrance extends StatefulWidget {
  const _AnimatedMessageEntrance({
    super.key,
    required this.mine,
    required this.child,
    required this.onCompleted,
  });

  final bool mine;
  final Widget child;
  final VoidCallback onCompleted;

  @override
  State<_AnimatedMessageEntrance> createState() =>
      _AnimatedMessageEntranceState();
}

class _AnimatedMessageEntranceState extends State<_AnimatedMessageEntrance>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
  );
  late final Animation<double> _fade = CurvedAnimation(
    parent: _controller,
    curve: const Interval(0.0, 0.55, curve: Curves.easeOut),
  );
  late final Animation<Offset> _slide =
      Tween<Offset>(begin: const Offset(0, 0.16), end: Offset.zero).animate(
        CurvedAnimation(
          parent: _controller,
          curve: const Cubic(0.16, 1.0, 0.3, 1.0),
        ),
      );

  @override
  void initState() {
    super.initState();
    _controller.forward().whenComplete(() {
      if (mounted) widget.onCompleted();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
    opacity: _fade,
    child: SlideTransition(position: _slide, child: widget.child),
  );
}

class _NavRailButton extends StatelessWidget {
  const _NavRailButton({
    super.key,
    required this.tooltip,
    required this.icon,
    required this.selected,
    required this.badgeCount,
    required this.onTap,
  });

  final String tooltip;
  final IconData icon;
  final bool selected;
  final int badgeCount;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOutCubic,
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: selected
                    ? colorScheme.primaryContainer
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                icon,
                size: 22,
                color: selected
                    ? colorScheme.primary
                    : colorScheme.onSurfaceVariant,
              ),
            ),
            if (badgeCount > 0)
              Positioned(
                top: -3,
                right: -5,
                child: UnreadBadge(count: badgeCount),
              ),
          ],
        ),
      ),
    );
  }
}

class _ContactGroupHeader extends StatelessWidget {
  const _ContactGroupHeader({
    required this.title,
    required this.countLabel,
    required this.expanded,
    required this.onTap,
  });

  final String title;
  final String countLabel;
  final bool expanded;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 14, 10),
      child: Row(
        children: [
          AnimatedRotation(
            turns: expanded ? 0.25 : 0.0,
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOutCubic,
            child: Icon(
              Icons.chevron_right,
              size: 18,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              title,
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
          Text(
            countLabel,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    ),
  );
}

/// 联系人 -> 新朋友：右侧审批面板，集中处理收发中的好友申请。
class FriendRequestsPane extends StatelessWidget {
  const FriendRequestsPane({
    super.key,
    required this.controller,
    required this.requests,
  });

  final AppController controller;
  final List<ChatRequest> requests;

  @override
  Widget build(BuildContext context) {
    final incoming = requests.where((r) => r.incoming).toList();
    final outgoing = requests.where((r) => !r.incoming).toList();
    return Column(
      children: [
        _PaneHeader(
          title: '新朋友',
          subtitle: '通过好友申请后，对方将加入已验证联系人',
        ),
        const Divider(height: 1),
        Expanded(
          child: requests.isEmpty
              ? const _EmptyApprovalState(
                  icon: Icons.person_add_disabled_outlined,
                  title: '暂无新的好友验证请求',
                  subtitle: '收到局域网其他设备的聊天请求或你主动发起请求时，会在这里显示。',
                )
              : Align(
                  alignment: Alignment.topCenter,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 680),
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
                      children: [
                        if (incoming.isNotEmpty) ...[
                          const SectionTitle(title: '待我审批'),
                          for (final request in incoming)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: ChatRequestCard(
                                controller: controller,
                                request: request,
                              ),
                            ),
                        ],
                        if (outgoing.isNotEmpty) ...[
                          const SectionTitle(title: '等待对方确认'),
                          for (final request in outgoing)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: ChatRequestCard(
                                controller: controller,
                                request: request,
                              ),
                            ),
                        ],
                      ],
                    ),
                  ),
                ),
        ),
      ],
    );
  }
}

/// 联系人 -> 群通知：右侧审批面板，集中处理收到的局域网群聊邀请。
class GroupNotificationsPane extends StatelessWidget {
  const GroupNotificationsPane({
    super.key,
    required this.controller,
    required this.invitations,
  });

  final AppController controller;
  final List<GroupInvitation> invitations;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const _PaneHeader(
          title: '群通知',
          subtitle: '审批收到的局域网群聊邀请',
        ),
        const Divider(height: 1),
        Expanded(
          child: invitations.isEmpty
              ? const _EmptyApprovalState(
                  icon: Icons.notifications_none_outlined,
                  title: '暂无新的群通知',
                  subtitle: '当其他设备邀请你加入群聊时，会在这里等待你同意或拒绝。',
                )
              : Align(
                  alignment: Alignment.topCenter,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 680),
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
                      children: [
                        const SectionTitle(title: '待处理群邀请'),
                        for (final invitation in invitations)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: GroupInviteCard(
                              controller: controller,
                              invitation: invitation,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
        ),
      ],
    );
  }
}

/// 联系人详情面板：展示已验证联系人的完整资料与快捷操作。
class ContactDetailPane extends StatelessWidget {
  const ContactDetailPane({
    super.key,
    required this.controller,
    required this.trustedPeer,
    required this.discoveredPeer,
    required this.onStartChat,
    required this.onEditRemark,
    required this.onToggleBlock,
    this.onRevokeVerification,
  });

  final AppController controller;
  final TrustedPeer trustedPeer;
  final DiscoveredPeer? discoveredPeer;
  final VoidCallback onStartChat;
  final VoidCallback onEditRemark;
  final VoidCallback onToggleBlock;
  final VoidCallback? onRevokeVerification;

  @override
  Widget build(BuildContext context) {
    final originalName = discoveredPeer?.displayName ?? trustedPeer.displayName;
    final displayName = controller.peerDisplayName(
      trustedPeer.deviceId,
      originalName,
    );
    final remark = controller.peerRemarks[trustedPeer.deviceId];
    final online = discoveredPeer?.online == true;
    final blocked = trustedPeer.blocked;
    final rows = <(IconData, String, String)>[
      (Icons.badge_outlined, '昵称', originalName),
      if (remark != null) (Icons.edit_note_outlined, '备注', remark),
      (Icons.fingerprint, '设备 ID', trustedPeer.deviceId),
      (
        Icons.lan_outlined,
        '网络',
        discoveredPeer?.ip ??
            (trustedPeer.lastKnownIp.isNotEmpty
                ? '${trustedPeer.lastKnownIp}（最近已知）'
                : '离线'),
      ),
      (Icons.wifi_tethering, '在线状态', online ? '在线' : '离线'),
      (
        Icons.verified_user_outlined,
        '验证状态',
        blocked ? '已拉黑' : '已验证',
      ),
    ];

    return Column(
      children: [
        _PaneHeader(
          title: '联系人资料',
          subtitle: blocked ? '该联系人当前在黑名单中' : '已验证的局域网联系人',
        ),
        const Divider(height: 1),
        Expanded(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(28),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 520),
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.all(28),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Center(
                          child: NamedAvatar(
                            imagePath: controller.peerAvatarPath(
                              trustedPeer.deviceId,
                            ),
                            name: displayName,
                            radius: 40,
                          ),
                        ),
                        const SizedBox(height: 14),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Flexible(
                              child: Text(
                                displayName,
                                style: Theme.of(context).textTheme.titleLarge,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (!blocked) ...[
                              const SizedBox(width: 6),
                              const Icon(
                                Icons.verified,
                                color: Colors.blue,
                                size: 20,
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 20),
                        for (final row in rows)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 5),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Icon(row.$1, size: 18, color: Colors.grey),
                                const SizedBox(width: 10),
                                SizedBox(
                                  width: 72,
                                  child: Text(
                                    row.$2,
                                    style: const TextStyle(color: Colors.grey),
                                  ),
                                ),
                                Expanded(
                                  child: SelectableText(
                                    row.$3,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        const SizedBox(height: 24),
                        Wrap(
                          spacing: 10,
                          runSpacing: 10,
                          alignment: WrapAlignment.center,
                          children: [
                            if (!blocked)
                              FilledButton.icon(
                                onPressed: onStartChat,
                                icon: const Icon(
                                  Icons.chat_bubble_outline,
                                  size: 18,
                                ),
                                label: const Text('发消息'),
                              ),
                            OutlinedButton.icon(
                              onPressed: onEditRemark,
                              icon: const Icon(
                                Icons.drive_file_rename_outline,
                                size: 18,
                              ),
                              label: const Text('修改备注'),
                            ),
                            if (onRevokeVerification != null)
                              OutlinedButton.icon(
                                onPressed: onRevokeVerification,
                                icon: const Icon(
                                  Icons.gpp_bad_outlined,
                                  size: 18,
                                ),
                                label: const Text('取消验证'),
                              ),
                            OutlinedButton.icon(
                              onPressed: onToggleBlock,
                              icon: Icon(
                                blocked
                                    ? Icons.check_circle_outline
                                    : Icons.block,
                                size: 18,
                              ),
                              label: Text(blocked ? '解除拉黑' : '拉黑此人'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _PaneHeader extends StatelessWidget {
  const _PaneHeader({required this.title, required this.subtitle});

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) => Material(
    color: Theme.of(context).colorScheme.surface,
    child: Container(
      height: 68,
      padding: const EdgeInsets.fromLTRB(22, 10, 20, 10),
      alignment: Alignment.centerLeft,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
          ),
          Text(
            subtitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    ),
  );
}

class _EmptyApprovalState extends StatelessWidget {
  const _EmptyApprovalState({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 420),
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 56, color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 16),
            Text(
              title,
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _ContactsPlaceholderPane extends StatelessWidget {
  const _ContactsPlaceholderPane();

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.contacts_outlined,
          size: 64,
          color: Theme.of(context).colorScheme.outline.withValues(alpha: .45),
        ),
        const SizedBox(height: 14),
        Text(
          '选择左侧新朋友、群通知或已验证联系人',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    ),
  );
}

class _GlobalSearchDialog extends StatefulWidget {
  const _GlobalSearchDialog({
    required this.controller,
    required this.onSelectPeer,
    required this.onSelectGroup,
  });

  final AppController controller;
  final Future<void> Function(UnifiedPeerEntry entry) onSelectPeer;
  final Future<void> Function(ChatGroup group) onSelectGroup;

  @override
  State<_GlobalSearchDialog> createState() => _GlobalSearchDialogState();
}

class _GlobalSearchDialogState extends State<_GlobalSearchDialog> {
  final _queryController = TextEditingController();

  @override
  void dispose() {
    _queryController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final query = _queryController.text.trim().toLowerCase();

    final peersById = {for (final peer in controller.peers) peer.deviceId: peer};
    final chatsByPeer = {
      for (final chat in controller.chats) chat.peerDeviceId: chat,
    };
    final candidateIds = <String>{
      ..._conversationEntries(controller).map((e) => e.deviceId),
      ...controller.trustedPeers.values
          .where((t) => !t.blocked)
          .map((t) => t.deviceId),
    };

    final matchedPeers = <UnifiedPeerEntry>[
      for (final deviceId in candidateIds)
        () {
          final peer = peersById[deviceId];
          final chat = chatsByPeer[deviceId];
          final trusted = controller.trustedPeers[deviceId];
          final originalName =
              peer?.displayName ??
              chat?.displayName ??
              trusted?.displayName ??
              '未知设备';
          final displayName = controller.peerDisplayName(
            deviceId,
            originalName,
          );
          return UnifiedPeerEntry(
            deviceId: deviceId,
            displayName: displayName,
            originalDisplayName: originalName,
            peer: peer,
            chat: chat,
            trustedPeer: trusted,
            avatarPath: controller.peerAvatarPath(deviceId),
          );
        }(),
    ].where((entry) {
      if (query.isEmpty) return true;
      return matchesPinyinSearch(entry.displayName, query) ||
          matchesPinyinSearch(entry.originalDisplayName, query) ||
          entry.deviceId.toLowerCase().contains(query) ||
          (entry.peer?.ip.contains(query) ?? false) ||
          (entry.trustedPeer?.lastKnownIp.contains(query) ?? false);
    }).toList();

    final matchedGroups = controller.groups.where((group) {
      if (query.isEmpty) return true;
      final displayName = controller.groupDisplayName(
        group.groupId,
        group.name,
      );
      return matchesPinyinSearch(displayName, query) ||
          matchesPinyinSearch(group.name, query);
    }).toList();

    return Dialog(
      key: const ValueKey('global-search-dialog'),
      insetPadding: const EdgeInsets.all(24),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520, maxHeight: 540),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
              child: TextField(
                controller: _queryController,
                autofocus: true,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  hintText: '搜索联系人或群聊',
                  prefixIcon: const Icon(Icons.search),
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(vertical: 14),
                  suffixIcon: _queryController.text.isEmpty
                      ? IconButton(
                          tooltip: '关闭',
                          onPressed: () => Navigator.pop(context),
                          icon: const Icon(Icons.close, size: 18),
                        )
                      : IconButton(
                          tooltip: '清空',
                          onPressed: () {
                            _queryController.clear();
                            setState(() {});
                          },
                          icon: const Icon(Icons.close, size: 18),
                        ),
                ),
              ),
            ),
            const Divider(height: 1),
            Flexible(
              child: matchedPeers.isEmpty && matchedGroups.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.symmetric(vertical: 48),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.search_off, size: 42, color: Colors.grey),
                          SizedBox(height: 10),
                          Text(
                            '没有找到匹配的联系人或群聊',
                            style: TextStyle(color: Colors.grey),
                          ),
                        ],
                      ),
                    )
                  : ListView(
                      shrinkWrap: true,
                      padding: const EdgeInsets.only(bottom: 12),
                      children: [
                        if (matchedPeers.isNotEmpty) ...[
                          const SectionTitle(title: '联系人'),
                          for (final entry in matchedPeers)
                            ListTile(
                              dense: true,
                              leading: NamedAvatar(
                                imagePath: entry.avatarPath,
                                name: entry.displayName,
                                radius: 18,
                              ),
                              title: Row(
                                children: [
                                  Flexible(
                                    child: Text(
                                      entry.displayName,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  if (entry.trustedPeer != null) ...[
                                    const SizedBox(width: 4),
                                    const Icon(
                                      Icons.verified,
                                      color: Colors.blue,
                                      size: 15,
                                    ),
                                  ],
                                ],
                              ),
                              subtitle: Text(
                                [
                                  if (entry.displayName !=
                                      entry.originalDisplayName)
                                    '原名：${entry.originalDisplayName}',
                                  entry.peer?.online == true ? '在线' : '离线',
                                  if (entry.peer?.ip != null) entry.peer!.ip,
                                ].join(' · '),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              trailing: const Icon(
                                Icons.chevron_right,
                                size: 18,
                              ),
                              onTap: () => widget.onSelectPeer(entry),
                            ),
                        ],
                        if (matchedGroups.isNotEmpty) ...[
                          const SectionTitle(title: '群聊'),
                          for (final group in matchedGroups)
                            ListTile(
                              dense: true,
                              leading: const CircleAvatar(
                                radius: 18,
                                child: Icon(Icons.groups, size: 19),
                              ),
                              title: Text(
                                controller.groupDisplayName(
                                  group.groupId,
                                  group.name,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Text(
                                _groupListSubtitle(controller, group),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              trailing: const Icon(
                                Icons.chevron_right,
                                size: 18,
                              ),
                              onTap: () => widget.onSelectGroup(group),
                            ),
                        ],
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class WelcomePane extends StatelessWidget {
  const WelcomePane({super.key, required this.controller});
  final AppController controller;
  @override
  Widget build(BuildContext context) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 560),
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.forum_rounded,
              size: 72,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(height: 20),
            Text(
              '你好，${controller.identity!.displayName}',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const SizedBox(height: 12),
            const Text(
              '到“联系人”里点“添加好友”，输入对方口令或从附近设备里挑选，发起好友申请，对方通过后即可聊天。',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 22),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    const Icon(Icons.security_outlined),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text('本机设备 ID\n${controller.identity!.deviceId}'),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// 会话列表条目：只包含已建立的私聊会话，不会混入底层发现的陌生设备。
/// 陌生设备不再能通过点击会话列表直接发起好友申请，添加好友统一走
/// “联系人 → 添加好友”（口令或附近设备）。
List<UnifiedPeerEntry> _conversationEntries(AppController controller) {
  final peersById = {for (final peer in controller.peers) peer.deviceId: peer};
  final entries = <UnifiedPeerEntry>[];
  for (final chat in controller.chats) {
    if (chat.state != ChatSessionState.active) continue;
    final trusted = controller.trustedPeers[chat.peerDeviceId];
    if (trusted?.blocked == true) continue;
    final peer = peersById[chat.peerDeviceId];
    final originalName = peer?.displayName ?? chat.displayName;
    entries.add(
      UnifiedPeerEntry(
        deviceId: chat.peerDeviceId,
        displayName: controller.peerDisplayName(
          chat.peerDeviceId,
          originalName,
        ),
        originalDisplayName: originalName,
        peer: peer,
        chat: chat,
        trustedPeer: trusted,
        avatarPath: controller.peerAvatarPath(chat.peerDeviceId),
      ),
    );
  }
  entries.sort((a, b) {
    final aTime =
        a.chat?.lastMessageAt?.millisecondsSinceEpoch ??
        a.chat?.createdAt?.millisecondsSinceEpoch ??
        0;
    final bTime =
        b.chat?.lastMessageAt?.millisecondsSinceEpoch ??
        b.chat?.createdAt?.millisecondsSinceEpoch ??
        0;
    if (aTime != bTime) return bTime.compareTo(aTime);
    return a.displayName.compareTo(b.displayName);
  });
  return entries;
}

String _peerListSubtitle(UnifiedPeerEntry entry) {
  final status = entry.chat?.lastMessagePreview ?? _unifiedPeerSubtitle(entry);
  if (entry.displayName == entry.originalDisplayName) return status;
  return '${entry.originalDisplayName} · $status';
}

String _groupRoleLabel(GroupRole role) => switch (role) {
  GroupRole.owner => '群主',
  GroupRole.admin => '管理员',
  GroupRole.member => '群成员',
};

String _groupListSubtitle(AppController controller, ChatGroup group) {
  final status =
      group.lastMessagePreview ??
      (group.ownerDeviceId == controller.identity!.deviceId ? '我创建的群聊' : '已加入');
  if (!controller.groupRemarks.containsKey(group.groupId)) return status;
  return '${group.name} · $status';
}

String _unifiedPeerSubtitle(UnifiedPeerEntry entry) {
  if (entry.trustedPeer?.blocked == true) return '已拉黑';
  final chat = entry.chat;
  if (chat?.state == ChatSessionState.pendingIncoming) return '等待你确认';
  if (chat?.state == ChatSessionState.pendingOutgoing) {
    return entry.trustedPeer == null ? '等待对方确认' : '正在恢复已验证会话…';
  }
  final peer = entry.peer;
  if (peer?.online == true) {
    final trust = entry.trustedPeer == null ? '未验证' : '已验证';
    final location = peer!.locationChanged ? ' · 网络位置变化' : '';
    return '${_machine(peer.ip)} · ${peer.ip} · $trust$location';
  }
  return entry.trustedPeer == null ? '离线' : '离线 · 已验证 · 可查看历史';
}

bool _peerOnline(AppController controller, String deviceId) =>
    controller.peers.any((peer) => peer.deviceId == deviceId && peer.online);
String _avatarText(String name) =>
    name.characters.take(1).toString().toUpperCase();
String _machine(String ip) => '${ip.split('.').last}号机';
String _time(DateTime value) =>
    '${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';

/// 列表里展示的简短时间：今天显示时分，否则显示月/日。
String _friendlyTime(DateTime value) {
  final now = DateTime.now();
  final sameDay =
      value.year == now.year &&
      value.month == now.month &&
      value.day == now.day;
  return sameDay ? _time(value) : '${value.month}/${value.day}';
}

IconData _statusIcon(MessageStatus status) => switch (status) {
  MessageStatus.pending => Icons.schedule,
  MessageStatus.awaitingAcceptance => Icons.hourglass_top,
  MessageStatus.sent => Icons.check,
  MessageStatus.rejected => Icons.block,
  MessageStatus.failed => Icons.error_outline,
  MessageStatus.recalled => Icons.undo,
};

String _statusLabel(MessageStatus status, {required bool mine}) =>
    switch (status) {
      MessageStatus.pending => '等待接收',
      MessageStatus.awaitingAcceptance => '等待对方接受',
      MessageStatus.sent => mine ? '已接受' : '已接收',
      MessageStatus.rejected => '已拒绝',
      MessageStatus.failed => '失败',
      MessageStatus.recalled => '已撤回',
    };

