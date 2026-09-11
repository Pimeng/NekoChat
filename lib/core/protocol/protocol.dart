import 'dart:convert';

import '../config/network_config.dart';

enum MessageType {
  announce('announce'),
  hello('hello'),
  chatRequest('chat_request'),
  chatAccept('chat_accept'),
  chatReject('chat_reject'),
  message('message'),
  sessionClose('session_close'),
  groupInvite('group_invite'),
  groupInviteResponse('group_invite_response'),
  groupMessage('group_message'),
  groupUpdate('group_update'),
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

String verificationCode({
  required String requestId,
  required String requesterDeviceId,
  required String recipientDeviceId,
}) {
  final input = '$requestId|$requesterDeviceId|$recipientDeviceId';
  var hash = 0x811c9dc5;
  for (final byte in utf8.encode(input)) {
    hash ^= byte;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  final digits = (hash % 1000000).toString().padLeft(6, '0');
  return '${digits.substring(0, 3)} ${digits.substring(3)}';
}
