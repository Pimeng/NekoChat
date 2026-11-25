import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:lpinyin/lpinyin.dart';

// ---------------------------------------------------------------------------
// 加好友口令中文词表生成器
// ---------------------------------------------------------------------------
// 运行: dart run tool/build_pairing_words.dart [--dump]
// 数据: tool/data/ 下的公开候选词表 + 人工校订的补充/排除表
// 输出: assets/pairing_words.json（UTF-8、2 空格缩进、每行一个词，供 App 运行时加载）
// ---------------------------------------------------------------------------

const String dataDir = 'tool/data';

const Map<String, String> sourceUrls = {
  'gsc_level1.txt':
      'https://raw.githubusercontent.com/shengdoushi/common-standard-chinese-characters-table/master/level-1.txt',
  'hsk30-expanded.csv':
      'https://raw.githubusercontent.com/ivankra/hsk30/master/hsk30-expanded.csv',
  'jieba_dict.txt':
      'https://raw.githubusercontent.com/fxsjy/jieba/master/jieba/dict.txt',
};

// 目标准入数量（2字 / 3字 / 4字），合计 2048
const int targetTwo = 1510;
const int targetThree = 370;
const int targetFour = 168;
const int targetTotal = 2048;

void log(Object? s) => print(s);

Future<void> main(List<String> args) async {
  final dump = args.contains('--dump');
  await ensureSources();

  final gsc = loadGsc();
  final hsk = loadHsk();
  final freq = loadJiebaFreq();
  final excludeWords = readLineSet('$dataDir/exclude_words.txt');
  final excludeChars = readLineSet('$dataDir/exclude_chars.txt');
  final curated = <int, List<Cand>>{2: [], 3: [], 4: []};
  for (final len in [2, 3, 4]) {
    curated[len] = loadCurated('$dataDir/curated_${len}char.txt', len);
  }

  final pyCache = <String, String>{};
  String pyOf(String w) => pyCache.putIfAbsent(
      w,
      () => PinyinHelper.getPinyinE(w, separator: '', defPinyin: '?')
          .toLowerCase());

  final stats = <String, int>{};
  void bump(String k, [int n = 1]) => stats[k] = (stats[k] ?? 0) + n;

  // ---------------- 候选生成 ----------------
  final pools = <int, List<Cand>>{2: [], 3: [], 4: []};
  final curatedOk = <int, List<Cand>>{2: [], 3: [], 4: []};
  final hskFourDump = <Cand>[];
  final seen = <String>{};
  for (final row in hsk) {
    final w = row.word;
    bump('hsk.rows');
    if (!validHan(w)) {
      bump('drop.not_han');
      continue;
    }
    if (!allCharsIn(w, gsc)) {
      bump('drop.rare_char');
      continue;
    }
    if (!hasNounPos(row.pos) && w.length != 4) {
      bump('drop.not_noun');
      continue;
    }
    final py = pyOf(w);
    final expected = normalizePinyin(row.pinyin);
    if (py.contains('?') || py.isEmpty || py != expected) {
      bump('drop.pinyin_mismatch');
      continue;
    }
    if (excludeChars.any(w.contains) || excludeWords.contains(w)) {
      bump('drop.blacklist');
      continue;
    }
    if (!seen.add(w)) {
      bump('drop.duplicate_word');
      continue;
    }
    final c = Cand(w, py, w.length, row.level, freq[w] ?? 0, 'hsk');
    if (w.length == 4) {
      hskFourDump.add(c);
    } else {
      pools[w.length]!.add(c);
    }
  }

  for (final len in [2, 3, 4]) {
    for (final c in curated[len]!) {
      bump('curated.rows.$len');
      if (c.word.length != len ||
          !validHan(c.word) ||
          !allCharsIn(c.word, gsc)) {
        bump('curated.drop.char');
        continue;
      }
      if (excludeWords.contains(c.word)) {
        bump('curated.drop.blacklist');
        continue;
      }
      final lp = pyOf(c.word);
      if (lp.contains('?') || lp.isEmpty) {
        bump('curated.drop.pinyin');
        continue;
      }
      if (c.py.isNotEmpty && c.py != lp) {
        bump('curated.drop.pinyin_mismatch');
        log('  [curated 拼音不符] ' + c.word + ': 标注=' + c.py + ' lpinyin=' + lp);
        continue;
      }
      c.py = lp;
      curatedOk[len]!.add(c);
    }
  }

  // 合并候选：人工补充词优先（保持表内顺序），再接 HSK 词（等级 + 词频排序）
  for (final len in [2, 3, 4]) {
    final hskList = pools[len]!..sort((a, b) {
      final lv = a.level.compareTo(b.level);
      if (lv != 0) return lv;
      final f = b.freq.compareTo(a.freq);
      if (f != 0) return f;
      return a.word.compareTo(b.word);
    });
    final seenWords = <String>{};
    final list = <Cand>[];
    var seq = 0;
    for (final c in curatedOk[len]!) {
      if (!seenWords.add(c.word)) continue;
      c.seq = seq++;
      list.add(c);
    }
    if (len != 4) {
      for (final c in hskList) {
        if (seenWords.add(c.word)) list.add(c);
      }
    }
    pools[len] = list;
  }

  log('=== 候选池 ===');
  for (final len in [2, 3, 4]) {
    final p = pools[len]!;
    log('  ' +
        len.toString() +
        ' 字候选: ' +
        p.length.toString() +
        ' 条（人工补充 ' +
        p.where((c) => c.source == 'curated').length.toString() +
        '）');
  }
  for (final len in [2, 3, 4]) {
    final p = pools[len]!;
    log('  ' + len.toString() + ' 字唯一拼音: ' +
        p.map((c) => c.py).toSet().length.toString());
  }
  log('  4 字 HSK 候选(仅 dump，供人工挑选): ' + hskFourDump.length.toString());
  log('=== 过滤统计 ===');
  final keys = stats.keys.toList()..sort();
  for (final k in keys) {
    log('  ' + k + ' = ' + stats[k].toString());
  }

  if (dump) {
    for (final len in [2, 3]) {
      final f = File('$dataDir/dump_${len}char.txt');
      final sb = StringBuffer();
      for (final c in pools[len]!) {
        sb.writeln(c.level.toString() +
            '\t' +
            c.freq.toString() +
            '\t' +
            c.word +
            '\t' +
            c.py +
            '\t' +
            c.source);
      }
      f.writeAsStringSync(sb.toString());
      log('  dump -> ' + f.path);
    }
    final f4 = File('$dataDir/dump_4char.txt');
    final sb4 = StringBuffer();
    for (final c in hskFourDump) {
      sb4.writeln(c.level.toString() +
          '\t' +
          c.freq.toString() +
          '\t' +
          c.word +
          '\t' +
          c.py);
    }
    f4.writeAsStringSync(sb4.toString());
    log('  dump -> ' + f4.path);
    return;
  }

  // ---------------- 全局选取（无调拼音全表唯一） ----------------
  final chosen = <Cand>[];
  final usedPy = <String>{};
  var collisions = 0;

  int takeFrom(List<Cand> pool, int target) {
    var added = 0;
    for (final c in pool) {
      if (added >= target) break;
      if (usedPy.contains(c.py)) {
        collisions++;
        continue;
      }
      usedPy.add(c.py);
      chosen.add(c);
      added++;
    }
    return added;
  }

  final gotTwo = takeFrom(pools[2]!, targetTwo);
  final gotThree = takeFrom(pools[3]!, targetThree);
  final gotFour = takeFrom(pools[4]!, targetFour);
  log('=== 初次选取 ===');
  log('  2 字 ' +
      gotTwo.toString() +
      ' / ' +
      targetTwo.toString() +
      '；3 字 ' +
      gotThree.toString() +
      ' / ' +
      targetThree.toString() +
      '；4 字 ' +
      gotFour.toString() +
      ' / ' +
      targetFour.toString());

  for (final len in [2, 3, 4]) {
    if (chosen.length >= targetTotal) break;
    takeFrom(pools[len]!, targetTotal - chosen.length);
  }

  if (chosen.length != targetTotal) {
    stderr.writeln('错误：仅选出 ' + chosen.length.toString() + ' 条');
    exitCode = 1;
    return;
  }

  // ---------------- 输出 ----------------
  chosen.sort((a, b) {
    final l = a.len.compareTo(b.len);
    if (l != 0) return l;
    return a.py.compareTo(b.py);
  });

  final words = [for (final c in chosen) c.word];
  final payload = <String, Object>{
    'version': 1,
    'wordCount': words.length,
    'generatedBy': 'tool/build_pairing_words.dart',
    'license': 'HSK 3.0 (MIT) + jieba (MIT) + 通用规范汉字表一级字表 + 原创筛选，'
        '详见 tool/pairing_words_report.md',
    'words': words,
  };
  final asset = File('assets/pairing_words.json');
  asset.parent.createSync(recursive: true);
  asset.writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert(payload) + '\n',
  );

  final byLen = <int, int>{};
  for (final c in chosen) {
    byLen[c.len] = (byLen[c.len] ?? 0) + 1;
  }
  final pySet = chosen.map((c) => c.py).toSet();
  log('=== 最终词表 ===');
  log('  总行数: ' + chosen.length.toString());
  log('  2字: ' +
      (byLen[2] ?? 0).toString() +
      '，3字: ' +
      (byLen[3] ?? 0).toString() +
      '，4字: ' +
      (byLen[4] ?? 0).toString());
  log('  词形唯一: ' +
      (chosen.map((c) => c.word).toSet().length == chosen.length).toString());
  log('  拼音唯一: ' + (pySet.length == chosen.length).toString());
  log('  跳过(拼音冲突): ' + collisions.toString());
  log('  5 词熵: ' +
      (5 * (math.log(chosen.length) / math.log(2))).toStringAsFixed(2) +
      ' bit');

  final rng = math.Random(20251125);
  log('=== 20 个 5 词口令样例 ===');
  for (var i = 0; i < 20; i++) {
    final idx = <int>{};
    while (idx.length < 5) {
      idx.add(rng.nextInt(chosen.length));
    }
    final words = idx.map((j) => chosen[j].word).toList();
    log('  ' + (i + 1).toString() + '. ' + words.join(' '));
  }
}

