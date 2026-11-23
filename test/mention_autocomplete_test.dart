import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neko_chat/features/chat/mention_autocomplete.dart';

void main() {
  const candidates = [
    MentionCandidate(
      deviceId: 'peer-1',
      displayName: '产品小李',
      insertionName: '李四',
      originalName: '李四',
    ),
    MentionCandidate(
      deviceId: 'peer-2',
      displayName: '王五',
      insertionName: '王五',
    ),
  ];

  Widget app({
    required TextEditingController controller,
    VoidCallback? onSend,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 500,
            child: MentionAutocomplete(
              controller: controller,
              focusNode: FocusNode(),
              enabled: true,
              onSend: onSend ?? () {},
              loadCandidates: () async => candidates,
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('输入 @ 弹出成员列表，方向键和回车完成选择', (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    var sendCount = 0;
    await tester.pumpWidget(
      app(controller: controller, onSend: () => sendCount++),
    );
    await tester.tap(find.byType(TextField));
    await tester.enterText(find.byType(TextField), '@');
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('mention-suggestions')), findsOneWidget);
    expect(find.text('产品小李'), findsOneWidget);
    expect(find.text('王五'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(controller.text, '@王五 ');
    expect(sendCount, 0);
    expect(find.byKey(const ValueKey('mention-suggestions')), findsNothing);
  });

  testWidgets('输入昵称可筛选并用鼠标选择，插入成员原昵称', (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(app(controller: controller));
    await tester.tap(find.byType(TextField));
    await tester.enterText(find.byType(TextField), '请看 @产品');
    await tester.pumpAndSettle();

    expect(find.text('产品小李'), findsOneWidget);
    expect(find.text('王五'), findsNothing);
    await tester.tap(find.text('产品小李'));
    await tester.pump();
    expect(controller.text, '请看 @李四 ');
  });
}
