import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neko_chat/core/database/app_database.dart';
import 'package:neko_chat/core/models/models.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  test('身份、信任、私聊历史和群成员可跨数据库重开恢复', () async {
    final directory = await Directory.systemTemp.createTemp(
      'neko-chat-db-test-',
    );
    addTearDown(() => directory.delete(recursive: true));
    const key = <int>[1, 2, 3, 4];
    final createdAt = DateTime.fromMillisecondsSinceEpoch(1000);

    final first = AppDatabase(directory: () async => directory);
    await first.open(key);
    final identity = LocalIdentity(
      deviceId: 'local-device',
      displayName: '张三',
      createdAt: createdAt,
      lastLoginAt: createdAt,
    );
    await first.saveIdentity(identity);
    await first.saveTrustedPeer(
      TrustedPeer(
        deviceId: 'peer-device',
        displayName: '李四',
        lastKnownIp: '192.168.10.23',
        verifiedAt: createdAt,
      ),
    );
    await first.saveChat(
      ChatSummary(
        chatId: 'private-chat',
        peerDeviceId: 'peer-device',
        displayName: '李四',
        state: ChatSessionState.active,
        sessionId: 'session-1',
      ),
    );
    await first.saveMessage(
      ChatMessage(
        messageId: 'message-1',
        chatId: 'private-chat',
        senderDeviceId: 'local-device',
        content: '你好',
        timestamp: createdAt,
        status: MessageStatus.sent,
      ),
    );
    await first.saveMessage(
      ChatMessage(
        messageId: 'file-message-1',
        chatId: 'private-chat',
        senderDeviceId: 'peer-device',
        content: '照片.png',
        timestamp: createdAt.add(const Duration(seconds: 1)),
        status: MessageStatus.awaitingAcceptance,
        kind: MessageKind.image,
        fileName: '照片.png',
        fileSize: 12 * 1024 * 1024,
        mimeType: 'image/png',
        transferId: 'transfer-1',
        fileHash:
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      ),
    );
    final group = ChatGroup(
      groupId: 'group-1',
      name: '一班',
      ownerDeviceId: 'local-device',
      createdAt: createdAt,
    );
    await first.saveGroup(group, [
      GroupMember(
        groupId: group.groupId,
        deviceId: 'local-device',
        displayName: '张三',
        role: GroupRole.owner,
      ),
      GroupMember(
        groupId: group.groupId,
        deviceId: 'peer-device',
        displayName: '李四',
        role: GroupRole.member,
      ),
    ]);
    await first.close();

    final reopened = AppDatabase(directory: () async => directory);
    await reopened.open(key);
    addTearDown(reopened.close);

    expect((await reopened.loadIdentity())?.deviceId, 'local-device');
    expect(
      (await reopened.loadTrustedPeers())['peer-device']?.lastKnownIp,
      '192.168.10.23',
    );
    expect((await reopened.loadChats()).single.sessionId, 'session-1');
    final messages = await reopened.loadMessages('private-chat');
    expect(messages, hasLength(2));
    expect(messages.first.content, '你好');
    expect(messages.last.kind, MessageKind.image);
    expect(messages.last.status, MessageStatus.awaitingAcceptance);
    expect(messages.last.fileName, '照片.png');
    expect(messages.last.fileSize, 12 * 1024 * 1024);
    expect(messages.last.mimeType, 'image/png');
    expect(messages.last.transferId, 'transfer-1');
    expect(
      messages.last.fileHash,
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    );
    expect((await reopened.loadGroups()).single.name, '一班');
    expect(await reopened.loadGroupMembers('group-1'), hasLength(2));
  });

  test('会话重新保存时保留最初的创建时间', () async {
    final directory = await Directory.systemTemp.createTemp(
      'neko-chat-chat-created-',
    );
    addTearDown(() => directory.delete(recursive: true));
    const key = <int>[1, 2, 3, 4];
    final database = AppDatabase(directory: () async => directory);
    await database.open(key);
    addTearDown(database.close);

    final createdAt = DateTime.fromMillisecondsSinceEpoch(1000);
    await database.saveChat(
      ChatSummary(
        chatId: 'chat-1',
        peerDeviceId: 'peer-1',
        displayName: '李四',
        state: ChatSessionState.pendingOutgoing,
        createdAt: createdAt,
      ),
    );
    // 模拟状态迁移时调用方没有携带 createdAt 的情况。
    await database.saveChat(
      const ChatSummary(
        chatId: 'chat-1',
        peerDeviceId: 'peer-1',
        displayName: '李四',
        state: ChatSessionState.active,
        sessionId: 'session-1',
      ),
    );

    final chat = (await database.loadChats()).single;
    expect(chat.state, ChatSessionState.active);
    expect(chat.sessionId, 'session-1');
    expect(chat.createdAt, createdAt);
  });

  test('附件以相对路径入库，搬迁数据目录后仍能定位', () async {
    final root = await Directory.systemTemp.createTemp('neko-chat-attach-');
    addTearDown(() => root.delete(recursive: true));
    final first = Directory(p.join(root.path, 'A'));
    final second = Directory(p.join(root.path, 'B'));
    const key = <int>[1, 2, 3, 4];
    final absolute = p.join(first.path, 'received_images', 'ab12.png');

    final database = AppDatabase(directory: () async => first);
    await database.open(key);
    await database.saveMessage(
      ChatMessage(
        messageId: 'image-1',
        chatId: 'chat-1',
        senderDeviceId: 'peer-1',
        content: 'ab12.png',
        timestamp: DateTime.fromMillisecondsSinceEpoch(1000),
        status: MessageStatus.sent,
        kind: MessageKind.image,
        fileName: 'ab12.png',
        filePath: absolute,
      ),
    );

    // 数据库里存的是相对数据目录的路径，而不是绝对路径。
    final row = (await database.database.query(
      'messages',
      columns: ['file_path'],
      where: 'message_id = ?',
      whereArgs: ['image-1'],
    )).single;
    expect(row['file_path'], 'received_images/ab12.png');
    // 读回时仍还原成本机绝对路径，界面无需改动。
    expect((await database.loadMessage('image-1'))?.filePath, absolute);
    await database.close();

    // 模拟把整个数据目录搬到另一个位置：只搬运数据库文件。
    await second.create(recursive: true);
    await for (final entry in first.list()) {
      if (entry is! File) continue;
      if (!p.basename(entry.path).startsWith('neko_chat.db')) continue;
      await entry.copy(p.join(second.path, p.basename(entry.path)));
    }

    final moved = AppDatabase(directory: () async => second);
    await moved.open(key);
    addTearDown(moved.close);

    expect(
      (await moved.loadMessage('image-1'))?.filePath,
      p.join(second.path, 'received_images', 'ab12.png'),
    );
  });

  test('重新指定文件位置后按新路径解析', () async {
    final root = await Directory.systemTemp.createTemp('neko-chat-relink-');
    addTearDown(() => root.delete(recursive: true));
    final database = AppDatabase(directory: () async => root);
    await database.open(const [1, 2, 3, 4]);
    addTearDown(database.close);

    await database.saveMessage(
      ChatMessage(
        messageId: 'file-1',
        chatId: 'chat-1',
        senderDeviceId: 'local-device',
        content: 'report.pdf',
        timestamp: DateTime.fromMillisecondsSinceEpoch(1000),
        status: MessageStatus.sent,
        kind: MessageKind.file,
        fileName: 'report.pdf',
        // 换机后失效的原始绝对路径。
        filePath: p.join(root.path, '..', 'other-machine', 'report.pdf'),
      ),
    );
    expect(
      database.isInsideDataDirectory(
        (await database.loadMessage('file-1'))!.filePath!,
      ),
      isFalse,
    );

    // 用户重新指定到数据目录内的文件，重新绑定后应存成相对路径。
    final relocated = p.join(root.path, 'received_files', 'report.pdf');
    await database.updateMessageFilePath('file-1', relocated);

    final row = (await database.database.query(
      'messages',
      columns: ['file_path'],
      where: 'message_id = ?',
      whereArgs: ['file-1'],
    )).single;
    expect(row['file_path'], 'received_files/report.pdf');
    expect((await database.loadMessage('file-1'))?.filePath, relocated);
    expect(database.isInsideDataDirectory(relocated), isTrue);
  });
}
