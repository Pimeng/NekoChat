import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/models/models.dart';
import '../../core/text/pinyin_search.dart';
import '../common/smooth_dialog.dart';

enum StickerPickerTab { emoji, favorites }

/// 聊天输入框的表情与收藏表情弹出面板。
///
/// 布局参考主流桌面聊天软件：上方为表情网格（收藏页首格为虚线 `+` 添加按钮），
/// 底部为分类切换栏（常用 Emoji / 收藏表情）。
class StickerPickerPanel extends StatefulWidget {
  const StickerPickerPanel({
    super.key,
    required this.stickers,
    required this.onSelectSticker,
    required this.onPickStickers,
    required this.onRemoveSticker,
    required this.onSelectEmoji,
    this.onReorderStickers,
    this.onEditStickerRemark,
    this.initialTab = StickerPickerTab.favorites,
    this.onTabChanged,
  });

  final List<FavoriteSticker> stickers;
  final Future<void> Function(FavoriteSticker sticker) onSelectSticker;
  final Future<int> Function() onPickStickers;
  final Future<void> Function(FavoriteSticker sticker) onRemoveSticker;
  final Future<void> Function(int oldIndex, int newIndex)? onReorderStickers;
  final Future<void> Function(FavoriteSticker sticker)? onEditStickerRemark;
  final ValueChanged<String> onSelectEmoji;
  final StickerPickerTab initialTab;
  final ValueChanged<StickerPickerTab>? onTabChanged;

  static const double preferredWidth = 420;
  static const double preferredHeight = 356;

  @override
  State<StickerPickerPanel> createState() => _StickerPickerPanelState();
}

class _StickerPickerPanelState extends State<StickerPickerPanel> {
  late StickerPickerTab _tab = widget.initialTab;

  static const List<String> _commonEmojis = [
    '😀', '😁', '😂', '🤣', '😊', '😇', '🙂', '😉',
    '😍', '🥰', '😘', '😋', '😜', '🤪', '🤩', '🥳',
    '😎', '🤓', '🧐', '😏', '😒', '🙄', '😬', '😮',
    '😯', '😲', '😳', '🥺', '😢', '😭', '😤', '😠',
    '😡', '🤯', '😱', '😨', '😰', '🤔', '🤭', '🤫',
    '🤥', '😶', '😐', '😴', '🤤', '🤮', '🤧', '🤒',
    '👍', '👎', '👌', '✌️', '🤞', '👏', '🙌', '🙏',
    '🤝', '💪', '❤️', '🧡', '💛', '💚', '💙', '💜',
    '💔', '✨', '🔥', '🎉', '🎊', '💯', '🐱', '🐶',
    '🦊', '🐼', '🐸', '☕', '🍵', '🍰', '🍺', '🌙',
  ];

