import 'dart:io';

import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../core/models/models.dart';
import 'message_composer.dart';

class MainShell extends StatefulWidget {
  const MainShell({super.key, required this.controller});
  final AppController controller;

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  final _search = TextEditingController();
  final _composer = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    _composer.dispose();
    super.dispose();
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
                SizedBox(width: 340, child: _buildSidebar(controller)),
                const VerticalDivider(width: 1),
                Expanded(child: _buildContent(controller)),
              ],
            ),
            if (controller.topRightMessage != null)
              Positioned(
                top: 14,
                right: 18,
                child: _TopRightSnackBar(
                  message: controller.topRightMessage!,
                  icon: controller.topRightIcon,
                  onClose: controller.clearTopRightMessage,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildSidebar(AppController controller) {
    final query = _search.text.trim().toLowerCase();
    final entries = _unifiedPeerEntries(controller)
        .where(
          (entry) =>
              query.isEmpty ||
              entry.displayName.toLowerCase().contains(query) ||
              (entry.peer?.ip.contains(query) ?? false),
        )
        .toList();
    final visibleChatRequests = controller.chatRequests.values
        .where(
          (request) =>
              request.incoming ||
              controller.trustedPeers[request.peerDeviceId] == null,
        )
        .toList();
    final groups =
        controller.groups
            .where(
              (group) =>
                  query.isEmpty || group.name.toLowerCase().contains(query),
            )
            .toList()
          ..sort((a, b) {
            final aTime =
                a.lastMessageAt?.millisecondsSinceEpoch ??
                a.createdAt.millisecondsSinceEpoch;
            final bTime =
                b.lastMessageAt?.millisecondsSinceEpoch ??
                b.createdAt.millisecondsSinceEpoch;
            return bTime.compareTo(aTime);
          });
    return ColoredBox(
      color: Theme.of(context).colorScheme.surface,
      child: Column(
        children: [
          _IdentityHeader(
            identity: controller.identity!,
            unreadCount:
                controller.chats.fold(
                  0,
                  (sum, chat) => sum + chat.unreadCount,
                ) +
                controller.groups.fold(
                  0,
                  (sum, group) => sum + group.unreadCount,
                ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
            child: TextField(
              controller: _search,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                hintText: '搜索设备或会话',
                prefixIcon: Icon(Icons.search),
                isDense: true,
              ),
            ),
          ),
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
            child: ListView(
              padding: const EdgeInsets.only(bottom: 16),
              children: [
                if (visibleChatRequests.isNotEmpty) ...[
                  const _SectionTitle(title: '聊天邀请'),
                  for (final request in visibleChatRequests)
                    _ChatRequestCard(controller: controller, request: request),
                ],
                if (controller.groupInvitations.isNotEmpty) ...[
                  const _SectionTitle(title: '群邀请'),
                  for (final invitation in controller.groupInvitations.values)
                    _GroupInviteCard(
                      controller: controller,
                      invitation: invitation,
                    ),
                ],
                const _SectionTitle(title: '会话与设备'),
                if (entries.isEmpty)
                  const _EmptyHint(icon: Icons.radar, text: '正在寻找局域网设备…')
                else
                  for (final entry in entries)
                    _UnifiedPeerTile(
                      entry: entry,
                      selected:
                          entry.chat != null &&
                          controller.selectedChatId == entry.chat!.chatId,
                      onTap: () async {
                        final chat = entry.chat;
                        if (chat?.state == ChatSessionState.active ||
                            entry.peer?.online != true) {
                          if (chat != null) {
                            await controller.selectChat(chat.chatId);
                          }
                          return;
                        }
                        if (chat?.state == ChatSessionState.pendingIncoming ||
                            chat?.state == ChatSessionState.pendingOutgoing) {
                          return;
                        }
                        await controller.requestChat(entry.peer!);
                      },
                    ),
                _SectionTitle(
                  title: '群聊',
                  trailing: IconButton(
                    tooltip: '创建群聊',
                    onPressed: () => _showCreateGroup(controller),
                    icon: const Icon(Icons.add, size: 20),
                  ),
                ),
                if (groups.isEmpty)
                  const _EmptyHint(icon: Icons.groups_outlined, text: '还没有群聊')
                else
                  for (final group in groups)
                    ListTile(
                      selected: controller.selectedGroupId == group.groupId,
                      leading: const CircleAvatar(
                        child: Icon(Icons.groups, size: 20),
                      ),
                      title: Text(
                        group.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        group.lastMessagePreview ??
                            (group.ownerDeviceId ==
                                    controller.identity!.deviceId
                                ? '我创建的群聊'
                                : '已加入'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing:
                          group.unreadCount > 0 || group.lastMessageAt != null
                          ? _ConversationMeta(
                              time: group.lastMessageAt,
                              unreadCount: group.unreadCount,
                            )
                          : null,
                      onTap: () => controller.selectGroup(group.groupId),
                    ),
              ],
            ),
          ),
          const Divider(height: 1),
          if (controller.dataDirectory != null)
            ListTile(
              leading: const Icon(Icons.folder_outlined),
              title: const Text('数据文件夹'),
              subtitle: Text(
                controller.dataDirectory!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: controller.openDataDirectory,
            ),
          ListTile(
            leading: const Icon(Icons.notifications_active_outlined),
            title: const Text('系统通知'),
            subtitle: const Text('点击发送测试通知'),
            onTap: controller.showTestNotification,
          ),
        ],
      ),
    );
  }

  Widget _buildContent(AppController controller) {
    if (controller.selectedChatId != null) {
      final chat = controller.chats
          .where((value) => value.chatId == controller.selectedChatId)
          .firstOrNull;
      if (chat != null) {
        final online = _peerOnline(controller, chat.peerDeviceId);
        return _ConversationPane(
          title: chat.displayName,
          subtitle: online ? '在线' : '离线 · 消息不会离线排队',
          messages: controller.messages,
          localDeviceId: controller.identity!.deviceId,
          peerName: (deviceId) =>
              deviceId == chat.peerDeviceId ? chat.displayName : '我',
          composer: _composer,
          enabled: online && chat.state == ChatSessionState.active,
          onSend: () => _send(controller),
          onAttach: controller.pickAndSendFile,
          onPasteAttachments: controller.pasteAndSendAttachments,
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
          actions: [
            PopupMenuButton<String>(
              tooltip: '会话操作',
              onSelected: (value) async {
                if (value == 'close') await controller.closeChat(chat);
                if (value == 'block') {
                  await controller.setBlocked(chat.peerDeviceId, true);
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem(
                  value: 'close',
                  child: ListTile(
                    leading: Icon(Icons.close),
                    title: Text('关闭对话'),
                  ),
                ),
                PopupMenuItem(
                  value: 'block',
                  child: ListTile(
                    leading: Icon(Icons.block),
                    title: Text('加入黑名单'),
                  ),
                ),
              ],
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
        return _ConversationPane(
          title: group.name,
          subtitle: '局域网实时群聊 · 离线成员不会收到消息',
          messages: controller.messages,
          localDeviceId: controller.identity!.deviceId,
          peerName: (deviceId) {
            if (deviceId == controller.identity!.deviceId) return '我';
            return controller.trustedPeers[deviceId]?.displayName ??
                controller.peers
                    .where((peer) => peer.deviceId == deviceId)
                    .firstOrNull
                    ?.displayName ??
                '群成员';
          },
          composer: _composer,
          enabled: true,
          onSend: () => _send(controller),
          onAttach: controller.pickAndSendFile,
          onPasteAttachments: controller.pasteAndSendAttachments,
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
          onMention: _insertMention,
          onPickMentionMember: () => _pickMentionMember(controller),
          actions: [
            if (group.ownerDeviceId == controller.identity!.deviceId)
              IconButton(
                tooltip: '邀请在线成员',
                onPressed: () => _showInviteMembers(controller, group),
                icon: const Icon(Icons.person_add_alt_1),
              ),
            PopupMenuButton<String>(
              tooltip: '群聊操作',
              onSelected: (value) async {
                if (value == 'members') {
                  await _showGroupMembers(controller, group);
                }
                if (value == 'rename') {
                  await _showRenameGroup(controller, group);
                }
                if (value == 'leave') {
                  await _confirmLeaveGroup(controller, group);
                }
              },
              itemBuilder: (_) => [
                const PopupMenuItem(
                  value: 'members',
                  child: ListTile(
                    leading: Icon(Icons.people_outline),
                    title: Text('群成员'),
                  ),
                ),
                if (group.ownerDeviceId == controller.identity!.deviceId)
                  const PopupMenuItem(
                    value: 'rename',
                    child: ListTile(
                      leading: Icon(Icons.edit_outlined),
                      title: Text('修改群名'),
                    ),
                  ),
                PopupMenuItem(
                  value: 'leave',
                  child: ListTile(
                    leading: Icon(
                      group.ownerDeviceId == controller.identity!.deviceId
                          ? Icons.delete_outline
                          : Icons.logout,
                    ),
                    title: Text(
                      group.ownerDeviceId == controller.identity!.deviceId
                          ? '解散群聊'
                          : '退出群聊',
                    ),
                  ),
                ),
              ],
            ),
          ],
        );
      }
    }
    return _WelcomePane(controller: controller);
  }

  Future<void> _send(AppController controller) async {
    final text = _composer.text;
    if (text.trim().isEmpty) return;
    _composer.clear();
    await controller.sendMessage(text);
  }

  /// 把“@昵称 ”插到输入框光标处。
  void _insertMention(String name) {
    final value = _composer.value;
    final selection = value.selection.isValid
        ? value.selection
        : TextSelection.collapsed(offset: value.text.length);
    final mention = '@$name ';
    final updated = value.text.replaceRange(
      selection.start,
      selection.end,
      mention,
    );
    _composer.value = value.copyWith(
      text: updated,
      selection: TextSelection.collapsed(
        offset: selection.start + mention.length,
      ),
      composing: TextRange.empty,
    );
  }

  Future<void> _pickMentionMember(AppController controller) async {
    final groupId = controller.selectedGroupId;
    if (groupId == null) return;
    final members = await controller.groupMembers(groupId);
    final candidates = members
        .where((member) => member.deviceId != controller.identity!.deviceId)
        .toList();
    if (!mounted || candidates.isEmpty) return;
    final selected = await showDialog<GroupMember>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('选择要 @ 的成员'),
        children: [
          for (final member in candidates)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(dialogContext, member),
              child: ListTile(
                leading: CircleAvatar(
                  child: Text(_avatarText(member.displayName)),
                ),
                title: Text(member.displayName),
              ),
            ),
        ],
      ),
    );
    if (selected != null) _insertMention(selected.displayName);
  }

  Future<void> _showCreateGroup(AppController controller) async {
    final name = TextEditingController();
    final available = controller.peers
        .where((peer) => peer.online && peer.trusted)
        .toList();
    final selected = <String>{};
    final create = await showDialog<bool>(
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
                TextField(
                  controller: name,
                  autofocus: true,
                  maxLength: 40,
                  decoration: const InputDecoration(labelText: '群名称'),
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
                            title: Text(peer.displayName),
                            subtitle: Text(peer.ip),
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
    if (create == true && name.text.trim().isNotEmpty) {
      final group = await controller.createGroup(
        name.text,
        available.where((peer) => selected.contains(peer.deviceId)).toList(),
      );
      await controller.selectGroup(group.groupId);
    }
    name.dispose();
  }

  Future<void> _showInviteMembers(
    AppController controller,
    ChatGroup group,
  ) async {
    final available = controller.peers
        .where((peer) => peer.online && peer.trusted)
        .toList();
    final peer = await showDialog<DiscoveredPeer>(
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
                      title: Text(value.displayName),
                      subtitle: Text(value.ip),
                    ),
                  ),
              ],
      ),
    );
    if (peer != null) await controller.inviteToGroup(group, peer);
  }

  Future<void> _showGroupMembers(
    AppController controller,
    ChatGroup group,
  ) async {
    final members = await controller.groupMembers(group.groupId);
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('${group.name} · 群成员'),
        content: SizedBox(
          width: 420,
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final member in members)
                ListTile(
                  leading: CircleAvatar(
                    child: Text(_avatarText(member.displayName)),
                  ),
                  title: Text(member.displayName),
                  subtitle: Text(
                    member.role == GroupRole.owner ? 'Owner' : 'Member',
                  ),
                  trailing:
                      group.ownerDeviceId == controller.identity!.deviceId &&
                          member.deviceId != controller.identity!.deviceId
                      ? IconButton(
                          tooltip: '移除成员',
                          onPressed: () async {
                            await controller.removeGroupMember(group, member);
                            if (dialogContext.mounted) {
                              Navigator.pop(dialogContext);
                            }
                          },
                          icon: const Icon(Icons.person_remove_outlined),
                        )
                      : null,
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
    );
  }

  Future<void> _showRenameGroup(
    AppController controller,
    ChatGroup group,
  ) async {
    final name = TextEditingController(text: group.name);
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('修改群名'),
        content: TextField(
          controller: name,
          autofocus: true,
          maxLength: 40,
          decoration: const InputDecoration(labelText: '群名称'),
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
    if (accepted == true) await controller.renameGroup(group, name.text);
    name.dispose();
  }

  Future<void> _confirmLeaveGroup(
    AppController controller,
    ChatGroup group,
  ) async {
    final isOwner = group.ownerDeviceId == controller.identity!.deviceId;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(isOwner ? '解散群聊？' : '退出群聊？'),
        content: Text(
          isOwner ? '群聊将从在线成员的设备上移除，此操作无法撤销。' : '退出后需要 Owner 再次邀请才能加入。',
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

class _IdentityHeader extends StatelessWidget {
  const _IdentityHeader({required this.identity, this.unreadCount = 0});
  final LocalIdentity identity;
  final int unreadCount;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(18, 18, 14, 14),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.primaryContainer
          .withValues(alpha: .45),
    ),
    child: Row(
      children: [
        CircleAvatar(
          radius: 23,
          backgroundColor: Theme.of(context).colorScheme.primary,
          foregroundColor: Theme.of(context).colorScheme.onPrimary,
          child: Text(_avatarText(identity.displayName)),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                identity.displayName,
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
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
          message: unreadCount > 0 ? '有 $unreadCount 条未读消息' : '局域网发现已开启',
          child: unreadCount > 0
              ? _UnreadBadge(count: unreadCount)
              : Icon(Icons.lan, color: Theme.of(context).colorScheme.primary),
        ),
      ],
    ),
  );
}

/// 未读消息徽标，样式参考聊天软件的红色圆角计数。
class _UnreadBadge extends StatelessWidget {
  const _UnreadBadge({required this.count});
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
        fontSize: 12,
        fontWeight: FontWeight.w700,
        color: Theme.of(context).colorScheme.onError,
      ),
    ),
  );
}

/// 会话条目右侧的最近消息时间与未读徽标。
class _ConversationMeta extends StatelessWidget {
  const _ConversationMeta({required this.time, required this.unreadCount});
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
        _UnreadBadge(count: unreadCount),
      ],
    ],
  );
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.title, this.trailing});
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

