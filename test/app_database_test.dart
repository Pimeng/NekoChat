import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neko_chat/core/database/app_database.dart';
import 'package:neko_chat/core/models/models.dart';
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
    expect((await reopened.loadGroups()).single.name, '一班');
    expect(await reopened.loadGroupMembers('group-1'), hasLength(2));
  });
}
