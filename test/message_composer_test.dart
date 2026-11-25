import 'package:material_ui/material_ui.dart';
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

  testWidgets('外部 FocusNode 可以直接聚焦输入框', (tester) async {
    final controller = TextEditingController();
    final focusNode = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MessageComposer(
            controller: controller,
            focusNode: focusNode,
            enabled: true,
            onSend: () {},
          ),
        ),
      ),
    );

    expect(focusNode.hasFocus, isFalse);
    // 引用回复后就是通过这种方式把光标送回输入框的。
    focusNode.requestFocus();
    await tester.pump();

    expect(focusNode.hasFocus, isTrue);
  });

  testWidgets('右下角发送按钮在有内容时可点击发送，空内容时不触发', (tester) async {
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

    await tester.tap(find.byKey(const ValueKey('composer-send-button')));
    await tester.pump();
    expect(sent, isEmpty);

    await tester.enterText(find.byType(TextField), '点击发送');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('composer-send-button')));
    await tester.pump();

    expect(sent, ['点击发送']);
    expect(controller.text, isEmpty);
  });

  testWidgets('点击发送右侧下拉可切换为 Ctrl+Enter 发送、Enter 换行', (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    final sent = <String>[];
    bool? changedValue;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MessageComposer(
            controller: controller,
            enabled: true,
            onSendOnCtrlEnterChanged: (value) => changedValue = value,
            onSend: () {
              sent.add(controller.text);
              controller.clear();
            },
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('composer-send-mode-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('按 Ctrl + Enter 键发送消息'));
    await tester.pumpAndSettle();

    expect(changedValue, isTrue);
    expect(find.text('Ctrl + Enter 发送，Enter 换行'), findsOneWidget);

    await tester.tap(find.byType(TextField));
    await tester.enterText(find.byType(TextField), '第一行');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(sent, isEmpty);
    expect(controller.text, '第一行\n');

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();

    expect(sent, ['第一行\n']);
    expect(controller.text, isEmpty);
  });
}