  void _selectTab(StickerPickerTab tab) {
    if (_tab == tab) return;
    setState(() => _tab = tab);
    widget.onTabChanged?.call(tab);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final panelColor = isDark
        ? colorScheme.surfaceContainerHigh
        : colorScheme.surface;

    return Material(
      color: Colors.transparent,
      child: Container(
        key: const ValueKey('sticker-picker-panel'),
        width: StickerPickerPanel.preferredWidth,
        height: StickerPickerPanel.preferredHeight,
        decoration: BoxDecoration(
          color: panelColor,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: colorScheme.outlineVariant.withValues(alpha: 0.7),
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: isDark ? 0.42 : 0.14),
              blurRadius: 24,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            Expanded(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 150),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                transitionBuilder: (child, animation) => FadeTransition(
                  opacity: animation,
                  child: child,
                ),
                child: _tab == StickerPickerTab.favorites
                    ? _buildFavoritesGrid(context)
                    : _buildEmojiGrid(context),
              ),
            ),
            Divider(
              height: 1,
              thickness: 1,
              color: colorScheme.outlineVariant.withValues(alpha: 0.5),
            ),
            _buildBottomBar(context),
          ],
        ),
      ),
    );
  }

  Widget _buildFavoritesGrid(BuildContext context) {
    return GridView.builder(
      key: const ValueKey('favorite-stickers-grid'),
      padding: const EdgeInsets.all(12),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 6,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
        childAspectRatio: 1,
      ),
      itemCount: widget.stickers.length + 1,
      itemBuilder: (context, index) {
        if (index == 0) {
          return _AddStickerTile(
            onTap: () => unawaited(widget.onPickStickers()),
          );
        }
        final stickerIndex = index - 1;
        final sticker = widget.stickers[stickerIndex];
        return _FavoriteStickerTile(
          key: ValueKey('sticker-tile-${sticker.stickerId}'),
          sticker: sticker,
          index: stickerIndex,
          canReorder:
              widget.onReorderStickers != null && widget.stickers.length > 1,
          onTap: () => unawaited(widget.onSelectSticker(sticker)),
          onRemove: () => unawaited(widget.onRemoveSticker(sticker)),
          onEditRemark: widget.onEditStickerRemark == null
              ? null
              : () => unawaited(widget.onEditStickerRemark!(sticker)),
          onMoveToFront:
              widget.onReorderStickers != null && stickerIndex > 0
              ? () => unawaited(widget.onReorderStickers!(stickerIndex, 0))
              : null,
          onAcceptDrop: widget.onReorderStickers == null
              ? null
              : (fromIndex) =>
                    unawaited(widget.onReorderStickers!(fromIndex, stickerIndex)),
        );
      },
    );
  }

  Widget _buildEmojiGrid(BuildContext context) {
    return GridView.builder(
      key: const ValueKey('common-emojis-grid'),
      padding: const EdgeInsets.all(12),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 8,
        crossAxisSpacing: 4,
        mainAxisSpacing: 4,
        childAspectRatio: 1,
      ),
      itemCount: _commonEmojis.length,
      itemBuilder: (context, index) {
        final emoji = _commonEmojis[index];
        return _EmojiTile(
          emoji: emoji,
          onTap: () => widget.onSelectEmoji(emoji),
        );
      },
    );
  }

  Widget _buildBottomBar(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      height: 46,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Row(
        children: [
          _TabButton(
            key: const ValueKey('sticker-tab-emoji'),
            tooltip: '常用表情',
            icon: Icons.sentiment_satisfied_alt_outlined,
            selected: _tab == StickerPickerTab.emoji,
            onTap: () => _selectTab(StickerPickerTab.emoji),
          ),
          const SizedBox(width: 6),
          _TabButton(
            key: const ValueKey('sticker-tab-favorites'),
            tooltip: '收藏表情',
            icon: _tab == StickerPickerTab.favorites
                ? Icons.favorite_rounded
                : Icons.favorite_border_rounded,
            selected: _tab == StickerPickerTab.favorites,
            onTap: () => _selectTab(StickerPickerTab.favorites),
          ),
          const Spacer(),
          if (_tab == StickerPickerTab.favorites)
            Text(
              widget.stickers.isEmpty
                  ? '点击 + 添加表情'
                  : widget.onReorderStickers != null &&
                        widget.stickers.length > 1
                  ? '${widget.stickers.length} 个收藏 · 拖动排序 · 右键管理'
                  : '${widget.stickers.length} 个收藏 · 右键管理',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
    );
  }
}

class _TabButton extends StatefulWidget {
  const _TabButton({
    super.key,
    required this.tooltip,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final String tooltip;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_TabButton> createState() => _TabButtonState();
}

class _TabButtonState extends State<_TabButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final background = widget.selected
        ? colorScheme.secondaryContainer
        : _hovered
        ? colorScheme.onSurface.withValues(alpha: 0.08)
        : Colors.transparent;
    final foreground = widget.selected
        ? colorScheme.onSecondaryContainer
        : colorScheme.onSurfaceVariant;

    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            width: 38,
            height: 32,
            decoration: BoxDecoration(
              color: background,
              borderRadius: BorderRadius.circular(8),
            ),
            alignment: Alignment.center,
            child: Icon(widget.icon, size: 20, color: foreground),
          ),
        ),
      ),
    );
  }
}

