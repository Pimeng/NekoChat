import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neko_chat/app/app_controller.dart';
import 'package:neko_chat/core/models/models.dart';
import 'package:neko_chat/features/settings/settings_page.dart';

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
  testWidgets('局域网相互发现开关默认开启', (tester) async {
    final controller = AppController();
    await tester.pumpWidget(
      MaterialApp(home: SettingsPage(controller: controller)),
    );

    expect(find.text('局域网相互发现'), findsOneWidget);
    expect(find.text('允许本机与同一局域网内的 NekoChat 设备相互发现'), findsOneWidget);
    expect(
      tester
          .widget<SwitchListTile>(
            find.widgetWithText(SwitchListTile, '局域网相互发现'),
          )
          .value,
      isTrue,
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
}
