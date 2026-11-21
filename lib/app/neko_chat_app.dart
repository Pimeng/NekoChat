import 'dart:async';

import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:multiview_desktop/multiview_desktop.dart' hide TitleBarStyle;
import 'package:window_manager/window_manager.dart';

import '../core/notifications/standalone_notification_service.dart';
import '../core/single_instance/single_instance_service.dart';
import '../features/chat/main_shell.dart';
import '../features/onboarding/auth_page.dart';
import 'app_controller.dart';

/// 构建应用主题。
///
/// [fontFamily] 为 null 时使用系统默认字体；[bold] 为 true 时各字号字重上调一档
/// （内置单字重字体由 Flutter 合成伪粗体）。
ThemeData buildNekoChatTheme({
  String? fontFamily = AppController.defaultFontFamily,
  List<String>? fontFamilyFallback,
  bool bold = false,
}) {
  final colorScheme = ColorScheme.fromSeed(
    seedColor: const Color(0xff4666e5),
    brightness: Brightness.light,
  );

  // 加粗时把字重按 FontWeight 档位上调一级（封顶 w900）。
  FontWeight weight(FontWeight base) {
    if (!bold) return base;
    final index = FontWeight.values.indexOf(base);
    return FontWeight.values[(index + 1).clamp(0, FontWeight.values.length - 1)];
  }

  TextStyle styled({
    required double fontSize,
    required FontWeight fontWeight,
    Color? color,
  }) => TextStyle(
    fontFamily: fontFamily,
    fontFamilyFallback: fontFamilyFallback,
    fontSize: fontSize,
    fontWeight: weight(fontWeight),
    color: color,
  );

  return ThemeData(
    useMaterial3: true,
    fontFamily: fontFamily,
    fontFamilyFallback: fontFamilyFallback,
    colorScheme: colorScheme,
    scaffoldBackgroundColor: const Color(0xfff7f8fc),
    textTheme: TextTheme(
      headlineMedium: styled(fontSize: 22, fontWeight: FontWeight.w600),
      headlineSmall: styled(fontSize: 20, fontWeight: FontWeight.w600),
      titleLarge: styled(fontSize: 18, fontWeight: FontWeight.w600),
      titleMedium: styled(fontSize: 15, fontWeight: FontWeight.w600),
      titleSmall: styled(fontSize: 13, fontWeight: FontWeight.w600),
      bodyLarge: styled(fontSize: 14, fontWeight: FontWeight.w400),
      bodyMedium: styled(fontSize: 14, fontWeight: FontWeight.w400),
      bodySmall: styled(
        fontSize: 12,
        fontWeight: FontWeight.w400,
        color: colorScheme.onSurfaceVariant,
      ),
      labelLarge: styled(fontSize: 13, fontWeight: FontWeight.w600),
      labelMedium: styled(fontSize: 12, fontWeight: FontWeight.w500),
      labelSmall: styled(
        fontSize: 11,
        fontWeight: FontWeight.w400,
        color: colorScheme.onSurfaceVariant,
      ),
    ),
    appBarTheme: AppBarTheme(
      titleTextStyle: styled(
        fontSize: 17,
        fontWeight: FontWeight.w600,
        color: colorScheme.onSurface,
      ),
    ),
    dialogTheme: DialogThemeData(
      titleTextStyle: styled(
        fontSize: 17,
        fontWeight: FontWeight.w600,
        color: colorScheme.onSurface,
      ),
    ),
    listTileTheme: ListTileThemeData(
      titleTextStyle: styled(
        fontSize: 14,
        fontWeight: FontWeight.w500,
        color: colorScheme.onSurface,
      ),
      subtitleTextStyle: styled(
        fontSize: 12,
        fontWeight: FontWeight.w400,
        color: colorScheme.onSurfaceVariant,
      ),
      leadingAndTrailingTextStyle: styled(
        fontSize: 12,
        fontWeight: FontWeight.w400,
        color: colorScheme.onSurfaceVariant,
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      border: const OutlineInputBorder(),
      hintStyle: styled(
        fontSize: 13,
        fontWeight: FontWeight.w400,
        color: colorScheme.onSurfaceVariant,
      ),
      labelStyle: styled(
        fontSize: 13,
        fontWeight: FontWeight.w400,
        color: colorScheme.onSurfaceVariant,
      ),
    ),
    cardTheme: const CardThemeData(margin: EdgeInsets.zero),
  );
}

class NekoChatApp extends StatefulWidget {
  const NekoChatApp({super.key, this.singleInstanceService});

  /// 可注入的单实例服务，便于测试；默认使用平台实现。
  final SingleInstanceService? singleInstanceService;

  @override
  State<NekoChatApp> createState() => _NekoChatAppState();
}

class _NekoChatAppState extends State<NekoChatApp> {
  final _log = Logger('NekoChatApp');
  late final AppController controller;
  late final SingleInstanceService _singleInstance;
  StreamSubscription<void>? _singleInstanceSubscription;

  /// 已应用的窗口形态：true=登录态无边框紧凑窗口，false=主界面正常窗口。
  bool? _authWindowApplied;

  @override
  void initState() {
    super.initState();
    Logger.root.level = Level.ALL;
    Logger.root.onRecord.listen((record) {
      debugPrint(
        '${record.time.toIso8601String()} [${record.level.name}] ${record.loggerName}: ${record.message}',
      );
      if (record.error != null) debugPrint('  ${record.error}');
    });
    controller = AppController(
      onBossKeyVisibilityChanged: _setSecondaryWindowsHidden,
    )..initialize();
    controller.addListener(_syncWindowToStage);
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncWindowToStage());
    _singleInstance = widget.singleInstanceService ?? SingleInstanceService();
    _singleInstanceSubscription = _singleInstance.onAlreadyRunning.listen(
      (_) => _bringWindowToFront(),
    );
    unawaited(_singleInstance.initialize());
  }

  /// 根据当前阶段切换窗口形态：登录/解锁（含启动）用无边框紧凑窗口，
  /// 进入主界面后恢复带系统标题栏的正常可缩放窗口。
  void _syncWindowToStage() {
    final auth = switch (controller.stage) {
      AppStage.booting || AppStage.setup || AppStage.locked => true,
      AppStage.ready || AppStage.error => false,
    };
    if (_authWindowApplied == auth) return;
    _authWindowApplied = auth;
    unawaited(_applyWindowMode(auth));
  }

  Future<void> _applyWindowMode(bool auth) async {
    try {
      if (auth) {
        const size = Size(840, 520);
        await windowManager.setTitleBarStyle(
          TitleBarStyle.hidden,
          windowButtonVisibility: false,
        );
        await windowManager.setResizable(false);
        await windowManager.setMinimumSize(size);
        await windowManager.setSize(size);
        await windowManager.center();
      } else {
        await windowManager.setTitleBarStyle(TitleBarStyle.normal);
        await windowManager.setResizable(true);
        await windowManager.setMinimumSize(const Size(720, 640));
        await windowManager.setSize(const Size(1024, 720));
        await windowManager.center();
      }
    } on Object catch (error, stack) {
      _log.warning('切换窗口形态失败', error, stack);
    }
  }

  /// 用户重复启动程序时，把已有的窗口置前。
  Future<void> _bringWindowToFront() async {
    try {
      await windowManager.show();
      if (await windowManager.isMinimized()) {
        await windowManager.restore();
      }
      await windowManager.focus();
    } on Object catch (error, stack) {
      _log.warning('无法将现有窗口置前', error, stack);
    }
  }

  /// 老板键隐藏主窗口时同步隐藏所有独立会话窗口，避免内容残留在桌面。
  /// 独立通知窗口由通知服务自身控制显隐，恢复时不强制弹出空窗口。
  Future<void> _setSecondaryWindowsHidden(bool hidden) async {
    await Future.wait(
      MultiViewDesktop.allWindowViewIds
          .where(
            (viewId) =>
                !StandaloneNotificationService.isNotificationViewId(viewId),
          )
          .map((viewId) {
            final window = MultiViewDesktop.fromId(viewId);
            return hidden ? window.hide() : window.show();
          }),
    );
  }

  @override
  void dispose() {
    controller.removeListener(_syncWindowToStage);
    _singleInstanceSubscription?.cancel();
    unawaited(_singleInstance.dispose());
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: controller.appearanceRevision,
      builder: (context, _, _) {
        final fontStack = controller.resolveFontStack();
        return MaterialApp(
          debugShowCheckedModeBanner: false,
          title: 'NekoChat 局域网聊天',
          theme: buildNekoChatTheme(
            fontFamily: fontStack.family,
            fontFamilyFallback: fontStack.fallback,
            bold: controller.boldText,
          ),
          builder: (context, child) {
            final mediaQuery = MediaQuery.of(context);
            return MediaQuery(
              data: mediaQuery.copyWith(
                textScaler: TextScaler.linear(controller.fontScale),
              ),
              child: child!,
            );
          },
          home: AnimatedBuilder(
            animation: controller,
            builder: (context, _) => switch (controller.stage) {
              AppStage.booting => const BootPage(),
              AppStage.setup ||
              AppStage.locked => AuthPage(controller: controller),
              AppStage.ready => MainShell(controller: controller),
              AppStage.error => FatalPage(
                message: controller.errorMessage ?? '未知错误',
              ),
            },
          ),
        );
      },
    );
  }
}

class BootPage extends StatelessWidget {
  const BootPage({super.key});
  @override
  Widget build(BuildContext context) => const Scaffold(
    body: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(),
          SizedBox(height: 18),
          Text('正在读取本地身份…'),
        ],
      ),
    ),
  );
}

class FatalPage extends StatelessWidget {
  const FatalPage({super.key, required this.message});
  final String message;
  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.error_outline,
                  size: 48,
                  color: Theme.of(context).colorScheme.error,
                ),
                const SizedBox(height: 16),
                const Text(
                  'NekoChat 无法启动',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 10),
                Text(message, textAlign: TextAlign.center),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
