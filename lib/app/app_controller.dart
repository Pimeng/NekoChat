import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:logging/logging.dart';
import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;
import 'package:pasteboard/pasteboard.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';

import '../core/config/network_config.dart';
import '../core/boss_key/boss_key_service.dart';
import '../core/database/app_database.dart';
import '../core/files/attachment_path.dart';
import '../core/files/content_hash.dart';
import '../core/files/open_path.dart';
import '../core/identity/database_key_provider.dart';
import '../core/identity/identity_service.dart';
import '../core/models/models.dart';
import '../core/networking/chat_transport.dart';
import '../core/networking/discovery_service.dart';
import '../core/notifications/system_notification_service.dart';
import '../core/protocol/protocol.dart';
import '../features/chat/chat_state_machine.dart';

enum AppStage { booting, setup, locked, ready, error }

class AppController extends ChangeNotifier {
  AppController({
    LocalDatabaseKeyProvider? keyProvider,
    AppDatabase? database,
    ChatTransport? transport,
    SystemNotificationService? notifications,
    BossKeyService? bossKey,
    DiscoveryServiceFactory? discoveryFactory,
    this.onBossKeyVisibilityChanged,
    this._requestTimeout = NetworkConfig.requestTimeout,
  }) : _keyProvider = keyProvider ?? EncryptedFileDatabaseKeyProvider(),
       _database = database ?? AppDatabase(),
       _transport = transport ?? WebSocketChatTransport(),
       _notifications = notifications ?? DesktopSystemNotificationService(),
       _bossKey = bossKey ?? WindowsBossKeyService(),
       _discoveryFactory = discoveryFactory ?? _defaultDiscoveryFactory;

  static const _uuid = Uuid();
  static const _autoReceiveFilesSetting = 'auto_receive_files';
  static const _autoReceiveFileLimitSetting = 'auto_receive_file_limit_bytes';
  static const _profileAvatarSetting = 'profile_avatar_path';
  static const _windowsNotificationsSetting = 'windows_notifications';
  static const _lanDiscoverySetting = 'lan_discovery_enabled';
  static const _bossKeySetting = 'boss_key_enabled';
  static const _bossKeyShortcutSetting = 'boss_key_shortcut';
  static const _bossKeyNotifyWhenHiddenSetting = 'boss_key_notify_when_hidden';
  final LocalDatabaseKeyProvider _keyProvider;
  final AppDatabase _database;
  final ChatTransport _transport;
  final SystemNotificationService _notifications;
  final BossKeyService _bossKey;
  final DiscoveryServiceFactory _discoveryFactory;
  final Duration _requestTimeout;
  final FutureOr<void> Function(bool hidden)? onBossKeyVisibilityChanged;
  final _log = Logger('AppController');
  DiscoveryService? _discovery;

  static DiscoveryService _defaultDiscoveryFactory({
    required LocalIdentity identity,
    required TrustLookup trustLookup,
    required void Function(List<DiscoveredPeer> peers) onPeersChanged,
  }) => DiscoveryService(
    identity: identity,
    trustLookup: trustLookup,
    onPeersChanged: onPeersChanged,
  );

  AppStage stage = AppStage.booting;
  String? errorMessage;
  String? topRightMessage;
  IconData topRightIcon = Icons.block;
  LocalIdentity? identity;
  String? profileAvatarPath;

  /// 本机头像的 SHA-256，用于向其他设备声明头像是否变化。
  String? profileAvatarHash;

  /// 局域网内其他设备同步过来的头像本地路径，按 deviceId 索引。
  final Map<String, String> peerAvatarPaths = {};
  final Map<String, String> _peerAvatarHashes = {};
  final Set<String> _avatarDownloadsInFlight = {};

  /// 当前数据目录。数据库、解锁密钥和已接收的附件都在这里，整体拷贝即可搬走。
  String? dataDirectory;
  Map<String, TrustedPeer> trustedPeers = {};
  List<DiscoveredPeer> peers = [];
  List<ChatSummary> chats = [];
  List<ChatGroup> groups = [];

  /// 本机在每个群里的角色缓存，用于同步判断管理员权限（如撤回）。
  final Map<String, GroupRole> _myGroupRoles = {};

  /// 每个群的成员角色缓存，加载过成员名单后可用于同步渲染角色标签。
  final Map<String, Map<String, GroupRole>> _groupMemberRoles = {};
  Map<String, String> peerRemarks = {};
  Map<String, String> groupRemarks = {};
  final Map<String, ChatRequest> chatRequests = {};
  final Map<String, Timer> _chatRequestTimers = {};
  Timer? _topRightMessageTimer;
  final Map<String, GroupInvitation> groupInvitations = {};
  final Map<String, Map<String, dynamic>> _pendingGroupPayloads = {};
  final Map<String, ({String groupId, String peerDeviceId})>
  _outgoingGroupInvites = {};
  String? selectedChatId;
  String? selectedGroupId;
  List<ChatMessage> messages = [];
  final Set<String> _openConversationWindows = {};

  /// 自动接收小于安全阈值的附件；大文件始终需要手动确认。
  bool autoReceiveFiles = true;

  /// 小于该大小的附件可自动下载；达到上限后由接收方手动确认。
  int autoReceiveFileLimitBytes = NetworkConfig.defaultAutoReceiveLimitBytes;

  /// 是否允许应用发送 Windows 系统通知。
  bool windowsNotificationsEnabled = true;

  /// 是否广播本机并监听局域网内其他 NekoChat 设备，默认开启。
  bool lanDiscoveryEnabled = true;

  /// 老板键默认关闭；开启后由 Windows 全局注册 Alt+F。
  bool bossKeyEnabled = false;
  BossKeyShortcut bossKeyShortcut = BossKeyShortcut.altF;

  /// 老板键隐藏窗口后是否仍弹出系统通知，默认关闭以免泄露应用仍在运行。
  bool bossKeyNotifyWhenHidden = false;

  /// 老板键隐藏期间暂停系统通知，避免通知泄露应用仍在运行。
  bool bossKeyHidden = false;
  String? bossKeyError;

  /// 当前正在引用的消息。存在时下一条消息会带上引用信息，发送后自动清空。
  ChatMessage? replyingTo;

  /// 本次上线后已经触发过群历史补发的设备，避免重复请求。
  final Set<String> _historySyncedDevices = {};

  Future<void> initialize() async {
    try {
      stage = await _keyProvider.hasExistingKey()
          ? AppStage.locked
          : AppStage.setup;
    } on Object catch (error, stack) {
      _fail('无法读取本地身份数据', error, stack);
    }
    notifyListeners();
  }

  Future<void> setup({
    required String displayName,
    required String password,
  }) async {
    if (stage != AppStage.setup) return;
    try {
      final key = await _keyProvider.create(password);
      await _database.open(key);
      identity = await IdentityService(_database).create(displayName);
      await _enterReady();
    } on Object catch (error, stack) {
      _fail(_friendlyError(error), error, stack, keepStage: AppStage.setup);
    }
  }

  Future<void> unlock(String password) async {
    if (stage != AppStage.locked) return;
    try {
      final key = await _keyProvider.unlock(password);
      await _database.open(key);
      identity = await IdentityService(_database).restore();
      if (identity == null) throw StateError('身份数据库为空，未生成新身份以保护原数据');
      await _enterReady();
    } on InvalidPasswordException {
      errorMessage = '密码错误';
      stage = AppStage.locked;
      notifyListeners();
    } on Object catch (error, stack) {
      _fail(_friendlyError(error), error, stack, keepStage: AppStage.locked);
    }
  }

  Future<void> _enterReady() async {
    autoReceiveFiles = _settingBool(
      await _database.loadSetting(_autoReceiveFilesSetting),
      fallback: true,
    );
    autoReceiveFileLimitBytes =
        _settingInt(
          await _database.loadSetting(_autoReceiveFileLimitSetting),
          fallback: NetworkConfig.defaultAutoReceiveLimitBytes,
        ).clamp(
          NetworkConfig.minAutoReceiveLimitBytes,
          NetworkConfig.maxAutoReceiveLimitBytes,
        );
    windowsNotificationsEnabled = _settingBool(
      await _database.loadSetting(_windowsNotificationsSetting),
      fallback: true,
    );
    lanDiscoveryEnabled = _settingBool(
      await _database.loadSetting(_lanDiscoverySetting),
      fallback: true,
    );
    bossKeyEnabled = _settingBool(
      await _database.loadSetting(_bossKeySetting),
      fallback: false,
    );
    bossKeyShortcut = BossKeyShortcut.decode(
      await _database.loadSetting(_bossKeyShortcutSetting),
    );
    bossKeyNotifyWhenHidden = _settingBool(
      await _database.loadSetting(_bossKeyNotifyWhenHiddenSetting),
      fallback: false,
    );
    peerRemarks = await _database.loadPeerRemarks();
    groupRemarks = await _database.loadGroupRemarks();
    final storedAvatarPath = await _database.loadSetting(_profileAvatarSetting);
    if (storedAvatarPath != null && storedAvatarPath.isNotEmpty) {
      final resolved = _database.attachmentPaths.decode(storedAvatarPath);
      if (await File(resolved).exists()) profileAvatarPath = resolved;
    }
    profileAvatarHash = profileAvatarPath == null
        ? null
        : await sha256File(File(profileAvatarPath!));
    await _transport.setLocalAvatar(profileAvatarPath);
    await _loadCachedPeerAvatars();
    trustedPeers = await _database.loadTrustedPeers();
    chats = await _database.loadChats();
    await _recoverInterruptedRequests();
    groups = await _database.loadGroups();
    for (final group in groups) {
      _rememberMyRole(group.groupId, await _database.loadGroupMembers(group.groupId));
    }
    final localIdentity = identity!;
    await _notifications.initialize();
    await _bossKey.initialize(_handleBossKeyVisibilityChanged);
    if (bossKeyEnabled) {
      try {
        await _bossKey.configure(enabled: true, shortcut: bossKeyShortcut);
      } on Object catch (error, stack) {
        bossKeyEnabled = false;
        bossKeyError =
            '${bossKeyShortcut.displayLabel} 注册失败，'
            '可能已被其他程序占用';
        _log.warning('老板键注册失败', error, stack);
      }
    }
    await _transport.start(_onPacket);
    _discovery = _discoveryFactory(
      identity: localIdentity,
      trustLookup: (id) => trustedPeers[id],
      onPeersChanged: _handlePeersChanged,
    );
    _discovery!.updateAvatarHash(profileAvatarHash);
    if (lanDiscoveryEnabled) await _discovery!.start();
    errorMessage = null;
    dataDirectory = _database.directoryPath;
    stage = AppStage.ready;
    _log.info('应用已就绪，deviceId=${localIdentity.deviceId}');
    notifyListeners();
  }

  Future<void> setAutoReceiveFiles(bool value) async {
    if (autoReceiveFiles == value) return;
    await _database.saveSetting(_autoReceiveFilesSetting, value.toString());
    autoReceiveFiles = value;
    notifyListeners();
  }

  Future<void> pickProfileAvatar() async {
    final result = await FilePicker.pickFile(
      dialogTitle: '选择头像',
      type: FileType.custom,
      allowedExtensions: const ['png', 'jpg', 'jpeg', 'webp', 'bmp'],
    );
    final path = result?.path;
    if (path != null) await setProfileAvatarFromPath(path);
  }

  Future<void> setProfileAvatarFromPath(String sourcePath) async {
    final source = File(sourcePath);
    if (!await source.exists()) throw ArgumentError('头像文件不存在');
    final size = await source.length();
    if (size <= 0 || size > NetworkConfig.maxProfileAvatarBytes) {
      throw ArgumentError('头像图片不能超过 20 MB');
    }
    final mimeType = lookupMimeType(source.path);
    if (mimeType?.startsWith('image/') != true) {
      throw ArgumentError('请选择 PNG、JPG、WebP 或 BMP 图片');
    }
    final extension = p.extension(source.path).toLowerCase();
    final hash = await sha256File(source);
    final directory = Directory(p.join(_database.directoryPath!, 'profile'));
    await directory.create(recursive: true);
    final target = File(p.join(directory.path, 'avatar_$hash$extension'));
    if (!await target.exists()) {
      final partial = File('${target.path}.part');
      if (await partial.exists()) await partial.delete();
      await source.copy(partial.path);
      await partial.rename(target.path);
    }
    final previous = profileAvatarPath;
    await _database.saveSetting(
      _profileAvatarSetting,
      _database.attachmentPaths.encode(target.path),
    );
    profileAvatarPath = target.path;
    profileAvatarHash = hash;
    await _transport.setLocalAvatar(target.path);
    _discovery?.updateAvatarHash(hash);
    await _deletePreviousProfileAvatar(previous, except: target.path);
    notifyListeners();
  }

  Future<void> removeProfileAvatar() async {
    final previous = profileAvatarPath;
    await _database.saveSetting(_profileAvatarSetting, '');
    profileAvatarPath = null;
    profileAvatarHash = null;
    await _transport.setLocalAvatar(null);
    _discovery?.updateAvatarHash(null);
    await _deletePreviousProfileAvatar(previous);
    notifyListeners();
  }

  Future<void> _deletePreviousProfileAvatar(
    String? path, {
    String? except,
  }) async {
    if (path == null ||
        path == except ||
        !_database.isInsideDataDirectory(path)) {
      return;
    }
    final file = File(path);
    if (await file.exists()) await file.delete();
  }

  /// 启动时读取数据目录里已经同步过的对端头像，避免每次上线都重新下载。
  Future<void> _loadCachedPeerAvatars() async {
    final base = _database.directoryPath;
    if (base == null) return;
    final directory = Directory(p.join(base, 'avatars'));
    if (!await directory.exists()) return;
    await for (final entity in directory.list()) {
      if (entity is! File) continue;
      final name = p.basename(entity.path);
      if (name.endsWith('.part')) continue;
      final separator = name.indexOf('_');
      if (separator <= 0) continue;
      final deviceId = name.substring(0, separator);
      var hash = name.substring(separator + 1);
      final dot = hash.indexOf('.');
      if (dot >= 0) hash = hash.substring(0, dot);
      if (!isSha256Hex(hash)) continue;
      peerAvatarPaths[deviceId] = entity.path;
      _peerAvatarHashes[deviceId] = hash;
    }
  }

  /// 对端头像本地路径；未同步成功时返回 null，由界面回退到首字母头像。
  String? peerAvatarPath(String deviceId) => peerAvatarPaths[deviceId];

