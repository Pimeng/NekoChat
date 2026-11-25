import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import '../../app/app_controller.dart';
import '../../core/boss_key/boss_key_service.dart';
import '../../core/models/models.dart';
import '../../core/notifications/notification_window_channel.dart';
import '../common/backup_restore_dialogs.dart';
import '../common/smooth_dialog.dart';

enum SettingsSection {
  lan('在线探测', '保持在线并与同一局域网设备互相可见', Icons.wifi_find_outlined),
  appearance('外观', '字体大小、字体与字重', Icons.text_fields_outlined),
  privacy('隐私与安全', '老板键、快捷键与黑名单', Icons.visibility_off_outlined),
  files('文件接收', '自动接收与大小上限', Icons.download_outlined),
  notifications('通知', '独立弹窗、系统通知与测试', Icons.notifications_outlined),
  storage('存储与关于', '数据文件夹、备份还原与版本信息', Icons.folder_outlined);

  const SettingsSection(this.title, this.subtitle, this.icon);
  final String title;
  final String subtitle;
  final IconData icon;
}

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key, required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) => Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
            children: [
              const SettingsSectionTitle('在线探测'),
              Card(
                child: SwitchListTile(
                  secondary: const Icon(Icons.wifi_find_outlined),
                  title: const Text('在线探测'),
                  subtitle: const Text(
                    '开启后与同一局域网内的 NekoChat 设备保持在线探测、互相可见；关闭后将无法收发消息',
                  ),
                  value: controller.lanDiscoveryEnabled,
                  onChanged: controller.setLanDiscoveryEnabled,
                ),
              ),
              const SizedBox(height: 12),
              PairingCodeCard(controller: controller),
              const SizedBox(height: 12),
              Card(
                child: SwitchListTile(
                  secondary: const Icon(Icons.person_off_outlined),
                  title: const Text('屏蔽加好友申请'),
                  subtitle: const Text(
                    '开启后忽略陌生人的加好友申请；用你口令来加你的人、以及已验证好友不受影响',
                  ),
                  value: controller.blockFriendRequests,
                  onChanged: controller.setBlockFriendRequests,
                ),
              ),
              const SizedBox(height: 24),
              const SettingsSectionTitle('隐私'),
              Card(
                child: Column(
                  children: [
                    SwitchListTile(
                      secondary: const Icon(Icons.visibility_off_outlined),
                      title: const Text('老板键'),
                      subtitle: const Text('开启全局快捷键隐藏或恢复应用'),
                      value: controller.bossKeyEnabled,
                      onChanged: controller.setBossKeyEnabled,
                    ),
                    const Divider(height: 1, indent: 56),
                    ListTile(
                      leading: const Icon(Icons.keyboard_outlined),
                      title: const Text('快捷键'),
                      subtitle: Text(controller.bossKeyShortcut.displayLabel),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) =>
                              BossKeyShortcutPage(controller: controller),
                        ),
                      ),
                    ),
                    const Divider(height: 1, indent: 56),
                    SwitchListTile(
                      secondary: const Icon(
                        Icons.notifications_active_outlined,
                      ),
                      title: const Text('隐藏后仍然弹出通知'),
                      subtitle: const Text('老板键隐藏窗口后，新消息仍显示 Windows 通知'),
                      value: controller.bossKeyNotifyWhenHidden,
                      onChanged: controller.setBossKeyNotifyWhenHidden,
                    ),
                    if (controller.bossKeyError != null) ...[
                      const Divider(height: 1, indent: 56),
                      ListTile(
                        leading: Icon(
                          Icons.warning_amber_rounded,
                          color: Theme.of(context).colorScheme.error,
                        ),
                        title: Text(
                          controller.bossKeyError!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 10, 16, 0),
                child: Text(
                  '隐藏后不显示任务栏入口或系统通知，再按当前快捷键 '
                  '或重新启动 NekoChat 即可恢复。进程仍会在任务管理器中显示。',
                  style: TextStyle(color: Colors.black54, fontSize: 12),
                ),
              ),
              const SizedBox(height: 12),
              Card(
                child: ListTile(
                  leading: const Icon(Icons.block_outlined),
                  title: const Text('黑名单'),
                  subtitle: Text(
                    controller.blockedPeers.isEmpty
                        ? '暂无已拉黑的联系人'
                        : '已拉黑 ${controller.blockedPeers.length} 人，可随时解除拉黑',
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => BlockedPeersPage(controller: controller),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 24),
              const SettingsSectionTitle('文件接收'),
              Card(
                child: Column(
                  children: [
                    SwitchListTile(
                      secondary: const Icon(Icons.download_outlined),
                      title: const Text('自动接收文件'),
                      subtitle: const Text('小文件自动下载，大文件仍需手动确认'),
                      value: controller.autoReceiveFiles,
                      onChanged: controller.setAutoReceiveFiles,
                    ),
                    const Divider(height: 1, indent: 56),
                    ListTile(
                      leading: const Icon(Icons.data_usage_outlined),
                      title: const Text('自动接收大小上限'),
                      subtitle: Text(
                        '小于 ${_formatMegabytes(controller.autoReceiveFileLimitBytes)} MB '
                        '的文件自动接收；达到上限后需要确认',
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            '${_formatMegabytes(controller.autoReceiveFileLimitBytes)} MB',
                          ),
                          const SizedBox(width: 4),
                          const Icon(Icons.chevron_right),
                        ],
                      ),
                      onTap: () => _showAutoReceiveLimitDialog(context),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              const SettingsSectionTitle('通知'),
              _NotificationSettingsCard(controller: controller),
              const SizedBox(height: 24),
              const SettingsSectionTitle('存储'),
              Card(
                child: ListTile(
                  leading: const Icon(Icons.folder_outlined),
                  title: const Text('数据文件夹'),
                  subtitle: Text(
                    controller.dataDirectory ?? '数据目录尚未就绪',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: const Icon(Icons.open_in_new, size: 20),
                  onTap: controller.dataDirectory == null
                      ? null
                      : controller.openDataDirectory,
                ),
              ),
              const SizedBox(height: 12),
              _BackupRestoreCard(
                controller: controller,
                popRoutesOnRestore: true,
              ),
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 10, 16, 0),
                child: Text(
                  '聊天记录、身份数据、收藏表情包和已接收附件都保存在本机；定期备份可避免重置或换机导致数据丢失。',
                  style: TextStyle(color: Colors.black54, fontSize: 12),
                ),
              ),
              const SizedBox(height: 24),
              const SettingsSectionTitle('外观'),
              AppearanceSettingsCards(controller: controller),
              const SizedBox(height: 32),
              const SettingsVersionFooter(),
            ],
          ),
        ),
      ),
    ),
  );

  Future<void> _showAutoReceiveLimitDialog(BuildContext context) async {
    var input = _formatMegabytes(controller.autoReceiveFileLimitBytes)
        .toString();
    String? errorText;
    final megabytes = await showNekoDialog<int>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('自动接收大小上限'),
          content: SizedBox(
            width: 360,
            child: TextFormField(
              initialValue: input,
              autofocus: true,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: InputDecoration(
                labelText: '文件大小',
                suffixText: 'MB',
                helperText: '可设置 1～512 MB，仅影响是否自动接收',
                helperMaxLines: 2,
                errorText: errorText,
              ),
              onChanged: (value) => input = value,
              onFieldSubmitted: (value) => _submitAutoReceiveLimit(
                dialogContext,
                value,
                (message) => setDialogState(() => errorText = message),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => _submitAutoReceiveLimit(
                dialogContext,
                input,
                (message) => setDialogState(() => errorText = message),
              ),
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    if (megabytes == null) return;
    await controller.setAutoReceiveFileLimitBytes(megabytes * 1024 * 1024);
  }

  void _submitAutoReceiveLimit(
    BuildContext context,
    String value,
    ValueChanged<String?> setError,
  ) {
    final megabytes = int.tryParse(value);
    if (megabytes == null || megabytes < 1 || megabytes > 512) {
      setError('请输入 1～512 之间的整数');
      return;
    }
    Navigator.pop(context, megabytes);
  }
}

class SettingsSectionTitle extends StatelessWidget {
  const SettingsSectionTitle(this.title, {super.key});

  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
    child: Text(
      title,
      style: Theme.of(context).textTheme.titleSmall?.copyWith(
        color: Theme.of(context).colorScheme.primary,
        fontWeight: FontWeight.w600,
      ),
    ),
  );
}

int _formatMegabytes(int bytes) => bytes ~/ (1024 * 1024);

/// “我的口令”卡片：展示本机口令并提供“重新生成”。别人用此口令加你可穿透“屏蔽加好友申请”。
class PairingCodeCard extends StatelessWidget {
  const PairingCodeCard({super.key, required this.controller});

  final AppController controller;

  Future<void> _regenerate(BuildContext context) async {
    final confirmed = await showNekoDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('重新生成口令'),
        content: const Text('生成新口令后，旧口令立即失效，用旧口令添加你的操作将失败。确定继续吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('重新生成'),
          ),
        ],
      ),
    );
    if (confirmed == true) await controller.regeneratePairingCode();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: AnimatedBuilder(
        animation: controller,
        builder: (context, _) => ListTile(
          leading: const Icon(Icons.vpn_key_outlined),
          title: const Text('我的口令'),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 4),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      controller.myPairingCode,
                      style: theme.textTheme.titleMedium?.copyWith(
                        letterSpacing: 1,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '复制口令',
                    onPressed: controller.copyPairingCode,
                    icon: const Icon(Icons.copy, size: 18),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                '把口令告诉对方即可用它加你（可穿透“屏蔽加好友申请”）；怀疑泄露可重新生成。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          isThreeLine: true,
          trailing: TextButton.icon(
            onPressed: () => _regenerate(context),
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('重新生成'),
          ),
        ),
      ),
    );
  }
}

