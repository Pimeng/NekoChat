import 'package:flutter_test/flutter_test.dart';
import 'package:neko_chat/core/networking/friend_request_limiter.dart';

void main() {
  test('发起方：同设备冷却期内被拒，冷却结束恢复，其他设备不受影响', () {
    var now = DateTime(2026, 1, 1);
    final limiter = FriendRequestLimiter(
      clock: () => now,
      outgoingCooldown: const Duration(seconds: 20),
      window: const Duration(seconds: 60),
      outgoingWindowLimit: 100,
    );

    expect(limiter.allowOutgoing('peer-a'), isTrue);
    expect(
      limiter.outgoingCooldownRemaining('peer-a'),
      const Duration(seconds: 20),
    );

    now = now.add(const Duration(seconds: 5));
    expect(limiter.allowOutgoing('peer-a'), isFalse);
    expect(
      limiter.outgoingCooldownRemaining('peer-a'),
      const Duration(seconds: 15),
    );

    // 其他设备不受同一设备的冷却影响。
    expect(limiter.allowOutgoing('peer-b'), isTrue);

    now = now.add(const Duration(seconds: 15));
    expect(limiter.outgoingCooldownRemaining('peer-a'), Duration.zero);
    expect(limiter.allowOutgoing('peer-a'), isTrue);
  });

  test('发起方：窗口内总次数超限后，要等最早一次滑出窗口', () {
    var now = DateTime(2026, 1, 1);
    final limiter = FriendRequestLimiter(
      clock: () => now,
      outgoingCooldown: Duration.zero,
      window: const Duration(seconds: 60),
      outgoingWindowLimit: 3,
    );

    expect(limiter.allowOutgoing('a'), isTrue);
    now = now.add(const Duration(seconds: 10));
    expect(limiter.allowOutgoing('b'), isTrue);
    now = now.add(const Duration(seconds: 10));
    expect(limiter.allowOutgoing('c'), isTrue);

    now = now.add(const Duration(seconds: 10));
    expect(limiter.allowOutgoing('d'), isFalse);
    expect(limiter.outgoingCooldownRemaining('d'), const Duration(seconds: 30));

    now = now.add(const Duration(seconds: 30));
    expect(limiter.outgoingCooldownRemaining('d'), Duration.zero);
    expect(limiter.allowOutgoing('d'), isTrue);
  });

  test('被添加方：同设备窗口内受理次数受限，窗口滑过后恢复', () {
    var now = DateTime(2026, 1, 1);
    final limiter = FriendRequestLimiter(
      clock: () => now,
      window: const Duration(seconds: 60),
      incomingPerPeerLimit: 2,
      incomingGlobalLimit: 100,
    );

    expect(limiter.allowIncoming('peer-a'), isTrue);
    expect(limiter.allowIncoming('peer-a'), isTrue);
    expect(limiter.allowIncoming('peer-a'), isFalse);
    // 其他设备仍有名额。
    expect(limiter.allowIncoming('peer-b'), isTrue);

    now = now.add(const Duration(seconds: 61));
    expect(limiter.allowIncoming('peer-a'), isTrue);
  });

  test('被添加方：全局上限兜底轮换设备号的刷屏', () {
    var now = DateTime(2026, 1, 1);
    final limiter = FriendRequestLimiter(
      clock: () => now,
      window: const Duration(seconds: 60),
      incomingPerPeerLimit: 100,
      incomingGlobalLimit: 3,
    );

    for (var index = 0; index < 3; index++) {
      expect(limiter.allowIncoming('peer-$index'), isTrue);
    }
    expect(limiter.allowIncoming('peer-new'), isFalse);

    now = now.add(const Duration(seconds: 61));
    expect(limiter.allowIncoming('peer-new'), isTrue);
  });
}
