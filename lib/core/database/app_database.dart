import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../config/app_paths.dart';
import '../files/attachment_path.dart';
import '../models/models.dart';

abstract interface class DatabaseBackend {
  Future<Database> open({
    required String path,
    required List<int> key,
    required OnDatabaseCreateFn onCreate,
    required OnDatabaseVersionChangeFn onUpgrade,
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
    required OnDatabaseVersionChangeFn onUpgrade,
  }) {
    return databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 6,
        onCreate: onCreate,
        onUpgrade: onUpgrade,
      ),
    );
  }
}

class AppDatabase {
  AppDatabase({
    DatabaseBackend? backend,
    Future<Directory> Function()? directory,
  }) : _backend = backend ?? PlainSqliteBackend(),
       _directory = directory ?? appDataDirectory;
  final DatabaseBackend _backend;
  final Future<Directory> Function() _directory;
  final _log = Logger('AppDatabase');
  Database? _database;
  AttachmentPathCodec? _attachmentPaths;
  String? _directoryPath;

  Database get database {
    final value = _database;
    if (value == null) throw StateError('数据库尚未打开');
    return value;
  }

  /// 附件路径编解码器。在 [open] 时根据实际数据目录创建，因此数据库、密钥和
  /// 附件始终按同一个根目录解释相对路径。
  AttachmentPathCodec get attachmentPaths {
    final value = _attachmentPaths;
    if (value == null) throw StateError('数据库尚未打开');
    return value;
  }

  /// 当前使用的数据目录，未打开数据库时为 null。界面用它告诉用户数据在哪。
  String? get directoryPath => _directoryPath;

  /// 判断路径是否位于数据目录内；数据库未打开时返回 false。
  bool isInsideDataDirectory(String path) =>
      _attachmentPaths?.isInsideRoot(path) ?? false;

  Future<void> open(List<int> databaseKey) async {
    final directory = await _directory();
    await directory.create(recursive: true);
    _directoryPath = directory.path;
    _attachmentPaths = AttachmentPathCodec(directory.path);
    _database = await _backend.open(
      path: p.join(directory.path, 'neko_chat.db'),
      key: databaseKey,
      onCreate: _createSchema,
      onUpgrade: _upgradeSchema,
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
        last_message_at INTEGER,
        unread_count INTEGER NOT NULL DEFAULT 0,
        last_message_preview TEXT
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
        status TEXT NOT NULL,
        kind TEXT NOT NULL DEFAULT 'text',
        file_name TEXT,
        file_path TEXT,
        file_size INTEGER,
        mime_type TEXT,
        transfer_id TEXT,
        file_hash TEXT,
        reply_to_message_id TEXT,
        reply_to_sender_id TEXT,
        reply_to_preview TEXT,
        mentions TEXT,
        recalled_at INTEGER,
        recalled_by_device_id TEXT
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
        created_at INTEGER NOT NULL,
        last_message_at INTEGER,
        unread_count INTEGER NOT NULL DEFAULT 0,
        last_message_preview TEXT
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
    await db.execute('''
      CREATE TABLE peer_remarks (
        device_id TEXT PRIMARY KEY,
        remark TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE group_remarks (
        group_id TEXT PRIMARY KEY,
        remark TEXT NOT NULL
      )
    ''');
    _log.info('数据库 Schema v$version 已创建');
  }

  Future<void> _upgradeSchema(
    Database db,
    int oldVersion,
    int newVersion,
  ) async {
    if (oldVersion < 2) {
      await db.execute(
        "ALTER TABLE messages ADD COLUMN kind TEXT NOT NULL DEFAULT 'text'",
      );
      await db.execute('ALTER TABLE messages ADD COLUMN file_name TEXT');
      await db.execute('ALTER TABLE messages ADD COLUMN file_path TEXT');
      await db.execute('ALTER TABLE messages ADD COLUMN file_size INTEGER');
      await db.execute('ALTER TABLE messages ADD COLUMN mime_type TEXT');
      await db.execute('ALTER TABLE messages ADD COLUMN transfer_id TEXT');
    }
    if (oldVersion < 3) {
      await db.execute('ALTER TABLE messages ADD COLUMN file_hash TEXT');
    }
    if (oldVersion < 4) {
      await db.execute(
        'ALTER TABLE messages ADD COLUMN reply_to_message_id TEXT',
      );
      await db.execute(
        'ALTER TABLE messages ADD COLUMN reply_to_sender_id TEXT',
      );
      await db.execute('ALTER TABLE messages ADD COLUMN reply_to_preview TEXT');
      await db.execute('ALTER TABLE messages ADD COLUMN mentions TEXT');
      await db.execute(
        'ALTER TABLE chats ADD COLUMN unread_count INTEGER NOT NULL DEFAULT 0',
      );
      await db.execute(
        'ALTER TABLE chats ADD COLUMN last_message_preview TEXT',
      );
      await db.execute(
        'ALTER TABLE groups ADD COLUMN unread_count INTEGER NOT NULL DEFAULT 0',
      );
      await db.execute(
        'ALTER TABLE groups ADD COLUMN last_message_preview TEXT',
      );
      await db.execute('ALTER TABLE groups ADD COLUMN last_message_at INTEGER');
    }
    if (oldVersion < 5) {
      await db.execute('''
        CREATE TABLE peer_remarks (
          device_id TEXT PRIMARY KEY,
          remark TEXT NOT NULL
        )
      ''');
      await db.execute('''
        CREATE TABLE group_remarks (
          group_id TEXT PRIMARY KEY,
          remark TEXT NOT NULL
        )
      ''');
    }
    if (oldVersion < 6) {
      final messageTables = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'messages'",
      );
      if (messageTables.isNotEmpty) {
        await db.execute('ALTER TABLE messages ADD COLUMN recalled_at INTEGER');
        await db.execute(
          'ALTER TABLE messages ADD COLUMN recalled_by_device_id TEXT',
        );
      }
    }
    _log.info('数据库 Schema 已从 v$oldVersion 升级到 v$newVersion');
  }

