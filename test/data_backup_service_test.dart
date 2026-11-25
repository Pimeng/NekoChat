import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:neko_chat/app/app_controller.dart';
import 'package:neko_chat/core/backup/data_backup_service.dart';
import 'package:neko_chat/core/boss_key/boss_key_service.dart';
import 'package:neko_chat/core/database/app_database.dart';
import 'package:neko_chat/core/files/content_hash.dart';
import 'package:neko_chat/core/identity/database_key_provider.dart';
import 'package:neko_chat/core/models/models.dart';
import 'package:neko_chat/core/networking/chat_transport.dart';
import 'package:neko_chat/core/networking/discovery_service.dart';
import 'package:neko_chat/core/notifications/system_notification_service.dart';
import 'package:neko_chat/core/protocol/protocol.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _NoopTransport implements ChatTransport {
  @override
  Future<void> start(void Function(IncomingPacket packet) onPacket) async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> setLocalAvatar(String? filePath) async {}

  @override
  Future<String> downloadAvatar({
    required String ip,
    required int port,
    required String deviceId,
    required String expectedHash,
  }) async => '';

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
  }) async => '';
}

class _NoopNotifications implements SystemNotificationService {
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
  Future<void> clearAll() async {}

  @override
  Future<void> dispose() async {}
}

class _NoopBossKey implements BossKeyService {
  @override
  Future<void> initialize(BossKeyVisibilityCallback onVisibilityChanged) async {}

  @override
  Future<void> configure({
    required bool enabled,
    required BossKeyShortcut shortcut,
  }) async {}

  @override
  Future<void> dispose() async {}
}

class _NoopDiscovery extends DiscoveryService {
  _NoopDiscovery({
    required super.identity,
    required super.trustLookup,
    required super.onPeersChanged,
  });

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  const backupService = DataBackupService();

  AppController createRealStorageController(Directory dataDir) => AppController(
    keyProvider: EncryptedFileDatabaseKeyProvider(directory: () async => dataDir),
    database: AppDatabase(directory: () async => dataDir),
    transport: _NoopTransport(),
    notifications: _NoopNotifications(),
    bossKey: _NoopBossKey(),
    discoveryFactory:
        ({
          required LocalIdentity identity,
          required TrustLookup trustLookup,
          required void Function(List<DiscoveredPeer> peers) onPeersChanged,
        }) => _NoopDiscovery(
          identity: identity,
          trustLookup: trustLookup,
          onPeersChanged: onPeersChanged,
        ),
  );

