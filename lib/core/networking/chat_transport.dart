import 'dart:async';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

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
  Future<void> offerFile({
    required String transferId,
    required String filePath,
    required Set<String> allowedAddresses,
  });
  Future<void> authorizeFileDownload({
    required String transferId,
    required String remoteAddress,
  });
  Future<String> downloadFile({
    required String ip,
    required int port,
    required String transferId,
    required String messageId,
    required String fileName,
    required int expectedSize,
  });
  Future<void> stop();
}

class _FileOffer {
  _FileOffer({
    required this.file,
    required this.eligibleAddresses,
    required this.expiresAt,
  });
  final File file;
  final Set<String> eligibleAddresses;
  final Set<String> authorizedAddresses = {};
  final DateTime expiresAt;
}

class WebSocketChatTransport implements ChatTransport {
  WebSocketChatTransport({
    this.port = NetworkConfig.chatPort,
    Future<Directory> Function()? downloadsDirectory,
  }) : _downloadsDirectory =
           downloadsDirectory ?? getApplicationSupportDirectory;

  final int port;
  final Future<Directory> Function() _downloadsDirectory;
  final _log = Logger('WebSocketChatTransport');
  final Map<String, _FileOffer> _fileOffers = {};
  HttpServer? _server;
  Timer? _offerCleanupTimer;
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
    _offerCleanupTimer = Timer.periodic(
      const Duration(minutes: 1),
      (_) => _removeExpiredOffers(),
    );
    server.listen(
      _handleRequest,
      onError: (Object error, StackTrace stack) {
        _log.severe('聊天服务异常', error, stack);
      },
    );
    _log.info('WebSocket 聊天服务监听 ${server.port}');
  }

  Future<void> _handleRequest(HttpRequest request) async {
    if (request.uri.pathSegments.length == 2 &&
        request.uri.pathSegments.first == 'files') {
      await _handleFileRequest(request, request.uri.pathSegments.last);
      return;
    }
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

  Future<void> _handleFileRequest(
    HttpRequest request,
    String transferId,
  ) async {
    if (request.method != 'GET') {
      request.response.statusCode = HttpStatus.methodNotAllowed;
      await request.response.close();
      return;
    }
    final remoteAddress = request.connectionInfo?.remoteAddress.address;
    final offer = _fileOffers[transferId];
    if (remoteAddress == null ||
        offer == null ||
        DateTime.now().isAfter(offer.expiresAt) ||
        !offer.authorizedAddresses.contains(remoteAddress) ||
        !await offer.file.exists()) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }
    try {
      final length = await offer.file.length();
      request.response.contentLength = length;
      final mimeType = lookupMimeType(offer.file.path);
      if (mimeType != null) {
        request.response.headers.contentType = ContentType.parse(mimeType);
      }
      await request.response.addStream(offer.file.openRead());
      await request.response.close();
      offer.authorizedAddresses.remove(remoteAddress);
      offer.eligibleAddresses.remove(remoteAddress);
      if (offer.eligibleAddresses.isEmpty) _fileOffers.remove(transferId);
      _log.info('文件 $transferId 已传输给 $remoteAddress');
    } on Object catch (error, stack) {
      _log.warning('向 $remoteAddress 传输文件失败', error, stack);
      request.response.statusCode = HttpStatus.internalServerError;
      await request.response.close();
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
  Future<void> offerFile({
    required String transferId,
    required String filePath,
    required Set<String> allowedAddresses,
  }) async {
    final file = File(filePath);
    if (!await file.exists()) throw StateError('文件不存在：$filePath');
    final size = await file.length();
    if (size > NetworkConfig.maxFileSizeBytes) {
      throw StateError('文件超过 512 MB 限制');
    }
    _fileOffers[transferId] = _FileOffer(
      file: file,
      eligibleAddresses: {...allowedAddresses},
      expiresAt: DateTime.now().add(NetworkConfig.fileOfferLifetime),
    );
    _log.info('已注册文件传输 $transferId，允许 ${allowedAddresses.length} 个地址');
  }

  @override
  Future<void> authorizeFileDownload({
    required String transferId,
    required String remoteAddress,
  }) async {
    final offer = _fileOffers[transferId];
    if (offer == null || DateTime.now().isAfter(offer.expiresAt)) {
      throw StateError('文件邀请不存在或已过期');
    }
    if (!offer.eligibleAddresses.contains(remoteAddress)) {
      throw StateError('该地址不在文件接收名单中');
    }
    offer.authorizedAddresses.add(remoteAddress);
    _log.info('已允许 $remoteAddress 下载文件 $transferId');
  }

  @override
  Future<String> downloadFile({
    required String ip,
    required int port,
    required String transferId,
    required String messageId,
    required String fileName,
    required int expectedSize,
  }) async {
    if (expectedSize < 0 || expectedSize > NetworkConfig.maxFileSizeBytes) {
      throw StateError('文件大小无效');
    }
    final baseDirectory = await _downloadsDirectory();
    final directory = Directory(p.join(baseDirectory.path, 'received_files'));
    await directory.create(recursive: true);
    final safeName = _safeFileName(fileName);
    final destination = File(p.join(directory.path, '${messageId}_$safeName'));
    final partial = File('${destination.path}.part');
    final client = HttpClient();
    try {
      final response = await _openFileResponse(
        client,
        Uri(scheme: 'http', host: ip, port: port, path: '/files/$transferId'),
      );
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        throw HttpException('文件下载失败：HTTP ${response.statusCode}');
      }
      if (response.contentLength > NetworkConfig.maxFileSizeBytes ||
          (response.contentLength >= 0 &&
              response.contentLength != expectedSize)) {
        await response.drain<void>();
        throw const HttpException('文件长度与声明不一致');
      }
      final sink = partial.openWrite();
      await response.pipe(sink);
      final actualSize = await partial.length();
      if (actualSize != expectedSize) {
        throw const HttpException('文件接收不完整');
      }
      if (await destination.exists()) await destination.delete();
      await partial.rename(destination.path);
      _log.info('文件 $transferId 已保存到 ${destination.path}');
      return destination.path;
    } finally {
      client.close(force: true);
      if (await partial.exists()) await partial.delete();
    }
  }

  Future<HttpClientResponse> _openFileResponse(
    HttpClient client,
    Uri uri,
  ) async {
    for (var attempt = 0; attempt < 10; attempt++) {
      final request = await client.getUrl(uri);
      final response = await request.close().timeout(
        NetworkConfig.requestTimeout,
      );
      if (response.statusCode != HttpStatus.notFound || attempt == 9) {
        return response;
      }
      await response.drain<void>();
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    throw const HttpException('文件下载授权超时');
  }

  String _safeFileName(String value) {
    final baseName = p
        .basename(value)
        .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_');
    return baseName.isEmpty ? 'file' : baseName;
  }

  void _removeExpiredOffers() {
    final now = DateTime.now();
    _fileOffers.removeWhere((_, offer) => now.isAfter(offer.expiresAt));
  }

  @override
  Future<void> stop() async {
    _offerCleanupTimer?.cancel();
    _offerCleanupTimer = null;
    _fileOffers.clear();
    await _server?.close(force: true);
    _server = null;
    _onPacket = null;
  }
}
