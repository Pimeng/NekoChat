import 'package:material_ui/material_ui.dart';

import '../../app/app_controller.dart';
import '../../core/backup/data_backup_service.dart';
import 'smooth_dialog.dart';

/// 引导用户创建本地数据备份（含全部收藏表情包及可选聊天附件）。
Future<void> runCreateBackupFlow(
  BuildContext context,
  AppController controller,
) async {
  var includeAttachments = true;
  final confirmed = await showNekoDialog<bool>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (context, setDialogState) => AlertDialog(
        title: const Text('备份本地数据'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '将本机身份密钥、聊天记录、应用设置以及全部 ${controller.favoriteStickers.length} 个收藏表情包（含备注与排序）打包为单个 .$backupFileExtension 备份文件，便于重置或换机后一键还原。',
              ),
              const SizedBox(height: 12),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: const Text('同时备份已接收的聊天图片与文件'),
                subtitle: const Text('取消勾选可减小备份体积，收藏的表情包始终会被备份'),
                value: includeAttachments,
                onChanged: (value) =>
                    setDialogState(() => includeAttachments = value ?? true),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('选择保存位置'),
          ),
        ],
      ),
    ),
  );
  if (confirmed != true || !context.mounted) return;

  final destinationPath = await controller.pickBackupDestinationPath();
  if (destinationPath == null || !context.mounted) return;

  try {
    final manifest = await controller.createBackup(
      destinationPath: destinationPath,
      includeAttachments: includeAttachments,
    );
    if (!context.mounted) return;
    await showNekoDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('数据备份完成'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _SummaryRow('收藏表情包', '${manifest.stickerCount} 个'),
              _SummaryRow(
                '聊天图片与文件',
                manifest.includesAttachments ? '已包含' : '未包含',
              ),
              _SummaryRow('原始数据大小', formatBackupBytes(manifest.totalBytes)),
              const SizedBox(height: 10),
              Text(
                '保存位置：$destinationPath',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('完成'),
          ),
        ],
      ),
    );
  } on Object catch (error) {
    if (!context.mounted) return;
    await _showBackupErrorDialog(context, title: '备份失败', error: error);
  }
}

/// 引导用户从 `.nekobackup` 文件还原全部本地数据。
///
/// 还原成功后返回 `true`，取消或失败返回 `false`。
Future<bool> runRestoreBackupFlow(
  BuildContext context,
  AppController controller, {
  bool popRoutesOnSuccess = false,
}) async {
  final sourcePath = await controller.pickBackupFilePath();
  if (sourcePath == null || !context.mounted) return false;

  final BackupManifest manifest;
  try {
    manifest = await controller.inspectBackup(sourcePath);
  } on Object catch (error) {
    if (context.mounted) {
      await _showBackupErrorDialog(context, title: '无法读取备份文件', error: error);
    }
    return false;
  }
  if (!context.mounted) return false;

  final confirmed = await showNekoDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('确认还原数据？'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _SummaryRow('备份时间', _formatBackupTime(manifest.createdAt)),
            if (manifest.displayName != null &&
                manifest.displayName!.isNotEmpty)
              _SummaryRow('备份昵称', manifest.displayName!),
            _SummaryRow('收藏表情包', '${manifest.stickerCount} 个'),
            _SummaryRow(
              '聊天图片与文件',
              manifest.includesAttachments ? '已包含' : '未包含',
            ),
            _SummaryRow('原始数据大小', formatBackupBytes(manifest.totalBytes)),
            const SizedBox(height: 12),
            Text(
              '还原将覆盖当前本机数据（包括聊天记录、设置与收藏表情），完成后需使用该备份对应的本地密码重新解锁。',
              style: TextStyle(
                color: Theme.of(context).colorScheme.error,
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text('立即还原'),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return false;

  try {
    await controller.restoreFromBackup(sourcePath);
    if (popRoutesOnSuccess && context.mounted) {
      Navigator.of(context).popUntil((route) => route.isFirst);
    }
    return true;
  } on Object catch (error) {
    if (context.mounted) {
      await _showBackupErrorDialog(context, title: '还原失败', error: error);
    }
    return false;
  }
}

Future<void> _showBackupErrorDialog(
  BuildContext context, {
  required String title,
  required Object error,
}) => showNekoDialog<void>(
  context: context,
  builder: (dialogContext) => AlertDialog(
    title: Text(title),
    content: SizedBox(
      width: 380,
      child: Text(error is BackupException ? error.message : error.toString()),
    ),
    actions: [
      FilledButton(
        onPressed: () => Navigator.of(dialogContext).pop(),
        child: const Text('知道了'),
      ),
    ],
  ),
);

class _SummaryRow extends StatelessWidget {
  const _SummaryRow(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          SizedBox(
            width: 108,
            child: Text(
              label,
              style: TextStyle(color: colorScheme.onSurfaceVariant),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontWeight: FontWeight.w500),
            ),
          ),
        ],
      ),
    );
  }
}

String _formatBackupTime(DateTime time) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${time.year}-${two(time.month)}-${two(time.day)} '
      '${two(time.hour)}:${two(time.minute)}';
}

String formatBackupBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}
