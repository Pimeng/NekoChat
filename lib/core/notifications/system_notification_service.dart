import 'dart:async';
import 'dart:io';

import 'package:local_notifier/local_notifier.dart';
import 'package:logging/logging.dart';
import 'package:window_manager/window_manager.dart';

typedef NotificationCallback = FutureOr<void> Function();

abstract interface class SystemNotificationService {
  bool get appIsFocused;
  Future<void> initialize();
  Future<void> show({
    required String identifier,
    required String title,
    required String body,
    required NotificationCallback onClick,
  });
  Future<void> dispose();
}

class DesktopSystemNotificationService
    with WindowListener
    implements SystemNotificationService {
  final _log = Logger('SystemNotificationService');
  final Map<String, LocalNotification> _active = {};
  bool _initialized = false;
  bool _listening = false;
  bool _focused = true;

  @override
  bool get appIsFocused => _focused;

  @override
  Future<void> initialize() async {
    if (!(Platform.isWindows || Platform.isLinux || Platform.isMacOS)) return;
    // 焦点跟踪与系统通知相互独立：即使通知初始化失败，也要能判断窗口是否失焦。
    if (!_listening) {
      windowManager.addListener(this);
      _listening = true;
      try {
        _focused = await windowManager.isFocused();
      } on Object catch (error, stack) {
        _log.fine('读取窗口焦点失败，按已聚焦处理', error, stack);
      }
    }
    if (_initialized) return;
    try {
      await localNotifier.setup(
        appName: 'NekoChat',
        shortcutPolicy: ShortcutPolicy.requireCreate,
      );
      _initialized = true;
      _log.info('系统通知服务已启用');
    } on Object catch (error, stack) {
      _log.warning('系统通知初始化失败，聊天功能将继续运行', error, stack);
    }
  }

  @override
  Future<void> show({
    required String identifier,
    required String title,
    required String body,
    required NotificationCallback onClick,
  }) async {
    if (!_initialized) return;
    final previous = _active.remove(identifier);
    if (previous != null) await _destroy(previous);

    final notification = LocalNotification(
      identifier: identifier,
      title: title,
      body: body,
    );
    _active[identifier] = notification;
    notification.onClick = () async {
      await onClick();
      await windowManager.show();
      await _remove(identifier, notification);
    };
    notification.onClose = (_) {
      if (identical(_active[identifier], notification)) {
        _active.remove(identifier);
      }
      unawaited(_destroy(notification));
    };
    try {
      await notification.show();
    } on Object catch (error, stack) {
      await _remove(identifier, notification);
      _log.warning('显示系统通知失败', error, stack);
    }
  }

  Future<void> _remove(
    String identifier,
    LocalNotification notification,
  ) async {
    if (!identical(_active[identifier], notification)) return;
    _active.remove(identifier);
    await _destroy(notification);
  }

  Future<void> _destroy(LocalNotification notification) async {
    notification.onClick = null;
    notification.onClose = null;
    try {
      await notification.destroy();
    } on Object catch (error, stack) {
      _log.fine('清理系统通知失败', error, stack);
    }
  }

  @override
  void onWindowFocus() => _focused = true;

  @override
  void onWindowBlur() => _focused = false;

  @override
  Future<void> dispose() async {
    if (_listening) {
      windowManager.removeListener(this);
      _listening = false;
    }
    final notifications = _active.values.toList();
    _active.clear();
    for (final notification in notifications) {
      await _destroy(notification);
    }
    _initialized = false;
  }
}

bool shouldNotifyForConversation({
  required bool appIsFocused,
  required String? selectedConversationId,
  required String incomingConversationId,
}) {
  return !appIsFocused || selectedConversationId != incomingConversationId;
}
