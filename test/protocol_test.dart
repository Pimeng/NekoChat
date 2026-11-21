import 'package:flutter_test/flutter_test.dart';
import 'package:neko_chat/core/protocol/protocol.dart';

void main() {
  group('ProtocolCodec', () {
    test('协议消息可往返编解码', () {
      const envelope = ProtocolEnvelope(
        type: MessageType.message,
        payload: {'sessionId': 'session-1', 'content': '你好'},
      );

      final decoded = ProtocolCodec.decode(ProtocolCodec.encode(envelope));

      expect(decoded?.type, MessageType.message);
      expect(decoded?.payload['content'], '你好');
    });

    test('未知类型会被忽略', () {
      final decoded = ProtocolCodec.decode(
        '{"protocolVersion":1,"type":"future_type","payload":{}}',
      );
      expect(decoded, isNull);
    });

    test('不兼容版本会被拒绝', () {
      expect(
        () => ProtocolCodec.decode(
          '{"protocolVersion":99,"type":"message","payload":{}}',
        ),
        throwsA(isA<ProtocolException>()),
      );
    });
  });

  group('入站字段校验', () {
    test('昵称必须非空且不超过 32 个字符', () {
      expect(isValidDisplayName('张三'), isTrue);
      expect(isValidDisplayName('  '), isFalse);
      expect(isValidDisplayName('a' * 32), isTrue);
      expect(isValidDisplayName('a' * 33), isFalse);
    });

    test('群名必须非空且不超过 40 个字符', () {
      expect(isValidGroupName('一班'), isTrue);
      expect(isValidGroupName(''), isFalse);
      expect(isValidGroupName('a' * 40), isTrue);
      expect(isValidGroupName('a' * 41), isFalse);
    });

    test('文本消息必须非空且不超过 10000 个字符', () {
      expect(isValidTextContent('你好'), isTrue);
      expect(isValidTextContent(''), isFalse);
      expect(isValidTextContent('a' * 10000), isTrue);
      expect(isValidTextContent('a' * 10001), isFalse);
    });

    test('引用摘要长度受限', () {
      expect(isValidReplyPreview(''), isTrue);
      expect(isValidReplyPreview('a' * 200), isTrue);
      expect(isValidReplyPreview('a' * 201), isFalse);
    });

    test('标识符非空且不过长', () {
      expect(isValidIdentifier('device-1'), isTrue);
      expect(isValidIdentifier(''), isFalse);
      expect(isValidIdentifier('a' * 128), isTrue);
      expect(isValidIdentifier('a' * 129), isFalse);
    });

    test('@ 提及会过滤非法项并去重', () {
      expect(parseMentions(['a', 'b', 'a', 1, '', 'c']), ['a', 'b', 'c']);
      expect(parseMentions('not-a-list'), isEmpty);
      expect(parseMentions(null), isEmpty);
    });
  });
}
