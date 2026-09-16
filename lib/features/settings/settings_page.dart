import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/app_controller.dart';
import '../../core/boss_key/boss_key_service.dart';

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
              const _SettingsSectionTitle('局域网'),
              Card(
                child: SwitchListTile(
                  secondary: const Icon(Icons.wifi_find_outlined),
                  title: const Text('局域网相互发现'),
                  subtitle: const Text('允许本机与同一局域网内的 NekoChat 设备相互发现'),
                  value: controller.lanDiscoveryEnabled,
                  onChanged: controller.setLanDiscoveryEnabled,
                ),
              ),
              const SizedBox(height: 24),
              const _SettingsSectionTitle('隐私'),
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
                              _BossKeyShortcutPage(controller: controller),
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
              const SizedBox(height: 24),
              const _SettingsSectionTitle('文件接收'),
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
              const _SettingsSectionTitle('通知'),
              Card(
                child: Column(
                  children: [
                    SwitchListTile(
                      secondary: const Icon(Icons.notifications_outlined),
                      title: const Text('开启 Windows 通知'),
                      subtitle: const Text('在后台或查看其他会话时提醒新消息'),
                      value: controller.windowsNotificationsEnabled,
                      onChanged: controller.setWindowsNotificationsEnabled,
                    ),
                    const Divider(height: 1, indent: 56),
                    ListTile(
                      enabled: controller.windowsNotificationsEnabled,
                      leading: const Icon(Icons.notification_add_outlined),
                      title: const Text('发送测试通知'),
                      subtitle: Text(
                        controller.windowsNotificationsEnabled
                            ? '验证 Windows 系统通知是否正常'
                            : '开启通知后可用',
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: controller.windowsNotificationsEnabled
                          ? controller.showTestNotification
                          : null,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              const _SettingsSectionTitle('存储'),
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
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 10, 16, 0),
                child: Text(
                  '聊天记录、身份数据和已接收附件都保存在本机。',
                  style: TextStyle(color: Colors.black54, fontSize: 12),
                ),
              ),
              const SizedBox(height: 32),
              const _VersionFooter(),
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
    final megabytes = await showDialog<int>(
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

class _SettingsSectionTitle extends StatelessWidget {
  const _SettingsSectionTitle(this.title);

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

class _VersionFooter extends StatelessWidget {
  const _VersionFooter();

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

class _BossKeyShortcutPage extends StatefulWidget {
  const _BossKeyShortcutPage({required this.controller});

  final AppController controller;

  @override
  State<_BossKeyShortcutPage> createState() => _BossKeyShortcutPageState();
}

class _BossKeyShortcutPageState extends State<_BossKeyShortcutPage> {
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
      Navigator.of(context).pop();
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
