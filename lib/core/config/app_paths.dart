import 'dart:io';

import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 解析应用的数据目录。
///
/// 数据默认与可执行文件放在一起：`<程序目录>/neko_chat_data/`。这样把整个程序
/// 文件夹拷到别的电脑（或换台机器联调）时，本地身份、聊天记录和已接收的附件
/// 都会跟着一起走。如果该位置不可写，例如程序被安装到 `C:\Program Files`
/// 且当前用户没有提权，则回退到系统 Application Support 目录，保证程序仍能
/// 正常启动。
class AppDataDirectoryProvider {
  AppDataDirectoryProvider({
    Future<Directory> Function()? fallback,
    String? executablePath,
  }) : _fallback = fallback ?? getApplicationSupportDirectory,
       _executablePath = executablePath ?? Platform.resolvedExecutable;

  /// 程序目录下存放数据的文件夹名。
  ///
  /// 不能使用 `data`，那是 Flutter 存放 `flutter_assets` 的目录。
  static const String portableFolderName = 'neko_chat_data';

  /// 由旧版本（系统用户目录）一次性搬运的关键文件。
  static const List<String> legacyFileNames = [
    'database-key.json',
    'neko_chat.db',
    'neko_chat.db-wal',
    'neko_chat.db-shm',
  ];
  static const String _migrationFolderName = '.legacy_migration';

  final Future<Directory> Function() _fallback;
  final String _executablePath;
  final _log = Logger('AppPaths');
  Future<Directory>? _resolved;

  /// 返回数据目录。同一进程内只解析一次，数据库、密钥和附件因此始终位于
  /// 同一个文件夹。
  Future<Directory> resolve() => _resolved ??= _resolve();

  Future<Directory> _resolve() async {
    final portable = await _portableDirectory();
    if (portable == null) {
      final system = await _fallback();
      _log.info('数据目录：${system.path}（程序目录不可写）');
      return system;
    }
    final legacy = await _fallback();
    if (!await _migrateLegacyData(portable, legacy)) {
      _log.warning('旧数据迁移未完成，本次继续使用 ${legacy.path}');
      return legacy;
    }
    _log.info('数据目录：${portable.path}（跟随程序目录）');
    return portable;
  }

  Future<Directory?> _portableDirectory() async {
    try {
      final directory = Directory(
        p.join(p.dirname(_executablePath), portableFolderName),
      );
      await directory.create(recursive: true);
      // Directory.create() 对已存在的目录是空操作，所以写入探针文件来判断
      // 当前用户是否真的有写权限。
      final probe = File(p.join(directory.path, '.write_probe'));
      await probe.writeAsString('', flush: true);
      await probe.delete();
      return directory;
    } on Object catch (error, stack) {
      _log.warning('程序目录不可写，将数据保存到系统用户目录', error, stack);
      return null;
    }
  }

  /// 把旧版本留在系统用户目录里的数据搬到程序目录，避免升级后看起来像被清空。
  ///
  /// 文件先复制到暂存目录，全部完成后才覆盖目标。若中途失败则保留暂存目录供
  /// 下次重试，并让本次启动继续使用旧目录，避免打开一个不完整的新数据库。
  Future<bool> _migrateLegacyData(Directory portable, Directory legacy) async {
    if (p.equals(legacy.path, portable.path)) return true;
    final keyName = legacyFileNames.first;
    const databaseName = 'neko_chat.db';
    final legacyKey = File(p.join(legacy.path, keyName));
    final legacyDatabase = File(p.join(legacy.path, databaseName));
    if (!await legacyKey.exists() || !await legacyDatabase.exists()) {
      return true;
    }

    final staging = Directory(p.join(portable.path, _migrationFolderName));
    final portableComplete =
        await File(p.join(portable.path, keyName)).exists() &&
        await File(p.join(portable.path, databaseName)).exists();
    if (portableComplete && !await staging.exists()) return true;

    try {
      await staging.create(recursive: true);
      var copied = 0;
      for (final name in legacyFileNames) {
        final source = File(p.join(legacy.path, name));
        if (!await source.exists()) continue;
        await source.copy(p.join(staging.path, name));
        copied++;
      }
      if (!await File(p.join(staging.path, keyName)).exists() ||
          !await File(p.join(staging.path, databaseName)).exists()) {
        throw const FileSystemException('暂存的旧数据不完整');
      }
      for (final name in legacyFileNames) {
        final staged = File(p.join(staging.path, name));
        if (!await staged.exists()) continue;
        await staged.copy(p.join(portable.path, name));
      }
      for (final entity in staging.listSync()) {
        if (entity is File) await entity.delete();
      }
      await staging.delete();
      _log.info('已从 ${legacy.path} 迁移 $copied 个数据文件到 ${portable.path}');
      return true;
    } on Object catch (error, stack) {
      _log.warning('迁移旧数据失败，将继续使用旧数据目录', error, stack);
      return false;
    }
  }
}

final _defaultProvider = AppDataDirectoryProvider();

/// 应用默认数据目录。数据库、解锁密钥和附件都通过它解析，保证三者始终在
/// 同一个文件夹里，整体拷贝即可带走。
Future<Directory> appDataDirectory() => _defaultProvider.resolve();
