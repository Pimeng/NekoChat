import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/app_controller.dart';
import '../../core/models/models.dart';
import 'main_shell.dart';

enum _DrawerPage { overview, members, invite, memberDetail }

/// 群聊右侧悬浮信息面板：所有群资料编辑、成员管理、邀请与退出均在面板内原地完成，不弹出对话框。
class GroupInfoDrawer extends StatefulWidget {
  const GroupInfoDrawer({
    super.key,
    required this.controller,
    required this.group,
    required this.onClose,
    this.onOpenInWindow,
    this.onMentionMember,
    this.onAfterLeaveOrDisband,
  });

  final AppController controller;
  final ChatGroup group;
  final VoidCallback onClose;
  final Future<void> Function()? onOpenInWindow;
  final void Function(String insertionName)? onMentionMember;
  final Future<void> Function()? onAfterLeaveOrDisband;

  @override
  State<GroupInfoDrawer> createState() => _GroupInfoDrawerState();
}

class _GroupInfoDrawerState extends State<GroupInfoDrawer> {
  final _memberSearch = TextEditingController();
  final _groupNameController = TextEditingController();
  final _groupNameFocus = FocusNode();
  final _groupRemarkController = TextEditingController();
  final _groupRemarkFocus = FocusNode();
  final _memberRemarkController = TextEditingController();
  final _memberRemarkFocus = FocusNode();

  List<GroupMember> _members = const [];
  bool _loadingMembers = true;
  _DrawerPage _page = _DrawerPage.overview;
  bool _removeMode = false;
  bool _editingGroupName = false;
  bool _editingGroupRemark = false;
  DateTime? _groupNameClosedByBlurAt;
  DateTime? _groupRemarkClosedByBlurAt;
  bool _confirmingLeave = false;
  String? _confirmingRemoveDeviceId;
  String? _selectedMemberDeviceId;
  String? _inlineError;

  @override
  void initState() {
    super.initState();
    _syncGroupInputs();
    _groupNameFocus.addListener(_onGroupNameFocusChange);
    _groupRemarkFocus.addListener(_onGroupRemarkFocusChange);
    _memberRemarkFocus.addListener(_onMemberRemarkFocusChange);
    _loadMembers();
  }

