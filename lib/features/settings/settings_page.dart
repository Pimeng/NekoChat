import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../core/config/network_config.dart';

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
              const _SettingsSectionTitle('文件接收'),
              Card(
                child: SwitchListTile(
                  secondary: const Icon(Icons.download_outlined),
                  title: const Text('自动接收文件'),
                  subtitle: Text(
                    '自动接收小于 '
                    '${_formatMegabytes(NetworkConfig.largeFileThresholdBytes)} MB '
                    '的文件；更大文件始终需要确认',
                  ),
                  value: controller.autoReceiveFiles,
                  onChanged: controller.setAutoReceiveFiles,
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
            ],
          ),
        ),
      ),
    ),
  );
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
