import 'dart:convert';
import 'dart:math';

import 'package:flutter/services.dart' show AssetBundle, rootBundle;

/// 中文词口令词表。
///
/// 词表作为 asset（[assetPath]）随应用打包，运行时加载一次并缓存，不作为代码常量。
/// 口令从词表里按 [wordCount] 个词不放回抽取，展示时按词用空格分隔。
class PairingWordList {
  PairingWordList({List<String>? words, AssetBundle? bundle, Random? random}) {
    _words = words == null ? null : _validateWords(words);
    _bundle = bundle;
    _random = random;
  }

  /// 词表资源路径（在 pubspec.yaml 的 assets 中声明）。
  static const String assetPath = 'assets/pairing_words.json';

  /// 每个口令包含的词数。
  static const int wordCount = 5;

  /// 词表 JSON 的格式版本；格式变化时递增并在 [load] 中拒绝旧版本。
  static const int formatVersion = 1;

  late final AssetBundle? _bundle;
  late final Random? _random;
  List<String>? _words;
  Set<String>? _wordSet;

  /// 词表是否已加载。
  bool get isLoaded => _words != null;

  /// 词表内容；未加载时抛出 [StateError]。
  List<String> get words {
    final words = _words;
    if (words == null) {
      throw StateError('词表尚未加载，请先 await load()');
    }
    return words;
  }

  Set<String> get _set => _wordSet ??= words.toSet();

  /// 加载并校验词表；重复调用是幂等的。
  Future<void> load() async {
    if (_words != null) return;
    final bundle = _bundle ?? rootBundle;
    final raw = await bundle.loadString(assetPath);
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('词表格式错误：期望 JSON 对象');
    }
    final version = decoded['version'];
    if (version != formatVersion) {
      throw FormatException('词表版本不支持：$version（期望 $formatVersion）');
    }
    final rawWords = decoded['words'];
    if (rawWords is! List || rawWords.any((word) => word is! String)) {
      throw const FormatException('词表格式错误：words 应为字符串数组');
    }
    final loaded = _validateWords(rawWords.cast<String>());
    final declaredCount = decoded['wordCount'];
    if (declaredCount != loaded.length) {
      throw FormatException(
        '词表 wordCount=$declaredCount 与实际 ${loaded.length} 条不一致',
      );
    }
    _words = loaded;
    _wordSet = loaded.toSet();
  }

  /// 生成一条新口令：从词表里不放回随机取 [count] 个词，用空格分隔。
  String generateSecret({int count = wordCount, Random? random}) {
    final words = this.words;
    if (count <= 0 || count > words.length) {
      throw ArgumentError.value(count, 'count', '词数超出词表范围');
    }
    final source = random ?? _random ?? Random.secure();
    final picked = <int>{};
    while (picked.length < count) {
      picked.add(source.nextInt(words.length));
    }
    return picked.map((index) => words[index]).join(' ');
  }

  /// 判断 [secret] 是否为当前格式的口令（词数正确且词都在词表内）。
  bool isCurrentSecret(String secret) {
    final parts = secret.split(' ');
    if (parts.length != wordCount) return false;
    return parts.every(_set.contains);
  }

  static List<String> _validateWords(List<String> words) {
    if (words.length < 1024) {
      throw FormatException('词表过短：${words.length} 条');
    }
    if (words.toSet().length != words.length) {
      throw const FormatException('词表存在重复词');
    }
    for (final word in words) {
      final runes = word.runes.toList();
      if (runes.length < 2 || runes.length > 4) {
        throw FormatException('词条长度不合法：$word');
      }
      for (final rune in runes) {
        final isCjk =
            (rune >= 0x4e00 && rune <= 0x9fff) ||
            (rune >= 0x3400 && rune <= 0x4dbf);
        if (!isCjk) throw FormatException('词条包含非汉字：$word');
      }
    }
    return List.unmodifiable(words);
  }
}
