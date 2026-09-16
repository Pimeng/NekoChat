import 'dart:async';

import 'package:flutter/services.dart';

enum ViewDropEventType { entered, exited, dropped }

class ViewDropEvent {
  const ViewDropEvent({
    required this.viewId,
    required this.type,
    this.paths = const [],
  });

  final int viewId;
  final ViewDropEventType type;
  final List<String> paths;
}

typedef ViewDropListener = void Function(ViewDropEvent event);

/// 独立窗口的原生文件拖放桥接。
///
/// `desktop_drop` 只为主窗口注册了 OLE 拖放目标，独立窗口收不到文件。
/// Windows runner 侧为每个 view 单独注册拖放目标，并通过本通道把
/// enter / leave / drop 事件发回 Dart，由 [ViewDropService] 按 viewId 分发。
class ViewDropService {
  ViewDropService({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('neko_chat/view_drop');

  /// 可替换的全局实例，便于测试注入假的 MethodChannel。
  static ViewDropService instance = ViewDropService();

  final MethodChannel _channel;
  final Map<int, Set<ViewDropListener>> _listeners = {};
  bool _initialized = false;

  void _ensureInitialized() {
    if (_initialized) return;
    _initialized = true;
    _channel.setMethodCallHandler(_handleCall);
  }

  Future<void> _handleCall(MethodCall call) async {
    if (call.method != 'event') return;
    final arguments = call.arguments;
    if (arguments is! Map) return;
    final viewId = arguments['viewId'];
    final typeName = arguments['type'];
    if (viewId is! int || typeName is! String) return;
    final type = switch (typeName) {
      'enter' => ViewDropEventType.entered,
      'leave' => ViewDropEventType.exited,
      'drop' => ViewDropEventType.dropped,
      _ => null,
    };
    if (type == null) return;
    final rawPaths = arguments['paths'];
    final paths = rawPaths is List
        ? [
            for (final path in rawPaths)
              if (path is String && path.isNotEmpty) path,
          ]
        : const <String>[];
    final listeners = _listeners[viewId];
    if (listeners == null) return;
    for (final listener in List<ViewDropListener>.of(listeners)) {
      listener(ViewDropEvent(viewId: viewId, type: type, paths: paths));
    }
  }

  /// 让原生层为该 view 登记拖放目标；返回是否登记成功。
  Future<bool> register(int viewId) async {
    _ensureInitialized();
    try {
      final result = await _channel.invokeMethod<bool>('register', {
        'viewId': viewId,
      });
      return result ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  Future<void> unregister(int viewId) async {
    _ensureInitialized();
    try {
      await _channel.invokeMethod<void>('unregister', {'viewId': viewId});
    } on MissingPluginException {
      // 非 Windows 平台没有原生实现。
    } on PlatformException {
      // 窗口可能已经被销毁。
    }
  }

  void addListener(int viewId, ViewDropListener listener) {
    _ensureInitialized();
    _listeners.putIfAbsent(viewId, () => <ViewDropListener>{}).add(listener);
  }

  void removeListener(int viewId, ViewDropListener listener) {
    final listeners = _listeners[viewId];
    if (listeners == null) return;
    listeners.remove(listener);
    if (listeners.isEmpty) _listeners.remove(viewId);
  }
}
