import 'package:flutter_test/flutter_test.dart';
import 'package:neko_chat/app/app_controller.dart';
import 'package:neko_chat/core/fonts/bundled_fonts.dart';
import 'package:neko_chat/core/fonts/installed_fonts.dart';

void main() {
  group('BundledFonts', () {
    test('识别 assets/font 下的字体资源 key', () {
      expect(BundledFonts.isFontAssetKey('assets/font/MiSans-Regular.ttf'), isTrue);
      expect(BundledFonts.isFontAssetKey('assets/font/sub/x.otf'), isTrue);
      expect(BundledFonts.isFontAssetKey('assets/font/.gitkeep'), isFalse);
      expect(BundledFonts.isFontAssetKey('assets/app.png'), isFalse);
      expect(BundledFonts.isFontAssetKey('assets/other/MiSans.ttf'), isFalse);
    });

    test('按词边界把随包字体资源归到对应族名', () {
      final keys = [
        'assets/font/MiSans-Regular.ttf',
        'assets/font/MiSans-Bold.ttf',
        'assets/font/LXGWWenKai.ttf', // 无连字符的历史文件名也应命中
        'assets/font/LXGWWenKaiMono-Regular.ttf', // Mono 为另一家族，应排除
        'assets/font/UnknownFont.ttf',
      ];
      final matched = BundledFonts.matchFamilies(keys, {
        'MiSans': ['misans'],
        'LXGW WenKai': ['lxgwwenkai'],
        'vivo Sans': ['vivosans'],
      });
      expect(matched['MiSans'], [
        'assets/font/MiSans-Regular.ttf',
        'assets/font/MiSans-Bold.ttf',
      ]);
      expect(matched['LXGW WenKai'], ['assets/font/LXGWWenKai.ttf']);
      // 未命中的族名不出现在结果里。
      expect(matched.containsKey('vivo Sans'), isFalse);
    });
  });

  group('InstalledFonts.isInstalled', () {
    final installed = <String>{
      'misans-regular.ttf',
      'misans-bold.ttf',
      'jetbrainsmono-regular.ttf',
      'jetbrainsmononl-regular.ttf',
      'vivosansglobal-regular.ttf',
      'lxgwwenkaimono-regular.ttf',
    };

    test('命中词边界前缀视为已安装', () {
      expect(InstalledFonts.isInstalled(installed, ['misans']), isTrue);
      expect(InstalledFonts.isInstalled(installed, ['jetbrainsmono']), isTrue);
      // 无连字符、直接等于前缀加扩展名的文件也应命中。
      expect(
        InstalledFonts.isInstalled({'lxgwwenkai.ttf'}, ['lxgwwenkai']),
        isTrue,
      );
    });

    test('词边界精确区分相近家族', () {
      // 只装了 vivo Sans Global，不应误判为 vivo Sans。
      expect(InstalledFonts.isInstalled(installed, ['vivosans']), isFalse);
      // 只装了 LXGW WenKai Mono，不应误判为 LXGW WenKai。
      expect(InstalledFonts.isInstalled(installed, ['lxgwwenkai']), isFalse);
    });

    test('未安装与空关键字返回 false', () {
      expect(InstalledFonts.isInstalled(installed, ['googlesans']), isFalse);
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
