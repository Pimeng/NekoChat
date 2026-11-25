import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:neko_chat/app/app_controller.dart';
import 'package:neko_chat/core/database/app_database.dart';
import 'package:neko_chat/core/models/models.dart';
import 'package:neko_chat/features/chat/main_shell.dart';
import 'package:neko_chat/features/settings/settings_page.dart';

/// 1×1 透明 PNG。
const _tinyPngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';

/// 另一张内容不同的 1×1 PNG（纯红）。
const _redPngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg==';

AppController _renderController({
  required List<ChatMessage> messages,
  List<FavoriteSticker> stickers = const [],
}) {
  final now = DateTime.fromMillisecondsSinceEpoch(1000);
  final controller = AppController();
  controller.stage = AppStage.ready;
  controller.identity = LocalIdentity(
    deviceId: 'local-device',
    displayName: '我',
    createdAt: now,
    lastLoginAt: now,
  );
  controller.peers = [
    DiscoveredPeer(
      deviceId: 'peer-device',
      displayName: '李四',
      ip: '127.0.0.1',
      port: 19999,
      lastSeen: now,
      trusted: true,
      online: true,
    ),
  ];
  controller.chats = [
    const ChatSummary(
      chatId: 'chat-1',
      peerDeviceId: 'peer-device',
      displayName: '李四',
      state: ChatSessionState.active,
      sessionId: 'session-1',
    ),
  ];
  controller.selectedChatId = 'chat-1';
  controller.messages = messages;
  controller.favoriteStickers = stickers;
  return controller;
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
  });

  test('数据库能保存、按时间倒序读取、相对路径编解码并删除收藏表情', () async {
    final dataDir = await Directory.systemTemp.createTemp('neko-sticker-db-');
    addTearDown(() => dataDir.delete(recursive: true));

    final db = AppDatabase(directory: () async => dataDir);
    await db.open(List<int>.filled(32, 7));
    addTearDown(db.close);

    final firstPath = p.join(dataDir.path, 'stickers', 'aaa.png');
    final secondPath = p.join(dataDir.path, 'stickers', 'bbb.png');
    await db.saveFavoriteSticker(
      FavoriteSticker(
        stickerId: 's-1',
        filePath: firstPath,
        fileHash: 'hash-1',
        fileName: 'a.png',
        mimeType: 'image/png',
        fileSize: 68,
        createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
      ),
    );
    await db.saveFavoriteSticker(
      FavoriteSticker(
        stickerId: 's-2',
        filePath: secondPath,
        fileHash: 'hash-2',
        fileName: 'b.png',
        mimeType: 'image/png',
        fileSize: 70,
        createdAt: DateTime.fromMillisecondsSinceEpoch(2000),
      ),
    );

    final loaded = await db.loadFavoriteStickers();
    expect(loaded.map((s) => s.stickerId).toList(), ['s-2', 's-1']);
    expect(loaded.first.filePath, secondPath);

    await db.deleteFavoriteSticker('s-2');
    final remaining = await db.loadFavoriteStickers();
    expect(remaining.map((s) => s.stickerId).toList(), ['s-1']);
  });

  test('AppController 添加收藏表情会复制到 stickers 目录、按内容去重并在移除时清理文件', () async {
    final dataDir = await Directory.systemTemp.createTemp('neko-sticker-ctrl-');
    final srcDir = await Directory.systemTemp.createTemp('neko-sticker-src-');
    addTearDown(() async {
      await dataDir.delete(recursive: true);
      await srcDir.delete(recursive: true);
    });

    final db = AppDatabase(directory: () async => dataDir);
    await db.open(List<int>.filled(32, 3));
    final controller = AppController(database: db);
    addTearDown(controller.dispose);

    final img1 = File(p.join(srcDir.path, 'cat.png'));
    await img1.writeAsBytes(base64Decode(_tinyPngBase64));
    final img2 = File(p.join(srcDir.path, 'red.png'));
    await img2.writeAsBytes(base64Decode(_redPngBase64));
    final txt = File(p.join(srcDir.path, 'note.txt'));
    await txt.writeAsString('not an image');

    expect(await controller.addFavoriteStickerFromPath(img1.path), isTrue);
    expect(controller.favoriteStickers, hasLength(1));
    final savedFile = File(controller.favoriteStickers.first.filePath);
    expect(await savedFile.exists(), isTrue);
    expect(p.isWithin(p.join(dataDir.path, 'stickers'), savedFile.path), isTrue);

    // 重复图片不会再次入库
    expect(await controller.addFavoriteStickerFromPath(img1.path), isFalse);
    expect(controller.favoriteStickers, hasLength(1));
    expect(controller.topRightMessage, '该表情已在收藏中');

    // 非图片文件被拒绝，并给出准确的原因提示（而非误报超大小）
    expect(await controller.addFavoriteStickerFromPath(txt.path), isFalse);
    expect(controller.favoriteStickers, hasLength(1));
    expect(controller.topRightMessage, '不支持该文件格式，请选择常见图片格式');

    // 文件头为特殊容器（如伪装/HEIF/AVIF）但扩展名为图片时，回退扩展名判定仍可收藏
    final specialImg = File(p.join(srcDir.path, 'special.jpg'));
    await specialImg.writeAsBytes([
      0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70, 0x6D, 0x70, 0x34, 0x32,
    ]);
    expect(await controller.addFavoriteStickerFromPath(specialImg.path), isTrue);
    expect(controller.favoriteStickers, hasLength(2));

    // 不同图片可以继续添加并排在最前
    expect(await controller.addFavoriteStickerFromPath(img2.path), isTrue);
    expect(controller.favoriteStickers, hasLength(3));

    // 移除表情同时删除数据库记录与 stickers 目录内的副本
    final toRemove = controller.favoriteStickers.last;
    await controller.removeFavoriteSticker(toRemove);
    expect(controller.favoriteStickers, hasLength(2));
    expect(await File(toRemove.filePath).exists(), isFalse);

    // 调整排序并验证持久化到数据库
    final beforeIds = controller.favoriteStickers
        .map((s) => s.stickerId)
        .toList();
    await controller.reorderFavoriteStickers(1, 0);
    final afterIds = controller.favoriteStickers
        .map((s) => s.stickerId)
        .toList();
    expect(afterIds, [beforeIds[1], beforeIds[0]]);

    final persistedIds = (await db.loadFavoriteStickers())
        .map((s) => s.stickerId)
        .toList();
    expect(persistedIds, afterIds);

    // 设置与清除备注，并验证持久化到数据库
    await controller.setFavoriteStickerRemark(
      controller.favoriteStickers.first,
      '开心 哈哈',
    );
    expect(controller.favoriteStickers.first.remark, '开心 哈哈');
    final reloadedWithRemark = await db.loadFavoriteStickers();
    expect(reloadedWithRemark.first.remark, '开心 哈哈');

    await controller.setFavoriteStickerRemark(
      controller.favoriteStickers.first,
      '   ',
    );
    expect(controller.favoriteStickers.first.remark, isNull);
    final reloadedCleared = await db.loadFavoriteStickers();
    expect(reloadedCleared.first.remark, isNull);
  });

  testWidgets('图片气泡右键显示“添加到表情”，纯文字气泡不显示', (tester) async {
    final directory = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('neko-sticker-menu-'),
    ))!;
    addTearDown(() => directory.delete(recursive: true));
    final image = File(p.join(directory.path, 'meme.png'));
    await tester.runAsync(
      () => image.writeAsBytes(base64Decode(_tinyPngBase64)),
    );

    final controller = _renderController(
      messages: [
        ChatMessage(
          messageId: 'm-img',
          chatId: 'chat-1',
          senderDeviceId: 'peer-device',
          content: 'meme.png',
          timestamp: DateTime.fromMillisecondsSinceEpoch(1000),
          status: MessageStatus.sent,
          kind: MessageKind.image,
          fileName: 'meme.png',
          filePath: image.path,
          fileSize: 68,
          mimeType: 'image/png',
        ),
        ChatMessage(
          messageId: 'm-txt',
          chatId: 'chat-1',
          senderDeviceId: 'peer-device',
          content: '普通文字消息',
          timestamp: DateTime.fromMillisecondsSinceEpoch(2000),
          status: MessageStatus.sent,
        ),
      ],
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: AnimatedBuilder(
          animation: controller,
          builder: (_, _) => MainShell(controller: controller),
        ),
      ),
    );
    await tester.pump();

    // 右键图片气泡：应看到“添加到表情”
    await tester.tap(
      find.byType(Image),
      buttons: kSecondaryMouseButton,
      warnIfMissed: false,
    );
    await tester.pumpAndSettle();
    expect(find.text('添加到表情'), findsOneWidget);

    // 关闭菜单
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(find.text('添加到表情'), findsNothing);

    // 右键文字气泡：不应看到“添加到表情”
    await tester.tap(find.text('普通文字消息'), buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    expect(find.text('复制'), findsOneWidget);
    expect(find.text('添加到表情'), findsNothing);
  });

  testWidgets('点击表情按钮弹出收藏面板，可切换常用 Emoji 并插入输入框', (tester) async {
    final directory = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('neko-sticker-picker-'),
    ))!;
    addTearDown(() => directory.delete(recursive: true));
    final image = File(p.join(directory.path, 'fav.png'));
    await tester.runAsync(
      () => image.writeAsBytes(base64Decode(_tinyPngBase64)),
    );

    final controller = _renderController(
      messages: const [],
      stickers: [
        FavoriteSticker(
          stickerId: 'fav-1',
          filePath: image.path,
          fileHash: 'hash-fav-1',
          fileName: 'fav.png',
          mimeType: 'image/png',
          fileSize: 68,
          createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
        ),
      ],
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: AnimatedBuilder(
          animation: controller,
          builder: (_, _) => MainShell(controller: controller),
        ),
      ),
    );
    await tester.pump();

    // 打开表情面板
    await tester.tap(find.byTooltip('表情与收藏'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('sticker-picker-panel')), findsOneWidget);
    expect(find.byKey(const ValueKey('add-sticker-button')), findsOneWidget);
    expect(find.byKey(const ValueKey('sticker-tile-fav-1')), findsOneWidget);

    // 切换到常用 Emoji 标签并点击一个表情
    await tester.tap(find.byKey(const ValueKey('sticker-tab-emoji')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('😀'));
    await tester.pump();

    final textField = tester.widget<TextField>(find.byType(TextField));
    expect(textField.controller?.text, '😀');

    // 点击空白处关闭面板
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('sticker-picker-panel')), findsNothing);
  });

  testWidgets('收藏表情面板支持右键“移到最前”排序', (tester) async {
    final directory = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('neko-sticker-reorder-'),
    ))!;
    addTearDown(() => directory.delete(recursive: true));
    final img1 = File(p.join(directory.path, 's1.png'));
    final img2 = File(p.join(directory.path, 's2.png'));
    await tester.runAsync(() async {
      await img1.writeAsBytes(base64Decode(_tinyPngBase64));
      await img2.writeAsBytes(base64Decode(_redPngBase64));
    });

    final controller = _renderController(
      messages: const [],
      stickers: [
        FavoriteSticker(
          stickerId: 'fav-1',
          filePath: img1.path,
          fileHash: 'hash-1',
          fileName: 's1.png',
          mimeType: 'image/png',
          fileSize: 68,
          createdAt: DateTime.fromMillisecondsSinceEpoch(2000),
          sortOrder: 0,
        ),
        FavoriteSticker(
          stickerId: 'fav-2',
          filePath: img2.path,
          fileHash: 'hash-2',
          fileName: 's2.png',
          mimeType: 'image/png',
          fileSize: 68,
          createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
          sortOrder: 1,
        ),
      ],
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: AnimatedBuilder(
          animation: controller,
          builder: (_, _) => MainShell(controller: controller),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.byTooltip('表情与收藏'));
    await tester.pumpAndSettle();

    // 右键第二个表情，点击“移到最前”
    await tester.tap(
      find.byKey(const ValueKey('sticker-tile-fav-2')),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
    expect(find.text('移到最前'), findsOneWidget);

    await tester.tap(find.text('移到最前'));
    await tester.pumpAndSettle();

    expect(
      controller.favoriteStickers.map((s) => s.stickerId).toList(),
      ['fav-2', 'fav-1'],
    );
  });

  testWidgets('支持给表情设置备注，输入备注时快捷弹出候选栏并可点击发送', (tester) async {
    final directory = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('neko-sticker-remark-'),
    ))!;
    addTearDown(() => directory.delete(recursive: true));
    final img = File(p.join(directory.path, 'cirno.png'));
    await tester.runAsync(
      () => img.writeAsBytes(base64Decode(_tinyPngBase64)),
    );

    final controller = _renderController(
      messages: const [],
      stickers: [
        FavoriteSticker(
          stickerId: 'fav-cirno',
          filePath: img.path,
          fileHash: 'hash-cirno',
          fileName: 'cirno.png',
          mimeType: 'image/png',
          fileSize: 68,
          createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
        ),
      ],
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: AnimatedBuilder(
          animation: controller,
          builder: (_, _) => MainShell(controller: controller),
        ),
      ),
    );
    await tester.pump();

    // 打开表情面板，右键表情 -> 设置备注
    await tester.tap(find.byTooltip('表情与收藏'));
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey('sticker-tile-fav-cirno')),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
    expect(find.text('设置备注'), findsOneWidget);

    await tester.tap(find.text('设置备注'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey('sticker-remark-field')),
      '琪露诺 开心',
    );
    await tester.tap(find.byKey(const ValueKey('sticker-remark-save')));
    await tester.pumpAndSettle();

    expect(controller.favoriteStickers.first.remark, '琪露诺 开心');

    // 在聊天输入框输入备注关键词“开心”，快捷候选栏应弹出对应表情
    await tester.enterText(find.byType(TextField), '开心');
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('quick-sticker-suggestion-bar')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('quick-sticker-fav-cirno')),
      findsOneWidget,
    );

    // 点击关闭按钮可临时收起当前词的联想
    await tester.tap(find.byKey(const ValueKey('quick-sticker-dismiss')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('quick-sticker-suggestion-bar')),
      findsNothing,
    );

    // 换个关键词再次弹出，点击候选表情会清空输入框
    await tester.enterText(find.byType(TextField), '琪露诺');
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('quick-sticker-fav-cirno')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('quick-sticker-fav-cirno')));
    await tester.pumpAndSettle();

    final textField = tester.widget<TextField>(find.byType(TextField));
    expect(textField.controller?.text, isEmpty);

    // 关闭表情联想开关后，再输入备注关键词不再弹出候选栏
    await controller.setStickerSuggestionsEnabled(false);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '琪露诺');
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('quick-sticker-suggestion-bar')),
      findsNothing,
    );
  });

  testWidgets('聊天设置页可切换表情联想开关', (tester) async {
    final controller = _renderController(messages: const []);
    addTearDown(controller.dispose);
    expect(controller.stickerSuggestionsEnabled, isTrue);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SettingsSectionPane(
            controller: controller,
            section: SettingsSection.chat,
          ),
        ),
      ),
    );
    await tester.pump();

    final switchFinder = find.byKey(const ValueKey('sticker-suggestions-switch'));
    expect(switchFinder, findsOneWidget);
    await tester.ensureVisible(switchFinder);
    await tester.tap(switchFinder);
    await tester.pumpAndSettle();

    expect(controller.stickerSuggestionsEnabled, isFalse);
  });
}
