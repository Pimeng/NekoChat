import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:neko_chat/app/app_controller.dart';
import 'package:neko_chat/core/models/models.dart';
import 'package:neko_chat/features/chat/main_shell.dart';

/// 记录“发起好友申请”的调用，避免测试真的走网络。
class _AddFriendController extends AppController {
  DiscoveredPeer? lastRequestedPeer;
  bool? lastViaPairingCode;
  String? lastCode;
  int requestChatCalls = 0;

  @override
  Future<void> requestChat(
    DiscoveredPeer peer, {
    bool viaPairingCode = false,
    String? code,
  }) async {
    requestChatCalls++;
    lastRequestedPeer = peer;
    lastViaPairingCode = viaPairingCode;
    lastCode = code;
  }
}

_AddFriendController _controller() {
  final now = DateTime.fromMillisecondsSinceEpoch(1000);
  final controller = _AddFriendController();
  controller.stage = AppStage.ready;
  controller.identity = LocalIdentity(
    deviceId: 'local-device',
    displayName: '我',
    createdAt: now,
    lastLoginAt: now,
  );
  // 底层发现到、但还不是好友的陌生设备。
  controller.peers = [
    DiscoveredPeer(
      deviceId: 'peer-stranger',
      displayName: '陌生设备',
      ip: '192.168.1.30',
      port: 23333,
      lastSeen: now,
      trusted: false,
      online: true,
    ),
  ];
  controller.chats = [
    const ChatSummary(
      chatId: 'chat-friend',
      peerDeviceId: 'peer-friend',
      displayName: '李四',
      state: ChatSessionState.active,
      sessionId: 'session-friend',
    ),
  ];
  controller.trustedPeers = {
    'peer-friend': TrustedPeer(
      deviceId: 'peer-friend',
      displayName: '李四',
      lastKnownIp: '192.168.1.20',
      verifiedAt: now,
    ),
  };
  return controller;
}

Widget _app(AppController controller) => MaterialApp(
  home: ListenableBuilder(
    listenable: controller,
    builder: (context, _) => MainShell(controller: controller),
  ),
);

void main() {
  testWidgets('陌生设备不会出现在会话列表，也不会被点击发起好友申请', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = _controller();
    addTearDown(controller.dispose);

    await tester.pumpWidget(_app(controller));
    await tester.pumpAndSettle();

    // 会话列表仍然展示已有会话。
    expect(find.text('李四'), findsOneWidget);
    // 陌生设备只在“联系人 → 添加好友”里出现，会话列表不再混入。
    expect(find.text('陌生设备'), findsNothing);
    expect(controller.requestChatCalls, 0);
  });

  testWidgets('添加好友统一从联系人页发起，附近设备可在对话框里挑选', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = _controller();
    addTearDown(controller.dispose);

    await tester.pumpWidget(_app(controller));
    await tester.tap(find.byKey(const ValueKey('nav-rail-contacts')));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, '添加好友'));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('附近设备（直接添加，等对方通过）'), findsOneWidget);
    expect(find.text('陌生设备'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, '加好友'));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
    expect(controller.requestChatCalls, 1);
    expect(controller.lastRequestedPeer?.deviceId, 'peer-stranger');
    expect(controller.lastViaPairingCode, isFalse);
  });

  testWidgets('全局搜索只搜索联系人与会话，不再把陌生设备当作入口', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = _controller();
    addTearDown(controller.dispose);

    await tester.pumpWidget(_app(controller));
    await tester.tap(find.byKey(const ValueKey('nav-rail-search')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('global-search-dialog')), findsOneWidget);
    expect(find.text('搜索联系人或群聊'), findsOneWidget);
    expect(find.text('联系人'), findsOneWidget);
    expect(find.text('陌生设备'), findsNothing);
    expect(controller.requestChatCalls, 0);
  });
}
