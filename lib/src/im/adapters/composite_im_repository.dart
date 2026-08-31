import 'dart:async';

import 'package:onebot_flutter/onebot_flutter.dart' show OneBotMessageSegment;

import '../data/im_repository.dart';
import '../models/im_models.dart';
import '../models/im_source_address.dart';
import 'im_message_source.dart';

class ImRepositoryRegistration {
  const ImRepositoryRegistration({
    required this.id,
    required this.label,
    required this.repository,
    this.connectionStatus,
  });

  final String id;
  final String label;
  final ImRepository repository;
  final Stream<ConnectionStatus>? connectionStatus;
}

/// Aggregates independent client-side sources into one inbox.
///
/// Every external identifier is scoped with its profile ID at this boundary.
/// Individual adapters continue to operate entirely with their native IDs.
class CompositeImRepository implements ImRepository {
  CompositeImRepository({
    required List<ImRepositoryRegistration> registrations,
    String? primarySourceId,
  }) : _registrations = {
         for (final registration in registrations)
           registration.id: registration,
       },
       _primarySourceId = primarySourceId {
    for (final registration in registrations) {
      _conversationSubscriptions.add(
        registration.repository.watchConversations().listen((conversations) {
          _conversationSnapshots[registration.id] = conversations;
          _emitConversations();
        }, onError: _conversationController.addError),
      );
      final status = registration.connectionStatus;
      if (status != null) {
        _statusSubscriptions.add(
          status.listen((value) {
            _statusSnapshots[registration.id] = value;
            _emitStatus();
          }),
        );
      }
    }
  }

  final Map<String, ImRepositoryRegistration> _registrations;
  final String? _primarySourceId;
  final Map<String, List<ImConversation>> _conversationSnapshots = {};
  final Map<String, ConnectionStatus> _statusSnapshots = {};
  final List<StreamSubscription<dynamic>> _conversationSubscriptions = [];
  final List<StreamSubscription<dynamic>> _statusSubscriptions = [];
  final _conversationController =
      StreamController<List<ImConversation>>.broadcast();
  final _statusController = StreamController<ConnectionStatus>.broadcast();

  Stream<ConnectionStatus> get connectionStatus {
    Future.microtask(_emitStatus);
    return _statusController.stream;
  }

  Iterable<ImRepositoryRegistration> get registrations => _registrations.values;

  ImRepositoryRegistration _registrationForValue(
    String value, {
    String? sourceId,
  }) {
    final resolvedSourceId = sourceId ?? ImSourceAddress.sourceIdOf(value);
    final registration = _registrations[resolvedSourceId];
    if (registration != null) return registration;

    final primary = _registrations[_primarySourceId];
    if (primary != null) return primary;
    if (_registrations.length == 1) return _registrations.values.first;
    throw StateError('Unable to determine the IM source for "$value".');
  }

  @override
  Future<ImUser> getCurrentUser({String? sourceId}) async {
    final registration = _registrationForValue('', sourceId: sourceId);
    final user = await registration.repository.getCurrentUser();
    return _scopeUser(registration, user);
  }

  @override
  Future<ImUser?> getUser(String userId) async {
    final registration = _registrationForValue(userId);
    final user = await registration.repository.getUser(
      ImSourceAddress.localIdOf(userId),
    );
    return user == null ? null : _scopeUser(registration, user);
  }

  @override
  Stream<List<ImConversation>> watchConversations() {
    Future.microtask(_emitConversations);
    return _conversationController.stream;
  }

  @override
  Stream<List<ImMessage>> watchMessages(String conversationId) {
    final registration = _registrationForValue(conversationId);
    return registration.repository
        .watchMessages(ImSourceAddress.localIdOf(conversationId))
        .map(
          (messages) => messages
              .map((message) => _scopeMessage(registration, message))
              .toList(growable: false),
        );
  }

  @override
  Future<ImConversation?> getConversation(String conversationId) async {
    final registration = _registrationForValue(conversationId);
    final conversation = await registration.repository.getConversation(
      ImSourceAddress.localIdOf(conversationId),
    );
    return conversation == null
        ? null
        : _scopeConversation(registration, conversation);
  }

  @override
  Future<ImMessage> sendTextMessage({
    required String conversationId,
    required String text,
  }) async {
    final registration = _registrationForValue(conversationId);
    final message = await registration.repository.sendTextMessage(
      conversationId: ImSourceAddress.localIdOf(conversationId),
      text: text,
    );
    return _scopeMessage(registration, message);
  }

  @override
  Future<ImMessage> sendMediaMessage({
    required String conversationId,
    required ImMediaUpload upload,
  }) async {
    final registration = _registrationForValue(conversationId);
    final message = await registration.repository.sendMediaMessage(
      conversationId: ImSourceAddress.localIdOf(conversationId),
      upload: upload,
    );
    return _scopeMessage(registration, message);
  }