// ---------------------------------------------------------------------------
class Cand {
  final String word;
  String py;
  final int len;
  final int level;
  final int freq;
  final String source;
  int seq = 0;
  Cand(this.word, this.py, this.len, this.level, this.freq, this.source);
}

class HskRow {
  final String word;
  final String pinyin;
  final String pos;
  final int level;
  HskRow(this.word, this.pinyin, this.pos, this.level);
}

bool validHan(String w) =>
    w.isNotEmpty && RegExp(r'^[\u4e00-\u9fff]+$').hasMatch(w);

bool allCharsIn(String w, Set<String> allowed) =>
    w.runes.every((r) => allowed.contains(String.fromCharCode(r)));

bool hasNounPos(String pos) {
  final up = pos.toUpperCase().replaceAll(' ', '');
  if (up.isEmpty) return false;
  for (final bad in const [
    'NR', 'NS', 'NZ', 'NT', 'PRON', 'CONJ', 'PREP', 'AUX',
    'PART', 'INTJ', 'SUFFIX', 'PREFIX', 'ADV'
  ]) {
    if (up.contains(bad)) return false;
  }
  return up.contains('N');
}

Set<String> loadGsc() {
  final f = File('$dataDir/gsc_level1.txt');
  return f
      .readAsLinesSync()
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toSet();
}

