import 'package:flutter_test/flutter_test.dart';
import 'package:neko_chat/core/identity/pairing_word_list.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final wordList = PairingWordList();
  setUpAll(() async {
    await wordList.load();
  });

  test('口令词表：asset 加载成功，数量合理、每条 2-4 个汉字、无重复', () {
    expect(wordList.isLoaded, isTrue);
    final words = wordList.words;
    expect(words.length, greaterThanOrEqualTo(1500));
    expect(words.length, lessThanOrEqualTo(4096));
    expect(words.toSet().length, words.length, reason: '词表不应有重复词');

    for (final word in words) {
      final runes = word.runes.toList();
      expect(runes.length, inInclusiveRange(2, 4), reason: '词条长度不合法: $word');
      for (final rune in runes) {
        final isCjk =
            (rune >= 0x4e00 && rune <= 0x9fff) ||
            (rune >= 0x3400 && rune <= 0x4dbf);
        expect(isCjk, isTrue, reason: '包含非汉字字符: $word');
      }
    }
  });

  test('口令词表：未加载时读取会抛出明确错误', () {
    final fresh = PairingWordList();
    expect(fresh.isLoaded, isFalse);
    expect(() => fresh.words, throwsStateError);
    expect(() => fresh.generateSecret(), throwsStateError);
  });

  test('口令词表：加载时会拒绝重复词与非法词条', () {
    expect(
      () => PairingWordList(words: List<String>.filled(1024, '月亮')),
      throwsFormatException,
    );
    expect(
      () => PairingWordList(
        words: List<String>.generate(1024, (index) => 'ab$index'),
      ),
      throwsFormatException,
    );
  });

  test('口令词表：抽取词数固定且不重复', () {
    final secret = wordList.generateSecret();
    final words = secret.split(' ');
    expect(words.length, PairingWordList.wordCount);
    expect(words.toSet().length, words.length);
    expect(wordList.isCurrentSecret(secret), isTrue);

    // 可注入固定种子的 Random，便于测试。
    final deterministic = wordList.generateSecret(count: 3);
    expect(deterministic.split(' ').length, 3);
  });
}
