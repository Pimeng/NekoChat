enum MessageStatus {
  pending,
  awaitingAcceptance,
  sent,
  rejected,
  failed,
  recalled,
}

enum MessageKind { text, image, file }

enum ChatSessionState {
  none,
  pendingIncoming,
  pendingOutgoing,
  active,
  rejected,
  blocked,
}

enum GroupRole { owner, member }

class LocalIdentity {
  const LocalIdentity({
    required this.deviceId,
    required this.displayName,
    required this.createdAt,
    required this.lastLoginAt,
  });
  final String deviceId;
  final String displayName;
  final DateTime createdAt;
  final DateTime lastLoginAt;

  LocalIdentity copyWith({String? displayName, DateTime? lastLoginAt}) =>
      LocalIdentity(
        deviceId: deviceId,
        displayName: displayName ?? this.displayName,
        createdAt: createdAt,
        lastLoginAt: lastLoginAt ?? this.lastLoginAt,
      );
}

class TrustedPeer {
  const TrustedPeer({
    required this.deviceId,
    required this.displayName,
    required this.lastKnownIp,
    required this.verifiedAt,
    this.blocked = false,
  });
  final String deviceId;
  final String displayName;
  final String lastKnownIp;
  final DateTime verifiedAt;
  final bool blocked;
}

class DiscoveredPeer {
  const DiscoveredPeer({
    required this.deviceId,
    required this.displayName,
    required this.ip,
    required this.port,
    required this.lastSeen,
    required this.trusted,
    required this.online,
    this.locationChanged = false,
  });
  final String deviceId;
  final String displayName;
  final String ip;
  final int port;
  final DateTime lastSeen;
  final bool trusted;
  final bool online;
  final bool locationChanged;

  DiscoveredPeer copyWith({bool? online, bool? trusted}) => DiscoveredPeer(
    deviceId: deviceId,
    displayName: displayName,
    ip: ip,
    port: port,
    lastSeen: lastSeen,
    trusted: trusted ?? this.trusted,
    online: online ?? this.online,
    locationChanged: locationChanged,
  );
}

class ChatRequest {
  const ChatRequest({
    required this.requestId,
    required this.peerDeviceId,
    required this.displayName,
    required this.ip,
    required this.verificationCode,
    required this.incoming,
  });
  final String requestId;
  final String peerDeviceId;
  final String displayName;
  final String ip;
  final String verificationCode;
  final bool incoming;
}

class ChatSummary {
  const ChatSummary({
    required this.chatId,
    required this.peerDeviceId,
    required this.displayName,
    required this.state,
    this.sessionId,
    this.createdAt,
    this.lastMessageAt,
    this.unreadCount = 0,
    this.lastMessagePreview,
  });
  final String chatId;
  final String peerDeviceId;
  final String displayName;
  final ChatSessionState state;
  final String? sessionId;

  /// 会话首次建立的时间。重新保存会话时会沿用已有值，缺失时由数据库补齐。
  final DateTime? createdAt;
  final DateTime? lastMessageAt;

  /// 未读消息数。只由数据库的未读接口变更，重新保存会话不会覆盖它。
  final int unreadCount;

  /// 侧边栏展示用的最新一条消息摘要。
  final String? lastMessagePreview;

  ChatSummary copyWith({
    String? displayName,
    ChatSessionState? state,
    String? sessionId,
    DateTime? lastMessageAt,
    int? unreadCount,
    String? lastMessagePreview,
  }) => ChatSummary(
    chatId: chatId,
    peerDeviceId: peerDeviceId,
    displayName: displayName ?? this.displayName,
    state: state ?? this.state,
    sessionId: sessionId ?? this.sessionId,
    createdAt: createdAt,
    lastMessageAt: lastMessageAt ?? this.lastMessageAt,
    unreadCount: unreadCount ?? this.unreadCount,
    lastMessagePreview: lastMessagePreview ?? this.lastMessagePreview,
  );
}

class ChatMessage {
  const ChatMessage({
    required this.messageId,
    required this.chatId,
    required this.senderDeviceId,
    required this.content,
    required this.timestamp,
    required this.status,
    this.groupId,
    this.kind = MessageKind.text,
    this.fileName,
    this.filePath,
    this.fileSize,
    this.mimeType,
    this.transferId,
    this.fileHash,
    this.replyToMessageId,
    this.replyToSenderId,
    this.replyToPreview,
    this.mentions = const [],
    this.recalledAt,
    this.recalledByDeviceId,
  });
  final String messageId;
  final String chatId;
  final String senderDeviceId;
  final String content;
  final DateTime timestamp;
  final MessageStatus status;
  final String? groupId;
  final MessageKind kind;
  final String? fileName;
  final String? filePath;
  final int? fileSize;
  final String? mimeType;
  final String? transferId;
  final String? fileHash;