List<HskRow> loadHsk() {
  final f = File('$dataDir/hsk30-expanded.csv');
  final text = f.readAsStringSync();
  final rows = parseCsv(text);
  if (rows.isEmpty) return [];
  final header = rows.first;
  int idx(String name) => header.indexOf(name);
  final iWord = idx('Simplified');
  final iPy = idx('Pinyin');
  final iPos = idx('POS');
  final iLevel = idx('Level');
  final out = <HskRow>[];
  for (var i = 1; i < rows.length; i++) {
    final r = rows[i];
    if (r.length <= iLevel) continue;
    final w = r[iWord].trim();
    if (!validHan(w)) continue;
    if (w.length < 2 || w.length > 4) continue;
    if (w.contains('|')) continue;
    final levelStr = r[iLevel].trim();
    final level = levelStr == '7-9' ? 7 : (int.tryParse(levelStr) ?? 7);
    out.add(HskRow(w, r[iPy].trim(), r[iPos].trim(), level));
  }
  return out;
}

Map<String, int> loadJiebaFreq() {
  final f = File('$dataDir/jieba_dict.txt');
  final map = <String, int>{};
  for (final line in f.readAsLinesSync()) {
    final parts = line.split(' ');
    if (parts.length < 2) continue;
    final w = parts[0];
    final fq = int.tryParse(parts[1]);
    if (fq == null) continue;
    if (!validHan(w) || w.length < 2 || w.length > 4) continue;
    final old = map[w];
    if (old == null || fq > old) map[w] = fq;
  }
  return map;
}

