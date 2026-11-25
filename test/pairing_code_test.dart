import 'package:flutter_test/flutter_test.dart';
import 'package:neko_chat/app/app_controller.dart';
import 'package:neko_chat/core/files/content_hash.dart';
import 'package:neko_chat/core/identity/pairing_word_list.dart';
import 'package:neko_chat/core/models/models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final wordList = PairingWordList();
  setUpAll(() async {
    await wordList.load();
  });

  DiscoveredPeer peerWithSecret(String deviceId, String secret) =>
      DiscoveredPeer(
        deviceId: deviceId,
        displayName: 'peer',
        ip: '192.168.1.2',
        port: 23333,
        lastSeen: DateTime.now(),
        trusted: false,
        online: true,
        pairingHash: sha256String(secret + deviceId),
      );

  test('口令格式化：旧版 8 位分成两组，中文词口令原样展示', () {
    expect(AppController.formatPairingCode('ABCD2345'), 'ABCD 2345');
    expect(AppController.formatPairingCode('ABC'), 'ABC');
    expect(AppController.formatPairingCode('月亮 咖啡 火箭 西瓜 星星'), '月亮 咖啡 火箭 西瓜 星星');
  });

  test('口令归一化：去空白并大写，中文词口令去空格后不变', () {
    expect(AppController.normalizePairingCode('ab cd 23 45'), 'ABCD2345');
    expect(AppController.normalizePairingCode(' aB3 '), 'AB3');
    expect(AppController.normalizePairingCode('月亮 咖啡 火箭 西瓜 星星'), '月亮咖啡火箭西瓜星星');
    // 全角空格也要被去掉，粘贴自聊天软件时很常见。
    expect(AppController.normalizePairingCode('月亮\u3000咖啡'), '月亮咖啡');
  });

  test('生成的中文口令：5 个词、都在词表内、互不重复', () {
    for (var round = 0; round < 50; round++) {
      final secret = wordList.generateSecret();
      final words = secret.split(' ');
      expect(words.length, PairingWordList.wordCount);
      expect(words.toSet().length, words.length, reason: '5 个词不应重复');
      for (final word in words) {
        expect(wordList.words, contains(word));
      }
      // 展示格式与存储格式一致（按词保留空格）。
      expect(AppController.formatPairingCode(secret), secret);
      expect(wordList.isCurrentSecret(secret), isTrue);
    }
  });

  test('口令格式识别：旧版 8 位字母数字不算当前格式', () {
    expect(wordList.isCurrentSecret('ABCD2345'), isFalse);
    expect(wordList.isCurrentSecret(''), isFalse);
    expect(wordList.isCurrentSecret('月亮 咖啡 火箭 西瓜'), isFalse, reason: '词数不足');
    expect(
      wordList.isCurrentSecret('月亮 咖啡 火箭 西瓜 不存在的词'),
      isFalse,
      reason: '词不在词表内',
    );
  });

  test('口令哈希匹配：中文词口令空格不敏感，换口令或换设备为假', () {
    final controller = AppController();
    const deviceId = 'neko-peer-01a2b3c4-5678';
    const secret = '月亮咖啡火箭西瓜星星';
    final peer = peerWithSecret(deviceId, secret);

    expect(controller.pairingCodeMatches(peer, '月亮咖啡火箭西瓜星星'), isTrue);
    expect(controller.pairingCodeMatches(peer, '月亮 咖啡 火箭 西瓜 星星'), isTrue);
    expect(controller.pairingCodeMatches(peer, '月亮 咖啡 火箭 西瓜'), isFalse);

    final otherPeer = peerWithSecret('neko-other-99f0e1d2-1111', secret);
    expect(
      otherPeer.pairingHash == peer.pairingHash,
      isFalse,
      reason: '不同设备号应产生不同口令哈希',
    );
  });

  test('口令哈希匹配：旧版 8 位字母数字口令仍然可用', () {
    final controller = AppController();
    const deviceId = 'neko-peer-01a2b3c4-5678';
    final peer = peerWithSecret(deviceId, 'ABCD2345');

    expect(controller.pairingCodeMatches(peer, 'ABCD2345'), isTrue);
    expect(controller.pairingCodeMatches(peer, 'abcd 2345'), isTrue);
    expect(controller.pairingCodeMatches(peer, 'WRONGXXX'), isFalse);
    expect(controller.pairingCodeMatches(peer, ''), isFalse);
  });
}
