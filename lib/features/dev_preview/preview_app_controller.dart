import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../app/app_controller.dart';
import '../../core/boss_key/boss_key_service.dart';
import '../../core/models/models.dart';
import '../../core/notifications/notification_window_channel.dart';
import '../../core/notifications/standalone_notification_service.dart';
import '../chat/mention_autocomplete.dart';

/// 组件预览模式共用的模拟数据工厂。
abstract final class PreviewFixtures {
  static final DateTime baseTime = DateTime(2026, 11, 21, 14, 30);

  static const localDeviceId = 'neko-local-01a2b3c4-5678';
  static const aliceDeviceId = 'neko-alice-99f0e1d2-1111';
  static const bobDeviceId = 'neko-bob-77c8b9a0-2222';
  static const carolDeviceId = 'neko-carol-55d6e7f8-3333';
  static const blockedDeviceId = 'neko-blocked-33a4b5c6-4444';

  static const activeChatId = 'chat-preview-alice';
  static const offlineChatId = 'chat-preview-carol';
  static const primaryGroupId = 'group-preview-lab';
  static const secondaryGroupId = 'group-preview-lunch';

  static LocalIdentity localIdentity() => LocalIdentity(
    deviceId: localDeviceId,
    displayName: '橘猫工程师',
    createdAt: baseTime.subtract(const Duration(days: 12)),
    lastLoginAt: baseTime,
  );

  static List<DiscoveredPeer> peers() => [
    DiscoveredPeer(
      deviceId: aliceDeviceId,
      displayName: '林晓猫',
      ip: '192.168.10.21',
      port: 23333,
      lastSeen: baseTime,
      trusted: true,
      online: true,
      pairingHash: 'a' * 64,
    ),
    DiscoveredPeer(
      deviceId: bobDeviceId,
      displayName: '三花开发机',
      ip: '192.168.10.35',
      port: 23333,
      lastSeen: baseTime,
      trusted: false,
      online: true,
      pairingHash: 'b' * 64,
    ),
    DiscoveredPeer(
      deviceId: carolDeviceId,
      displayName: '蓝猫测试机',
      ip: '192.168.10.48',
      port: 23333,
      lastSeen: baseTime.subtract(const Duration(hours: 2)),
      trusted: true,
      online: false,
    ),
    DiscoveredPeer(
      deviceId: blockedDeviceId,
      displayName: '未知访客机',
      ip: '192.168.10.99',
      port: 23333,
      lastSeen: baseTime.subtract(const Duration(minutes: 15)),
      trusted: true,
      online: true,
    ),
  ];

  static Map<String, TrustedPeer> trustedPeers() => {
    aliceDeviceId: TrustedPeer(
      deviceId: aliceDeviceId,
      displayName: '林晓猫',
      lastKnownIp: '192.168.10.21',
      verifiedAt: baseTime.subtract(const Duration(days: 3)),
    ),
    carolDeviceId: TrustedPeer(
      deviceId: carolDeviceId,
      displayName: '蓝猫测试机',
      lastKnownIp: '192.168.10.48',
      verifiedAt: baseTime.subtract(const Duration(days: 5)),
    ),
    blockedDeviceId: TrustedPeer(
      deviceId: blockedDeviceId,
      displayName: '未知访客机',
      lastKnownIp: '192.168.10.99',
      verifiedAt: baseTime.subtract(const Duration(days: 1)),
      blocked: true,
    ),
  };

  static List<ChatSummary> chats() => [
    ChatSummary(
      chatId: activeChatId,
      peerDeviceId: aliceDeviceId,
      displayName: '林晓猫',
      state: ChatSessionState.active,
      sessionId: 'session-alice',
      createdAt: baseTime.subtract(const Duration(days: 3)),
      lastMessageAt: baseTime.subtract(const Duration(minutes: 2)),
      unreadCount: 3,
      lastMessagePreview: '热重载已经生效，界面样式立刻刷新了！',
    ),
    ChatSummary(
      chatId: offlineChatId,
      peerDeviceId: carolDeviceId,
      displayName: '蓝猫测试机',
      state: ChatSessionState.active,
      sessionId: 'session-carol',
      createdAt: baseTime.subtract(const Duration(days: 5)),
      lastMessageAt: baseTime.subtract(const Duration(hours: 3)),
      unreadCount: 0,
      lastMessagePreview: '昨天的测试报告已经打包好了',
    ),
  ];

  static List<ChatGroup> groups() => [
    ChatGroup(
      groupId: primaryGroupId,
      name: '机房联调群',
      ownerDeviceId: localDeviceId,
      createdAt: baseTime.subtract(const Duration(days: 2)),
      lastMessageAt: baseTime.subtract(const Duration(minutes: 5)),
      unreadCount: 12,
      lastMessagePreview: '林晓猫: @橘猫工程师 麻烦看一下新版气泡间距',
    ),
    ChatGroup(
      groupId: secondaryGroupId,
      name: '午饭拼单小队',
      ownerDeviceId: aliceDeviceId,
      createdAt: baseTime.subtract(const Duration(days: 6)),
      lastMessageAt: baseTime.subtract(const Duration(days: 1)),
      unreadCount: 0,
      lastMessagePreview: '今天吃黄焖鸡还是拉面？',
    ),
  ];

