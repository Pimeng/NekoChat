import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:logging/logging.dart';
import 'package:multiview_desktop/multiview_desktop.dart' as mvd;
import 'package:window_manager/window_manager.dart';

import 'notification_window_channel.dart';
import 'standalone_notification_controller.dart';
import 'system_notification_service.dart';
import 'windows_toast_card.dart';

/// 独立通知弹窗服务：通过独立无边框多视图窗口在屏幕角落（默认右下角）
/// 弹出仿 Windows 11 样式的通知浮窗，不抢占当前应用焦点，也不显示在任务栏。
class StandaloneNotificationService
    with WindowListener
    implements SystemNotificationService {
  StandaloneNotificationService({
    StandaloneNotificationController? controller,
    NotificationWindowChannel? windowChannel,
    this._anchor = NotificationAnchor.bottomRight,
    Future<void> Function()? onBringMainWindowToFront,
  }) : _controller = controller ?? StandaloneNotificationController(),
       _windowChannel = windowChannel ?? NotificationWindowChannel(),
       _onBringMainWindowToFront =
           onBringMainWindowToFront ?? _defaultBringMainWindowToFront;

  static int? _activeViewId;

  /// 当前正在使用的独立通知窗口 public viewId（用于老板键等逻辑排除它）。
  static int? get activeViewId => _activeViewId;

  static bool isNotificationViewId(int viewId) =>
      _activeViewId != null && _activeViewId == viewId;

  final StandaloneNotificationController _controller;
  final NotificationWindowChannel _windowChannel;
  final Future<void> Function() _onBringMainWindowToFront;
  final ValueNotifier<bool> _darkMode = ValueNotifier<bool>(false);
  final _log = Logger('StandaloneNotificationService');

  NotificationAnchor _anchor;
  bool _listening = false;
  bool _focused = true;
  bool _disposed = false;
  bool _isWindowVisible = false;
  int? _viewId;
  double? _lastSyncedHeight;
  NotificationAnchor? _lastSyncedAnchor;
  DateTime? _lastDarkModeCheck;
  bool _syncRunning = false;
  bool _syncPending = false;
  Completer<void>? _syncIdleCompleter;

  NotificationAnchor get anchor => _anchor;

  set anchor(NotificationAnchor value) {
    if (_anchor == value) return;
    _anchor = value;
    if (!_controller.isEmpty) {
      _scheduleWindowSync();
    }
  }

  @override
  bool get appIsFocused => _focused;

  @override
  Future<void> initialize() async {
    if (!(Platform.isWindows || Platform.isLinux || Platform.isMacOS)) return;
    if (!_listening) {
      windowManager.addListener(this);
      _listening = true;
      try {
        _focused = await windowManager.isFocused();
      } on Object catch (error, stack) {
        _log.fine('读取窗口焦点失败，按已聚焦处理', error, stack);
      }
    }
    _controller.removeListener(_handleControllerChanged);
    _controller.addListener(_handleControllerChanged);
  }

  @override
  Future<void> show({
    required String identifier,
    required String title,
    required String body,
    required NotificationCallback onClick,
  }) async {
    if (_disposed) return;
    if (!(Platform.isWindows || Platform.isLinux || Platform.isMacOS)) return;
    if (!_listening) {
      await initialize();
    }
    final now = DateTime.now();
    if (!_isWindowVisible ||
        _lastDarkModeCheck == null ||
        now.difference(_lastDarkModeCheck!) > const Duration(seconds: 3)) {
      _lastDarkModeCheck = now;
      _darkMode.value = await _windowChannel.isSystemDarkMode();
    }
    _controller.show(
      identifier: identifier,
      title: title,
      body: body,
      onClick: () async {
        await onClick();
        await _onBringMainWindowToFront();
      },
    );
    await _waitForSync();
  }

  @override
  Future<void> clearAll() async {
    _controller.clearAll();
    await _waitForSync();
  }

  void _handleControllerChanged() {
    if (_disposed) return;
    _scheduleWindowSync();
  }

  void _scheduleWindowSync() {
    if (_disposed) return;
    _syncPending = true;
    if (_syncRunning) return;
    _syncRunning = true;
    _syncIdleCompleter ??= Completer<void>();
    unawaited(_runSyncLoop());
  }

  Future<void> _waitForSync() async {
    if (!_syncRunning) return;
    final completer = _syncIdleCompleter;
    if (completer != null && !completer.isCompleted) {
      await completer.future;
    }
  }

  Future<void> _runSyncLoop() async {
    try {
      while (_syncPending && !_disposed) {
        _syncPending = false;
        try {
          await _syncWindow();
        } on Object catch (error, stack) {
          _log.warning('同步独立通知窗口失败', error, stack);
        }
      }
    } finally {
      _syncRunning = false;
      final completer = _syncIdleCompleter;
      _syncIdleCompleter = null;
      if (completer != null && !completer.isCompleted) {
        completer.complete();
      }
    }
  }

  Future<void> _syncWindow() async {
    if (_disposed) return;
    final items = _controller.items;
    if (items.isEmpty) {
      final viewId = _existingViewId();
      if (viewId != null && _isWindowVisible) {
        if (Platform.isWindows) {
          await _windowChannel.hide(viewId);
        } else {
          await mvd.MultiViewDesktop.fromId(viewId).hide();
        }
      }
      _isWindowVisible = false;
      _lastSyncedHeight = null;
      _lastSyncedAnchor = null;
      return;
    }

    const width = WindowsNotificationSurface.toastWidth;
    final height = WindowsNotificationSurface.computeSurfaceHeight(
      items.length,
    );

    final existingId = _existingViewId();
    if (existingId != null) {
      if (_isWindowVisible &&
          _lastSyncedHeight == height &&
          _lastSyncedAnchor == _anchor) {
        return;
      }
      if (!_isWindowVisible) {
        await WidgetsBinding.instance.endOfFrame;
        if (_disposed || _controller.isEmpty) return;
      }
      if (Platform.isWindows) {
        final ok = await _windowChannel.updateBoundsAndShow(
          viewId: existingId,
          width: width,
          height: height,
          anchor: _anchor,
        );
        if (!ok) {
          final window = mvd.MultiViewDesktop.fromId(existingId);
          await window.setSize(Size(width, height));
          await window.show();
        }
      } else {
        final window = mvd.MultiViewDesktop.fromId(existingId);
        await window.setSize(Size(width, height));
        await window.setAlwaysOnTop(true);
        await window.show();
      }
      _isWindowVisible = true;
      _lastSyncedHeight = height;
      _lastSyncedAnchor = _anchor;
      return;
    }

    final firstFrame = Completer<void>();
    if (Platform.isWindows) {
      await _windowChannel.prepareForCreation(
        width: width,
        height: height,
        anchor: _anchor,
      );
    }

    late final int viewId;
    try {
      viewId = await mvd.openWindow(
        (_, _) => _StandaloneNotificationHost(
          controller: _controller,
          darkModeListenable: _darkMode,
          onFirstFrame: () {
            if (!firstFrame.isCompleted) {
              firstFrame.complete();
            }
          },
        ),
        options: mvd.WindowOptions(
          size: Size(width, height),
          minimumSize: const Size(width, 96),
          maximumSize: const Size(width, 320),
          alignment: _toAlignment(_anchor),
          titleBarStyle: mvd.TitleBarStyle.hidden,
          windowButtonVisibility: false,
          alwaysOnTop: true,
          title: 'NekoChat 通知',
          // Flutter 3.47+ 将 MaterialApp 拆至 material_ui，multiview_desktop
          // 1.2.2 捕获主窗口壳层时会回退到 WidgetsApp；为其提供 pageRouteBuilder
          // 以满足 WidgetsApp 断言，避免弹出独立通知窗口时抛出异常。
          shellOverrides: mvd.ViewShellOverrides(
            pageRouteBuilder:
                <T>(RouteSettings settings, WidgetBuilder builder) =>
                    PageRouteBuilder<T>(
                      settings: settings,
                      pageBuilder: (context, _, _) => builder(context),
                    ),
          ),
        ),
      );
    } finally {
      if (Platform.isWindows) {
        await _windowChannel.cancelPrepare();
      }
    }
    _viewId = viewId;
    _activeViewId = viewId;

    final window = mvd.MultiViewDesktop.fromId(viewId);
    await window.setAsFrameless();
    if (Platform.isWindows) {
      await _windowChannel.configure(
        viewId: viewId,
        width: width,
        height: height,
        anchor: _anchor,
        reveal: false,
      );
      await firstFrame.future.timeout(
        const Duration(milliseconds: 250),
        onTimeout: () {},
      );
      await WidgetsBinding.instance.endOfFrame;
      await WidgetsBinding.instance.endOfFrame;
      if (_disposed || _controller.isEmpty) {
        await _windowChannel.hide(viewId);
        _isWindowVisible = false;
        _lastSyncedHeight = null;
        _lastSyncedAnchor = null;
        return;
      }
      await _windowChannel.reveal(viewId);
      _isWindowVisible = true;
      _lastSyncedHeight = height;
      _lastSyncedAnchor = _anchor;
    } else {
      await window.setAlwaysOnTop(true);
      await window.setHasShadow(true);
      _isWindowVisible = true;
      _lastSyncedHeight = height;
      _lastSyncedAnchor = _anchor;
    }
  }

  int? _existingViewId() {
    final id = _viewId;
    if (id == null) return null;
    if (!mvd.MultiViewDesktop.allWindowViewIds.contains(id)) {
      _viewId = null;
      _isWindowVisible = false;
      _lastSyncedHeight = null;
      _lastSyncedAnchor = null;
      if (_activeViewId == id) _activeViewId = null;
      return null;
    }
    return id;
  }

  static Alignment _toAlignment(NotificationAnchor anchor) => switch (anchor) {
    NotificationAnchor.bottomRight => Alignment.bottomRight,
    NotificationAnchor.topRight => Alignment.topRight,
    NotificationAnchor.bottomLeft => Alignment.bottomLeft,
    NotificationAnchor.topLeft => Alignment.topLeft,
  };

  static Future<void> _defaultBringMainWindowToFront() async {
    try {
      await windowManager.show();
      if (await windowManager.isMinimized()) {
        await windowManager.restore();
      }
      await windowManager.focus();
    } on Object catch (_) {}
  }

  @override
  void onWindowFocus() => _focused = true;

  @override
  void onWindowBlur() => _focused = false;

  @override
  Future<void> dispose() async {
    _disposed = true;
    _controller.removeListener(_handleControllerChanged);
    if (_listening) {
      windowManager.removeListener(this);
      _listening = false;
    }
    _controller.clearAll();
    _isWindowVisible = false;
    final viewId = _existingViewId();
    _viewId = null;
    if (_activeViewId == viewId) _activeViewId = null;
    if (viewId != null) {
      try {
        await mvd.MultiViewDesktop.fromId(viewId).closeWindow();
      } on Object catch (_) {}
    }
    _controller.dispose();
    _darkMode.dispose();
  }
}