  /// 发现对端头像哈希变化时按需下载，失败会在下一次公告时重试。
  Future<void> _syncPeerAvatar(DiscoveredPeer peer) async {
    final hash = peer.avatarHash;
    if (hash == null) {
      if (peerAvatarPaths.remove(peer.deviceId) != null) {
        _peerAvatarHashes.remove(peer.deviceId);
        notifyListeners();
      }
      return;
    }
    if (_peerAvatarHashes[peer.deviceId] == hash &&
        peerAvatarPaths.containsKey(peer.deviceId)) {
      return;
    }
    if (!_avatarDownloadsInFlight.add(peer.deviceId)) return;
    try {
      final path = await _transport.downloadAvatar(
        ip: peer.ip,
        port: peer.port,
        deviceId: peer.deviceId,
        expectedHash: hash,
      );
      peerAvatarPaths[peer.deviceId] = path;
      _peerAvatarHashes[peer.deviceId] = hash;
      notifyListeners();
    } on Object catch (error, stack) {
      _log.fine('同步 ${peer.deviceId} 的头像失败', error, stack);
    } finally {
      _avatarDownloadsInFlight.remove(peer.deviceId);
    }
  }

  Future<void> setDisplayName(String value) async {
    final normalized = value.trim();
    if (!isValidDisplayName(normalized)) {
      throw ArgumentError('昵称长度应为 1～${NetworkConfig.maxDisplayNameLength} 个字符');
    }
    final current = identity!;
    if (current.displayName == normalized) return;
    final updated = current.copyWith(displayName: normalized);
    await _database.saveIdentity(updated);
    identity = updated;
    _discovery?.updateIdentity(updated);

    for (final group in groups) {
      final members = await _database.loadGroupMembers(group.groupId);
      final me = members
          .where((member) => member.deviceId == updated.deviceId)
          .firstOrNull;
      if (me == null) continue;
      await _database.saveGroupMember(
        GroupMember(
          groupId: me.groupId,
          deviceId: me.deviceId,
          displayName: normalized,
          role: me.role,
        ),
      );
      await _fanOutGroupControl(group.groupId, members, 'profile', {
        'displayName': normalized,
      });
    }
    notifyListeners();
  }

  Future<void> setAutoReceiveFileLimitBytes(int value) async {
    final normalized = value.clamp(
      NetworkConfig.minAutoReceiveLimitBytes,
      NetworkConfig.maxAutoReceiveLimitBytes,
    );
    if (autoReceiveFileLimitBytes == normalized) return;
    await _database.saveSetting(
      _autoReceiveFileLimitSetting,
      normalized.toString(),
    );
    autoReceiveFileLimitBytes = normalized;
    notifyListeners();
  }

  Future<void> setWindowsNotificationsEnabled(bool value) async {
    if (windowsNotificationsEnabled == value) return;
    await _database.saveSetting(_windowsNotificationsSetting, value.toString());
    windowsNotificationsEnabled = value;
    notifyListeners();
  }

  Future<void> setLanDiscoveryEnabled(bool value) async {
    if (lanDiscoveryEnabled == value) return;
    final discovery = _discovery;
    if (value) {
      await discovery?.start();
    } else {
      await discovery?.stop();
    }
    await _database.saveSetting(_lanDiscoverySetting, value.toString());
    lanDiscoveryEnabled = value;
    if (!value) {
      _historySyncedDevices.clear();
      peers = [];
    }
    notifyListeners();
  }

  String peerDisplayName(String deviceId, String originalName) =>
      peerRemarks[deviceId] ?? originalName;

  String groupDisplayName(String groupId, String originalName) =>
      groupRemarks[groupId] ?? originalName;

  Future<void> setPeerRemark(String deviceId, String value) async {
    final remark = _normalizeRemark(value);
    await _database.setPeerRemark(deviceId, remark);
    if (remark == null) {
      peerRemarks.remove(deviceId);
    } else {
      peerRemarks[deviceId] = remark;
    }
    notifyListeners();
  }

  Future<void> setGroupRemark(String groupId, String value) async {
    final remark = _normalizeRemark(value);
    await _database.setGroupRemark(groupId, remark);
    if (remark == null) {
      groupRemarks.remove(groupId);
    } else {
      groupRemarks[groupId] = remark;
    }
    notifyListeners();
  }

  Future<void> setBossKeyEnabled(bool value) async {
    if (bossKeyEnabled == value) return;
    final previous = bossKeyEnabled;
    try {
      await _bossKey.configure(enabled: value, shortcut: bossKeyShortcut);
      await _database.saveSetting(_bossKeySetting, value.toString());
      bossKeyEnabled = value;
      bossKeyError = null;
      if (!value) bossKeyHidden = false;
      notifyListeners();
    } on Object catch (error, stack) {
      try {
        await _bossKey.configure(enabled: previous, shortcut: bossKeyShortcut);
      } on Object {
        // 恢复失败时保留原界面状态，下次启动会重新注册。
      }
      bossKeyError = value
          ? '无法启用 ${bossKeyShortcut.displayLabel}，该快捷键可能已被占用'
          : '无法关闭老板键';
      _log.warning('更新老板键失败', error, stack);
      _showTopRightMessage(bossKeyError!, icon: Icons.keyboard_alt_outlined);
      notifyListeners();
    }
  }

  Future<void> setBossKeyNotifyWhenHidden(bool value) async {
    if (bossKeyNotifyWhenHidden == value) return;
    await _database.saveSetting(
      _bossKeyNotifyWhenHiddenSetting,
      value.toString(),
    );
    bossKeyNotifyWhenHidden = value;
    notifyListeners();
  }

  Future<bool> setBossKeyShortcut(BossKeyShortcut value) async {
    if (bossKeyShortcut == value) return true;
    try {
      await _bossKey.configure(enabled: bossKeyEnabled, shortcut: value);
      await _database.saveSetting(_bossKeyShortcutSetting, value.encode());
      bossKeyShortcut = value;
      bossKeyError = null;
      notifyListeners();
      return true;
    } on Object catch (error, stack) {
      try {
        await _bossKey.configure(
          enabled: bossKeyEnabled,
          shortcut: bossKeyShortcut,
        );
      } on Object {
        // Windows runner 也会尝试恢复旧组合，这里再做一次最佳努力恢复。
      }
      bossKeyError = '无法使用 ${value.displayLabel}，该快捷键可能已被占用';
      _log.warning('更新老板键快捷键失败', error, stack);
      _showTopRightMessage(bossKeyError!, icon: Icons.keyboard_alt_outlined);
      notifyListeners();
      return false;
    }
  }

  bool get _systemNotificationsAllowed =>
      windowsNotificationsEnabled &&
      (!bossKeyHidden || bossKeyNotifyWhenHidden);

  void _handleBossKeyVisibilityChanged(bool hidden) {
    bossKeyHidden = hidden;
    if (hidden) unawaited(_notifications.clearAll());
    final handler = onBossKeyVisibilityChanged;
    if (handler != null) unawaited(Future.sync(() => handler(hidden)));
    notifyListeners();
  }

  Future<void> requestChat(DiscoveredPeer peer) async {
    final existing = chats
        .where(
          (chat) =>
              chat.peerDeviceId == peer.deviceId &&
              chat.state == ChatSessionState.active,
        )
        .firstOrNull;
    if (existing != null) {
      await selectChat(existing.chatId);
      return;
    }
    final hasPending = chatRequests.values.any(
      (request) => request.peerDeviceId == peer.deviceId,
    );
    if (!ChatStateMachine.canStartRequest(
      online: peer.online,
      blocked: trustedPeers[peer.deviceId]?.blocked == true,
      active: false,
      hasPendingRequest: hasPending,
    )) {
      return;
    }
    final requestId = _uuid.v4();
    final request = ChatRequest(
      requestId: requestId,
      peerDeviceId: peer.deviceId,
      displayName: peer.displayName,
      ip: peer.ip,
      verificationCode: verificationCode(
        requestId: requestId,
        requesterDeviceId: identity!.deviceId,
        recipientDeviceId: peer.deviceId,
      ),
      incoming: false,
    );
    chatRequests[requestId] = request;
    _scheduleRequestTimeout(request);
    await _upsertChat(
      peer.deviceId,
      peer.displayName,
      ChatSessionState.pendingOutgoing,
    );
    notifyListeners();
    try {
      await _transport.send(
        peer.ip,
        peer.port,
        ProtocolEnvelope(
          type: MessageType.chatRequest,
          payload: {
            'requestId': requestId,
            'deviceId': identity!.deviceId,
            'displayName': identity!.displayName,
          },
        ),
      );
      _log.info('已向 ${peer.deviceId} 发送聊天邀请 $requestId');
    } on Object catch (error, stack) {
      _removeChatRequest(requestId);
      await _upsertChat(peer.deviceId, peer.displayName, ChatSessionState.none);
      _log.warning('聊天邀请发送失败', error, stack);
      errorMessage = '无法连接 ${peerDisplayName(peer.deviceId, peer.displayName)}';
      notifyListeners();
    }
  }

  Future<void> acceptChatRequest(ChatRequest request) async {
    if (!request.incoming ||
        !identical(chatRequests[request.requestId], request)) {
      return;
    }
    _removeChatRequest(request.requestId);
    final sessionId = _uuid.v4();
    final peer = TrustedPeer(
      deviceId: request.peerDeviceId,
      displayName: request.displayName,
      lastKnownIp: request.ip,
      verifiedAt: DateTime.now(),
    );
    trustedPeers[peer.deviceId] = peer;
    await _database.saveTrustedPeer(peer);
    await _upsertChat(
      peer.deviceId,
      peer.displayName,
      ChatSessionState.active,
      sessionId: sessionId,
    );
    _discovery?.refreshTrust();
    notifyListeners();
    await _sendToAddress(
      request.ip,
      ProtocolEnvelope(
        type: MessageType.chatAccept,
        payload: {
          'requestId': request.requestId,
          'sessionId': sessionId,
          'deviceId': identity!.deviceId,
          'displayName': identity!.displayName,
        },
      ),
    );
  }

  Future<void> rejectChatRequest(ChatRequest request) async {
    if (!identical(chatRequests[request.requestId], request)) return;
    _removeChatRequest(request.requestId);
    await _upsertChat(
      request.peerDeviceId,
      request.displayName,
      ChatSessionState.rejected,
    );
    notifyListeners();
    if (request.incoming) {
      await _sendToAddress(
        request.ip,
        ProtocolEnvelope(
          type: MessageType.chatReject,
          payload: {
            'requestId': request.requestId,
            'deviceId': identity!.deviceId,
          },
        ),
      );
    }
  }

  /// 撤回正在等待对方确认的聊天邀请，并通知对方撤销待确认提示。
  Future<void> cancelChatRequest(ChatRequest request) async {
    if (request.incoming ||
        !identical(chatRequests[request.requestId], request)) {
      return;
    }
    _removeChatRequest(request.requestId);
    await _upsertChat(
      request.peerDeviceId,
      request.displayName,
      ChatSessionState.none,
    );
    notifyListeners();
    await _sendToAddress(
      request.ip,
      ProtocolEnvelope(
        type: MessageType.chatReject,
        payload: {
          'requestId': request.requestId,
          'deviceId': identity!.deviceId,
          'cancelled': true,
        },
      ),
    );
  }

  Future<void> selectChat(String chatId) async {
    selectedGroupId = null;
    selectedChatId = chatId;
    replyingTo = null;
    await _clearUnread(chatId: chatId);
    messages = await _database.loadMessages(chatId);
    notifyListeners();
  }

  Future<void> sendMessage(String content) async {
    await _sendMessageTo(
      content,
      chatId: selectedChatId,
      groupId: selectedGroupId,
      reply: replyingTo,
    );
  }

  Future<void> _sendMessageTo(
    String content, {
    required String? chatId,
    required String? groupId,
    required ChatMessage? reply,
  }) async {
    final normalized = content.trim();
    if (normalized.isEmpty) return;
    if (groupId != null) {
      await _sendGroupMessage(groupId, normalized, reply: reply);
      return;
    }
    final chat = chats.where((value) => value.chatId == chatId).firstOrNull;
    if (chat == null ||
        chat.state != ChatSessionState.active ||
        chat.sessionId == null) {
      return;
    }
    final message = ChatMessage(
      messageId: _uuid.v4(),
      chatId: chat.chatId,
      senderDeviceId: identity!.deviceId,
      content: normalized,
      timestamp: DateTime.now(),
      status: MessageStatus.pending,
      replyToMessageId: reply?.messageId,
      replyToSenderId: reply?.senderDeviceId,
      replyToPreview: reply == null ? null : replyPreview(reply),
    );
    if (identical(replyingTo, reply)) replyingTo = null;
    await _database.saveMessage(message);
    if (selectedChatId == chat.chatId) messages = [...messages, message];
    await _reloadChats();
    notifyListeners();
    final peer = _onlinePeer(chat.peerDeviceId);
    if (peer == null) {
      await _setMessageStatus(message.messageId, MessageStatus.failed);
      return;
    }
    try {
      await _transport.send(
        peer.ip,
        peer.port,
        ProtocolEnvelope(
          type: MessageType.message,
          payload: {
            'sessionId': chat.sessionId,
            'messageId': message.messageId,
            'senderDeviceId': identity!.deviceId,
            'timestamp': message.timestamp.millisecondsSinceEpoch,
            'content': normalized,
            ..._replyPayload(reply),
          },
        ),
      );
      await _setMessageStatus(message.messageId, MessageStatus.sent);
    } on Object catch (error, stack) {
      _log.warning('消息发送失败', error, stack);
      await _setMessageStatus(message.messageId, MessageStatus.failed);
    }
  }

  /// 把被引用消息的元数据放进协议载荷；没有引用时返回空表。
  Map<String, dynamic> _replyPayload(ChatMessage? source) {
    if (source == null) return const {};
    return {
      'replyToMessageId': source.messageId,
      'replyToSenderId': source.senderDeviceId,
      'replyToPreview': replyPreview(source),
    };
  }

  /// 打开文件选择框，只返回可暂存在输入框里的附件，不直接发送。
  Future<List<PendingAttachment>> pickAttachments() async {
    final result = await FilePicker.pickFile(dialogTitle: '选择要发送的图片或文件');
    final filePath = result?.path;
    if (filePath == null) return const [];
    final attachment = await pendingAttachment(filePath);
    return attachment == null ? const [] : [attachment];
  }

  /// 读取剪贴板里的图片或文件，复制到临时目录后返回待发送附件，不直接发送。
  Future<List<PendingAttachment>> readClipboardAttachments() async {
    try {
      final clipboardFiles = await Pasteboard.files();
      final attachments = <PendingAttachment>[];
      for (final path in clipboardFiles) {
        if (!await File(path).exists()) continue;
        final attachment = await pendingAttachment(path);
        if (attachment != null) attachments.add(attachment);
      }
      if (attachments.isNotEmpty) return attachments;

      final imageBytes = await Pasteboard.image;
      if (imageBytes == null || imageBytes.isEmpty) return const [];
      final contentHash = await sha256Bytes(imageBytes);
      final temporaryDirectory = await getTemporaryDirectory();
      final clipboardDirectory = Directory(
        p.join(temporaryDirectory.path, 'neko_chat_clipboard'),
      );
      await clipboardDirectory.create(recursive: true);
      final imageFile = File(
        p.join(clipboardDirectory.path, '$contentHash.png'),
      );
      if (!await imageFile.exists()) {
        await imageFile.writeAsBytes(imageBytes, flush: true);
      }
      final attachment = await pendingAttachment(imageFile.path);
      return attachment == null ? const [] : [attachment];
    } on Object catch (error, stack) {
      _log.warning('读取剪贴板附件失败', error, stack);
      return const [];
    }
  }