  static ChatRequest incomingRequest() => const ChatRequest(
    requestId: 'req-incoming-1',
    peerDeviceId: 'neko-newpeer-88aa77bb-5555',
    displayName: '布偶设计师',
    ip: '192.168.10.62',
    incoming: true,
    viaPairingCode: true,
  );

  static ChatRequest outgoingRequest() => const ChatRequest(
    requestId: 'req-outgoing-1',
    peerDeviceId: bobDeviceId,
    displayName: '三花开发机',
    ip: '192.168.10.35',
    incoming: false,
  );

  static GroupInvitation groupInvitation() => const GroupInvitation(
    inviteId: 'invite-preview-1',
    groupId: 'group-design-review',
    groupName: 'UI 走查与主题评审',
    ownerDeviceId: aliceDeviceId,
    ownerDisplayName: '林晓猫',
    inviterDeviceId: aliceDeviceId,
    inviterDisplayName: '林晓猫',
    ip: '192.168.10.21',
  );

  static List<ChatMessage> privateMessages() => [
    ChatMessage(
      messageId: 'msg-p-1',
      chatId: activeChatId,
      senderDeviceId: aliceDeviceId,
      content: '哈喽！新的组件预览开发模式上线了吗？',
      timestamp: baseTime.subtract(const Duration(minutes: 12)),
      status: MessageStatus.sent,
    ),
    ChatMessage(
      messageId: 'msg-p-2',
      chatId: activeChatId,
      senderDeviceId: localDeviceId,
      content: '已经好了，现在改完任何 Widget 保存后按 r 就能热重载看到效果。',
      timestamp: baseTime.subtract(const Duration(minutes: 10)),
      status: MessageStatus.sent,
      replyToMessageId: 'msg-p-1',
      replyToSenderId: aliceDeviceId,
      replyToPreview: '哈喽！新的组件预览开发模式上线了吗？',
    ),
    ChatMessage(
      messageId: 'msg-p-3',
      chatId: activeChatId,
      senderDeviceId: aliceDeviceId,
      content: '',
      timestamp: baseTime.subtract(const Duration(minutes: 8)),
      status: MessageStatus.awaitingAcceptance,
      kind: MessageKind.file,
      fileName: 'neko_ui_spec_v2.pdf',
      fileSize: 18 * 1024 * 1024,
      mimeType: 'application/pdf',
    ),
    ChatMessage(
      messageId: 'msg-p-4',
      chatId: activeChatId,
      senderDeviceId: localDeviceId,
      content: '',
      timestamp: baseTime.subtract(const Duration(minutes: 6)),
      status: MessageStatus.sent,
      kind: MessageKind.file,
      fileName: 'preview_notes.md',
      filePath: r'C:\nonexistent\preview_notes.md',
      fileSize: 24 * 1024,
      mimeType: 'text/markdown',
    ),
    ChatMessage(
      messageId: 'msg-p-5',
      chatId: activeChatId,
      senderDeviceId: localDeviceId,
      content: '',
      timestamp: baseTime.subtract(const Duration(minutes: 4)),
      status: MessageStatus.recalled,
      recalledAt: baseTime.subtract(const Duration(minutes: 3)),
      recalledByDeviceId: localDeviceId,
    ),
    ChatMessage(
      messageId: 'msg-p-6',
      chatId: activeChatId,
      senderDeviceId: aliceDeviceId,
      content: '热重载已经生效，界面样式立刻刷新了！',
      timestamp: baseTime.subtract(const Duration(minutes: 2)),
      status: MessageStatus.sent,
    ),
  ];

  static List<ChatMessage> groupMessages() => [
    ChatMessage(
      messageId: 'msg-g-1',
      chatId: 'group:$primaryGroupId',
      groupId: primaryGroupId,
      senderDeviceId: localDeviceId,
      content: '大家可以在组件预览里单独查看气泡、卡片和设置页。',
      timestamp: baseTime.subtract(const Duration(minutes: 15)),
      status: MessageStatus.sent,
    ),
    ChatMessage(
      messageId: 'msg-g-2',
      chatId: 'group:$primaryGroupId',
      groupId: primaryGroupId,
      senderDeviceId: aliceDeviceId,
      content: '@橘猫工程师 麻烦看一下新版气泡间距和角色徽标样式！',
      timestamp: baseTime.subtract(const Duration(minutes: 5)),
      status: MessageStatus.sent,
      mentions: const [localDeviceId],
    ),
    ChatMessage(
      messageId: 'msg-g-3',
      chatId: 'group:$primaryGroupId',
      groupId: primaryGroupId,
      senderDeviceId: bobDeviceId,
      content: '正在传输日志压缩包…',
      timestamp: baseTime.subtract(const Duration(minutes: 1)),
      status: MessageStatus.pending,
      kind: MessageKind.file,
      fileName: 'lan_trace_logs.zip',
      fileSize: 4 * 1024 * 1024,
      mimeType: 'application/zip',
    ),
  ];

