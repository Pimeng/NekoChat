import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neko_chat/app/app_controller.dart';
import 'package:neko_chat/core/models/models.dart';
import 'package:neko_chat/features/chat/main_shell.dart';

AppController _baseController() {
  final now = DateTime.fromMillisecondsSinceEpoch(1000);
  final controller = AppController();
  controller.stage = AppStage.ready;
  controller.identity = LocalIdentity(
    deviceId: 'local-device',
    displayName: '我',
    createdAt: now,
    lastLoginAt: now,
  );
  return controller;
}

void main() {
  testWidgets('私聊优先显示人员备注，并保留原始昵称', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = _baseController();
    controller.chats = const [
      ChatSummary(
        chatId: 'chat-1',
        peerDeviceId: 'peer-1',
        displayName: '李四',
        state: ChatSessionState.active,
        sessionId: 'session-1',
      ),
    ];
    controller.selectedChatId = 'chat-1';
    controller.peerRemarks = {'peer-1': 'UI 小李'};

    await tester.pumpWidget(
      MaterialApp(home: MainShell(controller: controller)),
    );

    expect(find.text('UI 小李'), findsWidgets);
    expect(find.textContaining('原名：李四'), findsOneWidget);
    await tester.tap(find.byTooltip('会话操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('修改人员备注'));
    await tester.pumpAndSettle();
    expect(find.text('人员备注'), findsOneWidget);
    expect(find.text('原始名称：李四'), findsOneWidget);
  });

  testWidgets('群聊优先显示本地备注，并可从群操作修改', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = _baseController();
    controller.groups = [
      ChatGroup(
        groupId: 'group-1',
        name: '原始群名',
        ownerDeviceId: 'local-device',
        createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
      ),
    ];
    controller.selectedGroupId = 'group-1';
    controller.groupRemarks = {'group-1': '发布战情室'};

    await tester.pumpWidget(
      MaterialApp(home: MainShell(controller: controller)),
    );

    expect(find.text('发布战情室'), findsWidgets);
    expect(find.textContaining('原群名：原始群名'), findsOneWidget);
    await tester.tap(find.byTooltip('群聊操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('修改群聊备注'));
    await tester.pumpAndSettle();
    expect(find.text('群聊备注'), findsOneWidget);
    expect(find.text('原始名称：原始群名'), findsOneWidget);
  });
}
