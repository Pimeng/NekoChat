import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neko_chat/app/app_controller.dart';
import 'package:neko_chat/core/notifications/notification_window_channel.dart';
import 'package:neko_chat/core/notifications/standalone_notification_controller.dart';
import 'package:neko_chat/core/notifications/windows_toast_card.dart';
import 'package:neko_chat/features/settings/settings_page.dart';

void main() {
  group('StandaloneNotificationController', () {
    test('新通知置顶展示，同 identifier 覆盖更新并递增 revision，超出上限裁剪旧通知', () {
      final controller = StandaloneNotificationController(
        maxVisible: 3,
        defaultDuration: const Duration(minutes: 5),
      );
      addTearDown(controller.dispose);

      controller.show(
        identifier: 'c1',
        title: 'Alice',
        body: '第一条',
        onClick: () {},
      );
      controller.show(
        identifier: 'c2',
        title: 'Bob',
        body: '第二条',
        onClick: () {},
      );
      controller.show(
        identifier: 'c1',
        title: 'Alice',
        body: '更新后的第一条',
        onClick: () {},
      );

      expect(controller.items.length, 2);
      expect(controller.items.first.identifier, 'c1');
      expect(controller.items.first.body, '更新后的第一条');
      expect(controller.items.first.revision, 1);

      controller.show(
        identifier: 'c3',
        title: 'Carol',
        body: '第三条',
        onClick: () {},
      );
      controller.show(
        identifier: 'c4',
        title: 'Dave',
        body: '第四条',
        onClick: () {},
      );

      expect(controller.items.map((e) => e.identifier).toList(), [
        'c4',
        'c3',
        'c1',
      ]);
    });

    test('点击 activate 会触发回调并移除该通知', () async {
      final controller = StandaloneNotificationController(
        defaultDuration: const Duration(minutes: 5),
      );
      addTearDown(controller.dispose);

      var clicked = false;
      controller.show(
        identifier: 'msg-1',
        title: '林晓猫',
        body: '你好',
        onClick: () {
          clicked = true;
        },
      );

      await controller.activate('msg-1');
      expect(clicked, isTrue);
      expect(controller.isEmpty, isTrue);
    });

    test('悬停时暂停自动消失，移出后恢复倒计时', () async {
      var now = DateTime(2026, 11, 22, 12, 0, 0);
      final controller = StandaloneNotificationController(
        defaultDuration: const Duration(milliseconds: 60),
        resumeMinimumDuration: const Duration(milliseconds: 50),
        clock: () => now,
      );
      addTearDown(controller.dispose);

      controller.show(
        identifier: 'hover-1',
        title: '测试',
        body: '悬停暂停',
        onClick: () {},
      );

      controller.setHovered(true);
      await Future<void>.delayed(const Duration(milliseconds: 90));
      expect(controller.items.length, 1);

      now = now.add(const Duration(milliseconds: 90));
      controller.setHovered(false);
      await Future<void>.delayed(const Duration(milliseconds: 90));
      expect(controller.isEmpty, isTrue);
    });
  });

  group('WindowsNotificationSurface', () {
    testWidgets('单条通知展示应用名、标题、正文并响应点击与关闭', (tester) async {
      String? tappedId;
      var dismissedAll = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: WindowsNotificationSurface(
                items: [
                  StandaloneNotificationItem(
                    identifier: 'n1',
                    title: '林晓猫',
                    body: '晚上一起吃火锅吗？',
                    timestamp: DateTime(2026, 11, 22, 18, 0),
                    onClick: () {},
                  ),
                ],
                onItemTap: (id) => tappedId = id,
                onItemDismiss: (_) {},
                onDismissAll: () => dismissedAll = true,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('NekoChat'), findsOneWidget);
      expect(find.text('林晓猫'), findsOneWidget);
      expect(find.text('晚上一起吃火锅吗？'), findsOneWidget);

      await tester.tap(find.text('晚上一起吃火锅吗？'));
      expect(tappedId, 'n1');

      await tester.tap(find.byKey(const ValueKey('windows-toast-close-all')));
      expect(dismissedAll, isTrue);
    });

    testWidgets('多条堆叠时显示计数与全部清除按钮', (tester) async {
      var dismissedAll = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: WindowsNotificationSurface(
                darkMode: true,
                items: [
                  StandaloneNotificationItem(
                    identifier: 'n1',
                    title: '林晓猫',
                    body: '消息一',
                    timestamp: DateTime(2026, 11, 22, 18, 0),
                    onClick: () {},
                  ),
                  StandaloneNotificationItem(
                    identifier: 'n2',
                    title: '阿橙',
                    body: '消息二',
                    timestamp: DateTime(2026, 11, 22, 18, 1),
                    onClick: () {},
                  ),
                ],
                onItemTap: (_) {},
                onItemDismiss: (_) {},
                onDismissAll: () => dismissedAll = true,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('NekoChat · 2 条新通知'), findsOneWidget);
      expect(find.text('全部清除'), findsOneWidget);

      await tester.tap(find.text('全部清除'));
      expect(dismissedAll, isTrue);
    });

    testWidgets('在较紧凑的窗口约束 (346x104) 下渲染不溢出', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 346,
                height: 104,
                child: WindowsNotificationSurface(
                  items: [
                    StandaloneNotificationItem(
                      identifier: 'compact-1',
                      title: '林晓猫',
                      body: '这是一条来自组件预览模式的独立 Windows 通知，用于测试在紧凑高度下不会溢出。',
                      timestamp: DateTime(2026, 11, 22, 18, 2),
                      onClick: () {},
                    ),
                  ],
                  onItemTap: (_) {},
                  onItemDismiss: (_) {},
                  onDismissAll: () {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });
  });

  group('通知设置默认值', () {
    test('默认使用独立弹窗通知并停靠右下角', () {
      expect(NotificationMode.decode(null), NotificationMode.standalone);
      expect(NotificationAnchor.decode(null), NotificationAnchor.bottomRight);
    });

    testWidgets('设置页显示通知样式与弹窗位置选项', (tester) async {
      final controller = AppController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MaterialApp(home: SettingsPage(controller: controller)),
      );

      await tester.scrollUntilVisible(find.text('通知样式'), 250);
      await tester.pumpAndSettle();

      expect(find.text('通知样式'), findsOneWidget);
      expect(find.text('独立弹窗通知'), findsOneWidget);
      expect(find.text('弹窗位置'), findsOneWidget);
      expect(find.text('右下角'), findsOneWidget);
    });
  });
}