  static List<PendingAttachment> pendingAttachments() => const [
    PendingAttachment(
      path: r'C:\preview\architecture_diagram.png',
      fileName: 'architecture_diagram.png',
      fileSize: 428 * 1024,
      mimeType: 'image/png',
      isImage: true,
    ),
    PendingAttachment(
      path: r'C:\preview\release_notes.pdf',
      fileName: 'release_notes_v1.0.3.pdf',
      fileSize: 2 * 1024 * 1024,
      mimeType: 'application/pdf',
      isImage: false,
    ),
    PendingAttachment(
      path: r'C:\preview\config.json',
      fileName: 'network_config.json',
      fileSize: 3 * 1024,
      mimeType: 'application/json',
      isImage: false,
    ),
  ];

  static List<MentionCandidate> mentionCandidates() => const [
    MentionCandidate(
      deviceId: aliceDeviceId,
      displayName: '晓猫（前端）',
      insertionName: '林晓猫',
      originalName: '林晓猫',
    ),
    MentionCandidate(
      deviceId: bobDeviceId,
      displayName: '三花开发机',
      insertionName: '三花开发机',
    ),
    MentionCandidate(
      deviceId: carolDeviceId,
      displayName: '蓝猫测试机',
      insertionName: '蓝猫测试机',
    ),
  ];

  static List<GroupMember> groupMembers(String groupId) => [
    GroupMember(
      groupId: groupId,
      deviceId: localDeviceId,
      displayName: '橘猫工程师',
      role: GroupRole.owner,
    ),
    GroupMember(
      groupId: groupId,
      deviceId: aliceDeviceId,
      displayName: '林晓猫',
      role: GroupRole.admin,
    ),
    GroupMember(
      groupId: groupId,
      deviceId: bobDeviceId,
      displayName: '三花开发机',
      role: GroupRole.member,
    ),
  ];
}

/// 纯内存运行的预览控制器，不会访问数据库、文件系统、网络或系统热键。
class PreviewAppController extends AppController {
  PreviewAppController({AppStage initialStage = AppStage.ready}) {
    reset(initialStage: initialStage);
  }

  final Map<String, List<ChatMessage>> _messagesByConversation = {};
  final Map<String, Map<String, GroupRole>> _rolesByGroup = {};
  final Map<String, List<GroupMember>> _membersByGroup = {};
  int _nextMessageSeq = 100;

