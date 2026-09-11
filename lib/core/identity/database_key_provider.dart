import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class InvalidPasswordException implements Exception {
  const InvalidPasswordException();
}

abstract interface class LocalDatabaseKeyProvider {
  Future<bool> hasExistingKey();
  Future<List<int>> create(String password);
  Future<List<int>> unlock(String password);
}

class EncryptedFileDatabaseKeyProvider implements LocalDatabaseKeyProvider {
  EncryptedFileDatabaseKeyProvider({Future<Directory> Function()? directory})
    : _directory = directory ?? getApplicationSupportDirectory;
  static const _iterations = 210000;
  final Future<Directory> Function() _directory;
  final _cipher = AesGcm.with256bits();
  final _kdf = Pbkdf2(
    macAlgorithm: Hmac.sha256(),
    iterations: _iterations,
    bits: 256,
  );

  Future<File> get _file async {
    final directory = await _directory();
    await directory.create(recursive: true);
    return File(p.join(directory.path, 'database-key.json'));
  }

  @override
  Future<bool> hasExistingKey() async => (await _file).exists();

  @override
  Future<List<int>> create(String password) async {
    if (password.length < 4) throw ArgumentError('密码至少需要 4 个字符');
    final file = await _file;
    if (await file.exists()) throw StateError('本地密钥已经存在');
    final random = Random.secure();
    final salt = List<int>.generate(16, (_) => random.nextInt(256));
    final nonce = List<int>.generate(12, (_) => random.nextInt(256));
    final databaseKey = List<int>.generate(32, (_) => random.nextInt(256));
    final kek = await _kdf.deriveKeyFromPassword(
      password: password,
      nonce: salt,
    );
    final box = await _cipher.encrypt(
      databaseKey,
      secretKey: kek,
      nonce: nonce,
    );
    await file.writeAsString(
      jsonEncode({
        'version': 1,
        'kdf': 'PBKDF2-HMAC-SHA256',
        'iterations': _iterations,
        'salt': base64Encode(salt),
        'nonce': base64Encode(nonce),
        'cipherText': base64Encode(box.cipherText),
        'mac': base64Encode(box.mac.bytes),
      }),
      flush: true,
    );
    return databaseKey;
  }

  @override
  Future<List<int>> unlock(String password) async {
    final file = await _file;
    if (!await file.exists()) throw StateError('本地密钥不存在');
    final data = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    try {
      final salt = base64Decode(data['salt'] as String);
      final nonce = base64Decode(data['nonce'] as String);
      final kek = await _kdf.deriveKeyFromPassword(
        password: password,
        nonce: salt,
      );
      return await _cipher.decrypt(
        SecretBox(
          base64Decode(data['cipherText'] as String),
          nonce: nonce,
          mac: Mac(base64Decode(data['mac'] as String)),
        ),
        secretKey: kek,
      );
    } on SecretBoxAuthenticationError {
      throw const InvalidPasswordException();
    } on FormatException {
      throw const InvalidPasswordException();
    }
  }
}
