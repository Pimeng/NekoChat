import 'package:flutter_test/flutter_test.dart';
import 'package:neko_chat/app/app_controller.dart';
import 'package:neko_chat/core/files/content_hash.dart';
import 'package:neko_chat/core/models/models.dart';

void main() {
  DiscoveredPeer peerWithSecret(String deviceId, String secret) => DiscoveredPeer(
    deviceId: deviceId,
    displayName: 'peer',
    ip: '192.168.1.2',
    port: 23333,
    lastSeen: DateTime.now(),
    trusted: false,
    online: true,
    pairingHash: sha256String(secret + deviceId),
  );

  test('口令格式化：8 位分成两组，其它长度原样返回', () {
    expect(AppController.formatPairingCode('ABCD2345'), 'ABCD 2345');
    expect(AppController.formatPairingCode('ABC'), 'ABC');
  });

  test('口令归一化：去空白并大写', () {
    expect(AppController.normalizePairingCode('ab cd 23 45'), 'ABCD2345');
    expect(AppController.normalizePairingCode(' aB3 '), 'AB3');
  });

  test('口令哈希匹配：相符为真、大小写/空格不敏感，换口令或换设备为假', () {
    final controller = AppController();
    const deviceId = 'neko-peer-01a2b3c4-5678';
    const secret = 'ABCD2345';
    final peer = peerWithSecret(deviceId, secret);

    expect(controller.pairingCodeMatches(peer, 'ABCD2345'), isTrue);
    expect(controller.pairingCodeMatches(peer, 'abcd 2345'), isTrue);
    expect(controller.pairingCodeMatches(peer, 'WRONGXXX'), isFalse);
    expect(controller.pairingCodeMatches(peer, ''), isFalse);

    // 同口令换设备号（盐变化）→ 哈希不同 → 不匹配。
    final otherPeer = peerWithSecret('neko-other-99f0e1d2-1111', secret);
    expect(
      otherPeer.pairingHash == peer.pairingHash,
      isFalse,
      reason: '不同设备号应产生不同口令哈希',
    );
  });
}
