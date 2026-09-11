import 'package:flutter_test/flutter_test.dart';
import 'package:neko_chat/core/config/network_config.dart';

void main() {
  test('10 MB 以下自动接收，达到阈值后必须确认', () {
    expect(
      NetworkConfig.requiresFileAcceptance(
        NetworkConfig.largeFileThresholdBytes - 1,
      ),
      isFalse,
    );
    expect(
      NetworkConfig.requiresFileAcceptance(
        NetworkConfig.largeFileThresholdBytes,
      ),
      isTrue,
    );
  });
}
