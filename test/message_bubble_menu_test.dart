import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neko_chat/app/app_controller.dart';
import 'package:neko_chat/core/models/models.dart';
import 'package:neko_chat/features/chat/main_shell.dart';

/// 1×1 的透明 PNG，用来做真实的图片文件。
const _tinyPngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';

/// 构造一个只用于渲染的控制器：只填界面需要的字段，不触发任何初始化。
AppController renderOnlyController({required List<ChatMessage> messages}) {
  final now = DateTime.fromMillisecondsSinceEpoch(1000);
  final controller = AppController();
  controller.stage = AppStage.ready;
  controller.identity = LocalIdentity(
    deviceId: 'local-device',
    displayName: '我',
    createdAt: now,
    lastLoginAt: now,
  );
  controller.chats = [
    ChatSummary(
      chatId: 'chat-1',
      peerDeviceId: 'peer-device',
      displayName: '李四',
      state: ChatSessionState.active,
      sessionId: 'session-1',
    ),
  ];
  controller.selectedChatId = 'chat-1';
  controller.messages = messages;
  return controller;
}

void main() {
  testWidgets('纯图片气泡右键也能弹出菜单', (tester) async {
    final directory = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('neko-chat-bubble-'),
    ))!;
    addTearDown(() => directory.delete(recursive: true));
    final image = File('${directory.path}${Platform.pathSeparator}照片.png');
    await tester.runAsync(
      () => image.writeAsBytes(base64Decode(_tinyPngBase64)),
    );

    final controller = renderOnlyController(
      messages: [
        ChatMessage(
          messageId: 'm-1',
          chatId: 'chat-1',
          senderDeviceId: 'peer-device',
          content: '照片.png',
          timestamp: DateTime.fromMillisecondsSinceEpoch(1000),
          status: MessageStatus.sent,
          kind: MessageKind.image,
          fileName: '照片.png',
          filePath: image.path,
          fileSize: 68,
          mimeType: 'image/png',
        ),
      ],
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(home: MainShell(controller: controller)),
    );
    await tester.pump();

    // 图片气泡里没有可选中的文字，必须靠自绘菜单，否则右键毫无反应。
    expect(find.text('引用回复'), findsNothing);
    final imageMenuTarget = find.byWidgetPredicate(
      (widget) =>
          widget is GestureDetector && widget.onSecondaryTapDown != null,
    );
    expect(imageMenuTarget, findsOneWidget);
    await tester.tap(imageMenuTarget, buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();

    expect(find.text('复制'), findsOneWidget);
    expect(find.text('引用回复'), findsOneWidget);
    expect(find.text('打开图片'), findsOneWidget);

    // 点击空白处关闭菜单。
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(find.text('引用回复'), findsNothing);
  });

  testWidgets('文字气泡仍由框架的选择工具栏弹出合并菜单', (tester) async {
    final controller = renderOnlyController(
      messages: [
        ChatMessage(
          messageId: 'm-1',
          chatId: 'chat-1',
          senderDeviceId: 'peer-device',
          content: '你好',
          timestamp: DateTime.fromMillisecondsSinceEpoch(1000),
          status: MessageStatus.sent,
        ),
      ],
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(home: MainShell(controller: controller)),
    );
    await tester.pump();

    await tester.tap(find.text('你好'), buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();

    // 复制/全选来自框架，引用回复来自我们的菜单项。
    expect(find.text('复制'), findsOneWidget);
    expect(find.text('引用回复'), findsOneWidget);
  });

  testWidgets('两分钟内自己的消息菜单提供撤回', (tester) async {
    final controller = renderOnlyController(
      messages: [
        ChatMessage(
          messageId: 'm-recent',
          chatId: 'chat-1',
          senderDeviceId: 'local-device',
          content: '刚发出的消息',
          timestamp: DateTime.now(),
          status: MessageStatus.sent,
        ),
      ],
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(home: MainShell(controller: controller)),
    );
    await tester.tap(find.text('刚发出的消息'), buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    expect(find.text('撤回'), findsOneWidget);
  });

  testWidgets('撤回消息只显示居中的灰色提示，不显示原内容', (tester) async {
    final controller = renderOnlyController(
      messages: [
        ChatMessage(
          messageId: 'm-recalled',
          chatId: 'chat-1',
          senderDeviceId: 'local-device',
          content: '',
          timestamp: DateTime.now(),
          status: MessageStatus.recalled,
          recalledAt: DateTime.now(),
          recalledByDeviceId: 'local-device',
        ),
      ],
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(home: MainShell(controller: controller)),
    );
    expect(find.text('你撤回了一条消息'), findsOneWidget);
    expect(find.text('引用回复'), findsNothing);
    expect(find.byType(SelectionArea), findsNothing);
  });
}
