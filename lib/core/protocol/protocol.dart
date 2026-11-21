import 'dart:convert';

import '../config/network_config.dart';

enum MessageType {
  announce('announce'),
  hello('hello'),
  chatRequest('chat_request'),
  chatAccept('chat_accept'),
  chatReject('chat_reject'),
  message('message'),
  messageRecall('message_recall'),
  fileOffer('file_offer'),
  fileAccept('file_accept'),
  fileReject('file_reject'),
  sessionClose('session_close'),
  groupInvite('group_invite'),
  groupInviteResponse('group_invite_response'),
  groupMessage('group_message'),
  groupMessageRecall('group_message_recall'),
  groupFileOffer('group_file_offer'),
  groupUpdate('group_update'),
  groupHistoryRequest('group_history_request'),
  groupHistoryResponse('group_history_response'),
  groupMembersRequest('group_members_request'),
  error('error');

  const MessageType(this.wireName);
  final String wireName;

  static MessageType? fromWire(String value) {
    for (final type in values) {
      if (type.wireName == value) return type;
    }
    return null;
  }
}

class ProtocolException implements Exception {
  const ProtocolException(this.message);
  final String message;
  @override
  String toString() => 'ProtocolException: $message';
}

class ProtocolEnvelope {
  const ProtocolEnvelope({
    required this.type,
    required this.payload,
    this.protocolVersion = NetworkConfig.protocolVersion,
  });
  final int protocolVersion;
  final MessageType type;
  final Map<String, dynamic> payload;
  Map<String, dynamic> toJson() => {
    'protocolVersion': protocolVersion,
    'type': type.wireName,
    'payload': payload,
  };
}

abstract final class ProtocolCodec {
  static String encode(ProtocolEnvelope envelope) =>
      jsonEncode(envelope.toJson());

  static ProtocolEnvelope? decode(String source) {
    final value = jsonDecode(source);
    if (value is! Map<String, dynamic>) {
      throw const ProtocolException('消息根节点必须是对象');
    }
    final version = value['protocolVersion'];
    if (version is! int) throw const ProtocolException('缺少协议版本');
    if (version != NetworkConfig.protocolVersion) {
      throw ProtocolException('不兼容的协议版本：$version');
    }
    final rawType = value['type'];
    if (rawType is! String) throw const ProtocolException('缺少消息类型');
    final type = MessageType.fromWire(rawType);
    if (type == null) return null;
    final payload = value['payload'];
    if (payload is! Map<String, dynamic>) {
      throw const ProtocolException('payload 必须是对象');
    }
    return ProtocolEnvelope(type: type, payload: payload);
  }
}

/// 入站昵称必须非空且不超过 [NetworkConfig.maxDisplayNameLength]。
bool isValidDisplayName(String value) {
  final trimmed = value.trim();
  return trimmed.isNotEmpty &&
      trimmed.length <= NetworkConfig.maxDisplayNameLength;
}

/// 入站群名必须非空且不超过 [NetworkConfig.maxGroupNameLength]。
bool isValidGroupName(String value) {
  final trimmed = value.trim();
  return trimmed.isNotEmpty &&
      trimmed.length <= NetworkConfig.maxGroupNameLength;
}

/// 入站文本消息必须非空且不超过 [NetworkConfig.maxTextMessageLength]。
bool isValidTextContent(String value) =>
    value.isNotEmpty && value.length <= NetworkConfig.maxTextMessageLength;

/// 引用摘要可以为空，但长度不能超过 [NetworkConfig.maxReplyPreviewLength]。
bool isValidReplyPreview(String value) =>
    value.length <= NetworkConfig.maxReplyPreviewLength;

/// 入站消息 ID、设备号等标识符必须非空且不过长。
bool isValidIdentifier(String value) => value.isNotEmpty && value.length <= 128;

/// 解析 @ 提及的设备号列表，过滤非法项并限制总数量。
List<String> parseMentions(Object? value) {
  if (value is! List) return const [];
  final mentions = <String>[];
  for (final item in value) {
    if (item is! String || item.isEmpty || item.length > 128) continue;
    if (mentions.contains(item)) continue;
    mentions.add(item);
    if (mentions.length >= NetworkConfig.maxMentionCount) break;
  }
  return mentions;
}
