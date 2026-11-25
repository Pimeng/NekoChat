import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../core/models/models.dart';

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
    this.initialTab = StickerPickerTab.favorites,
    this.onTabChanged,
  });

  final List<FavoriteSticker> stickers;
  final Future<void> Function(FavoriteSticker sticker) onSelectSticker;
  final Future<int> Function() onPickStickers;
  final Future<void> Function(FavoriteSticker sticker) onRemoveSticker;
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
              child: _tab == StickerPickerTab.favorites
                  ? _buildFavoritesGrid(context)
                  : _buildEmojiGrid(context),
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
        final sticker = widget.stickers[index - 1];
        return _FavoriteStickerTile(
          key: ValueKey('sticker-tile-${sticker.stickerId}'),
          sticker: sticker,
          onTap: () => unawaited(widget.onSelectSticker(sticker)),
          onRemove: () => unawaited(widget.onRemoveSticker(sticker)),
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
                  : '${widget.stickers.length} 个收藏 · 右键移除',
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
    required this.onTap,
    required this.onRemove,
  });

  final FavoriteSticker sticker;
  final VoidCallback onTap;
  final VoidCallback onRemove;

  @override
  State<_FavoriteStickerTile> createState() => _FavoriteStickerTileState();
}

class _FavoriteStickerTileState extends State<_FavoriteStickerTile> {
  bool _hovered = false;

  Future<void> _showContextMenu(TapDownDetails details) async {
    final position = details.globalPosition;
    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        position.dx + 1,
        position.dy + 1,
      ),
      items: const [
        PopupMenuItem<String>(
          value: 'delete',
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.delete_outline_rounded, size: 18),
              SizedBox(width: 8),
              Text('移出收藏表情'),
            ],
          ),
        ),
      ],
    );
    if (action == 'delete') {
      widget.onRemove();
    }
  }

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
        onSecondaryTapDown: (details) => unawaited(_showContextMenu(details)),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: _hovered
                  ? colorScheme.primary.withValues(alpha: 0.7)
                  : Colors.transparent,
              width: 1.5,
            ),
            color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
          ),
          clipBehavior: Clip.antiAlias,
          child: Stack(
            fit: StackFit.expand,
            children: [
              Image.file(
                File(widget.sticker.filePath),
                fit: BoxFit.cover,
                filterQuality: FilterQuality.medium,
                errorBuilder: (_, _, _) => Icon(
                  Icons.broken_image_outlined,
                  size: 20,
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
              if (_hovered)
                Positioned(
                  top: 2,
                  right: 2,
                  child: Semantics(
                    button: true,
                    label: '移出收藏',
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
                ),
            ],
          ),
        ),
      ),
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
