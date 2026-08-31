import 'dart:async';

import '../../assets/app_assets.dart';
import '../models/im_models.dart';
import 'im_repository.dart';

/// In-memory repository with sample ZZZ-themed conversations.
class MockImRepository implements ImRepository {
  MockImRepository() {
    _seed();
  }

  static const _currentUserId = 'me';

  final _users = <String, ImUser>{};
  final _conversations = <String, ImConversation>{};
  final _messages = <String, List<ImMessage>>{};
  final _groupAnnouncements = <String, String>{};
  final _groupMuteAll = <String, bool>{};
  final _groupRoles = <String, Map<String, ImGroupRole>>{};
  final _groupMutedUntil = <String, Map<String, DateTime?>>{};
  final _conversationControllers =
      <String, StreamController<List<ImConversation>>>{};
  final _messageControllers = <String, StreamController<List<ImMessage>>>{};

  @override
  bool get supportsFriendManagement => false;

  void _seed() {
    _users.addAll({
      _currentUserId: const ImUser(
        id: _currentUserId,
        displayName: 'Proxy',
        avatarAssetPath: AppAssets.characterWise,
        isOnline: true,
      ),
      'belle': const ImUser(
        id: 'belle',
        displayName: 'Belle',
        avatarAssetPath: AppAssets.characterBelle,
        isOnline: true,
      ),
      'wise': const ImUser(
        id: 'wise',
        displayName: 'Wise',
        avatarAssetPath: AppAssets.characterWise,
      ),
      'nicole': ImUser(
        id: 'nicole',
        displayName: 'Nicole Demara',
        avatarAssetPath: AppAssets.character('NicoleDemara.png'),
        isOnline: true,
      ),
      'anby': ImUser(
        id: 'anby',
        displayName: 'Anby Demara',
        avatarAssetPath: AppAssets.character('AnbyDemara.png'),
      ),
      'fairy': ImUser(
        id: 'fairy',
        displayName: 'Fairy',
        avatarAssetPath: AppAssets.character('temp/Fairy.png'),
      ),
    });

    final now = DateTime.now();
    _putConversation(
      ImConversation(
        id: 'dm_belle_me',
        type: ImConversationType.direct,
        title: 'Belle',
        participantIds: [_currentUserId, 'belle'],
        avatarAssetPath: AppAssets.characterBelle,
        subtitle: 'See you at Sixth Street!',
        updatedAt: now.subtract(const Duration(minutes: 3)),
        unreadCount: 2,
        isPinned: true,
      ),
    );
    _putConversation(
      ImConversation(
        id: 'dm_me_wise',
        type: ImConversationType.direct,
        title: 'Wise',
        participantIds: [_currentUserId, 'wise'],
        avatarAssetPath: AppAssets.characterWise,
        subtitle: "Don't forget the commission.",
        updatedAt: now.subtract(const Duration(hours: 1)),
      ),
    );
    _putConversation(
      ImConversation(
        id: 'group_cunning_hares',
        type: ImConversationType.group,
        title: 'Cunning Hares',
        participantIds: [_currentUserId, 'nicole', 'anby', 'belle'],
        avatarAssetPath: AppAssets.character('NicoleDemara.png'),
        subtitle: 'Nicole: Pay up, buddy.',
        updatedAt: now.subtract(const Duration(hours: 5)),
        unreadCount: 5,
      ),
    );
    _putConversation(
      ImConversation(
        id: 'dm_me_nicole',
        type: ImConversationType.direct,
        title: 'Nicole Demara',
        participantIds: [_currentUserId, 'nicole'],
        avatarAssetPath: AppAssets.character('NicoleDemara.png'),
        subtitle: 'Interest is compounding.',
        updatedAt: now.subtract(const Duration(days: 1)),
      ),
    );
    _putConversation(
      ImConversation(
        id: 'dm_fairy_me',
        type: ImConversationType.direct,
        title: 'Fairy · System',
        participantIds: [_currentUserId, 'fairy'],
        avatarAssetPath: AppAssets.character('temp/Fairy.png'),
        subtitle: 'Power inspection scheduled.',
        updatedAt: now.subtract(const Duration(days: 2)),
      ),
    );

    _putMessages('dm_belle_me', [
      _msg(
        id: 'm1',
        conversationId: 'dm_belle_me',
        senderId: 'belle',
        text: 'Proxy, are you still at the video store?',
        sentAt: now.subtract(const Duration(minutes: 18)),
      ),
      _msg(
        id: 'm2',
        conversationId: 'dm_belle_me',
        senderId: _currentUserId,
        text: 'Yeah, sorting the new Hollow Observer tapes.',
        sentAt: now.subtract(const Duration(minutes: 12)),
        isMine: true,
      ),
      _msg(
        id: 'm3',
        conversationId: 'dm_belle_me',
        senderId: 'belle',
        text: 'See you at Sixth Street!',
        sentAt: now.subtract(const Duration(minutes: 3)),
      ),
    ]);

    _putMessages('dm_me_wise', [
      _msg(
        id: 'w1',
        conversationId: 'dm_me_wise',
        senderId: 'wise',
        text: "Don't forget the commission.",
        sentAt: now.subtract(const Duration(hours: 1)),
      ),
    ]);

    _putMessages('group_cunning_hares', [
      _msg(
        id: 'g1',
        conversationId: 'group_cunning_hares',
        senderId: 'anby',
        text: 'I brought snacks.',
        sentAt: now.subtract(const Duration(hours: 6)),
      ),
      _msg(
        id: 'g2',
        conversationId: 'group_cunning_hares',
        senderId: 'nicole',
        text: 'Pay up, buddy.',
        sentAt: now.subtract(const Duration(hours: 5)),
      ),
      _msg(
        id: 'g3',
        conversationId: 'group_cunning_hares',
        senderId: _currentUserId,
        text: 'Invoice sent.',
        sentAt: now.subtract(const Duration(hours: 4, minutes: 50)),
        isMine: true,
      ),
    ]);

    _putMessages('dm_me_nicole', [
      _msg(
        id: 'n1',
        conversationId: 'dm_me_nicole',
        senderId: 'nicole',
        text: 'Interest is compounding.',
        sentAt: now.subtract(const Duration(days: 1)),
      ),
    ]);

    _putMessages('dm_fairy_me', [
      _msg(
        id: 'f1',
        conversationId: 'dm_fairy_me',
        senderId: 'fairy',
        text: 'Power inspection scheduled.',
        sentAt: now.subtract(const Duration(days: 2)),
        kind: ImMessageKind.system,
      ),
    ]);
  }

