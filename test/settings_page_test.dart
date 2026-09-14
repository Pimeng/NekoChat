import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neko_chat/app/app_controller.dart';
import 'package:neko_chat/features/settings/settings_page.dart';

void main() {
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
}
