import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neko_chat/features/dev_preview/component_preview_app.dart';
import 'package:neko_chat/features/dev_preview/preview_app_controller.dart';
import 'package:neko_chat/features/dev_preview/preview_catalog.dart';

void main() {
  testWidgets('组件预览工作台默认展示全部组件总览并支持搜索过滤', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 860));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(const ComponentPreviewApp());
    await tester.pumpAndSettle();

    expect(find.text('NekoChat 组件预览'), findsOneWidget);
    expect(find.byKey(const ValueKey('preview-overview-list')), findsOneWidget);
    expect(find.text('完整页面（点击进入交互预览）'), findsOneWidget);
    expect(find.text('独立组件实时预览'), findsOneWidget);
    expect(find.text('热重载就绪 (按 r)'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('preview-search-field')),
      'MessageBubble',
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('preview-nav-message-bubble')), findsOneWidget);
    expect(find.byKey(const ValueKey('preview-nav-avatars')), findsNothing);
  });

  testWidgets('所有目录组件与完整页面均可正常渲染，热重载保留当前选中项并刷新计数', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 860));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final controller = PreviewAppController();
    addTearDown(controller.dispose);
    final allEntries = buildPreviewCatalog(controller, onAction: (_) {});

    await tester.pumpWidget(const ComponentPreviewApp());
    await tester.pumpAndSettle();

    for (final entry in allEntries) {
      final navFinder = find.byKey(ValueKey('preview-nav-${entry.id}'));
      await tester.ensureVisible(navFinder);
      await tester.tap(navFinder);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(
        find.byKey(ValueKey('stage-${entry.id}')),
        findsOneWidget,
        reason: '组件预览 ${entry.id} (${entry.widgetType}) 应当正常挂载',
      );
      expect(tester.takeException(), isNull);
    }

    // 模拟 Flutter Hot Reload (reassembleApplication)，验证保留选中页面且热重载计数递增。
    final lastId = allEntries.last.id;
    final reassembleFuture = tester.binding.reassembleApplication();
    await tester.pump();
    await reassembleFuture;

    expect(find.byKey(ValueKey('stage-$lastId')), findsOneWidget);
    expect(find.textContaining('热重载 #1'), findsOneWidget);
  });

  testWidgets('预览模式下的设置页和主界面可纯内存交互而不访问数据库', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 860));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(const ComponentPreviewApp());
    await tester.pumpAndSettle();

    final sidebarScrollable = find.descendant(
      of: find.byKey(const ValueKey('preview-sidebar-list')),
      matching: find.byType(Scrollable),
    );

    // 打开设置页并切换开关
    final settingsNav = find.byKey(const ValueKey('preview-nav-settings-page'));
    await tester.scrollUntilVisible(
      settingsNav,
      200,
      scrollable: sidebarScrollable,
    );
    await tester.ensureVisible(settingsNav);
    await tester.pumpAndSettle();
    await tester.tap(settingsNav);
    await tester.pumpAndSettle();

    final lanSwitch = find.widgetWithText(SwitchListTile, '局域网相互发现');
    expect(tester.widget<SwitchListTile>(lanSwitch).value, isTrue);
    await tester.tap(lanSwitch);
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(lanSwitch).value, isFalse);

    // 切换到完整主界面并验证模拟会话渲染
    final mainShellNav = find.byKey(const ValueKey('preview-nav-main-shell'));
    await tester.scrollUntilVisible(
      mainShellNav,
      -200,
      scrollable: sidebarScrollable,
    );
    await tester.ensureVisible(mainShellNav);
    await tester.pumpAndSettle();
    await tester.tap(mainShellNav);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('nav-rail-messages')), findsOneWidget);
    expect(find.byKey(const ValueKey('nav-rail-contacts')), findsOneWidget);
    expect(find.text('晓猫（前端）'), findsWidgets);
    expect(find.text('机房联调群'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
