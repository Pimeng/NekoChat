import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:logging/logging.dart';

/// 将 Windows 原生的单实例检测桥接到 Flutter。
///
/// Windows runner 只允许同时运行一个 NekoChat 实例。当用户再次启动一份新的
/// 程序时，runner 会把已有窗口置前，并通过 [channelName] 通道调用
/// [alreadyRunningMethod]；本服务将该事件转发到 [onAlreadyRunning]，让界面
/// 提醒用户程序已经在运行。
class SingleInstanceService {
  SingleInstanceService({MethodChannel? channel, bool? supported})
    : _channel = channel ?? const MethodChannel(channelName),
      _supported = supported ?? Platform.isWindows;

  /// 与原生 runner 约定的方法通道名称。
  static const String channelName = 'neko_chat/single_instance';

  /// 原生端在检测到重复启动时回调的方法名。
  static const String alreadyRunningMethod = 'alreadyRunning';

  final MethodChannel _channel;
  final bool _supported;
  final Logger _log = Logger('SingleInstance');
  final StreamController<void> _alreadyRunning =
      StreamController<void>.broadcast();

  /// 每当用户尝试再次启动程序时触发一次。
  Stream<void> get onAlreadyRunning => _alreadyRunning.stream;

  /// 注册方法通道回调。仅 Windows 平台生效，其他平台直接返回。
  Future<void> initialize() async {
    if (!_supported) return;
    _channel.setMethodCallHandler(_handleMethodCall);
  }

  Future<void> _handleMethodCall(MethodCall call) async {
    if (call.method != alreadyRunningMethod) return;
    _log.info('检测到重复启动，准备唤醒现有窗口');
    _alreadyRunning.add(null);
  }

  Future<void> dispose() async {
    if (_supported) {
      _channel.setMethodCallHandler(null);
    }
    await _alreadyRunning.close();
  }
}
