import 'dart:io';

import 'package:cryptography/cryptography.dart';

Future<String> sha256File(File file) async {
  final sink = Sha256().toSync().newHashSink();
  await for (final chunk in file.openRead()) {
    sink.add(chunk);
  }
  sink.close();
  final hash = sink.hashSync();
  return _toHex(hash.bytes);
}

Future<String> sha256Bytes(List<int> bytes) async {
  final hash = await Sha256().hash(bytes);
  return _toHex(hash.bytes);
}

/// 把字节序列编码成小写十六进制字符串，供上面两个摘要函数共用。
String _toHex(List<int> bytes) =>
    bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

bool isSha256Hex(String value) => RegExp(r'^[0-9a-f]{64}$').hasMatch(value);
