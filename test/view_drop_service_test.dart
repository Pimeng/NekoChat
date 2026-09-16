import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neko_chat/features/chat/view_drop_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('neko_chat/view_drop');
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'register') return true;
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  Future<void> sendEvent(int viewId, String type, {List<Object?>? paths}) =>
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
            'neko_chat/view_drop',
            const StandardMethodCodec().encodeMethodCall(
              MethodCall('event', {
                'viewId': viewId,
                'type': type,
                'paths': ?paths,
              }),
            ),
            (ByteData? _) {},
          );

  test('注册与注销会把 viewId 传给原生层', () async {
    final service = ViewDropService(channel: channel);

    expect(await service.register(3), isTrue);
    await service.unregister(3);

    expect(calls.map((call) => call.method), ['register', 'unregister']);
    expect(calls.first.arguments, {'viewId': 3});
    expect(calls.last.arguments, {'viewId': 3});
  });

  test('原生拖放事件只分发给对应 viewId 的监听者', () async {
    final service = ViewDropService(channel: channel);
    final events = <ViewDropEvent>[];
    service.addListener(2, events.add);

    await sendEvent(2, 'enter');
    await sendEvent(2, 'drop', paths: [r'C:\资料\报告.pdf', '', 42]);
    await sendEvent(5, 'enter');

    expect(events.map((event) => event.type), [
      ViewDropEventType.entered,
      ViewDropEventType.dropped,
    ]);
    expect(events.last.paths, [r'C:\资料\报告.pdf']);
  });

  test('移除监听后不再收到事件', () async {
    final service = ViewDropService(channel: channel);
    final events = <ViewDropEvent>[];
    void listener(ViewDropEvent event) => events.add(event);
    service.addListener(7, listener);
    service.removeListener(7, listener);

    await sendEvent(7, 'leave');

    expect(events, isEmpty);
  });
}
