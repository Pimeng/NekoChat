import 'dart:io';

import 'package:flutter/services.dart';
import 'package:logging/logging.dart';
import 'package:material_ui/material_ui.dart';

/// 根据应用 [ThemeMode] 与平台当前亮度，解析实际生效的深浅色。
Brightness resolveEffectiveBrightness(
  ThemeMode mode,
  Brightness platformBrightness,
) => switch (mode) {
  ThemeMode.light => Brightness.light,
  ThemeMode.dark => Brightness.dark,
  ThemeMode.system => platformBrightness,
};

/// 与 Windows 原生层 `neko_chat/window_theme` 通信，同步主窗口与独立会话窗口的
/// DWM 沉浸式深色标题栏（`DWMWA_USE_IMMERSIVE_DARK_MODE`）。
///
/// 之所以不直接调用 `window_manager.setBrightness`，是因为 `window_manager 0.5.2`
/// 在 Windows 上把应用亮度与系统 `AppsUseLightTheme` 做了与运算，系统处于浅色模式时
/// 无法把应用标题栏切到深色。
class WindowThemeChannel {
  WindowThemeChannel({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(channelName);

  static const channelName = 'neko_chat/window_theme';

  static final WindowThemeChannel instance = WindowThemeChannel();

  final MethodChannel _channel;
  final _log = Logger('WindowThemeChannel');

  /// 同步主窗口及指定独立窗口（[viewIds]）的原生标题栏深浅色。
  Future<void> syncThemeMode(
    ThemeMode mode, {
    List<int> viewIds = const [],
  }) async {
    if (!Platform.isWindows) return;
    try {
      await _channel.invokeMethod<void>('setThemeMode', {
        'mode': mode.name,
        'viewIds': viewIds,
      });
    } on MissingPluginException {
      // 测试环境或非 Windows 宿主未注册该通道，静默忽略。
    } on Object catch (error, stack) {
      _log.fine('同步原生窗口标题栏深浅色失败', error, stack);
    }
  }

  /// 仅同步单个独立窗口（[viewId]）的原生标题栏深浅色。
  Future<void> syncViewThemeMode(int viewId, ThemeMode mode) async {
    if (!Platform.isWindows) return;
    try {
      await _channel.invokeMethod<void>('setViewThemeMode', {
        'viewId': viewId,
        'mode': mode.name,
      });
    } on MissingPluginException {
      // 测试环境未注册该通道，静默忽略。
    } on Object catch (error, stack) {
      _log.fine('同步独立窗口标题栏深浅色失败', error, stack);
    }
  }
}
