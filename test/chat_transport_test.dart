import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:neko_chat/core/networking/chat_transport.dart';
import 'package:neko_chat/core/protocol/protocol.dart';

void main() {
  test('WebSocket 传输保留协议消息并提供实际来源地址', () async {
    final transport = WebSocketChatTransport(port: 0);
    final received = Completer<IncomingPacket>();
    await transport.start((packet) {
      if (!received.isCompleted) received.complete(packet);
    });
    addTearDown(transport.stop);

    await transport.send(
      '127.0.0.1',
      transport.listeningPort,
      const ProtocolEnvelope(
        type: MessageType.hello,
        payload: {'deviceId': 'local-test'},
      ),
    );
    final packet = await received.future.timeout(const Duration(seconds: 3));

    expect(packet.envelope.type, MessageType.hello);
    expect(packet.envelope.payload['deviceId'], 'local-test');
    expect(packet.remoteAddress, '127.0.0.1');
  });
}