Set<String> readLineSet(String path) {
  final f = File(path);
  if (!f.existsSync()) return <String>{};
  return f
      .readAsLinesSync()
      .map((e) => e.split('#').first.trim())
      .where((e) => e.isNotEmpty)
      .toSet();
}

List<Cand> loadCurated(String path, int len) {
  final f = File(path);
  if (!f.existsSync()) return [];
  final out = <Cand>[];
  for (final line in f.readAsLinesSync()) {
    final raw = line.split('#').first.trim();
    if (raw.isEmpty) continue;
    final parts = raw.split(RegExp(r'\s+'));
    final w = parts[0];
    final py = parts.length > 1 ? normalizePinyin(parts[1]) : '';
    out.add(Cand(w, py, len, 0, 0, 'curated'));
  }
  return out;
}

List<List<String>> parseCsv(String text) {
  if (text.startsWith('\uFEFF')) text = text.substring(1);
  final rows = <List<String>>[];
  var row = <String>[];
  final field = StringBuffer();
  var inQuotes = false;
  for (var i = 0; i < text.length; i++) {
    final c = text[i];
    if (inQuotes) {
      if (c == '"') {
        if (i + 1 < text.length && text[i + 1] == '"') {
          field.write('"');
          i++;
        } else {
          inQuotes = false;
        }
      } else {
        field.write(c);
      }
    } else if (c == '"') {
      inQuotes = true;
    } else if (c == ',') {
      row.add(field.toString());
      field.clear();
    } else if (c == '\n') {
      row.add(field.toString());
      field.clear();
      rows.add(row);
      row = <String>[];
    } else if (c == '\r') {
      // skip
    } else {
      field.write(c);
    }
  }
  if (field.isNotEmpty || row.isNotEmpty) {
    row.add(field.toString());
    rows.add(row);
  }
  return rows;
}

String normalizePinyin(String p) {
  const toneMap = {
    'ā': 'a', 'á': 'a', 'ǎ': 'a', 'à': 'a',
    'ē': 'e', 'é': 'e', 'ě': 'e', 'è': 'e',
    'ī': 'i', 'í': 'i', 'ǐ': 'i', 'ì': 'i',
    'ō': 'o', 'ó': 'o', 'ǒ': 'o', 'ò': 'o',
    'ū': 'u', 'ú': 'u', 'ǔ': 'u', 'ù': 'u',
    'ǖ': 'v', 'ǘ': 'v', 'ǚ': 'v', 'ǜ': 'v',
    'ń': 'n', 'ň': 'n', 'ǹ': 'n', 'ḿ': 'm',
    'ê': 'e', 'ü': 'v'
  };
  final sb = StringBuffer();
  for (final ch in p.toLowerCase().split('')) {
    sb.write(toneMap[ch] ?? ch);
  }
  return sb
      .toString()
      .replaceAll(RegExp(r"[\s'’·\-]"), '')
      .replaceAll('u:', 'v');
}

Future<void> ensureSources() async {
  final dir = Directory(dataDir);
  if (!dir.existsSync()) dir.createSync(recursive: true);
  final client = HttpClient();
  try {
    for (final e in sourceUrls.entries) {
      final f = File('$dataDir/' + e.key);
      if (f.existsSync() && f.lengthSync() > 1000) continue;
      log('下载候选词表: ' + e.key + ' ...');
      final req = await client.getUrl(Uri.parse(e.value));
      final res = await req.close();
      if (res.statusCode != 200) {
        throw StateError('下载失败 ' + e.key + ': HTTP ' + res.statusCode.toString());
      }
      final bytes = await res.fold<List<int>>(<int>[], (a, b) => a..addAll(b));
      f.writeAsBytesSync(bytes);
      log('  -> ' + f.path);
    }
  } finally {
    client.close(force: true);
  }
}