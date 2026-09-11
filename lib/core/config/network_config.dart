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

  static bool requiresFileAcceptance(int fileSize) =>
      fileSize >= largeFileThresholdBytes;
}