class _EmptyHint extends StatelessWidget {
  const _EmptyHint({required this.icon, required this.text});
  final IconData icon;
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
    child: Row(
      children: [
        Icon(icon, size: 18, color: Colors.grey),
        const SizedBox(width: 8),
        Text(text, style: const TextStyle(color: Colors.grey)),
      ],
    ),
  );
}

class _UnifiedPeerEntry {
  const _UnifiedPeerEntry({
    required this.deviceId,
    required this.displayName,
    required this.peer,
    required this.chat,
    required this.trustedPeer,
  });

  final String deviceId;
  final String displayName;
  final DiscoveredPeer? peer;
  final ChatSummary? chat;
  final TrustedPeer? trustedPeer;
}

class _UnifiedPeerTile extends StatelessWidget {
  const _UnifiedPeerTile({
    required this.entry,
    required this.selected,
    required this.onTap,
  });
  final _UnifiedPeerEntry entry;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final peer = entry.peer;
    final chat = entry.chat;
    final blocked = entry.trustedPeer?.blocked == true;
    final online = peer?.online == true;
    final pending =
        chat?.state == ChatSessionState.pendingIncoming ||
        chat?.state == ChatSessionState.pendingOutgoing;
    return ListTile(
      selected: selected,
      enabled: !blocked && (online || chat != null),
      leading: Stack(
        children: [
          CircleAvatar(child: Text(_avatarText(entry.displayName))),
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
        entry.chat?.lastMessagePreview ?? _unifiedPeerSubtitle(entry),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: pending
          ? const SizedBox.square(
              dimension: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : (chat?.unreadCount ?? 0) > 0 || chat?.lastMessageAt != null
          ? _ConversationMeta(
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
    );
  }
}

class _ChatRequestCard extends StatelessWidget {
  const _ChatRequestCard({required this.controller, required this.request});
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
                ? '${request.displayName} 请求与你聊天'
                : '等待 ${request.displayName} 确认',
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 5),
          Text('设备：${request.peerDeviceId.substring(0, 8)}…'),
          Text('网络：${request.ip}'),
          const SizedBox(height: 8),
          Text(
            request.verificationCode,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 25,
              fontWeight: FontWeight.w800,
              letterSpacing: 3,
            ),
          ),
          const Text(
            '请与对方口头核对验证码',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12),
          ),
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
                    child: const Text('确认并接受'),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    ),
  );
}