class _AddStickerTile extends StatefulWidget {
  const _AddStickerTile({required this.onTap});

  final VoidCallback onTap;

  @override
  State<_AddStickerTile> createState() => _AddStickerTileState();
}

class _AddStickerTileState extends State<_AddStickerTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: '添加本地图片到表情',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          key: const ValueKey('add-sticker-button'),
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: CustomPaint(
            painter: _DashedRoundedRectPainter(
              color: _hovered
                  ? colorScheme.primary.withValues(alpha: 0.8)
                  : colorScheme.outlineVariant,
              radius: 8,
            ),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              decoration: BoxDecoration(
                color: _hovered
                    ? colorScheme.primary.withValues(alpha: 0.08)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(8),
              ),
              alignment: Alignment.center,
              child: Icon(
                Icons.add_rounded,
                size: 26,
                color: _hovered
                    ? colorScheme.primary
                    : colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _FavoriteStickerTile extends StatefulWidget {
  const _FavoriteStickerTile({
    super.key,
    required this.sticker,
    required this.index,
    required this.canReorder,
    required this.onTap,
    required this.onRemove,
    this.onEditRemark,
    this.onMoveToFront,
    this.onAcceptDrop,
  });

  final FavoriteSticker sticker;
  final int index;
  final bool canReorder;
  final VoidCallback onTap;
  final VoidCallback onRemove;
  final VoidCallback? onEditRemark;
  final VoidCallback? onMoveToFront;
  final ValueChanged<int>? onAcceptDrop;

  @override
  State<_FavoriteStickerTile> createState() => _FavoriteStickerTileState();
}

class _FavoriteStickerTileState extends State<_FavoriteStickerTile> {
  bool _hovered = false;
  VoidCallback? _removeMenuOverlay;

  @override
  void dispose() {
    _removeMenuOverlay?.call();
    super.dispose();
  }

  void _showContextMenu(TapDownDetails details) {
    _removeMenuOverlay?.call();
    final overlay = Overlay.of(context);
    final menuKey = GlobalKey<_StickerContextMenuOverlayState>();
    late final OverlayEntry entry;
    var removed = false;

    void hardRemove() {
      if (removed) return;
      removed = true;
      if (entry.mounted) entry.remove();
      if (identical(_removeMenuOverlay, hardRemove)) _removeMenuOverlay = null;
    }

    void dismiss() {
      final state = menuKey.currentState;
      if (state != null) {
        state.close();
      } else {
        hardRemove();
      }
    }

    entry = OverlayEntry(
      builder: (_) => _StickerContextMenuOverlay(
        key: menuKey,
        position: details.globalPosition,
        hasRemark:
            widget.sticker.remark != null &&
            widget.sticker.remark!.trim().isNotEmpty,
        onDismiss: dismiss,
        onClosed: hardRemove,
        onMoveToFront: widget.onMoveToFront == null
            ? null
            : () {
                dismiss();
                widget.onMoveToFront!();
              },
        onEditRemark: widget.onEditRemark == null
            ? null
            : () {
                dismiss();
                widget.onEditRemark!();
              },
        onRemove: () {
          dismiss();
          widget.onRemove();
        },
      ),
    );
    _removeMenuOverlay = hardRemove;
    overlay.insert(entry);
  }

  Widget _buildImage(ColorScheme colorScheme) => Image.file(
    File(widget.sticker.filePath),
    fit: BoxFit.cover,
    filterQuality: FilterQuality.medium,
    errorBuilder: (_, _, _) => Icon(
      Icons.broken_image_outlined,
      size: 20,
      color: colorScheme.onSurfaceVariant,
    ),
  );

  Widget _buildTile(
    BuildContext context, {
    required bool isDropTarget,
    bool dimmed = false,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    return Opacity(
      opacity: dimmed ? 0.3 : 1.0,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          onSecondaryTapDown: _showContextMenu,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: isDropTarget
                    ? colorScheme.primary
                    : _hovered
                    ? colorScheme.primary.withValues(alpha: 0.7)
                    : Colors.transparent,
                width: isDropTarget ? 2 : 1.5,
              ),
              color: isDropTarget
                  ? colorScheme.primary.withValues(alpha: 0.14)
                  : colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
            ),
            clipBehavior: Clip.antiAlias,
            child: Stack(
              fit: StackFit.expand,
              children: [
                _buildImage(colorScheme),
                if (_hovered &&
                    !dimmed &&
                    widget.sticker.remark != null &&
                    widget.sticker.remark!.trim().isNotEmpty)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: IgnorePointer(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 3,
                          vertical: 1.5,
                        ),
                        color: Colors.black.withValues(alpha: 0.65),
                        child: Text(
                          widget.sticker.remark!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 10,
                            color: Colors.white,
                            height: 1.15,
                          ),
                        ),
                      ),
                    ),
                  ),
                if (_hovered && !dimmed)
                  Positioned(
                    top: 2,
                    right: 2,
                    child: GestureDetector(
                      onTap: widget.onRemove,
                      child: Container(
                        width: 18,
                        height: 18,
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.65),
                          shape: BoxShape.circle,
                        ),
                        alignment: Alignment.center,
                        child: const Icon(
                          Icons.close_rounded,
                          size: 12,
                          color: Colors.white,
                        ),
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

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    if (!widget.canReorder) {
      return _buildTile(context, isDropTarget: false);
    }

    return DragTarget<int>(
      onWillAcceptWithDetails: (details) => details.data != widget.index,
      onAcceptWithDetails: (details) => widget.onAcceptDrop?.call(details.data),
      builder: (context, candidateData, rejectedData) {
        final isDropTarget = candidateData.isNotEmpty;
        return Draggable<int>(
          data: widget.index,
          dragAnchorStrategy: pointerDragAnchorStrategy,
          feedback: Transform.translate(
            offset: const Offset(-30, -30),
            child: Material(
              color: Colors.transparent,
              elevation: 8,
              borderRadius: BorderRadius.circular(8),
              child: Opacity(
                opacity: 0.9,
                child: Container(
                  width: 60,
                  height: 60,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: colorScheme.primary,
                      width: 1.5,
                    ),
                    color: colorScheme.surfaceContainerHighest,
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: _buildImage(colorScheme),
                ),
              ),
            ),
          ),
          childWhenDragging: _buildTile(
            context,
            isDropTarget: false,
            dimmed: true,
          ),
          child: _buildTile(context, isDropTarget: isDropTarget),
        );
      },
    );
  }
}

