abstract final class NetworkConfig {
  static const int protocolVersion = 1;
  static const String multicastGroup = '239.255.42.99';
  static const int discoveryPort = 23332;
  static const int chatPort = 23333;
  static const Duration announceInterval = Duration(seconds: 3);
  static const Duration offlineTimeout = Duration(seconds: 10);
  static const Duration requestTimeout = Duration(seconds: 30);

  /// 加好友限频：同一设备两次发起申请的最小间隔（发起方）。
  static const Duration friendRequestCooldown = Duration(seconds: 20);

  /// 加好友限频的滑动统计窗口。
  static const Duration friendRequestWindow = Duration(seconds: 60);

  /// 发起方在窗口内最多发起的加好友申请次数，避免脚本批量加人。
  static const int friendRequestWindowLimit = 10;

  /// 被添加方在窗口内对同一设备最多受理的申请次数。
  static const int inboundFriendRequestPerPeerLimit = 3;

  /// 被添加方在窗口内全局最多受理的申请次数（deviceId 可伪造，需要全局兜底）。
  static const int inboundFriendRequestGlobalLimit = 30;
  static const Duration fileOfferLifetime = Duration(minutes: 10);
  static const Duration selfRecallWindow = Duration(minutes: 2);
  static const Duration groupOwnerRecallWindow = Duration(hours: 1);
  static const Duration recallClockSkewTolerance = Duration(seconds: 30);
  static const int minAutoReceiveLimitBytes = 1 * 1024 * 1024;
  static const int defaultAutoReceiveLimitBytes = 10 * 1024 * 1024;
  static const int maxAutoReceiveLimitBytes = 512 * 1024 * 1024;

  /// 入站协议字段的长度上限，避免对端发送超大载荷占用本地存储。
  static const int maxDisplayNameLength = 32;
  static const int maxGroupNameLength = 40;
  static const int maxTextMessageLength = 10000;
  static const int maxReplyPreviewLength = 200;
  static const int maxMentionCount = 64;
  static const int maxRemarkLength = 40;
  static const int maxProfileAvatarBytes = 20 * 1024 * 1024;

  /// 断线重连时一次最多补发的消息条数。
  static const int maxHistoryBatchSize = 300;

  /// 重连补发的最大时间跨度，避免一次同步过多历史。
  static const Duration historySyncWindow = Duration(days: 3);

  static bool canAutoReceive(int fileSize, int limitBytes) =>
      fileSize >= 0 && fileSize < limitBytes;
}