  void reset({AppStage initialStage = AppStage.ready}) {
    stage = initialStage;
    errorMessage = null;
    topRightMessage = null;
    topRightIcon = Icons.info_outline;
    identity = PreviewFixtures.localIdentity();
    profileAvatarPath = null;
    dataDirectory = r'D:\Project\NekoChat\neko_chat_data (预览模拟目录)';
    trustedPeers = Map<String, TrustedPeer>.from(
      PreviewFixtures.trustedPeers(),
    );
    peers = List<DiscoveredPeer>.from(PreviewFixtures.peers());
    chats = List<ChatSummary>.from(PreviewFixtures.chats());
    groups = List<ChatGroup>.from(PreviewFixtures.groups());
    peerRemarks = {PreviewFixtures.aliceDeviceId: '晓猫（前端）'};
    groupRemarks = {PreviewFixtures.secondaryGroupId: '干饭群'};
    chatRequests
      ..clear()
      ..[PreviewFixtures.incomingRequest().requestId] =
          PreviewFixtures.incomingRequest()
      ..[PreviewFixtures.outgoingRequest().requestId] =
          PreviewFixtures.outgoingRequest();
    groupInvitations
      ..clear()
      ..[PreviewFixtures.groupInvitation().inviteId] =
          PreviewFixtures.groupInvitation();
    _messagesByConversation
      ..clear()
      ..[PreviewFixtures.activeChatId] = List<ChatMessage>.from(
        PreviewFixtures.privateMessages(),
      )
      ..[PreviewFixtures.offlineChatId] = [
        ChatMessage(
          messageId: 'msg-c-1',
          chatId: PreviewFixtures.offlineChatId,
          senderDeviceId: PreviewFixtures.carolDeviceId,
          content: '昨天的测试报告已经打包好了，上线后我发给你。',
          timestamp: PreviewFixtures.baseTime.subtract(
            const Duration(hours: 3),
          ),
          status: MessageStatus.sent,
        ),
      ]
      ..['group:${PreviewFixtures.primaryGroupId}'] = List<ChatMessage>.from(
        PreviewFixtures.groupMessages(),
      )
      ..['group:${PreviewFixtures.secondaryGroupId}'] = [
        ChatMessage(
          messageId: 'msg-l-1',
          chatId: 'group:${PreviewFixtures.secondaryGroupId}',
          groupId: PreviewFixtures.secondaryGroupId,
          senderDeviceId: PreviewFixtures.aliceDeviceId,
          content: '今天吃黄焖鸡还是拉面？',
          timestamp: PreviewFixtures.baseTime.subtract(const Duration(days: 1)),
          status: MessageStatus.sent,
        ),
      ];
    _rolesByGroup
      ..clear()
      ..[PreviewFixtures.primaryGroupId] = {
        PreviewFixtures.localDeviceId: GroupRole.owner,
        PreviewFixtures.aliceDeviceId: GroupRole.admin,
        PreviewFixtures.bobDeviceId: GroupRole.member,
      }
      ..[PreviewFixtures.secondaryGroupId] = {
        PreviewFixtures.aliceDeviceId: GroupRole.owner,
        PreviewFixtures.localDeviceId: GroupRole.member,
      };
    _membersByGroup
      ..clear()
      ..[PreviewFixtures.primaryGroupId] = List<GroupMember>.from(
        PreviewFixtures.groupMembers(PreviewFixtures.primaryGroupId),
      )
      ..[PreviewFixtures.secondaryGroupId] = [
        GroupMember(
          groupId: PreviewFixtures.secondaryGroupId,
          deviceId: PreviewFixtures.aliceDeviceId,
          displayName: '林晓猫',
          role: GroupRole.owner,
        ),
        GroupMember(
          groupId: PreviewFixtures.secondaryGroupId,
          deviceId: PreviewFixtures.localDeviceId,
          displayName: '橘猫工程师',
          role: GroupRole.member,
        ),
      ];
    selectedChatId = PreviewFixtures.activeChatId;
    selectedGroupId = null;
    messages = List<ChatMessage>.from(
      _messagesByConversation[PreviewFixtures.activeChatId] ?? const [],
    );
    replyingTo = null;
    autoReceiveFiles = true;
    autoReceiveFileLimitBytes = 10 * 1024 * 1024;
    windowsNotificationsEnabled = true;
    lanDiscoveryEnabled = true;
    blockFriendRequests = false;
    pairingSecret = 'ABCD2345';
    bossKeyEnabled = true;
    bossKeyShortcut = BossKeyShortcut.altF;
    bossKeyNotifyWhenHidden = false;
    bossKeyError = null;
    notifyListeners();
  }

  void showPreviewToast(String message, {IconData icon = Icons.info_outline}) {
    topRightMessage = message;
    topRightIcon = icon;
    notifyListeners();
  }

  @override
  void clearError() {
    errorMessage = null;
    notifyListeners();
  }

  @override
  void clearTopRightMessage() {
    topRightMessage = null;
    notifyListeners();
  }

  @override
  Future<void> setup({
    required String displayName,
    required String password,
  }) async {
    if (displayName.trim().isEmpty) {
      errorMessage = '请输入昵称';
      notifyListeners();
      return;
    }
    if (password.length < 4) {
      errorMessage = '本地密码至少需要 4 个字符';
      notifyListeners();
      return;
    }
    identity = identity?.copyWith(displayName: displayName.trim());
    errorMessage = null;
    showPreviewToast('预览模式：已模拟创建身份「${displayName.trim()}」', icon: Icons.check);
  }

  @override
  Future<void> unlock(String password) async {
    if (password.isEmpty) {
      errorMessage = '请输入本地密码（预览模式输入任意非空密码即可模拟解锁）';
      notifyListeners();
      return;
    }
    errorMessage = null;
    showPreviewToast('预览模式：已模拟解锁成功', icon: Icons.lock_open);
  }

  @override
  Future<void> selectChat(String chatId) async {
    selectedChatId = chatId;
    selectedGroupId = null;
    replyingTo = null;
    chats = [
      for (final chat in chats)
        chat.chatId == chatId ? chat.copyWith(unreadCount: 0) : chat,
    ];
    messages = List<ChatMessage>.from(
      _messagesByConversation[chatId] ?? const [],
    );
    notifyListeners();
  }

  @override
  Future<void> selectGroup(String groupId) async {
    selectedChatId = null;
    selectedGroupId = groupId;
    replyingTo = null;
    groups = [
      for (final group in groups)
        group.groupId == groupId ? group.copyWith(unreadCount: 0) : group,
    ];
    messages = List<ChatMessage>.from(
      _messagesByConversation['group:$groupId'] ?? const [],
    );
    notifyListeners();
  }