class _EmojiTile extends StatefulWidget {
  const _EmojiTile({required this.emoji, required this.onTap});

  final String emoji;
  final VoidCallback onTap;

  @override
  State<_EmojiTile> createState() => _EmojiTileState();
}

class _EmojiTileState extends State<_EmojiTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 100),
          decoration: BoxDecoration(
            color: _hovered
                ? colorScheme.onSurface.withValues(alpha: 0.08)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          alignment: Alignment.center,
          child: Text(
            widget.emoji,
            style: const TextStyle(fontSize: 22),
          ),
        ),
      ),
    );
  }
}

class _DashedRoundedRectPainter extends CustomPainter {
  const _DashedRoundedRectPainter({
    required this.color,
    required this.radius,
  });

  final Color color;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.2
      ..style = PaintingStyle.stroke;
    final rect = Offset.zero & size;
    final rrect = RRect.fromRectAndRadius(
      rect.deflate(1),
      Radius.circular(radius),
    );
    final path = Path()..addRRect(rrect);
    const dashLength = 4.5;
    const gapLength = 3.5;
    for (final metric in path.computeMetrics()) {
      var distance = 0.0;
      while (distance < metric.length) {
        final next = math.min(distance + dashLength, metric.length);
        canvas.drawPath(metric.extractPath(distance, next), paint);
        distance += dashLength + gapLength;
      }
    }
  }

  @override
  bool shouldRepaint(_DashedRoundedRectPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.radius != radius;
}

