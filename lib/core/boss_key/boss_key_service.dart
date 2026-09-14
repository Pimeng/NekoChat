import 'dart:io';
import 'dart:convert';

import 'package:flutter/services.dart';

typedef BossKeyVisibilityCallback = void Function(bool hidden);

class BossKeyShortcut {
  const BossKeyShortcut({
    required this.virtualKey,
    required this.keyLabel,
    this.control = false,
    this.alt = false,
    this.shift = false,
    this.meta = false,
  });

  static const altF = BossKeyShortcut(
    virtualKey: 0x46,
    keyLabel: 'F',
    alt: true,
  );

  final int virtualKey;
  final String keyLabel;
  final bool control;
  final bool alt;
  final bool shift;
  final bool meta;

  int get windowsModifiers =>
      (alt ? 0x0001 : 0) |
      (control ? 0x0002 : 0) |
      (shift ? 0x0004 : 0) |
      (meta ? 0x0008 : 0);

  String get displayLabel => [
    if (control) 'Ctrl',
    if (alt) 'Alt',
    if (shift) 'Shift',
    if (meta) 'Win',
    keyLabel,
  ].join(' + ');

  String encode() => jsonEncode({
    'virtualKey': virtualKey,
    'keyLabel': keyLabel,
    'control': control,
    'alt': alt,
    'shift': shift,
    'meta': meta,
  });

  static BossKeyShortcut decode(String? value) {
    if (value == null) return altF;
    try {
      final data = jsonDecode(value);
      if (data is! Map<String, dynamic>) return altF;
      final virtualKey = data['virtualKey'];
      final keyLabel = data['keyLabel'];
      final control = data['control'];
      final alt = data['alt'];
      final shift = data['shift'];
      final meta = data['meta'];
      if (virtualKey is! int ||
          virtualKey <= 0 ||
          virtualKey > 0xff ||
          keyLabel is! String ||
          keyLabel.isEmpty ||
          control is! bool ||
          alt is! bool ||
          shift is! bool ||
          meta is! bool ||
          !(control || alt || shift || meta)) {
        return altF;
      }
      return BossKeyShortcut(
        virtualKey: virtualKey,
        keyLabel: keyLabel,
        control: control,
        alt: alt,
        shift: shift,
        meta: meta,
      );
    } on Object {
      return altF;
    }
  }

  static BossKeyShortcut? fromLogicalKey(
    LogicalKeyboardKey key, {
    required bool control,
    required bool alt,
    required bool shift,
    required bool meta,
  }) {
    if (!(control || alt || shift || meta) || _modifierKeys.contains(key)) {
      return null;
    }
    final rawLabel = key.keyLabel.trim();
    final upperLabel = rawLabel.toUpperCase();
    if (RegExp(r'^[A-Z0-9]$').hasMatch(upperLabel)) {
      return BossKeyShortcut(
        virtualKey: upperLabel.codeUnitAt(0),
        keyLabel: upperLabel,
        control: control,
        alt: alt,
        shift: shift,
        meta: meta,
      );
    }
    final functionMatch = RegExp(r'^F([1-9]|1[0-2])$').firstMatch(upperLabel);
    if (functionMatch != null) {
      final number = int.parse(functionMatch.group(1)!);
      return BossKeyShortcut(
        virtualKey: 0x70 + number - 1,
        keyLabel: 'F$number',
        control: control,
        alt: alt,
        shift: shift,
        meta: meta,
      );
    }
    final special = _specialKeys[key];
    if (special == null) return null;
    return BossKeyShortcut(
      virtualKey: special.$2,
      keyLabel: special.$1,
      control: control,
      alt: alt,
      shift: shift,
      meta: meta,
    );
  }

  static final _modifierKeys = {
    LogicalKeyboardKey.control,
    LogicalKeyboardKey.controlLeft,
    LogicalKeyboardKey.controlRight,
    LogicalKeyboardKey.alt,
    LogicalKeyboardKey.altLeft,
    LogicalKeyboardKey.altRight,
    LogicalKeyboardKey.shift,
    LogicalKeyboardKey.shiftLeft,
    LogicalKeyboardKey.shiftRight,
    LogicalKeyboardKey.meta,
    LogicalKeyboardKey.metaLeft,
    LogicalKeyboardKey.metaRight,
  };

  static final Map<LogicalKeyboardKey, (String, int)> _specialKeys = {
    LogicalKeyboardKey.space: ('Space', 0x20),
    LogicalKeyboardKey.enter: ('Enter', 0x0d),
    LogicalKeyboardKey.escape: ('Esc', 0x1b),
    LogicalKeyboardKey.arrowLeft: ('Left', 0x25),
    LogicalKeyboardKey.arrowUp: ('Up', 0x26),
    LogicalKeyboardKey.arrowRight: ('Right', 0x27),
    LogicalKeyboardKey.arrowDown: ('Down', 0x28),
    LogicalKeyboardKey.home: ('Home', 0x24),
    LogicalKeyboardKey.end: ('End', 0x23),
    LogicalKeyboardKey.pageUp: ('Page Up', 0x21),
    LogicalKeyboardKey.pageDown: ('Page Down', 0x22),
    LogicalKeyboardKey.insert: ('Insert', 0x2d),
    LogicalKeyboardKey.delete: ('Delete', 0x2e),
    LogicalKeyboardKey.backspace: ('Backspace', 0x08),
  };

  @override
  bool operator ==(Object other) =>
      other is BossKeyShortcut &&
      virtualKey == other.virtualKey &&
      control == other.control &&
      alt == other.alt &&
      shift == other.shift &&
      meta == other.meta;

  @override
  int get hashCode => Object.hash(virtualKey, control, alt, shift, meta);
}

abstract interface class BossKeyService {
  Future<void> initialize(BossKeyVisibilityCallback onVisibilityChanged);
  Future<void> configure({
    required bool enabled,
    required BossKeyShortcut shortcut,
  });
  Future<void> dispose();
}

/// 通过 Windows runner 注册系统级 Alt+F，不依赖 Flutter 窗口的焦点。
class WindowsBossKeyService implements BossKeyService {
  WindowsBossKeyService({MethodChannel? channel, bool? supported})
    : _channel = channel ?? const MethodChannel(channelName),
      _supported = supported ?? Platform.isWindows;

  static const String channelName = 'neko_chat/boss_key';
  static const String configureMethod = 'configure';
  static const String visibilityChangedMethod = 'visibilityChanged';

  final MethodChannel _channel;
  final bool _supported;
  BossKeyVisibilityCallback? _onVisibilityChanged;

  @override
  Future<void> initialize(BossKeyVisibilityCallback onVisibilityChanged) async {
    if (!_supported) return;
    _onVisibilityChanged = onVisibilityChanged;
    _channel.setMethodCallHandler(_handleMethodCall);
  }

  Future<void> _handleMethodCall(MethodCall call) async {
    if (call.method != visibilityChangedMethod || call.arguments is! bool) {
      return;
    }
    _onVisibilityChanged?.call(call.arguments as bool);
  }

  @override
  Future<void> configure({
    required bool enabled,
    required BossKeyShortcut shortcut,
  }) async {
    if (!_supported) return;
    await _channel.invokeMethod<void>(configureMethod, {
      'enabled': enabled,
      'modifiers': shortcut.windowsModifiers,
      'virtualKey': shortcut.virtualKey,
    });
  }

  @override
  Future<void> dispose() async {
    if (!_supported) return;
    _channel.setMethodCallHandler(null);
    _onVisibilityChanged = null;
  }
}
