import 'dart:io';

import 'package:flutter/services.dart';
import 'package:logging/logging.dart';

/// 通知显示方式：独立桌面弹窗（默认）或 Windows 原生系统通知。
enum NotificationMode {
  standalone('standalone', '独立弹窗通知', '在屏幕角落弹出仿 Windows 样式的独立浮窗，不依赖系统通知权限'),
  system('system', 'Windows 系统通知', '调用 Windows 原生通知中心推送提醒');

  const NotificationMode(this.wireName, this.label, this.description);

  final String wireName;
  final String label;
  final String description;

  static NotificationMode decode(String? value) => switch (value) {
    'system' => NotificationMode.system,
    _ => NotificationMode.standalone,
  };
}

/// 独立通知弹窗的停靠角落，默认右下角（与 Windows 通知一致）。
enum NotificationAnchor {
  bottomRight('bottomRight', '右下角'),
  topRight('topRight', '右上角'),
  bottomLeft('bottomLeft', '左下角'),
  topLeft('topLeft', '左上角');

  const NotificationAnchor(this.wireName, this.label);

  final String wireName;
  final String label;

  static NotificationAnchor decode(String? value) => switch (value) {
    'topRight' => NotificationAnchor.topRight,
    'bottomLeft' => NotificationAnchor.bottomLeft,
    'topLeft' => NotificationAnchor.topLeft,
    _ => NotificationAnchor.bottomRight,
  };
}

/// 与 Windows 原生层 `neko_chat/notification_window` 通信，将多视图窗口配置为
/// 无边框、不抢焦点、不进任务栏、始终置顶且贴合工作区边缘的圆角通知浮窗。
class NotificationWindowChannel {
  NotificationWindowChannel({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(channelName);

  static const channelName = 'neko_chat/notification_window';

  final MethodChannel _channel;
  final _log = Logger('NotificationWindowChannel');

  Future<void> captureForegroundWindow() async {
    if (!Platform.isWindows) return;
    try {
      await _channel.invokeMethod<void>('captureForegroundWindow');
    } on Object catch (error, stack) {
      _log.fine('记录前台窗口失败', error, stack);
    }
  }

  Future<bool> prepareForCreation({
    required double width,
    required double height,
    double marginX = 16,
    double marginY = 16,
    NotificationAnchor anchor = NotificationAnchor.bottomRight,
  }) async {
    if (!Platform.isWindows) return false;
    try {
      final ok = await _channel.invokeMethod<bool>('prepareForCreation', {
        'width': width,
        'height': height,
        'marginX': marginX,
        'marginY': marginY,
        'corner': anchor.wireName,
      });
      return ok ?? false;
    } on Object catch (error, stack) {
      _log.fine('预配置通知窗口创建钩子失败', error, stack);
      return false;
    }
  }

  Future<void> cancelPrepare() async {
    if (!Platform.isWindows) return;
    try {
      await _channel.invokeMethod<bool>('cancelPrepare');
    } on Object catch (error, stack) {
      _log.fine('清理通知窗口创建钩子失败', error, stack);
    }
  }

  Future<bool> configure({
    required int viewId,
    required double width,
    required double height,
    double marginX = 16,
    double marginY = 16,
    NotificationAnchor anchor = NotificationAnchor.bottomRight,
    bool reveal = true,
  }) async {
    if (!Platform.isWindows) return false;
    try {
      final ok = await _channel.invokeMethod<bool>('configure', {
        'viewId': viewId,
        'width': width,
        'height': height,
        'marginX': marginX,
        'marginY': marginY,
        'corner': anchor.wireName,
        'reveal': reveal,
      });
      return ok ?? false;
    } on Object catch (error, stack) {
      _log.warning('配置独立通知窗口失败', error, stack);
      return false;
    }
  }

  Future<bool> reveal(int viewId) async {
    if (!Platform.isWindows) return false;
    try {
      final ok = await _channel.invokeMethod<bool>('reveal', {
        'viewId': viewId,
      });
      return ok ?? false;
    } on Object catch (error, stack) {
      _log.warning('显示独立通知窗口失败', error, stack);
      return false;
    }
  }

  Future<bool> updateBoundsAndShow({
    required int viewId,
    required double width,
    required double height,
    double marginX = 16,
    double marginY = 16,
    NotificationAnchor anchor = NotificationAnchor.bottomRight,
  }) async {
    if (!Platform.isWindows) return false;
    try {
      final ok = await _channel.invokeMethod<bool>('updateBoundsAndShow', {
        'viewId': viewId,
        'width': width,
        'height': height,
        'marginX': marginX,
        'marginY': marginY,
        'corner': anchor.wireName,
      });
      return ok ?? false;
    } on Object catch (error, stack) {
      _log.warning('更新独立通知窗口位置失败', error, stack);
      return false;
    }
  }

  Future<void> hide(int viewId) async {
    if (!Platform.isWindows) return;
    try {
      await _channel.invokeMethod<bool>('hide', {'viewId': viewId});
    } on Object catch (error, stack) {
      _log.fine('隐藏独立通知窗口失败', error, stack);
    }
  }

  Future<bool> isSystemDarkMode() async {
    if (!Platform.isWindows) return false;
    try {
      return await _channel.invokeMethod<bool>('isSystemDarkMode') ?? false;
    } on Object catch (error, stack) {
      _log.fine('读取系统深浅色模式失败', error, stack);
      return false;
    }
  }
}
