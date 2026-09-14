import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../core/config/network_config.dart';
import '../../core/models/models.dart';
import '../settings/settings_page.dart';
import 'message_composer.dart';
import 'mention_autocomplete.dart';

class MainShell extends StatefulWidget {
  const MainShell({super.key, required this.controller});
  final AppController controller;

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  final _search = TextEditingController();
  final Map<String, TextEditingController> _composers = {};
  final Map<String, List<PendingAttachment>> _pendingAttachments = {};

  TextEditingController _composerFor(String conversationId) =>
      _composers.putIfAbsent(conversationId, TextEditingController.new);

  List<PendingAttachment> _pendingFor(String conversationId) =>
      _pendingAttachments.putIfAbsent(conversationId, () => []);

  @override
  void dispose() {
    _search.dispose();
    for (final composer in _composers.values) {
      composer.dispose();
    }
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
              entry.originalDisplayName.toLowerCase().contains(query) ||
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
                  query.isEmpty ||
                  group.name.toLowerCase().contains(query) ||
                  controller
                      .groupDisplayName(group.groupId, group.name)
                      .toLowerCase()
                      .contains(query),
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
    return Material(
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
                        controller.groupDisplayName(group.groupId, group.name),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        _groupListSubtitle(controller, group),
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
          ListTile(
            leading: const Icon(Icons.settings_outlined),
            title: const Text('设置'),
            subtitle: const Text('文件接收、通知与存储'),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => SettingsPage(controller: controller),
              ),
            ),
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
        final conversationId = chat.chatId;
        final displayName = controller.peerDisplayName(
          chat.peerDeviceId,
          chat.displayName,
        );
        return _ConversationPane(
          key: ValueKey(chat.chatId),
          conversationId: conversationId,
          title: displayName,
          subtitle: [
            if (displayName != chat.displayName) '原名：${chat.displayName}',
            online ? '在线' : '离线 · 消息不会离线排队',
          ].join(' · '),
          messages: controller.messages,
          localDeviceId: controller.identity!.deviceId,
          peerName: (deviceId) =>
              deviceId == chat.peerDeviceId ? displayName : '我',
          composer: _composerFor(conversationId),
          pendingAttachments: _pendingFor(conversationId),
          enabled: online && chat.state == ChatSessionState.active,
          onSend: (text, attachments) => controller.sendMessageWithAttachments(
            conversationId: conversationId,
            content: text,
            attachments: attachments,
          ),
          onPickAttachments: controller.pickAttachments,
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
          actions: [
            PopupMenuButton<String>(
              tooltip: '会话操作',
              onSelected: (value) async {
                if (value == 'remark') {
                  await _showPeerRemark(
                    controller,
                    chat.peerDeviceId,
                    chat.displayName,
                  );
                }
                if (value == 'close') await controller.closeChat(chat);
                if (value == 'block') {
                  await controller.setBlocked(chat.peerDeviceId, true);
                }
              },
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: 'remark',
                  child: ListTile(
                    leading: const Icon(Icons.drive_file_rename_outline),
                    title: Text(
                      controller.peerRemarks.containsKey(chat.peerDeviceId)
                          ? '修改人员备注'
                          : '添加人员备注',
                    ),
                  ),
                ),
                const PopupMenuItem(
                  value: 'close',
                  child: ListTile(
                    leading: Icon(Icons.close),
                    title: Text('关闭对话'),
                  ),
                ),
                const PopupMenuItem(
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
        final conversationId = 'group:${group.groupId}';
        final composer = _composerFor(conversationId);
        final displayName = controller.groupDisplayName(
          group.groupId,
          group.name,
        );
        return _ConversationPane(
          key: ValueKey(conversationId),
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
                controller.trustedPeers[deviceId]?.displayName ??
                controller.peers
                    .where((peer) => peer.deviceId == deviceId)
                    .firstOrNull
                    ?.displayName ??
                '群成员';
            return controller.peerDisplayName(deviceId, originalName);
          },
          composer: composer,
          pendingAttachments: _pendingFor(conversationId),
          enabled: true,
          onSend: (text, attachments) => controller.sendMessageWithAttachments(
            conversationId: conversationId,
            content: text,
            attachments: attachments,
          ),
          onPickAttachments: controller.pickAttachments,
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
            if (group.ownerDeviceId == controller.identity!.deviceId)
              IconButton(
                tooltip: '邀请在线成员',
                onPressed: () => _showInviteMembers(controller, group),
                icon: const Icon(Icons.person_add_alt_1),
              ),
            PopupMenuButton<String>(
              tooltip: '群聊操作',
              onSelected: (value) async {
                if (value == 'remark') {
                  await _showGroupRemark(controller, group);
                }
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
                PopupMenuItem(
                  value: 'remark',
                  child: ListTile(
                    leading: const Icon(Icons.drive_file_rename_outline),
                    title: Text(
                      controller.groupRemarks.containsKey(group.groupId)
                          ? '修改群聊备注'
                          : '添加群聊备注',
                    ),
                  ),
                ),
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

  /// 把“@昵称 ”插到输入框光标处。
  void _insertMention(TextEditingController composer, String name) {
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

  Future<void> _showGroupMembers(
    AppController controller,
    ChatGroup group,
  ) async {
    final members = await controller.groupMembers(group.groupId);
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(
            '${controller.groupDisplayName(group.groupId, group.name)} · 群成员',
          ),
          content: SizedBox(
            width: 420,
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final member in members)
                  ListTile(
                    leading: CircleAvatar(
                      child: Text(
                        _avatarText(
                          controller.peerDisplayName(
                            member.deviceId,
                            member.displayName,
                          ),
                        ),
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
                        member.role == GroupRole.owner ? 'Owner' : 'Member',
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
                              if (group.ownerDeviceId ==
                                  controller.identity!.deviceId)
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

  Future<void> _showPeerRemark(
    AppController controller,
    String deviceId,
    String originalName,
  ) => _showRemarkEditor(
    title: '人员备注',
    originalName: originalName,
    currentRemark: controller.peerRemarks[deviceId],
    onSave: (value) => controller.setPeerRemark(deviceId, value),
  );

  Future<void> _showGroupRemark(AppController controller, ChatGroup group) =>
      _showRemarkEditor(
        title: '群聊备注',
        originalName: group.name,
        currentRemark: controller.groupRemarks[group.groupId],
        onSave: (value) => controller.setGroupRemark(group.groupId, value),
      );

  Future<void> _showRemarkEditor({
    required String title,
    required String originalName,
    required String? currentRemark,
    required Future<void> Function(String value) onSave,
  }) async {
    final remark = TextEditingController(text: currentRemark);
    final accepted = await showDialog<bool>(
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
              TextField(
                controller: remark,
                autofocus: true,
                maxLength: NetworkConfig.maxRemarkLength,
                decoration: const InputDecoration(
                  labelText: '备注',
                  hintText: '留空即清除备注',
                ),
                onSubmitted: (_) => Navigator.pop(dialogContext, true),
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
    if (accepted == true) await onSave(remark.text);
    remark.dispose();
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
          message: '局域网发现已开启',
          child: Icon(Icons.lan, color: Theme.of(context).colorScheme.primary),
        ),
        if (unreadCount > 0) ...[
          const SizedBox(width: 10),
          Tooltip(
            message: '有 $unreadCount 条未读消息',
            child: _UnreadBadge(count: unreadCount),
          ),
        ],
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
    required this.originalDisplayName,
    required this.peer,
    required this.chat,
    required this.trustedPeer,
  });

  final String deviceId;
  final String displayName;
  final String originalDisplayName;
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
                ? '${controller.peerDisplayName(request.peerDeviceId, request.displayName)} 请求与你聊天'
                : '等待 ${controller.peerDisplayName(request.peerDeviceId, request.displayName)} 确认',
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
            '${controller.peerDisplayName(invitation.ownerDeviceId, invitation.ownerDisplayName)} '
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

  /// 发送输入框里的文字与待发送附件。
  final Future<void> Function(String text, List<PendingAttachment> attachments)
  onSend;

  /// 打开文件选择框 / 读取剪贴板，返回待暂存的附件。
  final Future<List<PendingAttachment>> Function() onPickAttachments;
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

  /// 图片气泡的自绘右键菜单。
  OverlayEntry? _fallbackMenu;

  @override
  void dispose() {
    _highlightTimer?.cancel();
    _removeFallbackMenu();
    _composerFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _removeFallbackMenu() {
    _fallbackMenu?.remove();
    _fallbackMenu = null;
  }

  /// 纯图片气泡里没有可选中的文字，框架的选择工具栏不会弹出，
  /// 这里把它渲染成同一个组件（位置、外观都与文字气泡一致）。
  void _showFallbackMenu(
    BuildContext context,
    Offset position,
    List<ContextMenuButtonItem> Function(VoidCallback dismiss) buildItems,
  ) {
    _removeFallbackMenu();
    final overlay = Overlay.of(context);
    final entry = OverlayEntry(
      builder: (context) {
        void dismiss() => _removeFallbackMenu();
        return Stack(
          children: [
            // 点击空白或其他地方关闭菜单。
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: dismiss,
                onSecondaryTapDown: (_) => dismiss(),
              ),
            ),
            Positioned.fill(
              child: AdaptiveTextSelectionToolbar.buttonItems(
                anchors: TextSelectionToolbarAnchors(primaryAnchor: position),
                buttonItems: buildItems(dismiss),
              ),
            ),
          ],
        );
      },
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
    return Column(
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
                      widget.title,
                      style: const TextStyle(
                        fontSize: 19,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      widget.subtitle,
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
              : ListView.builder(
                  key: PageStorageKey(widget.conversationId),
                  controller: _scroll,
                  reverse: true,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 18,
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
                      return _RecallNotice(
                        key: _keyFor(message.messageId),
                        text:
                            widget.recallNoticeFor?.call(message) ?? '一条消息已撤回',
                        highlighted: _highlightedMessageId == message.messageId,
                      );
                    }
                    return _MessageBubble(
                      key: _keyFor(message.messageId),
                      message: message,
                      mine: mine,
                      senderName: widget.peerName(message.senderDeviceId),
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
                      onShowFallbackMenu: _showFallbackMenu,
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
              if (widget.replyingTo != null)
                _ReplyBanner(
                  message: widget.replyingTo!,
                  senderName:
                      widget.replyingTo!.senderDeviceId == widget.localDeviceId
                      ? '我'
                      : widget.peerName(widget.replyingTo!.senderDeviceId),
                  onCancel: widget.onCancelReply,
                ),
              if (widget.pendingAttachments.isNotEmpty)
                _PendingAttachments(
                  attachments: widget.pendingAttachments,
                  onRemove: _removeAttachment,
                ),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  IconButton(
                    tooltip: '添加图片或文件',
                    onPressed: widget.enabled ? _pickAttachments : null,
                    icon: const Icon(Icons.attach_file),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: widget.loadMentionCandidates == null
                        ? MessageComposer(
                            controller: widget.composer,
                            focusNode: _composerFocus,
                            enabled: widget.enabled,
                            onSend: () => unawaited(_handleSend()),
                            onPasteAttachments: _pasteAttachments,
                          )
                        : MentionAutocomplete(
                            controller: widget.composer,
                            focusNode: _composerFocus,
                            enabled: widget.enabled,
                            onSend: () => unawaited(_handleSend()),
                            onPasteAttachments: _pasteAttachments,
                            loadCandidates: widget.loadMentionCandidates!,
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
}

/// 输入框上方的待发送附件区域：图片显示缩略图，其他文件显示文件名。
class _PendingAttachments extends StatelessWidget {
  const _PendingAttachments({
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
            itemBuilder: (context, index) => _PendingAttachmentChip(
              attachment: attachments[index],
              onRemove: () => onRemove(attachments[index]),
            ),
          ),
        ),
      ],
    ),
  );
}

class _PendingAttachmentChip extends StatelessWidget {
  const _PendingAttachmentChip({
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
          '${attachment.fileName}\n${_formatFileSize(attachment.fileSize)}',
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

class _ReplyBanner extends StatelessWidget {
  const _ReplyBanner({
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
                    fontWeight: FontWeight.w700,
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

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
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
    this.mentioned = false,
    this.highlighted = false,
    this.replySenderName,
    this.onReply,
    this.onCopy,
    this.onMention,
    this.onRecall,
    this.resolveMessage,
    this.onJumpToReply,
    this.onShowFallbackMenu,
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

  /// 从引用跳转过来后短暂高亮，方便找到目标。
  final bool highlighted;

  /// 引用块显示的发送者昵称，消息没有引用时为 null。
  final String? replySenderName;
  final VoidCallback? onReply;
  final Future<void> Function()? onCopy;
  final VoidCallback? onMention;
  final Future<void> Function()? onRecall;

  /// 按消息 id 找到本地的原消息，用于在引用块里展示图片缩略图。
  final ChatMessage? Function(String messageId)? resolveMessage;

  /// 点击引用块时跳到被引用的原消息。
  final void Function(String messageId)? onJumpToReply;

  /// 纯图片气泡没有可选中的文字，框架的选择工具栏不会弹出，
  /// 把菜单项交给面板用叠加层自绘。
  final void Function(
    BuildContext context,
    Offset position,
    List<ContextMenuButtonItem> Function(VoidCallback dismiss) buildItems,
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
  Widget build(BuildContext context) => AnimatedContainer(
    // 整行高亮：从引用跳转过来时给这一行铺底色，比只描气泡边框更容易定位。
    duration: const Duration(milliseconds: 220),
    width: double.infinity,
    margin: const EdgeInsets.only(bottom: 12),
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    decoration: BoxDecoration(
      color: highlighted
          ? Theme.of(context).colorScheme.primary.withValues(alpha: .12)
          : Colors.transparent,
      borderRadius: BorderRadius.circular(12),
    ),
    child: Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: _hasSelectableContent
          // 有可选文字时整块气泡放进选择区域，右键弹出「我们的菜单 + 全选」合并菜单。
          ? SelectionArea(
              contextMenuBuilder: _buildContextMenu,
              child: _buildBubble(context),
            )
          // 纯图片气泡没有可选文字，框架不会弹工具栏，改用自绘的同一套菜单。
          : GestureDetector(
              onSecondaryTapDown: (details) =>
                  _showOwnMenu(context, details.globalPosition),
              child: _buildBubble(context),
            ),
    ),
  );

  /// 气泡本体。
  Widget _buildBubble(BuildContext context) => Container(
    constraints: const BoxConstraints(maxWidth: 560),
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
          // 昵称、@ 标记属于元信息，不参与选择与全选。
          _unselectable(
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
          ),
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
                      Text(
                        message.fileName ?? message.content,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        textAlign: mine ? TextAlign.right : TextAlign.left,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      _unselectable(
                        Text(
                          _formatFileSize(message.fileSize ?? 0),
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
          constraints: const BoxConstraints(minWidth: 160),
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
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 图片气泡的右键入口：把菜单项交给面板渲染成与文字气泡一致的工具栏。
  void _showOwnMenu(BuildContext context, Offset position) {
    final handler = onShowFallbackMenu;
    if (handler == null) return;
    handler(context, position, _fallbackMenuItems);
  }

  /// 没有选中文本可用时的菜单项：复制整条消息内容（图片会复制文件路径）。
  List<ContextMenuButtonItem> _fallbackMenuItems(VoidCallback dismiss) => [
    ContextMenuButtonItem(
      type: ContextMenuButtonType.copy,
      label: '复制',
      onPressed: () {
        dismiss();
        unawaited(onCopy?.call() ?? Future<void>.value());
      },
    ),
    ..._messageActionItems(dismiss),
  ];

  /// 消息操作菜单项。文字气泡交给框架的选择工具栏渲染，图片气泡由面板自绘，
  /// 两处共用这一份定义，保证菜单内容和顺序一致。
  List<ContextMenuButtonItem> _messageActionItems(VoidCallback dismiss) => [
    ContextMenuButtonItem(
      label: '引用回复',
      onPressed: onReply == null
          ? null
          : () {
              dismiss();
              onReply!();
            },
    ),
    if (onMention != null)
      ContextMenuButtonItem(
        label: '@$senderName',
        onPressed: () {
          dismiss();
          onMention!();
        },
      ),
    if (onRecall != null)
      ContextMenuButtonItem(
        label: '撤回',
        onPressed: () {
          dismiss();
          unawaited(onRecall!());
        },
      ),
    if (_hasLocalAttachment)
      ContextMenuButtonItem(
        label: message.kind == MessageKind.image ? '打开图片' : '打开文件',
        onPressed: () {
          dismiss();
          unawaited(onOpen(message));
        },
      ),
    if (_hasLocalAttachment)
      ContextMenuButtonItem(
        label: '打开所在文件夹',
        onPressed: () {
          dismiss();
          unawaited(onOpenFolder(message));
        },
      ),
  ];

  bool get _hasLocalAttachment {
    final path = message.filePath;
    return path != null && File(path).existsSync();
  }

  /// 合并后的右键菜单：文字选择（复制/全选）+ 消息操作（引用/@/附件）。
  ///
  /// 由 [SelectionArea] 负责弹出与定位，因此只会出现一个菜单位置，
  /// 不再和原生的选择菜单各弹一个。
  Widget _buildContextMenu(BuildContext context, SelectableRegionState state) {
    // 复用框架准备好的复制/全选回调，它们已经处理了复制选中内容、收起工具栏等细节。
    final defaultItems = state.contextMenuButtonItems;
    ContextMenuButtonItem? defaultItem(ContextMenuButtonType type) =>
        defaultItems.where((item) => item.type == type).firstOrNull;
    final copyItem = defaultItem(ContextMenuButtonType.copy);
    final selectAllItem = defaultItem(ContextMenuButtonType.selectAll);
    return AdaptiveTextSelectionToolbar.buttonItems(
      anchors: state.contextMenuAnchors,
      buttonItems: [
        ContextMenuButtonItem(
          type: ContextMenuButtonType.copy,
          label: '复制',
          // 有选中文本时复制选中的片段，否则一键复制整条消息。
          onPressed: () {
            if (copyItem != null) {
              copyItem.onPressed?.call();
              return;
            }
            state.hideToolbar();
            unawaited(onCopy?.call() ?? Future<void>.value());
          },
        ),
        if (selectAllItem != null)
          ContextMenuButtonItem(
            type: ContextMenuButtonType.selectAll,
            label: '全选',
            onPressed: selectAllItem.onPressed,
          ),
        ..._messageActionItems(state.hideToolbar),
      ],
    );
  }
}

class _RecallNotice extends StatelessWidget {
  const _RecallNotice({
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
  String originalName(String deviceId) =>
      peersById[deviceId]?.displayName ??
      chatsByPeer[deviceId]?.displayName ??
      controller.trustedPeers[deviceId]?.displayName ??
      '未知设备';
  final entries = [
    for (final deviceId in deviceIds)
      _UnifiedPeerEntry(
        deviceId: deviceId,
        displayName: controller.peerDisplayName(
          deviceId,
          originalName(deviceId),
        ),
        originalDisplayName: originalName(deviceId),
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

String _peerListSubtitle(_UnifiedPeerEntry entry) {
  final status = entry.chat?.lastMessagePreview ?? _unifiedPeerSubtitle(entry);
  if (entry.displayName == entry.originalDisplayName) return status;
  return '${entry.originalDisplayName} · $status';
}

String _groupListSubtitle(AppController controller, ChatGroup group) {
  final status =
      group.lastMessagePreview ??
      (group.ownerDeviceId == controller.identity!.deviceId ? '我创建的群聊' : '已加入');
  if (!controller.groupRemarks.containsKey(group.groupId)) return status;
  return '${group.name} · $status';
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

String _formatFileSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}
