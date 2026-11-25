import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neko_chat/app/app_controller.dart';
import 'package:neko_chat/app/neko_chat_app.dart';
import 'package:neko_chat/core/theme/window_theme_channel.dart';

void main() {
  test('应用主题默认统一使用 MiSans', () {
    expect(buildNekoChatTheme().textTheme.bodyMedium?.fontFamily, 'MiSans');
  });

  test('可指定字体与中文回退字体', () {
    final theme = buildNekoChatTheme(
      fontFamily: 'Google Sans',
      fontFamilyFallback: const ['LXGW WenKai'],
    );
    expect(theme.textTheme.bodyMedium?.fontFamily, 'Google Sans');
    expect(
      theme.textTheme.bodyMedium?.fontFamilyFallback,
      const ['LXGW WenKai'],
    );
  });

  test('深色主题具备自然的深色表面层级与高对比度文字', () {
    final dark = buildNekoChatTheme(brightness: Brightness.dark);
    final light = buildNekoChatTheme(brightness: Brightness.light);

    expect(dark.brightness, Brightness.dark);
    expect(dark.colorScheme.brightness, Brightness.dark);
    expect(dark.scaffoldBackgroundColor.computeLuminance(), lessThan(0.08));
    expect(dark.colorScheme.surface.computeLuminance(), lessThan(0.12));
    expect(dark.cardTheme.color, isNotNull);
    expect(dark.cardTheme.color, isNot(dark.scaffoldBackgroundColor));
    expect(dark.dialogTheme.backgroundColor, isNotNull);
    expect(dark.canvasColor, dark.colorScheme.surfaceContainerHigh);
    expect(
      dark.textTheme.bodyMedium?.color?.computeLuminance() ??
          dark.colorScheme.onSurface.computeLuminance(),
      greaterThan(0.5),
    );
    expect(
      dark.textTheme.bodySmall?.color?.computeLuminance() ?? 0,
      greaterThan(0.4),
    );
    expect(
      dark.scaffoldBackgroundColor,
      isNot(light.scaffoldBackgroundColor),
    );
  });

  test('ThemeMode 编解码与实际亮度解析正确', () {
    expect(AppController.decodeThemeMode(null), ThemeMode.light);
    expect(AppController.decodeThemeMode('unknown'), ThemeMode.light);
    expect(AppController.decodeThemeMode('light'), ThemeMode.light);
    expect(AppController.decodeThemeMode('dark'), ThemeMode.dark);
    expect(AppController.decodeThemeMode('system'), ThemeMode.system);
    expect(AppController.encodeThemeMode(ThemeMode.dark), 'dark');

    expect(
      resolveEffectiveBrightness(ThemeMode.light, Brightness.dark),
      Brightness.light,
    );
    expect(
      resolveEffectiveBrightness(ThemeMode.dark, Brightness.light),
      Brightness.dark,
    );
    expect(
      resolveEffectiveBrightness(ThemeMode.system, Brightness.dark),
      Brightness.dark,
    );
    expect(
      resolveEffectiveBrightness(ThemeMode.system, Brightness.light),
      Brightness.light,
    );
  });
}
