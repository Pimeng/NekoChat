import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neko_chat/core/config/app_paths.dart';
import 'package:path/path.dart' as p;

void main() {
  Future<Directory> createTemp() =>
      Directory.systemTemp.createTemp('neko-chat-paths-');

  test('数据目录优先放在程序目录下，方便整体拷贝', () async {
    final temp = await createTemp();
    addTearDown(() => temp.delete(recursive: true));
    final fallback = Directory(p.join(temp.path, 'fallback'));
    final provider = AppDataDirectoryProvider(
      executablePath: p.join(temp.path, 'app', 'neko_chat.exe'),
      fallback: () async => fallback,
    );

    final directory = await provider.resolve();

    expect(
      directory.path,
      p.join(temp.path, 'app', AppDataDirectoryProvider.portableFolderName),
    );
    expect(await directory.exists(), isTrue);
    // 同一进程内重复调用复用同一个结果，避免数据库、密钥和附件分散到不同目录。
    expect((await provider.resolve()).path, directory.path);
    expect(await fallback.exists(), isFalse);
  });

  test('程序目录不可写时回退到系统用户目录', () async {
    final temp = await createTemp();
    addTearDown(() => temp.delete(recursive: true));
    final blocker = File(p.join(temp.path, 'blocker'));
    await blocker.writeAsString('not a directory');
    final fallback = Directory(p.join(temp.path, 'fallback'));
    final provider = AppDataDirectoryProvider(
      // 父路径是一个文件，创建子目录必然失败，模拟只读安装目录。
      executablePath: p.join(blocker.path, 'app.exe'),
      fallback: () async => fallback,
    );

    expect((await provider.resolve()).path, fallback.path);
  });

  test('程序目录为空时迁移旧的系统用户目录数据', () async {
    final temp = await createTemp();
    addTearDown(() => temp.delete(recursive: true));
    final legacy = Directory(p.join(temp.path, 'legacy'));
    await legacy.create(recursive: true);
    await File(p.join(legacy.path, 'database-key.json'))
        .writeAsString('{"version":1}');
    await File(p.join(legacy.path, 'neko_chat.db')).writeAsString('db');
    await File(p.join(legacy.path, 'neko_chat.db-wal')).writeAsString('wal');

    final provider = AppDataDirectoryProvider(
      executablePath: p.join(temp.path, 'app', 'neko_chat.exe'),
      fallback: () async => legacy,
    );

    final directory = await provider.resolve();

    expect(
      await File(p.join(directory.path, 'database-key.json')).readAsString(),
      '{"version":1}',
    );
    expect(
      await File(p.join(directory.path, 'neko_chat.db')).readAsString(),
      'db',
    );
    // 迁移只做拷贝，不改动原目录，出问题还能回退。
    expect(await File(p.join(legacy.path, 'neko_chat.db')).exists(), isTrue);
  });

  test('程序目录已有数据时不会被旧目录覆盖', () async {
    final temp = await createTemp();
    addTearDown(() => temp.delete(recursive: true));
    final legacy = Directory(p.join(temp.path, 'legacy'));
    await legacy.create(recursive: true);
    await File(p.join(legacy.path, 'database-key.json')).writeAsString('old');
    final app = Directory(p.join(temp.path, 'app'));
    final portable = Directory(
      p.join(app.path, AppDataDirectoryProvider.portableFolderName),
    );
    await portable.create(recursive: true);
    await File(p.join(portable.path, 'database-key.json')).writeAsString('new');

    final provider = AppDataDirectoryProvider(
      executablePath: p.join(app.path, 'neko_chat.exe'),
      fallback: () async => legacy,
    );

    final directory = await provider.resolve();

    expect(
      await File(p.join(directory.path, 'database-key.json')).readAsString(),
      'new',
    );
  });

  test('程序目录只有部分数据时会重新完成迁移', () async {
    final temp = await createTemp();
    addTearDown(() => temp.delete(recursive: true));
    final legacy = Directory(p.join(temp.path, 'legacy'));
    await legacy.create(recursive: true);
    await File(p.join(legacy.path, 'database-key.json')).writeAsString('key');
    await File(p.join(legacy.path, 'neko_chat.db')).writeAsString('database');

    final app = Directory(p.join(temp.path, 'app'));
    final portable = Directory(
      p.join(app.path, AppDataDirectoryProvider.portableFolderName),
    );
    await portable.create(recursive: true);
    await File(p.join(portable.path, 'database-key.json'))
        .writeAsString('partial');

    final provider = AppDataDirectoryProvider(
      executablePath: p.join(app.path, 'neko_chat.exe'),
      fallback: () async => legacy,
    );
    final directory = await provider.resolve();

    expect(directory.path, portable.path);
    expect(
      await File(p.join(portable.path, 'database-key.json')).readAsString(),
      'key',
    );
    expect(
      await File(p.join(portable.path, 'neko_chat.db')).readAsString(),
      'database',
    );
  });

  test('旧数据迁移失败时继续使用旧目录', () async {
    final temp = await createTemp();
    addTearDown(() => temp.delete(recursive: true));
    final legacy = Directory(p.join(temp.path, 'legacy'));
    await legacy.create(recursive: true);
    await File(p.join(legacy.path, 'database-key.json')).writeAsString('key');
    await File(p.join(legacy.path, 'neko_chat.db')).writeAsString('database');

    final app = Directory(p.join(temp.path, 'app'));
    final portable = Directory(
      p.join(app.path, AppDataDirectoryProvider.portableFolderName),
    );
    await portable.create(recursive: true);
    // 用同名目录阻止最终数据库文件落盘，模拟迁移中途失败。
    await Directory(p.join(portable.path, 'neko_chat.db')).create();

    final provider = AppDataDirectoryProvider(
      executablePath: p.join(app.path, 'neko_chat.exe'),
      fallback: () async => legacy,
    );

    expect((await provider.resolve()).path, legacy.path);
  });
}
