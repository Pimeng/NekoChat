import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neko_chat/features/chat/message_composer.dart';

void main() {
  testWidgets('Enter 发送当前消息', (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    final sent = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MessageComposer(
            controller: controller,
            enabled: true,
            onSend: () {
              sent.add(controller.text);
              controller.clear();
            },
          ),
        ),
      ),
    );
    await tester.tap(find.byType(TextField));
    await tester.enterText(find.byType(TextField), '你好');

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(sent, ['你好']);
    expect(controller.text, isEmpty);
  });

  testWidgets('Ctrl+Enter 插入换行且不发送', (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    var sendCount = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MessageComposer(
            controller: controller,
            enabled: true,
            onSend: () => sendCount++,
          ),
        ),
      ),
    );
    await tester.tap(find.byType(TextField));
    await tester.enterText(find.byType(TextField), '第一行');

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();

    expect(sendCount, 0);
    expect(controller.text, '第一行\n');
  });

  testWidgets('Ctrl+V 优先处理剪贴板附件', (tester) async {
    final controller = TextEditingController(text: '保留文本');
    addTearDown(controller.dispose);
    var pasteCount = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MessageComposer(
            controller: controller,
            enabled: true,
            onSend: () {},
            onPasteAttachments: () async {
              pasteCount++;
              return true;
            },
          ),
        ),
      ),
    );
    await tester.tap(find.byType(TextField));

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();

    expect(pasteCount, 1);
    expect(controller.text, '保留文本');
  });
}
