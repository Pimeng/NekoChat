import 'package:flutter_test/flutter_test.dart';
import 'package:neko_chat/core/config/network_config.dart';

void main() {
  test('自动接收上限由接收端传入，达到阈值后必须确认', () {
    const limit = 25 * 1024 * 1024;
    expect(NetworkConfig.canAutoReceive(limit - 1, limit), isTrue);
    expect(NetworkConfig.canAutoReceive(limit, limit), isFalse);
  });
}