  /// 校验并描述一个待发送附件。接收策略由对端决定，发送端不按大小拦截。
  Future<PendingAttachment?> pendingAttachment(String filePath) async {
    final file = File(filePath);
    if (!await file.exists()) {
      _showTopRightMessage('所选文件不存在', icon: Icons.error_outline);
      return null;
    }
    final fileSize = await file.length();
    final mimeType = lookupMimeType(file.path) ?? 'application/octet-stream';
    return PendingAttachment(
      path: file.path,
      fileName: p.basename(file.path),
      fileSize: fileSize,
      mimeType: mimeType,
      isImage: mimeType.startsWith('image/'),
    );
  }

  /// 把从系统文件管理器拖入的文件立即发送到拖放发生时的会话。
  ///
  /// Windows 的拖放事件不会区分文件与目录，因此这里再次检查实体类型；
  /// 目录和已经失效的路径会被忽略，多个有效文件保持资源管理器给出的顺序。
  Future<void> sendDroppedFiles({
    required String conversationId,
    required Iterable<String> filePaths,
  }) async {
    final attachments = <PendingAttachment>[];
    for (final filePath in filePaths) {
      if (!await FileSystemEntity.isFile(filePath)) continue;
      final attachment = await pendingAttachment(filePath);
      if (attachment != null) attachments.add(attachment);
    }
    if (attachments.isEmpty) return;
    await sendMessageWithAttachments(
      conversationId: conversationId,
      content: '',
      attachments: attachments,
    );
  }

  /// 发送输入框里的文字与附件：文字先发（引用挂在文字上），附件按顺序紧跟其后。
  ///
  /// 没有文字时引用会落到第一个附件上，这样「引用 + 图片」也能成立。
  Future<void> sendMessageWithAttachments({
    String? conversationId,
    required String content,
    required List<PendingAttachment> attachments,
  }) => sendMessageWithAttachmentsTo(
    conversationId:
        conversationId ??
        (selectedGroupId == null ? selectedChatId : 'group:$selectedGroupId'),
    content: content,
    attachments: attachments,
    reply: replyingTo,
  );

  /// 向一个固定会话发送文字和附件，供不跟随主窗口选择的独立会话窗口使用。
  Future<void> sendMessageWithAttachmentsTo({
    required String? conversationId,
    required String content,
    required List<PendingAttachment> attachments,
    ChatMessage? reply,
  }) async {
    if (content.trim().isEmpty && attachments.isEmpty) return;
    final groupId = conversationId?.startsWith('group:') == true
        ? conversationId!.substring('group:'.length)
        : null;
    final chatId = groupId == null ? conversationId : null;
    if (content.trim().isNotEmpty) {
      await _sendMessageTo(
        content,
        chatId: chatId,
        groupId: groupId,
        reply: reply,
      );
    }
    for (var index = 0; index < attachments.length; index++) {
      await _sendFileTo(
        attachments[index].path,
        chatId: chatId,
        groupId: groupId,
        reply: content.trim().isEmpty && index == 0 ? reply : null,
      );
    }
  }

  /// 读取指定会话的持久化消息，不改变主窗口当前选中的会话。
  Future<List<ChatMessage>> loadMessagesForConversation(
    String conversationId,
  ) => _database.loadMessages(conversationId);

  /// 登记独立窗口正在展示的会话，并在打开时清除该会话未读数。
  Future<void> setConversationWindowOpen(
    String conversationId,
    bool open,
  ) async {
    if (open) {
      _openConversationWindows.add(conversationId);
      if (conversationId.startsWith('group:')) {
        await _clearUnread(groupId: conversationId.substring('group:'.length));
      } else {
        await _clearUnread(chatId: conversationId);
      }
      notifyListeners();
    } else {
      _openConversationWindows.remove(conversationId);
    }
  }

  bool _isConversationOpen(String conversationId) =>
      _openConversationWindows.contains(conversationId) ||
      (conversationId.startsWith('group:')
          ? selectedGroupId == conversationId.substring('group:'.length)
          : selectedChatId == conversationId);

  Future<void> sendFile(String filePath) async {
    await _sendFileTo(
      filePath,
      chatId: selectedChatId,
      groupId: selectedGroupId,
      reply: replyingTo,
    );
  }

  Future<void> _sendFileTo(
    String filePath, {
    required String? chatId,
    required String? groupId,
    required ChatMessage? reply,
  }) async {
    final file = File(filePath);
    if (!await file.exists()) {
      errorMessage = '所选文件不存在';
      notifyListeners();
      return;
    }
    final fileSize = await file.length();
    final mimeType = lookupMimeType(file.path) ?? 'application/octet-stream';
    final fileHash = mimeType.startsWith('image/')
        ? await sha256File(file)
        : null;
    if (groupId != null) {
      await _sendGroupFile(
        groupId,
        file,
        fileSize,
        mimeType,
        fileHash,
        reply: reply,
      );
      return;
    }
    final chat = chats.where((value) => value.chatId == chatId).firstOrNull;
    if (chat == null ||
        chat.state != ChatSessionState.active ||
        chat.sessionId == null) {
      return;
    }
    final peer = _onlinePeer(chat.peerDeviceId);
    if (peer == null) {
      errorMessage =
          '${peerDisplayName(chat.peerDeviceId, chat.displayName)} '
          '当前离线，无法发送文件';
      notifyListeners();
      return;
    }
    final message = _localFileMessage(
      chatId: chat.chatId,
      file: file,
      fileSize: fileSize,
      mimeType: mimeType,
      fileHash: fileHash,
      reply: reply,
    );
    if (identical(replyingTo, reply)) replyingTo = null;
    await _database.saveMessage(message);
    if (selectedChatId == chat.chatId) messages = [...messages, message];
    notifyListeners();
    try {
      await _transport.offerFile(
        transferId: message.transferId!,
        filePath: file.path,
        allowedAddresses: {peer.ip},
      );
      await _transport.send(
        peer.ip,
        peer.port,
        ProtocolEnvelope(
          type: MessageType.fileOffer,
          payload: _filePayload(message, sessionId: chat.sessionId),
        ),
      );
    } on Object catch (error, stack) {
      _log.warning('文件发送失败', error, stack);
      await _setMessageStatus(message.messageId, MessageStatus.failed);
      errorMessage = '文件发送失败：$error';
      notifyListeners();
    }
  }

  ChatMessage _localFileMessage({
    required String chatId,
    required File file,
    required int fileSize,
    required String mimeType,
    required String? fileHash,
    String? groupId,
    ChatMessage? reply,
  }) {
    return ChatMessage(
      messageId: _uuid.v4(),
      chatId: chatId,
      groupId: groupId,
      senderDeviceId: identity!.deviceId,
      content: p.basename(file.path),
      timestamp: DateTime.now(),
      // 是否自动接收只能由接收端自己的设置决定；发送端统一等待接收响应。
      status: MessageStatus.awaitingAcceptance,
      kind: mimeType.startsWith('image/')
          ? MessageKind.image
          : MessageKind.file,
      fileName: p.basename(file.path),
      filePath: file.path,
      fileSize: fileSize,
      mimeType: mimeType,
      transferId: _uuid.v4(),
      fileHash: fileHash,
      replyToMessageId: reply?.messageId,
      replyToSenderId: reply?.senderDeviceId,
      replyToPreview: reply == null ? null : replyPreview(reply),
    );
  }

  Map<String, dynamic> _filePayload(ChatMessage message, {String? sessionId}) =>
      {
        'sessionId': ?sessionId,
        'groupId': ?message.groupId,
        'messageId': message.messageId,
        'senderDeviceId': identity!.deviceId,
        'timestamp': message.timestamp.millisecondsSinceEpoch,
        'transferId': message.transferId,
        'fileName': message.fileName,
        'fileSize': message.fileSize,
        'mimeType': message.mimeType,
        'fileHash': ?message.fileHash,
        'replyToMessageId': ?message.replyToMessageId,
        'replyToSenderId': ?message.replyToSenderId,
        'replyToPreview': ?message.replyToPreview,
      };

  Future<void> retryFileDownload(ChatMessage message) async {
    if (message.transferId == null ||
        message.fileName == null ||
        message.fileSize == null) {
      return;
    }
    final peer = _onlinePeer(message.senderDeviceId);
    if (peer == null) {
      errorMessage = '发送方当前离线，无法重试下载';
      notifyListeners();
      return;
    }
    await _acceptIncomingFile(message, peer.ip, peer.port);
  }

  Future<void> openAttachment(ChatMessage message) async {
    final path = message.filePath;
    if (path == null || !await File(path).exists()) {
      _reportMissingAttachment(message);
      return;
    }
    if (!await launchUrl(Uri.file(path))) {
      errorMessage = '无法打开文件';
      notifyListeners();
    }
  }

  Future<void> openAttachmentFolder(ChatMessage message) async {
    final path = message.filePath;
    if (path == null) {
      _reportMissingAttachment(message);
      return;
    }
    // 文件本身不在了，但上级目录还在时仍然把它打开，方便用户自己找一找。
    final directory = File(path).parent.path;
    if (!await File(path).exists()) {
      if (!await Directory(directory).exists()) {
        _reportMissingAttachment(message);
        return;
      }
      await _openPath(directory, failure: '无法打开文件所在位置');
      return;
    }
    await _openPath(directory, revealPath: path, failure: '无法打开文件所在位置');
  }

  /// 让用户重新指定缺失附件在本机的位置，修复换机或移动文件后失效的记录。
  Future<void> relocateAttachment(ChatMessage message) async {
    final result = await FilePicker.pickFile(
      dialogTitle: '重新指定“${message.fileName ?? '附件'}”的位置',
    );
    final filePath = result?.path;
    if (filePath == null) return;
    if (!await File(filePath).exists()) {
      errorMessage = '所选文件不存在';
      notifyListeners();
      return;
    }
    await _database.updateMessageFilePath(message.messageId, filePath);
    _replaceVisibleMessage(message.messageId, filePath: filePath);
    notifyListeners();
    _showTopRightMessage('已重新绑定本地文件', icon: Icons.link);
  }

  /// 这个附件记录指向的文件是否原本就在数据文件夹里。
  ///
  /// 界面用它决定缺失提示的文案：目录内的文件会随数据文件夹一起搬迁，
  /// 目录外的原始文件换机后只能靠用户重新指定。
  bool isAttachmentInsideDataDirectory(ChatMessage message) {
    final path = message.filePath;
    return path != null && _database.isInsideDataDirectory(path);
  }

  /// 附件缺失时展示给用户的说明。
  String attachmentMissingHint(ChatMessage message) => missingAttachmentHint(
    insideDataDirectory: isAttachmentInsideDataDirectory(message),
  );

  void _reportMissingAttachment(ChatMessage message) {
    _showTopRightMessage(
      attachmentMissingHint(message),
      icon: Icons.error_outline,
    );
  }

  /// 打开数据目录，方便用户把身份和聊天记录整体拷走。
  Future<void> openDataDirectory() async {
    final path = dataDirectory;
    if (path == null) return;
    await _openPath(path, failure: '无法打开数据目录');
  }

  Future<void> _openPath(
    String directoryPath, {
    String? revealPath,
    required String failure,
  }) async {
    try {
      if (Platform.isWindows) {
        await Process.start(
          'explorer.exe',
          windowsExplorerArguments(
            directoryPath: directoryPath,
            revealPath: revealPath,
          ),
          mode: ProcessStartMode.detached,
        );
        return;
      }
      final target = Uri.file(revealPath ?? directoryPath);
      if (!await launchUrl(target)) {
        throw StateError('系统未能打开目录');
      }
    } on Object catch (error, stack) {
      _log.warning(failure, error, stack);
      errorMessage = failure;
      notifyListeners();
    }
  }

  Future<void> closeChat(ChatSummary chat) async {
    if (selectedChatId == chat.chatId) {
      selectedChatId = null;
      messages = [];
    }
    notifyListeners();
  }

  Future<void> deleteChat(ChatSummary chat) async {
    await _database.deleteChat(chat.chatId);
    chats = chats.where((value) => value.chatId != chat.chatId).toList();
    if (selectedChatId == chat.chatId) {
      selectedChatId = null;
      messages = [];
      replyingTo = null;
    }
    notifyListeners();
  }

  List<TrustedPeer> get blockedPeers {
    final list = trustedPeers.values.where((peer) => peer.blocked).toList()
      ..sort((a, b) => a.displayName.compareTo(b.displayName));
    return list;
  }

  Future<void> setBlocked(String deviceId, bool blocked) async {
    final old = trustedPeers[deviceId];
    if (old == null) return;
    final updated = TrustedPeer(
      deviceId: old.deviceId,
      displayName: old.displayName,
      lastKnownIp: old.lastKnownIp,
      verifiedAt: old.verifiedAt,
      blocked: blocked,
    );
    trustedPeers[deviceId] = updated;
    await _database.saveTrustedPeer(updated);
    final chat = chats
        .where((value) => value.peerDeviceId == deviceId)
        .firstOrNull;
    if (chat != null) {
      await _upsertChat(
        deviceId,
        chat.displayName,
        blocked ? ChatSessionState.blocked : ChatSessionState.none,
      );
    }
    _discovery?.refreshTrust();
    notifyListeners();
  }

  /// 撤销对端验证状态，使其回到未验证状态；下次聊天需要重新核对 6 位验证码。
  Future<void> revokePeerVerification(String deviceId) async {
    if (!trustedPeers.containsKey(deviceId)) return;
    trustedPeers.remove(deviceId);
    await _database.deleteTrustedPeer(deviceId);
    final chat = chats
        .where((value) => value.peerDeviceId == deviceId)
        .firstOrNull;
    if (chat != null) {
      await _upsertChat(deviceId, chat.displayName, ChatSessionState.none);
    }
    _discovery?.refreshTrust();
    notifyListeners();
  }

