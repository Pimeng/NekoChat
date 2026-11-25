import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neko_chat/app/app_controller.dart';
import 'package:neko_chat/core/boss_key/boss_key_service.dart';
import 'package:neko_chat/core/config/network_config.dart';
import 'package:neko_chat/core/database/app_database.dart';
import 'package:neko_chat/core/files/content_hash.dart';
import 'package:neko_chat/core/identity/database_key_provider.dart';
import 'package:neko_chat/core/models/models.dart';
import 'package:neko_chat/core/networking/chat_transport.dart';
import 'package:neko_chat/core/networking/discovery_service.dart';
import 'package:neko_chat/core/networking/friend_request_limiter.dart';
import 'package:neko_chat/core/notifications/system_notification_service.dart';
import 'package:neko_chat/core/protocol/protocol.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 测试脚手架：控制器、数据库、假传输与假发现服务。
class _Setup {
  _Setup({
    required this.controller,
    required this.database,
    required this.transport,
    required this.discovery,
    required this.bossKey,
  });

  final AppController controller;
  final AppDatabase database;
  final _FakeTransport transport;
  final _FakeDiscoveryService discovery;
  final _FakeBossKeyService bossKey;
}

void main() {
  // 控制器启动时会从 assets 加载口令词表，需要初始化测试 binding。
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  _Setup createController(
    Directory directory, {
    required Duration requestTimeout,
    SystemNotificationService? notifications,
    bool hasExistingKey = false,
    FriendRequestLimiter? friendRequestLimiter,
  }) {
    final database = AppDatabase(directory: () async => directory);
    final transport = _FakeTransport();
    final discovery = _FakeDiscoveryService();
    final bossKey = _FakeBossKeyService();
    final controller = AppController(
      keyProvider: _FakeKeyProvider(existingKey: hasExistingKey),
      database: database,
      transport: transport,
      notifications: notifications ?? _FakeNotifications(),
      bossKey: bossKey,
      friendRequestLimiter: friendRequestLimiter,
      discoveryFactory:
          ({
            required LocalIdentity identity,
            required TrustLookup trustLookup,
            required void Function(List<DiscoveredPeer> peers) onPeersChanged,
          }) {
            // 控制器就绪时才拿到回调，这里后绑定给假发现服务。
            discovery.bind(onPeersChanged);
            return discovery;
          },
      requestTimeout: requestTimeout,
    );
    return _Setup(
      controller: controller,
      database: database,
      transport: transport,
      discovery: discovery,
      bossKey: bossKey,
    );
  }

  /// 让控制器认为某个设备在线，否则发送文件会被“对方离线”挡下。
  void setPeerOnline(_Setup setup) => setup.discovery.emit([
    DiscoveredPeer(
      deviceId: 'peer-device',
      displayName: '李四',
      ip: '192.168.1.20',
      port: 23333,
      lastSeen: DateTime.now(),
      trusted: true,
      online: true,
    ),
  ]);

  IncomingPacket chatRequestPacket() => IncomingPacket(
    envelope: const ProtocolEnvelope(
      type: MessageType.chatRequest,
      payload: {
        'requestId': 'request-1',
        'deviceId': 'peer-device',
        'displayName': '李四',
      },
    ),
    remoteAddress: '192.168.1.20',
  );

  /// 走完一次聊天邀请流程，返回建立后的 sessionId。
  Future<String> activateChat(_Setup setup) async {
    setup.transport.emit(chatRequestPacket());
    await _waitUntil(
      () =>
          setup.controller.chatRequests.isNotEmpty &&
          setup.controller.chats.any(
            (chat) => chat.state == ChatSessionState.pendingIncoming,
          ),
    );
    await setup.controller.acceptChatRequest(
      setup.controller.chatRequests.values.single,
    );
    await _waitUntil(
      () => setup.controller.chats.single.state == ChatSessionState.active,
    );
    return setup.controller.chats.single.sessionId!;
  }

  IncomingPacket textMessagePacket(
    String sessionId,
    String content, {
    String messageId = 'msg-1',
    int timestamp = 5000,
  }) => IncomingPacket(
    envelope: ProtocolEnvelope(
      type: MessageType.message,
      payload: {
        'sessionId': sessionId,
        'messageId': messageId,
        'senderDeviceId': 'peer-device',
        'timestamp': timestamp,
        'content': content,
      },
    ),
    remoteAddress: '192.168.1.20',
  );

  IncomingPacket fileOfferPacket(String sessionId, {int fileSize = 1024}) =>
      IncomingPacket(
        envelope: ProtocolEnvelope(
          type: MessageType.fileOffer,
          payload: {
            'sessionId': sessionId,
            'messageId': 'file-msg-1',
            'senderDeviceId': 'peer-device',
            'timestamp': 6000,
            'transferId': 'transfer-1',
            'fileName': '文档.txt',
            'fileSize': fileSize,
            'mimeType': 'text/plain',
          },
        ),
        remoteAddress: '192.168.1.20',
      );

  test('收到的聊天邀请超时后自动清除并回到无会话状态', () async {
    final directory = await Directory.systemTemp.createTemp(
      'neko-chat-controller-timeout-',
    );
    final setup = createController(
      directory,
      requestTimeout: const Duration(milliseconds: 200),
    );
    addTearDown(() async {
      setup.controller.clearTopRightMessage();
      await setup.database.close();
      setup.controller.dispose();
      await directory.delete(recursive: true);
    });

    await setup.controller.initialize();
    await setup.controller.setup(displayName: '本机', password: '1234');
    expect(setup.controller.stage, AppStage.ready);

    setup.transport.emit(chatRequestPacket());
    await _waitUntil(
      () =>
          setup.controller.chatRequests.isNotEmpty &&
          setup.controller.chats.any(
            (chat) =>
                chat.peerDeviceId == 'peer-device' &&
                chat.state == ChatSessionState.pendingIncoming,
          ),
    );

    await _waitUntil(
      () =>
          setup.controller.chatRequests.isEmpty &&
          setup.controller.chats.single.state == ChatSessionState.none,
    );
    expect(setup.controller.topRightMessage, contains('超时'));
  });

  test('带正确口令证明的聊天邀请标记为口令申请，错误证明则为普通申请', () async {
    final directory = await Directory.systemTemp.createTemp(
      'neko-chat-controller-pairing-',
    );
    final setup = createController(
      directory,
      requestTimeout: const Duration(seconds: 30),
    );
    addTearDown(() async {
      setup.controller.clearTopRightMessage();
      await setup.database.close();
      setup.controller.dispose();
      await directory.delete(recursive: true);
    });

    await setup.controller.initialize();
    await setup.controller.setup(displayName: '本机', password: '1234');
    expect(setup.controller.stage, AppStage.ready);

    // 口令证明基于归一化口令（中文词口令去掉词间空格）计算。
    final secret = AppController.normalizePairingCode(
      setup.controller.pairingSecret!,
    );
    final myDeviceId = setup.controller.identity!.deviceId;

    setup.transport.emit(
      IncomingPacket(
        envelope: ProtocolEnvelope(
          type: MessageType.chatRequest,
          payload: {
            'requestId': 'req-pair-ok',
            'deviceId': 'peer-device',
            'displayName': '李四',
            'viaPairingCode': true,
            'pairingProof': sha256String('$secret|req-pair-ok|$myDeviceId'),
          },
        ),
        remoteAddress: '192.168.1.20',
      ),
    );
    await _waitUntil(
      () => setup.controller.chatRequests.containsKey('req-pair-ok'),
    );
    expect(
      setup.controller.chatRequests['req-pair-ok']!.viaPairingCode,
      isTrue,
    );

    setup.transport.emit(
      const IncomingPacket(
        envelope: ProtocolEnvelope(
          type: MessageType.chatRequest,
          payload: {
            'requestId': 'req-pair-bad',
            'deviceId': 'peer-device-2',
            'displayName': '王五',
            'viaPairingCode': true,
            'pairingProof': 'deadbeef',
          },
        ),
        remoteAddress: '192.168.1.21',
      ),
    );
    await _waitUntil(
      () => setup.controller.chatRequests.containsKey('req-pair-bad'),
    );
    expect(
      setup.controller.chatRequests['req-pair-bad']!.viaPairingCode,
      isFalse,
    );
  });

  test('已接受的邀请不会被超时清除', () async {
    final directory = await Directory.systemTemp.createTemp(
      'neko-chat-controller-accept-',
    );
    final setup = createController(
      directory,
      requestTimeout: const Duration(milliseconds: 200),
    );
    addTearDown(() async {
      setup.controller.clearTopRightMessage();
      await setup.database.close();
      setup.controller.dispose();
      await directory.delete(recursive: true);
    });

    await setup.controller.initialize();
    await setup.controller.setup(displayName: '本机', password: '1234');

    setup.transport.emit(chatRequestPacket());
    await _waitUntil(
      () =>
          setup.controller.chatRequests.isNotEmpty &&
          setup.controller.chats.any(
            (chat) =>
                chat.peerDeviceId == 'peer-device' &&
                chat.state == ChatSessionState.pendingIncoming,
          ),
    );
    await setup.controller.acceptChatRequest(
      setup.controller.chatRequests.values.single,
    );

    // 等待超过请求超时时间，确认会话仍然有效。
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(setup.controller.chatRequests, isEmpty);
    final chat = setup.controller.chats.single;
    expect(chat.state, ChatSessionState.active);
    expect(chat.sessionId, isNotNull);
    expect(setup.controller.trustedPeers['peer-device'], isNotNull);
  });

  test('收到消息累计未读，进入会话后清零', () async {
    final directory = await Directory.systemTemp.createTemp(
      'neko-chat-controller-unread-',
    );
    final setup = createController(
      directory,
      requestTimeout: const Duration(seconds: 5),
    );
    addTearDown(() async {
      setup.controller.clearTopRightMessage();
      await setup.database.close();
      setup.controller.dispose();
      await directory.delete(recursive: true);
    });

    await setup.controller.initialize();
    await setup.controller.setup(displayName: '本机', password: '1234');
    final sessionId = await activateChat(setup);

    setup.transport.emit(textMessagePacket(sessionId, '在吗'));
    await _waitUntil(() => setup.controller.chats.single.unreadCount == 1);
    expect(setup.controller.chats.single.lastMessagePreview, '在吗');

    await setup.controller.selectChat(setup.controller.chats.single.chatId);
    await _waitUntil(() => setup.controller.chats.single.unreadCount == 0);
    expect(setup.controller.messages.single.content, '在吗');
  });

  test('独立窗口固定查看会话时实时收消息且不累计未读', () async {
    final directory = await Directory.systemTemp.createTemp(
      'neko-chat-controller-detached-window-',
    );
    final setup = createController(
      directory,
      requestTimeout: const Duration(seconds: 5),
    );
    addTearDown(() async {
      setup.controller.clearTopRightMessage();
      await setup.database.close();
      setup.controller.dispose();
      await directory.delete(recursive: true);
    });

    await setup.controller.initialize();
    await setup.controller.setup(displayName: '本机', password: '1234');
    final sessionId = await activateChat(setup);
    final chatId = setup.controller.chats.single.chatId;
    await setup.controller.setConversationWindowOpen(chatId, true);

    setup.transport.emit(textMessagePacket(sessionId, '独立窗口收到'));
    await _waitUntil(
      () => setup.controller.chats.single.lastMessagePreview == '独立窗口收到',
    );

    expect(setup.controller.selectedChatId, isNull);
    expect(setup.controller.chats.single.unreadCount, 0);
    expect(
      (await setup.controller.loadMessagesForConversation(chatId))
          .single
          .content,
      '独立窗口收到',
    );

    await setup.controller.setConversationWindowOpen(chatId, false);
    setup.transport.emit(
      textMessagePacket(
        sessionId,
        '窗口关闭后收到',
        messageId: 'msg-after-close',
        timestamp: 6000,
      ),
    );
    await _waitUntil(() => setup.controller.chats.single.unreadCount == 1);
  });

  test('重复收到同一消息不会重复计未读或追加到列表', () async {
    final directory = await Directory.systemTemp.createTemp(
      'neko-chat-controller-duplicate-',
    );
    final setup = createController(
      directory,
      requestTimeout: const Duration(seconds: 5),
    );
    addTearDown(() async {
      setup.controller.clearTopRightMessage();
      await setup.database.close();
      setup.controller.dispose();
      await directory.delete(recursive: true);
    });

    await setup.controller.initialize();
    await setup.controller.setup(displayName: '本机', password: '1234');
    final sessionId = await activateChat(setup);
    final packet = textMessagePacket(sessionId, '只应出现一次');

    setup.transport.emit(packet);
    await _waitUntil(() => setup.controller.chats.single.unreadCount == 1);
    setup.transport.emit(packet);
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(setup.controller.chats.single.unreadCount, 1);
    await setup.controller.selectChat(setup.controller.chats.single.chatId);
    expect(setup.controller.messages, hasLength(1));

    setup.transport.emit(packet);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(setup.controller.messages, hasLength(1));
  });

  test('窗口失焦但会话已打开时消息仍直接显示，且不计未读', () async {
    final directory = await Directory.systemTemp.createTemp(
      'neko-chat-controller-background-',
    );
    final notifications = _FakeNotifications(focused: false);
    final setup = createController(
      directory,
      requestTimeout: const Duration(seconds: 5),
      notifications: notifications,
    );
    addTearDown(() async {
      setup.controller.clearTopRightMessage();
      await setup.database.close();
      setup.controller.dispose();
      await directory.delete(recursive: true);
    });

    await setup.controller.initialize();
    await setup.controller.setup(displayName: '本机', password: '1234');
    final sessionId = await activateChat(setup);
    await setup.controller.selectChat(setup.controller.chats.single.chatId);

    setup.transport.emit(textMessagePacket(sessionId, '后台到达'));
    await _waitUntil(() => setup.controller.messages.length == 1);

    // 消息直接进了列表，未读保持 0，同时仍然发出了系统通知。
    expect(setup.controller.messages.single.content, '后台到达');
    expect(setup.controller.chats.single.unreadCount, 0);
    expect(notifications.shown, contains('message:msg-1'));
  });

  test('关闭 Windows 通知后不发送消息或测试通知', () async {
    final directory = await Directory.systemTemp.createTemp(
      'neko-chat-controller-notification-setting-',
    );
    final notifications = _FakeNotifications(focused: false);
    final setup = createController(
      directory,
      requestTimeout: const Duration(seconds: 5),
      notifications: notifications,
    );
    addTearDown(() async {
      setup.controller.clearTopRightMessage();
      await setup.database.close();
      setup.controller.dispose();
      await directory.delete(recursive: true);
    });

    await setup.controller.initialize();
    await setup.controller.setup(displayName: '本机', password: '1234');
    final sessionId = await activateChat(setup);
    notifications.shown.clear();
    await setup.controller.setWindowsNotificationsEnabled(false);

    setup.transport.emit(textMessagePacket(sessionId, '静默到达'));
    await _waitUntil(() => setup.controller.chats.single.unreadCount == 1);
    await setup.controller.showTestNotification();

    expect(notifications.shown, isEmpty);
  });

  test('老板键默认关闭，隐藏期间清理并暂停系统通知', () async {
    final directory = await Directory.systemTemp.createTemp(
      'neko-chat-controller-boss-key-',
    );
    final notifications = _FakeNotifications(focused: false);
    final setup = createController(
      directory,
      requestTimeout: const Duration(seconds: 5),
      notifications: notifications,
    );
    addTearDown(() async {
      await setup.database.close();
      setup.controller.dispose();
      await directory.delete(recursive: true);
    });

    await setup.controller.initialize();
    await setup.controller.setup(displayName: '本机', password: '1234');
    expect(setup.controller.bossKeyEnabled, isFalse);
    expect(setup.bossKey.enabledValues, isEmpty);

    final sessionId = await activateChat(setup);
    notifications.shown.clear();
    await setup.controller.setBossKeyEnabled(true);
    const customShortcut = BossKeyShortcut(
      virtualKey: 0x4b,
      keyLabel: 'K',
      control: true,
      shift: true,
    );
    expect(await setup.controller.setBossKeyShortcut(customShortcut), isTrue);
    expect(setup.controller.bossKeyShortcut, customShortcut);
    expect(
      BossKeyShortcut.decode(
        await setup.database.loadSetting('boss_key_shortcut'),
      ),
      customShortcut,
    );
    setup.bossKey.emitVisibility(hidden: true);
    await _waitUntil(() => notifications.clearCount == 1);

    setup.transport.emit(textMessagePacket(sessionId, '隐藏期间到达'));
    await _waitUntil(() => setup.controller.chats.single.unreadCount == 1);
    expect(notifications.shown, isEmpty);
    expect(await setup.database.loadSetting('boss_key_enabled'), 'true');

    setup.bossKey.emitVisibility(hidden: false);
    setup.transport.emit(
      textMessagePacket(sessionId, '恢复后到达', messageId: 'msg-after-restore'),
    );
    await _waitUntil(() => setup.controller.chats.single.unreadCount == 2);
    expect(notifications.shown, contains('message:msg-after-restore'));
  });

  test('开启“隐藏后仍然通知”后老板键隐藏期间仍会提醒', () async {
    final directory = await Directory.systemTemp.createTemp(
      'neko-chat-controller-boss-key-notify-',
    );
    final notifications = _FakeNotifications(focused: false);
    final setup = createController(
      directory,
      requestTimeout: const Duration(seconds: 5),
      notifications: notifications,
    );
    addTearDown(() async {
      await setup.database.close();
      setup.controller.dispose();
      await directory.delete(recursive: true);
    });

    await setup.controller.initialize();
    await setup.controller.setup(displayName: '本机', password: '1234');
    final sessionId = await activateChat(setup);
    await setup.controller.setBossKeyEnabled(true);
    await setup.controller.setBossKeyNotifyWhenHidden(true);
    expect(setup.controller.bossKeyNotifyWhenHidden, isTrue);
    expect(
      await setup.database.loadSetting('boss_key_notify_when_hidden'),
      'true',
    );

    notifications.shown.clear();
    setup.bossKey.emitVisibility(hidden: true);
    await _waitUntil(() => notifications.clearCount == 1);
    setup.transport.emit(
      textMessagePacket(sessionId, '隐藏期间到达', messageId: 'msg-hidden'),
    );
    await _waitUntil(() => notifications.shown.contains('message:msg-hidden'));
  });

  test('取消发送中的聊天请求会清空待确认并通知对端', () async {
    final directory = await Directory.systemTemp.createTemp(
      'neko-chat-controller-cancel-request-',
    );
    final setup = createController(
      directory,
      requestTimeout: const Duration(seconds: 30),
    );
    addTearDown(() async {
      await setup.database.close();
      setup.controller.dispose();
      await directory.delete(recursive: true);
    });

    await setup.controller.initialize();
    await setup.controller.setup(displayName: '本机', password: '1234');
    setPeerOnline(setup);
    await setup.controller.requestChat(setup.controller.peers.single);
    await _waitUntil(() => setup.controller.chatRequests.isNotEmpty);
    final request = setup.controller.chatRequests.values.single;
    expect(request.incoming, isFalse);
    expect(
      setup.controller.chats.single.state,
      ChatSessionState.pendingOutgoing,
    );

    await setup.controller.cancelChatRequest(request);

    expect(setup.controller.chatRequests, isEmpty);
    expect(setup.controller.chats.single.state, ChatSessionState.none);
    final reject = setup.transport.sentEnvelopes.lastWhere(
      (envelope) => envelope.type == MessageType.chatReject,
    );
    expect(reject.payload['requestId'], request.requestId);
    expect(reject.payload['cancelled'], isTrue);
  });

  ChatGroup adminGroup(String ownerDeviceId, String myDeviceId) => ChatGroup(
    groupId: 'group-admin',
    name: '管理群',
    ownerDeviceId: ownerDeviceId,
    createdAt: DateTime.fromMillisecondsSinceEpoch(0),
  );

  test('群管理员可撤回他人消息但不能撤回群主消息', () async {
    final directory = await Directory.systemTemp.createTemp(
      'neko-chat-controller-admin-recall-',
    );
    final setup = createController(
      directory,
      requestTimeout: const Duration(seconds: 5),
    );
    addTearDown(() async {
      await setup.database.close();
      setup.controller.dispose();
      await directory.delete(recursive: true);
    });

    await setup.controller.initialize();
    await setup.controller.setup(displayName: '本机', password: '1234');
    final me = setup.controller.identity!.deviceId;
    final group = adminGroup('owner-device', me);
    await setup.database.saveGroup(group, [
      GroupMember(
        groupId: group.groupId,
        deviceId: 'owner-device',
        displayName: '群主',
        role: GroupRole.owner,
      ),
      GroupMember(
        groupId: group.groupId,
        deviceId: me,
        displayName: '我',
        role: GroupRole.admin,
      ),
      GroupMember(
        groupId: group.groupId,
        deviceId: 'member-device',
        displayName: '成员',
        role: GroupRole.member,
      ),
    ]);
    setup.controller.groups = [group];
    await setup.controller.groupMembers(group.groupId);
    expect(setup.controller.groupRole(group.groupId), GroupRole.admin);

    final timestamp = DateTime.now();
    final memberMessage = ChatMessage(
      messageId: 'member-message',
      chatId: 'group:${group.groupId}',
      groupId: group.groupId,
      senderDeviceId: 'member-device',
      content: '普通成员消息',
      timestamp: timestamp,
      status: MessageStatus.sent,
    );
    final ownerMessage = ChatMessage(
      messageId: 'owner-message',
      chatId: 'group:${group.groupId}',
      groupId: group.groupId,
      senderDeviceId: 'owner-device',
      content: '群主消息',
      timestamp: timestamp,
      status: MessageStatus.sent,
    );

    expect(setup.controller.canRecallMessage(memberMessage), isTrue);
    expect(setup.controller.canRecallMessage(ownerMessage), isFalse);
  });

  test('管理员只能移除普通成员，群主与管理员不受影响', () async {
    final directory = await Directory.systemTemp.createTemp(
      'neko-chat-controller-admin-remove-',
    );
    final setup = createController(
      directory,
      requestTimeout: const Duration(seconds: 5),
    );
    addTearDown(() async {
      await setup.database.close();
      setup.controller.dispose();
      await directory.delete(recursive: true);
    });

    await setup.controller.initialize();
    await setup.controller.setup(displayName: '本机', password: '1234');
    final me = setup.controller.identity!.deviceId;
    final group = adminGroup('owner-device', me);
    final ownerMember = GroupMember(
      groupId: group.groupId,
      deviceId: 'owner-device',
      displayName: '群主',
      role: GroupRole.owner,
    );
    final member = GroupMember(
      groupId: group.groupId,
      deviceId: 'member-device',
      displayName: '成员',
      role: GroupRole.member,
    );
    final otherAdmin = GroupMember(
      groupId: group.groupId,
      deviceId: 'admin-device',
      displayName: '另一个管理员',
      role: GroupRole.admin,
    );
    await setup.database.saveGroup(group, [
      ownerMember,
      GroupMember(
        groupId: group.groupId,
        deviceId: me,
        displayName: '我',
        role: GroupRole.admin,
      ),
      member,
      otherAdmin,
    ]);
    setup.controller.groups = [group];
    await setup.controller.groupMembers(group.groupId);

    await setup.controller.removeGroupMember(group, member);
    var members = await setup.database.loadGroupMembers(group.groupId);
    expect(members.any((value) => value.deviceId == 'member-device'), isFalse);

    await setup.controller.removeGroupMember(group, ownerMember);
    await setup.controller.removeGroupMember(group, otherAdmin);
    members = await setup.database.loadGroupMembers(group.groupId);
    expect(members.any((value) => value.deviceId == 'owner-device'), isTrue);
    expect(members.any((value) => value.deviceId == 'admin-device'), isTrue);
  });

  test('群主可设置或取消管理员并同步成员名单', () async {
    final directory = await Directory.systemTemp.createTemp(
      'neko-chat-controller-set-admin-',
    );
    final setup = createController(
      directory,
      requestTimeout: const Duration(seconds: 5),
    );
    addTearDown(() async {
      await setup.database.close();
      setup.controller.dispose();
      await directory.delete(recursive: true);
    });

    await setup.controller.initialize();
    await setup.controller.setup(displayName: '本机', password: '1234');
    final me = setup.controller.identity!.deviceId;
    final group = adminGroup(me, me);
    final member = GroupMember(
      groupId: group.groupId,
      deviceId: 'member-device',
      displayName: '成员',
      role: GroupRole.member,
    );
    await setup.database.saveGroup(group, [
      GroupMember(
        groupId: group.groupId,
        deviceId: me,
        displayName: '我',
        role: GroupRole.owner,
      ),
      member,
    ]);
    setup.controller.groups = [group];
    await setup.controller.groupMembers(group.groupId);
    setup.discovery.emit([
      DiscoveredPeer(
        deviceId: 'member-device',
        displayName: '成员',
        ip: '192.168.1.30',
        port: 23333,
        lastSeen: DateTime.now(),
        trusted: true,
        online: true,
      ),
    ]);

    await setup.controller.setGroupMemberRole(group, member, GroupRole.admin);

    final updated = (await setup.database.loadGroupMembers(group.groupId))
        .firstWhere((value) => value.deviceId == 'member-device');
    expect(updated.role, GroupRole.admin);
    final broadcast = setup.transport.sentEnvelopes.lastWhere(
      (envelope) =>
          envelope.type == MessageType.groupUpdate &&
          envelope.payload['action'] == 'members',
    );
    expect(broadcast.payload['members'], isA<List>());

    await setup.controller.setGroupMemberRole(group, member, GroupRole.member);
    expect(
      (await setup.database.loadGroupMembers(group.groupId))
          .firstWhere((value) => value.deviceId == 'member-device')
          .role,
      GroupRole.member,
    );
  });

  test('关闭自动接收后小文件也等待手动确认', () async {
    final directory = await Directory.systemTemp.createTemp(
      'neko-chat-controller-file-setting-',
    );
    final setup = createController(
      directory,
      requestTimeout: const Duration(seconds: 5),
    );
    addTearDown(() async {
      setup.controller.clearTopRightMessage();
      await setup.database.close();
      setup.controller.dispose();
      await directory.delete(recursive: true);
    });

    await setup.controller.initialize();
    await setup.controller.setup(displayName: '本机', password: '1234');
    final sessionId = await activateChat(setup);
    setPeerOnline(setup);
    await setup.controller.setAutoReceiveFiles(false);

    setup.transport.emit(fileOfferPacket(sessionId));
    await _waitUntil(
      () => setup.controller.chats.single.lastMessagePreview != null,
    );
    final stored = await setup.database.loadMessages(
      setup.controller.chats.single.chatId,
    );

    expect(stored.single.status, MessageStatus.awaitingAcceptance);
  });

  test('超过接收端自定义自动接收上限后等待手动确认', () async {
    final directory = await Directory.systemTemp.createTemp(
      'neko-chat-controller-file-limit-',
    );
    final setup = createController(
      directory,
      requestTimeout: const Duration(seconds: 5),
    );
    addTearDown(() async {
      await setup.database.close();
      setup.controller.dispose();
      await directory.delete(recursive: true);
    });
    await setup.controller.initialize();
    await setup.controller.setup(displayName: '本机', password: '1234');
    final sessionId = await activateChat(setup);
    setPeerOnline(setup);
    await setup.controller.setAutoReceiveFileLimitBytes(1024 * 1024);

    setup.transport.emit(fileOfferPacket(sessionId, fileSize: 2 * 1024 * 1024));
    await _waitUntil(
      () => setup.controller.chats.single.lastMessagePreview != null,
    );
    final stored = await setup.database.loadMessages(
      setup.controller.chats.single.chatId,
    );
    expect(stored.single.status, MessageStatus.awaitingAcceptance);
  });

  test('重新解锁后恢复文件接收和通知设置', () async {
    final directory = await Directory.systemTemp.createTemp(
      'neko-chat-controller-settings-restore-',
    );
    final seed = AppDatabase(directory: () async => directory);
    await seed.open(List<int>.generate(32, (index) => index));
    final now = DateTime.fromMillisecondsSinceEpoch(1000);
    await seed.saveIdentity(
      LocalIdentity(
        deviceId: 'local-device',
        displayName: '本机',
        createdAt: now,
        lastLoginAt: now,
      ),
    );
    await seed.saveSetting('auto_receive_files', 'false');
    await seed.saveSetting(
      'auto_receive_file_limit_bytes',
      (25 * 1024 * 1024).toString(),
    );
    await seed.saveSetting('windows_notifications', 'false');
    await seed.saveSetting('lan_discovery_enabled', 'false');
    await seed.saveSetting('boss_key_enabled', 'true');
    const restoredShortcut = BossKeyShortcut(
      virtualKey: 0x4b,
      keyLabel: 'K',
      control: true,
      alt: true,
    );
    await seed.saveSetting('boss_key_shortcut', restoredShortcut.encode());
    await seed.close();

    final setup = createController(
      directory,
      requestTimeout: const Duration(seconds: 5),
      hasExistingKey: true,
    );
    addTearDown(() async {
      await setup.database.close();
      setup.controller.dispose();
      await directory.delete(recursive: true);
    });

    await setup.controller.initialize();
    expect(setup.controller.stage, AppStage.locked);
    await setup.controller.unlock('1234');

    expect(setup.controller.stage, AppStage.ready);
    expect(setup.controller.autoReceiveFiles, isFalse);
    expect(setup.controller.autoReceiveFileLimitBytes, 25 * 1024 * 1024);
    expect(setup.controller.windowsNotificationsEnabled, isFalse);
    expect(setup.controller.lanDiscoveryEnabled, isFalse);
    expect(setup.discovery.startCount, 0);
    expect(setup.controller.bossKeyEnabled, isTrue);
    expect(setup.controller.bossKeyShortcut, restoredShortcut);
    expect(setup.bossKey.enabledValues, [true]);
  });

  test('在线探测默认开启，并可即时停止、清空设备和恢复', () async {
    final directory = await Directory.systemTemp.createTemp(
      'neko-chat-controller-discovery-setting-',
    );
    final setup = createController(
      directory,
      requestTimeout: const Duration(seconds: 5),
    );
    addTearDown(() async {
      await setup.database.close();
      setup.controller.dispose();
      await directory.delete(recursive: true);
    });

    await setup.controller.initialize();
    await setup.controller.setup(displayName: '本机', password: '1234');
    expect(setup.controller.lanDiscoveryEnabled, isTrue);
    expect(setup.discovery.startCount, 1);

    setPeerOnline(setup);
    expect(setup.controller.peers, isNotEmpty);
    await setup.controller.setLanDiscoveryEnabled(false);
    expect(setup.controller.lanDiscoveryEnabled, isFalse);
    expect(setup.controller.peers, isEmpty);
    expect(setup.discovery.stopCount, 1);
    expect(await setup.database.loadSetting('lan_discovery_enabled'), 'false');

    await setup.controller.setLanDiscoveryEnabled(true);
    expect(setup.controller.lanDiscoveryEnabled, isTrue);
    expect(setup.discovery.startCount, 2);
    expect(await setup.database.loadSetting('lan_discovery_enabled'), 'true');
  });

  test('开启拒绝所有新申请后自动拒绝新的好友申请与群聊邀请', () async {
    final directory = await Directory.systemTemp.createTemp(
      'neko-chat-controller-reject-all-',
    );
    final setup = createController(
      directory,
      requestTimeout: const Duration(seconds: 5),
    );
    addTearDown(() async {
      await setup.database.close();
      setup.controller.dispose();
      await directory.delete(recursive: true);
    });

    await setup.controller.initialize();
    await setup.controller.setup(displayName: '本机', password: '1234');
    expect(setup.controller.rejectAllNewRequests, isFalse);

    await setup.controller.setRejectAllNewRequests(true);
    expect(setup.controller.rejectAllNewRequests, isTrue);
    expect(await setup.database.loadSetting('reject_all_new_requests'), 'true');

    // 普通好友申请与携带口令的新好友申请都会被自动拒绝并回复 chatReject。
    setup.transport.emit(chatRequestPacket());
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(setup.controller.chatRequests, isEmpty);
    expect(
      setup.transport.sentEnvelopes.any(
        (e) =>
            e.type == MessageType.chatReject &&
            e.payload['requestId'] == 'request-1',
      ),
      isTrue,
    );

    // 新的群聊邀请同样被自动拒绝并回复 groupInviteResponse(accepted: false)。
    final trusted = TrustedPeer(
      deviceId: 'trusted-peer',
      displayName: '好友',
      lastKnownIp: '192.168.1.30',
      verifiedAt: DateTime.now(),
    );
    await setup.database.saveTrustedPeer(trusted);
    setup.controller.trustedPeers[trusted.deviceId] = trusted;

    setup.transport.emit(
      const IncomingPacket(
        envelope: ProtocolEnvelope(
          type: MessageType.groupInvite,
          payload: {
            'inviteId': 'invite-auto-reject',
            'groupId': 'group-1',
            'groupName': '测试群',
            'ownerDeviceId': 'trusted-peer',
            'ownerDisplayName': '好友',
            'inviterDeviceId': 'trusted-peer',
            'inviterDisplayName': '好友',
          },
        ),
        remoteAddress: '192.168.1.30',
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(setup.controller.groupInvitations, isEmpty);
    expect(
      setup.transport.sentEnvelopes.any(
        (e) =>
            e.type == MessageType.groupInviteResponse &&
            e.payload['inviteId'] == 'invite-auto-reject' &&
            e.payload['accepted'] == false,
      ),
      isTrue,
    );
  });

  test('人员和群聊备注本地生效，不覆盖原始名称', () async {
    final directory = await Directory.systemTemp.createTemp(
      'neko-chat-controller-remarks-',
    );
    final setup = createController(
      directory,
      requestTimeout: const Duration(seconds: 5),
    );
    addTearDown(() async {
      await setup.database.close();
      setup.controller.dispose();
      await directory.delete(recursive: true);
    });

    await setup.controller.initialize();
    await setup.controller.setup(displayName: '本机', password: '1234');
    await activateChat(setup);
    final chat = setup.controller.chats.single;
    final group = await setup.controller.createGroup('原始群名', const []);

    await setup.controller.setPeerRemark(chat.peerDeviceId, 'UI 小李');
    await setup.controller.setGroupRemark(group.groupId, '发布战情室');

    expect(
      setup.controller.peerDisplayName(chat.peerDeviceId, chat.displayName),
      'UI 小李',
    );
    expect(
      setup.controller.groupDisplayName(group.groupId, group.name),
      '发布战情室',
    );
    expect(setup.controller.chats.single.displayName, '李四');
    expect(setup.controller.groups.single.name, '原始群名');
    setPeerOnline(setup);
    await setup.controller.inviteToGroup(group, setup.controller.peers.single);
    final invitation = setup.transport.sentEnvelopes.lastWhere(
      (envelope) => envelope.type == MessageType.groupInvite,
    );
    expect(invitation.payload['groupName'], '原始群名');

    await setup.controller.setPeerRemark(chat.peerDeviceId, '   ');
    await setup.controller.setGroupRemark(group.groupId, '');
    expect(setup.controller.peerRemarks, isEmpty);
    expect(setup.controller.groupRemarks, isEmpty);
  });

  test('修改昵称会持久化并更新本机群成员资料', () async {
    final directory = await Directory.systemTemp.createTemp(
      'neko-chat-controller-profile-name-',
    );
    final setup = createController(
      directory,
      requestTimeout: const Duration(seconds: 5),
    );
    addTearDown(() async {
      await setup.database.close();
      setup.controller.dispose();
      await directory.delete(recursive: true);
    });
    await setup.controller.initialize();
    await setup.controller.setup(displayName: '旧昵称', password: '1234');
    final group = await setup.controller.createGroup('测试群', const []);

    await setup.controller.setDisplayName('新昵称');

    expect(setup.controller.identity?.displayName, '新昵称');
    expect((await setup.database.loadIdentity())?.displayName, '新昵称');
    expect(
      (await setup.database.loadGroupMembers(group.groupId)).single.displayName,
      '新昵称',
    );
    expect(setup.discovery.identity.displayName, '新昵称');
  });

  test('没有在线群成员时文件发送失败通过右上角弹出提醒', () async {
    final directory = await Directory.systemTemp.createTemp(
      'neko-chat-controller-offline-group-file-',
    );
    final setup = createController(
      directory,
      requestTimeout: const Duration(seconds: 5),
    );
    addTearDown(() async {
      setup.controller.clearTopRightMessage();
      await setup.database.close();
      setup.controller.dispose();
      await directory.delete(recursive: true);
    });
    await setup.controller.initialize();
    await setup.controller.setup(displayName: '本机', password: '1234');
    final group = await setup.controller.createGroup('测试群', const []);
    final file = File('${directory.path}${Platform.pathSeparator}离线文件.txt');
    await file.writeAsString('offline');

    await setup.controller.sendMessageWithAttachments(
      conversationId: 'group:${group.groupId}',
      content: '',
      attachments: [(await setup.controller.pendingAttachment(file.path))!],
    );

    expect(setup.controller.errorMessage, isNull);
    expect(setup.controller.topRightMessage, '当前没有在线群成员，文件未发送');
    expect(setup.controller.topRightIcon, Icons.error_outline);
    final stored = await setup.database.loadMessages('group:${group.groupId}');
    expect(stored.single.status, MessageStatus.failed);
  });

  test('自定义头像复制到数据目录，更换与移除时清理旧文件', () async {
    final directory = await Directory.systemTemp.createTemp(
      'neko-chat-controller-avatar-',
    );
    final setup = createController(
      directory,
      requestTimeout: const Duration(seconds: 5),
    );
    addTearDown(() async {
      await setup.database.close();
      setup.controller.dispose();
      await directory.delete(recursive: true);
    });
    await setup.controller.initialize();
    await setup.controller.setup(displayName: '本机', password: '1234');
    final first = File('${directory.path}${Platform.pathSeparator}first.png');
    final second = File('${directory.path}${Platform.pathSeparator}second.png');
    await first.writeAsBytes([1, 2, 3]);
    await second.writeAsBytes([4, 5, 6]);

    await setup.controller.setProfileAvatarFromPath(first.path);
    final firstStored = setup.controller.profileAvatarPath!;
    expect(await File(firstStored).exists(), isTrue);
    expect(setup.database.isInsideDataDirectory(firstStored), isTrue);

    await setup.controller.setProfileAvatarFromPath(second.path);
    final secondStored = setup.controller.profileAvatarPath!;
    expect(secondStored, isNot(firstStored));
    expect(await File(firstStored).exists(), isFalse);
    expect(await File(secondStored).exists(), isTrue);

    await setup.controller.removeProfileAvatar();
    expect(setup.controller.profileAvatarPath, isNull);
    expect(await File(secondStored).exists(), isFalse);
  });

  test('设置头像后广播哈希并按需同步对端头像', () async {
    final directory = await Directory.systemTemp.createTemp(
      'neko-chat-controller-avatar-sync-',
    );
    final setup = createController(
      directory,
      requestTimeout: const Duration(seconds: 5),
    );
    addTearDown(() async {
      await setup.database.close();
      setup.controller.dispose();
      await directory.delete(recursive: true);
    });

    await setup.controller.initialize();
    await setup.controller.setup(displayName: '本机', password: '1234');

    final avatar = File('${directory.path}${Platform.pathSeparator}me.png');
    await avatar.writeAsBytes([1, 2, 3, 4]);
    await setup.controller.setProfileAvatarFromPath(avatar.path);

    expect(setup.controller.profileAvatarHash, isNotNull);
    expect(setup.discovery.avatarHash, setup.controller.profileAvatarHash);
    expect(setup.transport.localAvatarPath, setup.controller.profileAvatarPath);

    final remote = File('${directory.path}${Platform.pathSeparator}peer.png');
    await remote.writeAsBytes([9, 9, 9]);
    setup.transport.avatarDownloader = (deviceId, hash) async => remote.path;
    final peerHash = 'b' * 64;
    final peer = DiscoveredPeer(
      deviceId: 'peer-device',
      displayName: '李四',
      ip: '192.168.1.20',
      port: 23333,
      lastSeen: DateTime.now(),
      trusted: true,
      online: true,
      avatarHash: peerHash,
    );
    setup.discovery.emit([peer]);

    await _waitUntil(
      () => setup.controller.peerAvatarPath('peer-device') == remote.path,
    );
    expect(setup.transport.avatarDownloads, hasLength(1));
    expect(setup.transport.avatarDownloads.single.deviceId, 'peer-device');
    expect(setup.transport.avatarDownloads.single.hash, peerHash);

    // 哈希不变时不会重复下载。
    setup.discovery.emit([peer]);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(setup.transport.avatarDownloads, hasLength(1));
  });

  test('群成员也能邀请新成员并同步真实 Owner 信息', () async {
    final directory = await Directory.systemTemp.createTemp(
      'neko-chat-controller-member-invite-',
    );
    final setup = createController(
      directory,
      requestTimeout: const Duration(seconds: 5),
    );
    addTearDown(() async {
      await setup.database.close();
      setup.controller.dispose();
      await directory.delete(recursive: true);
    });

    await setup.controller.initialize();
    await setup.controller.setup(displayName: '本机', password: '1234');
    final myDeviceId = setup.controller.identity!.deviceId;
    final group = ChatGroup(
      groupId: 'group-member',
      name: '同学群',
      ownerDeviceId: 'owner-device',
      createdAt: DateTime.now(),
    );
    await setup.database.saveGroup(group, [
      GroupMember(
        groupId: group.groupId,
        deviceId: 'owner-device',
        displayName: '群主',
        role: GroupRole.owner,
      ),
      GroupMember(
        groupId: group.groupId,
        deviceId: myDeviceId,
        displayName: '本机',
        role: GroupRole.member,
      ),
    ]);
    setup.controller.groups = [group];
    setPeerOnline(setup);

    await setup.controller.inviteToGroup(group, setup.controller.peers.single);

    final invite = setup.transport.sentEnvelopes.lastWhere(
      (envelope) => envelope.type == MessageType.groupInvite,
    );
    expect(invite.payload['ownerDeviceId'], 'owner-device');
    expect(invite.payload['ownerDisplayName'], '群主');
    expect(invite.payload['inviterDeviceId'], myDeviceId);
    expect(invite.payload['inviterDisplayName'], '本机');
  });

  test('成员同步成员名单时保留 Owner，且非成员发送的名单被忽略', () async {
    final directory = await Directory.systemTemp.createTemp(
      'neko-chat-controller-member-sync-',
    );
    final setup = createController(
      directory,
      requestTimeout: const Duration(seconds: 5),
    );
    addTearDown(() async {
      await setup.database.close();
      setup.controller.dispose();
      await directory.delete(recursive: true);
    });

    await setup.controller.initialize();
    await setup.controller.setup(displayName: '本机', password: '1234');
    final myDeviceId = setup.controller.identity!.deviceId;
    final group = ChatGroup(
      groupId: 'group-sync',
      name: '同步群',
      ownerDeviceId: 'owner-device',
      createdAt: DateTime.now(),
    );
    await setup.database.saveGroup(group, [
      GroupMember(
        groupId: group.groupId,
        deviceId: 'owner-device',
        displayName: '群主',
        role: GroupRole.owner,
      ),
      GroupMember(
        groupId: group.groupId,
        deviceId: myDeviceId,
        displayName: '本机',
        role: GroupRole.member,
      ),
    ]);
    setup.controller.groups = [group];

    setup.transport.emit(
      IncomingPacket(
        envelope: ProtocolEnvelope(
          type: MessageType.groupUpdate,
          payload: {
            'groupId': 'group-sync',
            'action': 'members',
            'senderDeviceId': 'owner-device',
            'members': [
              {
                'deviceId': 'owner-device',
                'displayName': '群主',
                'role': 'owner',
              },
              {'deviceId': myDeviceId, 'displayName': '本机', 'role': 'member'},
              {
                'deviceId': 'new-member',
                'displayName': '新同学',
                'role': 'member',
              },
            ],
          },
        ),
        remoteAddress: '192.168.1.30',
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 150));
    final members = await setup.database.loadGroupMembers('group-sync');
    expect(members.any((member) => member.deviceId == 'new-member'), isTrue);
    expect(
      members.firstWhere((member) => member.deviceId == 'owner-device').role,
      GroupRole.owner,
    );
  });

  test('会话未打开时消息计为未读且不进入当前列表', () async {
    final directory = await Directory.systemTemp.createTemp(
      'neko-chat-controller-unseen-',
    );
    final setup = createController(
      directory,
      requestTimeout: const Duration(seconds: 5),
    );
    addTearDown(() async {
      setup.controller.clearTopRightMessage();
      await setup.database.close();
      setup.controller.dispose();
      await directory.delete(recursive: true);
    });

    await setup.controller.initialize();
    await setup.controller.setup(displayName: '本机', password: '1234');
    final sessionId = await activateChat(setup);

    setup.transport.emit(textMessagePacket(sessionId, '别的会话'));
    await _waitUntil(() => setup.controller.chats.single.unreadCount == 1);
    expect(setup.controller.messages, isEmpty);
  });

  test('发送消息携带引用并在发送后清空引用状态', () async {
    final directory = await Directory.systemTemp.createTemp(
      'neko-chat-controller-reply-',
    );
    final setup = createController(
      directory,
      requestTimeout: const Duration(seconds: 5),
    );
    addTearDown(() async {
      setup.controller.clearTopRightMessage();
      await setup.database.close();
      setup.controller.dispose();
      await directory.delete(recursive: true);
    });

    await setup.controller.initialize();
    await setup.controller.setup(displayName: '本机', password: '1234');
    final sessionId = await activateChat(setup);
    await setup.controller.selectChat(setup.controller.chats.single.chatId);

    setup.transport.emit(textMessagePacket(sessionId, '原始消息'));
    await _waitUntil(() => setup.controller.messages.isNotEmpty);
    final original = setup.controller.messages.last;

    setup.controller.beginReply(original);
    expect(setup.controller.replyingTo, same(original));
    await setup.controller.sendMessage('回复内容');
    await _waitUntil(() => setup.controller.messages.length == 2);

    final reply = setup.controller.messages.last;
    expect(reply.content, '回复内容');
    expect(reply.replyToMessageId, original.messageId);
    expect(reply.replyToPreview, '原始消息');
    expect(setup.controller.replyingTo, isNull);
  });

  test('文字与附件按顺序一起发送，引用只挂在文字上', () async {
    final directory = await Directory.systemTemp.createTemp(
      'neko-chat-controller-mixed-',
    );
    final setup = createController(
      directory,
      requestTimeout: const Duration(seconds: 5),
    );
    addTearDown(() async {
      setup.controller.clearTopRightMessage();
      await setup.database.close();
      setup.controller.dispose();
      await directory.delete(recursive: true);
    });

    await setup.controller.initialize();
    await setup.controller.setup(displayName: '本机', password: '1234');
    final sessionId = await activateChat(setup);
    await setup.controller.selectChat(setup.controller.chats.single.chatId);
    setPeerOnline(setup);

    setup.transport.emit(textMessagePacket(sessionId, '原始消息'));
    await _waitUntil(() => setup.controller.messages.isNotEmpty);
    final original = setup.controller.messages.last;
    setup.controller.beginReply(original);

    final file = File('${directory.path}${Platform.pathSeparator}混排.png');
    await file.writeAsBytes(List<int>.filled(32, 7));
    final attachment = await setup.controller.pendingAttachment(file.path);
    expect(attachment, isNotNull);
    expect(attachment!.isImage, isTrue);

    await setup.controller.sendMessageWithAttachments(
      content: '配图说明',
      attachments: [attachment],
    );
    await _waitUntil(() => setup.controller.messages.length == 3);

    final sent = setup.controller.messages.sublist(1);
    expect(sent.first.content, '配图说明');
    expect(sent.first.kind, MessageKind.text);
    // 引用落在文字上，附件不会重复携带引用。
    expect(sent.first.replyToMessageId, original.messageId);
    expect(sent.last.kind, MessageKind.image);
    expect(sent.last.fileName, '混排.png');
    expect(sent.last.replyToMessageId, isNull);
  });

  test('只有附件时引用落到第一个附件上', () async {
    final directory = await Directory.systemTemp.createTemp(
      'neko-chat-controller-file-reply-',
    );
    final setup = createController(
      directory,
      requestTimeout: const Duration(seconds: 5),
    );
    addTearDown(() async {
      setup.controller.clearTopRightMessage();
      await setup.database.close();
      setup.controller.dispose();
      await directory.delete(recursive: true);
    });

    await setup.controller.initialize();
    await setup.controller.setup(displayName: '本机', password: '1234');
    final sessionId = await activateChat(setup);
    await setup.controller.selectChat(setup.controller.chats.single.chatId);
    setPeerOnline(setup);

    setup.transport.emit(textMessagePacket(sessionId, '原始消息'));
    await _waitUntil(() => setup.controller.messages.isNotEmpty);
    final original = setup.controller.messages.last;
    setup.controller.beginReply(original);

    final file = File('${directory.path}${Platform.pathSeparator}报告.pdf');
    await file.writeAsBytes(List<int>.filled(32, 3));
    final attachment = await setup.controller.pendingAttachment(file.path);
    expect(attachment!.isImage, isFalse);

    await setup.controller.sendMessageWithAttachments(
      content: '   ',
      attachments: [attachment],
    );
    await _waitUntil(() => setup.controller.messages.length == 2);

    final sent = setup.controller.messages.last;
    expect(sent.kind, MessageKind.file);
    expect(sent.status, MessageStatus.awaitingAcceptance);
    expect(sent.replyToMessageId, original.messageId);
    expect(setup.controller.replyingTo, isNull);
  });

  test('批量发送绑定原会话，不会跟随当前选择串到别处', () async {
    final directory = await Directory.systemTemp.createTemp(
      'neko-chat-controller-target-',
    );
    final setup = createController(
      directory,
      requestTimeout: const Duration(seconds: 5),
    );
    addTearDown(() async {
      setup.controller.clearTopRightMessage();
      await setup.database.close();
      setup.controller.dispose();
      await directory.delete(recursive: true);
    });

    await setup.controller.initialize();
    await setup.controller.setup(displayName: '本机', password: '1234');
    await activateChat(setup);
    final chat = setup.controller.chats.single;
    await setup.controller.selectChat(chat.chatId);
    setPeerOnline(setup);

    final file = File('${directory.path}${Platform.pathSeparator}目标.txt');
    await file.writeAsString('target');
    final attachment = await setup.controller.pendingAttachment(file.path);
    await setup.controller.closeChat(chat);

    await setup.controller.sendMessageWithAttachments(
      conversationId: chat.chatId,
      content: '',
      attachments: [attachment!],
    );

    final stored = await setup.database.loadMessages(chat.chatId);
    expect(stored, hasLength(1));
    expect(stored.single.fileName, '目标.txt');
    expect(setup.controller.messages, isEmpty);
  });

  test('删除私聊会同时清除会话索引和本地消息记录', () async {
    final directory = await Directory.systemTemp.createTemp(
      'neko-chat-controller-delete-',
    );
    final setup = createController(
      directory,
      requestTimeout: const Duration(seconds: 5),
    );
    addTearDown(() async {
      setup.controller.clearTopRightMessage();
      await setup.database.close();
      setup.controller.dispose();
      await directory.delete(recursive: true);
    });

    await setup.controller.initialize();
    await setup.controller.setup(displayName: '本机', password: '1234');
    final sessionId = await activateChat(setup);
    final chat = setup.controller.chats.single;
    await setup.controller.selectChat(chat.chatId);
    setup.transport.emit(textMessagePacket(sessionId, '准备删除的消息'));
    await _waitUntil(() => setup.controller.messages.isNotEmpty);

    await setup.controller.deleteChat(chat);

    expect(setup.controller.chats, isEmpty);
    expect(setup.controller.selectedChatId, isNull);
    expect(setup.controller.messages, isEmpty);
    expect(await setup.database.loadChats(), isEmpty);
    expect(await setup.database.loadMessages(chat.chatId), isEmpty);
  });

  test('拖放多个文件会忽略目录和失效路径并按原顺序立即发送', () async {
    final directory = await Directory.systemTemp.createTemp(
      'neko-chat-controller-drop-',
    );
    final setup = createController(
      directory,
      requestTimeout: const Duration(seconds: 5),
    );
    addTearDown(() async {
      setup.controller.clearTopRightMessage();
      await setup.database.close();
      setup.controller.dispose();
      await directory.delete(recursive: true);
    });

    await setup.controller.initialize();
    await setup.controller.setup(displayName: '本机', password: '1234');
    await activateChat(setup);
    final chat = setup.controller.chats.single;
    await setup.controller.selectChat(chat.chatId);
    setPeerOnline(setup);

    final droppedDirectory = Directory(
      '${directory.path}${Platform.pathSeparator}资料夹',
    );
    await droppedDirectory.create();
    final first = File('${directory.path}${Platform.pathSeparator}一.txt');
    final second = File('${directory.path}${Platform.pathSeparator}二.pdf');
    await first.writeAsString('first');
    await second.writeAsBytes(List<int>.filled(16, 2));

    await setup.controller.sendDroppedFiles(
      conversationId: chat.chatId,
      filePaths: [
        droppedDirectory.path,
        first.path,
        '${directory.path}${Platform.pathSeparator}不存在.txt',
        second.path,
      ],
    );
    await _waitUntil(() => setup.controller.messages.length == 2);

    expect(setup.controller.messages.map((message) => message.fileName), [
      '一.txt',
      '二.pdf',
    ]);
  });

  test('引用附件时用文件名作为摘要，并压缩空白', () {
    ChatMessage message({
      required MessageKind kind,
      required String content,
      String? fileName,
    }) => ChatMessage(
      messageId: 'm-1',
      chatId: 'chat-1',
      senderDeviceId: 'peer-device',
      content: content,
      timestamp: DateTime.fromMillisecondsSinceEpoch(1000),
      status: MessageStatus.sent,
      kind: kind,
      fileName: fileName,
    );

    expect(
      AppController.replyPreview(
        message(kind: MessageKind.image, content: '照片.png', fileName: '照片.png'),
      ),
      '[图片]',
    );
    expect(
      AppController.replyPreview(
        message(kind: MessageKind.file, content: '报告.pdf', fileName: '报告.pdf'),
      ),
      '报告.pdf',
    );
    expect(
      AppController.replyPreview(
        message(kind: MessageKind.text, content: '  多行\n\n文本  '),
      ),
      '多行 文本',
    );
    final long = 'a' * 300;
    final preview = AppController.replyPreview(
      message(kind: MessageKind.text, content: long),
    );
    expect(preview.length, NetworkConfig.maxReplyPreviewLength + 1);
    expect(preview.endsWith('…'), isTrue);
  });

  test('自己的私聊消息可在两分钟内撤回并同步给对方', () async {
    final directory = await Directory.systemTemp.createTemp(
      'neko-chat-controller-recall-',
    );
    final setup = createController(
      directory,
      requestTimeout: const Duration(seconds: 1),
    );
    addTearDown(() async {
      await setup.database.close();
      setup.controller.dispose();
      await directory.delete(recursive: true);
    });
    await setup.controller.initialize();
    await setup.controller.setup(displayName: '本机', password: '1234');
    final sessionId = await activateChat(setup);
    setPeerOnline(setup);
    await setup.controller.selectChat(setup.controller.chats.single.chatId);
    await setup.controller.sendMessage('马上撤回');
    final message = setup.controller.messages.single;

    expect(setup.controller.canRecallMessage(message), isTrue);
    await setup.controller.recallMessage(message);

    final stored = (await setup.database.loadMessage(message.messageId))!;
    expect(stored.isRecalled, isTrue);
    expect(stored.content, isEmpty);
    expect(setup.controller.messages.single.isRecalled, isTrue);
    final recall = setup.transport.sentEnvelopes.lastWhere(
      (envelope) => envelope.type == MessageType.messageRecall,
    );
    expect(recall.payload['sessionId'], sessionId);
    expect(recall.payload['messageId'], message.messageId);
  });

  test('接收端拒绝超过两分钟的私聊撤回', () async {
    final directory = await Directory.systemTemp.createTemp(
      'neko-chat-controller-expired-recall-',
    );
    final setup = createController(
      directory,
      requestTimeout: const Duration(seconds: 1),
    );
    addTearDown(() async {
      await setup.database.close();
      setup.controller.dispose();
      await directory.delete(recursive: true);
    });
    await setup.controller.initialize();
    await setup.controller.setup(displayName: '本机', password: '1234');
    final sessionId = await activateChat(setup);
    final oldTimestamp = DateTime.now()
        .subtract(const Duration(minutes: 3))
        .millisecondsSinceEpoch;
    setup.transport.emit(
      textMessagePacket(sessionId, '不能被过期撤回', timestamp: oldTimestamp),
    );
    await _waitUntil(
      () => setup.controller.chats.single.lastMessagePreview == '不能被过期撤回',
    );
    setup.transport.emit(
      IncomingPacket(
        envelope: ProtocolEnvelope(
          type: MessageType.messageRecall,
          payload: {
            'sessionId': sessionId,
            'messageId': 'msg-1',
            'senderDeviceId': 'peer-device',
            'recalledAt': DateTime.now().millisecondsSinceEpoch,
          },
        ),
        remoteAddress: '192.168.1.20',
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect((await setup.database.loadMessage('msg-1'))?.isRecalled, isFalse);
  });

  test('群主可撤回一小时内的任意群消息，普通成员仍限自己的两分钟', () {
    final now = DateTime(2026, 9, 14, 12);
    final controller = AppController(bossKey: _FakeBossKeyService());
    addTearDown(controller.dispose);
    controller.identity = LocalIdentity(
      deviceId: 'owner',
      displayName: '群主',
      createdAt: now,
      lastLoginAt: now,
    );
    controller.groups = [
      ChatGroup(
        groupId: 'g-1',
        name: '测试群',
        ownerDeviceId: 'owner',
        createdAt: now,
      ),
    ];
    ChatMessage message(String sender, Duration age) => ChatMessage(
      messageId: '$sender-${age.inSeconds}',
      chatId: 'group:g-1',
      groupId: 'g-1',
      senderDeviceId: sender,
      content: '消息',
      timestamp: now.subtract(age),
      status: MessageStatus.sent,
    );

    expect(
      controller.canRecallMessage(
        message('member', const Duration(minutes: 59)),
        now: now,
      ),
      isTrue,
    );
    expect(
      controller.canRecallMessage(
        message('member', const Duration(minutes: 61)),
        now: now,
      ),
      isFalse,
    );
    expect(
      controller.canRecallMessage(
        message('owner', const Duration(minutes: 3)),
        now: now,
      ),
      isTrue,
    );
    expect(
      controller.canRecallMessage(
        message('owner', const Duration(minutes: 61)),
        now: now,
      ),
      isFalse,
    );
    controller.identity = LocalIdentity(
      deviceId: 'member',
      displayName: '成员',
      createdAt: now,
      lastLoginAt: now,
    );
    expect(
      controller.canRecallMessage(
        message('member', const Duration(minutes: 3)),
        now: now,
      ),
      isFalse,
    );
  });

  test('加好友限频：发送方冷却期内不会重复发起申请', () async {
    final directory = await Directory.systemTemp.createTemp(
      'neko-chat-rate-outgoing-',
    );
    final setup = createController(
      directory,
      requestTimeout: const Duration(milliseconds: 200),
    );
    addTearDown(() async {
      setup.controller.clearTopRightMessage();
      await setup.database.close();
      setup.controller.dispose();
      await directory.delete(recursive: true);
    });

    await setup.controller.initialize();
    await setup.controller.setup(displayName: '本机', password: '1234');

    setPeerOnline(setup);
    final peer = setup.controller.peers.single;
    await setup.controller.requestChat(peer);
    // 等第一条申请超时清除，模拟“刚失败就想再试一次”。
    await _waitUntil(
      () =>
          setup.controller.chatRequests.isEmpty &&
          setup.controller.chats.every(
            (chat) => chat.state == ChatSessionState.none,
          ),
    );
    final sentBefore = setup.transport.sentEnvelopes.length;

    await setup.controller.requestChat(peer);

    expect(setup.transport.sentEnvelopes.length, sentBefore);
    expect(setup.controller.chatRequests, isEmpty);
    expect(setup.controller.topRightMessage, contains('频繁'));
  });

  test('加好友限频：被添加方按设备限频并在窗口结束后恢复', () async {
    var now = DateTime(2026, 1, 1);
    final limiter = FriendRequestLimiter(
      clock: () => now,
      outgoingCooldown: Duration.zero,
      window: const Duration(seconds: 2),
      outgoingWindowLimit: 100,
      incomingPerPeerLimit: 1,
      incomingGlobalLimit: 100,
    );
    final directory = await Directory.systemTemp.createTemp(
      'neko-chat-rate-incoming-',
    );
    final setup = createController(
      directory,
      requestTimeout: const Duration(seconds: 30),
      friendRequestLimiter: limiter,
    );
    addTearDown(() async {
      setup.controller.clearTopRightMessage();
      await setup.database.close();
      setup.controller.dispose();
      await directory.delete(recursive: true);
    });

    await setup.controller.initialize();
    await setup.controller.setup(displayName: '本机', password: '1234');

    IncomingPacket request(String requestId) => IncomingPacket(
      envelope: ProtocolEnvelope(
        type: MessageType.chatRequest,
        payload: {
          'requestId': requestId,
          'deviceId': 'peer-device',
          'displayName': '李四',
        },
      ),
      remoteAddress: '192.168.1.20',
    );

    setup.transport.emit(request('rate-1'));
    await _waitUntil(() => setup.controller.chatRequests.containsKey('rate-1'));
    await setup.controller.rejectChatRequest(
      setup.controller.chatRequests['rate-1']!,
    );
    await _waitUntil(() => setup.controller.chatRequests.isEmpty);

    // 冷却窗口内再发一次：被限频静默丢弃，不生成申请。
    setup.transport.emit(request('rate-2'));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(setup.controller.chatRequests, isEmpty);

    // 窗口滑过后恢复受理。
    now = now.add(const Duration(seconds: 3));
    setup.transport.emit(request('rate-3'));
    await _waitUntil(() => setup.controller.chatRequests.containsKey('rate-3'));
  });

  test('深色模式设置持久化并在下次重启解锁前生效', () async {
    final directory = await Directory.systemTemp.createTemp(
      'neko-chat-theme-mode-',
    );
    final first = createController(
      directory,
      requestTimeout: const Duration(seconds: 30),
    );
    addTearDown(() async {
      await directory.delete(recursive: true);
    });

    await first.controller.initialize();
    await first.controller.setup(displayName: '本机', password: '1234');
    expect(first.controller.themeMode, ThemeMode.light);

    final beforeRevision = first.controller.appearanceRevision.value;
    await first.controller.setThemeMode(ThemeMode.dark);
    expect(first.controller.themeMode, ThemeMode.dark);
    expect(first.controller.appearanceRevision.value, beforeRevision + 1);
    expect(await first.database.loadSetting('theme_mode'), 'dark');

    await first.database.close();
    first.controller.dispose();

    final second = createController(
      directory,
      requestTimeout: const Duration(seconds: 30),
      hasExistingKey: true,
    );
    addTearDown(() async {
      await second.database.close();
      second.controller.dispose();
    });

    // 启动初始化（未解锁前）即从本地缓存恢复深色模式，避免解锁页闪白。
    await second.controller.initialize();
    expect(second.controller.stage, AppStage.locked);
    expect(second.controller.themeMode, ThemeMode.dark);

    // 解锁后从数据库加载并维持深色模式，且切换为跟随系统也会持久化。
    await second.controller.unlock('1234');
    expect(second.controller.themeMode, ThemeMode.dark);

    await second.controller.setThemeMode(ThemeMode.system);
    expect(await second.database.loadSetting('theme_mode'), 'system');
  });
}

Future<void> _waitUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('等待条件超时');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

class _FakeKeyProvider implements LocalDatabaseKeyProvider {
  _FakeKeyProvider({this.existingKey = false});

  final bool existingKey;
  final List<int> _key = List<int>.generate(32, (index) => index);

  @override
  Future<bool> hasExistingKey() async => existingKey;

  @override
  Future<List<int>> create(String password) async => _key;

  @override
  Future<List<int>> unlock(String password) async => _key;
}

class _FakeBossKeyService implements BossKeyService {
  BossKeyVisibilityCallback? _onVisibilityChanged;
  final List<({bool enabled, BossKeyShortcut shortcut})> configurations = [];

  List<bool> get enabledValues => [
    for (final configuration in configurations) configuration.enabled,
  ];

  void emitVisibility({required bool hidden}) =>
      _onVisibilityChanged?.call(hidden);

  @override
  Future<void> initialize(
    BossKeyVisibilityCallback onVisibilityChanged,
  ) async => _onVisibilityChanged = onVisibilityChanged;

  @override
  Future<void> configure({
    required bool enabled,
    required BossKeyShortcut shortcut,
  }) async => configurations.add((enabled: enabled, shortcut: shortcut));

  @override
  Future<void> dispose() async => _onVisibilityChanged = null;
}

class _FakeTransport implements ChatTransport {
  void Function(IncomingPacket packet)? _onPacket;
  final List<ProtocolEnvelope> sentEnvelopes = [];

  void emit(IncomingPacket packet) => _onPacket?.call(packet);

  @override
  Future<void> start(void Function(IncomingPacket packet) onPacket) async {
    _onPacket = onPacket;
  }

  @override
  Future<void> send(String ip, int port, ProtocolEnvelope envelope) async =>
      sentEnvelopes.add(envelope);

  @override
  Future<void> offerFile({
    required String transferId,
    required String filePath,
    required Set<String> allowedAddresses,
  }) async {}

  @override
  Future<void> authorizeFileDownload({
    required String transferId,
    required String remoteAddress,
  }) async {}

  @override
  Future<String> downloadFile({
    required String ip,
    required int port,
    required String transferId,
    required String messageId,
    required String fileName,
    required int expectedSize,
    String? mimeType,
    String? contentHash,
  }) async => throw UnimplementedError();

  String? localAvatarPath;
  final List<({String deviceId, String hash})> avatarDownloads = [];
  Future<String> Function(String deviceId, String hash)? avatarDownloader;

  @override
  Future<void> setLocalAvatar(String? filePath) async =>
      localAvatarPath = filePath;

  @override
  Future<String> downloadAvatar({
    required String ip,
    required int port,
    required String deviceId,
    required String expectedHash,
  }) async {
    avatarDownloads.add((deviceId: deviceId, hash: expectedHash));
    final downloader = avatarDownloader;
    if (downloader == null) throw UnimplementedError();
    return downloader(deviceId, expectedHash);
  }

  @override
  Future<void> stop() async {}
}

class _FakeNotifications implements SystemNotificationService {
  _FakeNotifications({this.focused = true});

  bool focused;
  final List<String> shown = [];
  int clearCount = 0;

  @override
  bool get appIsFocused => focused;

  @override
  Future<void> initialize() async {}

  @override
  Future<void> show({
    required String identifier,
    required String title,
    required String body,
    required NotificationCallback onClick,
  }) async => shown.add(identifier);

  @override
  Future<void> clearAll() async => clearCount += 1;

  @override
  Future<void> dispose() async {}
}

class _FakeDiscoveryService extends DiscoveryService {
  _FakeDiscoveryService()
    : super(
        identity: LocalIdentity(
          deviceId: 'fake-device',
          displayName: 'fake',
          createdAt: DateTime.fromMillisecondsSinceEpoch(0),
          lastLoginAt: DateTime.fromMillisecondsSinceEpoch(0),
        ),
        trustLookup: (_) => null,
        onPeersChanged: (_) {},
      );

  /// 控制器注册的发现回调，测试用它模拟设备上下线。
  void Function(List<DiscoveredPeer> peers)? _emitPeers;
  int startCount = 0;
  int stopCount = 0;

  void bind(void Function(List<DiscoveredPeer> peers) onPeersChanged) =>
      _emitPeers = onPeersChanged;

  void emit(List<DiscoveredPeer> peers) => _emitPeers?.call(peers);

  @override
  Future<void> start() async => startCount += 1;

  @override
  Future<void> stop() async => stopCount += 1;

  @override
  void refreshTrust() {}
}