/// 带入场/出场动画的表情选择浮层容器。
class StickerPickerOverlay extends StatefulWidget {
  const StickerPickerOverlay({
    super.key,
    required this.anchor,
    required this.onDismiss,
    required this.onClosed,
    required this.child,
  });

  final Offset anchor;
  final VoidCallback onDismiss;
  final VoidCallback onClosed;
  final Widget child;

  @override
  State<StickerPickerOverlay> createState() => StickerPickerOverlayState();
}

class StickerPickerOverlayState extends State<StickerPickerOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 170),
    reverseDuration: const Duration(milliseconds: 130),
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

  /// 反向播放收起动画，结束后移除浮层；重复调用安全。
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
    final screen = MediaQuery.sizeOf(context);
    const margin = 12.0;
    final panelWidth = StickerPickerPanel.preferredWidth.clamp(
      240.0,
      screen.width - margin * 2,
    );
    final panelHeight = StickerPickerPanel.preferredHeight.clamp(
      200.0,
      screen.height - margin * 2,
    );
    final left = widget.anchor.dx.clamp(
      margin,
      (screen.width - panelWidth - margin).clamp(margin, double.infinity),
    );
    final top = (widget.anchor.dy - panelHeight - 10).clamp(
      margin,
      (screen.height - panelHeight - margin).clamp(margin, double.infinity),
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
                behavior: HitTestBehavior.translucent,
                onTap: widget.onDismiss,
                onSecondaryTapDown: (_) => widget.onDismiss(),
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
                    child: Transform.translate(
                      offset: Offset(0, (1.0 - value) * 10),
                      child: Transform.scale(
                        scale: 0.92 + 0.08 * value,
                        alignment: Alignment.bottomLeft,
                        child: child,
                      ),
                    ),
                  );
                },
                child: SizedBox(
                  width: panelWidth,
                  height: panelHeight,
                  child: widget.child,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 收藏表情右键菜单浮层：直接插入到 Overlay 顶层，保证层级高于表情选择面板，
/// 样式与消息右键菜单保持一致，带平滑入场/出场动画。
class _StickerContextMenuOverlay extends StatefulWidget {
  const _StickerContextMenuOverlay({
    super.key,
    required this.position,
    required this.onDismiss,
    required this.onClosed,
    required this.onRemove,
    this.hasRemark = false,
    this.onMoveToFront,
    this.onEditRemark,
  });

  final Offset position;
  final VoidCallback onDismiss;
  final VoidCallback onClosed;
  final VoidCallback onRemove;
  final bool hasRemark;
  final VoidCallback? onMoveToFront;
  final VoidCallback? onEditRemark;

  @override
  State<_StickerContextMenuOverlay> createState() =>
      _StickerContextMenuOverlayState();
}

class _StickerContextMenuOverlayState extends State<_StickerContextMenuOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 140),
    reverseDuration: const Duration(milliseconds: 110),
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
    final screen = MediaQuery.sizeOf(context);
    const menuWidth = 148.0;
    final itemCount =
        1 +
        (widget.onMoveToFront != null ? 1 : 0) +
        (widget.onEditRemark != null ? 1 : 0);
    final menuHeight = itemCount * 34.0 + 10.0;
    final left = widget.position.dx.clamp(
      12.0,
      (screen.width - menuWidth - 12.0).clamp(12.0, double.infinity),
    );
    final top = widget.position.dy + menuHeight > screen.height - 12
        ? (widget.position.dy - menuHeight).clamp(12.0, double.infinity)
        : widget.position.dy.clamp(12.0, double.infinity);

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
                      alignment: Alignment.topLeft,
                      child: child,
                    ),
                  );
                },
                child: Material(
                  elevation: 14,
                  shadowColor: Colors.black45,
                  color: const Color(0xFF2C2C2C),
                  borderRadius: BorderRadius.circular(8),
                  clipBehavior: Clip.antiAlias,
                  child: Container(
                    width: menuWidth,
                    padding: const EdgeInsets.all(5),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.08),
                      ),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (widget.onMoveToFront != null)
                          _StickerMenuActionTile(
                            icon: Icons.vertical_align_top_rounded,
                            label: '移到最前',
                            onTap: widget.onMoveToFront!,
                          ),
                        if (widget.onEditRemark != null)
                          _StickerMenuActionTile(
                            icon: Icons.edit_note_rounded,
                            label: widget.hasRemark ? '修改备注' : '设置备注',
                            onTap: widget.onEditRemark!,
                          ),
                        _StickerMenuActionTile(
                          icon: Icons.delete_outline_rounded,
                          label: '移出收藏表情',
                          onTap: widget.onRemove,
                        ),
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