  test('完整备份并在重置数据后还原，身份、聊天记录与表情包（含备注排序）全部恢复', () async {
    final sandbox = await Directory.systemTemp.createTemp('neko_backup_e2e_');
    addTearDown(() async {
      if (await sandbox.exists()) await sandbox.delete(recursive: true);
    });

    final dataDir = Directory(p.join(sandbox.path, 'neko_chat_data'));
    final backupFile = File(p.join(sandbox.path, 'full.nekobackup'));

    // 1. 初始化应用，写入聊天记录、收藏表情包、附件等。
    final controller = createRealStorageController(dataDir);
    await controller.initialize();
    expect(controller.stage, AppStage.setup);
    await controller.setup(displayName: '橘猫测试', password: 'cat-password-123');
    expect(controller.stage, AppStage.ready);
    final originalDeviceId = controller.identity!.deviceId;

    // 准备两张模拟表情包图片并加入收藏。
    final sticker1Source = File(p.join(sandbox.path, 'cat_happy.png'));
    final sticker1Bytes = Uint8List.fromList([
      0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, // PNG header
      ...List<int>.generate(256, (i) => i),
    ]);
    await sticker1Source.writeAsBytes(sticker1Bytes, flush: true);

    final sticker2Source = File(p.join(sandbox.path, 'cat_wave.gif'));
    final sticker2Bytes = Uint8List.fromList([
      0x47, 0x49, 0x46, 0x38, 0x39, 0x61, // GIF89a header
      ...List<int>.generate(128, (i) => 255 - i),
    ]);
    await sticker2Source.writeAsBytes(sticker2Bytes, flush: true);

    expect(await controller.addFavoriteStickerFromPath(sticker1Source.path), isTrue);
    expect(await controller.addFavoriteStickerFromPath(sticker2Source.path), isTrue);
    expect(controller.favoriteStickers.length, 2);

    await controller.setFavoriteStickerRemark(
      controller.favoriteStickers[0],
      '挥手猫猫',
    );
    await controller.setFavoriteStickerRemark(
      controller.favoriteStickers[1],
      '开心猫猫',
    );

    // 写入模拟已接收图片附件。
    final receivedImagesDir = Directory(p.join(dataDir.path, 'received_images'));
    await receivedImagesDir.create(recursive: true);
    final receivedImage = File(p.join(receivedImagesDir.path, 'photo_01.png'));
    await receivedImage.writeAsBytes([1, 2, 3, 4, 5, 6, 7, 8], flush: true);

    // 2. 创建完整备份。
    final manifest = await controller.createBackup(
      destinationPath: backupFile.path,
      includeAttachments: true,
    );
    expect(await backupFile.exists(), isTrue);
    expect(manifest.stickerCount, 2);
    expect(manifest.includesAttachments, isTrue);
    expect(manifest.displayName, '橘猫测试');
    expect(
      manifest.entries.any((e) => e.path.startsWith('stickers/')),
      isTrue,
    );
    expect(
      manifest.entries.any((e) => e.path == 'received_images/photo_01.png'),
      isTrue,
    );

    // 3. 模拟应用彻底重置：销毁控制器并删除整个数据目录。
    controller.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await dataDir.delete(recursive: true);
    expect(await dataDir.exists(), isFalse);

    // 4. 在全新重置后的 setup 状态直接从备份还原。
    final restoredController = createRealStorageController(dataDir);
    addTearDown(restoredController.dispose);
    await restoredController.initialize();
    expect(restoredController.stage, AppStage.setup);

    final restoredManifest = await restoredController.restoreFromBackup(
      backupFile.path,
    );
    expect(restoredManifest.stickerCount, 2);
    expect(restoredController.stage, AppStage.locked);
    expect(restoredController.authNoticeMessage, contains('2 个收藏表情'));

    // 5. 使用原密码解锁，验证身份、表情包文件内容、备注、排序和聊天附件均完整恢复。
    await restoredController.unlock('cat-password-123');
    expect(restoredController.stage, AppStage.ready);
    expect(restoredController.identity?.deviceId, originalDeviceId);
    expect(restoredController.identity?.displayName, '橘猫测试');
    expect(restoredController.favoriteStickers.length, 2);
    expect(restoredController.favoriteStickers[0].remark, '挥手猫猫');
    expect(restoredController.favoriteStickers[1].remark, '开心猫猫');
    expect(
      await File(restoredController.favoriteStickers[0].filePath).readAsBytes(),
      sticker2Bytes,
    );
    expect(
      await File(restoredController.favoriteStickers[1].filePath).readAsBytes(),
      sticker1Bytes,
    );
    expect(
      await File(p.join(dataDir.path, 'received_images', 'photo_01.png'))
          .readAsBytes(),
      [1, 2, 3, 4, 5, 6, 7, 8],
    );
  });

  test('不包含聊天附件时仍完整备份和还原收藏表情包', () async {
    final sandbox = await Directory.systemTemp.createTemp('neko_backup_noatt_');
    addTearDown(() async {
      if (await sandbox.exists()) await sandbox.delete(recursive: true);
    });

    final dataDir = Directory(p.join(sandbox.path, 'data'));
    await dataDir.create(recursive: true);
    await File(p.join(dataDir.path, 'database-key.json')).writeAsString('{}');
    await File(p.join(dataDir.path, 'neko_chat.db')).writeAsBytes([10, 20, 30]);
    final stickersDir = Directory(p.join(dataDir.path, 'stickers'));
    await stickersDir.create();
    await File(p.join(stickersDir.path, 's1.gif')).writeAsBytes([7, 8, 9]);
    final filesDir = Directory(p.join(dataDir.path, 'received_files'));
    await filesDir.create();
    await File(p.join(filesDir.path, 'big.bin')).writeAsBytes([9, 9, 9, 9]);

    final backupFile = File(p.join(sandbox.path, 'core_only.nekobackup'));
    final manifest = await backupService.createBackup(
      dataDirectory: dataDir,
      destinationFile: backupFile,
      exportDatabaseSnapshot: (dest) async {
        await File(p.join(dataDir.path, 'neko_chat.db')).copy(dest);
      },
      includeAttachments: false,
    );

    expect(manifest.includesAttachments, isFalse);
    expect(manifest.stickerCount, 1);
    expect(manifest.entries.any((e) => e.path == 'stickers/s1.gif'), isTrue);
    expect(
      manifest.entries.any((e) => e.path.startsWith('received_files/')),
      isFalse,
    );
  });