class _GroupInviteCard extends StatelessWidget {
  const _GroupInviteCard({required this.controller, required this.invitation});
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
            '${invitation.ownerDisplayName} 邀请你加入',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          Text(
            invitation.groupName,
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

class _ConversationPane extends StatelessWidget {
  const _ConversationPane({
    required this.title,
    required this.subtitle,
    required this.messages,
    required this.localDeviceId,
    required this.peerName,
    required this.composer,
    required this.enabled,
    required this.onSend,
    required this.onAttach,
    required this.onPasteAttachments,
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
    this.onMention,
    this.onPickMentionMember,
  });
  final String title;
  final String subtitle;
  final List<ChatMessage> messages;
  final String localDeviceId;
  final String Function(String) peerName;
  final TextEditingController composer;
  final bool enabled;
  final VoidCallback onSend;
  final Future<void> Function() onAttach;
  final Future<bool> Function() onPasteAttachments;
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

  /// 右键“@TA”时把昵称插进输入框。
  final void Function(String name)? onMention;

  /// 群聊里点击按钮选择要 @ 的成员。
  final Future<void> Function()? onPickMentionMember;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Container(
        height: 72,
        padding: const EdgeInsets.symmetric(horizontal: 22),
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
                    title,
                    style: const TextStyle(
                      fontSize: 19,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ),
            ...actions,
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
            : ListView.builder(
                reverse: true,
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 18,
                ),
                itemCount: messages.length,
                itemBuilder: (context, reverseIndex) {
                  final message = messages[messages.length - 1 - reverseIndex];
                  final mine = message.senderDeviceId == localDeviceId;
                  final mentioned = message.mentionsDevice(localDeviceId);
                  return _MessageBubble(
                    message: message,
                    mine: mine,
                    senderName: peerName(message.senderDeviceId),
                    mentioned: mentioned,
                    replySenderName: message.replyToSenderId == null
                        ? null
                        : peerName(message.replyToSenderId!),
                    missingHint: missingHintFor(message),
                    onOpen: onOpenAttachment,
                    onOpenFolder: onOpenAttachmentFolder,
                    onAccept: onAcceptFile,
                    onReject: onRejectFile,
                    onRetry: onRetryFile,
                    onRelocate: onRelocateFile,
                    onReply: onReplyMessage == null
                        ? null
                        : () => onReplyMessage!(message),
                    onCopy: onCopyMessage == null
                        ? null
                        : () => onCopyMessage!(message),
                    onMention: message.senderDeviceId == localDeviceId
                        ? null
                        : onMention == null
                        ? null
                        : () => onMention!(peerName(message.senderDeviceId)),
                  );
                },
              ),
      ),
      Container(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 18),
        color: Theme.of(context).colorScheme.surface,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (replyingTo != null)
              _ReplyBanner(
                senderName: replyingTo!.senderDeviceId == localDeviceId
                    ? '我'
                    : peerName(replyingTo!.senderDeviceId),
                preview: AppController.replyPreview(replyingTo!),
                onCancel: onCancelReply,
              ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                IconButton(
                  tooltip: '发送图片或文件',
                  onPressed: enabled ? onAttach : null,
                  icon: const Icon(Icons.attach_file),
                ),
                if (onPickMentionMember != null)
                  IconButton(
                    tooltip: '@ 群成员',
                    onPressed: enabled ? onPickMentionMember : null,
                    icon: const Icon(Icons.alternate_email),
                  ),
                const SizedBox(width: 6),
                Expanded(
                  child: MessageComposer(
                    controller: composer,
                    enabled: enabled,
                    onSend: onSend,
                    onPasteAttachments: onPasteAttachments,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    ],
  );
}

class _ReplyBanner extends StatelessWidget {
  const _ReplyBanner({
    required this.senderName,
    required this.preview,
    this.onCancel,
  });

  final String senderName;
  final String preview;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(bottom: 8),
    padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(10),
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
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '引用 $senderName',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
              Text(
                preview,
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

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
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
    this.mentioned = false,
    this.replySenderName,
    this.onReply,
    this.onCopy,
    this.onMention,
  });
  final ChatMessage message;
  final bool mine;
  final String senderName;
  final String missingHint;
  final Future<void> Function(ChatMessage) onOpen;
  final Future<void> Function(ChatMessage) onOpenFolder;
  final Future<void> Function(ChatMessage) onAccept;
  final Future<void> Function(ChatMessage) onReject;
  final Future<void> Function(ChatMessage) onRetry;
  final Future<void> Function(ChatMessage) onRelocate;

  /// 本条消息是否 @ 了本机用户。
  final bool mentioned;

  /// 引用块显示的发送者昵称，消息没有引用时为 null。
  final String? replySenderName;
  final VoidCallback? onReply;
  final Future<void> Function()? onCopy;
  final VoidCallback? onMention;

  @override
  Widget build(BuildContext context) => Align(
    alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
    child: GestureDetector(
      onSecondaryTapDown: (details) =>
          _showContextMenu(context, details.globalPosition),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 560),
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: mine
              ? Theme.of(context).colorScheme.primaryContainer
              : Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: mentioned
                ? Theme.of(context).colorScheme.error
                : mine
                ? Colors.transparent
                : Theme.of(context).dividerColor,
            width: mentioned ? 1.6 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: mine
              ? CrossAxisAlignment.end
              : CrossAxisAlignment.start,
          children: [
            if (!mine)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    senderName,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                  if (mentioned) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 1,
                      ),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.errorContainer,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        '@我',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: Theme.of(context).colorScheme.onErrorContainer,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            if (message.isReply) _buildQuoted(context),
            if (message.kind == MessageKind.text)
              SelectionArea(
                child: Text(
                  message.content,
                  textAlign: mine ? TextAlign.right : TextAlign.left,
                ),
              )
            else
              _buildAttachment(context),
            const SizedBox(height: 4),
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
          ],
        ),
      ),
    ),
  );

  Widget _buildAttachment(BuildContext context) {
    final path = message.filePath;
    final hasLocalFile = path != null && File(path).existsSync();
    final canDecide =
        !mine && message.status == MessageStatus.awaitingAcceptance;
    final canRetry = !mine && message.status == MessageStatus.failed;
    return ConstrainedBox(
      constraints: BoxConstraints(
        minWidth: message.kind == MessageKind.image && hasLocalFile ? 0 : 250,
        maxWidth: 360,
      ),
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
              textDirection: mine ? TextDirection.rtl : TextDirection.ltr,
              children: [
                Icon(
                  message.kind == MessageKind.image
                      ? Icons.image_outlined
                      : Icons.insert_drive_file_outlined,
                  size: 34,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: mine
                        ? CrossAxisAlignment.end
                        : CrossAxisAlignment.start,
                    children: [
                      SelectionArea(
                        child: Text(
                          message.fileName ?? message.content,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          textAlign: mine ? TextAlign.right : TextAlign.left,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
                      Text(
                        _formatFileSize(message.fileSize ?? 0),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          if (canDecide) ...[
            const SizedBox(height: 10),
            Text(
              '这是一个大文件，接受后才会开始传输。',
              style: Theme.of(context).textTheme.bodySmall,
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

  /// 引用块：展示被引用消息的发送者与摘要。
  Widget _buildQuoted(BuildContext context) => Container(
    margin: const EdgeInsets.only(bottom: 6),
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainerHighest
          .withValues(alpha: .7),
      borderRadius: BorderRadius.circular(8),
      border: Border(
        left: BorderSide(
          color: Theme.of(context).colorScheme.primary,
          width: 3,
        ),
      ),
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          replySenderName ?? '被引用的消息',
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
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
  );

  /// 消息右键菜单：复制、引用、@ 以及附件打开操作。
  Future<void> _showContextMenu(BuildContext context, Offset position) async {
    final path = message.filePath;
    final hasLocalFile = path != null && File(path).existsSync();
    final isImage = message.kind == MessageKind.image;
    final isFile = message.kind == MessageKind.file;
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final localPosition = overlay.globalToLocal(position);
    final selection = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(localPosition.dx, localPosition.dy, 0, 0),
        Offset.zero & overlay.size,
      ),
      items: [
        PopupMenuItem(
          value: 'copy',
          enabled: onCopy != null,
          child: ListTile(
            leading: const Icon(Icons.copy),
            title: Text(message.kind == MessageKind.text ? '复制' : '复制文件路径'),
          ),
        ),
        PopupMenuItem(
          value: 'reply',
          enabled: onReply != null,
          child: const ListTile(
            leading: Icon(Icons.reply),
            title: Text('引用回复'),
          ),
        ),
        if (onMention != null)
          PopupMenuItem(
            value: 'mention',
            child: ListTile(
              leading: const Icon(Icons.alternate_email),
              title: Text('@$senderName'),
            ),
          ),
        if (isImage && hasLocalFile)
          const PopupMenuItem(
            value: 'open',
            child: ListTile(
              leading: Icon(Icons.open_in_new),
              title: Text('打开图片'),
            ),
          ),
        if (isFile && hasLocalFile)
          const PopupMenuItem(
            value: 'open',
            child: ListTile(
              leading: Icon(Icons.open_in_new),
              title: Text('打开文件'),
            ),
          ),
        if (hasLocalFile)
          const PopupMenuItem(
            value: 'folder',
            child: ListTile(
              leading: Icon(Icons.folder_open),
              title: Text('打开所在文件夹'),
            ),
          ),
      ],
    );
    switch (selection) {
      case 'copy':
        await onCopy?.call();
      case 'reply':
        onReply?.call();
      case 'mention':
        onMention?.call();
      case 'open':
        await onOpen(message);
      case 'folder':
        await onOpenFolder(message);
    }
  }
}

class _TopRightSnackBar extends StatelessWidget {
  const _TopRightSnackBar({
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

class _WelcomePane extends StatelessWidget {
  const _WelcomePane({required this.controller});
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
              style: Theme.of(context).textTheme.headlineMedium
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 12),
            const Text(
              'NekoChat 正在局域网中寻找其他设备。选择左侧在线设备，发送聊天请求并与对方口头核对 6 位验证码。',
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

List<_UnifiedPeerEntry> _unifiedPeerEntries(AppController controller) {
  final peersById = {for (final peer in controller.peers) peer.deviceId: peer};
  final chatsByPeer = {
    for (final chat in controller.chats) chat.peerDeviceId: chat,
  };
  final deviceIds = <String>{
    ...peersById.values
        .where((peer) => peer.online)
        .map((peer) => peer.deviceId),
    ...chatsByPeer.keys,
  };
  final entries = [
    for (final deviceId in deviceIds)
      _UnifiedPeerEntry(
        deviceId: deviceId,
        displayName:
            peersById[deviceId]?.displayName ??
            chatsByPeer[deviceId]?.displayName ??
            controller.trustedPeers[deviceId]?.displayName ??
            '未知设备',
        peer: peersById[deviceId],
        chat: chatsByPeer[deviceId],
        trustedPeer: controller.trustedPeers[deviceId],
      ),
  ];
  entries.sort((a, b) {
    final aOnline = a.peer?.online == true;
    final bOnline = b.peer?.online == true;
    if (aOnline != bOnline) return aOnline ? -1 : 1;
    final aTime = a.chat?.lastMessageAt?.millisecondsSinceEpoch ?? 0;
    final bTime = b.chat?.lastMessageAt?.millisecondsSinceEpoch ?? 0;
    if (aTime != bTime) return bTime.compareTo(aTime);
    return a.displayName.compareTo(b.displayName);
  });
  return entries;
}

String _unifiedPeerSubtitle(_UnifiedPeerEntry entry) {
  if (entry.trustedPeer?.blocked == true) return '已拉黑';
  final chat = entry.chat;
  if (chat?.state == ChatSessionState.pendingIncoming) return '等待你确认验证码';
  if (chat?.state == ChatSessionState.pendingOutgoing) {
    return entry.trustedPeer == null ? '等待对方确认验证码' : '正在恢复已验证会话…';
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
};

String _statusLabel(MessageStatus status, {required bool mine}) =>
    switch (status) {
      MessageStatus.pending => '等待接收',
      MessageStatus.awaitingAcceptance => '等待对方接受',
      MessageStatus.sent => mine ? '已接受' : '已接收',
      MessageStatus.rejected => '已拒绝',
      MessageStatus.failed => '失败',
    };

String _formatFileSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}
