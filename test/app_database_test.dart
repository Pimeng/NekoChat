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

  test('消息的引用与 @ 提及可持久化', () async {
    final directory = await Directory.systemTemp.createTemp('neko-chat-reply-');
    addTearDown(() => directory.delete(recursive: true));
    final database = AppDatabase(directory: () async => directory);
    await database.open(const [1, 2, 3, 4]);
    addTearDown(database.close);

    await database.saveMessage(
      ChatMessage(
        messageId: 'm-1',
        chatId: 'group:g-1',
        groupId: 'g-1',
        senderDeviceId: 'peer-1',
        content: '收到',
        timestamp: DateTime.fromMillisecondsSinceEpoch(2000),
        status: MessageStatus.sent,
        replyToMessageId: 'm-0',
        replyToSenderId: 'peer-2',
        replyToPreview: '原始消息',
        mentions: const ['local-device', 'peer-1'],
      ),
    );

    final message = (await database.loadMessage('m-1'))!;
    expect(message.replyToMessageId, 'm-0');
    expect(message.replyToSenderId, 'peer-2');
    expect(message.replyToPreview, '原始消息');
    expect(message.mentions, ['local-device', 'peer-1']);
  });

  test('未读计数与最新消息摘要不会被会话重存覆盖', () async {
    final directory = await Directory.systemTemp.createTemp(
      'neko-chat-unread-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final database = AppDatabase(directory: () async => directory);
    await database.open(const [1, 2, 3, 4]);
    addTearDown(database.close);

    await database.saveChat(
      const ChatSummary(
        chatId: 'chat-1',
        peerDeviceId: 'peer-1',
        displayName: '李四',
        state: ChatSessionState.active,
      ),
    );
    await database.saveMessage(
      ChatMessage(
        messageId: 'm-1',
        chatId: 'chat-1',
        senderDeviceId: 'peer-1',
        content: '在吗',
        timestamp: DateTime.fromMillisecondsSinceEpoch(2000),
        status: MessageStatus.sent,
      ),
    );
    await database.setChatUnread('chat-1', 3);
    // 状态变化重新保存会话时没有携带未读与摘要。
    await database.saveChat(
      const ChatSummary(
        chatId: 'chat-1',
        peerDeviceId: 'peer-1',
        displayName: '李四',
        state: ChatSessionState.none,
      ),
    );

    final chat = (await database.loadChats()).single;
    expect(chat.unreadCount, 3);
    expect(chat.lastMessagePreview, '在吗');
    expect(chat.lastMessageAt, DateTime.fromMillisecondsSinceEpoch(2000));

    // 补发的旧消息不会把最新消息摘要倒退回更早的内容。
    await database.saveMessage(
      ChatMessage(
        messageId: 'm-0',
        chatId: 'chat-1',
        senderDeviceId: 'peer-1',
        content: '更早的消息',
        timestamp: DateTime.fromMillisecondsSinceEpoch(1000),
        status: MessageStatus.sent,
      ),
    );
    expect((await database.loadChats()).single.lastMessagePreview, '在吗');

    await database.setChatUnread('chat-1', 0);
    expect((await database.loadChats()).single.unreadCount, 0);
  });

  test('群消息更新群摘要，且可查询重连补发范围', () async {
    final directory = await Directory.systemTemp.createTemp(
      'neko-chat-group-sync-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final database = AppDatabase(directory: () async => directory);
    await database.open(const [1, 2, 3, 4]);
    addTearDown(database.close);

    final createdAt = DateTime.fromMillisecondsSinceEpoch(1000);
    const members = [
      GroupMember(
        groupId: 'g-1',
        deviceId: 'local-device',
        displayName: '我',
        role: GroupRole.owner,
      ),
      GroupMember(
        groupId: 'g-1',
        deviceId: 'peer-1',
        displayName: '李四',
        role: GroupRole.member,
      ),
    ];
    await database.saveGroup(
      ChatGroup(
        groupId: 'g-1',
        name: '一班',
        ownerDeviceId: 'local-device',
        createdAt: createdAt,
      ),
      members,
    );
    await database.saveMessage(
      ChatMessage(
        messageId: 'gm-1',
        chatId: 'group:g-1',
        groupId: 'g-1',
        senderDeviceId: 'peer-1',
        content: '大家好',
        timestamp: DateTime.fromMillisecondsSinceEpoch(3000),
        status: MessageStatus.sent,
      ),
    );
    await database.setGroupUnread('g-1', 2);

    final loaded = (await database.loadGroups()).single;
    expect(loaded.lastMessagePreview, '大家好');
    expect(loaded.unreadCount, 2);
    expect(await database.latestMessageTimestamp('group:g-1', 0), 3000);
    // 只返回指定时间之后的消息，供重连补发。
    expect(await database.loadMessagesAfter('group:g-1', 3000), isEmpty);
    expect(await database.loadMessagesAfter('group:g-1', 2500), hasLength(1));

    // 重存群资料（如改名）不会丢失未读与摘要。
    await database.saveGroup(
      ChatGroup(
        groupId: 'g-1',
        name: '二班',
        ownerDeviceId: 'local-device',
        createdAt: createdAt,
      ),
      members,
    );
    final renamed = (await database.loadGroups()).single;
    expect(renamed.name, '二班');
    expect(renamed.unreadCount, 2);
    expect(renamed.lastMessagePreview, '大家好');
  });

  test('未读自增在并发下不会丢计数', () async {
    final directory = await Directory.systemTemp.createTemp(
      'neko-chat-unread-race-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final database = AppDatabase(directory: () async => directory);
    await database.open(const [1, 2, 3, 4]);
    addTearDown(database.close);

    await database.saveChat(
      const ChatSummary(
        chatId: 'chat-1',
        peerDeviceId: 'peer-1',
        displayName: '李四',
        state: ChatSessionState.active,
      ),
    );

    await Future.wait([
      for (var index = 0; index < 20; index++)
        database.incrementChatUnread('chat-1'),
    ]);
    expect((await database.loadChats()).single.unreadCount, 20);
  });

  test('应用设置可覆盖并在重开数据库后恢复', () async {
    final directory = await Directory.systemTemp.createTemp(
      'neko-chat-settings-',
    );
    addTearDown(() => directory.delete(recursive: true));

    final first = AppDatabase(directory: () async => directory);
    await first.open(const [1, 2, 3, 4]);
    expect(await first.loadSetting('auto_receive_files'), isNull);
    await first.saveSetting('auto_receive_files', 'true');
    await first.saveSetting('auto_receive_files', 'false');
    await first.close();

    final reopened = AppDatabase(directory: () async => directory);
    await reopened.open(const [1, 2, 3, 4]);
    addTearDown(reopened.close);
    expect(await reopened.loadSetting('auto_receive_files'), 'false');
  });

  test('人员和群聊备注只按本地 ID 持久化，并可清除', () async {
    final directory = await Directory.systemTemp.createTemp(
      'neko-chat-remarks-',
    );
    addTearDown(() => directory.delete(recursive: true));

    final first = AppDatabase(directory: () async => directory);
    await first.open(const [1, 2, 3, 4]);
    await first.setPeerRemark('peer-1', '设计组小李');
    await first.setGroupRemark('group-1', '新版本战情室');
    await first.close();

    final reopened = AppDatabase(directory: () async => directory);
    await reopened.open(const [1, 2, 3, 4]);
    addTearDown(reopened.close);
    expect(await reopened.loadPeerRemarks(), {'peer-1': '设计组小李'});
    expect(await reopened.loadGroupRemarks(), {'group-1': '新版本战情室'});

    await reopened.setPeerRemark('peer-1', null);
    await reopened.setGroupRemark('group-1', null);
    expect(await reopened.loadPeerRemarks(), isEmpty);
    expect(await reopened.loadGroupRemarks(), isEmpty);
  });

  test('Schema v4 升级时创建本地备注表', () async {
    final directory = await Directory.systemTemp.createTemp(
      'neko-chat-remarks-migration-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final path = p.join(directory.path, 'neko_chat.db');
    final legacy = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(version: 4),
    );
    await legacy.close();

    final database = AppDatabase(directory: () async => directory);
    await database.open(const [1, 2, 3, 4]);
    addTearDown(database.close);
    await database.setPeerRemark('peer-1', '小李');
    await database.setGroupRemark('group-1', '项目群');

    expect(await database.loadPeerRemarks(), {'peer-1': '小李'});
    expect(await database.loadGroupRemarks(), {'group-1': '项目群'});
  });
}
