import 'package:flutter/material.dart';
import 'package:multiview_desktop/multiview_desktop.dart' hide TitleBarStyle;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:window_manager/window_manager.dart';

import 'app/neko_chat_app.dart';
import 'features/dev_preview/component_preview_app.dart';

const bool _componentPreviewMode = bool.fromEnvironment('COMPONENT_PREVIEW');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (_componentPreviewMode) {
    await windowManager.ensureInitialized();
    await windowManager.setMinimumSize(const Size(720, 640));
    await windowManager.setSize(const Size(1280, 860));
    await windowManager.setTitle('NekoChat · 组件预览开发模式');
    runMultiApp(home: (_, _) => const ComponentPreviewApp());
    return;
  }
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  await windowManager.ensureInitialized();
  // 启动即进入创建身份/解锁，先按无边框紧凑窗口呈现（贴合登录卡片）；
  // 进入主界面后由 NekoChatApp 恢复带系统标题栏的正常可缩放窗口。
  await windowManager.setTitleBarStyle(
    TitleBarStyle.hidden,
    windowButtonVisibility: false,
  );
  await windowManager.setResizable(false);
  await windowManager.setMinimumSize(const Size(840, 520));
  await windowManager.setSize(const Size(840, 520));
  await windowManager.center();
  runMultiApp(home: (_, _) => const NekoChatApp());
}
