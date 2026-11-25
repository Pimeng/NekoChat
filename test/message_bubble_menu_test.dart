import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
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
      MaterialApp(
        home: AnimatedBuilder(
          animation: controller,
          builder: (context, _) => MainShell(controller: controller),
        ),
      ),
    );
    await tester.pump();

    // 图片气泡里没有可选中的文字，同样由整行监听弹出自绘菜单。
    expect(find.text('引用回复'), findsNothing);
    await tester.tap(
      find.byType(Image),
      buttons: kSecondaryMouseButton,
      warnIfMissed: false,
    );
    await tester.pumpAndSettle();

    expect(find.text('复制'), findsOneWidget);
    expect(find.text('引用回复'), findsOneWidget);
    expect(find.text('打开图片'), findsOneWidget);

    // 点击空白处关闭菜单。
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(find.text('引用回复'), findsNothing);
  });

  testWidgets('文字气泡右键弹出统一菜单，点击任意空白处即可关闭', (tester) async {
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
      MaterialApp(
        home: AnimatedBuilder(
          animation: controller,
          builder: (context, _) => MainShell(controller: controller),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('你好'), buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();

    expect(find.text('复制'), findsOneWidget);
    expect(find.text('引用回复'), findsOneWidget);

    // 点击窗口其他空白区域关闭菜单。
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(find.text('引用回复'), findsNothing);
  });

  testWidgets('在消息所在行的空白处右键也能弹出菜单', (tester) async {
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
      MaterialApp(
        home: AnimatedBuilder(
          animation: controller,
          builder: (context, _) => MainShell(controller: controller),
        ),
      ),
    );
    await tester.pump();

    final row = tester.getRect(find.byType(MessageBubble));
    // 对方消息靠左，行的右侧大片是空白。
    await tester.tapAt(
      Offset(row.right - 20, row.center.dy),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
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
      MaterialApp(
        home: AnimatedBuilder(
          animation: controller,
          builder: (context, _) => MainShell(controller: controller),
        ),
      ),
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
      MaterialApp(
        home: AnimatedBuilder(
          animation: controller,
          builder: (context, _) => MainShell(controller: controller),
        ),
      ),
    );
    expect(find.text('你撤回了一条消息'), findsOneWidget);
    expect(find.text('引用回复'), findsNothing);
    expect(find.byType(SelectionArea), findsNothing);
  });

  test('居中时间条按 5 分钟窗口与跨天自动聚合', () {
    ChatMessage msg(String id, DateTime ts) => ChatMessage(
      messageId: id,
      chatId: 'chat-1',
      senderDeviceId: 'peer-a',
      kind: MessageKind.text,
      content: id,
      timestamp: ts,
      status: MessageStatus.sent,
    );

    final messages = [
      msg('m1', DateTime(2026, 11, 25, 19, 35, 10)),
      msg('m2', DateTime(2026, 11, 25, 19, 37, 00)),
      msg('m3', DateTime(2026, 11, 25, 19, 40, 10)),
      msg('m4', DateTime(2026, 11, 26, 0, 1, 0)),
    ];

    expect(computeMessageTimeHeaderIndices(messages), {0, 2, 3});
    expect(
      formatMessageGroupTime(
        DateTime(2026, 11, 25, 19, 35),
        now: DateTime(2026, 11, 26, 10, 0),
      ),
      '昨天 19:35',
    );
    expect(
      formatMessageGroupTime(
        DateTime(2026, 11, 26, 9, 5),
        now: DateTime(2026, 11, 26, 10, 0),
      ),
      '09:05',
    );
    expect(
      formatMessageExactTime(
        DateTime(2026, 11, 25, 20, 12, 26),
        now: DateTime(2026, 11, 26, 10, 0),
      ),
      '11-25 20:12:26',
    );
  });

  testWidgets('相邻消息共用居中时间条，悬停约 2 秒后在头衔旁显示精确时间', (tester) async {
    final t1 = DateTime(2026, 11, 25, 20, 12, 26);
    final t2 = DateTime(2026, 11, 25, 20, 14, 5);
    final controller = renderOnlyController(
      messages: [
        ChatMessage(
          messageId: 'msg-t1',
          chatId: 'chat-1',
          senderDeviceId: 'peer-device',
          kind: MessageKind.text,
          content: '第一条消息',
          timestamp: t1,
          status: MessageStatus.sent,
        ),
        ChatMessage(
          messageId: 'msg-t2',
          chatId: 'chat-1',
          senderDeviceId: 'peer-device',
          kind: MessageKind.text,
          content: '两分钟后的第二条消息',
          timestamp: t2,
          status: MessageStatus.sent,
        ),
      ],
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: AnimatedBuilder(
          animation: controller,
          builder: (context, _) => MainShell(controller: controller),
        ),
      ),
    );

    // 两条消息在 5 分钟内，只显示 1 条居中时间分隔条
    expect(find.byType(MessageTimeDivider), findsOneWidget);
    final exactTimeText = formatMessageExactTime(t1);
    expect(find.text(exactTimeText), findsNothing);

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);

    // 悬停在第一条消息上 1 秒时还不显示，满 2 秒后淡入显示精确时间
    await gesture.moveTo(tester.getCenter(find.text('第一条消息')));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text(exactTimeText), findsNothing);

    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(find.text(exactTimeText), findsOneWidget);

    // 鼠标移出后精确时间隐藏
    await gesture.moveTo(Offset.zero);
    await tester.pumpAndSettle();
    expect(find.text(exactTimeText), findsNothing);
  });

  testWidgets('已接收文件气泡显示另存为按钮和右键菜单，saveAttachmentAs 避免覆盖重名文件', (tester) async {
    final sourceDir = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('neko-save-as-src-'),
    ))!;
    final targetDir = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('neko-save-as-dst-'),
    ))!;
    addTearDown(() async {
      await sourceDir.delete(recursive: true);
      await targetDir.delete(recursive: true);
    });
    final sourceFile = File(
      '${sourceDir.path}${Platform.pathSeparator}report.txt',
    );
    await tester.runAsync(() => sourceFile.writeAsString('hello neko'));

    final fileMessage = ChatMessage(
      messageId: 'msg-file-1',
      chatId: 'chat-1',
      senderDeviceId: 'peer-device',
      kind: MessageKind.file,
      content: 'report.txt',
      fileName: 'report.txt',
      filePath: sourceFile.path,
      fileSize: 10,
      mimeType: 'text/plain',
      timestamp: DateTime(2026, 11, 26, 0, 30),
      status: MessageStatus.sent,
    );
    final controller = renderOnlyController(messages: [fileMessage]);
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: AnimatedBuilder(
          animation: controller,
          builder: (context, _) => MainShell(controller: controller),
        ),
      ),
    );

    expect(find.text('打开文件'), findsOneWidget);
    expect(find.text('另存为'), findsOneWidget);

    await tester.tapAt(
      tester.getCenter(find.text('report.txt')),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
    expect(find.text('另存为…'), findsOneWidget);

    final firstSaved = await tester.runAsync(
      () => controller.saveAttachmentAs(
        fileMessage,
        destinationDirectory: targetDir.path,
      ),
    );
    expect(firstSaved, isNotNull);
    expect(File(firstSaved!).readAsStringSync(), 'hello neko');

    final secondSaved = await tester.runAsync(
      () => controller.saveAttachmentAs(
        fileMessage,
        destinationDirectory: targetDir.path,
      ),
    );
    expect(secondSaved, isNotNull);
    expect(secondSaved, isNot(firstSaved));
    expect(secondSaved!, endsWith('report (1).txt'));
    expect(File(secondSaved).readAsStringSync(), 'hello neko');
  });

  testWidgets('自己撤回的消息在 1 分钟内显示可点击的重新编辑，超时后自动隐藏', (tester) async {
    final now = DateTime.now();
    final recalledMessage = ChatMessage(
      messageId: 'msg-reedit-1',
      chatId: 'chat-1',
      senderDeviceId: 'local-device',
      kind: MessageKind.text,
      content: '原本要发的话',
      timestamp: now.subtract(const Duration(seconds: 10)),
      status: MessageStatus.sent,
    ).asRecalled(byDeviceId: 'local-device', at: now);
    final controller = renderOnlyController(messages: [recalledMessage]);
    controller.peers = [
      DiscoveredPeer(
        deviceId: 'peer-device',
        displayName: '李四',
        ip: '192.168.1.2',
        port: 23333,
        lastSeen: now,
        trusted: true,
        online: true,
      ),
    ];
    controller.registerRecallReEditDraft(
      'msg-reedit-1',
      '原本要发的话',
      recalledAt: now,
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: AnimatedBuilder(
          animation: controller,
          builder: (context, _) => MainShell(controller: controller),
        ),
      ),
    );

    expect(find.text('你撤回了一条消息'), findsOneWidget);
    expect(find.text('重新编辑'), findsOneWidget);

    await tester.tap(find.text('重新编辑'));
    await tester.pump();
    final composerField = tester.widget<TextField>(find.byType(TextField).last);
    expect(composerField.controller?.text, '原本要发的话');

    // 超过 1 分钟后「重新编辑」自动消失
    await tester.pump(const Duration(minutes: 1, seconds: 1));
    await tester.pump();
    expect(find.text('重新编辑'), findsNothing);
  });
}