  @override
  Future<void> sendMessageWithAttachmentsTo({
    required String? conversationId,
    required String content,
    required List<PendingAttachment> attachments,
    ChatMessage? reply,
  }) async {
    if (conversationId == null) return;
    final trimmed = content.trim();
    if (trimmed.isEmpty && attachments.isEmpty) return;
    final isGroup = conversationId.startsWith('group:');
    final groupId = isGroup ? conversationId.substring('group:'.length) : null;
    final list = _messagesByConversation.putIfAbsent(conversationId, () => []);
    final now = DateTime.now();

    if (trimmed.isNotEmpty) {
      list.add(
        ChatMessage(
          messageId: 'msg-preview-${_nextMessageSeq++}',
          chatId: conversationId,
          groupId: groupId,
          senderDeviceId: identity!.deviceId,
          content: trimmed,
          timestamp: now,
          status: MessageStatus.sent,
          replyToMessageId: reply?.messageId,
          replyToSenderId: reply?.senderDeviceId,
          replyToPreview: reply == null
              ? null
              : AppController.replyPreview(reply),
        ),
      );
    }
    for (final attachment in attachments) {
      list.add(
        ChatMessage(
          messageId: 'msg-preview-${_nextMessageSeq++}',
          chatId: conversationId,
          groupId: groupId,
          senderDeviceId: identity!.deviceId,
          content: '',
          timestamp: now,
          status: MessageStatus.sent,
          kind: attachment.isImage ? MessageKind.image : MessageKind.file,
          fileName: attachment.fileName,
          filePath: attachment.path,
          fileSize: attachment.fileSize,
          mimeType: attachment.mimeType,
        ),
      );
    }
    replyingTo = null;
    messages = List<ChatMessage>.from(list);
    notifyListeners();
  }

  @override
  Future<void> setDisplayName(String value) async {
    final normalized = value.trim();
    if (normalized.isEmpty) return;
    identity = identity?.copyWith(displayName: normalized);
    showPreviewToast('预览模式：昵称已更新为「$normalized」', icon: Icons.check);
  }

  @override
  Future<void> setPeerRemark(String deviceId, String value) async {
    final normalized = value.trim();
    if (normalized.isEmpty) {
      peerRemarks.remove(deviceId);
    } else {
      peerRemarks[deviceId] = normalized;
    }
    notifyListeners();
  }

  @override
  Future<void> setGroupRemark(String groupId, String value) async {
    final normalized = value.trim();
    if (normalized.isEmpty) {
      groupRemarks.remove(groupId);
    } else {
      groupRemarks[groupId] = normalized;
    }
    notifyListeners();
  }

  @override
  Future<void> setLanDiscoveryEnabled(bool value) async {
    lanDiscoveryEnabled = value;
    notifyListeners();
  }

  @override
  Future<void> setBlockFriendRequests(bool value) async {
    blockFriendRequests = value;
    notifyListeners();
  }

  @override
  Future<void> regeneratePairingCode() async {
    const alphabet = '23456789ABCDEFGHJKMNPQRSTUVWXYZ';
    final seed = DateTime.now().microsecondsSinceEpoch;
    pairingSecret = List.generate(
      8,
      (i) => alphabet[(seed >> (i * 3)) % alphabet.length],
    ).join();
    showPreviewToast('预览模式：已重新生成口令 $myPairingCode', icon: Icons.vpn_key);
  }

  @override
  Future<void> setBossKeyEnabled(bool value) async {
    bossKeyEnabled = value;
    bossKeyError = null;
    notifyListeners();
  }

  @override
  Future<void> setBossKeyNotifyWhenHidden(bool value) async {
    bossKeyNotifyWhenHidden = value;
    notifyListeners();
  }

  @override
  Future<bool> setBossKeyShortcut(BossKeyShortcut value) async {
    bossKeyShortcut = value;
    bossKeyError = null;
    notifyListeners();
    return true;
  }

  @override
  Future<void> setAutoReceiveFiles(bool value) async {
    autoReceiveFiles = value;
    notifyListeners();
  }

  @override
  Future<void> setAutoReceiveFileLimitBytes(int value) async {
    autoReceiveFileLimitBytes = value;
    notifyListeners();
  }

  @override
  Future<void> setWindowsNotificationsEnabled(bool value) async {
    windowsNotificationsEnabled = value;
    if (!value) {
      unawaited(clearPreviewNotifications());
    }
    notifyListeners();
  }

  StandaloneNotificationService? _previewStandaloneNotifications;
  int _previewNotificationSeq = 0;

  bool get _canLaunchRealStandaloneWindow =>
      WidgetsBinding.instance is WidgetsFlutterBinding;

  StandaloneNotificationService _ensurePreviewNotifications() {
    final existing = _previewStandaloneNotifications;
    if (existing != null) {
      existing.anchor = notificationAnchor;
      return existing;
    }
    final service = StandaloneNotificationService(anchor: notificationAnchor);
    _previewStandaloneNotifications = service;
    return service;
  }