  ImMessage _msg({
    required String id,
    required String conversationId,
    required String senderId,
    required String text,
    required DateTime sentAt,
    bool isMine = false,
    ImMessageKind kind = ImMessageKind.text,
  }) {
    return ImMessage(
      id: id,
      conversationId: conversationId,
      senderId: senderId,
      text: text,
      sentAt: sentAt,
      kind: kind,
      isMine: isMine || senderId == _currentUserId,
    );
  }

  void _putConversation(ImConversation conversation) {
    _conversations[conversation.id] = conversation;
  }

  void _putMessages(String conversationId, List<ImMessage> messages) {
    _messages[conversationId] = List.of(messages);
  }

  StreamController<List<ImConversation>> _conversationController() {
    return _conversationControllers.putIfAbsent(
      'all',
      StreamController<List<ImConversation>>.broadcast,
    );
  }

  StreamController<List<ImMessage>> _messageController(String conversationId) {
    return _messageControllers.putIfAbsent(
      conversationId,
      StreamController<List<ImMessage>>.broadcast,
    );
  }

  void _emitConversations() {
    final sorted =
        _conversations.values.toList()..sort((a, b) {
          if (a.isPinned != b.isPinned) return a.isPinned ? -1 : 1;
          final aTime = a.updatedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
          final bTime = b.updatedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
          return bTime.compareTo(aTime);
        });
    if (_conversationControllers['all']?.isClosed == false) {
      _conversationControllers['all']!.add(sorted);
    }
  }

  void _emitMessages(String conversationId) {
    final controller = _messageControllers[conversationId];
    if (controller != null && !controller.isClosed) {
      controller.add(List.unmodifiable(_messages[conversationId] ?? const []));
    }
  }

  @override
  Future<ImUser> getCurrentUser({String? sourceId}) async =>
      _users[_currentUserId]!;

  @override
  Future<ImUser?> getUser(String userId) async => _users[userId];

