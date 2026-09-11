import 'dart:io';

import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../models/models.dart';

abstract interface class DatabaseBackend {
  Future<Database> open({
    required String path,
    required List<int> key,
    required OnDatabaseCreateFn onCreate,
  });
}

/// MVP backend. The random key is validated before this is called. Replacing this
/// class with a SQLCipher backend encrypts the database without touching repositories.
class PlainSqliteBackend implements DatabaseBackend {
  @override
  Future<Database> open({
    required String path,
    required List<int> key,
    required OnDatabaseCreateFn onCreate,
  }) {
    return databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(version: 1, onCreate: onCreate),
    );
  }
}

class AppDatabase {
  AppDatabase({
    DatabaseBackend? backend,
    Future<Directory> Function()? directory,
  }) : _backend = backend ?? PlainSqliteBackend(),
       _directory = directory ?? getApplicationSupportDirectory;
  final DatabaseBackend _backend;
  final Future<Directory> Function() _directory;
  final _log = Logger('AppDatabase');
  Database? _database;

  Database get database {
    final value = _database;
    if (value == null) throw StateError('数据库尚未打开');
    return value;
  }

  Future<void> open(List<int> databaseKey) async {
    final directory = await _directory();
    await directory.create(recursive: true);
    _database = await _backend.open(
      path: p.join(directory.path, 'neko_chat.db'),
      key: databaseKey,
      onCreate: _createSchema,
    );
    _log.info('数据库已打开');
  }

