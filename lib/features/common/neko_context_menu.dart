import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/app_controller.dart';

/// 统一的桌面深色浮动菜单项（用于右键菜单、发送方式下拉菜单等）。
class NekoContextMenuItem<T> {
  const NekoContextMenuItem({
    required this.label,
    this.value,
    this.icon,
    this.onTap,
    this.enabled = true,
    this.selected = false,
    this.destructive = false,
    this.hasDividerBefore = false,
  });

  final T? value;
  final String label;
  final IconData? icon;
  final VoidCallback? onTap;
  final bool enabled;
  final bool selected;
  final bool destructive;
  final bool hasDividerBefore;
}

/// 弹出统一样式的深色桌面浮动菜单，返回被点击项的 [NekoContextMenuItem.value]；
/// 点击空白处、右键其他位置或按 Esc 取消时返回 null。
///
/// [preferAbove] 为 true 时优先在 [position] 上方展开（适合底部输入框附近的按钮）；
/// [alignRight] 为 true 时菜单右边缘对齐 [position.dx]。
Future<T?> showNekoContextMenu<T>({
  required BuildContext context,
  required Offset position,
  required List<NekoContextMenuItem<T>> items,
  double width = 160,
  bool preferAbove = false,
  bool alignRight = false,
}) {
  final overlay = Overlay.of(context);
  final completer = Completer<T?>();
  final menuKey = GlobalKey<NekoContextMenuOverlayState>();
  OverlayEntry? entry;

  void removeEntry() {
    entry?.remove();
    entry = null;
  }

  void closeWith(T? result) {
    if (!completer.isCompleted) {
      completer.complete(result);
    }
    final state = menuKey.currentState;
    if (state != null) {
      state.close();
    } else {
      removeEntry();
    }
  }

  final wrappedItems = [
    for (final item in items)
      NekoContextMenuItem<void>(
        label: item.label,
        icon: item.icon,
        enabled: item.enabled,
        selected: item.selected,
        destructive: item.destructive,
        hasDividerBefore: item.hasDividerBefore,
        onTap: item.enabled
            ? () {
                closeWith(item.value);
                item.onTap?.call();
              }
            : null,
      ),
  ];

  entry = OverlayEntry(
    builder: (_) => NekoContextMenuOverlay(
      key: menuKey,
      position: position,
      items: wrappedItems,
      width: width,
      preferAbove: preferAbove,
      alignRight: alignRight,
      onDismiss: () => closeWith(null),
      onClosed: removeEntry,
    ),
  );
  overlay.insert(entry!);
  return completer.future;
}

/// 现代桌面风格深色浮动菜单浮层（深色卡片 + 细描边 + 柔和投影 + 紧凑图标文字）。
///
/// 弹出时正向播放淡入+缩放，关闭时反向播放收起动画，动画结束后才移除浮层。
class NekoContextMenuOverlay extends StatefulWidget {
  const NekoContextMenuOverlay({
    super.key,
    required this.position,
    required this.items,
    required this.onDismiss,
    required this.onClosed,
    this.width = 160,
    this.preferAbove = false,
    this.alignRight = false,
  });

  final Offset position;
  final List<NekoContextMenuItem<dynamic>> items;
  final double width;
  final bool preferAbove;
  final bool alignRight;

  /// 请求关闭：会先触发收起动画。
  final VoidCallback onDismiss;

  /// 收起动画播完后的回调：真正把浮层从 Overlay 移除。
  final VoidCallback onClosed;

  @override
  State<NekoContextMenuOverlay> createState() => NekoContextMenuOverlayState();
}

