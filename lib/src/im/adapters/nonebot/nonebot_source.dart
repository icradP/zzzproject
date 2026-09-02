import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:onebot_flutter/onebot_flutter.dart'
    show OneBotClient, OneBotException;

import '../../data/im_avatar_cache.dart';
import '../../data/im_logger.dart';
import '../../data/im_media_cache.dart';
import '../../data/im_message_store.dart';
import '../../data/im_storage_config.dart';
import '../../models/im_models.dart';
import '../im_message_source.dart';
import 'nonebot_mapper.dart';
import 'nonebot_models.dart';

/// An [ImMessageSource] backed by the OneBot protocol.
///
/// - **Mock mode** ([NoneBotSource.mock]): fills sample data so no real server
///   is needed. Pass an [avatarResolver] to map user ids to asset paths.
/// - **Connected mode** ([NoneBotSource.connected]): wraps [OneBotClient] from
///   the standalone SDK, ingesting live events and translating them to the
///   [ImMessageSource] interface used by the app.
class NoneBotSource extends ImMessageSource {
  NoneBotSource._({
    required this.config,
    required bool mock,
    AvatarResolver? avatarResolver,
  }) : _mock = mock,
       _avatarResolver = avatarResolver ?? _defaultAvatar {
    _selfId = config.selfId;
    _users[_selfId] = ImUser(
      id: _selfId,
      displayName: _selfId.isNotEmpty ? 'Bot ($_selfId)' : 'Proxy',
      avatarAssetPath: _avatarResolver(_selfId),
      isOnline: true,
    );
    if (_mock) _seedMockData();
  }

  factory NoneBotSource.mock({AvatarResolver? avatarResolver}) {
    return NoneBotSource._(
      config: const OneBotConfig(selfId: 'me'),
      mock: true,
      avatarResolver: avatarResolver,
    );
  }

  factory NoneBotSource.connected({
    required OneBotConfig config,
    AvatarResolver? avatarResolver,
  }) {
    return NoneBotSource._(
      config: config,
      mock: false,
      avatarResolver: avatarResolver,
    );
  }

  final OneBotConfig config;
  final bool _mock;
  final AvatarResolver _avatarResolver;

  @override
  bool get supportsFriendManagement => false;
  ImStorageConfig? _storageConfig;

  /// Pass an [ImStorageConfig] to redirect media / avatar / database
  /// directories away from the default app documents location.
  set storageConfig(ImStorageConfig? v) => _storageConfig = v;

  /// Optional media cache for downloading OneBot images / records / videos.
  set mediaCache(ImMediaCache? v) => _mediaCache = v;

  late String _selfId;
  OneBotClient? _client;

  /// The connected OneBot client, or `null` in mock / disconnected mode.
  OneBotClient? get client => _client;

  /// Fetch + cache a user avatar. Returns the local path when ready.
  Future<String?> fetchUserAvatar(String userId) async {
    if (_avatarCache == null) return null;
    return _avatarCache!.get(userId);
  }

  ImMediaCache? _mediaCache;
  ImAvatarCache? _avatarCache;
  ImMessageStore? _store;
  StreamSubscription? _eventSubscription;

  final _users = <String, ImUser>{};
  final _friendIds = <String>{};
  final _groupNames = <String, String>{};
  final _groupMemberIds = <String, List<String>>{};
  final _groupAvatarPaths = <String, String>{};
  final _groupMuteAll = <String, bool>{};
  final _conversations = <String, ImConversation>{};
  final _messages = <String, List<ImMessage>>{};
  final _conversationControllers =
      <String, StreamController<List<ImConversation>>>{};
  final _messageControllers = <String, StreamController<List<ImMessage>>>{};
  final _statusController = StreamController<ConnectionStatus>.broadcast();
  final _usersController = StreamController<List<ImUser>>.broadcast();

  static String? _defaultAvatar(String userId) => null;

  // -----------------------------------------------------------------
  // ImMessageSource
  // -----------------------------------------------------------------

  @override
  String get platformName => 'NoneBot / OneBot';

  @override
  Stream<ConnectionStatus> get connectionStatus => _statusController.stream;

  @override
  Future<void> connect() async {
    if (_mock) {
      _statusController.add(ConnectionStatus.connected);
      return;
    }

    _statusController.add(ConnectionStatus.connecting);
    try {
      _client = OneBotClient(config: config, onLog: ImLogger.logRaw);
      await _client!.connect();
      ImLogger.ingestCount('connected', 0); // just mark connected

      // Subscribe to events IMMEDIATELY after connect, before any DB or
      // network operations.  This guarantees events are processed even if
      // a later step (storage, history, populate) fails.
      _eventSubscription = _client!.eventStream.listen((event) {
        if (event is OneBotMessageEvent) {
          if (event.isPrivate && event.event != null) {
            _ingestPrivateEvent(event.event!);
          } else if (event.isGroup) {
            _ingestGroupEvent(event.groupEvent!);
          }
        } else if (event is OneBotNoticeEventWrapper) {
          _ingestNoticeEvent(event.event);
        }
      });

      _mediaCache = ImMediaCache(
        client: _client!,
        storageConfig: _storageConfig,
      );
      _avatarCache = ImAvatarCache(storageConfig: _storageConfig);
      _store = ImMessageStore(selfId: _selfId, storageConfig: _storageConfig);
      ImLogger.logRaw(
        ImLogger.store,
        'opening store (config=${_storageConfig != null})',
      );
      await _store!.open();
      ImLogger.logRaw(ImLogger.store, 'store opened OK');
      await _loadHistory();

      // Best-effort: pre-populate friend & group names on connect.
      // Failures here are silent — names will be resolved lazily.
      await _populateInitialData();

      _statusController.add(ConnectionStatus.connected);
    } catch (e) {
      _statusController.add(ConnectionStatus.failed);
      rethrow;
    }
  }

  @override
  void disconnect() {
    _eventSubscription?.cancel();
    _client?.disconnect();
    _mediaCache = null;
    _store?.close();
    _store = null;
    _statusController.add(ConnectionStatus.disconnected);
    for (final c in _conversationControllers.values) {
      c.close();
    }
    for (final c in _messageControllers.values) {
      c.close();
    }
    _usersController.close();
  }

  @override
  Future<void> clearAvatarCache() async {
    await _avatarCache?.clear();
  }

  @override
  Future<void> saveForwardRaw(String forwardId, String rawJson) async {
    await _store?.saveForwardRaw(forwardId, rawJson);
  }

  @override
  Future<String?> loadForwardRaw(String forwardId) async {
    return _store?.loadForwardRaw(forwardId);
  }

  @override
  Future<String?> testConnection() async {
    if (_mock) return null;
    try {
      final client = OneBotClient(config: config);
      final result = await client.testConnection();
      client.disconnect();
      return result;
    } on OneBotException catch (e) {
      return e.message;
    } on SocketException catch (e) {
      return 'Socket error: ${e.message}';
    } catch (e) {
      return 'Connection failed: $e';
    }
  }

