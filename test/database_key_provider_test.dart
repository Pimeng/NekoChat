import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neko_chat/core/identity/database_key_provider.dart';

void main() {
  test('数据库随机密钥可用正确密码恢复，错误密码被拒绝', () async {
    final directory = await Directory.systemTemp.createTemp(
      'neko-chat-key-test-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final provider = EncryptedFileDatabaseKeyProvider(
      directory: () async => directory,
    );

    final created = await provider.create('correct-password');
    final unlocked = await provider.unlock('correct-password');

    expect(created, hasLength(32));
    expect(unlocked, created);
    expect(
      () => provider.unlock('wrong-password'),
      throwsA(isA<InvalidPasswordException>()),
    );
  });
}