  Future<ChatGroup> createGroup(
    String name,
    List<DiscoveredPeer> invitees,
  ) async {
    final normalized = name.trim();
    if (normalized.isEmpty || !isValidGroupName(normalized)) {
      throw ArgumentError('群名称长度应为 1～${NetworkConfig.maxGroupNameLength} 个字符');
    }
    final group = ChatGroup(
      groupId: _uuid.v4(),
      name: normalized,
      ownerDeviceId: identity!.deviceId,
      createdAt: DateTime.now(),
    );
    final members = [
      GroupMember(
        groupId: group.groupId,
        deviceId: identity!.deviceId,
        displayName: identity!.displayName,
        role: GroupRole.owner,
      ),
    ];
    await _database.saveGroup(group, members);
    groups = [group, ...groups];
    _rememberMyRole(group.groupId, members);
    notifyListeners();
    for (final peer in invitees.where(
      (value) => value.online && value.trusted,
    )) {
      await inviteToGroup(group, peer);
    }
    return group;
  }

  /// 邀请一个已验证且在线的设备加入群聊。
  ///
  /// Owner 与普通成员都可以邀请，因此邀请消息里同时携带真实的群 Owner 信息和
  /// 实际发出邀请的人，接收方据此显示邀请来源并按 Owner 建立群组织关系。
  Future<void> inviteToGroup(ChatGroup group, DiscoveredPeer peer) async {
    if (!peer.online || peer.deviceId == identity!.deviceId) return;
    final members = await _database.loadGroupMembers(group.groupId);
    if (!members.any((member) => member.deviceId == identity!.deviceId)) return;
    if (members.any((member) => member.deviceId == peer.deviceId)) return;
    final inviteId = _uuid.v4();
    _outgoingGroupInvites[inviteId] = (
      groupId: group.groupId,
      peerDeviceId: peer.deviceId,
    );
    final owner = members
        .where((member) => member.deviceId == group.ownerDeviceId)
        .firstOrNull;
    await _transport.send(
      peer.ip,
      peer.port,
      ProtocolEnvelope(
        type: MessageType.groupInvite,
        payload: {
          'inviteId': inviteId,
          'groupId': group.groupId,
          'groupName': group.name,
          'ownerDeviceId': group.ownerDeviceId,
          'ownerDisplayName': owner?.displayName ?? identity!.displayName,
          'inviterDeviceId': identity!.deviceId,
          'inviterDisplayName': identity!.displayName,
          'members': members
              .map(
                (member) => {
                  'deviceId': member.deviceId,
                  'displayName': member.displayName,
                  'role': member.role.name,
                },
              )
              .toList(),
        },
      ),
    );
  }

  Future<void> respondToGroupInvitation(
    GroupInvitation invitation,
    bool accepted,
  ) async {
    final payload = _pendingGroupPayloads.remove(invitation.inviteId);
    groupInvitations.remove(invitation.inviteId);
    if (accepted && payload != null) {
      final group = ChatGroup(
        groupId: invitation.groupId,
        name: invitation.groupName,
        ownerDeviceId: invitation.ownerDeviceId,
        createdAt: DateTime.now(),
      );
      final rawMembers = payload['members'];
      final members = <GroupMember>[];
      if (rawMembers is List) {
        for (final raw in rawMembers.whereType<Map>()) {
          final map = Map<String, dynamic>.from(raw);
          if (map['deviceId'] is String &&
              map['displayName'] is String &&
              map['role'] is String) {
            members.add(
              GroupMember(
                groupId: group.groupId,
                deviceId: map['deviceId'] as String,
                displayName: map['displayName'] as String,
                role: GroupRole.values.byName(map['role'] as String),
              ),
            );
          }
        }
      }
      members.removeWhere((member) => member.deviceId == identity!.deviceId);
      members.add(
        GroupMember(
          groupId: group.groupId,
          deviceId: identity!.deviceId,
          displayName: identity!.displayName,
          role: GroupRole.member,
        ),
      );
      await _database.saveGroup(group, members);
      groups = [
        group,
        ...groups.where((value) => value.groupId != group.groupId),
      ];
      _rememberMyRole(group.groupId, members);
    }
    notifyListeners();
    await _sendToAddress(
      invitation.ip,
      ProtocolEnvelope(
        type: MessageType.groupInviteResponse,
        payload: {
          'inviteId': invitation.inviteId,
          'groupId': invitation.groupId,
          'accepted': accepted,
          'deviceId': identity!.deviceId,
          'displayName': identity!.displayName,
        },
      ),
    );
  }

  Future<void> selectGroup(String groupId) async {
    selectedChatId = null;
    selectedGroupId = groupId;
    replyingTo = null;
    await _clearUnread(groupId: groupId);
    messages = await _database.loadMessages('group:$groupId');
    notifyListeners();
  }

  /// 开始引用一条消息，下一条发出的消息会带上引用。再次点击可取消。
  void beginReply(ChatMessage message) {
    replyingTo = identical(replyingTo, message) ? null : message;
    notifyListeners();
  }

  void cancelReply() {
    if (replyingTo == null) return;
    replyingTo = null;
    notifyListeners();
  }

  /// 复制一条消息：文本复制内容，附件复制本地路径（没有则复制文件名）。
  Future<void> copyMessage(ChatMessage message) async {
    final isText = message.kind == MessageKind.text;
    final text = isText
        ? message.content
        : (message.filePath ?? message.fileName ?? message.content);
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    _showTopRightMessage(isText ? '已复制消息内容' : '已复制文件路径', icon: Icons.copy);
  }

  /// 引用框里展示的摘要文本。
  static String replyPreview(ChatMessage message) {
    if (message.isRecalled) return '消息已撤回';
    final raw = message.kind == MessageKind.text
        ? message.content
        : (message.fileName ?? message.content);
    final normalized = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (normalized.length <= NetworkConfig.maxReplyPreviewLength) {
      return normalized;
    }
    return '${normalized.substring(0, NetworkConfig.maxReplyPreviewLength)}…';
  }

  /// 当前用户是否有权撤回这条消息。私聊和普通群成员限 2 分钟；
  /// 群主可在 1 小时内撤回群内任意消息；管理员可撤回群内非群主消息。
  bool canRecallMessage(ChatMessage message, {DateTime? now}) {
    final me = identity?.deviceId;
    if (me == null || message.isRecalled) return false;
    ChatGroup? group;
    var isAdmin = false;
    if (message.groupId != null) {
      group = groups
          .where((value) => value.groupId == message.groupId)
          .firstOrNull;
      if (group == null) return false;
      isAdmin =
          _myGroupRoles[group.groupId] == GroupRole.admin &&
          me != group.ownerDeviceId;
    }
    return canActorRecall(
      message,
      actorDeviceId: me,
      group: group,
      isAdmin: isAdmin,
      now: now ?? DateTime.now(),
    );
  }

  /// 撤回权限的唯一判定规则：不依赖实例状态的纯函数，供真实控制器与
  /// 组件预览共用，避免规则被复制成两份而产生分歧。私聊/普通成员限
  /// [NetworkConfig.selfRecallWindow]；群主与管理员限
  /// [NetworkConfig.groupOwnerRecallWindow]（管理员不得撤回群主消息）。
  static bool canActorRecall(
    ChatMessage message, {
    required String actorDeviceId,
    required ChatGroup? group,
    required bool isAdmin,
    required DateTime now,
  }) {
    if (message.isRecalled) return false;
    final age = now.difference(message.timestamp);
    if (age < -NetworkConfig.recallClockSkewTolerance) return false;
    if (group?.ownerDeviceId == actorDeviceId) {
      return age <= NetworkConfig.groupOwnerRecallWindow;
    }
    if (group != null &&
        isAdmin &&
        message.senderDeviceId != group.ownerDeviceId) {
      return age <= NetworkConfig.groupOwnerRecallWindow;
    }
    return message.senderDeviceId == actorDeviceId &&
        age <= NetworkConfig.selfRecallWindow;
  }

  static bool _isGroupAdmin(
    List<GroupMember> members,
    String deviceId,
    ChatGroup group,
  ) {
    if (deviceId == group.ownerDeviceId) return false;
    return members
            .where((member) => member.deviceId == deviceId)
            .firstOrNull
            ?.role ==
        GroupRole.admin;
  }

  /// 撤回消息并把撤回事件发给对端。私聊没有离线补发，因此对方离线时不
  /// 修改本地消息；群聊撤回会持久化，并在成员重连同步历史时继续生效。
  Future<void> recallMessage(ChatMessage message) async {
    if (!canRecallMessage(message)) {
      final isGroupOwner =
          message.groupId != null &&
          groups.any(
            (group) =>
                group.groupId == message.groupId &&
                group.ownerDeviceId == identity?.deviceId,
          );
      errorMessage = isGroupOwner ? '群主只能撤回 1 小时内的群消息' : '自己的消息只能在发送后 2 分钟内撤回';
      notifyListeners();
      return;
    }
    final recalledAt = DateTime.now();
    final actor = identity!.deviceId;
    if (message.groupId == null) {
      final chat = chats
          .where((value) => value.chatId == message.chatId)
          .firstOrNull;
      final peer = chat == null ? null : _onlinePeer(chat.peerDeviceId);
      if (chat?.sessionId == null || peer == null) {
        errorMessage = '对方当前离线，无法撤回私聊消息';
        notifyListeners();
        return;
      }
      try {
        await _transport.send(
          peer.ip,
          peer.port,
          ProtocolEnvelope(
            type: MessageType.messageRecall,
            payload: {
              'sessionId': chat!.sessionId,
              'messageId': message.messageId,
              'senderDeviceId': actor,
              'recalledAt': recalledAt.millisecondsSinceEpoch,
            },
          ),
        );
      } on Object catch (error, stack) {
        _log.warning('发送私聊撤回失败', error, stack);
        errorMessage = '撤回失败：无法连接对方';
        notifyListeners();
        return;
      }
      await _applyRecall(message, actor, recalledAt);
      return;
    }

    final groupId = message.groupId!;
    final members = await _database.loadGroupMembers(groupId);
    await _applyRecall(message, actor, recalledAt);
    final envelope = ProtocolEnvelope(
      type: MessageType.groupMessageRecall,
      payload: {
        'groupId': groupId,
        'messageId': message.messageId,
        'senderDeviceId': actor,
        'recalledAt': recalledAt.millisecondsSinceEpoch,
      },
    );
    for (final member in members.where((value) => value.deviceId != actor)) {
      final peer = _onlinePeer(member.deviceId);
      if (peer == null) continue;
      try {
        await _transport.send(peer.ip, peer.port, envelope);
      } on Object catch (error, stack) {
        _log.warning('向群成员 ${member.deviceId} 发送撤回失败', error, stack);
      }
    }
  }

  String recallNotice(ChatMessage message) {
    final actor = message.recalledByDeviceId;
    if (actor == identity?.deviceId) {
      if (message.senderDeviceId == actor) return '你撤回了一条消息';
      return '你撤回了 ${_messageSenderName(message)} 的一条消息';
    }
    if (actor == message.senderDeviceId) {
      return '${_messageSenderName(message)} 撤回了一条消息';
    }
    return '群主撤回了 ${_messageSenderName(message)} 的一条消息';
  }

  String _messageSenderName(ChatMessage message) {
    if (message.senderDeviceId == identity?.deviceId) return '你';
    final original =
        trustedPeers[message.senderDeviceId]?.displayName ??
        peers
            .where((peer) => peer.deviceId == message.senderDeviceId)
            .firstOrNull
            ?.displayName ??
        '一位群成员';
    return peerDisplayName(message.senderDeviceId, original);
  }

  Future<void> _applyRecall(
    ChatMessage message,
    String actorDeviceId,
    DateTime recalledAt,
  ) async {
    if (!await _database.recallMessage(
      message.messageId,
      recalledByDeviceId: actorDeviceId,
      recalledAt: recalledAt,
    )) {
      return;
    }
    if (replyingTo?.messageId == message.messageId) replyingTo = null;
    final index = messages.indexWhere(
      (value) => value.messageId == message.messageId,
    );
    if (index >= 0) {
      messages = [...messages]
        ..[index] = message.asRecalled(
          byDeviceId: actorDeviceId,
          at: recalledAt,
        );
    }
    if (message.groupId == null) {
      await _reloadChats();
    } else {
      await _reloadGroups();
    }
    notifyListeners();
  }

  /// 由控制器统一维护未读，界面只读取即可。
  ///
  /// 用数据库原子自增而不是「读内存再 +1」，避免多条消息几乎同时到达时
  /// 两次读改写互相覆盖导致少计。
  Future<void> _markUnread({String? chatId, String? groupId}) async {
    if (chatId != null) {
      await _database.incrementChatUnread(chatId);
    } else if (groupId != null) {
      await _database.incrementGroupUnread(groupId);
    }
  }

  Future<void> _clearUnread({String? chatId, String? groupId}) async {
    if (chatId != null) {
      final chat = chats.where((value) => value.chatId == chatId).firstOrNull;
      if (chat == null || chat.unreadCount == 0) return;
      await _database.setChatUnread(chatId, 0);
      await _reloadChats();
    } else if (groupId != null) {
      final group = groups
          .where((value) => value.groupId == groupId)
          .firstOrNull;
      if (group == null || group.unreadCount == 0) return;
      await _database.setGroupUnread(groupId, 0);
      await _reloadGroups();
    }
  }

  Future<List<GroupMember>> groupMembers(String groupId) async {
    final members = await _database.loadGroupMembers(groupId);
    _rememberMyRole(groupId, members);
    return members;
  }

  /// 记录群成员角色；成员列表变化后都要刷新，供同步的权限判断与界面渲染使用。
  void _rememberMyRole(String groupId, List<GroupMember> members) {
    final roles = <String, GroupRole>{
      for (final member in members) member.deviceId: member.role,
    };
    _groupMemberRoles[groupId] = roles;
    final me = identity?.deviceId;
    final role = me == null ? null : roles[me];
    if (role == null) {
      _myGroupRoles.remove(groupId);
    } else {
      _myGroupRoles[groupId] = role;
    }
  }

  void _forgetGroup(String groupId) {
    _myGroupRoles.remove(groupId);
    _groupMemberRoles.remove(groupId);
  }

  /// 本机在指定群里的角色；不在群里返回 null。
  GroupRole? groupRole(String groupId) => _myGroupRoles[groupId];

  /// 指定成员在群里的角色；用于渲染发送者的角色标签。
  GroupRole? groupMemberRole(String groupId, String deviceId) =>
      _groupMemberRoles[groupId]?[deviceId];

  Future<void> renameGroup(ChatGroup group, String name) async {
    final normalized = name.trim();
    if (group.ownerDeviceId != identity!.deviceId ||
        normalized.isEmpty ||
        !isValidGroupName(normalized)) {
      return;
    }
    final members = await _database.loadGroupMembers(group.groupId);
    final updated = group.copyWith(name: normalized);
    await _database.saveGroup(updated, members);
    groups = [
      for (final value in groups)
        if (value.groupId == group.groupId) updated else value,
    ];
    notifyListeners();
    await _fanOutGroupControl(group.groupId, members, 'rename', {
      'name': normalized,
    });
  }

