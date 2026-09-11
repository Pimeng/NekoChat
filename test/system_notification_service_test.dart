import 'package:flutter_test/flutter_test.dart';
import 'package:neko_chat/core/notifications/system_notification_service.dart';

void main() {
  group('通知策略', () {
    test('应用在后台时通知新消息', () {
      expect(
        shouldNotifyForConversation(
          appIsFocused: false,
          selectedConversationId: 'chat-a',
          incomingConversationId: 'chat-a',
        ),
        isTrue,
      );
    });

    test('正在查看当前会话时不重复通知', () {
      expect(
        shouldNotifyForConversation(
          appIsFocused: true,
          selectedConversationId: 'chat-a',
          incomingConversationId: 'chat-a',
        ),
        isFalse,
      );
    });

    test('应用在前台但消息来自其他会话时通知', () {
      expect(
        shouldNotifyForConversation(
          appIsFocused: true,
          selectedConversationId: 'chat-a',
          incomingConversationId: 'chat-b',
        ),
        isTrue,
      );
    });
  });
}
