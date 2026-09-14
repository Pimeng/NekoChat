import 'package:flutter_test/flutter_test.dart';
import 'package:neko_chat/core/files/open_path.dart';
import 'package:path/path.dart' as p;

void main() {
  group('windowsExplorerArguments', () {
    test('打开目录时传入规范化绝对路径', () {
      final directory = p.join('somewhere', '..', 'attachments');

      expect(windowsExplorerArguments(directoryPath: directory), [
        p.normalize(p.absolute(directory)),
      ]);
    });

    test('定位文件时将 select 开关和绝对路径合并为一个参数', () {
      final directory = p.join('somewhere', 'attachments');
      final file = p.join(directory, '聊天 图片.png');

      expect(
        windowsExplorerArguments(directoryPath: directory, revealPath: file),
        ['/select,${p.normalize(p.absolute(file))}'],
      );
    });
  });
}
