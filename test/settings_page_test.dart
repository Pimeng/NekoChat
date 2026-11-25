import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neko_chat/app/app_controller.dart';
import 'package:neko_chat/core/backup/data_backup_service.dart';
import 'package:neko_chat/core/models/models.dart';
import 'package:neko_chat/features/onboarding/auth_page.dart';
import 'package:neko_chat/features/settings/settings_page.dart';

class _BackupTestController extends AppController {
  _BackupTestController({this.fakeBackupPath}) {
    dataDirectory = r'D:\fake\neko_chat_data';
    stage = AppStage.ready;
  }

  final String? fakeBackupPath;
  bool? lastIncludeAttachments;
  String? lastRestoredPath;

  @override
  Future<String?> pickBackupDestinationPath() async => fakeBackupPath;

  @override
  Future<String?> pickBackupFilePath() async => fakeBackupPath;

  @override
  Future<BackupManifest> inspectBackup(String sourcePath) async =>
      BackupManifest(
        formatVersion: 1,
        createdAt: DateTime(2026, 11, 25, 22, 30),
        displayName: '测试猫猫',
        includesAttachments: true,
        stickerCount: 12,
        fileCount: 15,
        totalBytes: 3 * 1024 * 1024,
        entries: const [],
      );

  @override
  Future<BackupManifest> createBackup({
    required String destinationPath,
    bool includeAttachments = true,
  }) async {
    lastIncludeAttachments = includeAttachments;
    return inspectBackup(destinationPath);
  }

  @override
  Future<BackupManifest> restoreFromBackup(String sourcePath) async {
    lastRestoredPath = sourcePath;
    stage = AppStage.locked;
    authNoticeMessage = '已从备份还原数据（含 12 个收藏表情），请输入该备份的密码解锁';
    notifyListeners();
    return inspectBackup(sourcePath);
  }
}

class _BlacklistTestController extends AppController {
  @override
  Future<void> setBlocked(String deviceId, bool blocked) async {
    final existing = trustedPeers[deviceId];
    if (existing == null) return;
    trustedPeers[deviceId] = TrustedPeer(
      deviceId: existing.deviceId,
      displayName: existing.displayName,
      lastKnownIp: existing.lastKnownIp,
      verifiedAt: existing.verifiedAt,
      blocked: blocked,
    );
    notifyListeners();
  }
}

