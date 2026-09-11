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

  group('verificationCode', () {
    test('同一请求在双方得到相同的六位码', () {
      final atRequester = verificationCode(
        requestId: 'request-1',
        requesterDeviceId: 'device-a',
        recipientDeviceId: 'device-b',
      );
      final atRecipient = verificationCode(
        requestId: 'request-1',
        requesterDeviceId: 'device-a',
        recipientDeviceId: 'device-b',
      );

      expect(atRequester, atRecipient);
      expect(atRequester, matches(RegExp(r'^\d{3} \d{3}$')));
    });

    test('不同请求通常得到不同验证码', () {
      final first = verificationCode(
        requestId: 'request-1',
        requesterDeviceId: 'device-a',
        recipientDeviceId: 'device-b',
      );
      final second = verificationCode(
        requestId: 'request-2',
        requesterDeviceId: 'device-a',
        recipientDeviceId: 'device-b',
      );
      expect(first, isNot(second));
    });
  });
}
