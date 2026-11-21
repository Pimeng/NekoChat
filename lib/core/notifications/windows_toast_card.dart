import 'package:flutter/material.dart';

import 'standalone_notification_controller.dart';

/// 仿 Windows 11 原生 Toast 样式的独立通知卡片组件。
///
/// 既可作为独立多视图通知窗口的根内容，也可直接嵌入组件预览或测试中展示。
class WindowsNotificationSurface extends StatefulWidget {
  const WindowsNotificationSurface({
    super.key,
    required this.items,
    required this.onItemTap,
    required this.onItemDismiss,
    required this.onDismissAll,
    this.onHoverChanged,
    this.darkMode = false,
    this.borderRadius = 8.0,
    this.showShadow = false,
    this.showBorder = true,
  });

  /// Windows 11 原生 Toast 标准宽度。
  static const double toastWidth = 364.0;
  static const double _headerHeight = 36.0;
  static const double _singleRowHeight = 76.0;
  static const double _stackedRowHeight = 74.0;
  static const double _dividerHeight = 1.0;
  static const double _verticalBorder = 2.0;

  /// 根据通知条数计算精确逻辑高度，供原生窗口调整尺寸避免滚动或裁剪。
  static double computeSurfaceHeight(int itemCount) {
    if (itemCount <= 1) {
      return _headerHeight + _singleRowHeight + _verticalBorder;
    }
    return _headerHeight +
        itemCount * _stackedRowHeight +
        (itemCount - 1) * _dividerHeight +
        _verticalBorder;
  }

  final List<StandaloneNotificationItem> items;
  final ValueChanged<String> onItemTap;
  final ValueChanged<String> onItemDismiss;
  final VoidCallback onDismissAll;
  final ValueChanged<bool>? onHoverChanged;
  final bool darkMode;

  /// 原生独立窗口已由 DWM 提供圆角与阴影，默认 8px 仅作内容裁剪；
  /// 在组件预览等非独立窗口场景中可开启 [showShadow]。
  final double borderRadius;
  final bool showShadow;
  final bool showBorder;

  @override
  State<WindowsNotificationSurface> createState() =>
      _WindowsNotificationSurfaceState();
}