void main() {
  testWidgets('启用交流开关默认开启，子项拒绝所有新申请默认关闭', (tester) async {
    final controller = AppController();
    await tester.pumpWidget(
      MaterialApp(home: SettingsPage(controller: controller)),
    );

    expect(find.text('在线探测'), findsWidgets);
    expect(find.text('启用交流'), findsOneWidget);
    expect(find.text('拒绝所有新申请'), findsOneWidget);
    expect(
      find.text(
        '开启后与同一局域网内的 NekoChat 设备保持在线探测、互相可见；关闭后将无法收发消息',
      ),
      findsOneWidget,
    );
    expect(
      tester
          .widget<SwitchListTile>(
            find.widgetWithText(SwitchListTile, '启用交流'),
          )
          .value,
      isTrue,
    );
    expect(
      tester
          .widget<SwitchListTile>(
            find.widgetWithText(SwitchListTile, '拒绝所有新申请'),
          )
          .value,
      isFalse,
    );
  });

  testWidgets('文件接收设置显示大小上限并校验输入范围', (tester) async {
    await tester.binding.setSurfaceSize(const Size(373, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = AppController();
    await tester.pumpWidget(
      MaterialApp(home: SettingsPage(controller: controller)),
    );

    await tester.scrollUntilVisible(find.text('自动接收大小上限'), 200);
    await tester.pumpAndSettle();
    expect(find.text('自动接收大小上限'), findsOneWidget);
    expect(find.text('10 MB'), findsOneWidget);
    await tester.tap(find.text('自动接收大小上限'));
    await tester.pumpAndSettle();
    final helper = tester.widget<Text>(find.text('可设置 1～512 MB，仅影响是否自动接收'));
    expect(helper.maxLines, 2);
    await tester.enterText(find.byType(TextFormField), '0');
    await tester.tap(find.text('保存'));
    await tester.pump();
    expect(find.text('请输入 1～512 之间的整数'), findsOneWidget);
  });

  testWidgets('设置页面底部显示当前构建版本', (tester) async {
    await tester.binding.setSurfaceSize(const Size(373, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = AppController();
    await tester.pumpWidget(
      MaterialApp(home: SettingsPage(controller: controller)),
    );

    expect(appBuildName, isNotNull);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('settings-version-footer')),
      300,
    );
    expect(find.text('NekoChat · 当前版本 $appBuildName'), findsOneWidget);
  });

  testWidgets('快捷键二级页可录入新组合', (tester) async {
    final controller = AppController();
    await tester.pumpWidget(
      MaterialApp(home: SettingsPage(controller: controller)),
    );

    await tester.scrollUntilVisible(find.text('快捷键'), 200);
    await tester.pumpAndSettle();
    expect(find.text('Alt + F'), findsOneWidget);
    await tester.tap(find.text('快捷键'));
    await tester.pumpAndSettle();
    expect(find.text('老板键快捷键'), findsOneWidget);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();

    expect(find.text('Ctrl + Shift + K'), findsOneWidget);
    expect(find.text('已记录，点击右上角保存'), findsOneWidget);
  });

  testWidgets('设置页黑名单二级页可查看并解除拉黑联系人', (tester) async {
    final controller = _BlacklistTestController();
    controller.trustedPeers['peer-blocked-1'] = TrustedPeer(
      deviceId: 'peer-blocked-1',
      displayName: '访客设备',
      lastKnownIp: '192.168.1.88',
      verifiedAt: DateTime(2026, 11, 21),
      blocked: true,
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(home: SettingsPage(controller: controller)),
    );

    await tester.scrollUntilVisible(find.text('黑名单'), 200);
    await tester.pumpAndSettle();
    expect(find.text('黑名单'), findsOneWidget);
    expect(find.text('已拉黑 1 人，可随时解除拉黑'), findsOneWidget);

    await tester.tap(find.text('黑名单'));
    await tester.pumpAndSettle();

    expect(find.text('访客设备'), findsOneWidget);
    await tester.tap(find.widgetWithText(OutlinedButton, '解除拉黑'));
    await tester.pumpAndSettle();
    expect(find.text('解除拉黑？'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '解除拉黑'));
    await tester.pumpAndSettle();

    expect(controller.blockedPeers, isEmpty);
    expect(find.text('黑名单为空'), findsOneWidget);
  });

  testWidgets('存储设置页支持触发备份与还原确认流程', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = _BackupTestController(
      fakeBackupPath: r'D:\Backups\demo.nekobackup',
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SettingsSectionPane(
            controller: controller,
            section: SettingsSection.storage,
          ),
        ),
      ),
    );

    expect(find.text('备份数据'), findsOneWidget);
    expect(find.text('还原数据'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('settings-backup-tile')));
    await tester.pumpAndSettle();
    expect(find.text('备份本地数据'), findsOneWidget);
    await tester.tap(find.text('同时备份已接收的聊天图片与文件'));
    await tester.pump();
    await tester.tap(find.text('选择保存位置'));
    await tester.pumpAndSettle();

    expect(controller.lastIncludeAttachments, isFalse);
    expect(find.text('数据备份完成'), findsOneWidget);
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('settings-restore-tile')));
    await tester.pumpAndSettle();
    expect(find.text('确认还原数据？'), findsOneWidget);
    expect(find.text('12 个'), findsOneWidget);
    await tester.tap(find.text('立即还原'));
    await tester.pumpAndSettle();
    expect(controller.lastRestoredPath, r'D:\Backups\demo.nekobackup');
  });

  testWidgets('首次引导页提供从备份还原入口并在还原后显示提示', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = _BackupTestController(
      fakeBackupPath: r'D:\Backups\demo.nekobackup',
    )..stage = AppStage.setup;
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: AnimatedBuilder(
          animation: controller,
          builder: (context, _) =>
              AuthPage(controller: controller, windowControls: false),
        ),
      ),
    );

    expect(find.text('创建本机身份'), findsOneWidget);
    expect(find.text('从备份文件还原数据'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('auth-restore-backup-button')));
    await tester.pumpAndSettle();
    expect(find.text('确认还原数据？'), findsOneWidget);
    await tester.tap(find.text('立即还原'));
    await tester.pumpAndSettle();

    expect(controller.stage, AppStage.locked);
    expect(find.text('解锁 NekoChat'), findsOneWidget);
    expect(find.textContaining('已从备份还原数据'), findsOneWidget);
  });
}
