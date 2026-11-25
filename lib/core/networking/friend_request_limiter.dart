import '../config/network_config.dart';

/// 加好友限频器：用滑动窗口统计"发起"与"受理"两侧的申请频率。
///
/// 发起方（本机加别人）：
/// - 同一设备两次发起之间至少间隔 [NetworkConfig.friendRequestCooldown]；
/// - 任何设备在 [NetworkConfig.friendRequestWindow] 内最多发起
///   [NetworkConfig.friendRequestWindowLimit] 次，避免脚本批量加人。
///
/// 被添加方（别人加本机）：
/// - 同一设备在窗口内最多受理 [NetworkConfig.inboundFriendRequestPerPeerLimit] 次；
/// - 窗口内全局最多受理 [NetworkConfig.inboundFriendRequestGlobalLimit] 次。
///   deviceId 由对端自称、可以伪造，所以除按设备限频外还需要全局兜底，
///   防止轮换设备号刷屏申请与通知。
///
/// [clock] 可注入，便于测试推进时间而不必真的等待。
class FriendRequestLimiter {
  FriendRequestLimiter({
    DateTime Function()? clock,
    this.outgoingCooldown = NetworkConfig.friendRequestCooldown,
    this.window = NetworkConfig.friendRequestWindow,
    this.outgoingWindowLimit = NetworkConfig.friendRequestWindowLimit,
    this.incomingPerPeerLimit = NetworkConfig.inboundFriendRequestPerPeerLimit,
    this.incomingGlobalLimit = NetworkConfig.inboundFriendRequestGlobalLimit,
  }) : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;

  /// 同一设备两次发起之间的最小间隔。
  final Duration outgoingCooldown;

  /// 滑动统计窗口长度。
  final Duration window;

  /// 发起方在窗口内的申请次数上限。
  final int outgoingWindowLimit;

  /// 被添加方在窗口内对同一设备的受理次数上限。
  final int incomingPerPeerLimit;

  /// 被添加方在窗口内的全局受理次数上限。
  final int incomingGlobalLimit;

  final Map<String, DateTime> _lastOutgoingAt = {};
  final List<DateTime> _outgoingWindow = [];
  final Map<String, List<DateTime>> _incomingByPeer = {};
  final List<DateTime> _incomingWindow = [];

  /// 距离可以向 [deviceId] 再次发起申请还需等待多久；可立即发起时为 [Duration.zero]。
  ///
  /// 同时考虑"同设备冷却"和"全局次数上限"两个限制，取其中更晚解除的那个。
  Duration outgoingCooldownRemaining(String deviceId) {
    final now = _clock();
    _prune(_outgoingWindow, now);

    var remaining = Duration.zero;
    if (_outgoingWindow.length >= outgoingWindowLimit) {
      // 窗口内最早的一次申请移出窗口后会腾出一个名额。
      final freeAt =
          _outgoingWindow[_outgoingWindow.length - outgoingWindowLimit].add(
            window,
          );
      final candidate = freeAt.difference(now);
      if (candidate > remaining) remaining = candidate;
    }

    final last = _lastOutgoingAt[deviceId];
    if (last != null) {
      final candidate = outgoingCooldown - now.difference(last);
      if (candidate > remaining) remaining = candidate;
    }
    return remaining.isNegative ? Duration.zero : remaining;
  }

  /// 记录一次发起申请。被限频时返回 false，且不改变任何统计。
  bool allowOutgoing(String deviceId) {
    final now = _clock();
    _prune(_outgoingWindow, now);
    if (_outgoingWindow.length >= outgoingWindowLimit) return false;

    final last = _lastOutgoingAt[deviceId];
    if (last != null && now.difference(last) < outgoingCooldown) return false;

    _lastOutgoingAt[deviceId] = now;
    _outgoingWindow.add(now);
    _pruneOutgoingPeers(now);
    return true;
  }

  /// 记录一次入站申请。被限频时返回 false，调用方应静默丢弃该申请。
  bool allowIncoming(String deviceId) {
    final now = _clock();
    _prune(_incomingWindow, now);
    _pruneIncomingPeers(now);
    if (_incomingWindow.length >= incomingGlobalLimit) return false;

    final timestamps = _incomingByPeer.putIfAbsent(deviceId, () => []);
    timestamps.removeWhere((time) => now.difference(time) >= window);
    if (timestamps.length >= incomingPerPeerLimit) return false;

    timestamps.add(now);
    _incomingWindow.add(now);
    return true;
  }

  void _prune(List<DateTime> timestamps, DateTime now) {
    timestamps.removeWhere((time) => now.difference(time) >= window);
  }

  void _pruneOutgoingPeers(DateTime now) {
    if (_lastOutgoingAt.length <= 256) return;
    _lastOutgoingAt.removeWhere(
      (_, time) => now.difference(time) >= outgoingCooldown,
    );
  }

  void _pruneIncomingPeers(DateTime now) {
    _incomingByPeer.removeWhere((_, timestamps) {
      timestamps.removeWhere((time) => now.difference(time) >= window);
      return timestamps.isEmpty;
    });
  }
}