  @override
  Future<ImUser> getCurrentUser() async => _users[_selfId]!;

  @override
  Future<ImUser?> getUser(String userId) async => _users[userId];

  @override
  Stream<List<ImUser>> watchUsers() {
    Future.microtask(_emitUsers);
    return _usersController.stream;
  }

  @override
  Future<ImUser> updateProfile({
    String? nickname,
    ImMediaUpload? avatar,
    String? avatarAssetPath,
    String? bio,
    ImMediaUpload? cardBackground,
    String? cardBackgroundUrl,
    String? cardBackgroundColor,
    bool? cardBackgroundSensitive,
    bool? showMutualGroups,
    bool? showAccountId,
  }) async {
    throw UnsupportedError('NoneBot does not own the user profile.');
  }

  @override
  Future<ImConversation> createGroup({
    required String name,
    List<String> memberIds = const [],
    ImMediaUpload? avatar,
  }) async {
    throw UnsupportedError('Create groups through the connected platform.');
  }

  @override
  Future<void> joinGroup(String groupId) async {
    throw UnsupportedError('Join groups through the connected platform.');
  }

  @override
  Future<void> leaveGroup(String groupId) async {
    final parsed = parseConversationId(groupId, _selfId);
    if (!parsed.isGroup || _client == null) {
      throw UnsupportedError('Leave groups through the connected platform.');
    }
    await _client!.setGroupLeave(groupId: parsed.targetId);
    _groupNames.remove(parsed.targetId);
    _groupMemberIds.remove(parsed.targetId);
    _groupAvatarPaths.remove(parsed.targetId);
    _groupMuteAll.remove(parsed.targetId);
    _conversations.remove(groupId);
    _emitConversations();
  }

  @override
  Stream<List<ImConversation>> watchConversations() {
    final c = _conversationControllers.putIfAbsent(
      'all',
      () => StreamController<List<ImConversation>>.broadcast(),
    );
    Future.microtask(_emitConversations);
    return c.stream;
  }

  @override
  Stream<List<ImMessage>> watchMessages(String conversationId) {
    final c = _messageControllers.putIfAbsent(
      conversationId,
      () => StreamController<List<ImMessage>>.broadcast(),
    );
    Future.microtask(() => _emitMessages(conversationId));
    return c.stream;
  }

  @override
  Future<bool> loadOlderMessages(String conversationId) async {
    final store = _store;
    if (store == null) return false;
    const pageSize = 50;
    final current = _messages[conversationId] ?? const <ImMessage>[];
    final page = await store.getMessages(
      conversationId,
      limit: pageSize,
      offset: current.length,
    );
    if (page.isNotEmpty) {
      final merged = <String, ImMessage>{
        for (final message in current) message.id: message,
        for (final message in page) message.id: message,
      };
      _messages[conversationId] =
          merged.values.toList()..sort((a, b) => a.sentAt.compareTo(b.sentAt));
      _emitMessages(conversationId);
    }
    return page.length >= pageSize;
  }

  @override
  Future<ImConversation?> getConversation(String conversationId) async =>
      _conversations[conversationId];

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

    final localId = 'local_${DateTime.now().microsecondsSinceEpoch}';
    var message = ImMessage(
      id: localId,
      conversationId: conversationId,
      senderId: _selfId,
      text: trimmed,
      sentAt: DateTime.now(),
      isMine: true,
      status: ImMessageStatus.sending,
      replyToMessageId: replyToMessageId,
    );

    final list = _messages.putIfAbsent(conversationId, () => []);
    list.add(message);
    _emitMessages(conversationId);
    _saveMsg(message);

    final conv = _conversations[conversationId];
    if (conv != null) {
      _conversations[conversationId] = conv.copyWith(
        subtitle: trimmed,
        updatedAt: message.sentAt,
        unreadCount: 0,
      );
    } else {
      // Create a minimal conversation for new chats
      final parsed = parseConversationId(conversationId, _selfId);
      final user = _users[parsed.targetId];
      final dmTitle = user?.displayName;
      final participantIds =
          parsed.isGroup
              ? (_groupMemberIds[parsed.targetId] ?? [_selfId])
              : [_selfId, parsed.targetId];
      _conversations[conversationId] = ImConversation(
        id: conversationId,
        type:
            parsed.isGroup
                ? ImConversationType.group
                : ImConversationType.direct,
        title:
            parsed.isGroup
                ? (_groupNames[parsed.targetId] ?? 'Group ${parsed.targetId}')
                : ((dmTitle != null && dmTitle.isNotEmpty)
                    ? dmTitle
                    : parsed.targetId),
        participantIds: participantIds,
        subtitle: trimmed,
        updatedAt: message.sentAt,
        avatarAssetPath:
            parsed.isGroup
                ? null
                : (user?.avatarAssetPath ?? _avatarResolver(parsed.targetId)),
        avatarLocalPath:
            parsed.isGroup ? _groupAvatarPaths[parsed.targetId] : null,
      );
    }
    _saveConv(_conversations[conversationId]!);
    _emitConversations();

    // In connected mode, send via OneBot API
    if (!_mock && _client != null) {
      try {
        final chain = imMessageToOneBotChain(message);
        final parsed = parseConversationId(conversationId, _selfId);
        int msgId;
        if (parsed.isGroup) {
          msgId = await _client!.sendGroupMsg(
            groupId: parsed.targetId,
            message: chain,
          );
        } else {
          msgId = await _client!.sendPrivateMsg(
            userId: parsed.targetId,
            message: chain,
          );
        }
        // Update with real message id and status
        message = message.copyWith(id: '$msgId', status: ImMessageStatus.sent);
        // Swap the local message with the updated one
        final idx = list.indexWhere((m) => m.id == localId);
        if (idx >= 0) list[idx] = message;
        _emitMessages(conversationId);
      } on OneBotException catch (e) {
        message = message.copyWith(status: ImMessageStatus.failed);
        final idx = list.indexWhere((m) => m.id == localId);
        if (idx >= 0) list[idx] = message;
        _emitMessages(conversationId);
        // Re-throw so the UI can show the error
        throw Exception('Failed to send: ${e.message}');
      }
    } else {
      // Mock mode — just mark as sent
      message = message.copyWith(status: ImMessageStatus.sent);
      final idx = list.indexWhere((m) => m.id == localId);
      if (idx >= 0) list[idx] = message;
      _emitMessages(conversationId);
    }

