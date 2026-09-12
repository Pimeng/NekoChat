import 'package:flutter_test/flutter_test.dart';
import 'package:neko_chat/core/files/attachment_path.dart';
import 'package:path/path.dart' as p;

void main() {
  final root = p.join(p.separator == '/' ? '/data' : r'C:\data', 'neko_chat');

  test('数据目录内的路径存成相对路径并统一用斜杠', () {
    final codec = AttachmentPathCodec(root);
    final absolute = p.join(root, 'received_images', 'ab12.png');

    final stored = codec.encode(absolute);

    expect(stored, 'received_images/ab12.png');
    expect(codec.decode(stored), absolute);
  });

  test('数据目录之外的路径保持绝对，避免误判', () {
    final codec = AttachmentPathCodec(root);
    final outside = p.join(p.dirname(root), 'somewhere-else', 'photo.png');

    expect(codec.encode(outside), outside);
    expect(codec.decode(outside), outside);
  });

  test('搬迁数据目录后附件指向新位置下的同一个文件', () {
    final movedRoot = p.join(p.dirname(root), 'moved', 'neko_chat');
    final stored = AttachmentPathCodec(
      root,
    ).encode(p.join(root, 'received_files', 'report.pdf'));

    final resolved = AttachmentPathCodec(movedRoot).decode(stored);

    expect(stored, 'received_files/report.pdf');
    expect(resolved, p.join(movedRoot, 'received_files', 'report.pdf'));
  });

  test('升级前保存的绝对路径可以继续使用', () {
    final codec = AttachmentPathCodec(root);
    final legacy = p.join(root, 'received_files', 'old.bin');

    expect(codec.decode(legacy), legacy);
  });

  test('可以判断路径是否位于数据目录内', () {
    final codec = AttachmentPathCodec(root);

    expect(codec.isInsideRoot(p.join(root, 'received_files', 'a.bin')), isTrue);
    expect(codec.isInsideRoot(root), isFalse);
    expect(
      codec.isInsideRoot(p.join(p.dirname(root), 'elsewhere', 'a.bin')),
      isFalse,
    );
  });

  group('附件缺失提示', () {
    test('数据目录外的原始文件换机后提示无法找到', () {
      expect(
        missingAttachmentHint(insideDataDirectory: false),
        '原始文件不在原位置，无法帮你找到',
      );
    });

    test('数据目录内的副本消失时提示已被移动或删除', () {
      expect(
        missingAttachmentHint(insideDataDirectory: true),
        contains('无法打开'),
      );
    });
  });
}