  @override
  Future<void> markConversationRead(String conversationId) {
    final registration = _registrationForValue(conversationId);
    return registration.repository.markConversationRead(
      ImSourceAddress.localIdOf(conversationId),
    );
  }

  @override
  Future<List<ImConversation>> searchConversations(String query) async {
    final results = await Future.wait(
      _registrations.values.map((registration) async {
        final conversations = await registration.repository.searchConversations(
          query,
        );
        return conversations
            .map(
              (conversation) => _scopeConversation(registration, conversation),
            )
            .toList(growable: false);
      }),
    );
    return _sortConversations(results.expand((result) => result).toList());
  }

  @override
  Future<List<ImUser>> getUsers() async {
    final results = await Future.wait(
      _registrations.values.map((registration) async {
        final users = await registration.repository.getUsers();
        return users
            .map((user) => _scopeUser(registration, user))
            .toList(growable: false);
      }),
    );
    return results.expand((result) => result).toList(growable: false);
  }

  @override
  Future<List<ImConversation>> getGroupList() async {
    final results = await Future.wait(
      _registrations.values.map((registration) async {
        final conversations = await registration.repository.getGroupList();
        return conversations
            .map(
              (conversation) => _scopeConversation(registration, conversation),
            )
            .toList(growable: false);
      }),
    );
    return results.expand((result) => result).toList(growable: false);
  }

  @override
  Future<ImUser> updateProfile({
    String? nickname,
    ImMediaUpload? avatar,
    String? avatarAssetPath,
  }) async {
    final registration = _registrationForValue('', sourceId: _primarySourceId);
    final user = await registration.repository.updateProfile(
      nickname: nickname,
      avatar: avatar,
      avatarAssetPath: avatarAssetPath,
    );
    return _scopeUser(registration, user);
  }

  @override
  Future<ImConversation> createGroup({
    required String name,
    List<String> memberIds = const [],
    ImMediaUpload? avatar,
  }) async {
    final registration = _registrationForValue('', sourceId: _primarySourceId);
    final group = await registration.repository.createGroup(
      name: name,
      memberIds: memberIds
          .map(ImSourceAddress.localIdOf)
          .toList(growable: false),
      avatar: avatar,
    );
    return _scopeConversation(registration, group);
  }

  @override
  Future<void> joinGroup(String groupId) {
    final registration = _registrationForValue(groupId);
    return registration.repository.joinGroup(
      ImSourceAddress.localIdOf(groupId),
    );
  }

  @override
  Future<void> leaveGroup(String groupId) {
    final registration = _registrationForValue(groupId);
    return registration.repository.leaveGroup(
      ImSourceAddress.localIdOf(groupId),
    );
  }

  @override
  Future<void> ensureConversation(ImConversation conversation) {
    final registration = _registrationForValue(
      conversation.id,
      sourceId: conversation.sourceId,
    );
    return registration.repository.ensureConversation(
      _unScopeConversation(conversation),
    );
  }

  @override
  Future<void> deleteConversation(String conversationId) {
    final registration = _registrationForValue(conversationId);
    return registration.repository.deleteConversation(
      ImSourceAddress.localIdOf(conversationId),
    );
  }

  @override
  Future<void> clearAvatarCache() async {
    await Future.wait(
      _registrations.values.map(
        (registration) => registration.repository.clearAvatarCache(),
      ),
    );
  }

  @override
  Future<void> saveForwardRaw(String forwardId, String rawJson) {
    final registration = _registrationForValue(forwardId);
    return registration.repository.saveForwardRaw(
      ImSourceAddress.localIdOf(forwardId),
      rawJson,
    );
  }

  @override
  Future<String?> loadForwardRaw(String forwardId) {
    final registration = _registrationForValue(forwardId);
    return registration.repository.loadForwardRaw(
      ImSourceAddress.localIdOf(forwardId),
    );
  }

  ImUser _scopeUser(ImRepositoryRegistration registration, ImUser user) {
    return ImUser(
      id: ImSourceAddress.scope(registration.id, user.id),
      displayName: user.displayName,
      avatarAssetPath: user.avatarAssetPath,
      avatarBytes: user.avatarBytes,
      avatarLocalPath: user.avatarLocalPath,
      isOnline: user.isOnline,
      sourceId: registration.id,
      sourceLabel: registration.label,
    );
  }