  @override
  Future<void> setNotificationMode(NotificationMode value) async {
    if (notificationMode == value) return;
    notificationMode = value;
    notifyListeners();
  }

  @override
  Future<void> setNotificationAnchor(NotificationAnchor value) async {
    if (notificationAnchor == value) return;
    notificationAnchor = value;
    _previewStandaloneNotifications?.anchor = value;
    notifyListeners();
  }

  @override
  Future<void> setFontScale(double value) async {
    fontScale = value;
    appearanceRevision.value++;
    notifyListeners();
  }

  @override
  Future<void> setAppFontFamily(String? value) async {
    appFontFamily = value;
    appearanceRevision.value++;
    notifyListeners();
  }

  @override
  Future<void> setBoldText(bool value) async {
    boldText = value;
    appearanceRevision.value++;
    notifyListeners();
  }

  @override
  Future<void> setSeparateFonts(bool value) async {
    separateFonts = value;
    appearanceRevision.value++;
    notifyListeners();
  }

  @override
  Future<void> setLatinFontFamily(String? value) async {
    latinFontFamily = value;
    appearanceRevision.value++;
    notifyListeners();
  }

  @override
  Future<void> showTestNotification() async {
    if (!windowsNotificationsEnabled) {
      showPreviewToast('请先开启消息通知', icon: Icons.notifications_off_outlined);
      return;
    }
    if (notificationMode == NotificationMode.standalone &&
        _canLaunchRealStandaloneWindow) {
      final seq = ++_previewNotificationSeq;
      final service = _ensurePreviewNotifications();
      await service.show(
        identifier: 'preview-toast:$seq',
        title: '林晓猫',
        body: '这是一条来自组件预览模式的独立 Windows 通知（#$seq）。',
        onClick: () {
          showPreviewToast(
            '已点击独立通知 #$seq',
            icon: Icons.notifications_active_outlined,
          );
        },
      );
      return;
    }
    showPreviewToast(
      '预览模式：已模拟发送${notificationMode.label}（${notificationAnchor.label}）',
      icon: Icons.notifications_active_outlined,
    );
  }

  /// 组件预览专用：连续弹出 2 条通知以演示堆叠样式。
  Future<void> showStackedTestNotifications() async {
    if (_canLaunchRealStandaloneWindow) {
      final service = _ensurePreviewNotifications();
      final seq1 = ++_previewNotificationSeq;
      final seq2 = ++_previewNotificationSeq;
      await service.show(
        identifier: 'preview-toast:$seq1',
        title: '机房联调群',
        body: '林晓猫：@橘猫工程师 麻烦看一下右下角通知堆叠效果',
        onClick: () {
          showPreviewToast('已点击群聊通知 #$seq1');
        },
      );
      await service.show(
        identifier: 'preview-toast:$seq2',
        title: '三花开发机',
        body: '新的局域网聊天邀请已到达，点击可快速查看。',
        onClick: () {
          showPreviewToast('已点击私聊通知 #$seq2');
        },
      );
      return;
    }
    showPreviewToast(
      '预览模式：已模拟弹出 2 条堆叠通知',
      icon: Icons.notifications_active_outlined,
    );
  }

  /// 组件预览专用：关闭全部预览独立通知弹窗。
  Future<void> clearPreviewNotifications() async {
    await _previewStandaloneNotifications?.clearAll();
  }

  @override
  Future<void> openDataDirectory() async {
    showPreviewToast('预览模式：数据目录路径为 $dataDirectory', icon: Icons.folder_open);
  }

  @override
  Future<void> acceptChatRequest(ChatRequest request) async {
    chatRequests.remove(request.requestId);
    showPreviewToast('预览模式：已接受来自 ${request.displayName} 的聊天邀请');
  }

  @override
  Future<void> rejectChatRequest(ChatRequest request) async {
    chatRequests.remove(request.requestId);
    showPreviewToast('预览模式：已拒绝来自 ${request.displayName} 的聊天邀请');
  }

  @override
  Future<void> cancelChatRequest(ChatRequest request) async {
    chatRequests.remove(request.requestId);
    showPreviewToast('预览模式：已取消发给 ${request.displayName} 的聊天邀请');
  }

  @override
  Future<void> respondToGroupInvitation(
    GroupInvitation invitation,
    bool accepted,
  ) async {
    groupInvitations.remove(invitation.inviteId);
    showPreviewToast(
      accepted
          ? '预览模式：已加入群「${invitation.groupName}」'
          : '预览模式：已拒绝群「${invitation.groupName}」邀请',
    );
  }

  @override
  Future<void> requestChat(
    DiscoveredPeer peer, {
    bool viaPairingCode = false,
    String? code,
  }) async {
    showPreviewToast(
      viaPairingCode
          ? '预览模式：已通过口令向 ${peer.displayName} 发送好友请求'
          : '预览模式：已向 ${peer.displayName} 发送聊天邀请',
    );
  }

