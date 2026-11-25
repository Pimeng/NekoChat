import 'package:material_ui/material_ui.dart';

import '../../app/neko_chat_app.dart';
import '../../core/text/pinyin_search.dart';
import 'preview_app_controller.dart';
import 'preview_catalog.dart';

enum _ViewportPreset {
  auto('自适应', null),
  desktop('桌面 1200×800', Size(1200, 800)),
  minWindow('最小 720×640', Size(720, 640)),
  sidebar('侧栏 320px', Size(320, 720)),
  card('卡片 440px', Size(440, 680));

  const _ViewportPreset(this.label, this.size);
  final String label;
  final Size? size;
}

enum _CanvasBackground {
  theme('主题背景'),
  white('纯白'),
  grid('网格');

  const _CanvasBackground(this.label);
  final String label;
}

/// NekoChat 组件预览开发模式根应用。
class ComponentPreviewApp extends StatefulWidget {
  const ComponentPreviewApp({super.key});

  @override
  State<ComponentPreviewApp> createState() => _ComponentPreviewAppState();
}

class _ComponentPreviewAppState extends State<ComponentPreviewApp> {
  final ValueNotifier<ThemeMode> _themeMode = ValueNotifier<ThemeMode>(
    ThemeMode.light,
  );
  late ThemeData _lightTheme = buildNekoChatTheme(brightness: Brightness.light);
  late ThemeData _darkTheme = buildNekoChatTheme(brightness: Brightness.dark);

  @override
  void reassemble() {
    super.reassemble();
    _lightTheme = buildNekoChatTheme(brightness: Brightness.light);
    _darkTheme = buildNekoChatTheme(brightness: Brightness.dark);
  }

  @override
  void dispose() {
    _themeMode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: _themeMode,
      builder: (context, mode, _) => MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'NekoChat · 组件预览开发模式',
        themeMode: mode,
        theme: _lightTheme,
        darkTheme: _darkTheme,
        home: ComponentPreviewWorkbench(themeModeNotifier: _themeMode),
      ),
    );
  }
}

class ComponentPreviewWorkbench extends StatefulWidget {
  const ComponentPreviewWorkbench({super.key, this.themeModeNotifier});

  final ValueNotifier<ThemeMode>? themeModeNotifier;

  @override
  State<ComponentPreviewWorkbench> createState() =>
      _ComponentPreviewWorkbenchState();
}

class _ComponentPreviewWorkbenchState extends State<ComponentPreviewWorkbench> {
  static const _overviewId = '__all__';

  late final PreviewAppController _controller;
  late List<PreviewEntry> _catalog;
  final _searchController = TextEditingController();
  String _selectedId = _overviewId;
  _ViewportPreset _viewport = _ViewportPreset.auto;
  _CanvasBackground _background = _CanvasBackground.theme;
  double _textScale = 1.0;
  bool _sidebarOpen = true;
  int _hotReloadCount = 0;
  DateTime? _lastHotReloadAt;

  @override
  void initState() {
    super.initState();
    _controller = PreviewAppController();
    _controller.appearanceRevision.addListener(_syncRootThemeMode);
    _catalog = buildPreviewCatalog(_controller, onAction: _showActionToast);
  }

  void _syncRootThemeMode() {
    final notifier = widget.themeModeNotifier;
    if (notifier != null && notifier.value != _controller.themeMode) {
      notifier.value = _controller.themeMode;
    }
  }

  @override
  void reassemble() {
    super.reassemble();
    // Flutter 每次触发 Hot Reload 都会调用 reassemble()，这里刷新目录并记录刷新次数与时间。
    _catalog = buildPreviewCatalog(_controller, onAction: _showActionToast);
    _hotReloadCount++;
    _lastHotReloadAt = DateTime.now();
  }