  /// 群主设置或取消管理员。只有群主能调整，且不能改动群主本人。
  Future<void> setGroupMemberRole(
    ChatGroup group,
    GroupMember member,
    GroupRole role,
  ) async {
    if (role == GroupRole.owner || member.deviceId == group.ownerDeviceId) {
      return;
    }
    final members = await _database.loadGroupMembers(group.groupId);
    final me = members
        .where((value) => value.deviceId == identity!.deviceId)
        .firstOrNull;
    if (me?.role != GroupRole.owner) return;
    await _database.saveGroupMember(
      GroupMember(
        groupId: group.groupId,
        deviceId: member.deviceId,
        displayName: member.displayName,
        role: role,
      ),
    );
    await _broadcastGroupMembers(group.groupId);
    notifyListeners();
  }

  /// 移除群成员。群主可移除除自己以外的任何人；管理员只能移除普通成员，
  /// 不能移除群主或其他管理员。
  Future<void> removeGroupMember(ChatGroup group, GroupMember member) async {
    if (member.deviceId == identity!.deviceId) return;
    final members = await _database.loadGroupMembers(group.groupId);
    final me = members
        .where((value) => value.deviceId == identity!.deviceId)
        .firstOrNull;
    if (me == null || member.deviceId == group.ownerDeviceId) return;
    final allowed =
        me.role == GroupRole.owner ||
        (me.role == GroupRole.admin && member.role == GroupRole.member);
    if (!allowed) return;
    await _database.removeGroupMember(group.groupId, member.deviceId);
    await _fanOutGroupControl(group.groupId, members, 'remove', {
      'targetDeviceId': member.deviceId,
    });
    notifyListeners();
  }

  Future<void> leaveOrDisbandGroup(ChatGroup group) async {
    final members = await _database.loadGroupMembers(group.groupId);
    final isOwner = group.ownerDeviceId == identity!.deviceId;
    await _fanOutGroupControl(
      group.groupId,
      members,
      isOwner ? 'disband' : 'leave',
      {'targetDeviceId': identity!.deviceId},
    );
    await _database.deleteGroup(group.groupId);
    groups = groups.where((value) => value.groupId != group.groupId).toList();
    _forgetGroup(group.groupId);
    if (selectedGroupId == group.groupId) {
      selectedGroupId = null;
      messages = [];
    }
    notifyListeners();
  }

  Future<void> _sendGroupMessage(
    String groupId,
    String content, {
    required ChatMessage? reply,
  }) async {
    final members = await _database.loadGroupMembers(groupId);
    if (!members.any((member) => member.deviceId == identity!.deviceId)) return;
    final mentions = _resolveMentions(content, members);
    final message = ChatMessage(
      messageId: _uuid.v4(),
      chatId: 'group:$groupId',
      groupId: groupId,
      senderDeviceId: identity!.deviceId,
      content: content,
      timestamp: DateTime.now(),
      status: MessageStatus.sent,
      mentions: mentions,
      replyToMessageId: reply?.messageId,
      replyToSenderId: reply?.senderDeviceId,
      replyToPreview: reply == null ? null : replyPreview(reply),
    );
    if (identical(replyingTo, reply)) replyingTo = null;
    await _database.saveMessage(message);
    if (selectedGroupId == groupId) messages = [...messages, message];
    await _reloadGroups();
    notifyListeners();
    for (final member in members.where(
      (value) => value.deviceId != identity!.deviceId,
    )) {
      final peer = _onlinePeer(member.deviceId);
      if (peer == null) continue;
      try {
        await _transport.send(
          peer.ip,
          peer.port,
          ProtocolEnvelope(
            type: MessageType.groupMessage,
            payload: {
              'groupId': groupId,
              'messageId': message.messageId,
              'senderDeviceId': identity!.deviceId,
              'timestamp': message.timestamp.millisecondsSinceEpoch,
              'content': content,
              if (mentions.isNotEmpty) 'mentions': mentions,
              ..._replyPayload(reply),
            },
          ),
        );
      } on Object catch (error, stack) {
        _log.warning('向群成员 ${member.deviceId} 发送失败', error, stack);
      }
    }
  }

  /// 按群成员昵称解析消息中的 @ 提及，返回被提及的成员设备号。
  List<String> _resolveMentions(String content, List<GroupMember> members) {
    final mentions = <String>[];
    for (final member in members) {
      if (member.deviceId == identity!.deviceId) continue;
      if (mentions.length >= NetworkConfig.maxMentionCount) break;
      final localDisplayName = peerDisplayName(
        member.deviceId,
        member.displayName,
      );
      if (content.contains('@${member.displayName}') ||
          content.contains('@$localDisplayName')) {
        mentions.add(member.deviceId);
      }
    }
    return mentions;
  }

  Future<void> _sendGroupFile(
    String groupId,
    File file,
    int fileSize,
    String mimeType,
    String? fileHash, {
    required ChatMessage? reply,
  }) async {
    final members = await _database.loadGroupMembers(groupId);
    if (!members.any((member) => member.deviceId == identity!.deviceId)) return;
    final recipients = members
        .where((member) => member.deviceId != identity!.deviceId)
        .map((member) => _onlinePeer(member.deviceId))
        .whereType<DiscoveredPeer>()
        .toList();
    final message = _localFileMessage(
      chatId: 'group:$groupId',
      groupId: groupId,
      file: file,
      fileSize: fileSize,
      mimeType: mimeType,
      fileHash: fileHash,
      reply: reply,
    );
    if (identical(replyingTo, reply)) replyingTo = null;
    await _database.saveMessage(message);
    if (selectedGroupId == groupId) messages = [...messages, message];
    await _reloadGroups();
    notifyListeners();
    if (recipients.isEmpty) {
      await _setMessageStatus(message.messageId, MessageStatus.failed);
      _showTopRightMessage('当前没有在线群成员，文件未发送', icon: Icons.error_outline);
      return;
    }
    try {
      await _transport.offerFile(
        transferId: message.transferId!,
        filePath: file.path,
        allowedAddresses: recipients.map((peer) => peer.ip).toSet(),
      );
      var delivered = 0;
      for (final peer in recipients) {
        try {
          await _transport.send(
            peer.ip,
            peer.port,
            ProtocolEnvelope(
              type: MessageType.groupFileOffer,
              payload: _filePayload(message),
            ),
          );
          delivered++;
        } on Object catch (error, stack) {
          _log.warning('向群成员 ${peer.deviceId} 发送文件邀请失败', error, stack);
        }
      }
      if (delivered == 0) {
        await _setMessageStatus(message.messageId, MessageStatus.failed);
      }
    } on Object catch (error, stack) {
      _log.warning('群文件发送失败', error, stack);
      await _setMessageStatus(message.messageId, MessageStatus.failed);
      errorMessage = '群文件发送失败：$error';
      notifyListeners();
    }
  }

  Future<void> _fanOutGroupControl(
    String groupId,
    List<GroupMember> members,
    String action,
    Map<String, dynamic> extra,
  ) async {
    final envelope = ProtocolEnvelope(
      type: MessageType.groupUpdate,
      payload: {
        'groupId': groupId,
        'action': action,
        'senderDeviceId': identity!.deviceId,
        ...extra,
      },
    );
    for (final member in members.where(
      (value) => value.deviceId != identity!.deviceId,
    )) {
      final peer = _onlinePeer(member.deviceId);
      if (peer == null) continue;
      try {
        await _transport.send(peer.ip, peer.port, envelope);
      } on Object catch (error, stack) {
        _log.warning('群控制消息发送失败', error, stack);
      }
    }
  }

  /// 把最新成员名单广播给所有成员。Owner 与受邀成员都可以触发，让其他成员
  /// 知道新成员加入；接收方会校验发送者确实是群成员并保留 Owner。
  Future<void> _broadcastGroupMembers(String groupId) async {
    final group = groups.where((value) => value.groupId == groupId).firstOrNull;
    if (group == null) return;
    final members = await _database.loadGroupMembers(groupId);
    if (!members.any((member) => member.deviceId == identity!.deviceId)) return;
    await _fanOutGroupControl(groupId, members, 'members', {
      'members': [
        for (final member in members)
          {
            'deviceId': member.deviceId,
            'displayName': member.displayName,
            'role': member.role.name,
          },
      ],
    });
  }

  Future<void> _onPacket(IncomingPacket packet) async {
    try {
      switch (packet.envelope.type) {
        case MessageType.chatRequest:
          await _receiveChatRequest(packet);
        case MessageType.chatAccept:
          await _receiveChatAccept(packet);
        case MessageType.chatReject:
          await _receiveChatReject(packet);
        case MessageType.message:
          await _receiveMessage(packet);
        case MessageType.messageRecall:
          await _receiveMessageRecall(packet);
        case MessageType.fileOffer:
          await _receiveFileOffer(packet);
        case MessageType.fileAccept:
          await _receiveFileResponse(packet, accepted: true);
        case MessageType.fileReject:
          await _receiveFileResponse(packet, accepted: false);
        case MessageType.sessionClose:
          await _receiveSessionClose(packet);
        case MessageType.groupInvite:
          await _receiveGroupInvite(packet);
        case MessageType.groupInviteResponse:
          await _receiveGroupInviteResponse(packet);
        case MessageType.groupMessage:
          await _receiveGroupMessage(packet);
        case MessageType.groupMessageRecall:
          await _receiveGroupMessageRecall(packet);
        case MessageType.groupFileOffer:
          await _receiveGroupFileOffer(packet);
        case MessageType.groupUpdate:
          await _receiveGroupUpdate(packet);
        case MessageType.groupHistoryRequest:
          await _receiveGroupHistoryRequest(packet);
        case MessageType.groupHistoryResponse:
          await _receiveGroupHistoryResponse(packet);
        case MessageType.groupMembersRequest:
          await _receiveGroupMembersRequest(packet);
        case MessageType.announce || MessageType.hello || MessageType.error:
          break;
      }
    } on Object catch (error, stack) {
      _log.warning(
        '处理来自 ${packet.remoteAddress} 的 ${packet.envelope.type.wireName} 失败',
        error,
        stack,
      );
    }
  }

  Future<void> _receiveChatRequest(IncomingPacket packet) async {
    final payload = packet.envelope.payload;
    final requestId = payload['requestId'];
    final deviceId = payload['deviceId'];
    final displayName = payload['displayName'];
    if (requestId is! String ||
        deviceId is! String ||
        displayName is! String ||
        !isValidDisplayName(displayName) ||
        deviceId == identity!.deviceId) {
      return;
    }
    if (trustedPeers[deviceId]?.blocked == true ||
        chatRequests.containsKey(requestId)) {
      return;
    }
    final currentChat = chats
        .where((value) => value.peerDeviceId == deviceId)
        .firstOrNull;
    final trusted = trustedPeers[deviceId];
    if (currentChat?.state == ChatSessionState.active) {
      if (trusted != null && currentChat?.sessionId != null) {
        await _sendChatAccept(
          ip: packet.remoteAddress,
          requestId: requestId,
          sessionId: currentChat!.sessionId!,
        );
      }
      return;
    }

    final pendingForPeer = chatRequests.values
        .where((value) => value.peerDeviceId == deviceId)
        .firstOrNull;
    if (pendingForPeer?.incoming == true) return;
    if (pendingForPeer != null &&
        ChatStateMachine.resolveCollision(
              localDeviceId: identity!.deviceId,
              remoteDeviceId: deviceId,
            ) ==
            CollisionDecision.keepOutgoing) {
      return;
    }
    if (pendingForPeer != null) {
      _removeChatRequest(pendingForPeer.requestId);
    }

    if (trusted != null) {
      final sessionId = _uuid.v4();
      await _upsertChat(
        deviceId,
        displayName,
        ChatSessionState.active,
        sessionId: sessionId,
        allowTrustedReconnect: true,
      );
      await _sendChatAccept(
        ip: packet.remoteAddress,
        requestId: requestId,
        sessionId: sessionId,
      );
      _log.info('已自动恢复与已验证设备 $deviceId 的会话');
      notifyListeners();
      return;
    }

    final request = ChatRequest(
      requestId: requestId,
      peerDeviceId: deviceId,
      displayName: displayName,
      ip: packet.remoteAddress,
      verificationCode: verificationCode(
        requestId: requestId,
        requesterDeviceId: deviceId,
        recipientDeviceId: identity!.deviceId,
      ),
      incoming: true,
    );
    chatRequests[requestId] = request;
    _scheduleRequestTimeout(request);
    await _upsertChat(deviceId, displayName, ChatSessionState.pendingIncoming);
    notifyListeners();
    if (_systemNotificationsAllowed && !_notifications.appIsFocused) {
      await _notifications.show(
        identifier: 'chat-request:$requestId',
        title: '新的聊天邀请',
        body:
            '${peerDisplayName(deviceId, displayName)} 请求与你聊天，'
            '验证码 ${request.verificationCode}',
        onClick: () {},
      );
    }
  }

  Future<void> _receiveChatAccept(IncomingPacket packet) async {
    final payload = packet.envelope.payload;
    final requestId = payload['requestId'];
    final sessionId = payload['sessionId'];
    final deviceId = payload['deviceId'];
    final displayName = payload['displayName'];
    if (requestId is! String ||
        sessionId is! String ||
        deviceId is! String ||
        displayName is! String ||
        !isValidDisplayName(displayName)) {
      return;
    }
    final request = chatRequests[requestId];
    if (request == null ||
        request.incoming ||
        request.peerDeviceId != deviceId) {
      return;
    }
    final existingTrust = trustedPeers[deviceId];
    final peer = TrustedPeer(
      deviceId: deviceId,
      displayName: displayName,
      lastKnownIp: packet.remoteAddress,
      verifiedAt: existingTrust?.verifiedAt ?? DateTime.now(),
    );
    trustedPeers[deviceId] = peer;
    await _database.saveTrustedPeer(peer);
    _removeChatRequest(requestId);
    await _upsertChat(
      deviceId,
      displayName,
      ChatSessionState.active,
      sessionId: sessionId,
    );
    _discovery?.refreshTrust();
    notifyListeners();
    if (_systemNotificationsAllowed && !_notifications.appIsFocused) {
      final chatId = _privateChatId(identity!.deviceId, deviceId);
      await _notifications.show(
        identifier: 'chat-accept:$sessionId',
        title: '${peerDisplayName(deviceId, displayName)} 已接受聊天邀请',
        body: '点击进入会话',
        onClick: () => selectChat(chatId),
      );
    }
  }

  Future<void> _receiveChatReject(IncomingPacket packet) async {
    final requestId = packet.envelope.payload['requestId'];
    if (requestId is! String) return;
    final request = _removeChatRequest(requestId);
    if (request != null) {
      await _upsertChat(
        request.peerDeviceId,
        request.displayName,
        ChatSessionState.rejected,
      );
    }
    notifyListeners();
  }

