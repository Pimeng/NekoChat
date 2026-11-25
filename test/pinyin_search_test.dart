import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:neko_chat/core/models/models.dart';
import 'package:neko_chat/core/text/pinyin_search.dart';
import 'package:neko_chat/features/chat/mention_autocomplete.dart';
import 'package:neko_chat/features/chat/sticker_picker.dart';

void main() {
  test('matchesPinyinSearch 支持原文、全拼、首字母与忽略常见标点', () {
    expect(matchesPinyinSearch('晓猫（前端）', '晓猫'), isTrue);
    expect(matchesPinyinSearch('晓猫（前端）', 'xiaomao'), isTrue);
    expect(matchesPinyinSearch('晓猫（前端）', 'XIAOMAO'), isTrue);
    expect(matchesPinyinSearch('晓猫（前端）', 'xm'), isTrue);
    expect(matchesPinyinSearch('晓猫（前端）', 'xmqd'), isTrue);
    expect(matchesPinyinSearch('晓猫（前端）', 'qianduan'), isTrue);
    expect(matchesPinyinSearch('林晓猫', 'lxm'), isTrue);
    expect(matchesPinyinSearch('三花开发机', 'shkfj'), isTrue);
    expect(matchesPinyinSearch('三花开发机', 'sanhua'), isTrue);
    expect(matchesPinyinSearch('晓猫（前端）', 'zhangsan'), isFalse);
    expect(matchesPinyinSearch('晓猫（前端）', '不存在'), isFalse);
  });

  test('matchStickersByRemark 支持按全拼和首字母联想收藏表情', () {
    final stickers = [
      FavoriteSticker(
        stickerId: 's-1',
        filePath: 'a.gif',
        fileHash: 'h1',
        fileName: 'a.gif',
        mimeType: 'image/gif',
        fileSize: 100,
        createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
        remark: '琪露诺 开心',
      ),
      FavoriteSticker(
        stickerId: 's-2',
        filePath: 'b.png',
        fileHash: 'h2',
        fileName: 'b.png',
        mimeType: 'image/png',
        fileSize: 100,
        createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
        remark: '猫猫',
      ),
    ];

    expect(
      matchStickersByRemark(stickers, 'qilunuo').map((s) => s.stickerId),
      ['s-1'],
    );
    expect(
      matchStickersByRemark(stickers, 'qln').map((s) => s.stickerId),
      ['s-1'],
    );
    expect(
      matchStickersByRemark(stickers, 'kx').map((s) => s.stickerId),
      ['s-1'],
    );
    expect(
      matchStickersByRemark(stickers, 'mm').map((s) => s.stickerId),
      ['s-2'],
    );
  });

  testWidgets('群聊 @提及 支持全拼和首字母过滤成员', (tester) async {
    final controller = TextEditingController();
    final focusNode = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: MentionAutocomplete(
              controller: controller,
              focusNode: focusNode,
              enabled: true,
              onSend: () {},
              loadCandidates: () async => const [
                MentionCandidate(
                  deviceId: 'dev-1',
                  displayName: '晓猫（前端）',
                  insertionName: '林晓猫',
                  originalName: '林晓猫',
                ),
                MentionCandidate(
                  deviceId: 'dev-2',
                  displayName: '三花开发机',
                  insertionName: '三花开发机',
                ),
              ],
            ),
          ),
        ),
      ),
    );

    // 全拼匹配
    await tester.enterText(find.byType(TextField), '@xiaomao');
    await tester.pumpAndSettle();
    expect(find.text('晓猫（前端）'), findsOneWidget);
    expect(find.text('三花开发机'), findsNothing);

    // 首字母匹配
    await tester.enterText(find.byType(TextField), '@shkfj');
    await tester.pumpAndSettle();
    expect(find.text('三花开发机'), findsOneWidget);
    expect(find.text('晓猫（前端）'), findsNothing);

    // 原名全拼也可匹配
    await tester.enterText(find.byType(TextField), '@linxiaomao');
    await tester.pumpAndSettle();
    expect(find.text('晓猫（前端）'), findsOneWidget);
  });
}
