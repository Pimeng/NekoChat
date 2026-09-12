abstract final class NetworkConfig {
  static const int protocolVersion = 1;
  static const String multicastGroup = '239.255.42.99';
  static const int discoveryPort = 23332;
  static const int chatPort = 23333;
  static const Duration announceInterval = Duration(seconds: 3);
  static const Duration offlineTimeout = Duration(seconds: 10);
  static const Duration requestTimeout = Duration(seconds: 30);
  static const Duration fileOfferLifetime = Duration(minutes: 10);
  static const int maxFileSizeBytes = 512 * 1024 * 1024;
  static const int largeFileThresholdBytes = 10 * 1024 * 1024;

  /// 入站协议字段的长度上限，避免对端发送超大载荷占用本地存储。
  static const int maxDisplayNameLength = 32;
  static const int maxGroupNameLength = 40;
  static const int maxTextMessageLength = 10000;

  static bool requiresFileAcceptance(int fileSize) =>
      fileSize >= largeFileThresholdBytes;
}
