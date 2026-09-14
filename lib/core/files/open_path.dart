import 'package:path/path.dart' as p;

/// 构造 Windows 文件资源管理器参数。
///
/// `explorer.exe` 的 `/select,` 开关必须和目标路径位于同一个参数中；如果把
/// 两者拆开，资源管理器可能只打开目录而不会选中文件。
List<String> windowsExplorerArguments({
  required String directoryPath,
  String? revealPath,
}) {
  final targetPath = p.normalize(p.absolute(revealPath ?? directoryPath));
  return revealPath == null ? [targetPath] : ['/select,$targetPath'];
}
