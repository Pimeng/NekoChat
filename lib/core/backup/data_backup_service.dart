import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:path/path.dart' as p;

import '../files/content_hash.dart';

/// 备份文件扩展名（不含点号）。
const String backupFileExtension = 'nekobackup';

/// 备份与还原过程中的用户可读异常。
class BackupException implements Exception {
  const BackupException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 备份归档中的单个文件条目元数据。
class BackupEntry {
  const BackupEntry({
    required this.path,
    required this.size,
    required this.storedSize,
    required this.compressed,
    required this.sha256,
  });

  /// 相对于数据目录的路径，统一使用 `/` 分隔。
  final String path;

  /// 原始文件大小（字节）。
  final int size;

  /// 在备份归档中实际占用的大小（字节）。
  final int storedSize;

  /// 是否使用 GZip 压缩存储。
  final bool compressed;

  /// 原始文件内容的 SHA-256（小写十六进制）。
  final String sha256;

  Map<String, Object?> toJson() => {
    'path': path,
    'size': size,
    'storedSize': storedSize,
    'compressed': compressed,
    'sha256': sha256,
  };

  factory BackupEntry.fromJson(Map<String, dynamic> json) {
    final path = json['path'];
    final size = json['size'];
    final storedSize = json['storedSize'];
    final compressed = json['compressed'];
    final sha256 = json['sha256'];
    if (path is! String ||
        size is! int ||
        storedSize is! int ||
        compressed is! bool ||
        sha256 is! String ||
        size < 0 ||
        storedSize < 0 ||
        !isSha256Hex(sha256)) {
      throw const BackupException('备份清单中的文件条目格式无效');
    }
    return BackupEntry(
      path: path,
      size: size,
      storedSize: storedSize,
      compressed: compressed,
      sha256: sha256,
    );
  }
}

/// 备份归档头部清单，供还原前展示摘要与完整性校验。
class BackupManifest {
  const BackupManifest({
    required this.formatVersion,
    required this.createdAt,
    required this.includesAttachments,
    required this.stickerCount,
    required this.fileCount,
    required this.totalBytes,
    required this.entries,
    this.appVersion,
    this.displayName,
  });

  final int formatVersion;
  final DateTime createdAt;
  final String? appVersion;
  final String? displayName;
  final bool includesAttachments;
  final int stickerCount;
  final int fileCount;
  final int totalBytes;
  final List<BackupEntry> entries;

  Map<String, Object?> toJson() => {
    'formatVersion': formatVersion,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'appVersion': appVersion,
    'displayName': displayName,
    'includesAttachments': includesAttachments,
    'stickerCount': stickerCount,
    'fileCount': fileCount,
    'totalBytes': totalBytes,
    'entries': [for (final entry in entries) entry.toJson()],
  };

  factory BackupManifest.fromJson(Map<String, dynamic> json) {
    final formatVersion = json['formatVersion'];
    final createdAtRaw = json['createdAt'];
    final includesAttachments = json['includesAttachments'];
    final stickerCount = json['stickerCount'];
    final fileCount = json['fileCount'];
    final totalBytes = json['totalBytes'];
    final entriesRaw = json['entries'];
    if (formatVersion is! int ||
        createdAtRaw is! String ||
        includesAttachments is! bool ||
        stickerCount is! int ||
        fileCount is! int ||
        totalBytes is! int ||
        entriesRaw is! List) {
      throw const BackupException('备份清单格式无效或已损坏');
    }
    final createdAt = DateTime.tryParse(createdAtRaw);
    if (createdAt == null) {
      throw const BackupException('备份清单中的创建时间无效');
    }
    final entries = <BackupEntry>[];
    for (final item in entriesRaw) {
      if (item is! Map) {
        throw const BackupException('备份清单中的条目格式无效');
      }
      entries.add(BackupEntry.fromJson(Map<String, dynamic>.from(item)));
    }
    return BackupManifest(
      formatVersion: formatVersion,
      createdAt: createdAt.toLocal(),
      appVersion: json['appVersion'] as String?,
      displayName: json['displayName'] as String?,
      includesAttachments: includesAttachments,
      stickerCount: stickerCount,
      fileCount: fileCount,
      totalBytes: totalBytes,
      entries: entries,
    );
  }
}

/// 本地数据备份与还原服务。
///
/// 采用流式单文件归档格式（`.nekobackup`）：
/// - 8 字节魔数与版本号：`NEKOBKP\x01`
/// - 4 字节大端无符号整数：UTF-8 JSON 清单长度
/// - UTF-8 JSON 清单（含创建时间、表情包数量、所有文件条目及 SHA-256）
/// - 依次拼接的各条目字节流（数据库与密钥经 GZip 压缩，表情包等图片直接存储）
///
/// 还原时先在暂存目录完整解压并逐文件校验 SHA-256，确认无误后再关闭数据库
/// 做原子替换，失败自动回滚，避免损坏的备份破坏现有本地数据。
class DataBackupService {
  const DataBackupService();

