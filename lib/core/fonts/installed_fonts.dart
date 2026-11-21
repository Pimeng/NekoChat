import 'dart:io';

import 'package:path/path.dart' as p;

/// 系统已安装字体检测。
///
/// 应用不再随包携带字体文件，改为运行时查找本机已安装的字体：命中则使用，
/// 未命中则回退系统默认。Windows 上字体名若含中文（如“霞鹜文楷”）在注册表里
/// 会出现编码乱码，而字体文件名是 ASCII，因此这里按 Fonts 目录的文件名匹配，
/// 既稳定又不依赖子进程。
class InstalledFonts {
  const InstalledFonts._();

  /// Windows 上系统级与当前用户级字体目录。非 Windows 返回空列表。
  static List<Directory> defaultFontDirectories() {
    if (!Platform.isWindows) return const [];
    final dirs = <Directory>[];
    final winDir = Platform.environment['WINDIR'];
    dirs.add(Directory(p.join(winDir == null || winDir.isEmpty ? r'C:\Windows' : winDir, 'Fonts')));
    final localAppData = Platform.environment['LOCALAPPDATA'];
    if (localAppData != null && localAppData.isNotEmpty) {
      dirs.add(Directory(p.join(localAppData, 'Microsoft', 'Windows', 'Fonts')));
    }
    return dirs;
  }

  /// 扫描给定目录（默认取 [defaultFontDirectories]）里的字体文件名，统一小写返回。
  /// 目录不存在或无权限访问时跳过；非 Windows 或全部失败时返回空集合。
  static Set<String> scanFileNames({List<Directory>? directories}) {
    final dirs = directories ?? defaultFontDirectories();
    final names = <String>{};
    for (final dir in dirs) {
      try {
        if (!dir.existsSync()) continue;
        for (final entity in dir.listSync(followLinks: false)) {
          if (entity is! File) continue;
          final name = p.basename(entity.path).toLowerCase();
          if (name.endsWith('.ttf') ||
              name.endsWith('.ttc') ||
              name.endsWith('.otf')) {
            names.add(name);
          }
        }
      } catch (_) {
        // 某些目录可能无权限访问，忽略即可。
      }
    }
    return names;
  }

  /// 文件名是否以字体族标记 [token] 开头，且其后紧跟分隔符（`-`/`.`/空格/`_`）或恰好等于它。
  /// 用词边界而非简单包含，以便把相近家族区分开，例如
  /// `lxgwwenkai` 命中 `LXGWWenKai.ttf`/`LXGWWenKai-Regular.ttf`，但排除 `LXGWWenKaiMono-*`；
  /// `vivosans` 命中 `vivoSans-*` 但排除 `vivoSansGlobal-*`；`jetbrainsmono` 排除 `JetBrainsMonoNL-*`。
  static bool fileNameMatchesToken(String fileName, String token) {
    final name = fileName.toLowerCase();
    final key = token.toLowerCase();
    if (!name.startsWith(key)) return false;
    if (name.length == key.length) return true;
    final next = name[key.length];
    return next == '-' || next == '.' || next == ' ' || next == '_';
  }

  /// 在已安装文件名集合中判断是否存在匹配任一 [keys] 的字体文件。
  /// [keys] 为字体族标记（小写），按 [fileNameMatchesToken] 的词边界规则匹配；
  /// 命中其一即视为已安装；[keys] 为空时视为未安装。
  static bool isInstalled(Set<String> fileNames, List<String> keys) {
    if (keys.isEmpty) return false;
    for (final name in fileNames) {
      for (final key in keys) {
        if (fileNameMatchesToken(name, key)) return true;
      }
    }
    return false;
  }
}