  /// 读取单个应用设置。未写入过的设置由上层决定默认值。
  Future<String?> loadSetting(String key) async {
    final rows = await database.query(
      'settings',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [key],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['value'] as String;
  }

  /// 以覆盖方式保存设置，避免重复点击产生多条记录。
  Future<void> saveSetting(String key, String value) => database.insert(
    'settings',
    {'key': key, 'value': value},
    conflictAlgorithm: ConflictAlgorithm.replace,
  );

  Future<Map<String, String>> loadPeerRemarks() async => {
    for (final row in await database.query('peer_remarks'))
      row['device_id'] as String: row['remark'] as String,
  };

  Future<Map<String, String>> loadGroupRemarks() async => {
    for (final row in await database.query('group_remarks'))
      row['group_id'] as String: row['remark'] as String,
  };

  Future<void> setPeerRemark(String deviceId, String? remark) => remark == null
      ? database.delete(
          'peer_remarks',
          where: 'device_id = ?',
          whereArgs: [deviceId],
        )
      : database.insert('peer_remarks', {
          'device_id': deviceId,
          'remark': remark,
        }, conflictAlgorithm: ConflictAlgorithm.replace);

  Future<void> setGroupRemark(String groupId, String? remark) => remark == null
      ? database.delete(
          'group_remarks',
          where: 'group_id = ?',
          whereArgs: [groupId],
        )
      : database.insert('group_remarks', {
          'group_id': groupId,
          'remark': remark,
        }, conflictAlgorithm: ConflictAlgorithm.replace);

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
            createdAt: DateTime.fromMillisecondsSinceEpoch(
              row['created_at'] as int,
            ),
            lastMessageAt: row['last_message_at'] == null
                ? null
                : DateTime.fromMillisecondsSinceEpoch(
                    row['last_message_at'] as int,
                  ),
            unreadCount: (row['unread_count'] as int?) ?? 0,
            lastMessagePreview: row['last_message_preview'] as String?,
          ),
        )
        .toList();
  }

  Future<void> saveChat(ChatSummary chat) async {
    // 更新已有会话时必须沿用最初的创建时间，否则每次状态变化都会把它重置。
    final existing = await database.query(
      'chats',
      columns: [
        'created_at',
        'last_message_at',
        'unread_count',
        'last_message_preview',
      ],
      where: 'chat_id = ?',
      whereArgs: [chat.chatId],
      limit: 1,
    );
    final previous = existing.isEmpty ? null : existing.first;
    final createdAt =
        chat.createdAt?.millisecondsSinceEpoch ??
        previous?['created_at'] as int? ??
        DateTime.now().millisecondsSinceEpoch;
    // 未读数和摘要只由 saveMessage / setChatUnread 维护，重存会话不会重置。
    final unreadCount = previous?['unread_count'] as int? ?? chat.unreadCount;
    final preview =
        previous?['last_message_preview'] as String? ?? chat.lastMessagePreview;
    final lastMessageAt =
        chat.lastMessageAt?.millisecondsSinceEpoch ??
        previous?['last_message_at'] as int?;
    await database.insert('chats', {
      'chat_id': chat.chatId,
      'peer_device_id': chat.peerDeviceId,
      'peer_display_name': chat.displayName,
      'session_id': chat.sessionId,
      'state': chat.state.name,
      'created_at': createdAt,
      'last_message_at': lastMessageAt,
      'unread_count': unreadCount,
      'last_message_preview': preview,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// 直接设置会话未读数并返回新的值。
  Future<int> setChatUnread(String chatId, int unreadCount) async {
    final value = unreadCount < 0 ? 0 : unreadCount;
    await database.update(
      'chats',
      {'unread_count': value},
      where: 'chat_id = ?',
      whereArgs: [chatId],
    );
    return value;
  }

  /// 直接设置群未读数并返回新的值。
  Future<int> setGroupUnread(String groupId, int unreadCount) async {
    final value = unreadCount < 0 ? 0 : unreadCount;
    await database.update(
      'groups',
      {'unread_count': value},
      where: 'group_id = ?',
      whereArgs: [groupId],
    );
    return value;
  }

  /// 会话未读数原子加一，避免并发收包时读改写互相覆盖。
  Future<int> incrementChatUnread(String chatId) =>
      _incrementUnread(table: 'chats', column: 'chat_id', value: chatId);

  /// 群未读数原子加一，避免并发收包时读改写互相覆盖。
  Future<int> incrementGroupUnread(String groupId) =>
      _incrementUnread(table: 'groups', column: 'group_id', value: groupId);

  Future<int> _incrementUnread({
    required String table,
    required String column,
    required String value,
  }) async {
    await database.rawUpdate(
      'UPDATE $table SET unread_count = unread_count + 1 WHERE $column = ?',
      [value],
    );
    final rows = await database.query(
      table,
      columns: ['unread_count'],
      where: '$column = ?',
      whereArgs: [value],
      limit: 1,
    );
    return rows.isEmpty ? 0 : (rows.first['unread_count'] as int?) ?? 0;
  }

  /// 保存消息，并返回它是否是首次写入。
  ///
  /// 网络层可能重发同一个包；调用方可以据此避免重复追加到内存列表、重复计未读。
  Future<bool> saveMessage(ChatMessage message) async {
    final inserted = await database.insert('messages', {
      'message_id': message.messageId,
      'chat_id': message.chatId,
      'group_id': message.groupId,
      'sender_device_id': message.senderDeviceId,
      'content': message.content,
      'timestamp': message.timestamp.millisecondsSinceEpoch,
      'status': message.status.name,
      'kind': message.kind.name,
      'file_name': message.fileName,
      'file_path': _encodeAttachment(message.filePath),
      'file_size': message.fileSize,
      'mime_type': message.mimeType,
      'transfer_id': message.transferId,
      'file_hash': message.fileHash,
      'reply_to_message_id': message.replyToMessageId,
      'reply_to_sender_id': message.replyToSenderId,
      'reply_to_preview': message.replyToPreview,
      'mentions': message.mentions.isEmpty
          ? null
          : jsonEncode(message.mentions),
      'recalled_at': message.recalledAt?.millisecondsSinceEpoch,
      'recalled_by_device_id': message.recalledByDeviceId,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
    if (inserted == 0) return false;
    // 只在时间前进时更新最新消息，避免历史补发把预览倒退回旧消息。
    final timestamp = message.timestamp.millisecondsSinceEpoch;
    final preview = _previewFor(message);
    if (message.groupId == null) {
      await database.rawUpdate(
        'UPDATE chats SET last_message_at = ?, last_message_preview = ? '
        'WHERE chat_id = ? AND (last_message_at IS NULL OR last_message_at <= ?)',
        [timestamp, preview, message.chatId, timestamp],
      );
    } else {
      await database.rawUpdate(
        'UPDATE groups SET last_message_at = ?, last_message_preview = ? '
        'WHERE group_id = ? AND (last_message_at IS NULL OR last_message_at <= ?)',
        [timestamp, preview, message.groupId, timestamp],
      );
    }
    return true;
  }

  String _previewFor(ChatMessage message) {
    if (message.isRecalled) return '[消息已撤回]';
    final raw = switch (message.kind) {
      MessageKind.text => message.content,
      MessageKind.image => '[图片] ${message.fileName ?? ''}',
      MessageKind.file => '[文件] ${message.fileName ?? ''}',
    };
    final normalized = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
    return normalized.length <= 120
        ? normalized
        : '${normalized.substring(0, 120)}…';
  }

  /// 最近一段时间内的群消息时间戳，用于断线重连时请求缺失的消息。
  Future<int> latestMessageTimestamp(String chatId, int fallback) async {
    final rows = await database.rawQuery(
      'SELECT MAX(CASE WHEN recalled_at > timestamp THEN recalled_at '
      'ELSE timestamp END) AS latest FROM messages WHERE chat_id = ?',
      [chatId],
    );
    final latest = rows.first['latest'] as int?;
    return latest ?? fallback;
  }

  /// 读取某会话中指定时间之后的消息，用于重连后补发。
  ///
  /// 超过上限时优先保留最近的消息，再按时间升序返回。
  Future<List<ChatMessage>> loadMessagesAfter(
    String chatId,
    int since, {
    int limit = 300,
  }) async {
    final rows = await database.rawQuery(
      'SELECT * FROM messages WHERE chat_id = ? '
      'AND (timestamp > ? OR recalled_at > ?) '
      'ORDER BY CASE WHEN recalled_at > timestamp THEN recalled_at '
      'ELSE timestamp END DESC LIMIT ?',
      [chatId, since, since, limit],
    );
    return rows.map(_messageFromRow).toList().reversed.toList();
  }

  Future<int> updateMessageStatus(String messageId, MessageStatus status) =>
      database.update(
        'messages',
        {'status': status.name},
        where: 'message_id = ? AND status != ?',
        whereArgs: [messageId, MessageStatus.recalled.name],
      );

  /// 把原消息原地替换为撤回占位，并同步修正会话列表中的最新摘要。
  /// 返回 false 表示消息不存在或已撤回，调用方据此避免重复刷新界面。
  Future<bool> recallMessage(
    String messageId, {
    required String recalledByDeviceId,
    required DateTime recalledAt,
  }) async => database.transaction((txn) async {
    final rows = await txn.query(
      'messages',
      columns: ['chat_id', 'group_id'],
      where: 'message_id = ? AND status != ?',
      whereArgs: [messageId, MessageStatus.recalled.name],
      limit: 1,
    );
    if (rows.isEmpty) return false;
    final row = rows.single;
    final changed = await txn.update(
      'messages',
      {
        'content': '',
        'status': MessageStatus.recalled.name,
        'file_name': null,
        'file_path': null,
        'file_size': null,
        'mime_type': null,
        'transfer_id': null,
        'file_hash': null,
        'reply_to_message_id': null,
        'reply_to_sender_id': null,
        'reply_to_preview': null,
        'mentions': null,
        'recalled_at': recalledAt.millisecondsSinceEpoch,
        'recalled_by_device_id': recalledByDeviceId,
      },
      where: 'message_id = ? AND status != ?',
      whereArgs: [messageId, MessageStatus.recalled.name],
    );
    if (changed == 0) return false;
    final chatId = row['chat_id'] as String;
    final latest = await txn.query(
      'messages',
      columns: ['message_id'],
      where: 'chat_id = ?',
      whereArgs: [chatId],
      orderBy: 'timestamp DESC, rowid DESC',
      limit: 1,
    );
    if (latest.isNotEmpty && latest.single['message_id'] == messageId) {
      final groupId = row['group_id'] as String?;
      await txn.update(
        groupId == null ? 'chats' : 'groups',
        {'last_message_preview': '[消息已撤回]'},
        where: groupId == null ? 'chat_id = ?' : 'group_id = ?',
        whereArgs: [groupId ?? chatId],
      );
    }
    return true;
  });

  Future<int> updateMessageAttachment(
    String messageId, {
    required String? filePath,
    required MessageStatus status,
  }) => database.update(
    'messages',
    {'file_path': _encodeAttachment(filePath), 'status': status.name},
    where: 'message_id = ? AND status != ?',
    whereArgs: [messageId, MessageStatus.recalled.name],
  );

  /// 只更新附件的本地路径，用于用户在换机后重新指定文件位置。
  Future<void> updateMessageFilePath(String messageId, String? filePath) =>
      database.update(
        'messages',
        {'file_path': _encodeAttachment(filePath)},
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

  Future<ChatMessage?> loadMessage(String messageId) async {
    final rows = await database.query(
      'messages',
      where: 'message_id = ?',
      whereArgs: [messageId],
      limit: 1,
    );
    return rows.isEmpty ? null : _messageFromRow(rows.first);
  }

  ChatMessage _messageFromRow(Map<String, Object?> row) => ChatMessage(
    messageId: row['message_id'] as String,
    chatId: row['chat_id'] as String,
    groupId: row['group_id'] as String?,
    senderDeviceId: row['sender_device_id'] as String,
    content: row['content'] as String,
    timestamp: DateTime.fromMillisecondsSinceEpoch(row['timestamp'] as int),
    status: MessageStatus.values.byName(row['status'] as String),
    kind: MessageKind.values.byName(row['kind'] as String),
    fileName: row['file_name'] as String?,
    filePath: _decodeAttachment(row['file_path'] as String?),
    fileSize: row['file_size'] as int?,
    mimeType: row['mime_type'] as String?,
    transferId: row['transfer_id'] as String?,
    fileHash: row['file_hash'] as String?,
    replyToMessageId: row['reply_to_message_id'] as String?,
    replyToSenderId: row['reply_to_sender_id'] as String?,
    replyToPreview: row['reply_to_preview'] as String?,
    mentions: _decodeMentions(row['mentions'] as String?),
    recalledAt: row['recalled_at'] == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(row['recalled_at'] as int),
    recalledByDeviceId: row['recalled_by_device_id'] as String?,
  );

  static List<String> _decodeMentions(String? value) {
    if (value == null || value.isEmpty) return const [];
    try {
      final decoded = jsonDecode(value);
      if (decoded is! List) return const [];
      return [
        for (final item in decoded)
          if (item is String) item,
      ];
    } on Object {
      return const [];
    }
  }

  Future<List<ChatGroup>> loadGroups() async {
    final rows = await database.query(
      'groups',
      orderBy: 'last_message_at DESC, created_at DESC',
    );
    return rows
        .map(
          (row) => ChatGroup(
            groupId: row['group_id'] as String,
            name: row['name'] as String,
            ownerDeviceId: row['owner_device_id'] as String,
            createdAt: DateTime.fromMillisecondsSinceEpoch(
              row['created_at'] as int,
            ),
            lastMessageAt: row['last_message_at'] == null
                ? null
                : DateTime.fromMillisecondsSinceEpoch(
                    row['last_message_at'] as int,
                  ),
            unreadCount: (row['unread_count'] as int?) ?? 0,
            lastMessagePreview: row['last_message_preview'] as String?,
          ),
        )
        .toList();
  }

  Future<void> saveGroup(ChatGroup group, List<GroupMember> members) async {
    await database.transaction((txn) async {
      final existing = await txn.query(
        'groups',
        columns: ['last_message_at', 'unread_count', 'last_message_preview'],
        where: 'group_id = ?',
        whereArgs: [group.groupId],
        limit: 1,
      );
      final previous = existing.isEmpty ? null : existing.first;
      // 未读数和摘要只由 saveMessage / setGroupUnread 维护，重存群资料不会重置。
      final lastMessageAt =
          group.lastMessageAt?.millisecondsSinceEpoch ??
          previous?['last_message_at'] as int?;
      final unreadCount =
          previous?['unread_count'] as int? ?? group.unreadCount;
      final preview =
          previous?['last_message_preview'] as String? ??
          group.lastMessagePreview;
      await txn.insert('groups', {
        'group_id': group.groupId,
        'name': group.name,
        'owner_device_id': group.ownerDeviceId,
        'created_at': group.createdAt.millisecondsSinceEpoch,
        'last_message_at': lastMessageAt,
        'unread_count': unreadCount,
        'last_message_preview': preview,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      // 成员表以传入列表为准，先清空再写入，避免移除成员后残留。
      await txn.delete(
        'group_members',
        where: 'group_id = ?',
        whereArgs: [group.groupId],
      );
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
    _attachmentPaths = null;
    _directoryPath = null;
  }

  /// 附件路径存入数据库前转成相对数据目录的形式，便于整体搬迁。
  String? _encodeAttachment(String? filePath) =>
      filePath == null ? null : attachmentPaths.encode(filePath);

  /// 读取时还原成本机绝对路径；升级前的绝对路径会原样返回。
  String? _decodeAttachment(String? storedPath) =>
      storedPath == null ? null : attachmentPaths.decode(storedPath);
}