  /// 被引用的消息 id、发送者以及摘要。摘要随消息一起传输，对方缺少原消息也能展示。
  final String? replyToMessageId;
  final String? replyToSenderId;
  final String? replyToPreview;

  /// 群消息中被 @ 到的成员设备号，用于高亮并提醒被提及的人。
  final List<String> mentions;

  /// 撤回后只保留消息身份与时间线位置，原正文和附件引用会从数据库清除。
  final DateTime? recalledAt;
  final String? recalledByDeviceId;

  bool get isRecalled => status == MessageStatus.recalled;

  bool get isReply => replyToMessageId != null;

  bool mentionsDevice(String deviceId) => mentions.contains(deviceId);

  ChatMessage copyWith({
    MessageStatus? status,
    String? filePath,
    List<String>? mentions,
  }) => ChatMessage(
    messageId: messageId,
    chatId: chatId,
    groupId: groupId,
    senderDeviceId: senderDeviceId,
    content: content,
    timestamp: timestamp,
    status: status ?? this.status,
    kind: kind,
    fileName: fileName,
    filePath: filePath ?? this.filePath,
    fileSize: fileSize,
    mimeType: mimeType,
    transferId: transferId,
    fileHash: fileHash,
    replyToMessageId: replyToMessageId,
    replyToSenderId: replyToSenderId,
    replyToPreview: replyToPreview,
    mentions: mentions ?? this.mentions,
    recalledAt: recalledAt,
    recalledByDeviceId: recalledByDeviceId,
  );

  ChatMessage asRecalled({required String byDeviceId, required DateTime at}) =>
      ChatMessage(
        messageId: messageId,
        chatId: chatId,
        groupId: groupId,
        senderDeviceId: senderDeviceId,
        content: '',
        timestamp: timestamp,
        status: MessageStatus.recalled,
        kind: kind,
        recalledAt: at,
        recalledByDeviceId: byDeviceId,
      );
}

class ChatGroup {
  const ChatGroup({
    required this.groupId,
    required this.name,
    required this.ownerDeviceId,
    required this.createdAt,
    this.lastMessageAt,
    this.unreadCount = 0,
    this.lastMessagePreview,
  });
  final String groupId;
  final String name;
  final String ownerDeviceId;
  final DateTime createdAt;
  final DateTime? lastMessageAt;

  /// 未读消息数。只由数据库的未读接口变更，重新保存群资料不会覆盖它。
  final int unreadCount;

  /// 侧边栏展示用的最新一条群消息摘要。
  final String? lastMessagePreview;

  ChatGroup copyWith({
    String? name,
    DateTime? lastMessageAt,
    int? unreadCount,
    String? lastMessagePreview,
  }) => ChatGroup(
    groupId: groupId,
    name: name ?? this.name,
    ownerDeviceId: ownerDeviceId,
    createdAt: createdAt,
    lastMessageAt: lastMessageAt ?? this.lastMessageAt,
    unreadCount: unreadCount ?? this.unreadCount,
    lastMessagePreview: lastMessagePreview ?? this.lastMessagePreview,
  );
}

class GroupMember {
  const GroupMember({
    required this.groupId,
    required this.deviceId,
    required this.displayName,
    required this.role,
  });
  final String groupId;
  final String deviceId;
  final String displayName;
  final GroupRole role;
}

class GroupInvitation {
  const GroupInvitation({
    required this.inviteId,
    required this.groupId,
    required this.groupName,
    required this.ownerDeviceId,
    required this.ownerDisplayName,
    required this.ip,
  });
  final String inviteId;
  final String groupId;
  final String groupName;
  final String ownerDeviceId;
  final String ownerDisplayName;
  final String ip;
}

/// 输入框里暂存的待发送附件。还没发出去，可以继续编辑文字或移除。
class PendingAttachment {
  const PendingAttachment({
    required this.path,
    required this.fileName,
    required this.fileSize,
    required this.mimeType,
    required this.isImage,
  });
  final String path;
  final String fileName;
  final int fileSize;
  final String mimeType;
  final bool isImage;
}
