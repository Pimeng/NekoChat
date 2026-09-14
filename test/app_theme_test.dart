import 'package:flutter_test/flutter_test.dart';
import 'package:neko_chat/app/neko_chat_app.dart';

void main() {
  test('应用主题在所有 Material 界面统一使用霞鹜文楷', () {
    expect(buildNekoChatTheme().textTheme.bodyMedium?.fontFamily, 'LXGWWenKai');
  });
}
