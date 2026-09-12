import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neko_chat/app/app_controller.dart';
import 'package:neko_chat/core/database/app_database.dart';
import 'package:neko_chat/core/identity/database_key_provider.dart';
import 'package:neko_chat/core/models/models.dart';
import 'package:neko_chat/core/networking/chat_transport.dart';
import 'package:neko_chat/core/networking/discovery_service.dart';
import 'package:neko_chat/core/notifications/system_notification_service.dart';
import 'package:neko_chat/core/protocol/protocol.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  ({AppController controller, AppDatabase database, _FakeTransport transport})
  createController(Directory directory, {required Duration requestTimeout}) {
    final database = AppDatabase(directory: () async => directory);
    final transport = _FakeTransport();
    final controller = AppController(
      keyProvider: _FakeKeyProvider(),
      database: database,
      transport: transport,
      notifications: _FakeNotifications(),
      discoveryFactory:
          ({
            required LocalIdentity identity,
            required TrustLookup trustLookup,
            required void Function(List<DiscoveredPeer> peers) onPeersChanged,
          }) => _FakeDiscoveryService(),
      requestTimeout: requestTimeout,
    );
    return (controller: controller, database: database, transport: transport);
  }

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
  final List<int> _key = List<int>.generate(32, (index) => index);

  @override
  Future<bool> hasExistingKey() async => false;

  @override
  Future<List<int>> create(String password) async => _key;

  @override
  Future<List<int>> unlock(String password) async => _key;
}

class _FakeTransport implements ChatTransport {
  void Function(IncomingPacket packet)? _onPacket;

  void emit(IncomingPacket packet) => _onPacket?.call(packet);

  @override
  Future<void> start(void Function(IncomingPacket packet) onPacket) async {
    _onPacket = onPacket;
  }

  @override
  Future<void> send(String ip, int port, ProtocolEnvelope envelope) async {}

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
  @override
  bool get appIsFocused => true;

  @override
  Future<void> initialize() async {}

  @override
  Future<void> show({
    required String identifier,
    required String title,
    required String body,
    required NotificationCallback onClick,
  }) async {}

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

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {}

  @override
  void refreshTrust() {}
}
