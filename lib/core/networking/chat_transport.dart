import 'dart:async';
import 'dart:io';

import 'package:logging/logging.dart';

import '../config/network_config.dart';
import '../protocol/protocol.dart';

class IncomingPacket {
  const IncomingPacket({required this.envelope, required this.remoteAddress});
  final ProtocolEnvelope envelope;
  final String remoteAddress;
}

abstract interface class ChatTransport {
  Future<void> start(void Function(IncomingPacket packet) onPacket);
  Future<void> send(String ip, int port, ProtocolEnvelope envelope);
  Future<void> stop();
}

class WebSocketChatTransport implements ChatTransport {
  WebSocketChatTransport({this.port = NetworkConfig.chatPort});

  final int port;
  final _log = Logger('WebSocketChatTransport');
  HttpServer? _server;
  void Function(IncomingPacket packet)? _onPacket;

  int get listeningPort => _server?.port ?? port;

  @override
  Future<void> start(void Function(IncomingPacket packet) onPacket) async {
    if (_server != null) return;
    _onPacket = onPacket;
    final server = await HttpServer.bind(
      InternetAddress.anyIPv4,
      port,
      shared: true,
    );
    _server = server;
    server.listen(
      _handleRequest,
      onError: (Object error, StackTrace stack) {
        _log.severe('聊天服务异常', error, stack);
      },
    );
    _log.info('WebSocket 聊天服务监听 ${server.port}');
  }

  Future<void> _handleRequest(HttpRequest request) async {
    if (request.uri.path != '/ws' ||
        !WebSocketTransformer.isUpgradeRequest(request)) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }
    final remoteAddress =
        request.connectionInfo?.remoteAddress.address ?? 'unknown';
    try {
      final socket = await WebSocketTransformer.upgrade(request);
      socket.listen(
        (dynamic data) {
          if (data is! String) return;
          try {
            final envelope = ProtocolCodec.decode(data);
            if (envelope != null) {
              _onPacket?.call(
                IncomingPacket(
                  envelope: envelope,
                  remoteAddress: remoteAddress,
                ),
              );
            }
          } on ProtocolException catch (error) {
            _log.warning('拒绝来自 $remoteAddress 的协议消息', error);
            socket.add(
              ProtocolCodec.encode(
                ProtocolEnvelope(
                  type: MessageType.error,
                  payload: {'reason': error.message},
                ),
              ),
            );
          } on Object catch (error, stack) {
            _log.warning('忽略来自 $remoteAddress 的无效消息', error, stack);
          }
        },
        onError: (Object error, StackTrace stack) {
          _log.warning('来自 $remoteAddress 的连接异常', error, stack);
        },
      );
    } on Object catch (error, stack) {
      _log.warning('WebSocket 升级失败', error, stack);
    }
  }

  @override
  Future<void> send(String ip, int port, ProtocolEnvelope envelope) async {
    final socket = await WebSocket.connect('ws://$ip:$port/ws')
        .timeout(NetworkConfig.requestTimeout);
    try {
      socket.add(ProtocolCodec.encode(envelope));
      await socket.close(WebSocketStatus.normalClosure);
      _log.fine('已发送 ${envelope.type.wireName} 到 $ip:$port');
    } finally {
      if (socket.readyState == WebSocket.open) await socket.close();
    }
  }

  @override
  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
    _onPacket = null;
  }
}