  static const int currentFormatVersion = 1;
  static const List<int> _magicBytes = [
    0x4E, // N
    0x45, // E
    0x4B, // K
    0x4F, // O
    0x42, // B
    0x4B, // K
    0x50, // P
    currentFormatVersion,
  ];
  static const int _headerLength = 8 + 4;
  static const int _maxManifestBytes = 16 * 1024 * 1024;
  static const int _chunkSize = 64 * 1024;

  static const String _keyFileName = 'database-key.json';
  static const String _databaseFileName = 'neko_chat.db';

  static const List<String> _alwaysIncludedDirs = [
    'stickers',
    'profile',
    'avatars',
  ];
  static const List<String> _attachmentDirs = [
    'received_images',
    'received_files',
  ];
  static const List<String> _managedRootEntries = [
    _keyFileName,
    _databaseFileName,
    'neko_chat.db-wal',
    'neko_chat.db-shm',
    ..._alwaysIncludedDirs,
    ..._attachmentDirs,
  ];

  /// 生成默认的备份文件名，例如 `NekoChat_Backup_20261125_233506.nekobackup`。
  static String suggestedFileName({DateTime? now}) {
    final t = now ?? DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    final stamp =
        '${t.year}${two(t.month)}${two(t.day)}_${two(t.hour)}${two(t.minute)}${two(t.second)}';
    return 'NekoChat_Backup_$stamp.$backupFileExtension';
  }

  /// 创建完整数据备份（包含身份密钥、数据库快照、全部收藏表情包、头像及可选附件）。
  Future<BackupManifest> createBackup({
    required Directory dataDirectory,
    required File destinationFile,
    required Future<void> Function(String snapshotPath) exportDatabaseSnapshot,
    bool includeAttachments = true,
    String? displayName,
    String? appVersion,
    int? stickerCount,
  }) async {
    final keyFile = File(p.join(dataDirectory.path, _keyFileName));
    if (!await keyFile.exists()) {
      throw const BackupException('未找到本地密钥文件，无法创建备份');
    }

    final stagingDir = Directory(
      p.join(
        dataDirectory.path,
        '.backup_staging_${DateTime.now().microsecondsSinceEpoch}',
      ),
    );
    await stagingDir.create(recursive: true);

    final partialDestination = File('${destinationFile.path}.part');

    try {
      // 1. 导出一致性 SQLite 快照，避免直接复制处于活动状态的数据库/WAL 文件。
      final snapshotDbFile = File(p.join(stagingDir.path, _databaseFileName));
      await exportDatabaseSnapshot(snapshotDbFile.path);
      if (!await snapshotDbFile.exists()) {
        throw const BackupException('导出数据库快照失败');
      }

      // 2. 收集待备份的文件。
      final sources = <({String relativePath, File file})>[
        (relativePath: _keyFileName, file: keyFile),
        (relativePath: _databaseFileName, file: snapshotDbFile),
      ];

      final dirsToScan = <String>[
        ..._alwaysIncludedDirs,
        if (includeAttachments) ..._attachmentDirs,
      ];
      var scannedStickerFiles = 0;
      for (final dirName in dirsToScan) {
        final dir = Directory(p.join(dataDirectory.path, dirName));
        if (!await dir.exists()) continue;
        final files = await _collectFiles(dir, dirName);
        if (dirName == 'stickers') {
          scannedStickerFiles = files.length;
        }
        sources.addAll(files);
      }

      // 3. 逐个准备条目（计算 SHA-256，并对数据库/JSON 做 GZip 压缩）。
      final prepared = <({BackupEntry entry, File payloadFile})>[];
      var totalBytes = 0;
      for (var i = 0; i < sources.length; i++) {
        final source = sources[i];
        final size = await source.file.length();
        final hash = await sha256File(source.file);
        totalBytes += size;

        final shouldCompress = _shouldCompress(source.relativePath);
        File payloadFile = source.file;
        int storedSize = size;
        if (shouldCompress) {
          payloadFile = File(p.join(stagingDir.path, 'entry_$i.gz'));
          await _gzipFile(source.file, payloadFile);
          storedSize = await payloadFile.length();
        }

        prepared.add((
          entry: BackupEntry(
            path: source.relativePath,
            size: size,
            storedSize: storedSize,
            compressed: shouldCompress,
            sha256: hash,
          ),
          payloadFile: payloadFile,
        ));
      }

      final manifest = BackupManifest(
        formatVersion: currentFormatVersion,
        createdAt: DateTime.now(),
        appVersion: appVersion,
        displayName: displayName,
        includesAttachments: includeAttachments,
        stickerCount: stickerCount ?? scannedStickerFiles,
        fileCount: prepared.length,
        totalBytes: totalBytes,
        entries: [for (final item in prepared) item.entry],
      );

      // 4. 流式写入临时目标文件，完成后原子替换。
      await destinationFile.parent.create(recursive: true);
      if (await partialDestination.exists()) {
        await partialDestination.delete();
      }
      final manifestBytes = utf8.encode(jsonEncode(manifest.toJson()));
      final lengthHeader = ByteData(4)
        ..setUint32(0, manifestBytes.length, Endian.big);

      final sink = partialDestination.openWrite();
      try {
        sink.add(_magicBytes);
        sink.add(lengthHeader.buffer.asUint8List());
        sink.add(manifestBytes);
        for (final item in prepared) {
          await sink.addStream(item.payloadFile.openRead());
        }
        await sink.flush();
      } finally {
        await sink.close();
      }

      if (await destinationFile.exists()) {
        await destinationFile.delete();
      }
      await partialDestination.rename(destinationFile.path);
      return manifest;
    } on BackupException {
      await _deleteIfExists(partialDestination);
      rethrow;
    } on Object catch (error) {
      await _deleteIfExists(partialDestination);
      throw BackupException('创建备份失败：$error');
    } finally {
      await _deleteDirectoryIfExists(stagingDir);
    }
  }