  Future<void> _receiveMessage(IncomingPacket packet) async {
    final payload = packet.envelope.payload;
    final sessionId = payload['sessionId'];
    final messageId = payload['messageId'];
    final senderDeviceId = payload['senderDeviceId'];
    final timestamp = payload['timestamp'];
    final content = payload['content'];
    if (sessionId is! String ||
        messageId is! String ||
        senderDeviceId is! String ||
        timestamp is! int ||
        timestamp < 0 ||
        content is! String ||
        !isValidTextContent(content) ||
        !isValidIdentifier(messageId) ||
        !isValidIdentifier(senderDeviceId)) {
      return;
    }
    if (trustedPeers[senderDeviceId]?.blocked == true) return;
    final chat = chats
        .where(
          (value) =>
              value.sessionId == sessionId &&
              value.peerDeviceId == senderDeviceId &&
              value.state == ChatSessionState.active,
        )
        .firstOrNull;
    if (chat == null) {
      _log.warning('忽略未知 sessionId=$sessionId 的消息');
      return;
    }
    final reply = _incomingReply(payload);
    final message = ChatMessage(
      messageId: messageId,
      chatId: chat.chatId,
      senderDeviceId: senderDeviceId,
      content: content,
      timestamp: DateTime.fromMillisecondsSinceEpoch(timestamp),
      status: MessageStatus.sent,
      replyToMessageId: reply.$1,
      replyToSenderId: reply.$2,
      replyToPreview: reply.$3,
    );
    // 只要当前打开的就是这个会话，消息就立刻显示在列表里（哪怕窗口没聚焦）；
    // 只有会话没打开时才累计未读，靠红点提醒。
    final conversationOpen = _isConversationOpen(chat.chatId);
    if (!await _database.saveMessage(message)) return;
    if (selectedChatId == chat.chatId) {
      messages = [...messages, message];
    }
    if (!conversationOpen) {
      await _markUnread(chatId: chat.chatId);
    }
    await _reloadChats();
    notifyListeners();
    if (!_openConversationWindows.contains(chat.chatId) &&
        _systemNotificationsAllowed &&
        shouldNotifyForConversation(
          appIsFocused: _notifications.appIsFocused,
          selectedConversationId: selectedChatId,
          incomingConversationId: chat.chatId,
        )) {
      await _notifications.show(
        identifier: 'message:$messageId',
        title: peerDisplayName(chat.peerDeviceId, chat.displayName),
        body: _notificationPreview(content),
        onClick: () => selectChat(chat.chatId),
      );
    }
  }

  Future<void> _receiveMessageRecall(IncomingPacket packet) async {
    final payload = packet.envelope.payload;
    final sessionId = payload['sessionId'];
    final messageId = payload['messageId'];
    final actorDeviceId = payload['senderDeviceId'];
    final recalledAt = payload['recalledAt'];
    if (sessionId is! String ||
        messageId is! String ||
        actorDeviceId is! String ||
        recalledAt is! int ||
        recalledAt < 0 ||
        !isValidIdentifier(messageId) ||
        !isValidIdentifier(actorDeviceId)) {
      return;
    }
    final chat = chats
        .where(
          (value) =>
              value.sessionId == sessionId &&
              value.peerDeviceId == actorDeviceId &&
              value.state == ChatSessionState.active,
        )
        .firstOrNull;
    if (chat == null ||
        trustedPeers[actorDeviceId]?.blocked == true ||
        !_packetMatchesDevice(packet, actorDeviceId)) {
      return;
    }
    final message = await _database.loadMessage(messageId);
    final now = DateTime.now();
    if (message == null ||
        message.chatId != chat.chatId ||
        message.groupId != null ||
        message.senderDeviceId != actorDeviceId ||
        !canActorRecall(
          message,
          actorDeviceId: actorDeviceId,
          group: null,
          isAdmin: false,
          now: now,
        )) {
      return;
    }
    await _applyRecall(message, actorDeviceId, now);
  }

  /// 解析入站消息的引用字段，非法时返回全空。
  (String?, String?, String?) _incomingReply(Map<String, dynamic> payload) {
    final id = payload['replyToMessageId'];
    final sender = payload['replyToSenderId'];
    final preview = payload['replyToPreview'];
    if (id is! String || sender is! String || preview is! String) {
      return (null, null, null);
    }
    if (!isValidIdentifier(id) ||
        !isValidIdentifier(sender) ||
        !isValidReplyPreview(preview)) {
      return (null, null, null);
    }
    return (id, sender, preview);
  }

  Future<void> _receiveFileOffer(IncomingPacket packet) async {
    final payload = packet.envelope.payload;
    final sessionId = payload['sessionId'];
    final senderDeviceId = payload['senderDeviceId'];
    if (sessionId is! String || senderDeviceId is! String) return;
    if (trustedPeers[senderDeviceId]?.blocked == true) return;
    final chat = chats
        .where(
          (value) =>
              value.sessionId == sessionId &&
              value.peerDeviceId == senderDeviceId &&
              value.state == ChatSessionState.active,
        )
        .firstOrNull;
    if (chat == null) return;
    final message = _incomingFileMessage(payload, chatId: chat.chatId);
    if (message == null ||
        await _database.loadMessage(message.messageId) != null) {
      return;
    }
    if (!await _database.saveMessage(message)) return;
    // 会话已打开就立刻显示，附件同样不依赖窗口焦点。
    final conversationOpen = _isConversationOpen(chat.chatId);
    if (selectedChatId == chat.chatId) {
      messages = [...messages, message];
    }
    if (!conversationOpen) {
      await _markUnread(chatId: chat.chatId);
    }
    await _reloadChats();
    notifyListeners();
    await _notifyIncomingFile(
      message,
      peerDisplayName(chat.peerDeviceId, chat.displayName),
      chat.chatId,
    );
    if (message.status == MessageStatus.pending) {
      await _acceptIncomingFile(
        message,
        packet.remoteAddress,
        _onlinePeer(senderDeviceId)?.port ?? NetworkConfig.chatPort,
      );
    }
  }

  ChatMessage? _incomingFileMessage(
    Map<String, dynamic> payload, {
    required String chatId,
    String? groupId,
  }) {
    final messageId = payload['messageId'];
    final senderDeviceId = payload['senderDeviceId'];
    final timestamp = payload['timestamp'];
    final transferId = payload['transferId'];
    final fileName = payload['fileName'];
    final fileSize = payload['fileSize'];
    final mimeType = payload['mimeType'];
    final fileHash = payload['fileHash'];
    if (messageId is! String ||
        senderDeviceId is! String ||
        timestamp is! int ||
        transferId is! String ||
        fileName is! String ||
        fileName.isEmpty ||
        fileName.length > 255 ||
        fileSize is! int ||
        fileSize < 0 ||
        mimeType is! String ||
        (fileHash != null && (fileHash is! String || !isSha256Hex(fileHash)))) {
      return null;
    }
    final reply = _incomingReply(payload);
    return ChatMessage(
      messageId: messageId,
      chatId: chatId,
      groupId: groupId,
      senderDeviceId: senderDeviceId,
      content: fileName,
      timestamp: DateTime.fromMillisecondsSinceEpoch(timestamp),
      status:
          autoReceiveFiles &&
              NetworkConfig.canAutoReceive(fileSize, autoReceiveFileLimitBytes)
          ? MessageStatus.pending
          : MessageStatus.awaitingAcceptance,
      kind: mimeType.startsWith('image/')
          ? MessageKind.image
          : MessageKind.file,
      fileName: fileName,
      fileSize: fileSize,
      mimeType: mimeType,
      transferId: transferId,
      fileHash: fileHash as String?,
      replyToMessageId: reply.$1,
      replyToSenderId: reply.$2,
      replyToPreview: reply.$3,
    );
  }

  Future<void> acceptIncomingFile(ChatMessage message) async {
    if (message.senderDeviceId == identity!.deviceId ||
        message.status != MessageStatus.awaitingAcceptance) {
      return;
    }
    final peer = _onlinePeer(message.senderDeviceId);
    if (peer == null) {
      errorMessage = '发送方当前离线，无法接收文件';
      notifyListeners();
      return;
    }
    await _acceptIncomingFile(message, peer.ip, peer.port);
  }

  Future<void> _acceptIncomingFile(
    ChatMessage message,
    String ip,
    int port,
  ) async {
    await _setMessageStatus(message.messageId, MessageStatus.pending);
    try {
      await _sendFileResponse(message, ip, port, accepted: true);
      await _downloadAttachment(message, ip, port);
    } on Object catch (error, stack) {
      _log.warning('发送文件接受响应失败', error, stack);
      await _setMessageStatus(message.messageId, MessageStatus.failed);
      errorMessage = '无法开始文件传输：$error';
      notifyListeners();
    }
  }

  Future<void> rejectIncomingFile(ChatMessage message) async {
    if (message.senderDeviceId == identity!.deviceId ||
        message.status != MessageStatus.awaitingAcceptance) {
      return;
    }
    final peer = _onlinePeer(message.senderDeviceId);
    try {
      if (peer != null) {
        await _sendFileResponse(message, peer.ip, peer.port, accepted: false);
      }
    } on Object catch (error, stack) {
      _log.warning('发送文件拒绝响应失败', error, stack);
    }
    await _setMessageStatus(message.messageId, MessageStatus.rejected);
    _showTopRightMessage(
      '已拒收${message.kind == MessageKind.image ? '图片' : '文件'}“${message.fileName}”',
    );
  }

  Future<void> _sendFileResponse(
    ChatMessage message,
    String ip,
    int port, {
    required bool accepted,
  }) {
    return _transport.send(
      ip,
      port,
      ProtocolEnvelope(
        type: accepted ? MessageType.fileAccept : MessageType.fileReject,
        payload: {
          'messageId': message.messageId,
          'deviceId': identity!.deviceId,
          'groupId': ?message.groupId,
        },
      ),
    );
  }

  Future<void> _receiveFileResponse(
    IncomingPacket packet, {
    required bool accepted,
  }) async {
    final messageId = packet.envelope.payload['messageId'];
    final deviceId = packet.envelope.payload['deviceId'];
    if (messageId is! String || deviceId is! String) return;
    final message = await _database.loadMessage(messageId);
    if (message == null ||
        message.senderDeviceId != identity!.deviceId ||
        message.kind == MessageKind.text ||
        message.transferId == null) {
      return;
    }
    final expectedIp =
        _onlinePeer(deviceId)?.ip ?? trustedPeers[deviceId]?.lastKnownIp;
    if (expectedIp == null || expectedIp != packet.remoteAddress) return;
    if (message.groupId == null) {
      final chat = chats
          .where((value) => value.chatId == message.chatId)
          .firstOrNull;
      if (chat?.peerDeviceId != deviceId) return;
      if (accepted) {
        await _transport.authorizeFileDownload(
          transferId: message.transferId!,
          remoteAddress: packet.remoteAddress,
        );
      }
      await _setMessageStatus(
        messageId,
        accepted ? MessageStatus.sent : MessageStatus.rejected,
      );
      if (!accepted) {
        _showTopRightMessage(
          '${peerDisplayName(chat!.peerDeviceId, chat.displayName)} '
          '已拒收${message.kind == MessageKind.image ? '图片' : '文件'}“${message.fileName}”',
        );
      }
      return;
    }
    final members = await _database.loadGroupMembers(message.groupId!);
    if (!members.any((member) => member.deviceId == deviceId)) return;
    if (accepted) {
      await _transport.authorizeFileDownload(
        transferId: message.transferId!,
        remoteAddress: packet.remoteAddress,
      );
      await _setMessageStatus(messageId, MessageStatus.sent);
    } else {
      final displayName =
          trustedPeers[deviceId]?.displayName ??
          _onlinePeer(deviceId)?.displayName ??
          '一位群成员';
      _showTopRightMessage(
        '$displayName 已拒收${message.kind == MessageKind.image ? '图片' : '文件'}“${message.fileName}”',
      );
    }
  }

  Future<void> _downloadAttachment(
    ChatMessage message,
    String ip,
    int port,
  ) async {
    await _setMessageStatus(message.messageId, MessageStatus.pending);
    try {
      final filePath = await _transport.downloadFile(
        ip: ip,
        port: port,
        transferId: message.transferId!,
        messageId: message.messageId,
        fileName: message.fileName!,
        expectedSize: message.fileSize!,
        mimeType: message.mimeType,
        contentHash: message.fileHash,
      );
      final changed = await _database.updateMessageAttachment(
        message.messageId,
        filePath: filePath,
        status: MessageStatus.sent,
      );
      if (changed > 0) {
        _replaceVisibleMessage(
          message.messageId,
          filePath: filePath,
          status: MessageStatus.sent,
        );
      }
    } on Object catch (error, stack) {
      _log.warning('文件下载失败', error, stack);
      final changed = await _database.updateMessageAttachment(
        message.messageId,
        filePath: null,
        status: MessageStatus.failed,
      );
      if (changed > 0) {
        _replaceVisibleMessage(message.messageId, status: MessageStatus.failed);
      }
    }
    notifyListeners();
  }

  Future<void> _notifyIncomingFile(
    ChatMessage message,
    String senderName,
    String conversationId,
  ) async {
    if (_openConversationWindows.contains(conversationId) ||
        !_systemNotificationsAllowed ||
        !shouldNotifyForConversation(
          appIsFocused: _notifications.appIsFocused,
          selectedConversationId: selectedGroupId == null
              ? selectedChatId
              : 'group:$selectedGroupId',
          incomingConversationId: conversationId,
        )) {
      return;
    }
    await _notifications.show(
      identifier: 'file:${message.messageId}',
      title: senderName,
      body: '${message.fileName}（${formatFileSize(message.fileSize ?? 0)}）',
      onClick: () => message.groupId == null
          ? selectChat(message.chatId)
          : selectGroup(message.groupId!),
    );
  }

  Future<void> _receiveSessionClose(IncomingPacket packet) async {
    final sessionId = packet.envelope.payload['sessionId'];
    final deviceId = packet.envelope.payload['deviceId'];
    if (sessionId is! String || deviceId is! String) return;
    final chat = chats
        .where(
          (value) =>
              value.sessionId == sessionId && value.peerDeviceId == deviceId,
        )
        .firstOrNull;
    if (chat != null) {
      await _upsertChat(deviceId, chat.displayName, ChatSessionState.none);
    }
    notifyListeners();
  }

