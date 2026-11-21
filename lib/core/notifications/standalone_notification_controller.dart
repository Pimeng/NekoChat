import 'dart:async';

import 'package:flutter/foundation.dart';

import 'system_notification_service.dart';

/// 单条独立通知的数据快照。
class StandaloneNotificationItem {
  const StandaloneNotificationItem({
    required this.identifier,
    required this.title,
    required this.body,
    required this.timestamp,
    required this.onClick,
    this.appName = 'NekoChat',
    this.revision = 0,
  });

  final String identifier;
  final String title;
  final String body;
  final DateTime timestamp;
  final NotificationCallback onClick;
  final String appName;

  /// 同 identifier 刷新时递增，用于触发入场微动效。
  final int revision;
}

class _TrackedNotification {
  _TrackedNotification({
    required this.item,
    required this.remaining,
    required this.startedAt,
  });

  StandaloneNotificationItem item;
  Duration remaining;
  DateTime startedAt;
  Timer? timer;
}

/// 独立通知队列控制器：负责去重更新、最多展示条数、自动消失倒计时与悬停暂停。
class StandaloneNotificationController extends ChangeNotifier {
  StandaloneNotificationController({
    this.maxVisible = 3,
    this.defaultDuration = const Duration(seconds: 6),
    this.resumeMinimumDuration = const Duration(seconds: 2),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final int maxVisible;
  final Duration defaultDuration;
  final Duration resumeMinimumDuration;
  final DateTime Function() _clock;

  final List<_TrackedNotification> _entries = [];
  bool _hovered = false;
  bool _disposed = false;

  List<StandaloneNotificationItem> get items =>
      List.unmodifiable(_entries.map((entry) => entry.item));

  bool get isEmpty => _entries.isEmpty;
  bool get isHovered => _hovered;

  /// 新增或更新同 [identifier] 的通知，并置顶展示。
  void show({
    required String identifier,
    required String title,
    required String body,
    required NotificationCallback onClick,
    String appName = 'NekoChat',
    Duration? duration,
  }) {
    if (_disposed) return;
    final now = _clock();
    final ttl = duration ?? defaultDuration;
    final existingIndex = _entries.indexWhere(
      (entry) => entry.item.identifier == identifier,
    );
    var nextRevision = 0;
    if (existingIndex >= 0) {
      final previous = _entries.removeAt(existingIndex);
      previous.timer?.cancel();
      nextRevision = previous.item.revision + 1;
    }

    final tracked = _TrackedNotification(
      item: StandaloneNotificationItem(
        identifier: identifier,
        title: title,
        body: body,
        timestamp: now,
        onClick: onClick,
        appName: appName,
        revision: nextRevision,
      ),
      remaining: ttl,
      startedAt: now,
    );
    _entries.insert(0, tracked);

    while (_entries.length > maxVisible) {
      final overflow = _entries.removeLast();
      overflow.timer?.cancel();
    }

    if (!_hovered) {
      _armTimer(tracked);
    }
    notifyListeners();
  }

  /// 鼠标移入时暂停所有自动消失计时，移出后继续剩余时间。
  void setHovered(bool hovered) {
    if (_disposed || _hovered == hovered) return;
    _hovered = hovered;
    final now = _clock();
    if (_hovered) {
      for (final entry in _entries) {
        entry.timer?.cancel();
        entry.timer = null;
        final elapsed = now.difference(entry.startedAt);
        final left = entry.remaining - elapsed;
        entry.remaining = left > resumeMinimumDuration
            ? left
            : resumeMinimumDuration;
      }
    } else {
      for (final entry in _entries) {
        entry.startedAt = now;
        _armTimer(entry);
      }
    }
    notifyListeners();
  }

  /// 关闭指定通知。
  void dismiss(String identifier) {
    if (_disposed) return;
    final index = _entries.indexWhere(
      (entry) => entry.item.identifier == identifier,
    );
    if (index < 0) return;
    final removed = _entries.removeAt(index);
    removed.timer?.cancel();
    notifyListeners();
  }

  /// 触发指定通知的点击回调并移除该通知。
  Future<void> activate(String identifier) async {
    if (_disposed) return;
    final index = _entries.indexWhere(
      (entry) => entry.item.identifier == identifier,
    );
    if (index < 0) return;
    final removed = _entries.removeAt(index);
    removed.timer?.cancel();
    notifyListeners();
    await removed.item.onClick();
  }

  /// 清空全部通知。
  void clearAll() {
    if (_disposed || _entries.isEmpty) return;
    for (final entry in _entries) {
      entry.timer?.cancel();
    }
    _entries.clear();
    notifyListeners();
  }

  void _armTimer(_TrackedNotification entry) {
    entry.timer?.cancel();
    if (entry.remaining <= Duration.zero) {
      dismiss(entry.item.identifier);
      return;
    }
    entry.timer = Timer(entry.remaining, () {
      dismiss(entry.item.identifier);
    });
  }

  @override
  void dispose() {
    _disposed = true;
    for (final entry in _entries) {
      entry.timer?.cancel();
    }
    _entries.clear();
    super.dispose();
  }
}
