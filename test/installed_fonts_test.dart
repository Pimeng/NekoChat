import 'package:flutter_test/flutter_test.dart';
import 'package:neko_chat/app/app_controller.dart';
import 'package:neko_chat/core/fonts/installed_fonts.dart';

void main() {
  group('InstalledFonts.isInstalled', () {
    final installed = <String>{
      'misans-regular.ttf',
      'misans-bold.ttf',
      'jetbrainsmono-regular.ttf',
      'jetbrainsmononl-regular.ttf',
      'vivosansglobal-regular.ttf',
      'lxgwwenkaimono-regular.ttf',
    };

    test('命中前缀关键字视为已安装', () {
      expect(InstalledFonts.isInstalled(installed, ['misans-']), isTrue);
      expect(InstalledFonts.isInstalled(installed, ['jetbrainsmono-']), isTrue);
    });

    test('前缀精确区分相近家族', () {
      // 只装了 vivo Sans Global，不应误判为 vivo Sans。
      expect(InstalledFonts.isInstalled(installed, ['vivosans-']), isFalse);
      // 只装了 LXGW WenKai Mono，不应误判为 LXGW WenKai。
      expect(InstalledFonts.isInstalled(installed, ['lxgwwenkai-']), isFalse);
    });

    test('未安装与空关键字返回 false', () {
      expect(InstalledFonts.isInstalled(installed, ['googlesans-']), isFalse);
      expect(InstalledFonts.isInstalled(installed, const []), isFalse);
    });
  });

  group('AppController 字体可用性', () {
    test('旧字体名迁移到系统真实族名', () {
      expect(AppController.migrateLegacyFontFamily('vivoSans'), 'vivo Sans');
      expect(AppController.migrateLegacyFontFamily('GoogleSans'), 'Google Sans');
      expect(
        AppController.migrateLegacyFontFamily('JetBrainsMono'),
        'JetBrains Mono',
      );
      expect(AppController.migrateLegacyFontFamily('LXGWWenKai'), 'LXGW WenKai');
      // 已是真实名或未知名原样返回；null 保持 null。
      expect(AppController.migrateLegacyFontFamily('MiSans'), 'MiSans');
      expect(AppController.migrateLegacyFontFamily(null), isNull);
    });

    test('未检测到安装信息时展示全部内置选项', () {
      final controller = AppController();
      // 默认 availableFontFamilies 为空（测试环境不扫描系统）。
      final cjk = controller.availableFontOptions(wantCjk: true);
      expect(
        cjk.map((o) => o.family),
        containsAll(<String?>[null, 'MiSans', 'vivo Sans', 'LXGW WenKai']),
      );
    });

    test('检测到安装信息时仅保留已安装字体，系统默认恒在', () {
      final controller = AppController()..availableFontFamilies = {'MiSans'};
      final cjk = controller.availableFontOptions(wantCjk: true);
      expect(cjk.map((o) => o.family), <String?>[null, 'MiSans']);
      // 选中但未安装的字体在下拉里收敛为系统默认（null）。
      controller.appFontFamily = 'vivo Sans';
      expect(controller.selectedCjkFontFamily, isNull);
      controller.appFontFamily = 'MiSans';
      expect(controller.selectedCjkFontFamily, 'MiSans');
    });

    test('选中字体未安装时主题回退系统默认', () {
      final controller = AppController()
        ..availableFontFamilies = {'MiSans'}
        ..appFontFamily = 'Google Sans';
      expect(controller.resolveFontStack().family, isNull);
    });
  });
}