  test('损坏或被篡改的备份文件会被拒绝且不会破坏现有数据', () async {
    final sandbox = await Directory.systemTemp.createTemp('neko_backup_corrupt_');
    addTearDown(() async {
      if (await sandbox.exists()) await sandbox.delete(recursive: true);
    });

    final dataDir = Directory(p.join(sandbox.path, 'data'));
    await dataDir.create(recursive: true);
    final keyFile = File(p.join(dataDir.path, 'database-key.json'));
    final dbFile = File(p.join(dataDir.path, 'neko_chat.db'));
    await keyFile.writeAsString('{"version":1}');
    await dbFile.writeAsBytes([1, 2, 3, 4]);
    final stickersDir = Directory(p.join(dataDir.path, 'stickers'));
    await stickersDir.create();
    final stickerFile = File(p.join(stickersDir.path, 'cat.png'));
    await stickerFile.writeAsBytes([0x89, 0x50, 0x4E, 0x47, 42, 43]);

    final backupFile = File(p.join(sandbox.path, 'tampered.nekobackup'));
    await backupService.createBackup(
      dataDirectory: dataDir,
      destinationFile: backupFile,
      exportDatabaseSnapshot: (dest) async => dbFile.copy(dest),
    );

    // 修改备份文件最后一个字节（破坏表情包内容，触发 SHA-256 校验失败）。
    final bytes = await backupFile.readAsBytes();
    bytes[bytes.length - 1] ^= 0xFF;
    await backupFile.writeAsBytes(bytes, flush: true);

    // 修改现有数据以验证还原失败后现有数据未被触动。
    await keyFile.writeAsString('{"version":1,"live":true}');
    var beforeSwapCalled = false;

    await expectLater(
      backupService.restoreBackup(
        sourceFile: backupFile,
        dataDirectory: dataDir,
        beforeSwap: () async => beforeSwapCalled = true,
      ),
      throwsA(isA<BackupException>()),
    );
    expect(beforeSwapCalled, isFalse);
    expect(await keyFile.readAsString(), '{"version":1,"live":true}');
  });

  test('非法格式与包含路径穿越的恶意备份会被拒绝', () async {
    final sandbox = await Directory.systemTemp.createTemp('neko_backup_sec_');
    addTearDown(() async {
      if (await sandbox.exists()) await sandbox.delete(recursive: true);
    });

    final invalidFile = File(p.join(sandbox.path, 'invalid.nekobackup'));
    await invalidFile.writeAsString('not a backup');
    await expectLater(
      backupService.inspectBackup(invalidFile),
      throwsA(isA<BackupException>()),
    );

    // 构造一个带 `../escape.txt` 路径穿越条目的伪造备份。
    final dummyHash = sha256String('x');
    final maliciousManifest = utf8.encode(
      jsonEncode({
        'formatVersion': 1,
        'createdAt': DateTime.now().toUtc().toIso8601String(),
        'includesAttachments': false,
        'stickerCount': 0,
        'fileCount': 3,
        'totalBytes': 3,
        'entries': [
          {
            'path': 'database-key.json',
            'size': 1,
            'storedSize': 1,
            'compressed': false,
            'sha256': dummyHash,
          },
          {
            'path': 'neko_chat.db',
            'size': 1,
            'storedSize': 1,
            'compressed': false,
            'sha256': dummyHash,
          },
          {
            'path': '../escape.txt',
            'size': 1,
            'storedSize': 1,
            'compressed': false,
            'sha256': dummyHash,
          },
        ],
      }),
    );
    final headerLen = ByteData(4)
      ..setUint32(0, maliciousManifest.length, Endian.big);
    final maliciousFile = File(p.join(sandbox.path, 'malicious.nekobackup'));
    await maliciousFile.writeAsBytes([
      0x4E, 0x45, 0x4B, 0x4F, 0x42, 0x4B, 0x50, 1,
      ...headerLen.buffer.asUint8List(),
      ...maliciousManifest,
      0x78, 0x78, 0x78,
    ]);

    await expectLater(
      backupService.inspectBackup(maliciousFile),
      throwsA(isA<BackupException>()),
    );
  });
}