class _StandaloneNotificationHost extends StatefulWidget {
  const _StandaloneNotificationHost({
    required this.controller,
    required this.darkModeListenable,
    this.onFirstFrame,
  });

  final StandaloneNotificationController controller;
  final ValueNotifier<bool> darkModeListenable;
  final VoidCallback? onFirstFrame;

  @override
  State<_StandaloneNotificationHost> createState() =>
      _StandaloneNotificationHostState();
}

class _StandaloneNotificationHostState
    extends State<_StandaloneNotificationHost> {
  bool _firstFrameNotified = false;
  List<StandaloneNotificationItem> _lastVisibleItems = const [];

  void _notifyFirstFrameOnce() {
    if (_firstFrameNotified || widget.onFirstFrame == null) return;
    _firstFrameNotified = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.onFirstFrame?.call();
    });
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: widget.darkModeListenable,
      builder: (context, darkMode, _) {
        return AnimatedBuilder(
          animation: widget.controller,
          builder: (context, _) {
            final liveItems = widget.controller.items;
            final isExiting = liveItems.isEmpty;
            if (!isExiting) {
              _lastVisibleItems = liveItems;
              _notifyFirstFrameOnce();
            } else if (_lastVisibleItems.isEmpty) {
              return const SizedBox.shrink();
            }
            final displayItems = isExiting ? _lastVisibleItems : liveItems;
            final content = ColoredBox(
              color: darkMode
                  ? const Color(0xFF2B2B2B)
                  : const Color(0xFFF6F6F6),
              child: MediaQuery.withClampedTextScaling(
                minScaleFactor: 1.0,
                maxScaleFactor: 1.15,
                child: SizedBox.expand(
                  child: WindowsNotificationSurface(
                    items: displayItems,
                    darkMode: darkMode,
                    borderRadius: 0,
                    showBorder: false,
                    onItemTap: (id) =>
                        unawaited(widget.controller.activate(id)),
                    onItemDismiss: widget.controller.dismiss,
                    onDismissAll: widget.controller.clearAll,
                    onHoverChanged: widget.controller.setHovered,
                  ),
                ),
              ),
            );
            return isExiting ? IgnorePointer(child: content) : content;
          },
        );
      },
    );
  }
}

