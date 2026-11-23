import 'package:material_ui/material_ui.dart';
import 'package:multiview_desktop/multiview_desktop.dart';
import 'package:window_manager/window_manager.dart';

import 'features/dev_preview/component_preview_app.dart';

/// 组件预览开发模式入口：
/// `flutter run -d windows -t lib/main_preview.dart`
///
/// 不初始化本地数据库、网络端口、单实例锁或全局老板键，
/// 可直接展示所有组件并配合 Flutter 原生 Hot Reload (`r`) 实时调试 UI。
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();
  await windowManager.setMinimumSize(const Size(720, 640));
  await windowManager.setSize(const Size(1280, 860));
  await windowManager.setTitle('NekoChat · 组件预览开发模式');
  runMultiApp(home: (_, _) => const ComponentPreviewApp());
}
