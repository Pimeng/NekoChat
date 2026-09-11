import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neko_chat/core/single_instance/single_instance_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(SingleInstanceService.channelName);

  Future<void> sendRunnerCall(String method) {
    return TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          SingleInstanceService.channelName,
          const StandardMethodCodec().encodeMethodCall(MethodCall(method)),
          (ByteData? _) {},
        );
  }

  test('原生报告重复启动时通知监听者', () async {
    final service = SingleInstanceService(channel: channel, supported: true);
    await service.initialize();
    final events = <void>[];
    final subscription = service.onAlreadyRunning.listen(events.add);

    await sendRunnerCall(SingleInstanceService.alreadyRunningMethod);
    await Future<void>.delayed(Duration.zero);

    expect(events, hasLength(1));

    await subscription.cancel();
    await service.dispose();
  });

  test('忽略未知的方法调用', () async {
    final service = SingleInstanceService(channel: channel, supported: true);
    await service.initialize();
    final events = <void>[];
    final subscription = service.onAlreadyRunning.listen(events.add);

    await sendRunnerCall('somethingElse');
    await Future<void>.delayed(Duration.zero);

    expect(events, isEmpty);

    await subscription.cancel();
    await service.dispose();
  });

  test('不支持单实例的平台不注册回调', () async {
    final service = SingleInstanceService(channel: channel, supported: false);
    await service.initialize();
    final events = <void>[];
    final subscription = service.onAlreadyRunning.listen(events.add);

    await sendRunnerCall(SingleInstanceService.alreadyRunningMethod);
    await Future<void>.delayed(Duration.zero);

    expect(events, isEmpty);

    await subscription.cancel();
    await service.dispose();
  });
}
