abstract final class NetworkConfig {
  static const int protocolVersion = 1;
  static const String multicastGroup = '239.255.42.99';
  static const int discoveryPort = 23332;
  static const int chatPort = 23333;
  static const Duration announceInterval = Duration(seconds: 3);
  static const Duration offlineTimeout = Duration(seconds: 10);
  static const Duration requestTimeout = Duration(seconds: 30);
}
