import '../../core/models/models.dart';

enum CollisionDecision { keepOutgoing, acceptIncoming }

abstract final class ChatStateMachine {
  static bool canStartRequest({
    required bool online,
    required bool blocked,
    required bool active,
    required bool hasPendingRequest,
  }) {
    return online && !blocked && !active && !hasPendingRequest;
  }

  static bool canRestoreTrustedSession({
    required bool trusted,
    required bool blocked,
  }) => trusted && !blocked;

  static bool canTransition(ChatSessionState from, ChatSessionState to) {
    if (from == to) return true;
    return switch (from) {
      ChatSessionState.none => {
        ChatSessionState.pendingIncoming,
        ChatSessionState.pendingOutgoing,
        ChatSessionState.blocked,
      }.contains(to),
      ChatSessionState.pendingIncoming || ChatSessionState.pendingOutgoing => {
        ChatSessionState.pendingIncoming,
        ChatSessionState.pendingOutgoing,
        ChatSessionState.active,
        ChatSessionState.rejected,
        ChatSessionState.none,
        ChatSessionState.blocked,
      }.contains(to),
      ChatSessionState.active => {
        ChatSessionState.none,
        ChatSessionState.blocked,
      }.contains(to),
      ChatSessionState.rejected => {
        ChatSessionState.none,
        ChatSessionState.pendingIncoming,
        ChatSessionState.pendingOutgoing,
        ChatSessionState.blocked,
      }.contains(to),
      ChatSessionState.blocked => to == ChatSessionState.none,
    };
  }

  static CollisionDecision resolveCollision({
    required String localDeviceId,
    required String remoteDeviceId,
  }) {
    return localDeviceId.compareTo(remoteDeviceId) < 0
        ? CollisionDecision.keepOutgoing
        : CollisionDecision.acceptIncoming;
  }
}
