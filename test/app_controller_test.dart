import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neko_chat/app/app_controller.dart';
import 'package:neko_chat/core/boss_key/boss_key_service.dart';
import 'package:neko_chat/core/config/network_config.dart';
import 'package:neko_chat/core/database/app_database.dart';
import 'package:neko_chat/core/identity/database_key_provider.dart';
import 'package:neko_chat/core/models/models.dart';
import 'package:neko_chat/core/networking/chat_transport.dart';
import 'package:neko_chat/core/networking/discovery_service.dart';
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
  setUpAll(sqfliteFfiInit);

  _Setup createController(
    Directory directory, {
    required Duration requestTimeout,
    SystemNotificationService? notifications,
    bool hasExistingKey = false,
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

  test('局域网相互发现默认开启，并可即时停止、清空设备和恢复', () async {
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
      '照片.png',
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