  Future<void> _receiveGroupInvite(IncomingPacket packet) async {
    final payload = packet.envelope.payload;
    final inviteId = payload['inviteId'];
    final groupId = payload['groupId'];
    final groupName = payload['groupName'];
    final ownerDeviceId = payload['ownerDeviceId'];
    final ownerDisplayName = payload['ownerDisplayName'];
    // 旧版本只发送 Owner 信息，此时邀请人视为 Owner。
    final inviterDeviceId = payload['inviterDeviceId'] ?? ownerDeviceId;
    final inviterDisplayName = payload['inviterDisplayName'] ?? ownerDisplayName;
    if (inviteId is! String ||
        groupId is! String ||
        groupName is! String ||
        ownerDeviceId is! String ||
        ownerDisplayName is! String ||
        inviterDeviceId is! String ||
        inviterDisplayName is! String ||
        !isValidGroupName(groupName) ||
        !isValidDisplayName(ownerDisplayName) ||
        !isValidDisplayName(inviterDisplayName)) {
      return;
    }
    if (trustedPeers[inviterDeviceId] == null ||
        trustedPeers[inviterDeviceId]!.blocked ||
        groupInvitations.containsKey(inviteId)) {
      return;
    }
    groupInvitations[inviteId] = GroupInvitation(
      inviteId: inviteId,
      groupId: groupId,
      groupName: groupName,
      ownerDeviceId: ownerDeviceId,
      ownerDisplayName: ownerDisplayName,
      inviterDeviceId: inviterDeviceId,
      inviterDisplayName: inviterDisplayName,
      ip: packet.remoteAddress,
    );
    _pendingGroupPayloads[inviteId] = payload;
    notifyListeners();
    if (_systemNotificationsAllowed && !_notifications.appIsFocused) {
      await _notifications.show(
        identifier: 'group-invite:$inviteId',
        title: '新的群聊邀请',
        body:
            '${peerDisplayName(inviterDeviceId, inviterDisplayName)} '
            '邀请你加入“${groupDisplayName(groupId, groupName)}”',
        onClick: () {},
      );
    }
  }

  Future<void> _receiveGroupInviteResponse(IncomingPacket packet) async {
    final payload = packet.envelope.payload;
    final inviteId = payload['inviteId'];
    final accepted = payload['accepted'];
    final deviceId = payload['deviceId'];
    final displayName = payload['displayName'];
    if (inviteId is! String ||
        accepted is! bool ||
        deviceId is! String ||
        displayName is! String ||
        !isValidDisplayName(displayName)) {
      return;
    }
    final pending = _outgoingGroupInvites.remove(inviteId);
    if (pending == null || pending.peerDeviceId != deviceId || !accepted) {
      return;
    }
    await _database.saveGroupMember(
      GroupMember(
        groupId: pending.groupId,
        deviceId: deviceId,
        displayName: displayName,
        role: GroupRole.member,
      ),
    );
    notifyListeners();
    // 新成员加入后把完整名单广播给所有人，否则成员之间彼此不可见。
    await _broadcastGroupMembers(pending.groupId);
  }

  Future<void> _receiveGroupMessage(IncomingPacket packet) async {
    final payload = packet.envelope.payload;
    final groupId = payload['groupId'];
    final messageId = payload['messageId'];
    final senderDeviceId = payload['senderDeviceId'];
    final timestamp = payload['timestamp'];
    final content = payload['content'];
    if (groupId is! String ||
        messageId is! String ||
        senderDeviceId is! String ||
        timestamp is! int ||
        timestamp < 0 ||
        content is! String ||
        !isValidTextContent(content) ||
        !isValidIdentifier(messageId) ||
        !isValidIdentifier(senderDeviceId)) {
      return;
    }
    final group = groups.where((value) => value.groupId == groupId).firstOrNull;
    if (group == null || trustedPeers[senderDeviceId]?.blocked == true) return;
    final members = await _database.loadGroupMembers(groupId);
    if (!members.any((member) => member.deviceId == senderDeviceId)) return;
    final mentions = parseMentions(payload['mentions']);
    final reply = _incomingReply(payload);
    final message = ChatMessage(
      messageId: messageId,
      chatId: 'group:$groupId',
      groupId: groupId,
      senderDeviceId: senderDeviceId,
      content: content,
      timestamp: DateTime.fromMillisecondsSinceEpoch(timestamp),
      status: MessageStatus.sent,
      mentions: mentions,
      replyToMessageId: reply.$1,
      replyToSenderId: reply.$2,
      replyToPreview: reply.$3,
    );
    final mentionMe = mentions.contains(identity!.deviceId);
    // 会话已打开就立刻显示；未读只统计没打开的那个会话。
    final conversationOpen = _isConversationOpen('group:$groupId');
    if (!await _database.saveMessage(message)) return;
    if (selectedGroupId == groupId) {
      messages = [...messages, message];
    }
    if (!conversationOpen) {
      await _markUnread(groupId: groupId);
    }
    await _reloadGroups();
    notifyListeners();
    final senderName =
        members
            .where((member) => member.deviceId == senderDeviceId)
            .firstOrNull
            ?.displayName ??
        '群成员';
    if (mentionMe) {
      _showTopRightMessage(
        '${peerDisplayName(senderDeviceId, senderName)} '
        '在“${groupDisplayName(groupId, group.name)}”里 @ 了你',
        icon: Icons.alternate_email,
      );
    }
    final shouldNotify =
        !_openConversationWindows.contains('group:$groupId') &&
        _systemNotificationsAllowed &&
        shouldNotifyForConversation(
          appIsFocused: _notifications.appIsFocused,
          selectedConversationId: selectedGroupId == null
              ? selectedChatId
              : 'group:$selectedGroupId',
          incomingConversationId: 'group:$groupId',
        );
    if (shouldNotify) {
      await _notifications.show(
        identifier: 'group-message:$messageId',
        title: mentionMe
            ? '${groupDisplayName(groupId, group.name)} · @你'
            : groupDisplayName(groupId, group.name),
        body:
            '${peerDisplayName(senderDeviceId, senderName)}：${_notificationPreview(content)}',
        onClick: () => selectGroup(groupId),
      );
    }
  }

  Future<void> _receiveGroupMessageRecall(IncomingPacket packet) async {
    final payload = packet.envelope.payload;
    final groupId = payload['groupId'];
    final messageId = payload['messageId'];
    final actorDeviceId = payload['senderDeviceId'];
    final recalledAt = payload['recalledAt'];
    if (groupId is! String ||
        messageId is! String ||
        actorDeviceId is! String ||
        recalledAt is! int ||
        recalledAt < 0 ||
        !isValidIdentifier(groupId) ||
        !isValidIdentifier(messageId) ||
        !isValidIdentifier(actorDeviceId)) {
      return;
    }
    final group = groups.where((value) => value.groupId == groupId).firstOrNull;
    if (group == null ||
        trustedPeers[actorDeviceId]?.blocked == true ||
        !_packetMatchesDevice(packet, actorDeviceId)) {
      return;
    }
    final members = await _database.loadGroupMembers(groupId);
    if (!members.any((member) => member.deviceId == actorDeviceId)) return;
    final message = await _database.loadMessage(messageId);
    final now = DateTime.now();
    if (message == null ||
        message.groupId != groupId ||
        !canActorRecall(
          message,
          actorDeviceId: actorDeviceId,
          group: group,
          isAdmin: _isGroupAdmin(members, actorDeviceId, group),
          now: now,
        )) {
      return;
    }
    await _applyRecall(message, actorDeviceId, now);
  }

  Future<void> _receiveGroupFileOffer(IncomingPacket packet) async {
    final payload = packet.envelope.payload;
    final groupId = payload['groupId'];
    final senderDeviceId = payload['senderDeviceId'];
    if (groupId is! String || senderDeviceId is! String) return;
    final group = groups.where((value) => value.groupId == groupId).firstOrNull;
    if (group == null || trustedPeers[senderDeviceId]?.blocked == true) return;
    final members = await _database.loadGroupMembers(groupId);
    if (!members.any((member) => member.deviceId == senderDeviceId)) return;
    final message = _incomingFileMessage(
      payload,
      chatId: 'group:$groupId',
      groupId: groupId,
    );
    if (message == null ||
        await _database.loadMessage(message.messageId) != null) {
      return;
    }
    if (!await _database.saveMessage(message)) return;
    // 会话已打开就立刻显示，附件同样不依赖窗口焦点。
    final conversationOpen = _isConversationOpen('group:$groupId');
    if (selectedGroupId == groupId) {
      messages = [...messages, message];
    }
    if (!conversationOpen) {
      await _markUnread(groupId: groupId);
    }
    await _reloadGroups();
    notifyListeners();
    await _notifyIncomingFile(
      message,
      groupDisplayName(groupId, group.name),
      'group:$groupId',
    );
    if (message.status == MessageStatus.pending) {
      await _acceptIncomingFile(
        message,
        packet.remoteAddress,
        _onlinePeer(senderDeviceId)?.port ?? NetworkConfig.chatPort,
      );
    }
  }

  Future<void> _receiveGroupUpdate(IncomingPacket packet) async {
    final payload = packet.envelope.payload;
    final groupId = payload['groupId'];
    final action = payload['action'];
    final senderDeviceId = payload['senderDeviceId'];
    if (groupId is! String || action is! String || senderDeviceId is! String) {
      return;
    }
    final group = groups.where((value) => value.groupId == groupId).firstOrNull;
    if (group == null) return;
    final members = await _database.loadGroupMembers(groupId);
    if (!members.any((member) => member.deviceId == senderDeviceId)) return;

    switch (action) {
      case 'profile':
        final displayName = payload['displayName'];
        if (displayName is! String || !isValidDisplayName(displayName)) {
          return;
        }
        final sender = members
            .where((member) => member.deviceId == senderDeviceId)
            .first;
        await _database.saveGroupMember(
          GroupMember(
            groupId: groupId,
            deviceId: senderDeviceId,
            displayName: displayName.trim(),
            role: sender.role,
          ),
        );
      case 'rename':
        final name = payload['name'];
        if (senderDeviceId != group.ownerDeviceId ||
            name is! String ||
            !isValidGroupName(name)) {
          return;
        }
        final updated = group.copyWith(name: name.trim());
        await _database.saveGroup(updated, members);
        groups = [
          for (final value in groups)
            if (value.groupId == groupId) updated else value,
        ];
      case 'remove':
        final target = payload['targetDeviceId'];
        if (target is! String) return;
        final sender = members
            .where((member) => member.deviceId == senderDeviceId)
            .first;
        final targetMember = members
            .where((member) => member.deviceId == target)
            .firstOrNull;
        if (targetMember == null || target == group.ownerDeviceId) return;
        final allowed =
            senderDeviceId == group.ownerDeviceId ||
            (sender.role == GroupRole.admin &&
                targetMember.role == GroupRole.member);
        if (!allowed) return;
        if (target == identity!.deviceId) {
          await _database.deleteGroup(groupId);
          groups = groups.where((value) => value.groupId != groupId).toList();
          _forgetGroup(groupId);
          if (selectedGroupId == groupId) {
            selectedGroupId = null;
            messages = [];
          }
        } else {
          await _database.removeGroupMember(groupId, target);
        }
      case 'disband':
        if (senderDeviceId != group.ownerDeviceId) return;
        await _database.deleteGroup(groupId);
        groups = groups.where((value) => value.groupId != groupId).toList();
        if (selectedGroupId == groupId) {
          selectedGroupId = null;
          messages = [];
        }
      case 'leave':
        final target = payload['targetDeviceId'];
        if (target != senderDeviceId) return;
        await _database.removeGroupMember(groupId, senderDeviceId);
        if (senderDeviceId == identity!.deviceId) _forgetGroup(groupId);
      case 'members':
        // Owner 或任意成员都可以同步成员名单（成员邀请新人后需要让其他人知道），
        // 但发送者必须已在名单里，且名单必须保留群 Owner。
        final rawMembers = payload['members'];
        if (rawMembers is! List) return;
        final incoming = <GroupMember>[];
        for (final raw in rawMembers.whereType<Map>()) {
          final map = Map<String, dynamic>.from(raw);
          final memberId = map['deviceId'];
          final memberName = map['displayName'];
          final memberRole = map['role'];
          if (memberId is! String ||
              memberName is! String ||
              memberRole is! String ||
              !isValidIdentifier(memberId) ||
              !isValidDisplayName(memberName) ||
              !GroupRole.values.any((role) => role.name == memberRole)) {
            continue;
          }
          incoming.add(
            GroupMember(
              groupId: groupId,
              deviceId: memberId,
              displayName: memberName,
              role: GroupRole.values.byName(memberRole),
            ),
          );
        }
        if (incoming.isEmpty ||
            !incoming.any((member) => member.deviceId == group.ownerDeviceId) ||
            !incoming.any((member) => member.deviceId == senderDeviceId)) {
          return;
        }
        if (!incoming.any((member) => member.deviceId == identity!.deviceId)) {
          await _database.deleteGroup(groupId);
          groups = groups.where((value) => value.groupId != groupId).toList();
          _forgetGroup(groupId);
          if (selectedGroupId == groupId) {
            selectedGroupId = null;
            messages = [];
          }
          break;
        }
        await _database.saveGroup(group, incoming);
        _rememberMyRole(groupId, incoming);
      default:
        return;
    }
    notifyListeners();
  }

  Future<void> _recoverInterruptedRequests() async {
    final interrupted = chats
        .where(
          (chat) =>
              chat.state == ChatSessionState.pendingIncoming ||
              chat.state == ChatSessionState.pendingOutgoing,
        )
        .toList();
    for (final chat in interrupted) {
      await _database.saveChat(
        ChatSummary(
          chatId: chat.chatId,
          peerDeviceId: chat.peerDeviceId,
          displayName: chat.displayName,
          state: ChatSessionState.none,
          lastMessageAt: chat.lastMessageAt,
        ),
      );
    }
    if (interrupted.isNotEmpty) await _reloadChats();
  }

  void _scheduleRequestTimeout(ChatRequest request) {
    _chatRequestTimers[request.requestId]?.cancel();
    _chatRequestTimers[request.requestId] = Timer(
      _requestTimeout,
      () => unawaited(_expireChatRequest(request)),
    );
  }

  Future<void> _expireChatRequest(ChatRequest request) async {
    if (!identical(chatRequests[request.requestId], request)) return;
    _removeChatRequest(request.requestId);
    await _upsertChat(
      request.peerDeviceId,
      request.displayName,
      ChatSessionState.none,
    );
    if (request.incoming) {
      _showTopRightMessage(
        '来自 ${peerDisplayName(request.peerDeviceId, request.displayName)} '
        '的聊天邀请已超时',
        icon: Icons.schedule,
      );
    } else {
      errorMessage =
          '与 ${peerDisplayName(request.peerDeviceId, request.displayName)} '
          '的连接请求已超时，可以重试';
    }
    notifyListeners();
  }

  ChatRequest? _removeChatRequest(String requestId) {
    _chatRequestTimers.remove(requestId)?.cancel();
    return chatRequests.remove(requestId);
  }

  Future<void> _sendChatAccept({
    required String ip,
    required String requestId,
    required String sessionId,
  }) {
    return _sendToAddress(
      ip,
      ProtocolEnvelope(
        type: MessageType.chatAccept,
        payload: {
          'requestId': requestId,
          'sessionId': sessionId,
          'deviceId': identity!.deviceId,
          'displayName': identity!.displayName,
        },
      ),
    );
  }

