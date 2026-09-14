import 'package:flutter/gestures.dart';
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

class _ProfileSaveController extends AppController {
  @override
  Future<void> setDisplayName(String value) async {
    identity = identity!.copyWith(displayName: value.trim());
    notifyListeners();
  }
}

_ProfileSaveController _profileSaveController() {
  final now = DateTime.fromMillisecondsSinceEpoch(1000);
  final controller = _ProfileSaveController();
  controller.stage = AppStage.ready;
  controller.identity = LocalIdentity(
    deviceId: 'local-device',
    displayName: '我',
    createdAt: now,
    lastLoginAt: now,
  );
  return controller;
}

class _SidebarActionsController extends AppController {
  ChatSummary? deletedChat;
  String? blockedDeviceId;
  String? savedRemark;

  @override
  Future<void> deleteChat(ChatSummary chat) async {
    deletedChat = chat;
    chats = chats.where((value) => value.chatId != chat.chatId).toList();
    notifyListeners();
  }

  @override
  Future<void> setBlocked(String deviceId, bool blocked) async {
    if (blocked) blockedDeviceId = deviceId;
  }

  @override
  Future<void> setPeerRemark(String deviceId, String value) async {
    savedRemark = value;
    peerRemarks[deviceId] = value;
    notifyListeners();
  }
}

_SidebarActionsController _sidebarActionsController() {
  final now = DateTime.fromMillisecondsSinceEpoch(1000);
  final controller = _SidebarActionsController();
  controller.stage = AppStage.ready;
  controller.identity = LocalIdentity(
    deviceId: 'local-device',
    displayName: '我',
    createdAt: now,
    lastLoginAt: now,
  );
  controller.chats = const [
    ChatSummary(
      chatId: 'chat-1',
      peerDeviceId: 'peer-1',
      displayName: '李四',
      state: ChatSessionState.active,
      sessionId: 'session-1',
    ),
  ];
  controller.trustedPeers = {
    'peer-1': TrustedPeer(
      deviceId: 'peer-1',
      displayName: '李四',
      lastKnownIp: '192.168.1.20',
      verifiedAt: now,
    ),
  };
  return controller;
}

Future<void> _openSidebarContextMenu(
  WidgetTester tester,
  _SidebarActionsController controller, {
  ConversationWindowOpener? openConversationWindow,
}) async {
  await tester.binding.setSurfaceSize(const Size(1280, 720));
  await tester.pumpWidget(
    MaterialApp(
      home: ListenableBuilder(
        listenable: controller,
        builder: (context, _) => MainShell(
          controller: controller,
          openConversationWindow:
              openConversationWindow ?? openConversationInWindow,
        ),
      ),
    ),
  );
  await tester.tap(find.text('李四'), buttons: kSecondaryMouseButton);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('侧边栏会话右键菜单可在独立窗口打开会话', (tester) async {
    final controller = _sidebarActionsController();
    addTearDown(controller.dispose);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    String? openedConversationId;
    await _openSidebarContextMenu(
      tester,
      controller,
      openConversationWindow: (_, _, conversationId) async {
        openedConversationId = conversationId;
      },
    );

    expect(find.text('在独立窗口打开'), findsOneWidget);
    await tester.tap(find.text('在独立窗口打开'));
    await tester.pumpAndSettle();

    expect(openedConversationId, 'chat-1');
  });

  testWidgets('侧边栏会话右键菜单可修改人员备注', (tester) async {
    final controller = _sidebarActionsController();
    addTearDown(controller.dispose);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _openSidebarContextMenu(tester, controller);

    expect(find.text('修改备注'), findsOneWidget);
    expect(find.text('在独立窗口打开'), findsOneWidget);
    expect(find.text('删除对话'), findsOneWidget);
    expect(find.text('拉黑此人'), findsOneWidget);
    await tester.tap(find.text('修改备注'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), '项目小李');
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();

    expect(controller.savedRemark, '项目小李');
    expect(find.text('项目小李'), findsOneWidget);
  });

  testWidgets('侧边栏会话右键菜单确认后删除对话', (tester) async {
    final controller = _sidebarActionsController();
    addTearDown(controller.dispose);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _openSidebarContextMenu(tester, controller);

    await tester.tap(find.text('删除对话'));
    await tester.pumpAndSettle();
    expect(find.text('删除对话？'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();

    expect(controller.deletedChat?.chatId, 'chat-1');
    expect(find.text('李四'), findsNothing);
  });

  testWidgets('侧边栏会话右键菜单确认后拉黑联系人', (tester) async {
    final controller = _sidebarActionsController();
    addTearDown(controller.dispose);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _openSidebarContextMenu(tester, controller);

    await tester.tap(find.text('拉黑此人'));
    await tester.pumpAndSettle();
    expect(find.text('拉黑此人？'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '拉黑'));
    await tester.pumpAndSettle();

    expect(controller.blockedDeviceId, 'peer-1');
  });

  testWidgets('侧边栏可从内容区标题栏收起并重新展开', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = _baseController();
    await tester.pumpWidget(
      MaterialApp(home: MainShell(controller: controller)),
    );

    expect(find.text('搜索设备或会话'), findsOneWidget);
    expect(find.byTooltip('收起侧边栏'), findsOneWidget);

    await tester.tap(find.byTooltip('收起侧边栏'));
    await tester.pump();

    expect(find.text('搜索设备或会话'), findsNothing);
    expect(find.byTooltip('展开侧边栏'), findsOneWidget);

    await tester.tap(find.byTooltip('展开侧边栏'));
    await tester.pump();

    expect(find.text('搜索设备或会话'), findsOneWidget);
    expect(find.byTooltip('收起侧边栏'), findsOneWidget);
  });

  testWidgets('点击左上角个人区域可编辑头像和昵称', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = _baseController();
    await tester.pumpWidget(
      MaterialApp(home: MainShell(controller: controller)),
    );

    expect(find.byTooltip('编辑头像和昵称'), findsOneWidget);
    await tester.tap(find.byTooltip('编辑头像和昵称'));
    await tester.pumpAndSettle();
    expect(find.text('编辑个人资料'), findsOneWidget);
    expect(find.text('选择头像'), findsOneWidget);
    expect(find.widgetWithText(TextFormField, '昵称'), findsOneWidget);
    expect(find.text('保存'), findsOneWidget);
  });

  testWidgets('保存个人资料后退出动画不会继续使用已销毁的输入控制器', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = _profileSaveController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(home: MainShell(controller: controller)),
    );

    await tester.tap(find.byTooltip('编辑头像和昵称'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), '新昵称');
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(controller.identity!.displayName, '新昵称');
    expect(find.text('编辑个人资料'), findsNothing);
  });

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