  @override
  void dispose() {
    _controller.appearanceRevision.removeListener(_syncRootThemeMode);
    _searchController.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _showActionToast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          width: 420,
          duration: const Duration(seconds: 2),
          content: Text(message),
        ),
      );
  }

  void _resetMockData() {
    _controller.reset();
    _showActionToast('已重置组件预览模拟数据');
  }

  @override
  Widget build(BuildContext context) {
    final catalog = _catalog;
    final query = _searchController.text.trim().toLowerCase();
    final filteredCatalog = query.isEmpty
        ? catalog
        : catalog
              .where(
                (entry) =>
                    matchesPinyinSearch(entry.name, query) ||
                    entry.widgetType.toLowerCase().contains(query) ||
                    matchesPinyinSearch(entry.description, query) ||
                    matchesPinyinSearch(entry.category.label, query),
              )
              .toList();

    final selectedEntry = _selectedId == _overviewId
        ? null
        : catalog.where((entry) => entry.id == _selectedId).firstOrNull;

    return Scaffold(
      body: SafeArea(
        child: Row(
          children: [
            if (_sidebarOpen) ...[
              RepaintBoundary(
                child: SizedBox(
                  width: 280,
                  child: _buildSidebar(context, catalog, filteredCatalog),
                ),
              ),
              const VerticalDivider(width: 1),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  RepaintBoundary(child: _buildToolbar(context, selectedEntry)),
                  const Divider(height: 1),
                  Expanded(
                    child: RepaintBoundary(
                      child: _buildStage(
                        context,
                        selectedEntry: selectedEntry,
                        catalog: filteredCatalog,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSidebar(
    BuildContext context,
    List<PreviewEntry> allEntries,
    List<PreviewEntry> filteredEntries,
  ) {
    final colorScheme = Theme.of(context).colorScheme;
    return Material(
      color: colorScheme.surface,
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(16, 16, 12, 12),
            color: colorScheme.primaryContainer.withValues(alpha: .45),
            child: Row(
              children: [
                Icon(Icons.auto_awesome_mosaic, color: colorScheme.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'NekoChat 组件预览',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        '共 ${allEntries.length} 组组件 · 支持热重载',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 7,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: colorScheme.primary,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    'DEV',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: colorScheme.onPrimary,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
            child: TextField(
              key: const ValueKey('preview-search-field'),
              controller: _searchController,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                hintText: '搜索组件名称或类名',
                prefixIcon: const Icon(Icons.search, size: 20),
                isDense: true,
                suffixIcon: _searchController.text.isEmpty
                    ? null
                    : IconButton(
                        tooltip: '清空搜索',
                        onPressed: () {
                          _searchController.clear();
                          setState(() {});
                        },
                        icon: const Icon(Icons.close, size: 18),
                      ),
              ),
            ),
          ),
          Expanded(
            child: ListView(
              key: const ValueKey('preview-sidebar-list'),
              padding: const EdgeInsets.only(bottom: 16),
              children: [
                ListTile(
                  key: const ValueKey('preview-nav-all'),
                  dense: true,
                  selected: _selectedId == _overviewId,
                  leading: const Icon(Icons.grid_view_rounded, size: 20),
                  title: const Text(
                    '全部组件总览',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  subtitle: Text('一屏浏览 ${filteredEntries.length} 组组件'),
                  onTap: () => setState(() => _selectedId = _overviewId),
                ),
                for (final category in PreviewCategory.values) ...[
                  if (filteredEntries.any((e) => e.category == category)) ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 14, 12, 4),
                      child: Row(
                        children: [
                          Icon(
                            category.icon,
                            size: 16,
                            color: colorScheme.primary,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            category.label,
                            style: Theme.of(context).textTheme.labelLarge
                                ?.copyWith(
                                  color: colorScheme.primary,
                                  fontWeight: FontWeight.w600,
                                ),
                          ),
                        ],
                      ),
                    ),
                    for (final entry in filteredEntries.where(
                      (e) => e.category == category,
                    ))
                      ListTile(
                        key: ValueKey('preview-nav-${entry.id}'),
                        dense: true,
                        selected: _selectedId == entry.id,
                        title: Text(
                          entry.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          entry.widgetType,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.labelSmall,
                        ),
                        onTap: () => setState(() => _selectedId = entry.id),
                      ),
                  ],
                ],
                if (filteredEntries.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(20),
                    child: Text(
                      '没有匹配的组件',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: colorScheme.onSurfaceVariant),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildToolbar(BuildContext context, PreviewEntry? selectedEntry) {
    final colorScheme = Theme.of(context).colorScheme;
    final reloadText = _hotReloadCount == 0
        ? '热重载就绪 (按 r)'
        : '热重载 #$_hotReloadCount · ${_formatClock(_lastHotReloadAt!)}';
    return Material(
      color: colorScheme.surface,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Wrap(
          spacing: 10,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            IconButton(
              tooltip: _sidebarOpen ? '收起组件目录' : '展开组件目录',
              onPressed: () => setState(() => _sidebarOpen = !_sidebarOpen),
              icon: Icon(
                _sidebarOpen ? Icons.menu_open : Icons.menu,
                size: 20,
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  selectedEntry?.name ?? '全部组件总览',
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  selectedEntry?.widgetType ??
                      '修改任意 lib/ 组件后按 r 即可实时热重载',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(width: 8),
            DropdownButton<_ViewportPreset>(
              key: const ValueKey('preview-viewport-dropdown'),
              value: _viewport,
              isDense: true,
              underline: const SizedBox.shrink(),
              items: [
                for (final preset in _ViewportPreset.values)
                  DropdownMenuItem(
                    value: preset,
                    child: Text('视口：${preset.label}'),
                  ),
              ],
              onChanged: (value) {
                if (value != null) setState(() => _viewport = value);
              },
            ),
            DropdownButton<double>(
              key: const ValueKey('preview-scale-dropdown'),
              value: _textScale,
              isDense: true,
              underline: const SizedBox.shrink(),
              items: const [
                DropdownMenuItem(value: 1.0, child: Text('字号：1.0x')),
                DropdownMenuItem(value: 1.15, child: Text('字号：1.15x')),
                DropdownMenuItem(value: 1.3, child: Text('字号：1.3x')),
              ],
              onChanged: (value) {
                if (value != null) setState(() => _textScale = value);
              },
            ),
            DropdownButton<_CanvasBackground>(
              key: const ValueKey('preview-bg-dropdown'),
              value: _background,
              isDense: true,
              underline: const SizedBox.shrink(),
              items: [
                for (final bg in _CanvasBackground.values)
                  DropdownMenuItem(value: bg, child: Text(bg.label)),
              ],
              onChanged: (value) {
                if (value != null) setState(() => _background = value);
              },
            ),
            DropdownButton<ThemeMode>(
              key: const ValueKey('preview-theme-dropdown'),
              value: _controller.themeMode,
              isDense: true,
              underline: const SizedBox.shrink(),
              items: const [
                DropdownMenuItem(value: ThemeMode.light, child: Text('主题：浅色')),
                DropdownMenuItem(value: ThemeMode.dark, child: Text('主题：深色')),
                DropdownMenuItem(
                  value: ThemeMode.system,
                  child: Text('主题：跟随系统'),
                ),
              ],
              onChanged: (value) {
                if (value != null) {
                  _controller.setThemeMode(value);
                  setState(() {});
                }
              },
            ),
            Container(
              key: const ValueKey('preview-hot-reload-badge'),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: colorScheme.secondaryContainer,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.bolt,
                    size: 15,
                    color: colorScheme.onSecondaryContainer,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    reloadText,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: colorScheme.onSecondaryContainer,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
            OutlinedButton.icon(
              onPressed: _resetMockData,
              icon: const Icon(Icons.restart_alt, size: 17),
              label: const Text('重置数据'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStage(
    BuildContext context, {
    required PreviewEntry? selectedEntry,
    required List<PreviewEntry> catalog,
  }) {
    final child = selectedEntry == null
        ? _buildOverviewGallery(context, catalog)
        : _buildSingleEntryStage(context, selectedEntry);

    // 预览画布跟随“外观”设置（主题模式 / 字体族 / 字重 / 字号），与真实应用保持一致；
    // 工具栏缩放 _textScale 与设置里的字号相乘叠加。
    final scaled = AnimatedBuilder(
      animation: _controller,
      child: child,
      builder: (context, inner) {
        final effectiveScale = _textScale * _controller.fontScale;
        final fontStack = _controller.resolveFontStack();
        final platformBrightness = MediaQuery.platformBrightnessOf(context);
        final brightness = switch (_controller.themeMode) {
          ThemeMode.light => Brightness.light,
          ThemeMode.dark => Brightness.dark,
          ThemeMode.system => platformBrightness,
        };
        final themed = Theme(
          data: buildNekoChatTheme(
            fontFamily: fontStack.family,
            fontFamilyFallback: fontStack.fallback,
            bold: _controller.boldText,
            brightness: brightness,
          ),
          child: inner!,
        );
        return effectiveScale == 1.0
            ? themed
            : _TextScaleScope(textScale: effectiveScale, child: themed);
      },
    );

    final bgWidget = _CanvasSurface(background: _background, child: scaled);
    final presetSize = _viewport.size;
    if (presetSize == null) return bgWidget;

    return _CanvasSurface(
      background: _background,
      child: Center(
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Container(
              width: presetSize.width,
              height: presetSize.height,
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: Theme.of(context).scaffoldBackgroundColor,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: Theme.of(context).colorScheme.outlineVariant,
                ),
                boxShadow: const [
                  BoxShadow(
                    color: Colors.black12,
                    blurRadius: 18,
                    offset: Offset(0, 6),
                  ),
                ],
              ),
              child: scaled,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSingleEntryStage(BuildContext context, PreviewEntry entry) {
    if (entry.isFullPage) {
      return KeyedSubtree(
        key: ValueKey('stage-${entry.id}'),
        child: entry.builder(context),
      );
    }
    return SingleChildScrollView(
      key: ValueKey('stage-${entry.id}'),
      padding: const EdgeInsets.all(28),
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 880),
          child: _PreviewCard(entry: entry, onOpenSolo: null),
        ),
      ),
    );
  }

  Widget _buildOverviewGallery(
    BuildContext context,
    List<PreviewEntry> catalog,
  ) {
    final componentEntries = catalog.where((e) => !e.isFullPage).toList();
    final pageEntries = catalog.where((e) => e.isFullPage).toList();

    return ListView(
      key: const ValueKey('preview-overview-list'),
      padding: const EdgeInsets.all(24),
      children: [
        if (pageEntries.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              '完整页面（点击进入交互预览）',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              for (final page in pageEntries)
                SizedBox(
                  width: 260,
                  child: Card(
                    clipBehavior: Clip.antiAlias,
                    child: InkWell(
                      onTap: () => setState(() => _selectedId = page.id),
                      child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Icon(
                                  Icons.desktop_windows_outlined,
                                  size: 18,
                                  color: Theme.of(context).colorScheme.primary,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    page.name,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w700,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                const Icon(Icons.chevron_right, size: 18),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Text(
                              page.widgetType,
                              style: Theme.of(context).textTheme.labelSmall
                                  ?.copyWith(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.primary,
                                  ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              page.description,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 28),
        ],
        if (componentEntries.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              '独立组件实时预览',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
          for (final entry in componentEntries) ...[
            _PreviewCard(
              entry: entry,
              onOpenSolo: () => setState(() => _selectedId = entry.id),
            ),
            const SizedBox(height: 18),
          ],
        ],
      ],
    );
  }
}

class _PreviewCard extends StatelessWidget {
  const _PreviewCard({required this.entry, required this.onOpenSolo});

  final PreviewEntry entry;
  final VoidCallback? onOpenSolo;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Card(
      elevation: 1,
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            color: colorScheme.surfaceContainerLow,
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            entry.name,
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 7,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: colorScheme.primaryContainer,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              entry.widgetType,
                              style: Theme.of(context).textTheme.labelSmall
                                  ?.copyWith(
                                    color: colorScheme.onPrimaryContainer,
                                  ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 3),
                      Text(
                        entry.description,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                if (onOpenSolo != null)
                  TextButton.icon(
                    onPressed: onOpenSolo,
                    icon: const Icon(Icons.open_in_full, size: 16),
                    label: const Text('单独聚焦'),
                  ),
              ],
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.all(18),
            child: Builder(builder: entry.builder),
          ),
        ],
      ),
    );
  }
}

class _TextScaleScope extends StatelessWidget {
  const _TextScaleScope({required this.textScale, required this.child});

  final double textScale;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(textScale)),
      child: child,
    );
  }
}

class _CanvasSurface extends StatelessWidget {
  const _CanvasSurface({required this.background, required this.child});

  final _CanvasBackground background;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return switch (background) {
      _CanvasBackground.theme => ColoredBox(
        color: Theme.of(context).scaffoldBackgroundColor,
        child: child,
      ),
      _CanvasBackground.white => ColoredBox(color: Colors.white, child: child),
      _CanvasBackground.grid => CustomPaint(
        painter: _GridBackgroundPainter(
          backgroundColor: Theme.of(context).scaffoldBackgroundColor,
          lineColor: Theme.of(context).dividerColor.withValues(alpha: .35),
        ),
        child: child,
      ),
    };
  }
}

class _GridBackgroundPainter extends CustomPainter {
  const _GridBackgroundPainter({
    required this.backgroundColor,
    required this.lineColor,
  });
  final Color backgroundColor;
  final Color lineColor;

  @override
  void paint(Canvas canvas, Size size) {
    final bgPaint = Paint()..color = backgroundColor;
    canvas.drawRect(Offset.zero & size, bgPaint);

    final paint = Paint()
      ..color = lineColor
      ..strokeWidth = 1;
    const step = 24.0;
    for (double x = 0; x <= size.width; x += step) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    for (double y = 0; y <= size.height; y += step) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _GridBackgroundPainter oldDelegate) =>
      oldDelegate.backgroundColor != backgroundColor ||
      oldDelegate.lineColor != lineColor;
}

String _formatClock(DateTime time) {
  String two(int value) => value.toString().padLeft(2, '0');
  return '${two(time.hour)}:${two(time.minute)}:${two(time.second)}';
}
