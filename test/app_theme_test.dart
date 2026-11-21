import 'package:flutter_test/flutter_test.dart';
import 'package:neko_chat/app/neko_chat_app.dart';

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
}
