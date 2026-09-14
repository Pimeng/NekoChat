import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neko_chat/core/boss_key/boss_key_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(WindowsBossKeyService.channelName);

  Future<void> sendRunnerVisibility(bool hidden) =>
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
            WindowsBossKeyService.channelName,
            const StandardMethodCodec().encodeMethodCall(
              MethodCall(WindowsBossKeyService.visibilityChangedMethod, hidden),
            ),
            (ByteData? _) {},
          );

  test('快捷键可持久化并拒绝无修饰键组合', () {
    final shortcut = BossKeyShortcut.fromLogicalKey(
      LogicalKeyboardKey.keyK,
      control: true,
      alt: false,
      shift: true,
      meta: false,
    );

    expect(shortcut?.displayLabel, 'Ctrl + Shift + K');
    expect(BossKeyShortcut.decode(shortcut!.encode()), shortcut);
    expect(
      BossKeyShortcut.fromLogicalKey(
        LogicalKeyboardKey.keyK,
        control: false,
        alt: false,
        shift: false,
        meta: false,
      ),
      isNull,
    );
    expect(BossKeyShortcut.decode('broken'), BossKeyShortcut.altF);
  });

  test('配置时把开关和快捷键传给 Windows runner', () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    final service = WindowsBossKeyService(channel: channel, supported: true);
    await service.initialize((_) {});

    await service.configure(enabled: true, shortcut: BossKeyShortcut.altF);
    await service.configure(enabled: false, shortcut: BossKeyShortcut.altF);

    expect(calls.map((call) => call.method), [
      WindowsBossKeyService.configureMethod,
      WindowsBossKeyService.configureMethod,
    ]);
    expect(calls.first.arguments, {
      'enabled': true,
      'modifiers': 0x0001,
      'virtualKey': 0x46,
    });
    expect((calls.last.arguments as Map)['enabled'], isFalse);
    await service.dispose();
  });

  test('原生隐藏状态会回传给应用', () async {
    final hiddenValues = <bool>[];
    final service = WindowsBossKeyService(channel: channel, supported: true);
    await service.initialize(hiddenValues.add);

    await sendRunnerVisibility(true);
    await sendRunnerVisibility(false);

    expect(hiddenValues, [true, false]);
    await service.dispose();
  });

  test('非 Windows 平台不调用原生通道', () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    final service = WindowsBossKeyService(channel: channel, supported: false);

    await service.initialize((_) {});
    await service.configure(enabled: true, shortcut: BossKeyShortcut.altF);

    expect(calls, isEmpty);
    await service.dispose();
  });
}