/// 外观设置卡片组：实时预览 + 字体大小、字体、加粗，供嵌入式面板与独立设置页共用。
class AppearanceSettingsCards extends StatelessWidget {
  const AppearanceSettingsCards({super.key, required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final colorScheme = Theme.of(context).colorScheme;
    final scaleEntries = AppController.fontScaleOptions.entries.toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '预览',
                  style: textTheme.labelMedium?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'NekoChat 局域网聊天 · 字体预览 Abc 123',
                  style: textTheme.bodyLarge,
                ),
                const SizedBox(height: 4),
                Text(
                  '在这里可以直观看到字号、字体与字重的效果。',
                  style: textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.format_size_outlined),
                    const SizedBox(width: 12),
                    Text('字体大小', style: textTheme.titleSmall),
                  ],
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: SegmentedButton<double>(
                    showSelectedIcon: false,
                    segments: [
                      for (final entry in scaleEntries)
                        ButtonSegment<double>(
                          value: entry.value,
                          label: Text(entry.key),
                        ),
                    ],
                    selected: {controller.fontScale},
                    onSelectionChanged: (selection) =>
                        controller.setFontScale(selection.first),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.font_download_outlined),
                    const SizedBox(width: 12),
                    Text('字体', style: textTheme.titleSmall),
                  ],
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('中英文分开设置'),
                  subtitle: const Text('关闭时中英文用同一字体；开启后分别选择'),
                  value: controller.separateFonts,
                  onChanged: controller.setSeparateFonts,
                ),
                const SizedBox(height: 8),
                if (!controller.separateFonts)
                  _fontDropdown(
                    context,
                    value: controller.selectedCjkFontFamily,
                    options: controller.availableFontOptions(wantCjk: true),
                    onChanged: controller.setAppFontFamily,
                  )
                else ...[
                  _fontDropdown(
                    context,
                    label: '中文字体',
                    value: controller.selectedCjkFontFamily,
                    options: controller.availableFontOptions(wantCjk: true),
                    onChanged: controller.setAppFontFamily,
                  ),
                  const SizedBox(height: 12),
                  _fontDropdown(
                    context,
                    label: '英文字体',
                    value: controller.selectedLatinFontFamily,
                    options: controller.availableFontOptions(wantCjk: false),
                    onChanged: controller.setLatinFontFamily,
                  ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Card(
          child: SwitchListTile(
            secondary: const Icon(Icons.format_bold),
            title: const Text('字体加粗'),
            subtitle: const Text('整体文字字重上调一档，看起来更醒目'),
            value: controller.boldText,
            onChanged: controller.setBoldText,
          ),
        ),
        const SizedBox(height: 16),
        Card(
          child: SwitchListTile(
            key: const ValueKey('sticker-suggestions-switch'),
            secondary: const Icon(Icons.sentiment_satisfied_alt_outlined),
            title: const Text('表情联想'),
            subtitle: const Text('输入与收藏表情备注匹配的文字时，在输入框上方快捷弹出对应表情'),
            value: controller.stickerSuggestionsEnabled,
            onChanged: controller.setStickerSuggestionsEnabled,
          ),
        ),
      ],
    );
  }

  /// 带边框的字体下拉；每个选项用它自己的字体渲染，便于直观对比。
  Widget _fontDropdown(
    BuildContext context, {
    String? label,
    required String? value,
    required Iterable<AppFontOption> options,
    required ValueChanged<String?> onChanged,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (label != null) ...[
          Text(
            label,
            style: textTheme.labelMedium?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 6),
        ],
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            border: Border.all(color: colorScheme.outlineVariant),
            borderRadius: BorderRadius.circular(8),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String?>(
              isExpanded: true,
              value: value,
              borderRadius: BorderRadius.circular(8),
              // 选中后按钮仍持有焦点，默认 focusColor 会铺一层灰底，置空消除。
              focusColor: Colors.transparent,
              items: [
                for (final option in options)
                  DropdownMenuItem<String?>(
                    value: option.family,
                    child: Text(
                      option.label,
                      style: TextStyle(fontFamily: option.family),
                    ),
                  ),
              ],
              onChanged: onChanged,
            ),
          ),
        ),
      ],
    );
  }
}