  @override
  Future<void> closeChat(ChatSummary chat) async {
    if (selectedChatId == chat.chatId) {
      selectedChatId = null;
      messages = [];
    }
    notifyListeners();
  }

  @override
  Future<void> deleteChat(ChatSummary chat) async {
    chats = chats.where((c) => c.chatId != chat.chatId).toList();
    if (selectedChatId == chat.chatId) {
      selectedChatId = null;
      messages = [];
    }
    notifyListeners();
  }

  @override
  Future<void> setBlocked(String deviceId, bool blocked) async {
    final existing = trustedPeers[deviceId];
    if (existing != null) {
      trustedPeers[deviceId] = TrustedPeer(
        deviceId: existing.deviceId,
        displayName: existing.displayName,
        lastKnownIp: existing.lastKnownIp,
        verifiedAt: existing.verifiedAt,
        blocked: blocked,
      );
      chats = [
        for (final chat in chats)
          chat.peerDeviceId == deviceId
              ? chat.copyWith(
                  state: blocked
                      ? ChatSessionState.blocked
                      : ChatSessionState.none,
                )
              : chat,
      ];
      final name = peerDisplayName(deviceId, existing.displayName);
      showPreviewToast(
        blocked ? '预览模式：已将 $name 加入黑名单' : '预览模式：已解除对 $name 的拉黑',
        icon: blocked ? Icons.block : Icons.check_circle_outline,
      );
      return;
    }
    notifyListeners();
  }

  @override
  Future<void> revokePeerVerification(String deviceId) async {
    final removed = trustedPeers.remove(deviceId);
    if (removed == null) return;
    peers = [
      for (final peer in peers)
        peer.deviceId == deviceId ? peer.copyWith(trusted: false) : peer,
    ];
    chats = [
      for (final chat in chats)
        chat.peerDeviceId == deviceId
            ? chat.copyWith(state: ChatSessionState.none)
            : chat,
    ];
    final name = peerDisplayName(deviceId, removed.displayName);
    showPreviewToast(
      '预览模式：已取消对 $name 的验证，下次聊天需重新发起好友申请',
      icon: Icons.gpp_bad_outlined,
    );
  }

  @override
  Future<List<GroupMember>> groupMembers(String groupId) async =>
      List<GroupMember>.from(
        _membersByGroup[groupId] ?? PreviewFixtures.groupMembers(groupId),
      );

  @override
  GroupRole? groupMemberRole(String groupId, String deviceId) =>
      _rolesByGroup[groupId]?[deviceId];

  @override
  Future<void> inviteToGroup(ChatGroup group, DiscoveredPeer peer) async {
    final list = _membersByGroup.putIfAbsent(
      group.groupId,
      () => List<GroupMember>.from(PreviewFixtures.groupMembers(group.groupId)),
    );
    if (list.any((m) => m.deviceId == peer.deviceId)) return;
    list.add(
      GroupMember(
        groupId: group.groupId,
        deviceId: peer.deviceId,
        displayName: peer.displayName,
        role: GroupRole.member,
      ),
    );
    (_rolesByGroup[group.groupId] ??= {})[peer.deviceId] = GroupRole.member;
    showPreviewToast('预览模式：已邀请 ${peer.displayName} 加入群聊');
  }

  @override
  Future<void> setGroupMemberRole(
    ChatGroup group,
    GroupMember member,
    GroupRole role,
  ) async {
    final list = _membersByGroup[group.groupId];
    if (list == null) return;
    final idx = list.indexWhere((m) => m.deviceId == member.deviceId);
    if (idx < 0) return;
    list[idx] = GroupMember(
      groupId: member.groupId,
      deviceId: member.deviceId,
      displayName: member.displayName,
      role: role,
    );
    (_rolesByGroup[group.groupId] ??= {})[member.deviceId] = role;
    showPreviewToast(
      role == GroupRole.admin
          ? '预览模式：已将 ${member.displayName} 设为管理员'
          : '预览模式：已取消 ${member.displayName} 的管理员身份',
    );
  }

  @override
  Future<void> removeGroupMember(ChatGroup group, GroupMember member) async {
    final list = _membersByGroup[group.groupId];
    if (list == null) return;
    list.removeWhere((m) => m.deviceId == member.deviceId);
    _rolesByGroup[group.groupId]?.remove(member.deviceId);
    showPreviewToast('预览模式：已将 ${member.displayName} 移出群聊');
  }

  @override
  Future<ChatGroup> createGroup(
    String name,
    List<DiscoveredPeer> invitees,
  ) async {
    final group = ChatGroup(
      groupId: 'group-preview-${_nextMessageSeq++}',
      name: name.trim(),
      ownerDeviceId: identity!.deviceId,
      createdAt: DateTime.now(),
    );
    groups = [group, ...groups];
    notifyListeners();
    return group;
  }