  ImConversation _scopeConversation(
    ImRepositoryRegistration registration,
    ImConversation conversation,
  ) {
    return ImConversation(
      id: ImSourceAddress.scope(registration.id, conversation.id),
      type: conversation.type,
      title: conversation.title,
      participantIds: conversation.participantIds
          .map((id) => ImSourceAddress.scope(registration.id, id))
          .toList(growable: false),
      subtitle: conversation.subtitle,
      avatarAssetPath: conversation.avatarAssetPath,
      avatarLocalPath: conversation.avatarLocalPath,
      updatedAt: conversation.updatedAt,
      unreadCount: conversation.unreadCount,
      isPinned: conversation.isPinned,
      sourceId: registration.id,
      sourceLabel: registration.label,
    );
  }

  ImConversation _unScopeConversation(ImConversation conversation) {
    return ImConversation(
      id: ImSourceAddress.localIdOf(conversation.id),
      type: conversation.type,
      title: conversation.title,
      participantIds: conversation.participantIds
          .map(ImSourceAddress.localIdOf)
          .toList(growable: false),
      subtitle: conversation.subtitle,
      avatarAssetPath: conversation.avatarAssetPath,
      avatarLocalPath: conversation.avatarLocalPath,
      updatedAt: conversation.updatedAt,
      unreadCount: conversation.unreadCount,
      isPinned: conversation.isPinned,
    );
  }

  ImMessage scopeMessage(String sourceId, ImMessage message) {
    final registration = _registrations[sourceId];
    if (registration == null) return message;
    return _scopeMessage(registration, message);
  }

  ImMessage _scopeMessage(
    ImRepositoryRegistration registration,
    ImMessage message,
  ) {
    return ImMessage(
      id: ImSourceAddress.scope(registration.id, message.id),
      conversationId: ImSourceAddress.scope(
        registration.id,
        message.conversationId,
      ),
      senderId: ImSourceAddress.scope(registration.id, message.senderId),
      text: message.text,
      sentAt: message.sentAt,
      kind: message.kind,
      status: message.status,
      isMine: message.isMine,
      segments: _scopeSegments(registration.id, message.segments),
      mediaPath: message.mediaPath,
      mediaUrl: message.mediaUrl,
      mediaSize: message.mediaSize,
      thumbnailPath: message.thumbnailPath,
      mediaMime: message.mediaMime,
      reactions: message.reactions,
      replyToMessageId:
          message.replyToMessageId == null
              ? null
              : ImSourceAddress.scope(
                registration.id,
                message.replyToMessageId!,
              ),
      recalled: message.recalled,
      sourceId: registration.id,
      sourceLabel: registration.label,
    );
  }

  List<OneBotMessageSegment>? _scopeSegments(
    String sourceId,
    List<OneBotMessageSegment>? segments,
  ) {
    if (segments == null) return null;
    return segments
        .map((segment) {
          final data = Map<String, dynamic>.from(segment.data);
          if (segment.type == 'forward' && data['id'] is String) {
            data['id'] = ImSourceAddress.scope(sourceId, data['id'] as String);
          }
          if (segment.type == 'record' && data['file'] is String) {
            data['file'] = ImSourceAddress.scope(
              sourceId,
              data['file'] as String,
            );
          }
          return OneBotMessageSegment(type: segment.type, data: data);
        })
        .toList(growable: false);
  }

  void _emitConversations() {
    if (_conversationController.isClosed) return;
    final conversations = <ImConversation>[];
    for (final entry in _conversationSnapshots.entries) {
      final registration = _registrations[entry.key];
      if (registration == null) continue;
      conversations.addAll(
        entry.value.map(
          (conversation) => _scopeConversation(registration, conversation),
        ),
      );
    }
    _conversationController.add(_sortConversations(conversations));
  }

  List<ImConversation> _sortConversations(List<ImConversation> conversations) {
    conversations.sort((a, b) {
      if (a.isPinned != b.isPinned) return a.isPinned ? -1 : 1;
      final aTime = a.updatedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      final bTime = b.updatedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      return bTime.compareTo(aTime);
    });
    return List.unmodifiable(conversations);
  }

  void _emitStatus() {
    if (_statusController.isClosed) return;
    final statuses = _statusSnapshots.values;
    final value =
        statuses.contains(ConnectionStatus.connecting)
            ? ConnectionStatus.connecting
            : statuses.contains(ConnectionStatus.connected)
            ? ConnectionStatus.connected
            : statuses.isNotEmpty &&
                statuses.every((status) => status == ConnectionStatus.failed)
            ? ConnectionStatus.failed
            : ConnectionStatus.disconnected;
    _statusController.add(value);
  }

  @override
  void dispose() {
    for (final subscription in _conversationSubscriptions) {
      unawaited(subscription.cancel());
    }
    for (final subscription in _statusSubscriptions) {
      unawaited(subscription.cancel());
    }
    for (final registration in _registrations.values) {
      registration.repository.dispose();
    }
    unawaited(_conversationController.close());
    unawaited(_statusController.close());
  }
}