  /// 读取并校验备份清单（不解压正文），供还原前确认展示。
  Future<BackupManifest> inspectBackup(File sourceFile) async {
    if (!await sourceFile.exists()) {
      throw const BackupException('所选备份文件不存在');
    }
    final totalLength = await sourceFile.length();
    if (totalLength < _headerLength) {
      throw const BackupException('不是有效的 NekoChat 备份文件');
    }

    final raf = await sourceFile.open(mode: FileMode.read);
    try {
      final header = await _readExact(raf, _headerLength);
      for (var i = 0; i < 7; i++) {
        if (header[i] != _magicBytes[i]) {
          throw const BackupException('不是有效的 NekoChat 备份文件');
        }
      }
      final headerVersion = header[7];
      if (headerVersion != currentFormatVersion) {
        throw BackupException('不支持的备份格式版本（v$headerVersion），请升级应用后再试');
      }

      final manifestLength = ByteData.sublistView(
        header,
        8,
        12,
      ).getUint32(0, Endian.big);
      if (manifestLength == 0 ||
          manifestLength > _maxManifestBytes ||
          _headerLength + manifestLength > totalLength) {
        throw const BackupException('备份文件头损坏或已被截断');
      }

      final manifestBytes = await _readExact(raf, manifestLength);
      final decoded = _decodeManifestJson(manifestBytes);
      final manifest = BackupManifest.fromJson(decoded);
      _validateManifest(
        manifest,
        totalFileLength: totalLength,
        manifestLength: manifestLength,
      );
      return manifest;
    } finally {
      await raf.close();
    }
  }