  Future<void> _createSchema(Database db, int version) async {
    await db.execute('''
      CREATE TABLE local_identities (
        device_id TEXT PRIMARY KEY,
        display_name TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        last_login_at INTEGER NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE trusted_peers (
        device_id TEXT PRIMARY KEY,
        display_name TEXT NOT NULL,
        last_known_ip TEXT NOT NULL,
        verified_at INTEGER NOT NULL,
        blocked INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await db.execute('''
      CREATE TABLE chats (
        chat_id TEXT PRIMARY KEY,
        peer_device_id TEXT NOT NULL UNIQUE,
        peer_display_name TEXT NOT NULL,
        session_id TEXT,
        state TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        last_message_at INTEGER
      )
    ''');
    await db.execute('''
      CREATE TABLE messages (
        message_id TEXT PRIMARY KEY,
        chat_id TEXT NOT NULL,
        group_id TEXT,
        sender_device_id TEXT NOT NULL,
        content TEXT NOT NULL,
        timestamp INTEGER NOT NULL,
        status TEXT NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX messages_chat_time ON messages(chat_id, timestamp)',
    );
    await db.execute('''
      CREATE TABLE groups (
        group_id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        owner_device_id TEXT NOT NULL,
        created_at INTEGER NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE group_members (
        group_id TEXT NOT NULL,
        device_id TEXT NOT NULL,
        display_name TEXT NOT NULL,
        role TEXT NOT NULL,
        PRIMARY KEY (group_id, device_id)
      )
    ''');
    await db.execute('''
      CREATE TABLE group_invites (
        invite_id TEXT PRIMARY KEY,
        group_id TEXT NOT NULL,
        inviter_device_id TEXT NOT NULL,
        status TEXT NOT NULL,
        created_at INTEGER NOT NULL
      )
    ''');
    await db.execute(
      'CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
    );
    _log.info('数据库 Schema v$version 已创建');
  }

  Future<LocalIdentity?> loadIdentity() async {
    final rows = await database.query('local_identities', limit: 1);
    if (rows.isEmpty) return null;
    final row = rows.first;
    return LocalIdentity(
      deviceId: row['device_id'] as String,
      displayName: row['display_name'] as String,
      createdAt: DateTime.fromMillisecondsSinceEpoch(row['created_at'] as int),
      lastLoginAt: DateTime.fromMillisecondsSinceEpoch(
        row['last_login_at'] as int,
      ),
    );
  }

  Future<void> saveIdentity(LocalIdentity identity) =>
      database.insert('local_identities', {
        'device_id': identity.deviceId,
        'display_name': identity.displayName,
        'created_at': identity.createdAt.millisecondsSinceEpoch,
        'last_login_at': identity.lastLoginAt.millisecondsSinceEpoch,
      }, conflictAlgorithm: ConflictAlgorithm.replace);

  Future<Map<String, TrustedPeer>> loadTrustedPeers() async {
    final rows = await database.query('trusted_peers');
    return {
      for (final row in rows)
        row['device_id'] as String: TrustedPeer(
          deviceId: row['device_id'] as String,
          displayName: row['display_name'] as String,
          lastKnownIp: row['last_known_ip'] as String,
          verifiedAt: DateTime.fromMillisecondsSinceEpoch(
            row['verified_at'] as int,
          ),
          blocked: (row['blocked'] as int) == 1,
        ),
    };
  }

  Future<void> saveTrustedPeer(TrustedPeer peer) =>
      database.insert('trusted_peers', {
        'device_id': peer.deviceId,
        'display_name': peer.displayName,
        'last_known_ip': peer.lastKnownIp,
        'verified_at': peer.verifiedAt.millisecondsSinceEpoch,
        'blocked': peer.blocked ? 1 : 0,
      }, conflictAlgorithm: ConflictAlgorithm.replace);

  Future<void> setPeerBlocked(String deviceId, bool blocked) => database.update(
    'trusted_peers',
    {'blocked': blocked ? 1 : 0},
    where: 'device_id = ?',
    whereArgs: [deviceId],
  );

  Future<List<ChatSummary>> loadChats() async {
    final rows = await database.query(
      'chats',
      orderBy: 'last_message_at DESC, created_at DESC',
    );
    return rows
        .map(
          (row) => ChatSummary(
            chatId: row['chat_id'] as String,
            peerDeviceId: row['peer_device_id'] as String,
            displayName: row['peer_display_name'] as String,
            sessionId: row['session_id'] as String?,
            state: ChatSessionState.values.byName(row['state'] as String),
            lastMessageAt: row['last_message_at'] == null
                ? null
                : DateTime.fromMillisecondsSinceEpoch(
                    row['last_message_at'] as int,
                  ),
          ),
        )
        .toList();
  }

  Future<void> saveChat(ChatSummary chat) => database.insert('chats', {
    'chat_id': chat.chatId,
    'peer_device_id': chat.peerDeviceId,
    'peer_display_name': chat.displayName,
    'session_id': chat.sessionId,
    'state': chat.state.name,
    'created_at': DateTime.now().millisecondsSinceEpoch,
    'last_message_at': chat.lastMessageAt?.millisecondsSinceEpoch,
  }, conflictAlgorithm: ConflictAlgorithm.replace);

  Future<void> saveMessage(ChatMessage message) async {
    await database.insert('messages', {
      'message_id': message.messageId,
      'chat_id': message.chatId,
      'group_id': message.groupId,
      'sender_device_id': message.senderDeviceId,
      'content': message.content,
      'timestamp': message.timestamp.millisecondsSinceEpoch,
      'status': message.status.name,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
    if (message.groupId == null) {
      await database.update(
        'chats',
        {'last_message_at': message.timestamp.millisecondsSinceEpoch},
        where: 'chat_id = ?',
        whereArgs: [message.chatId],
      );
    }
  }

  Future<void> updateMessageStatus(String messageId, MessageStatus status) =>
      database.update(
        'messages',
        {'status': status.name},
        where: 'message_id = ?',
        whereArgs: [messageId],
      );

  Future<List<ChatMessage>> loadMessages(String chatId) async {
    final rows = await database.query(
      'messages',
      where: 'chat_id = ?',
      whereArgs: [chatId],
      orderBy: 'timestamp ASC',
    );
    return rows.map(_messageFromRow).toList();
  }

  ChatMessage _messageFromRow(Map<String, Object?> row) => ChatMessage(
    messageId: row['message_id'] as String,
    chatId: row['chat_id'] as String,
    groupId: row['group_id'] as String?,
    senderDeviceId: row['sender_device_id'] as String,
    content: row['content'] as String,
    timestamp: DateTime.fromMillisecondsSinceEpoch(row['timestamp'] as int),
    status: MessageStatus.values.byName(row['status'] as String),
  );

  Future<List<ChatGroup>> loadGroups() async {
    final rows = await database.query('groups', orderBy: 'created_at DESC');
    return rows
        .map(
          (row) => ChatGroup(
            groupId: row['group_id'] as String,
            name: row['name'] as String,
            ownerDeviceId: row['owner_device_id'] as String,
            createdAt: DateTime.fromMillisecondsSinceEpoch(
              row['created_at'] as int,
            ),
          ),
        )
        .toList();
  }

  Future<void> saveGroup(ChatGroup group, List<GroupMember> members) async {
    await database.transaction((txn) async {
      await txn.insert('groups', {
        'group_id': group.groupId,
        'name': group.name,
        'owner_device_id': group.ownerDeviceId,
        'created_at': group.createdAt.millisecondsSinceEpoch,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      for (final member in members) {
        await txn.insert('group_members', {
          'group_id': member.groupId,
          'device_id': member.deviceId,
          'display_name': member.displayName,
          'role': member.role.name,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
  }

  Future<List<GroupMember>> loadGroupMembers(String groupId) async {
    final rows = await database.query(
      'group_members',
      where: 'group_id = ?',
      whereArgs: [groupId],
    );
    return rows
        .map(
          (row) => GroupMember(
            groupId: row['group_id'] as String,
            deviceId: row['device_id'] as String,
            displayName: row['display_name'] as String,
            role: GroupRole.values.byName(row['role'] as String),
          ),
        )
        .toList();
  }

  Future<void> saveGroupMember(GroupMember member) =>
      database.insert('group_members', {
        'group_id': member.groupId,
        'device_id': member.deviceId,
        'display_name': member.displayName,
        'role': member.role.name,
      }, conflictAlgorithm: ConflictAlgorithm.replace);

  Future<void> removeGroupMember(String groupId, String deviceId) =>
      database.delete(
        'group_members',
        where: 'group_id = ? AND device_id = ?',
        whereArgs: [groupId, deviceId],
      );

  Future<void> deleteGroup(String groupId) async {
    await database.transaction((txn) async {
      await txn.delete(
        'group_members',
        where: 'group_id = ?',
        whereArgs: [groupId],
      );
      await txn.delete('messages', where: 'group_id = ?', whereArgs: [groupId]);
      await txn.delete('groups', where: 'group_id = ?', whereArgs: [groupId]);
    });
  }

  Future<void> close() async {
    await _database?.close();
    _database = null;
  }
}
