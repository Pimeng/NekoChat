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
        child: Row(
          children: [
            SizedBox(width: 340, child: _buildSidebar(controller)),
            const VerticalDivider(width: 1),
            Expanded(child: _buildContent(controller)),
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
    final groups = controller.groups
        .where(
          (group) => query.isEmpty || group.name.toLowerCase().contains(query),
        )
        .toList();
    return ColoredBox(
      color: Theme.of(context).colorScheme.surface,
      child: Column(
        children: [
          _IdentityHeader(identity: controller.identity!),
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
                        group.ownerDeviceId == controller.identity!.deviceId
                            ? '我创建的群聊'
                            : '已加入',
                      ),
                      onTap: () => controller.selectGroup(group.groupId),
                    ),
              ],
            ),
          ),
          const Divider(height: 1),
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
  const _IdentityHeader({required this.identity});
  final LocalIdentity identity;
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
      ],
    ),
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
        _unifiedPeerSubtitle(entry),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: pending
          ? const SizedBox.square(
              dimension: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
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
    required this.actions,
  });
  final String title;
  final String subtitle;
  final List<ChatMessage> messages;
  final String localDeviceId;
  final String Function(String) peerName;
  final TextEditingController composer;
  final bool enabled;
  final VoidCallback onSend;
  final List<Widget> actions;

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
                  return _MessageBubble(
                    message: message,
                    mine: mine,
                    senderName: peerName(message.senderDeviceId),
                  );
                },
              ),
      ),
      Container(
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 18),
        color: Theme.of(context).colorScheme.surface,
        child: MessageComposer(
          controller: composer,
          enabled: enabled,
          onSend: onSend,
        ),
      ),
    ],
  );
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    required this.message,
    required this.mine,
    required this.senderName,
  });
  final ChatMessage message;
  final bool mine;
  final String senderName;
  @override
  Widget build(BuildContext context) => Align(
    alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
    child: Container(
      constraints: const BoxConstraints(maxWidth: 560),
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: mine
            ? Theme.of(context).colorScheme.primaryContainer
            : Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: mine ? null : Border.all(color: Theme.of(context).dividerColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!mine)
            Text(
              senderName,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
          Text(message.content),
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
                  message.status == MessageStatus.failed
                      ? Icons.error_outline
                      : message.status == MessageStatus.pending
                      ? Icons.schedule
                      : Icons.check,
                  size: 13,
                  color: message.status == MessageStatus.failed
                      ? Theme.of(context).colorScheme.error
                      : null,
                ),
              ],
            ],
          ),
        ],
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