  @override
  void didUpdateWidget(covariant GroupInfoDrawer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.group.groupId != widget.group.groupId) {
      _page = _DrawerPage.overview;
      _removeMode = false;
      _editingGroupName = false;
      _editingGroupRemark = false;
      _confirmingLeave = false;
      _confirmingRemoveDeviceId = null;
      _selectedMemberDeviceId = null;
      _inlineError = null;
      _memberSearch.clear();
      _syncGroupInputs();
      _loadMembers();
    } else if (!_editingGroupName && !_editingGroupRemark) {
      _syncGroupInputs();
    }
  }

  @override
  void dispose() {
    _groupNameFocus.removeListener(_onGroupNameFocusChange);
    _groupRemarkFocus.removeListener(_onGroupRemarkFocusChange);
    _memberRemarkFocus.removeListener(_onMemberRemarkFocusChange);
    _memberSearch.dispose();
    _groupNameController.dispose();
    _groupNameFocus.dispose();
    _groupRemarkController.dispose();
    _groupRemarkFocus.dispose();
    _memberRemarkController.dispose();
    _memberRemarkFocus.dispose();
    super.dispose();
  }

  void _syncGroupInputs() {
    _groupNameController.text = widget.group.name;
    _groupRemarkController.text =
        widget.controller.groupRemarks[widget.group.groupId] ?? '';
  }

  void _onGroupNameFocusChange() {
    if (!_groupNameFocus.hasFocus && _editingGroupName) {
      _groupNameClosedByBlurAt = DateTime.now();
      _commitGroupName();
    }
  }

  void _onGroupRemarkFocusChange() {
    if (!_groupRemarkFocus.hasFocus && _editingGroupRemark) {
      _groupRemarkClosedByBlurAt = DateTime.now();
      _commitGroupRemark();
    }
  }

  void _onMemberRemarkFocusChange() {
    if (!_memberRemarkFocus.hasFocus && _selectedMemberDeviceId != null) {
      _commitMemberRemark();
    }
  }

  Future<void> _loadMembers() async {
    setState(() => _loadingMembers = true);
    List<GroupMember> loaded;
    try {
      loaded = await widget.controller.groupMembers(widget.group.groupId);
    } on Object {
      loaded = const [];
    }
    if (!mounted) return;
    setState(() {
      _members = _sortedMembers(loaded);
      _loadingMembers = false;
    });
  }

  List<GroupMember> _sortedMembers(List<GroupMember> source) {
    int roleRank(GroupRole role) => switch (role) {
      GroupRole.owner => 0,
      GroupRole.admin => 1,
      GroupRole.member => 2,
    };
    final onlineIds = {
      for (final peer in widget.controller.peers)
        if (peer.online) peer.deviceId,
      if (widget.controller.identity != null)
        widget.controller.identity!.deviceId,
    };
    return List<GroupMember>.from(source)..sort((a, b) {
      final roleDiff = roleRank(a.role).compareTo(roleRank(b.role));
      if (roleDiff != 0) return roleDiff;
      final onlineDiff = (onlineIds.contains(a.deviceId) ? 0 : 1).compareTo(
        onlineIds.contains(b.deviceId) ? 0 : 1,
      );
      if (onlineDiff != 0) return onlineDiff;
      return a.displayName.compareTo(b.displayName);
    });
  }

  bool _isOnline(String deviceId) {
    if (deviceId == widget.controller.identity?.deviceId) return true;
    return widget.controller.peers.any(
      (peer) => peer.deviceId == deviceId && peer.online,
    );
  }

  GroupRole? get _myRole {
    final myId = widget.controller.identity?.deviceId;
    if (myId == null) return null;
    return _members.where((m) => m.deviceId == myId).firstOrNull?.role ??
        (widget.group.ownerDeviceId == myId ? GroupRole.owner : null);
  }

  bool get _isOwner =>
      _myRole == GroupRole.owner ||
      widget.group.ownerDeviceId == widget.controller.identity?.deviceId;

  bool get _isAdmin => _myRole == GroupRole.admin;

  bool _canRemove(GroupMember member) {
    if (member.deviceId == widget.controller.identity?.deviceId) return false;
    if (member.role == GroupRole.owner) return false;
    return _isOwner || (_isAdmin && member.role == GroupRole.member);
  }

  Future<void> _commitGroupName() async {
    if (!_editingGroupName) return;
    final trimmed = _groupNameController.text.trim();
    if (trimmed.isEmpty) {
      setState(() {
        _groupNameController.text = widget.group.name;
        _editingGroupName = false;
        _inlineError = null;
      });
      return;
    }
    setState(() {
      _editingGroupName = false;
      _inlineError = null;
    });
    if (trimmed == widget.group.name) return;
    try {
      await widget.controller.renameGroup(widget.group, trimmed);
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _groupNameController.text = widget.group.name;
        _inlineError = '$error';
      });
    }
  }

  Future<void> _commitGroupRemark() async {
    if (!_editingGroupRemark) return;
    final trimmed = _groupRemarkController.text.trim();
    final current = widget.controller.groupRemarks[widget.group.groupId] ?? '';
    setState(() => _editingGroupRemark = false);
    if (trimmed == current) return;
    await widget.controller.setGroupRemark(widget.group.groupId, trimmed);
    if (mounted) setState(() {});
  }

  Future<void> _commitMemberRemark() async {
    final deviceId = _selectedMemberDeviceId;
    if (deviceId == null) return;
    final trimmed = _memberRemarkController.text.trim();
    final current = widget.controller.peerRemarks[deviceId] ?? '';
    if (trimmed == current) return;
    await widget.controller.setPeerRemark(deviceId, trimmed);
    if (mounted) setState(() {});
  }

  void _openMemberDetail(GroupMember member) {
    if (member.deviceId == widget.controller.identity?.deviceId) return;
    _memberRemarkController.text =
        widget.controller.peerRemarks[member.deviceId] ?? '';
    setState(() {
      _selectedMemberDeviceId = member.deviceId;
      _confirmingRemoveDeviceId = null;
      _page = _DrawerPage.memberDetail;
    });
  }

  Future<void> _removeMember(GroupMember member) async {
    await widget.controller.removeGroupMember(widget.group, member);
    if (!mounted) return;
    setState(() {
      _confirmingRemoveDeviceId = null;
      if (_selectedMemberDeviceId == member.deviceId) {
        _selectedMemberDeviceId = null;
        _page = _DrawerPage.members;
      }
    });
    await _loadMembers();
  }

  Future<void> _toggleAdminRole(GroupMember member) async {
    final nextRole = member.role == GroupRole.admin
        ? GroupRole.member
        : GroupRole.admin;
    await widget.controller.setGroupMemberRole(widget.group, member, nextRole);
    await _loadMembers();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return RepaintBoundary(
      child: Material(
        key: const ValueKey('group-info-drawer'),
      elevation: 12,
      shadowColor: Colors.black26,
      color: colorScheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: colorScheme.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: 332,
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 190),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          transitionBuilder: (child, animation) => FadeTransition(
            opacity: animation,
            child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0.04, 0),
                end: Offset.zero,
              ).animate(animation),
              child: child,
            ),
          ),
          child: switch (_page) {
            _DrawerPage.overview => _buildOverviewView(context),
            _DrawerPage.members => _buildMembersManagementView(context),
            _DrawerPage.invite => _buildInviteView(context),
            _DrawerPage.memberDetail => _buildMemberDetailView(context),
          },
        ),
      ),
      ),
    );
  }

  Widget _buildOverviewView(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final group = widget.group;
    final displayName = widget.controller.groupDisplayName(
      group.groupId,
      group.name,
    );
    final remark = widget.controller.groupRemarks[group.groupId];
    final canManageRemove = _isOwner || _isAdmin;
    final maxGridMembers = canManageRemove ? 13 : 14;
    final visibleMembers = _members.take(maxGridMembers).toList();

    return Column(
      key: const ValueKey('group-drawer-overview'),
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(14),
            children: [
              // 顶部群资料卡片
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: colorScheme.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    CircleAvatar(
                      radius: 22,
                      backgroundColor: colorScheme.primaryContainer,
                      foregroundColor: colorScheme.primary,
                      child: const Icon(Icons.groups, size: 22),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            displayName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            remark != null
                                ? '原群名：${group.name}'
                                : (_loadingMembers && _members.isEmpty
                                      ? '局域网群聊'
                                      : '${_members.length} 名成员'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(color: colorScheme.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ),
                    if (widget.onOpenInWindow != null) ...[
                      const SizedBox(width: 8),
                      OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 6,
                          ),
                        ),
                        onPressed: () async {
                          widget.onClose();
                          await widget.onOpenInWindow!();
                        },
                        icon: const Icon(Icons.open_in_new, size: 15),
                        label: const Text('独立窗口'),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 12),

              // 群聊成员网格卡片
              Container(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 14),
                decoration: BoxDecoration(
                  color: colorScheme.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        const Text(
                          '群聊成员',
                          style: TextStyle(fontWeight: FontWeight.w600),
                        ),
                        const Spacer(),
                        InkWell(
                          borderRadius: BorderRadius.circular(6),
                          onTap: () => setState(() {
                            _page = _DrawerPage.members;
                            _removeMode = false;
                            _confirmingRemoveDeviceId = null;
                          }),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 4,
                              vertical: 2,
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  '查看 ${_members.length} 名群成员',
                                  style: Theme.of(context).textTheme.bodySmall
                                      ?.copyWith(
                                        color: colorScheme.onSurfaceVariant,
                                      ),
                                ),
                                Icon(
                                  Icons.chevron_right,
                                  size: 16,
                                  color: colorScheme.onSurfaceVariant,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    if (_loadingMembers && _members.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 16),
                        child: Center(
                          child: SizedBox.square(
                            dimension: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        ),
                      )
                    else
                      Wrap(
                        spacing: 10,
                        runSpacing: 12,
                        children: [
                          for (final member in visibleMembers)
                            _MemberGridItem(
                              avatarPath: widget.controller.peerAvatarPath(
                                member.deviceId,
                              ),
                              name: widget.controller.peerDisplayName(
                                member.deviceId,
                                member.displayName,
                              ),
                              role: member.role,
                              online: _isOnline(member.deviceId),
                              onTap: () => _openMemberDetail(member),
                            ),
                          _GridActionCircle(
                            icon: Icons.add,
                            label: '邀请',
                            onTap: () =>
                                setState(() => _page = _DrawerPage.invite),
                          ),
                          if (canManageRemove)
                            _GridActionCircle(
                              icon: Icons.remove,
                              label: '移出',
                              onTap: () => setState(() {
                                _page = _DrawerPage.members;
                                _removeMode = true;
                                _confirmingRemoveDeviceId = null;
                              }),
                            ),
                        ],
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 14),

              // 群资料与备注（点击直接原地展开输入框，回车或失焦保存）
              Padding(
                padding: const EdgeInsets.only(left: 4, bottom: 6),
                child: Text(
                  '群资料与备注',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              Material(
                color: colorScheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(12),
                clipBehavior: Clip.antiAlias,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    ListTile(
                      dense: true,
                      leading: const Icon(Icons.edit_outlined, size: 20),
                      title: Text(_isOwner ? '修改群名' : '群名称'),
                      subtitle: Text(
                        group.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: _isOwner
                          ? Icon(
                              _editingGroupName
                                  ? Icons.expand_less
                                  : Icons.chevron_right,
                              size: 18,
                            )
                          : null,
                      onTap: _isOwner
                          ? () {
                              final closedAt = _groupNameClosedByBlurAt;
                              if (closedAt != null &&
                                  DateTime.now().difference(closedAt) <
                                      const Duration(milliseconds: 250)) {
                                _groupNameClosedByBlurAt = null;
                                return;
                              }
                              if (_editingGroupName) {
                                _commitGroupName();
                              } else {
                                _groupNameClosedByBlurAt = null;
                                _groupNameController.text = group.name;
                                setState(() {
                                  _editingGroupName = true;
                                  _inlineError = null;
                                });
                                WidgetsBinding.instance.addPostFrameCallback((
                                  _,
                                ) {
                                  if (mounted) _groupNameFocus.requestFocus();
                                });
                              }
                            }
                          : null,
                    ),
                    AnimatedSize(
                      duration: const Duration(milliseconds: 240),
                      curve: const Cubic(0.16, 1.0, 0.3, 1.0),
                      alignment: Alignment.topCenter,
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 150),
                        child: _editingGroupName
                            ? Padding(
                                key: const ValueKey('group-name-editor'),
                                padding: const EdgeInsets.fromLTRB(
                                  14,
                                  0,
                                  14,
                                  12,
                                ),
                                child: KeyboardListener(
                                  focusNode: FocusNode(skipTraversal: true),
                                  onKeyEvent: (event) {
                                    if (event is KeyDownEvent &&
                                        event.logicalKey ==
                                            LogicalKeyboardKey.escape) {
                                      setState(() {
                                        _groupNameController.text = group.name;
                                        _editingGroupName = false;
                                      });
                                    }
                                  },
                                  child: TextField(
                                    controller: _groupNameController,
                                    focusNode: _groupNameFocus,
                                    maxLength: 40,
                                    style: const TextStyle(fontSize: 13),
                                    textInputAction: TextInputAction.done,
                                    onSubmitted: (_) => _commitGroupName(),
                                    decoration: InputDecoration(
                                      hintText: '输入新群名',
                                      hintStyle: TextStyle(
                                        fontSize: 13,
                                        color: colorScheme.onSurfaceVariant,
                                      ),
                                      contentPadding:
                                          const EdgeInsets.symmetric(
                                            horizontal: 10,
                                            vertical: 9,
                                          ),
                                      counterText: '',
                                      isDense: true,
                                    ),
                                  ),
                                ),
                              )
                            : const SizedBox.shrink(),
                      ),
                    ),
                    if (_inlineError != null)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                        child: Text(
                          _inlineError!,
                          style: TextStyle(
                            color: colorScheme.error,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    const Divider(height: 1, indent: 52),
                    ListTile(
                      dense: true,
                      leading: const Icon(
                        Icons.drive_file_rename_outline,
                        size: 20,
                      ),
                      title: Text(remark != null ? '修改群聊备注' : '添加群聊备注'),
                      subtitle: Text(
                        remark ?? '仅本机可见，点击填写备注',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: Icon(
                        _editingGroupRemark
                            ? Icons.expand_less
                            : Icons.chevron_right,
                        size: 18,
                      ),
                      onTap: () {
                        final closedAt = _groupRemarkClosedByBlurAt;
                        if (closedAt != null &&
                            DateTime.now().difference(closedAt) <
                                const Duration(milliseconds: 250)) {
                          _groupRemarkClosedByBlurAt = null;
                          return;
                        }
                        if (_editingGroupRemark) {
                          _commitGroupRemark();
                        } else {
                          _groupRemarkClosedByBlurAt = null;
                          _groupRemarkController.text = remark ?? '';
                          setState(() => _editingGroupRemark = true);
                          WidgetsBinding.instance.addPostFrameCallback((_) {
                            if (mounted) _groupRemarkFocus.requestFocus();
                          });
                        }
                      },
                    ),
                    AnimatedSize(
                      duration: const Duration(milliseconds: 240),
                      curve: const Cubic(0.16, 1.0, 0.3, 1.0),
                      alignment: Alignment.topCenter,
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 150),
                        child: _editingGroupRemark
                            ? Padding(
                                key: const ValueKey('group-remark-editor'),
                                padding: const EdgeInsets.fromLTRB(
                                  14,
                                  0,
                                  14,
                                  12,
                                ),
                                child: KeyboardListener(
                                  focusNode: FocusNode(skipTraversal: true),
                                  onKeyEvent: (event) {
                                    if (event is KeyDownEvent &&
                                        event.logicalKey ==
                                            LogicalKeyboardKey.escape) {
                                      setState(() {
                                        _groupRemarkController.text =
                                            remark ?? '';
                                        _editingGroupRemark = false;
                                      });
                                    }
                                  },
                                  child: TextFormField(
                                    controller: _groupRemarkController,
                                    focusNode: _groupRemarkFocus,
                                    maxLength: 40,
                                    style: const TextStyle(fontSize: 13),
                                    textInputAction: TextInputAction.done,
                                    onFieldSubmitted: (_) =>
                                        _commitGroupRemark(),
                                    decoration: InputDecoration(
                                      hintText: '填写备注（留空清除）',
                                      hintStyle: TextStyle(
                                        fontSize: 13,
                                        color: colorScheme.onSurfaceVariant,
                                      ),
                                      contentPadding:
                                          const EdgeInsets.symmetric(
                                            horizontal: 10,
                                            vertical: 9,
                                          ),
                                      counterText: '',
                                      isDense: true,
                                      suffixIcon:
                                          _groupRemarkController.text.isEmpty
                                          ? null
                                          : IconButton(
                                              tooltip: '清空备注',
                                              onPressed: () {
                                                _groupRemarkController.clear();
                                                _commitGroupRemark();
                                              },
                                              icon: const Icon(
                                                Icons.close,
                                                size: 16,
                                              ),
                                            ),
                                    ),
                                  ),
                                ),
                              )
                            : const SizedBox.shrink(),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.all(14),
          child: AnimatedSize(
            duration: const Duration(milliseconds: 240),
            curve: const Cubic(0.16, 1.0, 0.3, 1.0),
            alignment: Alignment.bottomCenter,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 150),
              child: _confirmingLeave
                  ? Column(
                      key: const ValueKey('group-leave-confirm'),
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          _isOwner
                              ? '解散后本机与在线成员将退出该群聊，确定继续？'
                              : '退出后将不再接收该群聊消息，确定继续？',
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: colorScheme.error),
                        ),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton(
                                onPressed: () =>
                                    setState(() => _confirmingLeave = false),
                                child: const Text('取消'),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: FilledButton(
                                style: FilledButton.styleFrom(
                                  backgroundColor: colorScheme.error,
                                  foregroundColor: colorScheme.onError,
                                ),
                                onPressed: () async {
                                  await widget.controller.leaveOrDisbandGroup(
                                    widget.group,
                                  );
                                  widget.onClose();
                                  await widget.onAfterLeaveOrDisband?.call();
                                },
                                child: Text(_isOwner ? '确认解散' : '确认退出'),
                              ),
                            ),
                          ],
                        ),
                      ],
                    )
                  : SizedBox(
                      key: const ValueKey('group-leave-button'),
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: colorScheme.error,
                          side: BorderSide(
                            color: colorScheme.error.withValues(alpha: .45),
                          ),
                        ),
                        onPressed: () =>
                            setState(() => _confirmingLeave = true),
                        icon: Icon(
                          _isOwner ? Icons.delete_outline : Icons.logout,
                          size: 18,
                        ),
                        label: Text(_isOwner ? '解散群聊' : '退出群聊'),
                      ),
                    ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildMembersManagementView(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final query = _memberSearch.text.trim().toLowerCase();
    final filtered = _members.where((member) {
      if (query.isEmpty) return true;
      final displayName = widget.controller.peerDisplayName(
        member.deviceId,
        member.displayName,
      );
      return displayName.toLowerCase().contains(query) ||
          member.displayName.toLowerCase().contains(query);
    }).toList();

    return Column(
      key: const ValueKey('group-drawer-members'),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(6, 10, 10, 6),
          child: Row(
            children: [
              IconButton(
                tooltip: '返回群信息',
                onPressed: () => setState(() {
                  _page = _DrawerPage.overview;
                  _removeMode = false;
                  _confirmingRemoveDeviceId = null;
                  _memberSearch.clear();
                }),
                icon: const Icon(Icons.arrow_back, size: 20),
              ),
              Expanded(
                child: Text(
                  _removeMode
                      ? '移出群成员 (${_members.length})'
                      : '群成员 (${_members.length})',
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (_removeMode)
                TextButton(
                  onPressed: () => setState(() {
                    _removeMode = false;
                    _confirmingRemoveDeviceId = null;
                  }),
                  child: const Text('完成'),
                )
              else
                IconButton(
                  tooltip: '邀请成员',
                  onPressed: () => setState(() => _page = _DrawerPage.invite),
                  icon: const Icon(Icons.person_add_alt_1, size: 20),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
          child: TextField(
            controller: _memberSearch,
            onChanged: (_) => setState(() {}),
            style: const TextStyle(fontSize: 13),
            decoration: InputDecoration(
              hintText: '搜索群成员',
              hintStyle: TextStyle(
                fontSize: 13,
                color: colorScheme.onSurfaceVariant,
              ),
              prefixIcon: const Icon(Icons.search, size: 18),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 9,
              ),
              isDense: true,
            ),
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: filtered.isEmpty
              ? const Center(
                  child: Text('没有匹配的群成员', style: TextStyle(color: Colors.grey)),
                )
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  itemCount: filtered.length,
                  itemBuilder: (context, index) {
                    final member = filtered[index];
                    final isMe =
                        member.deviceId == widget.controller.identity?.deviceId;
                    final displayName = widget.controller.peerDisplayName(
                      member.deviceId,
                      member.displayName,
                    );
                    final hasRemark = widget.controller.peerRemarks.containsKey(
                      member.deviceId,
                    );
                    final online = _isOnline(member.deviceId);
                    final removable = _canRemove(member);
                    final confirmingThis =
                        _confirmingRemoveDeviceId == member.deviceId;

                    return ListTile(
                      dense: true,
                      onTap: isMe || _removeMode
                          ? null
                          : () => _openMemberDetail(member),
                      leading: Stack(
                        children: [
                          NamedAvatar(
                            imagePath: widget.controller.peerAvatarPath(
                              member.deviceId,
                            ),
                            name: displayName,
                            radius: 18,
                          ),
                          Positioned(
                            right: 0,
                            bottom: 0,
                            child: Container(
                              width: 9,
                              height: 9,
                              decoration: BoxDecoration(
                                color: online ? Colors.green : Colors.grey,
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: colorScheme.surface,
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
                            child: Text(
                              isMe ? '$displayName（我）' : displayName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (member.role != GroupRole.member) ...[
                            const SizedBox(width: 6),
                            RoleTag(role: member.role),
                          ],
                        ],
                      ),
                      subtitle: Text(
                        [
                          if (hasRemark) '原名：${member.displayName}',
                          online ? '在线' : '离线',
                        ].join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: isMe
                          ? null
                          : _removeMode
                          ? (removable
                                ? (confirmingThis
                                      ? FilledButton(
                                          style: FilledButton.styleFrom(
                                            backgroundColor: colorScheme.error,
                                            foregroundColor:
                                                colorScheme.onError,
                                            visualDensity:
                                                VisualDensity.compact,
                                          ),
                                          onPressed: () =>
                                              _removeMember(member),
                                          child: const Text('确认移出'),
                                        )
                                      : FilledButton.tonal(
                                          style: FilledButton.styleFrom(
                                            backgroundColor:
                                                colorScheme.errorContainer,
                                            foregroundColor:
                                                colorScheme.onErrorContainer,
                                            visualDensity:
                                                VisualDensity.compact,
                                          ),
                                          onPressed: () => setState(
                                            () => _confirmingRemoveDeviceId =
                                                member.deviceId,
                                          ),
                                          child: const Text('移出'),
                                        ))
                                : null)
                          : const Icon(Icons.chevron_right, size: 18),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildInviteView(BuildContext context) {
    final existingIds = _members.map((m) => m.deviceId).toSet();
    final available = widget.controller.peers
        .where(
          (peer) =>
              peer.online &&
              peer.trusted &&
              !existingIds.contains(peer.deviceId),
        )
        .toList();

    return Column(
      key: const ValueKey('group-drawer-invite'),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(6, 10, 10, 6),
          child: Row(
            children: [
              IconButton(
                tooltip: '返回群信息',
                onPressed: () => setState(() => _page = _DrawerPage.overview),
                icon: const Icon(Icons.arrow_back, size: 20),
              ),
              const Expanded(
                child: Text(
                  '邀请在线成员',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: available.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      '暂无可邀请的已验证在线设备',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey),
                    ),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  itemCount: available.length,
                  itemBuilder: (context, index) {
                    final peer = available[index];
                    final displayName = widget.controller.peerDisplayName(
                      peer.deviceId,
                      peer.displayName,
                    );
                    final hasRemark = widget.controller.peerRemarks.containsKey(
                      peer.deviceId,
                    );
                    return ListTile(
                      dense: true,
                      leading: NamedAvatar(
                        imagePath: widget.controller.peerAvatarPath(
                          peer.deviceId,
                        ),
                        name: displayName,
                        radius: 18,
                      ),
                      title: Text(
                        displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        hasRemark ? '${peer.displayName} · ${peer.ip}' : peer.ip,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: FilledButton.tonal(
                        style: FilledButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                        ),
                        onPressed: () async {
                          await widget.controller.inviteToGroup(
                            widget.group,
                            peer,
                          );
                          await _loadMembers();
                        },
                        child: const Text('邀请'),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildMemberDetailView(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final member = _members
        .where((m) => m.deviceId == _selectedMemberDeviceId)
        .firstOrNull;
    if (member == null) {
      return Center(
        child: TextButton(
          onPressed: () => setState(() => _page = _DrawerPage.overview),
          child: const Text('返回群信息'),
        ),
      );
    }

    final displayName = widget.controller.peerDisplayName(
      member.deviceId,
      member.displayName,
    );
    final hasRemark = widget.controller.peerRemarks.containsKey(
      member.deviceId,
    );
    final online = _isOnline(member.deviceId);
    final removable = _canRemove(member);
    final confirmingRemove = _confirmingRemoveDeviceId == member.deviceId;

    return Column(
      key: const ValueKey('group-drawer-member-detail'),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(6, 10, 10, 6),
          child: Row(
            children: [
              IconButton(
                tooltip: '返回',
                onPressed: () async {
                  await _commitMemberRemark();
                  if (!mounted) return;
                  setState(() {
                    _page = _DrawerPage.overview;
                    _confirmingRemoveDeviceId = null;
                  });
                },
                icon: const Icon(Icons.arrow_back, size: 20),
              ),
              const Expanded(
                child: Text(
                  '成员操作',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(14),
            children: [
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: colorScheme.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    NamedAvatar(
                      imagePath: widget.controller.peerAvatarPath(
                        member.deviceId,
                      ),
                      name: displayName,
                      radius: 22,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Flexible(
                                child: Text(
                                  displayName,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 6),
                              RoleTag(role: member.role),
                            ],
                          ),
                          const SizedBox(height: 2),
                          Text(
                            [
                              if (hasRemark) '原名：${member.displayName}',
                              online ? '在线' : '离线',
                            ].join(' · '),
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(color: colorScheme.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              Padding(
                padding: const EdgeInsets.only(left: 4, bottom: 6),
                child: Text(
                  '人员备注',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              TextField(
                controller: _memberRemarkController,
                focusNode: _memberRemarkFocus,
                maxLength: 32,
                style: const TextStyle(fontSize: 13),
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _commitMemberRemark(),
                decoration: InputDecoration(
                  hintText: '填写备注（留空清除）',
                  hintStyle: TextStyle(
                    fontSize: 13,
                    color: colorScheme.onSurfaceVariant,
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 9,
                  ),
                  counterText: '',
                  isDense: true,
                  filled: true,
                  fillColor: colorScheme.surfaceContainerLow,
                ),
              ),
              const SizedBox(height: 14),
              Material(
                color: colorScheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(12),
                clipBehavior: Clip.antiAlias,
                child: Column(
                  children: [
                    if (widget.onMentionMember != null)
                      ListTile(
                        dense: true,
                        leading: const Icon(Icons.alternate_email, size: 20),
                        title: const Text('@ 提及此人'),
                        onTap: () {
                          widget.onMentionMember!(member.displayName);
                          widget.onClose();
                        },
                      ),
                    if (_isOwner && member.role != GroupRole.owner) ...[
                      if (widget.onMentionMember != null)
                        const Divider(height: 1, indent: 52),
                      ListTile(
                        dense: true,
                        leading: Icon(
                          member.role == GroupRole.admin
                              ? Icons.remove_moderator_outlined
                              : Icons.add_moderator_outlined,
                          size: 20,
                        ),
                        title: Text(
                          member.role == GroupRole.admin ? '取消管理员' : '设为管理员',
                        ),
                        onTap: () => _toggleAdminRole(member),
                      ),
                    ],
                  ],
                ),
              ),
              if (removable) ...[
                const SizedBox(height: 14),
                if (confirmingRemove)
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () =>
                              setState(() => _confirmingRemoveDeviceId = null),
                          child: const Text('取消'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: FilledButton(
                          style: FilledButton.styleFrom(
                            backgroundColor: colorScheme.error,
                            foregroundColor: colorScheme.onError,
                          ),
                          onPressed: () => _removeMember(member),
                          child: const Text('确认移出'),
                        ),
                      ),
                    ],
                  )
                else
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: colorScheme.error,
                        side: BorderSide(
                          color: colorScheme.error.withValues(alpha: .45),
                        ),
                      ),
                      onPressed: () => setState(
                        () => _confirmingRemoveDeviceId = member.deviceId,
                      ),
                      icon: const Icon(Icons.person_remove_outlined, size: 18),
                      label: const Text('移出群聊'),
                    ),
                  ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _MemberGridItem extends StatelessWidget {
  const _MemberGridItem({
    required this.avatarPath,
    required this.name,
    required this.role,
    required this.online,
    required this.onTap,
  });

  final String? avatarPath;
  final String name;
  final GroupRole role;
  final bool online;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      child: SizedBox(
        width: 50,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                NamedAvatar(imagePath: avatarPath, name: name, radius: 19),
                Positioned(
                  right: 0,
                  bottom: 0,
                  child: Container(
                    width: 9,
                    height: 9,
                    decoration: BoxDecoration(
                      color: online ? Colors.green : Colors.grey,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: colorScheme.surfaceContainerLow,
                        width: 1.5,
                      ),
                    ),
                  ),
                ),
                if (role != GroupRole.member)
                  Positioned(
                    right: -3,
                    top: -3,
                    child: Container(
                      padding: const EdgeInsets.all(2),
                      decoration: BoxDecoration(
                        color: role == GroupRole.owner
                            ? const Color(0xFFFFE9B8)
                            : colorScheme.tertiaryContainer,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        role == GroupRole.owner
                            ? Icons.star_rounded
                            : Icons.shield_outlined,
                        size: 10,
                        color: role == GroupRole.owner
                            ? const Color(0xFF8A5A00)
                            : colorScheme.onTertiaryContainer,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _GridActionCircle extends StatelessWidget {
  const _GridActionCircle({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      child: SizedBox(
        width: 50,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: colorScheme.outlineVariant),
                color: colorScheme.surface,
              ),
              child: Icon(icon, size: 18, color: colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 4),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
