import 'dart:async';

import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:window_manager/window_manager.dart';

import '../core/single_instance/single_instance_service.dart';
import '../features/chat/main_shell.dart';
import '../features/onboarding/auth_page.dart';
import 'app_controller.dart';

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
    controller = AppController()..initialize();
    _singleInstance = widget.singleInstanceService ?? SingleInstanceService();
    _singleInstanceSubscription = _singleInstance.onAlreadyRunning.listen(
      (_) => _bringWindowToFront(),
    );
    unawaited(_singleInstance.initialize());
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

  @override
  void dispose() {
    _singleInstanceSubscription?.cancel();
    unawaited(_singleInstance.dispose());
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'NekoChat 局域网聊天',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xff4666e5),
          brightness: Brightness.light,
        ),
        scaffoldBackgroundColor: const Color(0xfff7f8fc),
        inputDecorationTheme: const InputDecorationTheme(
          border: OutlineInputBorder(),
        ),
        cardTheme: const CardThemeData(margin: EdgeInsets.zero),
      ),
      home: AnimatedBuilder(
        animation: controller,
        builder: (context, _) => switch (controller.stage) {
          AppStage.booting => const _BootPage(),
          AppStage.setup || AppStage.locked => AuthPage(controller: controller),
          AppStage.ready => MainShell(controller: controller),
          AppStage.error => _FatalPage(
            message: controller.errorMessage ?? '未知错误',
          ),
        },
      ),
    );
  }
}

class _BootPage extends StatelessWidget {
  const _BootPage();
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

class _FatalPage extends StatelessWidget {
  const _FatalPage({required this.message});
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
