import 'package:flutter/services.dart';

import 'installed_fonts.dart';

/// 随包字体加载。
///
/// 仓库本身不携带字体文件，但 `assets/font/` 已在 pubspec 中登记为打包资源目录：
/// 谁在编译前把字体文件丢进该目录，就会被一起打包进应用。Flutter 不会把普通资源
/// 自动当作可用字体，这里在启动时用 [FontLoader] 把随包字体按真实族名注册，使其可用。
///
/// 与 [InstalledFonts] 配合形成三级优先级：随包字体 > 系统已安装字体 > 系统默认。
class BundledFonts {
  const BundledFonts._();

  /// 打包字体所在的资源目录前缀。
  static const assetDirPrefix = 'assets/font/';

  /// 从资源清单里挑出 [assetDirPrefix] 下的字体资源 key；读取失败时返回空列表。
  static Future<List<String>> listFontAssetKeys({AssetBundle? bundle}) async {
    try {
      final manifest = await AssetManifest.loadFromAssetBundle(
        bundle ?? rootBundle,
      );
      return manifest
          .listAssets()
          .where(isFontAssetKey)
          .toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  /// 是否为 [assetDirPrefix] 下的字体文件资源 key。
  static bool isFontAssetKey(String key) {
    if (!key.startsWith(assetDirPrefix)) return false;
    final lower = key.toLowerCase();
    return lower.endsWith('.ttf') ||
        lower.endsWith('.otf') ||
        lower.endsWith('.ttc');
  }

  /// 纯匹配：在 [assetKeys] 中按各族名的匹配关键字挑出对应资源，返回 族名 → 资源 key 列表。
  /// 关键字按 [InstalledFonts.fileNameMatchesToken] 的词边界规则匹配资源 key 的文件名部分。
  /// 仅返回有命中的族名。
  static Map<String, List<String>> matchFamilies(
    Iterable<String> assetKeys,
    Map<String, List<String>> familyToMatchKeys,
  ) {
    final result = <String, List<String>>{};
    for (final entry in familyToMatchKeys.entries) {
      if (entry.value.isEmpty) continue;
      final matched = <String>[];
      for (final key in assetKeys) {
        final fileName = key.split('/').last;
        if (entry.value.any(
          (token) => InstalledFonts.fileNameMatchesToken(fileName, token),
        )) {
          matched.add(key);
        }
      }
      if (matched.isNotEmpty) result[entry.key] = matched;
    }
    return result;
  }

  /// 把 [assetKeys] 指向的字体资源注册到字体族 [family]。
  static Future<void> registerFamily(
    String family,
    List<String> assetKeys, {
    AssetBundle? bundle,
  }) async {
    final b = bundle ?? rootBundle;
    final loader = FontLoader(family);
    for (final key in assetKeys) {
      loader.addFont(b.load(key));
    }
    await loader.load();
  }
}
