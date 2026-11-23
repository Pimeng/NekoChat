import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import '../../app/app_controller.dart';
import '../../core/models/models.dart';
import 'main_shell.dart';

enum _PeerConfirmAction { none, revokeVerification, block, unblock }

/// 单聊右侧悬浮信息面板：
/// 将原右上角菜单与弹窗中的「查看资料、修改备注、独立窗口、关闭对话、取消验证、拉黑/解除拉黑」
/// 全部收拢到右侧悬浮面板内，并全部采用面板内原地展开编辑与原地二次确认，无模态弹窗。
class PeerInfoDrawer extends StatefulWidget {
  const PeerInfoDrawer({
    super.key,
    required this.controller,
    required this.chat,
    required this.onClose,
    this.onOpenInWindow,
    this.onAfterClose,
  });

  final AppController controller;
  final ChatSummary chat;
  final VoidCallback onClose;
  final Future<void> Function()? onOpenInWindow;
  final Future<void> Function()? onAfterClose;

  @override
  State<PeerInfoDrawer> createState() => _PeerInfoDrawerState();
}

class _PeerInfoDrawerState extends State<PeerInfoDrawer> {
  final TextEditingController _remarkController = TextEditingController();
  final FocusNode _remarkFocus = FocusNode();
  bool _editingRemark = false;
  DateTime? _remarkBlurClosedAt;
  bool _committingRemark = false;
  bool _copiedDeviceId = false;
  _PeerConfirmAction _confirmAction = _PeerConfirmAction.none;

  @override
  void initState() {
    super.initState();
    _remarkFocus.addListener(_handleRemarkFocusChange);
  }

