import 'dart:async';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neko_chat/app/app_controller.dart';
import 'package:neko_chat/core/models/models.dart';
import 'package:neko_chat/features/chat/main_shell.dart';

class _DropSpyController extends AppController {
  final droppedPaths = <String>[];
  String? droppedConversationId;
  Completer<void>? sendCompleter;

  @override
  Future<void> sendDroppedFiles({
    required String conversationId,
    required Iterable<String> filePaths,
  }) async {
    droppedConversationId = conversationId;
    droppedPaths.addAll(filePaths);
    await sendCompleter?.future;
  }
}

_DropSpyController _groupController() {
  final now = DateTime.fromMillisecondsSinceEpoch(1000);
  final controller = _DropSpyController();
  controller.stage = AppStage.ready;
  controller.identity = LocalIdentity(
    deviceId: 'local-device',
    displayName: '我',
    createdAt: now,
    lastLoginAt: now,
  );
  controller.groups = [
    ChatGroup(
      groupId: 'group-1',
      name: '测试群',
      ownerDeviceId: 'local-device',
      createdAt: now,
    ),
  ];
  controller.selectedGroupId = 'group-1';
  return controller;
}

void main() {
  testWidgets('拖入文件显示提示并在松手后立即发送', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = _groupController()..sendCompleter = Completer<void>();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(home: MainShell(controller: controller)),
    );

    final target = tester.widget<DropTarget>(find.byType(DropTarget));
    target.onDragEntered!(
      DropEventDetails(
        localPosition: const Offset(20, 20),
        globalPosition: const Offset(360, 20),
      ),
    );
    await tester.pump();
    expect(find.text('松开发送文件'), findsOneWidget);

    target.onDragDone!(
      DropDoneDetails(
        files: [
          DropItemDirectory(r'C:\资料夹', const []),
          DropItemFile(r'C:\资料\报告.pdf'),
          DropItemFile(r'C:\资料\照片.png'),
        ],
        localPosition: const Offset(20, 20),
        globalPosition: const Offset(360, 20),
      ),
    );
    await tester.pump();

    expect(controller.droppedConversationId, 'group:group-1');
    expect(controller.droppedPaths, [r'C:\资料\报告.pdf', r'C:\资料\照片.png']);
    expect(find.text('正在发送文件…'), findsOneWidget);

    controller.sendCompleter!.complete();
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('file-drop-overlay')), findsNothing);
  });
}
