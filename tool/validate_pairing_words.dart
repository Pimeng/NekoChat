import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:lpinyin/lpinyin.dart';

/// 独立校验 assets/pairing_words.json：
/// 元数据、2-4 个汉字、一级字表、词形唯一、无调拼音唯一、字数分布。
void main() {
  final file = File('assets/pairing_words.json');
  final bytes = file.readAsBytesSync();
  final text = file.readAsStringSync();
  final hasBom =
      bytes.length >= 3 &&
      bytes[0] == 0xEF &&
      bytes[1] == 0xBB &&
      bytes[2] == 0xBF;
  final hasCr = text.contains('\r');
  final endsLf = text.endsWith('\n');

  final decoded = jsonDecode(text) as Map<String, dynamic>;
  final version = decoded['version'];
  final declaredCount = decoded['wordCount'];
  final rawWords = decoded['words'] as List;
  final words = rawWords.cast<String>();

  final gsc = File('tool/data/gsc_level1.txt')
      .readAsLinesSync()
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toSet();
  final han = RegExp(r'^[\u4e00-\u9fff]{2,4}$');
  final byLen = <int, int>{};
  final py = <String, String>{};
  final unique = <String>{};
  final problems = <String>[];

  if (version != 1) problems.add('version 应为 1，实际 $version');
  if (declaredCount != words.length) {
    problems.add('wordCount=$declaredCount 与实际 ${words.length} 条不一致');
  }
  for (var i = 0; i < words.length; i++) {
    final w = words[i];
    if (!han.hasMatch(w)) problems.add('第 ${i + 1} 条非 2-4 汉字: "$w"');
    if (w.trim() != w) problems.add('第 ${i + 1} 条首尾有空白');
    if (w.contains(' ')) problems.add('第 ${i + 1} 条含空格');
    if (!unique.add(w)) problems.add('重复词: ' + w);
    for (final ch in w.split('')) {
      if (!gsc.contains(ch)) problems.add('非一级字: ' + ch + '（' + w + '）');
    }
    byLen[w.length] = (byLen[w.length] ?? 0) + 1;
    final p = PinyinHelper.getPinyinE(w, separator: '', defPinyin: '?');
    if (p.contains('?')) problems.add('拼音转换失败: ' + w);
    final old = py[p];
    if (old != null) problems.add('拼音冲突: ' + old + ' / ' + w + ' -> ' + p);
    py[p] = w;
  }

  print('版本: $version');
  print('词数: ${words.length}（wordCount=$declaredCount）');
  print('BOM: ' + (hasBom ? '有' : '无'));
  print('CR 字符: ' + (hasCr ? '有' : '无'));
  print('文件以 LF 结尾: ' + (endsLf ? '是' : '否'));
  print('字数分布: $byLen');
  print('词形唯一: ' + (unique.length == words.length ? '是' : '否'));
  print('无调拼音唯一: ' + (py.length == words.length ? '是' : '否'));
  print('约束问题数: ${problems.length}');
  for (final problem in problems.take(20)) {
    print('  - ' + problem);
  }

  final rng = Random(777);
  final picked = <int>{};
  while (picked.length < 30) {
    picked.add(rng.nextInt(words.length));
  }
  print('--- 随机抽查 30 词 ---');
  for (final index in picked.toList()..sort()) {
    print('  ${index + 1}\t${words[index]}');
  }
}
