import 'package:path/path.dart' as p;

/// 在“数据库存储路径”和“运行时绝对路径”之间转换附件路径。
///
/// 数据库里保存的是相对于数据目录的路径，例如 `received_images/ab12….png`。
/// 这样把数据目录连同程序一起搬到别的电脑、或换到另一个盘符后，历史附件依然
/// 指向新位置下的同一个文件。位于数据目录之外的文件（例如发送时自己挑的
/// 原始文件）无法用相对路径表达，仍然按绝对路径原样保存。
class AttachmentPathCodec {
  const AttachmentPathCodec(this.rootDirectoryPath);

  /// 数据目录的绝对路径。
  final String rootDirectoryPath;

  /// 把绝对路径转换成数据库中保存的形式。
  ///
  /// 统一使用 `/` 作为分隔符，避免数据库内容随平台变化；不在数据目录内的
  /// 路径保持原样返回。
  String encode(String absolutePath) {
    if (!isInsideRoot(absolutePath)) return absolutePath;
    final root = p.normalize(p.absolute(rootDirectoryPath));
    final target = p.normalize(p.absolute(absolutePath));
    return p.split(p.relative(target, from: root)).join('/');
  }

  /// 判断绝对路径是否位于数据目录内。
  ///
  /// 目录内的文件会跟着数据文件夹一起搬迁；目录外的文件（发送时由本机自己
  /// 挑选的原始文件）换机后无法自动定位。
  bool isInsideRoot(String absolutePath) {
    final root = p.normalize(p.absolute(rootDirectoryPath));
    final target = p.normalize(p.absolute(absolutePath));
    return p.isWithin(root, target);
  }

  /// 把数据库中保存的路径还原成本机绝对路径。
  ///
  /// 已经是绝对路径的旧数据（升级前写入的记录）原样返回。
  String decode(String storedPath) {
    if (p.isAbsolute(storedPath)) return storedPath;
    return p.joinAll([rootDirectoryPath, ...storedPath.split('/')]);
  }
}

/// 附件文件已不在预期位置时的用户提示。
///
/// [insideDataDirectory] 表示这条记录指向的文件原本位于数据文件夹内。目录内的
/// 文件会随数据文件夹整体搬迁，因此文件消失通常是被手动删除或移动；目录外的
/// 文件是发送时由本机挑选的原始文件，换到另一台电脑后无法自动定位，需要用户
/// 自己重新指定。
String missingAttachmentHint({required bool insideDataDirectory}) {
  if (insideDataDirectory) return '本地文件已被移动或删除，无法打开';
  return '原始文件不在原位置，无法帮你找到';
}