class SettingsVersionFooter extends StatelessWidget {
  const SettingsVersionFooter({super.key});

  @override
  Widget build(BuildContext context) => Padding(
    key: const ValueKey('settings-version-footer'),
    padding: const EdgeInsets.only(top: 8, bottom: 4),
    child: Text(
      'NekoChat · 当前版本 ${appBuildName ?? '未知'}',
      textAlign: TextAlign.center,
      style: Theme.of(context).textTheme.bodySmall
          ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
    ),
  );
}

class BossKeyShortcutPage extends StatefulWidget {
  const BossKeyShortcutPage({
    super.key,
    required this.controller,
    this.onBack,
  });

  final AppController controller;
  final VoidCallback? onBack;

  @override
  State<BossKeyShortcutPage> createState() => _BossKeyShortcutPageState();
}

class _BossKeyShortcutPageState extends State<BossKeyShortcutPage> {
  final _focusNode = FocusNode(debugLabel: 'boss-key-recorder');
  late BossKeyShortcut _candidate;
  String _hint = '请按下新的快捷键组合';
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _candidate = widget.controller.bossKeyShortcut;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.handled;
    final keyboard = HardwareKeyboard.instance;
    final shortcut = BossKeyShortcut.fromLogicalKey(
      event.logicalKey,
      control: keyboard.isControlPressed,
      alt: keyboard.isAltPressed,
      shift: keyboard.isShiftPressed,
      meta: keyboard.isMetaPressed,
    );
    if (shortcut == null) {
      setState(() {
        _hint =
            keyboard.isControlPressed ||
                keyboard.isAltPressed ||
                keyboard.isShiftPressed ||
                keyboard.isMetaPressed
            ? '请在修饰键按住时再按一个普通键'
            : '快捷键必须包含 Ctrl、Alt、Shift 或 Win';
      });
      return KeyEventResult.handled;
    }
    setState(() {
      _candidate = shortcut;
      _hint = '已记录，点击右上角保存';
    });
    return KeyEventResult.handled;
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    final saved = await widget.controller.setBossKeyShortcut(_candidate);
    if (!mounted) return;
    if (saved) {
      if (widget.onBack != null) {
        widget.onBack!();
      } else {
        Navigator.of(context).pop();
      }
    } else {
      setState(() {
        _saving = false;
        _hint = widget.controller.bossKeyError ?? '无法保存该快捷键';
      });
      _focusNode.requestFocus();
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      leading: widget.onBack != null
          ? IconButton(
              tooltip: '返回',
              onPressed: widget.onBack,
              icon: const Icon(Icons.arrow_back),
            )
          : null,
      title: const Text('老板键快捷键'),
      actions: [
        TextButton(
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('保存'),
        ),
        const SizedBox(width: 12),
      ],
    ),
    body: Focus(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: _handleKeyEvent,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _focusNode.requestFocus,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.keyboard, size: 52),
                  const SizedBox(height: 24),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 28,
                      vertical: 18,
                    ),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surfaceContainerHigh,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: Theme.of(context).colorScheme.outlineVariant,
                      ),
                    ),
                    child: Text(
                      _candidate.displayLabel,
                      style: Theme.of(context).textTheme.headlineSmall
                          ?.copyWith(fontWeight: FontWeight.w600),
                    ),
                  ),
                  const SizedBox(height: 18),
                  Text(_hint, textAlign: TextAlign.center),
                  const SizedBox(height: 8),
                  const Text(
                    '支持字母、数字、F1–F12 和常用功能键，'
                    '至少需要一个修饰键。',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.black54, fontSize: 12),
                  ),
                  const SizedBox(height: 20),
                  TextButton.icon(
                    onPressed: () => setState(() {
                      _candidate = BossKeyShortcut.altF;
                      _hint = '已恢复默认值，点击保存后生效';
                    }),
                    icon: const Icon(Icons.restart_alt),
                    label: const Text('恢复默认 Alt + F'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class BlockedPeersPage extends StatelessWidget {
  const BlockedPeersPage({
    super.key,
    required this.controller,
    this.onBack,
  });

  final AppController controller;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) {
      final blocked = controller.blockedPeers;
      return Scaffold(
        appBar: AppBar(
          leading: onBack != null
              ? IconButton(
                  tooltip: '返回',
                  onPressed: onBack,
                  icon: const Icon(Icons.arrow_back),
                )
              : null,
          title: const Text('黑名单'),
        ),
        body: blocked.isEmpty
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.check_circle_outline,
                        size: 52,
                        color: Theme.of(context).colorScheme.outline,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        '黑名单为空',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        '被拉黑的联系人会显示在这里，你可以随时解除拉黑。',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.black54),
                      ),
                    ],
                  ),
                ),
              )
            : Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 760),
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
                    children: [
                      Card(
                        child: Column(
                          children: [
                            for (var i = 0; i < blocked.length; i++) ...[
                              if (i > 0) const Divider(height: 1, indent: 56),
                              _buildPeerTile(context, blocked[i]),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
      );
    },
  );

  Widget _buildPeerTile(BuildContext context, TrustedPeer peer) {
    final displayName = controller.peerDisplayName(
      peer.deviceId,
      peer.displayName,
    );
    final hasRemark = displayName != peer.displayName;
    final devicePrefix = peer.deviceId.length > 8
        ? peer.deviceId.substring(0, 8)
        : peer.deviceId;
    final subtitleParts = [
      if (hasRemark) '原名：${peer.displayName}',
      '设备 $devicePrefix',
      if (peer.lastKnownIp.isNotEmpty) peer.lastKnownIp,
    ];
    return ListTile(
      leading: const CircleAvatar(child: Icon(Icons.block, size: 20)),
      title: Text(displayName, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        subtitleParts.join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: OutlinedButton(
        onPressed: () => _confirmUnblock(
          context,
          deviceId: peer.deviceId,
          displayName: displayName,
        ),
        child: const Text('解除拉黑'),
      ),
    );
  }

  Future<void> _confirmUnblock(
    BuildContext context, {
    required String deviceId,
    required String displayName,
  }) async {
    final confirmed =
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
    if (!confirmed) return;
    await controller.setBlocked(deviceId, false);
  }
}

enum _PrivacySubPage { none, bossKeyShortcut, blockedPeers }

/// 主界面右侧嵌入式设置内容区：配合侧边栏分类快捷切换，二级页也在右侧原地展示。
class SettingsSectionPane extends StatefulWidget {
  const SettingsSectionPane({
    super.key,
    required this.controller,
    required this.section,
  });

  final AppController controller;
  final SettingsSection section;

  @override
  State<SettingsSectionPane> createState() => _SettingsSectionPaneState();
}

class _SettingsSectionPaneState extends State<SettingsSectionPane> {
  _PrivacySubPage _privacySubPage = _PrivacySubPage.none;

  @override
  void didUpdateWidget(covariant SettingsSectionPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.section != widget.section) {
      _privacySubPage = _PrivacySubPage.none;
    }
  }

  @override
  Widget build(BuildContext context) {
    final Widget child;
    if (widget.section == SettingsSection.privacy &&
        _privacySubPage == _PrivacySubPage.bossKeyShortcut) {
      child = BossKeyShortcutPage(
        key: const ValueKey('settings-sub-bosskey'),
        controller: widget.controller,
        onBack: () => setState(() => _privacySubPage = _PrivacySubPage.none),
      );
    } else if (widget.section == SettingsSection.privacy &&
        _privacySubPage == _PrivacySubPage.blockedPeers) {
      child = BlockedPeersPage(
        key: const ValueKey('settings-sub-blocked'),
        controller: widget.controller,
        onBack: () => setState(() => _privacySubPage = _PrivacySubPage.none),
      );
    } else {
      child = AnimatedBuilder(
        key: ValueKey('settings-main-${widget.section.name}'),
        animation: widget.controller,
        builder: (context, _) => Column(
          children: [
            Material(
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
                      widget.section.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      widget.section.subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 760),
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
                    children: _buildSectionBody(context),
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    }

    final isSubPage = _privacySubPage != _PrivacySubPage.none;
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
                begin: isSubPage
                    ? const Offset(0.06, 0)
                    : const Offset(0, 0.035),
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

  List<Widget> _buildSectionBody(BuildContext context) {
    final controller = widget.controller;
    return switch (widget.section) {
      SettingsSection.lan => [
        Card(
          child: SwitchListTile(
            secondary: const Icon(Icons.wifi_find_outlined),
            title: const Text('在线探测'),
            subtitle: const Text(
              '开启后与同一局域网内的 NekoChat 设备保持在线探测、互相可见；关闭后将无法收发消息',
            ),
            value: controller.lanDiscoveryEnabled,
            onChanged: controller.setLanDiscoveryEnabled,
          ),
        ),
        const SizedBox(height: 12),
        PairingCodeCard(controller: controller),
        const SizedBox(height: 12),
        Card(
          child: SwitchListTile(
            secondary: const Icon(Icons.person_off_outlined),
            title: const Text('屏蔽加好友申请'),
            subtitle: const Text(
              '开启后忽略陌生人的加好友申请；用你口令来加你的人、以及已验证好友不受影响',
            ),
            value: controller.blockFriendRequests,
            onChanged: controller.setBlockFriendRequests,
          ),
        ),
      ],
      SettingsSection.appearance => [
        AppearanceSettingsCards(controller: controller),
      ],
      SettingsSection.privacy => [
        Card(
          child: Column(
            children: [
              SwitchListTile(
                secondary: const Icon(Icons.visibility_off_outlined),
                title: const Text('老板键'),
                subtitle: const Text('开启全局快捷键隐藏或恢复应用'),
                value: controller.bossKeyEnabled,
                onChanged: controller.setBossKeyEnabled,
              ),
              const Divider(height: 1, indent: 56),
              ListTile(
                leading: const Icon(Icons.keyboard_outlined),
                title: const Text('快捷键'),
                subtitle: Text(controller.bossKeyShortcut.displayLabel),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => setState(
                  () => _privacySubPage = _PrivacySubPage.bossKeyShortcut,
                ),
              ),
              const Divider(height: 1, indent: 56),
              SwitchListTile(
                secondary: const Icon(Icons.notifications_active_outlined),
                title: const Text('隐藏后仍然弹出通知'),
                subtitle: const Text('老板键隐藏窗口后，新消息仍显示 Windows 通知'),
                value: controller.bossKeyNotifyWhenHidden,
                onChanged: controller.setBossKeyNotifyWhenHidden,
              ),
              if (controller.bossKeyError != null) ...[
                const Divider(height: 1, indent: 56),
                ListTile(
                  leading: Icon(
                    Icons.warning_amber_rounded,
                    color: Theme.of(context).colorScheme.error,
                  ),
                  title: Text(
                    controller.bossKeyError!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 10, 16, 0),
          child: Text(
            '隐藏后不显示任务栏入口或系统通知，再按当前快捷键 '
            '或重新启动 NekoChat 即可恢复。进程仍会在任务管理器中显示。',
            style: TextStyle(color: Colors.black54, fontSize: 12),
          ),
        ),
        const SizedBox(height: 16),
        Card(
          child: ListTile(
            leading: const Icon(Icons.block_outlined),
            title: const Text('黑名单'),
            subtitle: Text(
              controller.blockedPeers.isEmpty
                  ? '暂无已拉黑的联系人'
                  : '已拉黑 ${controller.blockedPeers.length} 人，可随时解除拉黑',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => setState(
              () => _privacySubPage = _PrivacySubPage.blockedPeers,
            ),
          ),
        ),
      ],
      SettingsSection.files => [
        Card(
          child: Column(
            children: [
              SwitchListTile(
                secondary: const Icon(Icons.download_outlined),
                title: const Text('自动接收文件'),
                subtitle: const Text('小文件自动下载，大文件仍需手动确认'),
                value: controller.autoReceiveFiles,
                onChanged: controller.setAutoReceiveFiles,
              ),
              const Divider(height: 1, indent: 56),
              ListTile(
                leading: const Icon(Icons.data_usage_outlined),
                title: const Text('自动接收大小上限'),
                subtitle: Text(
                  '小于 ${_formatMegabytes(controller.autoReceiveFileLimitBytes)} MB '
                  '的文件自动接收；达到上限后需要确认',
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '${_formatMegabytes(controller.autoReceiveFileLimitBytes)} MB',
                    ),
                    const SizedBox(width: 4),
                    const Icon(Icons.chevron_right),
                  ],
                ),
                onTap: () =>
                    SettingsPage(controller: controller)
                        ._showAutoReceiveLimitDialog(context),
              ),
            ],
          ),
        ),
      ],
      SettingsSection.notifications => [
        _NotificationSettingsCard(controller: controller),
      ],
      SettingsSection.storage => [
        Card(
          child: ListTile(
            leading: const Icon(Icons.folder_outlined),
            title: const Text('数据文件夹'),
            subtitle: Text(
              controller.dataDirectory ?? '数据目录尚未就绪',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: const Icon(Icons.open_in_new, size: 20),
            onTap: controller.dataDirectory == null
                ? null
                : controller.openDataDirectory,
          ),
        ),
        const SizedBox(height: 12),
        _BackupRestoreCard(controller: controller),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 10, 16, 0),
          child: Text(
            '聊天记录、身份数据、收藏表情包和已接收附件都保存在本机；定期备份可避免重置或换机导致数据丢失。',
            style: TextStyle(color: Colors.black54, fontSize: 12),
          ),
        ),
        const SizedBox(height: 28),
        const SettingsVersionFooter(),
      ],
    };
  }
}

class _BackupRestoreCard extends StatelessWidget {
  const _BackupRestoreCard({
    required this.controller,
    this.popRoutesOnRestore = false,
  });

  final AppController controller;
  final bool popRoutesOnRestore;

  @override
  Widget build(BuildContext context) {
    final busy = controller.backupInProgress || controller.restoreInProgress;
    final canBackup = !busy && controller.dataDirectory != null;
    final stickerCount = controller.favoriteStickers.length;
    return Card(
      child: Column(
        children: [
          ListTile(
            key: const ValueKey('settings-backup-tile'),
            leading: const Icon(Icons.backup_outlined),
            title: const Text('备份数据'),
            subtitle: Text(
              stickerCount > 0
                  ? '打包身份、聊天记录、设置与全部 $stickerCount 个收藏表情'
                  : '打包身份、聊天记录、设置与收藏表情，防止重置丢失',
            ),
            trailing: controller.backupInProgress
                ? const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.chevron_right),
            enabled: canBackup,
            onTap: canBackup
                ? () => runCreateBackupFlow(context, controller)
                : null,
          ),
          const Divider(height: 1, indent: 56),
          ListTile(
            key: const ValueKey('settings-restore-tile'),
            leading: const Icon(Icons.restore_outlined),
            title: const Text('还原数据'),
            subtitle: const Text('从 .nekobackup 备份文件恢复全部数据与表情包'),
            trailing: controller.restoreInProgress
                ? const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.chevron_right),
            enabled: !busy,
            onTap: busy
                ? null
                : () => runRestoreBackupFlow(
                    context,
                    controller,
                    popRoutesOnSuccess: popRoutesOnRestore,
                  ),
          ),
        ],
      ),
    );
  }
}

class _NotificationSettingsCard extends StatelessWidget {
  const _NotificationSettingsCard({required this.controller});

  final AppController controller;

  Widget _styledDropdown<T>({
    required BuildContext context,
    required T value,
    required bool enabled,
    required List<DropdownMenuItem<T>> items,
    required ValueChanged<T?> onChanged,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      decoration: BoxDecoration(
        color: enabled
            ? colorScheme.surfaceContainerLow
            : colorScheme.surfaceContainerLowest,
        border: Border.all(
          color: enabled
              ? colorScheme.outlineVariant
              : colorScheme.outlineVariant.withValues(alpha: 0.45),
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: value,
          isDense: true,
          borderRadius: BorderRadius.circular(8),
          focusColor: Colors.transparent,
          items: items,
          onChanged: enabled ? onChanged : null,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final enabled = controller.windowsNotificationsEnabled;
    final isStandalone =
        controller.notificationMode == NotificationMode.standalone;
    return Card(
      child: Column(
        children: [
          SwitchListTile(
            secondary: const Icon(Icons.notifications_outlined),
            title: const Text('开启消息通知'),
            subtitle: const Text('在后台或查看其他会话时提醒新消息'),
            value: enabled,
            onChanged: controller.setWindowsNotificationsEnabled,
          ),
          const Divider(height: 1, indent: 56),
          ListTile(
            enabled: enabled,
            leading: const Icon(Icons.picture_in_picture_alt_outlined),
            title: const Text('通知样式'),
            subtitle: Text(controller.notificationMode.description),
            trailing: _styledDropdown<NotificationMode>(
              context: context,
              value: controller.notificationMode,
              enabled: enabled,
              onChanged: (value) {
                if (value != null) {
                  controller.setNotificationMode(value);
                }
              },
              items: [
                for (final mode in NotificationMode.values)
                  DropdownMenuItem(value: mode, child: Text(mode.label)),
              ],
            ),
          ),
          if (isStandalone) ...[
            const Divider(height: 1, indent: 56),
            ListTile(
              enabled: enabled,
              leading: const Icon(Icons.crop_free_outlined),
              title: const Text('弹窗位置'),
              subtitle: const Text('独立通知浮窗在屏幕上的停靠角落'),
              trailing: _styledDropdown<NotificationAnchor>(
                context: context,
                value: controller.notificationAnchor,
                enabled: enabled,
                onChanged: (value) {
                  if (value != null) {
                    controller.setNotificationAnchor(value);
                  }
                },
                items: [
                  for (final anchor in NotificationAnchor.values)
                    DropdownMenuItem(
                      value: anchor,
                      child: Text(anchor.label),
                    ),
                ],
              ),
            ),
          ],
          const Divider(height: 1, indent: 56),
          ListTile(
            enabled: enabled,
            leading: const Icon(Icons.notification_add_outlined),
            title: const Text('发送测试通知'),
            subtitle: Text(
              !enabled
                  ? '开启通知后可用'
                  : isStandalone
                  ? '在屏幕${controller.notificationAnchor.label}弹出独立通知预览'
                  : '验证 Windows 系统通知是否正常',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: enabled ? controller.showTestNotification : null,
          ),
        ],
      ),
    );
  }
}