class _StickerMenuActionTile extends StatefulWidget {
  const _StickerMenuActionTile({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  State<_StickerMenuActionTile> createState() => _StickerMenuActionTileState();
}

class _StickerMenuActionTileState extends State<_StickerMenuActionTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 100),
          height: 34,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: _hovered
                ? Colors.white.withValues(alpha: 0.1)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(5),
          ),
          child: Row(
            children: [
              Icon(widget.icon, size: 17, color: const Color(0xFFEAEAEA)),
              const SizedBox(width: 8),
              Text(
                widget.label,
                style: const TextStyle(
                  fontSize: 13,
                  color: Color(0xFFEAEAEA),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 弹出编辑表情备注对话框。返回 `null` 表示取消；返回 `(remark: ...)` 表示确认保存
/// （其中 `remark` 为 `null` 或空串表示清除备注）。
Future<({String? remark})?> showStickerRemarkDialog(
  BuildContext context,
  FavoriteSticker sticker,
) => showNekoDialog<({String? remark})>(
  context: context,
  builder: (_) => _StickerRemarkDialog(sticker: sticker),
);

class _StickerRemarkDialog extends StatefulWidget {
  const _StickerRemarkDialog({required this.sticker});

  final FavoriteSticker sticker;

  @override
  State<_StickerRemarkDialog> createState() => _StickerRemarkDialogState();
}

class _StickerRemarkDialogState extends State<_StickerRemarkDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.sticker.remark ?? '',
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final text = _controller.text.trim();
    Navigator.of(context).pop((remark: text.isEmpty ? null : text));
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final hasRemark =
        widget.sticker.remark != null &&
        widget.sticker.remark!.trim().isNotEmpty;
    return AlertDialog(
      title: Text(hasRemark ? '修改表情备注' : '设置表情备注'),
      content: SizedBox(
        width: 340,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: colorScheme.outlineVariant),
                    color: colorScheme.surfaceContainerHighest.withValues(
                      alpha: 0.4,
                    ),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Image.file(
                    File(widget.sticker.filePath),
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => Icon(
                      Icons.broken_image_outlined,
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    '在聊天输入框中输入备注关键词，即可快捷弹出该表情并一键发送（支持空格分隔多个关键词）。',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            TextField(
              key: const ValueKey('sticker-remark-field'),
              controller: _controller,
              autofocus: true,
              maxLength: 24,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _submit(),
              decoration: const InputDecoration(
                labelText: '表情备注',
                hintText: '例如：开心 / 琪露诺 / 疑惑（留空可清除）',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const ValueKey('sticker-remark-save'),
          onPressed: _submit,
          child: const Text('保存'),
        ),
      ],
    );
  }
}

/// 根据输入框文本匹配设置了备注的收藏表情。
///
/// 排序规则：完全匹配 > 关键词前缀匹配 > 子串匹配，同级保持原有收藏排序。
List<FavoriteSticker> matchStickersByRemark(
  List<FavoriteSticker> stickers,
  String rawQuery,
) {
  final query = rawQuery.trim();
  if (query.isEmpty || query.length > 24 || query.startsWith('@')) {
    return const [];
  }
  final scored = <(FavoriteSticker sticker, int score, int order)>[];
  for (var i = 0; i < stickers.length; i++) {
    final sticker = stickers[i];
    final remark = sticker.remark?.trim();
    if (remark == null || remark.isEmpty) continue;
    final tokens = remark
        .split(RegExp(r'[\s,，、/]+'))
        .where((token) => token.isNotEmpty)
        .toList();
    var bestScore = pinyinMatchScore(remark, query);
    for (final token in tokens) {
      final tokenScore = pinyinMatchScore(token, query);
      if (tokenScore != null && (bestScore == null || tokenScore < bestScore)) {
        bestScore = tokenScore;
      }
    }
    if (bestScore != null) {
      scored.add((sticker, bestScore, i));
    }
  }
  scored.sort((a, b) {
    final byScore = a.$2.compareTo(b.$2);
    return byScore != 0 ? byScore : a.$3.compareTo(b.$3);
  });
  return [for (final item in scored) item.$1];
}

/// 输入备注关键词时在输入框上方弹出的快捷表情候选栏。
class QuickStickerSuggestionBar extends StatelessWidget {
  const QuickStickerSuggestionBar({
    super.key,
    required this.stickers,
    required this.onSelect,
    required this.onDismiss,
  });

  final List<FavoriteSticker> stickers;
  final Future<void> Function(FavoriteSticker sticker) onSelect;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    return Container(
      key: const ValueKey('quick-sticker-suggestion-bar'),
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
      decoration: BoxDecoration(
        color: isDark
            ? colorScheme.surfaceContainerHigh
            : colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: colorScheme.outlineVariant.withValues(alpha: 0.7),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: SizedBox(
              height: 76,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: stickers.length,
                separatorBuilder: (_, _) => const SizedBox(width: 8),
                itemBuilder: (context, index) {
                  final sticker = stickers[index];
                  return _QuickStickerCandidate(
                    key: ValueKey('quick-sticker-${sticker.stickerId}'),
                    sticker: sticker,
                    onTap: () => unawaited(onSelect(sticker)),
                  );
                },
              ),
            ),
          ),
          const SizedBox(width: 4),
          IconButton(
            key: const ValueKey('quick-sticker-dismiss'),
            tooltip: '关闭表情联想',
            visualDensity: VisualDensity.compact,
            onPressed: onDismiss,
            icon: Icon(
              Icons.close_rounded,
              size: 18,
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _QuickStickerCandidate extends StatefulWidget {
  const _QuickStickerCandidate({
    super.key,
    required this.sticker,
    required this.onTap,
  });

  final FavoriteSticker sticker;
  final VoidCallback onTap;

  @override
  State<_QuickStickerCandidate> createState() => _QuickStickerCandidateState();
}

class _QuickStickerCandidateState extends State<_QuickStickerCandidate> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final remark = widget.sticker.remark ?? '';
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 110),
          width: 62,
          padding: const EdgeInsets.fromLTRB(4, 3, 4, 2),
          decoration: BoxDecoration(
            color: _hovered
                ? colorScheme.primary.withValues(alpha: 0.1)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: _hovered
                  ? colorScheme.primary.withValues(alpha: 0.65)
                  : Colors.transparent,
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: AspectRatio(
                    aspectRatio: 1,
                    child: Image.file(
                      File(widget.sticker.filePath),
                      fit: BoxFit.cover,
                      filterQuality: FilterQuality.medium,
                      errorBuilder: (_, _, _) => Icon(
                        Icons.broken_image_outlined,
                        size: 20,
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 2),
              Text(
                remark,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  fontSize: 10.5,
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