/// 可在「独立弹窗通知（默认）」与「Windows 原生系统通知」间动态切换的通知服务。
class AdaptiveDesktopNotificationService implements SystemNotificationService {
  AdaptiveDesktopNotificationService({
    StandaloneNotificationService? standalone,
    DesktopSystemNotificationService? system,
    this._mode = NotificationMode.standalone,
    NotificationAnchor anchor = NotificationAnchor.bottomRight,
  }) : _standalone =
           standalone ?? StandaloneNotificationService(anchor: anchor),
       _system = system ?? DesktopSystemNotificationService();

  final StandaloneNotificationService _standalone;
  final DesktopSystemNotificationService _system;
  NotificationMode _mode;
  bool _systemInitialized = false;

  NotificationMode get mode => _mode;

  NotificationAnchor get anchor => _standalone.anchor;

  Future<void> setMode(NotificationMode value) async {
    if (_mode == value) return;
    await clearAll();
    _mode = value;
    if (_mode == NotificationMode.system && !_systemInitialized) {
      await _system.initialize();
      _systemInitialized = true;
    }
  }

  void setAnchor(NotificationAnchor value) {
    _standalone.anchor = value;
  }

  @override
  bool get appIsFocused => _mode == NotificationMode.standalone
      ? _standalone.appIsFocused
      : _system.appIsFocused;

  @override
  Future<void> initialize() async {
    await _standalone.initialize();
    if (_mode == NotificationMode.system && !_systemInitialized) {
      await _system.initialize();
      _systemInitialized = true;
    }
  }

  @override
  Future<void> show({
    required String identifier,
    required String title,
    required String body,
    required NotificationCallback onClick,
  }) async {
    if (_mode == NotificationMode.system) {
      if (!_systemInitialized) {
        await _system.initialize();
        _systemInitialized = true;
      }
      await _system.show(
        identifier: identifier,
        title: title,
        body: body,
        onClick: onClick,
      );
      return;
    }
    await _standalone.show(
      identifier: identifier,
      title: title,
      body: body,
      onClick: onClick,
    );
  }

  @override
  Future<void> clearAll() async {
    await _standalone.clearAll();
    if (_systemInitialized) {
      await _system.clearAll();
    }
  }

  @override
  Future<void> dispose() async {
    await _standalone.dispose();
    await _system.dispose();
  }
}