  /// 从备份文件还原到本地数据目录。
  ///
  /// 1. 先完整解压并校验所有文件的 SHA-256 到暂存目录；
  /// 2. 确认无损后再回调 [beforeSwap] 停止网络并关闭当前数据库；
  /// 3. 安全替换数据目录内容，若替换出错则自动回滚原有数据。
  Future<BackupManifest> restoreBackup({
    required File sourceFile,
    required Directory dataDirectory,
    required Future<void> Function() beforeSwap,
  }) async {
    final manifest = await inspectBackup(sourceFile);
    await dataDirectory.create(recursive: true);

    final stamp = DateTime.now().microsecondsSinceEpoch;
    final stagingDir = Directory(
      p.join(dataDirectory.path, '.restore_staging_$stamp'),
    );
    final oldDir = Directory(p.join(dataDirectory.path, '.restore_old_$stamp'));

    await stagingDir.create(recursive: true);

    try {
      // 1. 流式解压并逐文件校验 SHA-256。
      final raf = await sourceFile.open(mode: FileMode.read);
      try {
        final header = await _readExact(raf, _headerLength);
        final manifestLength = ByteData.sublistView(
          header,
          8,
          12,
        ).getUint32(0, Endian.big);
        await raf.setPosition(_headerLength + manifestLength);

        for (final entry in manifest.entries) {
          final targetPath = _resolveSafePath(stagingDir.path, entry.path);
          final targetFile = File(targetPath);
          await targetFile.parent.create(recursive: true);
          await _extractAndVerifyEntry(raf, entry, targetFile);
        }
      } finally {
        await raf.close();
      }

      // 2. 所有备份内容已校验完整，通知上层关闭数据库与服务。
      await beforeSwap();

      // 3. 将当前受管文件移至备份旧目录，再将新数据移入正式位置；出错自动回滚。
      await oldDir.create(recursive: true);
      final movedOldNames = <String>[];
      final movedNewNames = <String>[];

      try {
        for (final name in _managedRootEntries) {
          final currentPath = p.join(dataDirectory.path, name);
          final type = await FileSystemEntity.type(
            currentPath,
            followLinks: false,
          );
          if (type == FileSystemEntityType.notFound) continue;
          final backupPath = p.join(oldDir.path, name);
          await _moveEntity(currentPath, backupPath, type);
          movedOldNames.add(name);
        }

        await for (final entity in stagingDir.list(followLinks: false)) {
          final name = p.basename(entity.path);
          final destPath = p.join(dataDirectory.path, name);
          final type = await FileSystemEntity.type(
            entity.path,
            followLinks: false,
          );
          await _moveEntity(entity.path, destPath, type);
          movedNewNames.add(name);
        }
      } on Object catch (error) {
        // 回滚：清除已移入的新条目，并把旧数据移回原位。
        for (final name in movedNewNames) {
          await _deleteEntityIfExists(p.join(dataDirectory.path, name));
        }
        for (final name in movedOldNames) {
          final oldPath = p.join(oldDir.path, name);
          final type = await FileSystemEntity.type(oldPath, followLinks: false);
          if (type != FileSystemEntityType.notFound) {
            await _moveEntity(oldPath, p.join(dataDirectory.path, name), type);
          }
        }
        throw BackupException('替换本地数据时出错，已自动保留原数据：$error');
      }

      await _deleteDirectoryIfExists(oldDir);
      await _deleteDirectoryIfExists(stagingDir);
      return manifest;
    } on BackupException {
      await _deleteDirectoryIfExists(stagingDir);
      await _deleteDirectoryIfExists(oldDir);
      rethrow;
    } on Object catch (error) {
      await _deleteDirectoryIfExists(stagingDir);
      await _deleteDirectoryIfExists(oldDir);
      throw BackupException('还原备份失败：$error');
    }
  }

  Future<List<({String relativePath, File file})>> _collectFiles(
    Directory dir,
    String prefix,
  ) async {
    final result = <({String relativePath, File file})>[];
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final name = p.basename(entity.path);
      if (name.startsWith('.') || name.endsWith('.part')) continue;
      final rel = p.relative(entity.path, from: dir.path);
      final normalized = [prefix, ...p.split(rel)].join('/');
      result.add((relativePath: normalized, file: entity));
    }
    result.sort((a, b) => a.relativePath.compareTo(b.relativePath));
    return result;
  }

  static bool _shouldCompress(String relativePath) {
    final lower = relativePath.toLowerCase();
    return lower.endsWith('.db') || lower.endsWith('.json');
  }

  static Future<void> _gzipFile(File source, File destination) async {
    final sink = destination.openWrite();
    try {
      await sink.addStream(source.openRead().transform(gzip.encoder));
      await sink.flush();
    } finally {
      await sink.close();
    }
  }

  static Future<Uint8List> _readExact(RandomAccessFile raf, int count) async {
    final bytes = await raf.read(count);
    if (bytes.length != count) {
      throw const BackupException('备份文件不完整或已被截断');
    }
    return bytes;
  }