  Future<void> _upsertChat(
    String peerDeviceId,
    String displayName,
    ChatSessionState state, {
    String? sessionId,
    bool allowTrustedReconnect = false,
  }) async {
    final existing = chats
        .where((value) => value.peerDeviceId == peerDeviceId)
        .firstOrNull;
    final isTrustedReconnect =
        allowTrustedReconnect &&
        ChatStateMachine.canRestoreTrustedSession(
          trusted: trustedPeers[peerDeviceId] != null,
          blocked: trustedPeers[peerDeviceId]?.blocked == true,
        ) &&
        state == ChatSessionState.active;
    if (existing != null &&
        !isTrustedReconnect &&
        !ChatStateMachine.canTransition(existing.state, state)) {
      _log.warning('拒绝非法会话状态迁移 ${existing.state.name} -> ${state.name}');
      return;
    }
    final chat = ChatSummary(
      chatId:
          existing?.chatId ?? _privateChatId(identity!.deviceId, peerDeviceId),
      peerDeviceId: peerDeviceId,
      displayName: displayName,
      state: state,
      sessionId: sessionId,
      createdAt: existing?.createdAt,
      lastMessageAt: existing?.lastMessageAt,
    );
    await _database.saveChat(chat);
    await _reloadChats();
  }

  Future<void> _reloadChats() async => chats = await _database.loadChats();

  Future<void> _reloadGroups() async => groups = await _database.loadGroups();

  Future<void> _setMessageStatus(String id, MessageStatus status) async {
    if (await _database.updateMessageStatus(id, status) == 0) return;
    _replaceVisibleMessage(id, status: status);
    notifyListeners();
  }

  void _replaceVisibleMessage(
    String id, {
    MessageStatus? status,
    String? filePath,
  }) {
    messages = [
      for (final message in messages)
        if (message.messageId == id)
          message.copyWith(status: status, filePath: filePath)
        else
          message,
    ];
  }

  DiscoveredPeer? _onlinePeer(String deviceId) => peers
      .where((peer) => peer.deviceId == deviceId && peer.online)
      .firstOrNull;

  bool _packetMatchesDevice(IncomingPacket packet, String deviceId) {
    final expected =
        _onlinePeer(deviceId)?.ip ?? trustedPeers[deviceId]?.lastKnownIp;
    return expected != null && expected == packet.remoteAddress;
  }

  /// 设备上下线时刷新列表；新上线的设备会触发一次群历史补发。
  void _handlePeersChanged(List<DiscoveredPeer> value) {
    final previouslyOnline = {
      for (final peer in peers) peer.deviceId: peer.online,
    };
    peers = value;
    for (final peer in value) {
      if (!peer.online) {
        _historySyncedDevices.remove(peer.deviceId);
        continue;
      }
      unawaited(_syncPeerAvatar(peer));
      if (previouslyOnline[peer.deviceId] == true) continue;
      if (_historySyncedDevices.add(peer.deviceId)) {
        unawaited(_syncGroupHistoryWith(peer));
      }
    }
    notifyListeners();
  }

  /// 向刚上线的设备请求共享群中我们缺失的消息。
  Future<void> _syncGroupHistoryWith(DiscoveredPeer peer) async {
    if (groups.isEmpty) return;
    final myDeviceId = identity?.deviceId;
    if (myDeviceId == null) return;
    for (final group in groups.toList()) {
      try {
        final members = await _database.loadGroupMembers(group.groupId);
        if (!members.any((member) => member.deviceId == myDeviceId)) continue;
        if (!members.any((member) => member.deviceId == peer.deviceId)) {
          continue;
        }
        // 向 Owner 拉取最新成员名单，保证成员之间彼此可见。
        if (group.ownerDeviceId == peer.deviceId) {
          await _transport.send(
            peer.ip,
            peer.port,
            ProtocolEnvelope(
              type: MessageType.groupMembersRequest,
              payload: {
                'groupId': group.groupId,
                'requesterDeviceId': myDeviceId,
              },
            ),
          );
        }
        final fallback = DateTime.now()
            .subtract(NetworkConfig.historySyncWindow)
            .millisecondsSinceEpoch;
        final latest = await _database.latestMessageTimestamp(
          'group:${group.groupId}',
          fallback,
        );
        // 同一毫秒可能产生多条消息；向前重叠 1 ms，再靠 messageId 去重，
        // 避免恰好同时间戳但尚未收到的消息永远补不回来。
        final since = latest > 0 ? latest - 1 : 0;
        await _transport.send(
          peer.ip,
          peer.port,
          ProtocolEnvelope(
            type: MessageType.groupHistoryRequest,
            payload: {
              'groupId': group.groupId,
              'since': since,
              'requesterDeviceId': myDeviceId,
            },
          ),
        );
      } on Object catch (error, stack) {
        _log.warning('向 ${peer.deviceId} 请求群历史失败', error, stack);
      }
    }
  }

  Future<void> _receiveGroupHistoryRequest(IncomingPacket packet) async {
    final payload = packet.envelope.payload;
    final groupId = payload['groupId'];
    final since = payload['since'];
    final requesterDeviceId = payload['requesterDeviceId'];
    if (groupId is! String ||
        since is! int ||
        since < 0 ||
        requesterDeviceId is! String ||
        !isValidIdentifier(requesterDeviceId) ||
        requesterDeviceId == identity!.deviceId) {
      return;
    }
    final group = groups.where((value) => value.groupId == groupId).firstOrNull;
    if (group == null) return;
    final members = await _database.loadGroupMembers(groupId);
    if (!members.any((member) => member.deviceId == identity!.deviceId)) return;
    if (!members.any((member) => member.deviceId == requesterDeviceId)) return;
    if (trustedPeers[requesterDeviceId]?.blocked == true) return;
    final messages = await _database.loadMessagesAfter(
      'group:$groupId',
      since,
      limit: NetworkConfig.maxHistoryBatchSize,
    );
    final data = [
      for (final message in messages)
        if (message.kind == MessageKind.text || message.isRecalled)
          {
            'messageId': message.messageId,
            'senderDeviceId': message.senderDeviceId,
            'timestamp': message.timestamp.millisecondsSinceEpoch,
            'content': message.content,
            if (message.isRecalled) 'recalled': true,
            if (message.isRecalled)
              'recalledAt': message.recalledAt!.millisecondsSinceEpoch,
            if (message.isRecalled)
              'recalledByDeviceId': message.recalledByDeviceId,
            if (message.mentions.isNotEmpty) 'mentions': message.mentions,
            'replyToMessageId': ?message.replyToMessageId,
            'replyToSenderId': ?message.replyToSenderId,
            'replyToPreview': ?message.replyToPreview,
          },
    ];
    if (data.isEmpty) return;
    await _sendToAddress(
      packet.remoteAddress,
      ProtocolEnvelope(
        type: MessageType.groupHistoryResponse,
        payload: {
          'groupId': groupId,
          'senderDeviceId': identity!.deviceId,
          'messages': data,
        },
      ),
    );
  }

  /// 成员重连后向 Owner 请求最新名单，Owner 直接回发成员列表。
  Future<void> _receiveGroupMembersRequest(IncomingPacket packet) async {
    final payload = packet.envelope.payload;
    final groupId = payload['groupId'];
    final requesterDeviceId = payload['requesterDeviceId'];
    if (groupId is! String ||
        requesterDeviceId is! String ||
        !isValidIdentifier(requesterDeviceId)) {
      return;
    }
    final group = groups.where((value) => value.groupId == groupId).firstOrNull;
    if (group == null || group.ownerDeviceId != identity!.deviceId) return;
    final members = await _database.loadGroupMembers(groupId);
    if (!members.any((member) => member.deviceId == requesterDeviceId)) return;
    if (trustedPeers[requesterDeviceId]?.blocked == true) return;
    await _sendToAddress(
      packet.remoteAddress,
      ProtocolEnvelope(
        type: MessageType.groupUpdate,
        payload: {
          'groupId': groupId,
          'action': 'members',
          'senderDeviceId': identity!.deviceId,
          'members': [
            for (final member in members)
              {
                'deviceId': member.deviceId,
                'displayName': member.displayName,
                'role': member.role.name,
              },
          ],
        },
      ),
    );
  }

  Future<void> _receiveGroupHistoryResponse(IncomingPacket packet) async {
    final payload = packet.envelope.payload;
    final groupId = payload['groupId'];
    final rawMessages = payload['messages'];
    final senderDeviceId = payload['senderDeviceId'];
    if (groupId is! String ||
        rawMessages is! List ||
        senderDeviceId is! String ||
        !isValidIdentifier(senderDeviceId)) {
      return;
    }
    final group = groups.where((value) => value.groupId == groupId).firstOrNull;
    if (group == null) return;
    final members = await _database.loadGroupMembers(groupId);
    if (!members.any((member) => member.deviceId == identity!.deviceId) ||
        !members.any((member) => member.deviceId == senderDeviceId) ||
        trustedPeers[senderDeviceId]?.blocked == true) {
      return;
    }
    var added = false;
    for (final raw in rawMessages.whereType<Map>()) {
      final item = Map<String, dynamic>.from(raw);
      final messageId = item['messageId'];
      final messageSender = item['senderDeviceId'];
      final timestamp = item['timestamp'];
      final content = item['content'];
      final recalled = item['recalled'] == true;
      if (messageId is! String ||
          messageSender is! String ||
          timestamp is! int ||
          content is! String ||
          !isValidIdentifier(messageId) ||
          !members.any((member) => member.deviceId == messageSender) ||
          (!recalled && !isValidTextContent(content))) {
        continue;
      }
      if (recalled) {
        final actor = item['recalledByDeviceId'];
        final recalledAtValue = item['recalledAt'];
        if (actor is! String ||
            recalledAtValue is! int ||
            !members.any((member) => member.deviceId == actor)) {
          continue;
        }
        final original = ChatMessage(
          messageId: messageId,
          chatId: 'group:$groupId',
          groupId: groupId,
          senderDeviceId: messageSender,
          content: '',
          timestamp: DateTime.fromMillisecondsSinceEpoch(timestamp),
          status: MessageStatus.sent,
        );
        final recalledAt = DateTime.fromMillisecondsSinceEpoch(recalledAtValue);
        if (recalledAt.isAfter(
              DateTime.now().add(NetworkConfig.recallClockSkewTolerance),
            ) ||
            !canActorRecall(
              original,
              actorDeviceId: actor,
              group: group,
              isAdmin: _isGroupAdmin(members, actor, group),
              now: recalledAt,
            )) {
          continue;
        }
        final existing = await _database.loadMessage(messageId);
        if (existing == null) {
          final inserted = await _database.saveMessage(
            original.asRecalled(byDeviceId: actor, at: recalledAt),
          );
          added = inserted || added;
        } else {
          final changed = await _database.recallMessage(
            messageId,
            recalledByDeviceId: actor,
            recalledAt: recalledAt,
          );
          added = changed || added;
        }
        continue;
      }
      if (await _database.loadMessage(messageId) != null) continue;
      final reply = _incomingReply(item);
      final inserted = await _database.saveMessage(
        ChatMessage(
          messageId: messageId,
          chatId: 'group:$groupId',
          groupId: groupId,
          senderDeviceId: messageSender,
          content: content,
          timestamp: DateTime.fromMillisecondsSinceEpoch(timestamp),
          status: MessageStatus.sent,
          mentions: parseMentions(item['mentions']),
          replyToMessageId: reply.$1,
          replyToSenderId: reply.$2,
          replyToPreview: reply.$3,
        ),
      );
      added = inserted || added;
    }
    if (!added) return;
    if (selectedGroupId == groupId) {
      messages = await _database.loadMessages('group:$groupId');
    }
    await _reloadGroups();
    notifyListeners();
    _showTopRightMessage(
      '已同步“${groupDisplayName(groupId, group.name)}”的离线消息',
      icon: Icons.sync,
    );
  }

  Future<void> _sendToAddress(String ip, ProtocolEnvelope envelope) =>
      _transport.send(ip, NetworkConfig.chatPort, envelope);

  static String _privateChatId(String a, String b) {
    final ids = [a, b]..sort();
    return 'private:${ids[0]}:${ids[1]}';
  }

  static String _notificationPreview(String content) {
    final normalized = content.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (normalized.length <= 100) return normalized;
    return '${normalized.substring(0, 100)}…';
  }

  /// 把字节数格式化为 B/KB/MB 文本，供控制器与聊天界面共用，避免重复实现。
  static String formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  String _friendlyError(Object error) {
    if (error is ArgumentError) return error.message?.toString() ?? '输入无效';
    return '操作失败：$error';
  }

  void clearError() {
    errorMessage = null;
    notifyListeners();
  }

  void _showTopRightMessage(String message, {IconData icon = Icons.block}) {
    _topRightMessageTimer?.cancel();
    topRightMessage = message;
    topRightIcon = icon;
    notifyListeners();
    _topRightMessageTimer = Timer(const Duration(seconds: 4), () {
      topRightMessage = null;
      notifyListeners();
    });
  }

  void clearTopRightMessage() {
    _topRightMessageTimer?.cancel();
    _topRightMessageTimer = null;
    topRightMessage = null;
    notifyListeners();
  }

  Future<void> showTestNotification() async {
    if (!_systemNotificationsAllowed) {
      _showTopRightMessage('请先开启 Windows 通知', icon: Icons.notifications_off);
      return;
    }
    await _notifications.show(
      identifier: 'neko-chat:test',
      title: 'NekoChat 系统通知已启用',
      body: '新的聊天邀请和消息会通过这里提醒你。',
      onClick: () {},
    );
  }

  static bool _settingBool(String? value, {required bool fallback}) =>
      switch (value) {
        'true' => true,
        'false' => false,
        _ => fallback,
      };

  static int _settingInt(String? value, {required int fallback}) =>
      int.tryParse(value ?? '') ?? fallback;

  static String? _normalizeRemark(String value) {
    final normalized = value.trim();
    if (normalized.isEmpty) return null;
    if (normalized.characters.length > NetworkConfig.maxRemarkLength) {
      throw ArgumentError('备注不能超过 ${NetworkConfig.maxRemarkLength} 个字符');
    }
    return normalized;
  }

  void _fail(
    String message,
    Object error,
    StackTrace stack, {
    AppStage? keepStage,
  }) {
    _log.severe(message, error, stack);
    errorMessage = message;
    stage = keepStage ?? AppStage.error;
  }

  @override
  void dispose() {
    _topRightMessageTimer?.cancel();
    for (final timer in _chatRequestTimers.values) {
      timer.cancel();
    }
    _chatRequestTimers.clear();
    unawaited(_discovery?.stop());
    unawaited(_transport.stop());
    unawaited(_database.close());
    unawaited(_notifications.dispose());
    unawaited(_bossKey.dispose());
    super.dispose();
  }
}
