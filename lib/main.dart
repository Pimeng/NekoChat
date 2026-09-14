import 'package:flutter/material.dart';
import 'package:multiview_desktop/multiview_desktop.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:window_manager/window_manager.dart';

import 'app/neko_chat_app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  await windowManager.ensureInitialized();
  // 桌面端保持一个可用的最小尺寸，避免窗口被压缩到左侧栏无法操作。
  await windowManager.setMinimumSize(const Size(1024, 640));
  runMultiApp(home: (_, _) => const NekoChatApp());
}