  static Map<String, dynamic> _decodeManifestJson(Uint8List bytes) {
    try {
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map<String, dynamic>) {
        throw const BackupException('备份清单内容不是有效的 JSON 对象');
      }
      return decoded;
    } on BackupException {
      rethrow;
    } on Object {
      throw const BackupException('无法解析备份清单，文件可能已损坏');
    }
  }

  static void _validateManifest(
    BackupManifest manifest, {
    required int totalFileLength,
    required int manifestLength,
  }) {
    if (manifest.formatVersion != currentFormatVersion) {
      throw BackupException('不支持的备份格式版本（v${manifest.formatVersion}）');
    }
    if (manifest.entries.isEmpty) {
      throw const BackupException('备份文件中没有任何数据');
    }

    final seenPaths = <String>{};
    var expectedBodyBytes = 0;
    for (final entry in manifest.entries) {
      _assertSafeRelativePath(entry.path);
      if (!seenPaths.add(entry.path)) {
        throw BackupException('备份清单包含重复路径：${entry.path}');
      }
      expectedBodyBytes += entry.storedSize;
    }

    if (!seenPaths.contains(_keyFileName) ||
        !seenPaths.contains(_databaseFileName)) {
      throw const BackupException('备份文件缺少核心身份密钥或数据库');
    }

    final expectedTotal = _headerLength + manifestLength + expectedBodyBytes;
    if (totalFileLength != expectedTotal) {
      throw const BackupException('备份文件长度不匹配，可能已损坏或未完整下载');
    }
  }

  static void _assertSafeRelativePath(String relativePath) {
    if (relativePath.isEmpty ||
        relativePath.startsWith('/') ||
        relativePath.startsWith('\\') ||
        relativePath.contains('\\') ||
        relativePath.contains(':')) {
      throw BackupException('备份清单包含非法路径：$relativePath');
    }
    final segments = relativePath.split('/');
    for (final segment in segments) {
      if (segment.isEmpty || segment == '.' || segment == '..') {
        throw BackupException('备份清单包含非法路径：$relativePath');
      }
    }
    final root = segments.first;
    final allowedRoot =
        root == _keyFileName ||
        root == _databaseFileName ||
        _alwaysIncludedDirs.contains(root) ||
        _attachmentDirs.contains(root);
    if (!allowedRoot) {
      throw BackupException('备份清单包含不受支持的路径：$relativePath');
    }
  }

  static String _resolveSafePath(String rootDir, String relativePath) {
    _assertSafeRelativePath(relativePath);
    final root = p.normalize(p.absolute(rootDir));
    final resolved = p.normalize(p.joinAll([root, ...relativePath.split('/')]));
    if (!p.isWithin(root, resolved)) {
      throw BackupException('备份路径越界：$relativePath');
    }
    return resolved;
  }

  static Future<void> _extractAndVerifyEntry(
    RandomAccessFile raf,
    BackupEntry entry,
    File targetFile,
  ) async {
    final hashSink = Sha256().toSync().newHashSink();
    var writtenBytes = 0;
    final output = targetFile.openWrite();

    try {
      if (!entry.compressed) {
        var remaining = entry.storedSize;
        while (remaining > 0) {
          final toRead = remaining > _chunkSize ? _chunkSize : remaining;
          final chunk = await _readExact(raf, toRead);
          output.add(chunk);
          hashSink.add(chunk);
          writtenBytes += chunk.length;
          remaining -= chunk.length;
        }
      } else {
        final controller = StreamController<List<int>>();
        final done = output.addStream(
          controller.stream.transform(gzip.decoder).map((chunk) {
            hashSink.add(chunk);
            writtenBytes += chunk.length;
            return chunk;
          }),
        );
        try {
          var remaining = entry.storedSize;
          while (remaining > 0) {
            final toRead = remaining > _chunkSize ? _chunkSize : remaining;
            final chunk = await _readExact(raf, toRead);
            controller.add(chunk);
            remaining -= chunk.length;
          }
          await controller.close();
          await done;
        } on Object {
          if (!controller.isClosed) {
            await controller.close();
          }
          await done.catchError((_) {});
          throw BackupException('解压备份条目失败（${entry.path}），文件可能已损坏');
        }
      }
      await output.flush();
    } finally {
      await output.close();
    }

    hashSink.close();
    final actualHash = hashSink
        .hashSync()
        .bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    if (writtenBytes != entry.size || actualHash != entry.sha256) {
      throw BackupException('备份文件校验失败（${entry.path}），内容可能已损坏或被篡改');
    }
  }

  static Future<void> _moveEntity(
    String sourcePath,
    String destinationPath,
    FileSystemEntityType type,
  ) async {
    if (type == FileSystemEntityType.file) {
      await File(sourcePath).rename(destinationPath);
    } else if (type == FileSystemEntityType.directory) {
      await Directory(sourcePath).rename(destinationPath);
    }
  }

  static Future<void> _deleteEntityIfExists(String path) async {
    final type = await FileSystemEntity.type(path, followLinks: false);
    if (type == FileSystemEntityType.file) {
      await File(path).delete();
    } else if (type == FileSystemEntityType.directory) {
      await Directory(path).delete(recursive: true);
    }
  }

  static Future<void> _deleteIfExists(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } on Object {
      // 忽略清理临时文件失败。
    }
  }

  static Future<void> _deleteDirectoryIfExists(Directory directory) async {
    try {
      if (await directory.exists()) await directory.delete(recursive: true);
    } on Object {
      // 忽略清理临时目录失败。
    }
  }
}