class NekoContextMenuOverlayState extends State<NekoContextMenuOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 140),
    reverseDuration: const Duration(milliseconds: 120),
  );
  late final Animation<double> _anim = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOutCubic,
    reverseCurve: Curves.easeInCubic,
  );
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    _controller.forward();
  }

  /// 反向播放收起动画，结束后移除浮层；重复调用只生效一次。
  void close() {
    if (_closing) return;
    _closing = true;
    _controller.reverse().whenComplete(widget.onClosed);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.sizeOf(context);
    final textScaler = MediaQuery.textScalerOf(context);
    final textDirection = Directionality.of(context);
    final items = widget.items;
    final hasLeadingSlot = items.any((e) => e.icon != null || e.selected);
    const labelStyle = TextStyle(
      fontFamily: AppController.brandFontFamily,
      fontSize: 13,
      fontWeight: FontWeight.w400,
    );
    var maxTextWidth = 0.0;
    for (final item in items) {
      final painter = TextPainter(
        text: TextSpan(text: item.label, style: labelStyle),
        maxLines: 1,
        textDirection: textDirection,
        textScaler: textScaler,
      )..layout();
      if (painter.width > maxTextWidth) {
        maxTextWidth = painter.width;
      }
    }
    final horizontalChrome = 28.0 + (hasLeadingSlot ? 26.0 : 0.0) + 12.0;
    final maxAllowedWidth = math.max(widget.width, screenSize.width - 24.0);
    final menuWidth = math
        .max(widget.width, maxTextWidth + horizontalChrome)
        .clamp(widget.width, maxAllowedWidth);
    final dividerCount = items.where((e) => e.hasDividerBefore).length;
    final menuHeight = items.length * 34.0 + dividerCount * 9.0 + 10.0;

    double left = widget.alignRight
        ? widget.position.dx - menuWidth
        : widget.position.dx;
    if (left + menuWidth > screenSize.width - 12) {
      left = (screenSize.width - menuWidth - 12).clamp(12.0, double.infinity);
    }
    if (left < 12) {
      left = 12;
    }

    double top;
    bool openedAbove;
    if (widget.preferAbove) {
      final candidateTop = widget.position.dy - menuHeight;
      if (candidateTop >= 12) {
        top = candidateTop;
        openedAbove = true;
      } else {
        top = widget.position.dy.clamp(
          12.0,
          (screenSize.height - menuHeight - 12).clamp(12.0, double.infinity),
        );
        openedAbove = false;
      }
    } else if (widget.position.dy + menuHeight > screenSize.height - 12) {
      top = (widget.position.dy - menuHeight).clamp(12.0, double.infinity);
      openedAbove = true;
    } else {
      top = widget.position.dy.clamp(12.0, double.infinity);
      openedAbove = false;
    }

    final scaleAlignment = Alignment(
      widget.alignRight ? 1.0 : -1.0,
      openedAbove ? 1.0 : -1.0,
    );

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): widget.onDismiss,
      },
      child: Focus(
        autofocus: true,
        child: Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapDown: (_) => widget.onDismiss(),
                onSecondaryTapDown: (_) => widget.onDismiss(),
                child: const ColoredBox(color: Colors.transparent),
              ),
            ),
            Positioned(
              left: left,
              top: top,
              child: AnimatedBuilder(
                animation: _anim,
                builder: (context, child) {
                  final value = _anim.value.clamp(0.0, 1.0);
                  return Opacity(
                    opacity: value,
                    child: Transform.scale(
                      scale: 0.94 + 0.06 * value,
                      alignment: scaleAlignment,
                      child: child,
                    ),
                  );
                },
                child: Material(
                  elevation: 12,
                  shadowColor: Colors.black45,
                  color: const Color(0xFF2C2C2C),
                  borderRadius: BorderRadius.circular(8),
                  clipBehavior: Clip.antiAlias,
                  child: Container(
                    width: menuWidth,
                    padding: const EdgeInsets.symmetric(vertical: 5),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.14),
                        width: 0.8,
                      ),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (final item in items) ...[
                          if (item.hasDividerBefore)
                            Divider(
                              height: 9,
                              thickness: 0.8,
                              indent: 8,
                              endIndent: 8,
                              color: Colors.white.withValues(alpha: 0.12),
                            ),
                          _NekoContextMenuItemTile(
                            item: item,
                            hasLeadingSlot: hasLeadingSlot,
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NekoContextMenuItemTile extends StatefulWidget {
  const _NekoContextMenuItemTile({
    required this.item,
    required this.hasLeadingSlot,
  });

  final NekoContextMenuItem<dynamic> item;
  final bool hasLeadingSlot;

  @override
  State<_NekoContextMenuItemTile> createState() =>
      _NekoContextMenuItemTileState();
}

class _NekoContextMenuItemTileState extends State<_NekoContextMenuItemTile> {
  bool _isHovering = false;

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final enabled = item.enabled;
    final baseColor = !enabled
        ? Colors.white.withValues(alpha: 0.34)
        : item.destructive
        ? const Color(0xFFFF8A80)
        : Colors.white.withValues(alpha: 0.94);
    final iconColor = !enabled
        ? Colors.white.withValues(alpha: 0.32)
        : item.destructive
        ? const Color(0xFFFF8A80)
        : item.selected
        ? const Color(0xFF7CB7FF)
        : Colors.white.withValues(alpha: 0.88);
    final displayIcon = item.icon ?? (item.selected ? Icons.check_rounded : null);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        onEnter: enabled ? (_) => setState(() => _isHovering = true) : null,
        onExit: enabled ? (_) => setState(() => _isHovering = false) : null,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: enabled ? item.onTap : null,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 100),
            height: 32,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: enabled && _isHovering
                  ? Colors.white.withValues(alpha: 0.12)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(5),
            ),
            child: Row(
              children: [
                if (widget.hasLeadingSlot) ...[
                  SizedBox(
                    width: 16,
                    child: displayIcon != null
                        ? Icon(displayIcon, size: 16, color: iconColor)
                        : null,
                  ),
                  const SizedBox(width: 10),
                ],
                Expanded(
                  child: Text(
                    item.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: AppController.brandFontFamily,
                      fontSize: 13,
                      fontWeight: FontWeight.w400,
                      color: baseColor,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