  @override
  Future<void> renameGroup(ChatGroup group, String name) async {
    groups = [
      for (final g in groups)
        g.groupId == group.groupId ? g.copyWith(name: name.trim()) : g,
    ];
    notifyListeners();
  }

  @override
  Future<void> leaveOrDisbandGroup(ChatGroup group) async {
    groups = groups.where((g) => g.groupId != group.groupId).toList();
    if (selectedGroupId == group.groupId) {
      selectedGroupId = null;
      messages = [];
    }
    notifyListeners();
  }

  @override
  Future<void> copyMessage(ChatMessage message) async {
    showPreviewToast('预览模式：已模拟复制消息内容', icon: Icons.copy);
  }

  @override
  bool canRecallMessage(ChatMessage message, {DateTime? now}) {
    final me = identity?.deviceId;
    if (me == null || message.isRecalled) return false;
    ChatGroup? group;
    var isAdmin = false;
    if (message.groupId != null) {
      group = groups
          .where((value) => value.groupId == message.groupId)
          .firstOrNull;
      if (group == null) return false;
      isAdmin =
          _rolesByGroup[group.groupId]?[me] == GroupRole.admin &&
          me != group.ownerDeviceId;
    }
    // 复用真实控制器的撤回规则；预览的角色数据在 _rolesByGroup，且时间锚到
    // 固定数据的 baseTime，避免实际时钟偏离窗口后连群主也撤不了。
    return AppController.canActorRecall(
      message,
      actorDeviceId: me,
      group: group,
      isAdmin: isAdmin,
      now: now ?? PreviewFixtures.baseTime,
    );
  }

  @override
  Future<void> recallMessage(ChatMessage message) async {
    final list = _messagesByConversation[message.chatId];
    if (list == null) return;
    final idx = list.indexWhere((m) => m.messageId == message.messageId);
    if (idx < 0) return;
    list[idx] = message.asRecalled(
      byDeviceId: identity!.deviceId,
      at: DateTime.now(),
    );
    messages = List<ChatMessage>.from(list);
    notifyListeners();
  }

  @override
  Future<List<PendingAttachment>> pickAttachments() async {
    showPreviewToast('预览模式：已插入模拟附件', icon: Icons.attach_file);
    return [PreviewFixtures.pendingAttachments().first];
  }

  @override
  Future<List<PendingAttachment>> readClipboardAttachments() async => const [];

  @override
  Future<void> openAttachment(ChatMessage message) async {
    showPreviewToast('预览模式：打开附件 ${message.fileName ?? ""}');
  }

  @override
  Future<void> openAttachmentFolder(ChatMessage message) async {
    showPreviewToast('预览模式：打开所在文件夹');
  }

  @override
  Future<void> acceptIncomingFile(ChatMessage message) async {
    showPreviewToast('预览模式：已接受文件 ${message.fileName ?? ""}');
  }

  @override
  Future<void> rejectIncomingFile(ChatMessage message) async {
    showPreviewToast('预览模式：已拒绝文件 ${message.fileName ?? ""}');
  }

  @override
  Future<void> retryFileDownload(ChatMessage message) async {
    showPreviewToast('预览模式：已重试下载 ${message.fileName ?? ""}');
  }

  @override
  Future<void> relocateAttachment(ChatMessage message) async {
    showPreviewToast('预览模式：重新指定文件位置');
  }

  @override
  Future<void> pickProfileAvatar() async {
    showPreviewToast('预览模式：选择头像（不访问系统文件对话框）');
  }

  @override
  Future<void> removeProfileAvatar() async {
    profileAvatarPath = null;
    notifyListeners();
  }

  @override
  Future<int> pickAndAddFavoriteStickers() async {
    showPreviewToast('预览模式：选择收藏表情（不访问系统文件对话框）');
    return 0;
  }

  @override
  Future<bool> addMessageToFavoriteStickers(ChatMessage message) async {
    showPreviewToast('预览模式：已添加到收藏表情');
    return true;
  }

  @override
  Future<void> removeFavoriteSticker(FavoriteSticker sticker) async {
    favoriteStickers = favoriteStickers
        .where((item) => item.stickerId != sticker.stickerId)
        .toList();
    showPreviewToast('预览模式：已移除收藏表情');
    notifyListeners();
  }

  @override
  Future<void> sendFavoriteSticker(
    FavoriteSticker sticker, {
    String? conversationId,
    ChatMessage? reply,
  }) async {
    showPreviewToast('预览模式：发送收藏表情 ${sticker.fileName}');
  }

  @override
  void dispose() {
    final service = _previewStandaloneNotifications;
    _previewStandaloneNotifications = null;
    if (service != null) {
      unawaited(service.dispose());
    }
    super.dispose();
  }
}
