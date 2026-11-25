import 'package:lpinyin/lpinyin.dart';

/// 轻量级拼音搜索工具：同时支持原文子串、全拼、首字母与常见多音字匹配（忽略大小写与常见标点）。
///
/// 例如 `"晓猫（前端）"` 可被以下查询命中：
/// - 原文：`"晓猫"`、`"前端"`
/// - 全拼：`"xiaomao"`、`"qianduan"`、`"xiaomaoqianduan"`
/// - 首字母：`"xm"`、`"qd"`、`"xmqd"`
/// 多音字如 `"琪露诺"` 可同时被 `"qilunuo"` 与 `"qilounuo"` 命中。
bool matchesPinyinSearch(String text, String rawQuery) =>
    pinyinMatchScore(text, rawQuery) != null;

/// 返回匹配优先级分值（越小越靠前）：
/// - `0`：原文、全拼或首字母完全匹配
/// - `1`：原文、全拼或首字母前缀匹配
/// - `2`：原文、全拼或首字母子串匹配
/// - `null`：不匹配
int? pinyinMatchScore(String text, String rawQuery) {
  final query = rawQuery.trim().toLowerCase();
  if (query.isEmpty) return 0;

  final lowerText = text.toLowerCase();
  if (lowerText == query) return 0;
  if (lowerText.startsWith(query)) return 1;
  if (lowerText.contains(query)) return 2;

  // 仅当查询包含 ASCII 字母/数字时才做拼音匹配，纯中文查询无需转换。
  final compactQuery = _stripSeparators(query);
  if (compactQuery.isEmpty || !_hasAsciiAlphaNum(compactQuery)) {
    return null;
  }

  final index = _indexFor(text);
  int? best;
  for (final candidate in index.fullVariants) {
    final score = _scoreString(candidate, compactQuery);
    if (score != null && (best == null || score < best)) {
      best = score;
      if (best == 0) return 0;
    }
  }
  for (final candidate in index.initialVariants) {
    final score = _scoreString(candidate, compactQuery);
    if (score != null && (best == null || score < best)) {
      best = score;
      if (best == 0) return 0;
    }
  }
  return best;
}

int? _scoreString(String candidate, String query) {
  if (candidate == query) return 0;
  if (candidate.startsWith(query)) return 1;
  if (candidate.contains(query)) return 2;
  return null;
}

class _PinyinIndex {
  const _PinyinIndex({
    required this.fullVariants,
    required this.initialVariants,
  });
  final List<String> fullVariants;
  final List<String> initialVariants;
}

final Map<String, _PinyinIndex> _cache = {};
const int _maxCacheEntries = 512;
const int _maxVariants = 32;

_PinyinIndex _indexFor(String text) {
  final cached = _cache[text];
  if (cached != null) return cached;

  var fullVariants = <String>[''];
  var initialVariants = <String>[''];

  for (final rune in text.runes) {
    final ch = String.fromCharCode(rune);
    if (_separatorPattern.hasMatch(ch)) continue;

    final readings = _readingsForChar(ch);
    if (readings.isEmpty) continue;

    final nextFull = <String>{};
    for (final prefix in fullVariants) {
      for (final reading in readings) {
        nextFull.add('$prefix$reading');
        if (nextFull.length >= _maxVariants) break;
      }
      if (nextFull.length >= _maxVariants) break;
    }
    fullVariants = nextFull.toList();

    final initials = readings.map((r) => r[0]).toSet();
    final nextInitials = <String>{};
    for (final prefix in initialVariants) {
      for (final initial in initials) {
        nextInitials.add('$prefix$initial');
        if (nextInitials.length >= _maxVariants) break;
      }
      if (nextInitials.length >= _maxVariants) break;
    }
    initialVariants = nextInitials.toList();
  }

  final index = _PinyinIndex(
    fullVariants: fullVariants,
    initialVariants: initialVariants,
  );
  if (_cache.length >= _maxCacheEntries) {
    _cache.clear();
  }
  _cache[text] = index;
  return index;
}

List<String> _readingsForChar(String ch) {
  final lower = ch.toLowerCase();
  if (_asciiAlphaNumPattern.hasMatch(lower)) {
    return [lower];
  }
  if (!ChineseHelper.isChinese(ch)) {
    return const [];
  }
  final raw = PinyinHelper.convertToPinyinArray(
    ch,
    PinyinFormat.WITHOUT_TONE,
  );
  final unique = <String>{};
  for (final item in raw) {
    final normalized = item.trim().toLowerCase();
    if (normalized.isNotEmpty) {
      unique.add(normalized);
    }
  }
  return unique.toList();
}

final RegExp _separatorPattern = RegExp(
  r'[\s\-_()（）【】\[\]·,，.。/\\:：]+',
);
final RegExp _asciiAlphaNumPattern = RegExp(r'[a-z0-9]');

String _stripSeparators(String value) => value.replaceAll(_separatorPattern, '');

bool _hasAsciiAlphaNum(String value) => _asciiAlphaNumPattern.hasMatch(value);
