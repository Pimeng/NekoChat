import 'package:flutter_test/flutter_test.dart';
import 'package:neko_chat/core/models/models.dart';
import 'package:neko_chat/features/chat/chat_state_machine.dart';

void main() {
  group('ChatStateMachine', () {
    test('同一设备已有待处理请求时不允许重复发送好友申请', () {
      expect(
        ChatStateMachine.canStartRequest(
          online: true,
          blocked: false,
          active: false,
          hasPendingRequest: true,
        ),
        isFalse,
      );
      expect(
        ChatStateMachine.canStartRequest(
          online: true,
          blocked: false,
          active: false,
          hasPendingRequest: false,
        ),
        isTrue,
      );
    });

    test('已验证且未拉黑的设备可以免申请直接恢复会话', () {
      expect(
        ChatStateMachine.canRestoreTrustedSession(
          trusted: true,
          blocked: false,
        ),
        isTrue,
      );
      expect(
        ChatStateMachine.canRestoreTrustedSession(trusted: true, blocked: true),
        isFalse,
      );
    });

    test('未接受的会话不能直接变为 active', () {
      expect(
        ChatStateMachine.canTransition(
          ChatSessionState.none,
          ChatSessionState.active,
        ),
        isFalse,
      );
    });

    test('邀请接受、拒绝和关闭是合法迁移', () {
      expect(
        ChatStateMachine.canTransition(
          ChatSessionState.pendingOutgoing,
          ChatSessionState.active,
        ),
        isTrue,
      );
      expect(
        ChatStateMachine.canTransition(
          ChatSessionState.pendingIncoming,
          ChatSessionState.rejected,
        ),
        isTrue,
      );
      expect(
        ChatStateMachine.canTransition(
          ChatSessionState.active,
          ChatSessionState.none,
        ),
        isTrue,
      );
    });

    test('同时申请时双方会选择同一个请求方向', () {
      final atA = ChatStateMachine.resolveCollision(
        localDeviceId: 'a-device',
        remoteDeviceId: 'b-device',
      );
      final atB = ChatStateMachine.resolveCollision(
        localDeviceId: 'b-device',
        remoteDeviceId: 'a-device',
      );

      expect(atA, CollisionDecision.keepOutgoing);
      expect(atB, CollisionDecision.acceptIncoming);
    });
  });
}
