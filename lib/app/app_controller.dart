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
import '../core/database/app_database.dart';
import '../core/files/attachment_path.dart';
import '../core/files/content_hash.dart';
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
    DiscoveryServiceFactory? discoveryFactory,
    this._requestTimeout = NetworkConfig.requestTimeout,
  }) : _keyProvider = keyProvider ?? EncryptedFileDatabaseKeyProvider(),
       _database = database ?? AppDatabase(),
       _transport = transport ?? WebSocketChatTransport(),
       _notifications = notifications ?? DesktopSystemNotificationService(),
       _discoveryFactory = discoveryFactory ?? _defaultDiscoveryFactory;

  static const _uuid = Uuid();
  final LocalDatabaseKeyProvider _keyProvider;
  final AppDatabase _database;
  final ChatTransport _transport;
  final SystemNotificationService _notifications;
  final DiscoveryServiceFactory _discoveryFactory;
  final Duration _requestTimeout;
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

  /// 当前数据目录。数据库、解锁密钥和已接收的附件都在这里，整体拷贝即可搬走。
  String? dataDirectory;
  Map<String, TrustedPeer> trustedPeers = {};
  List<DiscoveredPeer> peers = [];
  List<ChatSummary> chats = [];
  List<ChatGroup> groups = [];
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
    trustedPeers = await _database.loadTrustedPeers();
    chats = await _database.loadChats();
    await _recoverInterruptedRequests();
    groups = await _database.loadGroups();
    final localIdentity = identity!;
    await _notifications.initialize();
    await _transport.start(_onPacket);
    _discovery = _discoveryFactory(
      identity: localIdentity,
      trustLookup: (id) => trustedPeers[id],
      onPeersChanged: _handlePeersChanged,
    );
    await _discovery!.start();
    errorMessage = null;
    dataDirectory = _database.directoryPath;
    stage = AppStage.ready;
    _log.info('应用已就绪，deviceId=${localIdentity.deviceId}');
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
      errorMessage = '无法连接 ${peer.displayName}';
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

  Future<void> selectChat(String chatId) async {
    selectedGroupId = null;
    selectedChatId = chatId;
    replyingTo = null;
    await _clearUnread(chatId: chatId);
    messages = await _database.loadMessages(chatId);
    notifyListeners();
  }

  Future<void> sendMessage(String content) async {
    final normalized = content.trim();
    if (normalized.isEmpty) return;
    if (selectedGroupId != null) {
      await _sendGroupMessage(selectedGroupId!, normalized);
      return;
    }
    final chat = chats
        .where((value) => value.chatId == selectedChatId)
        .firstOrNull;
    if (chat == null ||
        chat.state != ChatSessionState.active ||
        chat.sessionId == null) {
      return;
    }
    final reply = replyingTo;
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
    replyingTo = null;
    await _database.saveMessage(message);
    messages = [...messages, message];
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

  /// 校验并描述一个待发送附件。文件不存在或超过大小限制时返回 null 并提示。
  Future<PendingAttachment?> pendingAttachment(String filePath) async {
    final file = File(filePath);
    if (!await file.exists()) {
      _showTopRightMessage('所选文件不存在', icon: Icons.error_outline);
      return null;
    }
    final fileSize = await file.length();
    if (fileSize > NetworkConfig.maxFileSizeBytes) {
      _showTopRightMessage('文件不能超过 512 MB', icon: Icons.error_outline);
      return null;
    }
    final mimeType = lookupMimeType(file.path) ?? 'application/octet-stream';
    return PendingAttachment(
      path: file.path,
      fileName: p.basename(file.path),
      fileSize: fileSize,
      mimeType: mimeType,
      isImage: mimeType.startsWith('image/'),
    );
  }

  /// 发送输入框里的文字与附件：文字先发（引用挂在文字上），附件按顺序紧跟其后。
  ///
  /// 没有文字时引用会落到第一个附件上，这样「引用 + 图片」也能成立。
  Future<void> sendMessageWithAttachments({
    required String content,
    required List<PendingAttachment> attachments,
  }) async {
    if (content.trim().isEmpty && attachments.isEmpty) return;
    if (content.trim().isNotEmpty) {
      await sendMessage(content);
    }
    for (final attachment in attachments) {
      await sendFile(attachment.path);
    }
  }

  Future<void> sendFile(String filePath) async {
    final file = File(filePath);
    if (!await file.exists()) {
      errorMessage = '所选文件不存在';
      notifyListeners();
      return;
    }
    final fileSize = await file.length();
    if (fileSize > NetworkConfig.maxFileSizeBytes) {
      errorMessage = '文件不能超过 512 MB';
      notifyListeners();
      return;
    }
    final mimeType = lookupMimeType(file.path) ?? 'application/octet-stream';
    final fileHash = mimeType.startsWith('image/')
        ? await sha256File(file)
        : null;
    if (selectedGroupId != null) {
      await _sendGroupFile(
        selectedGroupId!,
        file,
        fileSize,
        mimeType,
        fileHash,
      );
      return;
    }
    final chat = chats
        .where((value) => value.chatId == selectedChatId)
        .firstOrNull;
    if (chat == null ||
        chat.state != ChatSessionState.active ||
        chat.sessionId == null) {
      return;
    }
    final peer = _onlinePeer(chat.peerDeviceId);
    if (peer == null) {
      errorMessage = '${chat.displayName} 当前离线，无法发送文件';
      notifyListeners();
      return;
    }
    final message = _localFileMessage(
      chatId: chat.chatId,
      file: file,
      fileSize: fileSize,
      mimeType: mimeType,
      fileHash: fileHash,
    );
    replyingTo = null;
    await _database.saveMessage(message);
    messages = [...messages, message];
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
  }) {
    final reply = replyingTo;
    return ChatMessage(
      messageId: _uuid.v4(),
      chatId: chatId,
      groupId: groupId,
      senderDeviceId: identity!.deviceId,
      content: p.basename(file.path),
      timestamp: DateTime.now(),
      status: NetworkConfig.requiresFileAcceptance(fileSize)
          ? MessageStatus.awaitingAcceptance
          : MessageStatus.pending,
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
        final arguments = revealPath == null
            ? [directoryPath]
            : ['/select,', revealPath];
        await Process.start(
          'explorer.exe',
          arguments,
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
    notifyListeners();
    for (final peer in invitees.where(
      (value) => value.online && value.trusted,
    )) {
      await inviteToGroup(group, peer);
    }
    return group;
  }

  Future<void> inviteToGroup(ChatGroup group, DiscoveredPeer peer) async {
    if (group.ownerDeviceId != identity!.deviceId || !peer.online) return;
    final inviteId = _uuid.v4();
    _outgoingGroupInvites[inviteId] = (
      groupId: group.groupId,
      peerDeviceId: peer.deviceId,
    );
    final members = await _database.loadGroupMembers(group.groupId);
    await _transport.send(
      peer.ip,
      peer.port,
      ProtocolEnvelope(
        type: MessageType.groupInvite,
        payload: {
          'inviteId': inviteId,
          'groupId': group.groupId,
          'groupName': group.name,
          'ownerDeviceId': identity!.deviceId,
          'ownerDisplayName': identity!.displayName,
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
    final raw = message.kind == MessageKind.text
        ? message.content
        : (message.fileName ?? message.content);
    final normalized = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (normalized.length <= NetworkConfig.maxReplyPreviewLength) {
      return normalized;
    }
    return '${normalized.substring(0, NetworkConfig.maxReplyPreviewLength)}…';
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

  Future<List<GroupMember>> groupMembers(String groupId) =>
      _database.loadGroupMembers(groupId);

  Future<void> renameGroup(ChatGroup group, String name) async {
    final normalized = name.trim();
    if (group.ownerDeviceId != identity!.deviceId ||
        normalized.isEmpty ||
        !isValidGroupName(normalized)) {
      return;
    }
    final members = await _database.loadGroupMembers(group.groupId);
    final updated = ChatGroup(
      groupId: group.groupId,
      name: normalized,
      ownerDeviceId: group.ownerDeviceId,
      createdAt: group.createdAt,
    );
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

  Future<void> removeGroupMember(ChatGroup group, GroupMember member) async {
    if (group.ownerDeviceId != identity!.deviceId ||
        member.deviceId == identity!.deviceId) {
      return;
    }
    final members = await _database.loadGroupMembers(group.groupId);
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
    if (selectedGroupId == group.groupId) {
      selectedGroupId = null;
      messages = [];
    }
    notifyListeners();
  }

  Future<void> _sendGroupMessage(String groupId, String content) async {
    final members = await _database.loadGroupMembers(groupId);
    if (!members.any((member) => member.deviceId == identity!.deviceId)) return;
    final reply = replyingTo;
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
    replyingTo = null;
    await _database.saveMessage(message);
    messages = [...messages, message];
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
      if (content.contains('@${member.displayName}')) {
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
    String? fileHash,
  ) async {
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
    );
    replyingTo = null;
    await _database.saveMessage(message);
    messages = [...messages, message];
    await _reloadGroups();
    notifyListeners();
    if (recipients.isEmpty) {
      await _setMessageStatus(message.messageId, MessageStatus.failed);
      errorMessage = '当前没有在线群成员，文件未发送';
      notifyListeners();
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

  /// Owner 把最新成员名单广播给所有成员。
  Future<void> _broadcastGroupMembers(String groupId) async {
    final group = groups.where((value) => value.groupId == groupId).firstOrNull;
    if (group == null || group.ownerDeviceId != identity!.deviceId) return;
    final members = await _database.loadGroupMembers(groupId);
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
    if (!_notifications.appIsFocused) {
      await _notifications.show(
        identifier: 'chat-request:$requestId',
        title: '新的聊天邀请',
        body: '$displayName 请求与你聊天，验证码 ${request.verificationCode}',
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
    if (!_notifications.appIsFocused) {
      final chatId = _privateChatId(identity!.deviceId, deviceId);
      await _notifications.show(
        identifier: 'chat-accept:$sessionId',
        title: '$displayName 已接受聊天邀请',
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
        content is! String ||
        !isValidTextContent(content)) {
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
    final conversationOpen = selectedChatId == chat.chatId;
    await _database.saveMessage(message);
    if (conversationOpen) {
      messages = [...messages, message];
    } else {
      await _markUnread(chatId: chat.chatId);
    }
    await _reloadChats();
    notifyListeners();
    if (shouldNotifyForConversation(
      appIsFocused: _notifications.appIsFocused,
      selectedConversationId: selectedChatId,
      incomingConversationId: chat.chatId,
    )) {
      await _notifications.show(
        identifier: 'message:$messageId',
        title: chat.displayName,
        body: _notificationPreview(content),
        onClick: () => selectChat(chat.chatId),
      );
    }
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
    await _database.saveMessage(message);
    // 会话已打开就立刻显示，附件同样不依赖窗口焦点。
    final conversationOpen = selectedChatId == chat.chatId;
    if (conversationOpen) {
      messages = [...messages, message];
    } else {
      await _markUnread(chatId: chat.chatId);
    }
    await _reloadChats();
    notifyListeners();
    await _notifyIncomingFile(message, chat.displayName, chat.chatId);
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
        fileSize > NetworkConfig.maxFileSizeBytes ||
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
      status: NetworkConfig.requiresFileAcceptance(fileSize)
          ? MessageStatus.awaitingAcceptance
          : MessageStatus.pending,
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
          '${chat!.displayName} 已拒收${message.kind == MessageKind.image ? '图片' : '文件'}“${message.fileName}”',
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
      await _database.updateMessageAttachment(
        message.messageId,
        filePath: filePath,
        status: MessageStatus.sent,
      );
      _replaceVisibleMessage(
        message.messageId,
        filePath: filePath,
        status: MessageStatus.sent,
      );
    } on Object catch (error, stack) {
      _log.warning('文件下载失败', error, stack);
      await _database.updateMessageAttachment(
        message.messageId,
        filePath: null,
        status: MessageStatus.failed,
      );
      _replaceVisibleMessage(message.messageId, status: MessageStatus.failed);
    }
    notifyListeners();
  }

  Future<void> _notifyIncomingFile(
    ChatMessage message,
    String senderName,
    String conversationId,
  ) async {
    if (!shouldNotifyForConversation(
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
      body: '${message.fileName}（${_formatFileSize(message.fileSize ?? 0)}）',
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
    if (inviteId is! String ||
        groupId is! String ||
        groupName is! String ||
        ownerDeviceId is! String ||
        ownerDisplayName is! String ||
        !isValidGroupName(groupName) ||
        !isValidDisplayName(ownerDisplayName)) {
      return;
    }
    if (trustedPeers[ownerDeviceId] == null ||
        trustedPeers[ownerDeviceId]!.blocked ||
        groupInvitations.containsKey(inviteId)) {
      return;
    }
    groupInvitations[inviteId] = GroupInvitation(
      inviteId: inviteId,
      groupId: groupId,
      groupName: groupName,
      ownerDeviceId: ownerDeviceId,
      ownerDisplayName: ownerDisplayName,
      ip: packet.remoteAddress,
    );
    _pendingGroupPayloads[inviteId] = payload;
    notifyListeners();
    if (!_notifications.appIsFocused) {
      await _notifications.show(
        identifier: 'group-invite:$inviteId',
        title: '新的群聊邀请',
        body: '$ownerDisplayName 邀请你加入“$groupName”',
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
        content is! String ||
        !isValidTextContent(content)) {
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
    final conversationOpen = selectedGroupId == groupId;
    await _database.saveMessage(message);
    if (conversationOpen) {
      messages = [...messages, message];
    } else {
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
        '$senderName 在“${group.name}”里 @ 了你',
        icon: Icons.alternate_email,
      );
    }
    final shouldNotify = shouldNotifyForConversation(
      appIsFocused: _notifications.appIsFocused,
      selectedConversationId: selectedGroupId == null
          ? selectedChatId
          : 'group:$selectedGroupId',
      incomingConversationId: 'group:$groupId',
    );
    if (shouldNotify) {
      await _notifications.show(
        identifier: 'group-message:$messageId',
        title: mentionMe ? '${group.name} · @你' : group.name,
        body: '$senderName：${_notificationPreview(content)}',
        onClick: () => selectGroup(groupId),
      );
    }
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
    await _database.saveMessage(message);
    // 会话已打开就立刻显示，附件同样不依赖窗口焦点。
    final conversationOpen = selectedGroupId == groupId;
    if (conversationOpen) {
      messages = [...messages, message];
    } else {
      await _markUnread(groupId: groupId);
    }
    await _reloadGroups();
    notifyListeners();
    await _notifyIncomingFile(message, group.name, 'group:$groupId');
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
      case 'rename':
        if (senderDeviceId != group.ownerDeviceId ||
            payload['name'] is! String) {
          return;
        }
        final updated = ChatGroup(
          groupId: group.groupId,
          name: payload['name'] as String,
          ownerDeviceId: group.ownerDeviceId,
          createdAt: group.createdAt,
        );
        await _database.saveGroup(updated, members);
        groups = [
          for (final value in groups)
            if (value.groupId == groupId) updated else value,
        ];
      case 'remove':
        if (senderDeviceId != group.ownerDeviceId ||
            payload['targetDeviceId'] is! String) {
          return;
        }
        final target = payload['targetDeviceId'] as String;
        if (target == identity!.deviceId) {
          await _database.deleteGroup(groupId);
          groups = groups.where((value) => value.groupId != groupId).toList();
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
      case 'members':
        if (senderDeviceId != group.ownerDeviceId) return;
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
            !incoming.any((member) => member.deviceId == group.ownerDeviceId)) {
          return;
        }
        if (!incoming.any((member) => member.deviceId == identity!.deviceId)) {
          await _database.deleteGroup(groupId);
          groups = groups.where((value) => value.groupId != groupId).toList();
          if (selectedGroupId == groupId) {
            selectedGroupId = null;
            messages = [];
          }
          break;
        }
        await _database.saveGroup(group, incoming);
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
        '来自 ${request.displayName} 的聊天邀请已超时',
        icon: Icons.schedule,
      );
    } else {
      errorMessage = '与 ${request.displayName} 的连接请求已超时，可以重试';
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
    await _database.updateMessageStatus(id, status);
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
        final since = await _database.latestMessageTimestamp(
          'group:${group.groupId}',
          fallback,
        );
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
        if (message.kind == MessageKind.text)
          {
            'messageId': message.messageId,
            'senderDeviceId': message.senderDeviceId,
            'timestamp': message.timestamp.millisecondsSinceEpoch,
            'content': message.content,
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
      if (messageId is! String ||
          messageSender is! String ||
          timestamp is! int ||
          content is! String ||
          !isValidTextContent(content) ||
          !isValidIdentifier(messageId) ||
          !members.any((member) => member.deviceId == messageSender) ||
          await _database.loadMessage(messageId) != null) {
        continue;
      }
      final reply = _incomingReply(item);
      await _database.saveMessage(
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
      added = true;
    }
    if (!added) return;
    if (selectedGroupId == groupId) {
      messages = await _database.loadMessages('group:$groupId');
    }
    await _reloadGroups();
    notifyListeners();
    _showTopRightMessage('已同步“${group.name}”的离线消息', icon: Icons.sync);
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

  static String _formatFileSize(int bytes) {
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

  Future<void> showTestNotification() => _notifications.show(
    identifier: 'neko-chat:test',
    title: 'NekoChat 系统通知已启用',
    body: '新的聊天邀请和消息会通过这里提醒你。',
    onClick: () {},
  );

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
    super.dispose();
  }
}