  @override
  Stream<List<ImConversation>> watchConversations() {
    final controller = _conversationController();
    Future.microtask(_emitConversations);
    return controller.stream;
  }

  @override
  Stream<List<ImMessage>> watchMessages(String conversationId) {
    final controller = _messageController(conversationId);
    Future.microtask(() => _emitMessages(conversationId));
    return controller.stream;
  }

  @override
  Future<ImConversation?> getConversation(String conversationId) async {
    return _conversations[conversationId];
  }

  @override
  Future<ImMessage> sendTextMessage({
    required String conversationId,
    required String text,
    String? replyToMessageId,
  }) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError.value(text, 'text', 'Message cannot be empty.');
    }

    final message = ImMessage(
      id: 'local_${DateTime.now().microsecondsSinceEpoch}',
      conversationId: conversationId,
      senderId: _currentUserId,
      text: trimmed,
      sentAt: DateTime.now(),
      isMine: true,
      status: ImMessageStatus.sent,
      replyToMessageId: replyToMessageId,
    );

    final list = _messages.putIfAbsent(conversationId, () => []);
    list.add(message);
    _emitMessages(conversationId);

    final conversation = _conversations[conversationId];
    if (conversation != null) {
      _conversations[conversationId] = conversation.copyWith(
        subtitle: trimmed,
        updatedAt: message.sentAt,
        unreadCount: 0,
      );
    } else {
      final isGroup = conversationId.startsWith('group_');
      final title =
          isGroup
              ? 'Group ${conversationId.substring(6)}'
              : _resolveDisplayName(conversationId);
      _conversations[conversationId] = ImConversation(
        id: conversationId,
        type: isGroup ? ImConversationType.group : ImConversationType.direct,
        title: title,
        participantIds: [_currentUserId],
        subtitle: trimmed,
        updatedAt: message.sentAt,
      );
    }
    _emitConversations();

    return message;
  }

  @override
  Future<void> recallMessage({
    required String conversationId,
    required String messageId,
  }) async {
    final messages = _messages[conversationId];
    if (messages == null) throw StateError('Conversation not found.');
    final index = messages.indexWhere((message) => message.id == messageId);
    if (index < 0) throw StateError('Message not found.');
    if (!messages[index].isMine) {
      throw StateError('Only your messages can be recalled.');
    }
    messages[index] = messages[index].copyWith(recalled: true);
    _emitMessages(conversationId);
  }

  @override
  Future<ImMessage> sendMediaMessage({
    required String conversationId,
    required ImMediaUpload upload,
  }) async {
    final label = switch (upload.kind) {
      ImMessageKind.image => '[图片]',
      ImMessageKind.record => '[语音]',
      ImMessageKind.video => '[视频]',
      ImMessageKind.file => '[文件]',
      _ => '[媒体]',
    };
    final message = ImMessage(
      id: 'local_${DateTime.now().microsecondsSinceEpoch}',
      conversationId: conversationId,
      senderId: _currentUserId,
      text: label,
      sentAt: DateTime.now(),
      isMine: true,
      kind: upload.kind,
      mediaPath: upload.filePath,
      mediaMime: upload.mimeType,
    );
    final list = _messages.putIfAbsent(conversationId, () => []);
    list.add(message);
    _emitMessages(conversationId);
    final conversation = _conversations[conversationId];
    if (conversation != null) {
      _conversations[conversationId] = conversation.copyWith(
        subtitle: label,
        updatedAt: message.sentAt,
        unreadCount: 0,
      );
    }
    _emitConversations();
    return message;
  }

  @override
  Future<void> markConversationRead(String conversationId) async {
    final conversation = _conversations[conversationId];
    if (conversation == null || conversation.unreadCount == 0) return;
    _conversations[conversationId] = conversation.copyWith(unreadCount: 0);
    _emitConversations();
  }

  @override
  Future<List<ImConversation>> searchConversations(String query) async {
    final normalized = query.trim().toLowerCase();
    if (normalized.isEmpty) {
      return _conversations.values.toList();
    }
    return _conversations.values.where((conversation) {
      return conversation.title.toLowerCase().contains(normalized) ||
          (conversation.subtitle ?? '').toLowerCase().contains(normalized);
    }).toList();
  }

  @override
  Future<List<ImUser>> getUsers() async {
    return _users.values.where((u) => u.id != _currentUserId).toList();
  }

  @override
  Future<List<ImUser>> searchUsers(String query) async => getUsers();

  @override
  Future<List<ImFriendRequest>> getFriendRequests() async => const [];

  @override
  Future<void> sendFriendRequest({
    required String userId,
    String comment = '',
  }) async {
    throw UnsupportedError('Friend management is not supported by the mock.');
  }

  @override
  Future<void> handleFriendRequest({
    required String requestId,
    required bool accept,
  }) async {
    throw UnsupportedError('Friend management is not supported by the mock.');
  }

  @override
  Future<void> removeFriend(String userId) async {
    throw UnsupportedError('Friend management is not supported by the mock.');
  }

  @override
  Future<List<ImConversation>> getGroupList() async {
    final groups =
        _conversations.values
            .where((c) => c.type == ImConversationType.group)
            .toList();
    // Include a synthetic group to demonstrate groups without messages.
    if (!groups.any((g) => g.id == 'group_mock')) {
      groups.add(
        ImConversation(
          id: 'group_mock',
          type: ImConversationType.group,
          title: 'Random Play (Mock)',
          participantIds: [_currentUserId],
        ),
      );
    }
    return groups;
  }

  @override
  Future<ImUser> updateProfile({
    String? nickname,
    ImMediaUpload? avatar,
    String? avatarAssetPath,
  }) async {
    final current = _users[_currentUserId]!;
    final updated = ImUser(
      id: current.id,
      displayName:
          nickname?.trim().isNotEmpty == true
              ? nickname!.trim()
              : current.displayName,
      avatarAssetPath:
          avatarAssetPath ?? (avatar == null ? current.avatarAssetPath : null),
      avatarBytes:
          avatarAssetPath == null ? avatar?.bytes ?? current.avatarBytes : null,
      avatarLocalPath:
          avatarAssetPath == null
              ? avatar?.filePath ?? current.avatarLocalPath
              : null,
      isOnline: true,
    );
    _users[_currentUserId] = updated;
    return updated;
  }

  @override
  Future<ImConversation> createGroup({
    required String name,
    List<String> memberIds = const [],
    ImMediaUpload? avatar,
  }) async {
    final id = 'group_${DateTime.now().microsecondsSinceEpoch}';
    final conversation = ImConversation(
      id: id,
      type: ImConversationType.group,
      title: name.trim(),
      participantIds: [
        _currentUserId,
        ...memberIds.where((id) => id != _currentUserId),
      ],
      avatarLocalPath: avatar?.filePath,
    );
    _conversations[id] = conversation;
    _emitConversations();
    return conversation;
  }

  @override
  Future<void> joinGroup(String groupId) async {}

  @override
  Future<void> leaveGroup(String groupId) async {
    _conversations.remove(groupId);
    _emitConversations();
  }

  @override
  Future<ImGroupDetails> getGroupDetails(String groupId) async {
    final conversation = _conversations[groupId];
    if (conversation == null || !conversation.isGroup) {
      throw StateError('Group not found.');
    }
    final members = conversation.participantIds
        .map((userId) {
          final user =
              _users[userId] ??
              ImUser(
                id: userId,
                displayName: userId,
                avatarAssetPath: AppAssets.fallbackAvatarForId(userId),
              );
          return ImGroupMember(
            user: user,
            role:
                _groupRoles[groupId]?[userId] ??
                (userId == conversation.participantIds.first
                    ? ImGroupRole.owner
                    : ImGroupRole.member),
            mutedUntil: _groupMutedUntil[groupId]?[userId],
          );
        })
        .toList(growable: false);
    final ownerID =
        conversation.participantIds.isEmpty
            ? null
            : conversation.participantIds.first;
    return ImGroupDetails(
      conversation: conversation,
      members: members,
      currentUserId: _currentUserId,
      supportsInvites: true,
      supportsMemberRemoval: true,
      canLeave: ownerID != _currentUserId,
      announcement: _groupAnnouncements[groupId] ?? '',
      muteAll: _groupMuteAll[groupId] ?? false,
      supportsNameEditing: true,
      supportsAvatarEditing: true,
      supportsAnnouncementEditing: true,
      supportsAdminManagement: true,
      supportsMemberMuting: true,
      supportsWholeGroupMute: true,
      supportsOwnershipTransfer: true,
      supportsDismissal: true,
    );
  }

  @override
  Future<void> inviteGroupMembers({
    required String groupId,
    required List<String> userIds,
  }) async {
    final details = await getGroupDetails(groupId);
    if (!details.canInviteMembers) {
      throw StateError('Group permission denied.');
    }
    final participants = details.conversation.participantIds.toSet();
    for (final userId in userIds) {
      if (_users.containsKey(userId)) participants.add(userId);
    }
    _conversations[groupId] = details.conversation.copyWith(
      participantIds: participants.toList(growable: false),
    );
    _emitConversations();
  }

  @override
  Future<void> removeGroupMember({
    required String groupId,
    required String userId,
  }) async {
    final details = await getGroupDetails(groupId);
    final target = details.members.where((member) => member.user.id == userId);
    if (target.isEmpty || !details.canRemoveMember(target.first)) {
      throw StateError('Group permission denied.');
    }
    _conversations[groupId] = details.conversation.copyWith(
      participantIds: details.conversation.participantIds
          .where((participantID) => participantID != userId)
          .toList(growable: false),
    );
    _emitConversations();
  }

  @override
  Future<void> updateGroup({
    required String groupId,
    String? name,
    ImMediaUpload? avatar,
    String? announcement,
  }) async {
    final conversation = _conversations[groupId];
    if (conversation == null) throw StateError('Group not found.');
    _conversations[groupId] = conversation.copyWith(
      title: name?.trim(),
      avatarLocalPath: avatar?.filePath,
    );
    if (announcement != null) {
      _groupAnnouncements[groupId] = announcement.trim();
    }
    _emitConversations();
  }

  @override
  Future<void> setGroupAdmin({
    required String groupId,
    required String userId,
    required bool enabled,
  }) async {
    _groupRoles.putIfAbsent(groupId, () => {})[userId] =
        enabled ? ImGroupRole.admin : ImGroupRole.member;
  }

  @override
  Future<void> setGroupMemberMute({
    required String groupId,
    required String userId,
    required Duration duration,
  }) async {
    _groupMutedUntil.putIfAbsent(groupId, () => {})[userId] =
        duration == Duration.zero ? null : DateTime.now().add(duration);
  }

  @override
  Future<void> setGroupMuteAll({
    required String groupId,
    required bool enabled,
  }) async {
    _groupMuteAll[groupId] = enabled;
  }

  @override
  Future<void> transferGroupOwnership({
    required String groupId,
    required String userId,
  }) async {
    final details = await getGroupDetails(groupId);
    final currentOwner = details.members.firstWhere(
      (member) => member.role == ImGroupRole.owner,
    );
    final roles = _groupRoles.putIfAbsent(groupId, () => {});
    roles[currentOwner.user.id] = ImGroupRole.member;
    roles[userId] = ImGroupRole.owner;
  }

  @override
  Future<void> dismissGroup(String groupId) async {
    _conversations.remove(groupId);
    _messages.remove(groupId);
    _emitConversations();
  }

  @override
  Future<void> ensureConversation(ImConversation conversation) async {
    if (_conversations.containsKey(conversation.id)) return;
    _conversations[conversation.id] = conversation;
    _emitConversations();
  }

  @override
  Future<void> deleteConversation(String conversationId) async {
    _conversations.remove(conversationId);
    // Keep _messages so history survives a re-show.
    _emitConversations();
  }

  @override
  Future<void> clearAvatarCache() async {
    // Mock repository uses asset images; nothing to clear.
  }

  @override
  Future<void> saveForwardRaw(String forwardId, String rawJson) async {}

  @override
  Future<String?> loadForwardRaw(String forwardId) async => null;

  String _resolveDisplayName(String conversationId) {
    if (!conversationId.startsWith('dm_')) return conversationId;
    final parts = conversationId.substring(3).split('_');
    final otherId = parts.firstWhere(
      (p) => p != _currentUserId,
      orElse: () => parts.last,
    );
    return _users[otherId]?.displayName ?? otherId;
  }

  @override
  void dispose() {
    for (final controller in _conversationControllers.values) {
      controller.close();
    }
    for (final controller in _messageControllers.values) {
      controller.close();
    }
  }
}