  @override
  void didUpdateWidget(covariant PeerInfoDrawer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.chat.chatId != widget.chat.chatId) {
      _editingRemark = false;
      _confirmAction = _PeerConfirmAction.none;
      _copiedDeviceId = false;
    }
  }

  @override
  void dispose() {
    _remarkFocus.removeListener(_handleRemarkFocusChange);
    _remarkFocus.dispose();
    _remarkController.dispose();
    super.dispose();
  }

  void _handleRemarkFocusChange() {
    if (!_remarkFocus.hasFocus && _editingRemark) {
      _remarkBlurClosedAt = DateTime.now();
      _commitRemark();
    }
  }

  bool _recentlyClosedByBlur(DateTime? closedAt) =>
      closedAt != null &&
      DateTime.now().difference(closedAt) < const Duration(milliseconds: 250);

  void _startEditRemark() {
    final current = widget.controller.peerRemarks[widget.chat.peerDeviceId] ?? '';
    _remarkController.text = current;
    _remarkController.selection = TextSelection.collapsed(
      offset: current.length,
    );
    setState(() {
      _editingRemark = true;
      _confirmAction = _PeerConfirmAction.none;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _editingRemark) _remarkFocus.requestFocus();
    });
  }

  Future<void> _commitRemark() async {
    if (_committingRemark || !_editingRemark) return;
    _committingRemark = true;
    final next = _remarkController.text.trim();
    final current = widget.controller.peerRemarks[widget.chat.peerDeviceId] ?? '';
    if (mounted) {
      setState(() => _editingRemark = false);
    }
    try {
      if (next != current) {
        await widget.controller.setPeerRemark(widget.chat.peerDeviceId, next);
      }
    } finally {
      _committingRemark = false;
    }
  }

  Future<void> _copyDeviceId(String deviceId) async {
    await Clipboard.setData(ClipboardData(text: deviceId));
    if (!mounted) return;
    setState(() => _copiedDeviceId = true);
    Future<void>.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copiedDeviceId = false);
    });
  }

  Future<void> _executeConfirmAction() async {
    final action = _confirmAction;
    if (action == _PeerConfirmAction.none) return;
    setState(() => _confirmAction = _PeerConfirmAction.none);
    final deviceId = widget.chat.peerDeviceId;
    switch (action) {
      case _PeerConfirmAction.revokeVerification:
        await widget.controller.revokePeerVerification(deviceId);
      case _PeerConfirmAction.block:
        await widget.controller.setBlocked(deviceId, true);
      case _PeerConfirmAction.unblock:
        await widget.controller.setBlocked(deviceId, false);
      case _PeerConfirmAction.none:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final controller = widget.controller;
    final chat = widget.chat;
    final deviceId = chat.peerDeviceId;
    final peer = controller.peers
        .where((value) => value.deviceId == deviceId)
        .firstOrNull;
    final trusted = controller.trustedPeers[deviceId];
    final originalName =
        peer?.displayName ?? trusted?.displayName ?? chat.displayName;
    final displayName = controller.peerDisplayName(deviceId, originalName);
    final remark = controller.peerRemarks[deviceId];
    final online = peer?.online == true;
    final isBlocked = trusted?.blocked == true;
    final isVerified = trusted != null && !isBlocked;

    final infoRows = <(IconData, String, String, bool)>[
      (Icons.badge_outlined, '原昵称', originalName, false),
      (Icons.fingerprint, '设备 ID', deviceId, true),
      (Icons.lan_outlined, '网络', peer?.ip ?? '离线', false),
      if (peer != null)
        (Icons.settings_ethernet, '端口', '${peer.port}', false),
      (Icons.wifi_tethering, '在线状态', online ? '在线' : '离线', false),
      (
        Icons.verified_user_outlined,
        '验证状态',
        trusted == null ? '未验证' : (isBlocked ? '已拉黑' : '已验证'),
        false,
      ),
    ];

    return RepaintBoundary(
      child: Material(
        key: const ValueKey('peer-info-drawer'),
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
          child: ListView(
            padding: const EdgeInsets.all(14),
            children: [
              // 顶部联系人卡片
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: colorScheme.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    NamedAvatar(
                      imagePath: controller.peerAvatarPath(deviceId),
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
                              if (isVerified) ...[
                                const SizedBox(width: 4),
                                const Icon(
                                  Icons.verified,
                                  color: Colors.blue,
                                  size: 15,
                                ),
                              ],
                            ],
                          ),
                          const SizedBox(height: 2),
                          Text(
                            [
                              if (remark != null) '原名：$originalName',
                              online ? '在线' : '离线',
                            ].join(' · '),
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
              const SizedBox(height: 14),

              // 人员备注（点击直接原地展开输入框，回车或失焦保存）
              Padding(
                padding: const EdgeInsets.only(left: 4, bottom: 6),
                child: Text(
                  '人员备注',
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
                      leading: const Icon(
                        Icons.drive_file_rename_outline,
                        size: 20,
                      ),
                      title: Text(remark != null ? '修改人员备注' : '添加人员备注'),
                      subtitle: Text(
                        remark ?? '仅本机可见，点击填写备注',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: Icon(
                        _editingRemark
                            ? Icons.expand_less
                            : Icons.chevron_right,
                        size: 18,
                      ),
                      onTap: () {
                        if (_editingRemark) {
                          _commitRemark();
                        } else if (_recentlyClosedByBlur(_remarkBlurClosedAt)) {
                          _remarkBlurClosedAt = null;
                        } else {
                          _startEditRemark();
                        }
                      },
                    ),
                    AnimatedSize(
                      duration: const Duration(milliseconds: 240),
                      curve: const Cubic(0.16, 1.0, 0.3, 1.0),
                      alignment: Alignment.topCenter,
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 150),
                        switchInCurve: Curves.easeOutCubic,
                        switchOutCurve: Curves.easeInCubic,
                        child: _editingRemark
                            ? Padding(
                                key: const ValueKey('peer-remark-editor'),
                                padding: const EdgeInsets.fromLTRB(
                                  12,
                                  0,
                                  12,
                                  12,
                                ),
                                child: TextField(
                                  key: const ValueKey(
                                    'peer-drawer-remark-field',
                                  ),
                                  controller: _remarkController,
                                  focusNode: _remarkFocus,
                                  maxLength: 32,
                                  style: const TextStyle(fontSize: 13),
                                  textInputAction: TextInputAction.done,
                                  onSubmitted: (_) => _commitRemark(),
                                  decoration: InputDecoration(
                                    hintText: '填写备注（留空清除）',
                                    hintStyle: TextStyle(
                                      fontSize: 13,
                                      color: colorScheme.onSurfaceVariant,
                                    ),
                                    isDense: true,
                                    contentPadding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 9,
                                    ),
                                    counterText: '',
                                  ),
                                ),
                              )
                            : const SizedBox.shrink(),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),

              // 设备与网络资料
              Padding(
                padding: const EdgeInsets.only(left: 4, bottom: 6),
                child: Text(
                  '设备与网络资料',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              Material(
                color: colorScheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(12),
                clipBehavior: Clip.antiAlias,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  child: Column(
                    children: [
                      for (var i = 0; i < infoRows.length; i++) ...[
                        if (i > 0) const Divider(height: 14),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            Icon(
                              infoRows[i].$1,
                              size: 16,
                              color: colorScheme.onSurfaceVariant,
                            ),
                            const SizedBox(width: 8),
                            SizedBox(
                              width: 60,
                              child: Text(
                                infoRows[i].$2,
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ),
                            Expanded(
                              child: Text(
                                infoRows[i].$3,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                            if (infoRows[i].$4)
                              IconButton(
                                tooltip: _copiedDeviceId ? '已复制' : '复制设备 ID',
                                visualDensity: VisualDensity.compact,
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints.tightFor(
                                  width: 28,
                                  height: 28,
                                ),
                                onPressed: () => _copyDeviceId(deviceId),
                                icon: Icon(
                                  _copiedDeviceId
                                      ? Icons.check
                                      : Icons.copy_outlined,
                                  size: 15,
                                  color: _copiedDeviceId
                                      ? colorScheme.primary
                                      : colorScheme.onSurfaceVariant,
                                ),
                              ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 14),

              // 会话与安全操作
              Padding(
                padding: const EdgeInsets.only(left: 4, bottom: 6),
                child: Text(
                  '会话与安全',
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
                      leading: const Icon(Icons.close, size: 20),
                      title: const Text('关闭对话'),
                      subtitle: const Text('从当前会话收起，历史记录仍保留'),
                      onTap: () async {
                        widget.onClose();
                        await controller.closeChat(chat);
                        await widget.onAfterClose?.call();
                      },
                    ),
                    if (trusted != null) ...[
                      const Divider(height: 1, indent: 52),
                      ListTile(
                        dense: true,
                        leading: Icon(
                          Icons.gpp_bad_outlined,
                          size: 20,
                          color: colorScheme.error,
                        ),
                        title: Text(
                          '取消验证',
                          style: TextStyle(color: colorScheme.error),
                        ),
                        subtitle: const Text('撤销已验证身份，下次聊天需重新发起好友申请'),
                        trailing: Icon(
                          _confirmAction ==
                                  _PeerConfirmAction.revokeVerification
                              ? Icons.expand_less
                              : Icons.chevron_right,
                          size: 18,
                          color: colorScheme.error,
                        ),
                        onTap: () => setState(() {
                          _confirmAction =
                              _confirmAction ==
                                  _PeerConfirmAction.revokeVerification
                              ? _PeerConfirmAction.none
                              : _PeerConfirmAction.revokeVerification;
                        }),
                      ),
                    ],
                    const Divider(height: 1, indent: 52),
                    ListTile(
                      dense: true,
                      leading: Icon(
                        isBlocked ? Icons.check_circle_outline : Icons.block,
                        size: 20,
                        color: isBlocked
                            ? colorScheme.primary
                            : colorScheme.error,
                      ),
                      title: Text(
                        isBlocked ? '解除拉黑' : '加入黑名单',
                        style: TextStyle(
                          color: isBlocked
                              ? colorScheme.primary
                              : colorScheme.error,
                        ),
                      ),
                      subtitle: Text(
                        isBlocked ? '重新接受此人的聊天请求与消息' : '拦截此人发来的聊天请求与消息',
                      ),
                      trailing: Icon(
                        _confirmAction ==
                                (isBlocked
                                    ? _PeerConfirmAction.unblock
                                    : _PeerConfirmAction.block)
                            ? Icons.expand_less
                            : Icons.chevron_right,
                        size: 18,
                        color: isBlocked
                            ? colorScheme.primary
                            : colorScheme.error,
                      ),
                      onTap: () => setState(() {
                        final target = isBlocked
                            ? _PeerConfirmAction.unblock
                            : _PeerConfirmAction.block;
                        _confirmAction = _confirmAction == target
                            ? _PeerConfirmAction.none
                            : target;
                      }),
                    ),
                  ],
                ),
              ),
              AnimatedSize(
                duration: const Duration(milliseconds: 240),
                curve: const Cubic(0.16, 1.0, 0.3, 1.0),
                alignment: Alignment.topCenter,
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 150),
                  switchInCurve: Curves.easeOutCubic,
                  switchOutCurve: Curves.easeInCubic,
                  child: _confirmAction != _PeerConfirmAction.none
                      ? Padding(
                          key: ValueKey('peer-confirm-${_confirmAction.name}'),
                          padding: const EdgeInsets.only(top: 10),
                          child: _buildConfirmBanner(context, displayName),
                        )
                      : const SizedBox.shrink(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildConfirmBanner(BuildContext context, String displayName) {
    final colorScheme = Theme.of(context).colorScheme;
    final isPositive = _confirmAction == _PeerConfirmAction.unblock;
    final title = switch (_confirmAction) {
      _PeerConfirmAction.revokeVerification => '确认取消验证？',
      _PeerConfirmAction.block => '确认加入黑名单？',
      _PeerConfirmAction.unblock => '确认解除拉黑？',
      _PeerConfirmAction.none => '',
    };
    final message = switch (_confirmAction) {
      _PeerConfirmAction.revokeVerification =>
        '取消对“$displayName”的验证后，再次聊天需要重新发起好友申请并由对方通过。',
      _PeerConfirmAction.block => '拉黑“$displayName”后，将不再接收此人的聊天请求和消息。',
      _PeerConfirmAction.unblock => '解除对“$displayName”的拉黑后，将重新接受此人的聊天请求和消息。',
      _PeerConfirmAction.none => '',
    };
    final confirmLabel = switch (_confirmAction) {
      _PeerConfirmAction.revokeVerification => '确认取消验证',
      _PeerConfirmAction.block => '确认拉黑',
      _PeerConfirmAction.unblock => '确认解除',
      _PeerConfirmAction.none => '',
    };

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isPositive
            ? colorScheme.primaryContainer.withValues(alpha: .45)
            : colorScheme.errorContainer.withValues(alpha: .55),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isPositive
              ? colorScheme.primary.withValues(alpha: .35)
              : colorScheme.error.withValues(alpha: .35),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: isPositive
                  ? colorScheme.onPrimaryContainer
                  : colorScheme.onErrorContainer,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            message,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: isPositive
                  ? colorScheme.onPrimaryContainer
                  : colorScheme.onErrorContainer,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () =>
                      setState(() => _confirmAction = _PeerConfirmAction.none),
                  child: const Text('取消'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton(
                  style: isPositive
                      ? null
                      : FilledButton.styleFrom(
                          backgroundColor: colorScheme.error,
                          foregroundColor: colorScheme.onError,
                        ),
                  onPressed: _executeConfirmAction,
                  child: Text(confirmLabel),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
