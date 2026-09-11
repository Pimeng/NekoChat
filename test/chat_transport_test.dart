import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neko_chat/core/files/content_hash.dart';
import 'package:neko_chat/core/networking/chat_transport.dart';
import 'package:neko_chat/core/protocol/protocol.dart';
import 'package:path/path.dart' as p;

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

  test('文件仅能由获准地址下载，并完整保存到接收目录', () async {
    final directory = await Directory.systemTemp.createTemp(
      'neko-chat-transfer-test-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final source = File('${directory.path}${Platform.pathSeparator}source.bin');
    final bytes = List<int>.generate(128 * 1024, (index) => index % 251);
    await source.writeAsBytes(bytes);
    final downloads = Directory(
      '${directory.path}${Platform.pathSeparator}downloads',
    );
    final transport = WebSocketChatTransport(
      port: 0,
      downloadsDirectory: () async => downloads,
    );
    await transport.start((_) {});
    addTearDown(transport.stop);

    await transport.offerFile(
      transferId: 'transfer-1',
      filePath: source.path,
      allowedAddresses: {'127.0.0.1'},
    );
    final client = HttpClient();
    final earlyRequest = await client.getUrl(
      Uri.parse('http://127.0.0.1:${transport.listeningPort}/files/transfer-1'),
    );
    final earlyResponse = await earlyRequest.close();
    await earlyResponse.drain<void>();
    client.close();
    expect(earlyResponse.statusCode, HttpStatus.notFound);

    await transport.authorizeFileDownload(
      transferId: 'transfer-1',
      remoteAddress: '127.0.0.1',
    );
    final receivedPath = await transport.downloadFile(
      ip: '127.0.0.1',
      port: transport.listeningPort,
      transferId: 'transfer-1',
      messageId: 'message-1',
      fileName: '../unsafe:name.bin',
      expectedSize: bytes.length,
    );

    expect(await File(receivedPath).readAsBytes(), bytes);
    expect(receivedPath, contains('message-1_unsafe_name.bin'));
    await expectLater(
      transport.downloadFile(
        ip: '127.0.0.1',
        port: transport.listeningPort,
        transferId: 'transfer-1',
        messageId: 'message-2',
        fileName: 'second.bin',
        expectedSize: bytes.length,
      ),
      throwsA(isA<HttpException>()),
    );
  });

  test('相同 SHA-256 的图片复用同一份本地文件', () async {
    final directory = await Directory.systemTemp.createTemp(
      'neko-chat-image-dedup-test-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final source = File('${directory.path}${Platform.pathSeparator}image.png');
    await source.writeAsBytes(List<int>.generate(4096, (index) => index % 199));
    final hash = await sha256File(source);
    final downloads = Directory(
      '${directory.path}${Platform.pathSeparator}downloads',
    );
    final transport = WebSocketChatTransport(
      port: 0,
      downloadsDirectory: () async => downloads,
    );
    await transport.start((_) {});
    addTearDown(transport.stop);
    await transport.offerFile(
      transferId: 'image-transfer-1',
      filePath: source.path,
      allowedAddresses: {'127.0.0.1'},
    );
    await transport.authorizeFileDownload(
      transferId: 'image-transfer-1',
      remoteAddress: '127.0.0.1',
    );

    final firstPath = await transport.downloadFile(
      ip: '127.0.0.1',
      port: transport.listeningPort,
      transferId: 'image-transfer-1',
      messageId: 'image-message-1',
      fileName: 'first.png',
      expectedSize: await source.length(),
      mimeType: 'image/png',
      contentHash: hash,
    );
    final reusedPath = await transport.downloadFile(
      ip: '127.0.0.1',
      port: 1,
      transferId: 'does-not-exist',
      messageId: 'image-message-2',
      fileName: 'second.png',
      expectedSize: await source.length(),
      mimeType: 'image/png',
      contentHash: hash,
    );

    expect(reusedPath, firstPath);
    expect(p.basename(firstPath), '$hash.png');
    expect(
      await Directory(
        '${downloads.path}${Platform.pathSeparator}received_images',
      ).list().where((entry) => entry is File).length,
      1,
    );
  });
}