class _WindowsNotificationSurfaceState
    extends State<WindowsNotificationSurface> {
  bool _headerCloseHovered = false;
  bool _clearAllHovered = false;

  @override
  Widget build(BuildContext context) {
    final palette = _WindowsToastPalette.of(widget.darkMode);
    final items = widget.items;
    final appName = items.isNotEmpty ? items.first.appName : 'NekoChat';
    final isStacked = items.length > 1;
    final surfaceHeight = WindowsNotificationSurface.computeSurfaceHeight(
      items.length,
    );

    return MouseRegion(
      onEnter: (_) => widget.onHoverChanged?.call(true),
      onExit: (_) => widget.onHoverChanged?.call(false),
      child: Container(
        width: WindowsNotificationSurface.toastWidth,
        height: surfaceHeight,
        decoration: BoxDecoration(
          color: palette.background,
          borderRadius: BorderRadius.circular(widget.borderRadius),
          border: widget.showBorder
              ? Border.all(color: palette.border, width: 1)
              : null,
          boxShadow: widget.showShadow
              ? [
                  BoxShadow(
                    color: Colors.black.withValues(
                      alpha: widget.darkMode ? 0.42 : 0.16,
                    ),
                    blurRadius: 24,
                    offset: const Offset(0, 8),
                  ),
                  BoxShadow(
                    color: Colors.black.withValues(
                      alpha: widget.darkMode ? 0.24 : 0.06,
                    ),
                    blurRadius: 4,
                    offset: const Offset(0, 1),
                  ),
                ]
              : null,
        ),
        clipBehavior: Clip.antiAlias,
        child: Material(
          type: MaterialType.transparency,
          child: Column(
            children: [
              _buildHeader(palette, appName, isStacked, items.length),
              if (items.length == 1)
                Expanded(
                  child: _WindowsToastRow(
                    item: items.first,
                    palette: palette,
                    showItemClose: false,
                    onTap: () => widget.onItemTap(items.first.identifier),
                    onDismiss: () =>
                        widget.onItemDismiss(items.first.identifier),
                  ),
                )
              else
                for (var i = 0; i < items.length; i++) ...[
                  if (i > 0)
                    Container(
                      height: WindowsNotificationSurface._dividerHeight,
                      color: palette.divider,
                    ),
                  Expanded(
                    child: _WindowsToastRow(
                      item: items[i],
                      palette: palette,
                      showItemClose: true,
                      onTap: () => widget.onItemTap(items[i].identifier),
                      onDismiss: () =>
                          widget.onItemDismiss(items[i].identifier),
                    ),
                  ),
                ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(
    _WindowsToastPalette palette,
    String appName,
    bool isStacked,
    int count,
  ) {
    return SizedBox(
      height: WindowsNotificationSurface._headerHeight,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 6, 8, 0),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(3.5),
              child: Image.asset(
                'assets/app.png',
                width: 16,
                height: 16,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                cacheWidth: 32,
                cacheHeight: 32,
                errorBuilder: (_, _, _) => Container(
                  width: 16,
                  height: 16,
                  decoration: BoxDecoration(
                    color: palette.accent,
                    borderRadius: BorderRadius.circular(3.5),
                  ),
                  child: const Icon(
                    Icons.chat_bubble_rounded,
                    size: 10,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                isStacked ? '$appName · $count 条新通知' : appName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w400,
                  color: palette.appLabel,
                  height: 1.2,
                ),
              ),
            ),
            if (isStacked) ...[
              MouseRegion(
                cursor: SystemMouseCursors.click,
                onEnter: (_) => setState(() => _clearAllHovered = true),
                onExit: (_) => setState(() => _clearAllHovered = false),
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: widget.onDismissAll,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 7,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: _clearAllHovered
                          ? palette.closeHoverBg
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      '全部清除',
                      style: TextStyle(
                        fontSize: 11.5,
                        color: palette.appLabel,
                        height: 1.2,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 2),
            ],
            MouseRegion(
              cursor: SystemMouseCursors.click,
              onEnter: (_) => setState(() => _headerCloseHovered = true),
              onExit: (_) => setState(() => _headerCloseHovered = false),
              child: Tooltip(
                message: isStacked ? '关闭全部通知' : '关闭通知',
                waitDuration: const Duration(milliseconds: 500),
                child: GestureDetector(
                  key: const ValueKey('windows-toast-close-all'),
                  behavior: HitTestBehavior.opaque,
                  onTap: widget.onDismissAll,
                  child: Container(
                    width: 26,
                    height: 26,
                    decoration: BoxDecoration(
                      color: _headerCloseHovered
                          ? palette.closeHoverBg
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    alignment: Alignment.center,
                    child: Icon(
                      Icons.close_rounded,
                      size: 15,
                      color: palette.closeIcon,
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

class _WindowsToastRow extends StatefulWidget {
  const _WindowsToastRow({
    required this.item,
    required this.palette,
    required this.showItemClose,
    required this.onTap,
    required this.onDismiss,
  });

  final StandaloneNotificationItem item;
  final _WindowsToastPalette palette;
  final bool showItemClose;
  final VoidCallback onTap;
  final VoidCallback onDismiss;

  @override
  State<_WindowsToastRow> createState() => _WindowsToastRowState();
}

class _WindowsToastRowState extends State<_WindowsToastRow> {
  bool _hovered = false;
  bool _closeHovered = false;

  String _badgeGlyph(String title) {
    final trimmed = title.trim();
    if (trimmed.isEmpty) return 'N';
    return String.fromCharCode(trimmed.runes.first).toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final palette = widget.palette;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          color: _hovered ? palette.rowHoverBg : Colors.transparent,
          padding: const EdgeInsets.fromLTRB(14, 2, 12, 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: palette.avatarBg,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: palette.avatarBorder, width: 1),
                ),
                alignment: Alignment.center,
                child: Text(
                  _badgeGlyph(widget.item.title),
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: palette.accent,
                    height: 1.0,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.item.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: palette.title,
                        height: 1.25,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Flexible(
                      child: Text(
                        widget.item.body,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w400,
                          color: palette.body,
                          height: 1.32,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              if (widget.showItemClose) ...[
                const SizedBox(width: 4),
                Opacity(
                  opacity: _hovered ? 1.0 : 0.0,
                  child: MouseRegion(
                    cursor: SystemMouseCursors.click,
                    onEnter: (_) => setState(() => _closeHovered = true),
                    onExit: (_) => setState(() => _closeHovered = false),
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: widget.onDismiss,
                      child: Container(
                        width: 24,
                        height: 24,
                        decoration: BoxDecoration(
                          color: _closeHovered
                              ? palette.closeHoverBg
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        alignment: Alignment.center,
                        child: Icon(
                          Icons.close_rounded,
                          size: 14,
                          color: palette.closeIcon,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _WindowsToastPalette {
  const _WindowsToastPalette({
    required this.background,
    required this.border,
    required this.divider,
    required this.appLabel,
    required this.title,
    required this.body,
    required this.rowHoverBg,
    required this.closeIcon,
    required this.closeHoverBg,
    required this.accent,
    required this.avatarBg,
    required this.avatarBorder,
  });

  final Color background;
  final Color border;
  final Color divider;
  final Color appLabel;
  final Color title;
  final Color body;
  final Color rowHoverBg;
  final Color closeIcon;
  final Color closeHoverBg;
  final Color accent;
  final Color avatarBg;
  final Color avatarBorder;

  static _WindowsToastPalette of(bool dark) {
    if (dark) {
      return const _WindowsToastPalette(
        background: Color(0xFF2B2B2B),
        border: Color(0x1FFFFFFF),
        divider: Color(0x16FFFFFF),
        appLabel: Color(0xB3FFFFFF),
        title: Color(0xF5FFFFFF),
        body: Color(0xC2FFFFFF),
        rowHoverBg: Color(0x0DFFFFFF),
        closeIcon: Color(0xB3FFFFFF),
        closeHoverBg: Color(0x1AFFFFFF),
        accent: Color(0xFF7B96FF),
        avatarBg: Color(0x247B96FF),
        avatarBorder: Color(0x337B96FF),
      );
    }
    return const _WindowsToastPalette(
      background: Color(0xFFF6F6F6),
      border: Color(0x18000000),
      divider: Color(0x12000000),
      appLabel: Color(0x9E000000),
      title: Color(0xE8000000),
      body: Color(0xA6000000),
      rowHoverBg: Color(0x08000000),
      closeIcon: Color(0x99000000),
      closeHoverBg: Color(0x12000000),
      accent: Color(0xFF4666E5),
      avatarBg: Color(0x164666E5),
      avatarBorder: Color(0x264666E5),
    );
  }
}
