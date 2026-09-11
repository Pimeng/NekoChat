enum MessageStatus { pending, awaitingAcceptance, sent, rejected, failed }

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
    this.lastMessageAt,
  });
  final String chatId;
  final String peerDeviceId;
  final String displayName;
  final ChatSessionState state;
  final String? sessionId;
  final DateTime? lastMessageAt;
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
}

class ChatGroup {
  const ChatGroup({
    required this.groupId,
    required this.name,
    required this.ownerDeviceId,
    required this.createdAt,
  });
  final String groupId;
  final String name;
  final String ownerDeviceId;
  final DateTime createdAt;
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
