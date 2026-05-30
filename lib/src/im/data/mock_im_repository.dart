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
  final _conversationControllers =
      <String, StreamController<List<ImConversation>>>{};
  final _messageControllers = <String, StreamController<List<ImMessage>>>{};

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
  Future<ImUser> getCurrentUser() async => _users[_currentUserId]!;

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
      final title = isGroup
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
    return _conversations.values
        .where((conversation) {
          return conversation.title.toLowerCase().contains(normalized) ||
              (conversation.subtitle ?? '').toLowerCase().contains(normalized);
        })
        .toList();
  }

  @override
  Future<List<ImUser>> getUsers() async {
    return _users.values.where((u) => u.id != _currentUserId).toList();
  }

  @override
  Future<List<ImConversation>> getGroupList() async {
    final groups = _conversations.values
        .where((c) => c.type == ImConversationType.group)
        .toList();
    // Include a synthetic group to demonstrate groups without messages.
    if (!groups.any((g) => g.id == 'group_mock')) {
      groups.add(ImConversation(
        id: 'group_mock',
        type: ImConversationType.group,
        title: 'Random Play (Mock)',
        participantIds: [_currentUserId],
      ));
    }
    return groups;
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
