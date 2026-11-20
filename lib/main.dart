import 'package:flutter/material.dart';
import 'package:multiview_desktop/multiview_desktop.dart';
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
  // 侧边栏可以收起或缩窄，小窗口下仍保留足够的会话操作空间。
  await windowManager.setMinimumSize(const Size(720, 640));
  runMultiApp(home: (_, _) => const NekoChatApp());
}