    return message;
  }

  @override
  Future<ImMessage> sendStickerMessage({
    required String conversationId,
    required ImStickerReference sticker,
  }) => sendTextMessage(conversationId: conversationId, text: '[Sticker]');

  @override
  Future<void> recallMessage({
    required String conversationId,
    required String messageId,
  }) async {
    final baseId = _oneBotBaseMessageId(messageId);
    if (!_mock) {
      final numericId = int.tryParse(baseId);
      if (numericId == null || _client == null) {
        throw StateError('This message cannot be recalled.');
      }
      await _client!.deleteMsg(numericId);
    }
    _markRecalledByPrefix(conversationId, baseId, _selfId);
  }

  String _oneBotBaseMessageId(String messageId) {
    final match = RegExp(r'^(-?\d+)(?:_\d+)?$').firstMatch(messageId);
    return match?.group(1) ?? messageId;
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
      ImMessageKind.file => upload.fileName,
      _ => '[媒体]',
    };

    final localId = 'local_${DateTime.now().microsecondsSinceEpoch}';
    var message = ImMessage(
      id: localId,
      conversationId: conversationId,
      senderId: _selfId,
      text: label,
      kind: upload.kind,
      mediaPath: upload.filePath,
      mediaMime: upload.mimeType,
      sentAt: DateTime.now(),
      isMine: true,
      status: ImMessageStatus.sending,
    );

    final list = _messages.putIfAbsent(conversationId, () => []);
    list.add(message);
    _emitMessages(conversationId);
    _saveMsg(message);

    final conv = _conversations[conversationId];
    if (conv != null) {
      _conversations[conversationId] = conv.copyWith(
        subtitle: label,
        updatedAt: message.sentAt,
        unreadCount: 0,
      );
    } else {
      final parsed = parseConversationId(conversationId, _selfId);
      _conversations[conversationId] = ImConversation(
        id: conversationId,
        type:
            parsed.isGroup
                ? ImConversationType.group
                : ImConversationType.direct,
        title:
            parsed.isGroup
                ? (_groupNames[parsed.targetId] ?? 'Group ${parsed.targetId}')
                : parsed.targetId,
        participantIds:
            parsed.isGroup
                ? (_groupMemberIds[parsed.targetId] ?? [_selfId])
                : [_selfId, parsed.targetId],
        subtitle: label,
        updatedAt: message.sentAt,
      );
    }
    _saveConv(_conversations[conversationId]!);
    _emitConversations();

    if (!_mock && _client != null) {
      try {
        final chain = _mediaToChain(upload);
        final parsed = parseConversationId(conversationId, _selfId);
        int msgId;
        if (parsed.isGroup) {
          msgId = await _client!.sendGroupMsg(
            groupId: parsed.targetId,
            message: chain,
          );
        } else {
          msgId = await _client!.sendPrivateMsg(
            userId: parsed.targetId,
            message: chain,
          );
        }
        message = message.copyWith(id: '$msgId', status: ImMessageStatus.sent);
        final idx = list.indexWhere((m) => m.id == localId);
        if (idx >= 0) list[idx] = message;
        _emitMessages(conversationId);
      } on OneBotException catch (e) {
        message = message.copyWith(status: ImMessageStatus.failed);
        final idx = list.indexWhere((m) => m.id == localId);
        if (idx >= 0) list[idx] = message;
        _emitMessages(conversationId);
        throw Exception('Failed to send media: ${e.message}');
      }
    } else {
      message = message.copyWith(status: ImMessageStatus.sent);
      final idx = list.indexWhere((m) => m.id == localId);
      if (idx >= 0) list[idx] = message;
      _emitMessages(conversationId);
    }

    return message;
  }

  List<OneBotMessageSegment> _mediaToChain(ImMediaUpload upload) {
    final bytes =
        upload.bytes ??
        (upload.filePath == null
            ? null
            : File(upload.filePath!).readAsBytesSync());
    if (bytes == null) return [OneBotMessageSegment.plain('[文件未找到]')];
    final b64 = base64Encode(bytes);
    // Prepend a MIME hint so the OneBot server can detect the type.
    final dataUri = 'base64://$b64';

    return switch (upload.kind) {
      ImMessageKind.image => [OneBotMessageSegment.image(dataUri)],
      ImMessageKind.record => [OneBotMessageSegment.record(dataUri)],
      ImMessageKind.video => [OneBotMessageSegment.video(dataUri)],
      ImMessageKind.file => [
        OneBotMessageSegment(
          type: 'file',
          data: {'file': dataUri, 'name': upload.fileName},
        ),
      ],
      _ => [OneBotMessageSegment.plain(upload.fileName)],
    };
  }

  @override
  Future<void> markConversationRead(String conversationId) async {
    final conv = _conversations[conversationId];
    if (conv == null || conv.unreadCount == 0) return;
    _conversations[conversationId] = conv.copyWith(unreadCount: 0);
    _emitConversations();
  }

  @override
  Future<void> setConversationPreferences({
    required String conversationId,
    required bool isPinned,
    required ImConversationNotificationLevel notificationLevel,
  }) async {
    final conversation = _conversations[conversationId];
    if (conversation == null) throw StateError('Conversation not found.');
    final updated = conversation.copyWith(
      isPinned: isPinned,
      notificationLevel: notificationLevel,
    );
    _conversations[conversationId] = updated;
    _saveConv(updated);
    _emitConversations();
  }

  @override
  Future<List<ImConversation>> searchConversations(String query) async {
    final normalized = query.trim().toLowerCase();
    if (normalized.isEmpty) return _conversations.values.toList();
    return _conversations.values
        .where(
          (c) =>
              c.title.toLowerCase().contains(normalized) ||
              (c.subtitle ?? '').toLowerCase().contains(normalized),
        )
        .toList();
  }

  @override
  Future<List<ImUser>> getUsers() async {
    return _visibleUsers();
  }

  List<ImUser> _visibleUsers() {
    return _friendIds
        .map((id) => _users[id])
        .where((u) => u != null)
        .cast<ImUser>()
        .toList();
  }

  @override
  Future<List<ImUser>> searchUsers(String query) async {
    throw UnsupportedError(
      'Friend management is owned by the connected platform.',
    );
  }

  @override
  Future<List<ImFriendRequest>> getFriendRequests() async {
    throw UnsupportedError(
      'Friend management is owned by the connected platform.',
    );
  }

  @override
  Stream<List<ImFriendRequest>> watchFriendRequests() => Stream.value(const []);

  @override
  Future<void> sendFriendRequest({
    required String userId,
    String comment = '',
  }) async {
    throw UnsupportedError(
      'Friend management is owned by the connected platform.',
    );
  }

  @override
  Future<void> handleFriendRequest({
    required String requestId,
    required bool accept,
  }) async {
    throw UnsupportedError(
      'Friend management is owned by the connected platform.',
    );
  }

  @override
  Future<void> removeFriend(String userId) async {
    throw UnsupportedError(
      'Friend management is owned by the connected platform.',
    );
  }

  @override
  Future<List<ImConversation>> getGroupList() async {
    return _groupNames.entries.map((e) {
      return ImConversation(
        id: oneBotConversationId(selfId: _selfId, groupId: e.key),
        type: ImConversationType.group,
        title: e.value,
        participantIds: _groupMemberIds[e.key] ?? [_selfId],
        avatarLocalPath: _groupAvatarPaths[e.key],
      );
    }).toList();
  }

  @override
  Future<ImGroupDetails> getGroupDetails(String groupId) async {
    final parsed = parseConversationId(groupId, _selfId);
    if (!parsed.isGroup) throw StateError('Group not found.');
    final existing = _conversations[groupId];
    final members = <ImGroupMember>[];
    if (_client != null) {
      final remoteMembers = await _client!.getGroupMemberList(
        groupId: parsed.targetId,
      );
      for (final remote in remoteMembers) {
        final displayName =
            remote.card?.isNotEmpty == true ? remote.card! : remote.nickname;
        final known = _users[remote.userId];
        final user = ImUser(
          id: remote.userId,
          displayName: displayName.isEmpty ? remote.userId : displayName,
          avatarAssetPath:
              known?.avatarAssetPath ?? _avatarResolver(remote.userId),
          avatarLocalPath: known?.avatarLocalPath,
          isOnline: known?.isOnline ?? true,
        );
        _users[remote.userId] = user;
        members.add(
          ImGroupMember(
            user: user,
            role: imGroupRoleFromString(remote.role),
            joinedAt:
                remote.joinTime == null || remote.joinTime! <= 0
                    ? null
                    : DateTime.fromMillisecondsSinceEpoch(
                      remote.joinTime! * 1000,
                    ),
            mutedUntil:
                remote.shutUpTimestamp == null || remote.shutUpTimestamp! <= 0
                    ? null
                    : DateTime.fromMillisecondsSinceEpoch(
                      remote.shutUpTimestamp! * 1000,
                    ),
          ),
        );
      }
    } else {
      final participantIDs =
          existing?.participantIds ??
          _groupMemberIds[parsed.targetId] ??
          [_selfId];
      for (var index = 0; index < participantIDs.length; index++) {
        final userID = participantIDs[index];
        final user =
            _users[userID] ??
            ImUser(
              id: userID,
              displayName: userID,
              avatarAssetPath: _avatarResolver(userID),
            );
        members.add(
          ImGroupMember(
            user: user,
            role: index == 0 ? ImGroupRole.owner : ImGroupRole.member,
          ),
        );
      }
    }
    final participantIDs = members
        .map((member) => member.user.id)
        .toList(growable: false);
    _groupMemberIds[parsed.targetId] = participantIDs;
    final conversation = ImConversation(
      id: groupId,
      type: ImConversationType.group,
      title:
          existing?.title ??
          _groupNames[parsed.targetId] ??
          'Group ${parsed.targetId}',
      participantIds: participantIDs,
      subtitle: existing?.subtitle,
      avatarAssetPath: existing?.avatarAssetPath,
      avatarLocalPath:
          existing?.avatarLocalPath ?? _groupAvatarPaths[parsed.targetId],
      updatedAt: existing?.updatedAt,
      unreadCount: existing?.unreadCount ?? 0,
      isPinned: existing?.isPinned ?? false,
      notificationLevel:
          existing?.notificationLevel ?? ImConversationNotificationLevel.normal,
    );
    _conversations[groupId] = conversation;
    _emitConversations();
    ImGroupRole? currentRole;
    for (final member in members) {
      if (member.user.id == _selfId) {
        currentRole = member.role;
        break;
      }
    }
    return ImGroupDetails(
      conversation: conversation,
      members: members,
      currentUserId: _selfId,
      supportsInvites: false,
      supportsMemberRemoval: _client != null,
      canLeave:
          _client != null &&
          currentRole != null &&
          currentRole != ImGroupRole.owner,
      supportsNameEditing: _client != null,
      muteAll: _groupMuteAll[parsed.targetId] ?? false,
      supportsAdminManagement: _client != null,
      supportsMemberMuting: _client != null,
      supportsWholeGroupMute: _client != null,
      supportsDismissal: _client != null,
    );
  }

  @override
  Future<void> inviteGroupMembers({
    required String groupId,
    required List<String> userIds,
  }) async {
    throw UnsupportedError(
      'Inviting members is not available through OneBot v11.',
    );
  }

  @override
  Future<void> removeGroupMember({
    required String groupId,
    required String userId,
  }) async {
    final parsed = parseConversationId(groupId, _selfId);
    if (!parsed.isGroup || _client == null) {
      throw UnsupportedError('Remove members through the connected platform.');
    }
    final details = await getGroupDetails(groupId);
    ImGroupMember? target;
    for (final member in details.members) {
      if (member.user.id == userId) {
        target = member;
        break;
      }
    }
    if (target == null || !details.canRemoveMember(target)) {
      throw StateError('Group permission denied.');
    }
    await _client!.setGroupKick(groupId: parsed.targetId, userId: userId);
    await _populateGroupMembers(parsed.targetId);
  }

  @override
  Future<void> updateGroup({
    required String groupId,
    String? name,
    ImMediaUpload? avatar,
    String? announcement,
  }) async {
    final parsed = parseConversationId(groupId, _selfId);
    if (!parsed.isGroup || _client == null) {
      throw UnsupportedError('Edit groups through the connected platform.');
    }
    if (avatar != null || announcement != null) {
      throw UnsupportedError(
        'OneBot v11 does not expose group avatars or announcements.',
      );
    }
    final value = name?.trim();
    if (value == null || value.isEmpty) return;
    await _client!.setGroupName(groupId: parsed.targetId, groupName: value);
    _groupNames[parsed.targetId] = value;
    final existing = _conversations[groupId];
    if (existing != null) {
      _conversations[groupId] = existing.copyWith(title: value);
    }
    _emitConversations();
  }

  @override
  Future<void> setGroupAdmin({
    required String groupId,
    required String userId,
    required bool enabled,
  }) async {
    final parsed = parseConversationId(groupId, _selfId);
    if (!parsed.isGroup || _client == null) {
      throw UnsupportedError(
        'Manage administrators through the connected platform.',
      );
    }
    await _client!.setGroupAdmin(
      groupId: parsed.targetId,
      userId: userId,
      enable: enabled,
    );
    await _populateGroupMembers(parsed.targetId);
  }

  @override
  Future<void> setGroupMemberMute({
    required String groupId,
    required String userId,
    required Duration duration,
  }) async {
    final parsed = parseConversationId(groupId, _selfId);
    if (!parsed.isGroup || _client == null) {
      throw UnsupportedError('Mute members through the connected platform.');
    }
    await _client!.setGroupBan(
      groupId: parsed.targetId,
      userId: userId,
      duration: duration.inSeconds,
    );
  }

  @override
  Future<void> setGroupMuteAll({
    required String groupId,
    required bool enabled,
  }) async {
    final parsed = parseConversationId(groupId, _selfId);
    if (!parsed.isGroup || _client == null) {
      throw UnsupportedError('Mute groups through the connected platform.');
    }
    await _client!.setGroupWholeBan(groupId: parsed.targetId, enable: enabled);
    _groupMuteAll[parsed.targetId] = enabled;
  }

  @override
  Future<void> dismissGroup(String groupId) async {
    final parsed = parseConversationId(groupId, _selfId);
    if (!parsed.isGroup || _client == null) {
      throw UnsupportedError('Dismiss groups through the connected platform.');
    }
    await _client!.setGroupLeave(groupId: parsed.targetId, isDismiss: true);
    _groupMuteAll.remove(parsed.targetId);
    _conversations.remove(groupId);
    _emitConversations();
  }

  @override
  Future<void> transferGroupOwnership({
    required String groupId,
    required String userId,
  }) async {
    throw UnsupportedError(
      'OneBot v11 does not expose group ownership transfer.',
    );
  }

  @override
  Future<void> deleteConversation(String conversationId) async {
    // Only hide from the conversation list.  Keep messages and the
    // message stream alive so history is preserved if the conversation
    // reappears via a new incoming event.
    _conversations.remove(conversationId);
    _emitConversations();
  }

  @override
  Future<void> ensureConversation(ImConversation conversation) async {
    if (_conversations.containsKey(conversation.id)) return;
    _conversations[conversation.id] = conversation;
    _emitConversations();
  }

  // -----------------------------------------------------------------
  // Event ingestion (connected mode)
  // -----------------------------------------------------------------

  void _ingestPrivateEvent(OneBotPrivateMessageEvent event) {
    final convId = oneBotConversationId(selfId: _selfId, userId: event.userId);
    final imUser = oneBotSenderToImUser(
      event.sender,
      avatarResolver: _avatarResolver,
    );
    final isNewUser = !_users.containsKey(imUser.id);
    _users.putIfAbsent(imUser.id, () => imUser);
    if (isNewUser) _fetchUserAvatar(imUser.id);

    final msgs = oneBotPrivateMessageToImMessages(
      event: event,
      conversationId: convId,
      selfId: _selfId,
      resolveName: _resolveNameForAt,
    );

    final lastText = msgs.last.text;
    final existing = _conversations[convId];
    if (existing != null) {
      _conversations[convId] = existing.copyWith(
        subtitle: lastText,
        updatedAt: msgs.last.sentAt,
        unreadCount: existing.unreadCount + 1,
      );
    } else {
      _conversations[convId] = oneBotPrivateEventToConversation(
        event: event,
        conversationId: convId,
        selfId: _selfId,
        peer: imUser,
        subtitle: lastText,
        updatedAt: msgs.last.sentAt,
        avatarAssetPath: _avatarResolver(event.userId),
      );
    }
    _saveConv(_conversations[convId]!);

    final list = _messages.putIfAbsent(convId, () => []);
    for (final msg in msgs) {
      list.add(msg);
      _saveMsg(msg);
      _downloadMedia(msg);
    }
    _emitMessages(convId);
    _emitConversations();
    ImLogger.ingestMessage(
      convId,
      msgs.first.senderId,
      msgs.first.kind.name,
      msgs.map((m) => m.text).join(' | '),
      segCount: msgs.first.segments?.length,
    );
  }

  void _ingestGroupEvent(OneBotGroupMessageEvent event) {
    final convId = oneBotConversationId(
      selfId: _selfId,
      groupId: event.groupId,
    );
    final imUser = oneBotSenderToImUser(
      event.sender,
      avatarResolver: _avatarResolver,
    );
    final isNewGroupUser = !_users.containsKey(imUser.id);
    _users.putIfAbsent(imUser.id, () => imUser);
    if (isNewGroupUser) _fetchUserAvatar(imUser.id);

    final msgs = oneBotGroupMessageToImMessages(
      event: event,
      conversationId: convId,
      selfId: _selfId,
      resolveName: _resolveNameForAt,
    );

    // Use cached member IDs if available, otherwise lazy-fetch.
    final memberIds = _groupMemberIds[event.groupId] ?? [_selfId];
    final senderName = imUser.displayName;
    final subtitle = '$senderName: ${msgs.last.text}';

    final existing = _conversations[convId];
    if (existing != null) {
      _conversations[convId] = existing.copyWith(
        subtitle: subtitle,
        updatedAt: msgs.last.sentAt,
        unreadCount: existing.unreadCount + 1,
        participantIds:
            existing.participantIds.length <= 1 && memberIds.length > 1
                ? memberIds
                : existing.participantIds,
        avatarLocalPath:
            existing.avatarLocalPath ?? _groupAvatarPaths[event.groupId],
      );
    } else {
      _conversations[convId] = oneBotGroupEventToConversation(
        event: event,
        conversationId: convId,
        selfId: _selfId,
        title: _groupNames[event.groupId] ?? 'Group ${event.groupId}',
        participantIds: memberIds,
        subtitle: subtitle,
        updatedAt: msgs.last.sentAt,
      ).copyWith(avatarLocalPath: _groupAvatarPaths[event.groupId]);
      // Lazily resolve group name and members if not cached.
      _fetchGroupAvatar(event.groupId);
      if (!_groupNames.containsKey(event.groupId)) {
        _resolveGroupName(event.groupId);
      } else if (memberIds.length <= 1) {
        _populateGroupMembers(event.groupId);
      }
    }

    final list = _messages.putIfAbsent(convId, () => []);
    for (final msg in msgs) {
      list.add(msg);
      _saveMsg(msg);
      _downloadMedia(msg);
    }
    _emitMessages(convId);
    _emitConversations();
    _saveConv(_conversations[convId]!);
    ImLogger.ingestMessage(
      convId,
      msgs.first.senderId,
      msgs.first.kind.name,
      msgs.map((m) => m.text).join(' | '),
      segCount: msgs.first.segments?.length,
    );
  }

  void _ingestNoticeEvent(OneBotNoticeEvent event) {
    switch (event) {
      case OneBotEmojiLikeNotice(
        :final groupId,
        :final messageId,
        :final likes,
      ):
        final convId = oneBotConversationId(selfId: _selfId, groupId: groupId);
        final list = _messages[convId];
        if (list == null) return;
        final idx = list.indexWhere((m) => m.id == '$messageId');
        if (idx < 0) return;
        final msg = list[idx];
        final current = Map<String, int>.fromEntries(
          (msg.reactions ?? const []).map((r) => MapEntry(r.emojiId, r.count)),
        );
        for (final like in likes) {
          current[like.emojiId] = like.count;
        }
        final updated =
            current.entries
                .map((e) => ImReaction(emojiId: e.key, count: e.value))
                .toList();
        list[idx] = msg.copyWith(reactions: updated);
        _saveMsg(list[idx]);
        _emitMessages(convId);
        ImLogger.ingestMessage(
          convId,
          '',
          'reaction',
          'msg=$messageId likes=${likes.map((l) => '${l.emojiId}x${l.count}').join(',')}',
        );
      case OneBotGroupUploadNotice(:final groupId, :final userId, :final file):
        final convId = oneBotConversationId(selfId: _selfId, groupId: groupId);
        final senderName = _users[userId]?.displayName ?? userId;
        final sizeLabel = file.size > 0 ? ' (${_formatBytes(file.size)})' : '';
        final msg = ImMessage(
          id: 'file_${event.time}',
          conversationId: convId,
          senderId: userId,
          text: file.name,
          sentAt: DateTime.fromMillisecondsSinceEpoch(event.time * 1000),
          kind: ImMessageKind.file,
          mediaSize: file.size,
        );
        if (!_conversations.containsKey(convId)) {
          _conversations[convId] = ImConversation(
            id: convId,
            type: ImConversationType.group,
            title: _groupNames[groupId] ?? 'Group $groupId',
            participantIds: _groupMemberIds[groupId] ?? [_selfId],
            subtitle: '$senderName uploaded ${file.name}$sizeLabel',
            updatedAt: msg.sentAt,
            avatarLocalPath: _groupAvatarPaths[groupId],
          );
          _emitConversations();
        }
        _messages.putIfAbsent(convId, () => []).add(msg);
        _saveMsg(msg);
        _emitMessages(convId);
      case OneBotPokeNotice(:final groupId, :final userId, :final targetId):
        final isGroup = groupId != null;
        final convId =
            isGroup
                ? oneBotConversationId(selfId: _selfId, groupId: groupId)
                : oneBotConversationId(selfId: _selfId, userId: userId);

        final pokerName = _users[userId]?.displayName ?? userId;
        final targetName =
            targetId == _selfId
                ? '你'
                : (_users[targetId]?.displayName ?? targetId);
        final text = '$pokerName 戳了戳 $targetName';

        final msg = ImMessage(
          id: 'poke_${event.time}',
          conversationId: convId,
          senderId: userId,
          text: text,
          sentAt: DateTime.fromMillisecondsSinceEpoch(event.time * 1000),
          kind: ImMessageKind.poke,
        );

        _messages.putIfAbsent(convId, () => []).add(msg);
        _emitMessages(convId);

        if (!_conversations.containsKey(convId)) {
          final pokeParticipantIds =
              isGroup
                  ? (_groupMemberIds[groupId] ?? [_selfId])
                  : [_selfId, userId];
          _conversations[convId] = ImConversation(
            id: convId,
            type:
                isGroup ? ImConversationType.group : ImConversationType.direct,
            title:
                isGroup
                    ? (_groupNames[groupId] ?? 'Group $groupId')
                    : pokerName,
            participantIds: pokeParticipantIds,
            avatarLocalPath: isGroup ? _groupAvatarPaths[groupId] : null,
            subtitle: text,
            updatedAt: DateTime.fromMillisecondsSinceEpoch(event.time * 1000),
          );
          _emitConversations();
        }
      case OneBotGroupRecallNotice(
        :final groupId,
        :final operatorId,
        :final messageId,
      ):
        ImLogger.logRaw(
          ImLogger.event,
          'recall groupId=$groupId opId=$operatorId msgId=$messageId',
        );
        final convId = oneBotConversationId(selfId: _selfId, groupId: groupId);
        _markRecalled(convId, messageId, operatorId);
      case OneBotGroupIncreaseNotice(:final groupId):
        unawaited(_populateGroupMembers(groupId));
      case OneBotGroupDecreaseNotice(:final groupId, :final userId):
        final convId = oneBotConversationId(selfId: _selfId, groupId: groupId);
        if (userId == _selfId) {
          _groupNames.remove(groupId);
          _groupMemberIds.remove(groupId);
          _groupAvatarPaths.remove(groupId);
          _conversations.remove(convId);
          _emitConversations();
        } else {
          unawaited(_populateGroupMembers(groupId));
        }
      case OneBotFriendRecallNotice(:final userId, :final messageId):
        ImLogger.logRaw(
          ImLogger.event,
          'recall userId=$userId msgId=$messageId',
        );
        final convId = oneBotConversationId(selfId: _selfId, userId: userId);
        _markRecalled(convId, messageId, userId);
      default:
        ImLogger.logRaw(
          ImLogger.event,
          'unhandled notice: ${event.noticeType}',
        );
        break;
    }
  }

  @override
  Future<List<ImReaction>> reactToMessage({
    required String conversationId,
    required String messageId,
    required String emojiId,
    bool remove = false,
  }) async {
    throw UnsupportedError(
      'Message reactions are provided by the OneBot platform.',
    );
  }

  void _markRecalled(String convId, int messageId, String operatorId) {
    _markRecalledByPrefix(convId, '$messageId', operatorId);
  }

  void _markRecalledByPrefix(String convId, String prefix, String operatorId) {
    final list = _messages[convId];
    if (list == null) return;
    final opName = _users[operatorId]?.displayName ?? operatorId;
    var found = false;
    for (var i = 0; i < list.length; i++) {
      if (list[i].id == prefix || list[i].id.startsWith('${prefix}_')) {
        list[i] = list[i].copyWith(recalled: true);
        // Persist the recall notice text separately so we can display it
        // in the banner while keeping the original content.
        _saveRecallNotice(convId, list[i].id, opName);
        _saveMsg(list[i]); // persists recalled flag
        found = true;
      }
    }
    if (found) {
      _emitMessages(convId);
      ImLogger.logRaw(ImLogger.event, 'recall msg=$prefix by=$operatorId');
    }
  }

  final _recallNotices = <String, String>{}; // msgId → operatorName

  void _saveRecallNotice(String convId, String msgId, String opName) {
    _recallNotices[msgId] = opName;
  }

  String? recallNoticeFor(String msgId) => _recallNotices[msgId];

  // -----------------------------------------------------------------
  // Name resolution (connected mode)
  // -----------------------------------------------------------------

  /// Load previously persisted conversations and messages from SQLite.
  Future<void> _loadHistory() async {
    if (_store == null) return;
    try {
      final convs = await _store!.getConversations();
      ImLogger.ingestCount('history conversations', convs.length);
      for (final c in convs) {
        _conversations[c.id] = c;
        if (c.isGroup) {
          final parsed = parseConversationId(c.id, _selfId);
          _groupNames.putIfAbsent(parsed.targetId, () => c.title);
        }
        final msgs = await _store!.getMessages(c.id, limit: 30);
        if (msgs.isNotEmpty) {
          _messages[c.id] = msgs;
        }
      }
      _emitConversations();
      ImLogger.ingestCount(
        'history messages total',
        _messages.values.fold<int>(0, (s, l) => s + l.length),
      );
    } catch (e) {
      ImLogger.logRaw(ImLogger.store, 'loadHistory error: $e');
    }
  }

  /// Persist a message to SQLite (fire-and-forget).
  void _saveMsg(ImMessage msg) {
    final store = _store;
    if (store == null) return;
    unawaited(
      store.insertMessage(msg).catchError((
        Object error,
        StackTrace stackTrace,
      ) {
        ImLogger.logRaw(ImLogger.store, 'save message error: $error');
      }),
    );
  }

  /// Persist a conversation to SQLite.
  void _saveConv(ImConversation conv) {
    final store = _store;
    if (store == null) return;
    unawaited(
      store.upsertConversation(conv).catchError((
        Object error,
        StackTrace stackTrace,
      ) {
        ImLogger.logRaw(ImLogger.store, 'save conversation error: $error');
      }),
    );
  }

  Future<void> _populateInitialData() async {
    if (_client == null) return;

    // Resolve self (bot) display name.
    try {
      final info = await _client!.getLoginInfo();
      _selfId = info.userId;
      _users[_selfId] = ImUser(
        id: _selfId,
        displayName:
            info.nickname.isNotEmpty ? info.nickname : 'Bot ($_selfId)',
        avatarAssetPath: _avatarResolver(_selfId),
        isOnline: true,
      );
    } catch (_) {}

    // Resolve friend nicknames.
    try {
      final friends = await _client!.getFriendList();
      ImLogger.ingestCount('friends loaded', friends.length);
      for (final f in friends) {
        final id = f.userId;
        final name = f.remark.isNotEmpty ? f.remark : f.nickname;
        _friendIds.add(id);
        _users[id] = ImUser(
          id: id,
          displayName: name,
          avatarAssetPath: _avatarResolver(id),
          isOnline: true,
        );
        _fetchUserAvatar(id);
      }
      _emitUsers();
    } catch (_) {}

    // Resolve group names and member lists.
    try {
      final groups = await _client!.getGroupList();
      ImLogger.ingestCount('groups loaded', groups.length);
      for (final g in groups) {
        _groupNames[g.groupId] = g.groupName;
        // Fetch group avatar.
        _fetchGroupAvatar(g.groupId);
        // Update existing conversation title if present.
        final convId = oneBotConversationId(
          selfId: _selfId,
          groupId: g.groupId,
        );
        final conv = _conversations[convId];
        if (conv != null) {
          _conversations[convId] = conv.copyWith(title: g.groupName);
        }
        // Fetch member list for this group.
        await _populateGroupMembers(g.groupId);
      }
      _emitConversations();
    } catch (_) {}
  }

  String _resolveNameForAt(String qq) {
    return _users[qq]?.displayName ?? qq;
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  /// Downloads the group avatar for [groupId] and applies it to the
  /// matching conversation (or stores it for later).
  void _fetchGroupAvatar(String groupId) {
    if (_avatarCache == null) return;
    ImLogger.avatarFetch('group:$groupId');
    _avatarCache!.getGroup(groupId).then((path) {
      if (path == null) return;
      _groupAvatarPaths[groupId] = path;
      ImLogger.avatarReady('group:$groupId', path);
      final convId = oneBotConversationId(selfId: _selfId, groupId: groupId);
      final conv = _conversations[convId];
      if (conv == null) return;
      _conversations[convId] = conv.copyWith(avatarLocalPath: path);
      _emitConversations();
    });
  }

  /// Downloads the QQ avatar for [userId] and updates [ImUser.avatarLocalPath].
  void _fetchUserAvatar(String userId) {
    if (_avatarCache == null) return;
    ImLogger.avatarFetch(userId);
    _avatarCache!.get(userId).then((path) {
      if (path == null) return;
      final u = _users[userId];
      if (u == null) return;
      _users[userId] = u.copyWith(avatarLocalPath: path);
      ImLogger.avatarReady(userId, path);
      if (_friendIds.contains(userId)) _emitUsers();
    });
  }

  /// Parses a mini-program json payload for the preview image URL.
  String? _parseJsonPreview(String raw) {
    try {
      final obj = jsonDecode(raw) as Map<String, dynamic>;
      final meta = obj['meta'] as Map<String, dynamic>?;
      final detail1 = meta?['detail_1'] as Map<String, dynamic>?;
      return (obj['preview'] as String?) ??
          (detail1?['preview'] as String?) ??
          (detail1?['qqdocurl'] as String?);
    } catch (_) {
      return null;
    }
  }

  /// Downloads media for [msg] in the background and updates the message
  /// once the local file is ready.
  void _downloadMedia(ImMessage msg) {
    if (_mediaCache == null || _client == null) return;
    final segs = msg.segments;
    if (segs == null) return;

    for (final seg in segs) {
      final media = oneBotExtractMedia(seg);
      var fileId = media.fileId;
      var url = media.url;

      // For json mini-program cards, extract preview URL from the payload.
      if (seg.type == 'json') {
        final raw = seg.data['data'] as String?;
        if (raw != null && raw.isNotEmpty) {
          url = _parseJsonPreview(raw);
          fileId = url;
        }
      }

      if ((fileId == null || fileId.isEmpty) && (url == null || url.isEmpty)) {
        continue;
      }
      // Record / voice files are downloaded on-demand when the user taps play.
      if (seg.type == 'record') continue;
      final dlId = fileId ?? url!;

      Future<CachedMedia> future;
      switch (seg.type) {
        case 'image':
          future = _mediaCache!.downloadImage(fileId: dlId, url: url);
        case 'record':
          future = _mediaCache!.downloadRecord(fileId: dlId, url: url);
        default:
          future = _mediaCache!.downloadFile(fileId: dlId, url: url);
      }

      future.then((cached) {
        final path = cached.localPath;
        if (path == null) return;
        final list = _messages[msg.conversationId];
        if (list == null) return;
        final idx = list.indexWhere((m) => m.id == msg.id);
        if (idx < 0) return;
        final updated = list[idx].copyWith(mediaPath: path);
        list[idx] = updated;
        _emitMessages(msg.conversationId);
        _saveMsg(updated); // persist media path to store
        ImLogger.mediaReady(path, size: cached.size);
      });
      break; // only process the first media segment
    }
  }

  Future<void> _resolveGroupName(String groupId) async {
    if (_client == null) return;
    try {
      final info = await _client!.getGroupInfo(groupId: groupId);
      _groupNames[groupId] = info.groupName;
      final convId = oneBotConversationId(selfId: _selfId, groupId: groupId);
      final conv = _conversations[convId];
      if (conv != null) {
        _conversations[convId] = conv.copyWith(title: info.groupName);
        _emitConversations();
      }
    } catch (_) {}
    _fetchGroupAvatar(groupId);
    // Also try to populate members.
    await _populateGroupMembers(groupId);
  }

  /// Fetches the member list for [groupId] from OneBot and updates
  /// `_users`, `_groupMemberIds`, and any existing conversation's
  /// `participantIds`.
  Future<void> _populateGroupMembers(String groupId) async {
    if (_client == null) return;
    try {
      final members = await _client!.getGroupMemberList(groupId: groupId);
      final ids = <String>[_selfId];
      for (final m in members) {
        if (m.userId == _selfId) continue; // self already in list
        ids.add(m.userId);
        if (!_users.containsKey(m.userId)) {
          final displayName =
              (m.card != null && m.card!.isNotEmpty) ? m.card! : m.nickname;
          _users[m.userId] = ImUser(
            id: m.userId,
            displayName: displayName,
            avatarAssetPath: _avatarResolver(m.userId),
            isOnline: true,
          );
          _fetchUserAvatar(m.userId);
        }
      }
      _groupMemberIds[groupId] = ids;
      // Update existing conversation participantIds.
      final convId = oneBotConversationId(selfId: _selfId, groupId: groupId);
      final conv = _conversations[convId];
      if (conv != null) {
        _conversations[convId] = conv.copyWith(participantIds: ids);
        _emitConversations();
        _saveConv(_conversations[convId]!);
      }
    } catch (_) {}
  }

  // -----------------------------------------------------------------
  // Internal helpers
  // -----------------------------------------------------------------

  void _emitConversations() {
    final sorted =
        _conversations.values.toList()..sort((a, b) {
          if (a.isPinned != b.isPinned) return a.isPinned ? -1 : 1;
          final at = a.updatedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
          final bt = b.updatedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
          return bt.compareTo(at);
        });
    final c = _conversationControllers['all'];
    if (c != null && !c.isClosed) c.add(sorted);
  }

  void _emitUsers() {
    if (!_usersController.isClosed) {
      _usersController.add(List.unmodifiable(_visibleUsers()));
    }
  }

  /// Optional callback invoked when a new message arrives (for notifications).
  static void Function(String convId, String sender, String text)? onNewMessage;

  void _emitMessages(String conversationId) {
    final c = _messageControllers[conversationId];
    if (c != null && !c.isClosed) {
      c.add(List.unmodifiable(_messages[conversationId] ?? const []));
    }
    // Fire notification hook.
    final list = _messages[conversationId];
    if (list != null && list.isNotEmpty) {
      final last = list.last;
      if (!last.isMine) {
        onNewMessage?.call(
          conversationId,
          _users[last.senderId]?.displayName ?? last.senderId,
          last.text,
        );
      }
    }
  }

  // -----------------------------------------------------------------
  // Mock data
  // -----------------------------------------------------------------

  void _seedMockData() {
    _friendIds.addAll(['belle', 'wise', 'nicole', 'anby', 'fairy']);
    _users.addAll({
      _selfId: ImUser(
        id: _selfId,
        displayName: 'Proxy',
        avatarAssetPath: _avatarResolver(_selfId),
        isOnline: true,
      ),
      'belle': ImUser(
        id: 'belle',
        displayName: 'Belle',
        avatarAssetPath: _avatarResolver('belle'),
        isOnline: true,
      ),
      'wise': ImUser(
        id: 'wise',
        displayName: 'Wise',
        avatarAssetPath: _avatarResolver('wise'),
      ),
      'nicole': ImUser(
        id: 'nicole',
        displayName: 'Nicole Demara',
        avatarAssetPath: _avatarResolver('nicole'),
        isOnline: true,
      ),
      'anby': ImUser(
        id: 'anby',
        displayName: 'Anby Demara',
        avatarAssetPath: _avatarResolver('anby'),
      ),
      'fairy': ImUser(
        id: 'fairy',
        displayName: 'Fairy',
        avatarAssetPath: _avatarResolver('fairy'),
      ),
    });

    final now = DateTime.now();
    _putConversation(
      ImConversation(
        id: 'dm_belle_me',
        type: ImConversationType.direct,
        title: 'Belle',
        participantIds: [_selfId, 'belle'],
        avatarAssetPath: _avatarResolver('belle'),
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
        participantIds: [_selfId, 'wise'],
        avatarAssetPath: _avatarResolver('wise'),
        subtitle: "Don't forget the commission.",
        updatedAt: now.subtract(const Duration(hours: 1)),
      ),
    );
    _putConversation(
      ImConversation(
        id: 'group_cunning_hares',
        type: ImConversationType.group,
        title: 'Cunning Hares',
        participantIds: [_selfId, 'nicole', 'anby', 'belle'],
        avatarAssetPath: _avatarResolver('nicole'),
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
        participantIds: [_selfId, 'nicole'],
        avatarAssetPath: _avatarResolver('nicole'),
        subtitle: 'Interest is compounding.',
        updatedAt: now.subtract(const Duration(days: 1)),
      ),
    );
    _putConversation(
      ImConversation(
        id: 'dm_fairy_me',
        type: ImConversationType.direct,
        title: 'Fairy · System',
        participantIds: [_selfId, 'fairy'],
        avatarAssetPath: _avatarResolver('fairy'),
        subtitle: 'Power inspection scheduled.',
        updatedAt: now.subtract(const Duration(days: 2)),
      ),
    );

    _putMessages('dm_belle_me', [
      _mockMsg(
        'm1',
        'dm_belle_me',
        'belle',
        'Proxy, are you still at the video store?',
        now.subtract(const Duration(minutes: 18)),
      ),
      _mockMsg(
        'm2',
        'dm_belle_me',
        _selfId,
        'Yeah, sorting the new Hollow Observer tapes.',
        now.subtract(const Duration(minutes: 12)),
      ),
      _mockMsg(
        'm3',
        'dm_belle_me',
        'belle',
        'See you at Sixth Street!',
        now.subtract(const Duration(minutes: 3)),
      ),
    ]);
    _putMessages('dm_me_wise', [
      _mockMsg(
        'w1',
        'dm_me_wise',
        'wise',
        "Don't forget the commission.",
        now.subtract(const Duration(hours: 1)),
      ),
    ]);
    _putMessages('group_cunning_hares', [
      _mockMsg(
        'g1',
        'group_cunning_hares',
        'anby',
        'I brought snacks.',
        now.subtract(const Duration(hours: 6)),
      ),
      _mockMsg(
        'g2',
        'group_cunning_hares',
        'nicole',
        'Pay up, buddy.',
        now.subtract(const Duration(hours: 5)),
      ),
      _mockMsg(
        'g3',
        'group_cunning_hares',
        _selfId,
        'Invoice sent.',
        now.subtract(const Duration(hours: 4, minutes: 50)),
      ),
    ]);
    _putMessages('dm_me_nicole', [
      _mockMsg(
        'n1',
        'dm_me_nicole',
        'nicole',
        'Interest is compounding.',
        now.subtract(const Duration(days: 1)),
      ),
    ]);
    _putMessages('dm_fairy_me', [
      ImMessage(
        id: 'f1',
        conversationId: 'dm_fairy_me',
        senderId: 'fairy',
        text: 'Power inspection scheduled.',
        sentAt: now.subtract(const Duration(days: 2)),
        kind: ImMessageKind.system,
      ),
    ]);
  }

  ImMessage _mockMsg(
    String id,
    String convId,
    String senderId,
    String text,
    DateTime sentAt,
  ) {
    return ImMessage(
      id: id,
      conversationId: convId,
      senderId: senderId,
      text: text,
      sentAt: sentAt,
      isMine: senderId == _selfId,
    );
  }

  void _putConversation(ImConversation c) => _conversations[c.id] = c;

  void _putMessages(String convId, List<ImMessage> msgs) =>
      _messages[convId] = List.of(msgs);
}
