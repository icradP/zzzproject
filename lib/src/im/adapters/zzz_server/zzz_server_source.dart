import 'dart:async';
import 'dart:convert';

import 'package:onebot_flutter/onebot_flutter.dart' show oneBotChainFromJson;
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../models/im_models.dart';
import '../../models/im_source_address.dart';
import '../im_message_source.dart';
import 'im_upload_bytes.dart';

typedef ZzzAvatarResolver = String? Function(String userId);
typedef ZzzDisplayNameResolver =
    String Function(String userId, String? nickname);
typedef ZzzNotificationHandler = void Function(String title, String body);

class ZzzServerConfig {
  const ZzzServerConfig({
    required this.serverUrl,
    this.authToken = '',
    this.selfId = '',
  });

  final String serverUrl;
  final String authToken;
  final String selfId;
}

class ZzzAccountResult {
  const ZzzAccountResult({
    required this.userId,
    required this.nickname,
    required this.avatarUrl,
    required this.sessionToken,
  });

  final String userId;
  final String nickname;
  final String avatarUrl;
  final String sessionToken;
}

/// WebSocket-backed source shared by PWA and native clients.
class ZzzServerSource implements ImMessageSource {
  ZzzServerSource({
    required this.config,
    bool allowReconnect = true,
    ZzzAvatarResolver? avatarResolver,
    ZzzDisplayNameResolver? displayNameResolver,
    ZzzNotificationHandler? onNotification,
    Future<void> Function()? onAuthenticationFailed,
  }) : _onAuthenticationFailed = onAuthenticationFailed,
       _onNotification = onNotification,
       _avatarResolver = avatarResolver,
       _displayNameResolver = displayNameResolver,
       _allowReconnect = allowReconnect,
       _selfId = config.selfId;

  final ZzzServerConfig config;
  final bool _allowReconnect;
  final ZzzAvatarResolver? _avatarResolver;
  final ZzzDisplayNameResolver? _displayNameResolver;
  final ZzzNotificationHandler? _onNotification;
  final Future<void> Function()? _onAuthenticationFailed;

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _channelSubscription;
  Timer? _reconnectTimer;
  Timer? _heartbeatTimer;
  int _reconnectAttempts = 0;
  bool _connecting = false;
  bool _disposed = false;
  bool _manualDisconnect = false;
  String _selfId;

  static const _maxReconnectAttempts = 10;
  static const _heartbeatInterval = Duration(seconds: 30);
  static const _messagePageSize = 50;

  final _statusController = StreamController<ConnectionStatus>.broadcast();
  final _usersController = StreamController<List<ImUser>>.broadcast();
  final _conversationsController =
      StreamController<List<ImConversation>>.broadcast();
  final _friendRequestsController =
      StreamController<List<ImFriendRequest>>.broadcast();
  final _messageControllers = <String, StreamController<List<ImMessage>>>{};

  final _conversations = <String, ImConversation>{};
  final _messages = <String, List<ImMessage>>{};
  final _hasMoreMessages = <String, bool>{};
  final _loadingMessageHistory = <String>{};
  final _users = <String, ImUser>{};
  final _friendIds = <String>{};
  List<ImFriendRequest> _friendRequests = const [];
  final _echoCompleters = <String, Completer<Map<String, dynamic>>>{};
  int _echoCounter = 0;
  ConnectionStatus _status = ConnectionStatus.disconnected;

  @override
  String get platformName => 'ZZZ Server';

  @override
  bool get supportsFriendManagement => true;

  @override
  Stream<ConnectionStatus> get connectionStatus async* {
    yield _status;
    yield* _statusController.stream;
  }

  @override
  Future<void> connect() async {
    if (_disposed || _connecting || _status == ConnectionStatus.connected) {
      return;
    }
    _manualDisconnect = false;
    _connecting = true;
    _setStatus(ConnectionStatus.connecting);
    try {
      final channel = WebSocketChannel.connect(Uri.parse(config.serverUrl));
      _channel = channel;
      await channel.ready.timeout(const Duration(seconds: 10));
      _channelSubscription = channel.stream.listen(
        _onRawMessage,
        onDone: _onDisconnected,
        onError: _onError,
        cancelOnError: true,
      );
      await _authenticate();
      await _syncFromServer();
      if (_disposed) return;
      _reconnectAttempts = 0;
      _setStatus(ConnectionStatus.connected);
      _startHeartbeat();
    } catch (_) {
      _setStatus(ConnectionStatus.failed);
      await _closeChannel();
      _scheduleReconnect();
      rethrow;
    } finally {
      _connecting = false;
    }
  }

  @override
  void disconnect() {
    if (_disposed) return;
    _disposed = true;
    _manualDisconnect = true;
    _heartbeatTimer?.cancel();
    _reconnectTimer?.cancel();
    _failPending(StateError('ZZZ Server connection closed'));
    unawaited(_closeChannel());
    _setStatus(ConnectionStatus.disconnected);
    unawaited(_statusController.close());
    unawaited(_usersController.close());
    unawaited(_conversationsController.close());
    unawaited(_friendRequestsController.close());
    for (final controller in _messageControllers.values) {
      unawaited(controller.close());
    }
  }

  @override
  Future<String?> testConnection() async {
    final probe = ZzzServerSource(
      config: config,
      allowReconnect: false,
      avatarResolver: _avatarResolver,
      displayNameResolver: _displayNameResolver,
    );
    try {
      await probe.connect().timeout(const Duration(seconds: 12));
      return null;
    } catch (error) {
      return error.toString();
    } finally {
      probe.disconnect();
    }
  }

  @override
  Future<ImUser> getCurrentUser() async =>
      _users[_selfId] ??
      ImUser(
        id: _selfId,
        displayName: _resolveDisplayName(_selfId, null),
        avatarAssetPath: _avatarResolver?.call(_selfId),
        isOnline: true,
      );

  @override
  Future<ImUser?> getUser(String userId) async {
    final localId = ImSourceAddress.localIdOf(userId);
    final cached = _users[localId];
    if (cached != null) return cached;
    if (_status != ConnectionStatus.connected) return null;
    try {
      final response = await _request('get_user', {'user_id': localId});
      _requireOk(response, 'Load user');
      final data = response['data'];
      if (data is! Map) return null;
      final user = _userFromJson(
        Map<String, dynamic>.from(data),
        fallbackId: localId,
      );
      _users[user.id] = user;
      return user;
    } catch (_) {
      return null;
    }
  }

  @override
  Stream<List<ImUser>> watchUsers() {
    Future.microtask(_emitUsers);
    return _usersController.stream;
  }

  @override
  Stream<List<ImConversation>> watchConversations() async* {
    yield _sortedConversations();
    yield* _conversationsController.stream;
  }

  @override
  Stream<List<ImMessage>> watchMessages(String conversationId) async* {
    final controller = _messageControllers.putIfAbsent(
      conversationId,
      () => StreamController<List<ImMessage>>.broadcast(),
    );
    yield List.unmodifiable(_messages[conversationId] ?? const <ImMessage>[]);
    yield* controller.stream;
  }

  @override
  Future<bool> loadOlderMessages(String conversationId) async {
    if (_hasMoreMessages[conversationId] == false ||
        !_loadingMessageHistory.add(conversationId)) {
      return false;
    }
    try {
      final messages = _messages[conversationId] ?? const <ImMessage>[];
      if (messages.isEmpty || _status != ConnectionStatus.connected) {
        return _hasMoreMessages[conversationId] ?? false;
      }
      final response = await _request('get_messages', {
        'conversation_id': conversationId,
        'limit': _messagePageSize,
        'before_message_id': messages.first.id,
      });
      _requireOk(response, 'Load older messages');
      final data = response['data'];
      if (data is! List) {
        _hasMoreMessages[conversationId] = false;
        return false;
      }
      _mergeMessages(conversationId, data);
      final hasMore = data.length >= _messagePageSize;
      _hasMoreMessages[conversationId] = hasMore;
      return hasMore;
    } finally {
      _loadingMessageHistory.remove(conversationId);
    }
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
    return _sendMessage(conversationId, [
      if (replyToMessageId != null)
        {
          'type': 'reply',
          'data': {'id': replyToMessageId},
        },
      {
        'type': 'text',
        'data': {'text': trimmed},
      },
    ]);
  }

  @override
  Future<void> recallMessage({
    required String conversationId,
    required String messageId,
  }) async {
    final response = await _request('recall_message', {
      'message_id': messageId,
    });
    _requireOk(response, 'Recall message');
    final messages = _messages[conversationId];
    final index =
        messages?.indexWhere((message) => message.id == messageId) ?? -1;
    if (messages != null && index >= 0) {
      messages[index] = messages[index].copyWith(recalled: true);
      _emitMessages(conversationId);
    }
  }

  @override
  Future<List<ImReaction>> reactToMessage({
    required String conversationId,
    required String messageId,
    required String emojiId,
    bool remove = false,
  }) async {
    final response = await _request('react_message', {
      'message_id': messageId,
      'emoji_id': emojiId,
      if (remove) 'remove': true,
    });
    _requireOk(response, 'Update reaction');
    final data = Map<String, dynamic>.from(
      response['data'] as Map? ?? const {},
    );
    final myReactionIds = _stringList(data['my_reactions']);
    final reactions = _parseReactions(
      data['reactions'],
      myReactionIds: myReactionIds,
    );
    final messages = _messages[conversationId];
    final index =
        messages?.indexWhere((message) => message.id == messageId) ?? -1;
    if (messages != null && index >= 0) {
      messages[index] = messages[index].copyWith(reactions: reactions);
      _emitMessages(conversationId);
    }
    return reactions;
  }

  @override
  Future<ImMessage> sendMediaMessage({
    required String conversationId,
    required ImMediaUpload upload,
  }) async {
    final bytes = await readUploadBytes(upload);
    if (bytes.length > 20 * 1024 * 1024) {
      throw StateError('Files larger than 20 MB are not supported.');
    }
    final fileType = _segmentType(upload.kind);
    if (fileType == null) throw StateError('Unsupported media type.');
    final response = await _request('upload_file', {
      'file': base64Encode(bytes),
      'file_name': upload.fileName,
      'file_type': fileType == 'record' ? 'voice' : fileType,
      'mime_type': upload.mimeType ?? 'application/octet-stream',
    }, timeout: const Duration(seconds: 30));
    _requireOk(response, 'Upload file');
    final data = response['data'] as Map?;
    final url = data?['url'] as String?;
    final fileId = data?['file_id'] as String?;
    if (url == null || url.isEmpty || fileId == null || fileId.isEmpty) {
      throw StateError('Upload file failed: invalid server response');
    }
    return _sendMessage(conversationId, [
      {
        'type': fileType,
        'data': {
          'file': fileId,
          'url': url,
          'name': upload.fileName,
          'mime_type': upload.mimeType,
          'size': bytes.length,
        },
      },
    ]);
  }

  @override
  Future<void> markConversationRead(String conversationId) async {
    final conversation = _conversations[conversationId];
    final previousUnreadCount = conversation?.unreadCount ?? 0;
    if (conversation != null && conversation.unreadCount != 0) {
      _conversations[conversationId] = conversation.copyWith(unreadCount: 0);
      _emitConversations();
    }
    if (_status == ConnectionStatus.connected) {
      try {
        final response = await _request('mark_read', {
          'conversation_id': conversationId,
        });
        _requireOk(response, 'Mark conversation read');
      } catch (_) {
        final current = _conversations[conversationId];
        if (current != null && previousUnreadCount > 0) {
          _conversations[conversationId] = current.copyWith(
            unreadCount: current.unreadCount + previousUnreadCount,
          );
          _emitConversations();
        }
        rethrow;
      }
    }
  }

  @override
  Future<void> setConversationPreferences({
    required String conversationId,
    required bool isPinned,
    required bool isMuted,
  }) async {
    final previous = _conversations[conversationId];
    if (previous == null) throw StateError('Conversation not found.');
    _conversations[conversationId] = previous.copyWith(
      isPinned: isPinned,
      isMuted: isMuted,
    );
    _emitConversations();
    try {
      final response = await _request('set_conversation_preferences', {
        'conversation_id': conversationId,
        'is_pinned': isPinned,
        'is_muted': isMuted,
      });
      _requireOk(response, 'Save conversation preferences');
    } catch (_) {
      _conversations[conversationId] = previous;
      _emitConversations();
      rethrow;
    }
  }

  @override
  Future<List<ImConversation>> searchConversations(String query) async {
    final normalized = query.trim().toLowerCase();
    if (normalized.isEmpty) return _sortedConversations();
    return _conversations.values.where((conversation) {
      return conversation.title.toLowerCase().contains(normalized) ||
          (conversation.subtitle ?? '').toLowerCase().contains(normalized);
    }).toList();
  }

  @override
  Future<List<ImUser>> getUsers() async => _visibleUsers();

  @override
  Future<List<ImUser>> searchUsers(String query) async {
    final normalized = query.trim();
    if (normalized.isEmpty) return const [];
    final response = await _request('search_users', {'query': normalized});
    _requireOk(response, 'Search users');
    final users = <ImUser>[];
    for (final raw in response['data'] as List? ?? const []) {
      if (raw is! Map) continue;
      final user = _userFromJson(
        Map<String, dynamic>.from(raw),
        fallbackId: '${raw['user_id'] ?? ''}',
      );
      if (user.id.isEmpty) continue;
      _users[user.id] = user;
      users.add(user);
    }
    return users;
  }

  @override
  Future<List<ImFriendRequest>> getFriendRequests() async {
    final response = await _request('get_friend_requests', const {});
    _requireOk(response, 'Load friend requests');
    final requests = <ImFriendRequest>[];
    final responseData = response['data'];
    for (final raw in responseData is List ? responseData : const []) {
      if (raw is! Map) continue;
      final json = Map<String, dynamic>.from(raw);
      final fromData = Map<String, dynamic>.from(
        json['from_user'] as Map? ?? const {},
      );
      final toData = Map<String, dynamic>.from(
        json['to_user'] as Map? ?? const {},
      );
      final from = _userFromJson(
        fromData,
        fallbackId: '${fromData['user_id'] ?? ''}',
      );
      final to = _userFromJson(
        toData,
        fallbackId: '${toData['user_id'] ?? ''}',
      );
      if (from.id.isEmpty || to.id.isEmpty) continue;
      _users[from.id] = from;
      _users[to.id] = to;
      final timestamp = (json['created_at'] as num?)?.toInt() ?? 0;
      requests.add(
        ImFriendRequest(
          id: '${json['flag'] ?? ''}',
          fromUser: from,
          toUser: to,
          comment: '${json['comment'] ?? ''}',
          status: '${json['status'] ?? 'pending'}',
          createdAt:
              timestamp > 0
                  ? DateTime.fromMillisecondsSinceEpoch(timestamp * 1000)
                  : null,
        ),
      );
    }
    _friendRequests = requests
        .where((request) => request.id.isNotEmpty)
        .toList(growable: false);
    _emitFriendRequests();
    return _friendRequests;
  }

  @override
  Stream<List<ImFriendRequest>> watchFriendRequests() async* {
    yield List.unmodifiable(_friendRequests);
    if (_status == ConnectionStatus.connected) {
      unawaited(getFriendRequests().catchError((_) => _friendRequests));
    }
    yield* _friendRequestsController.stream;
  }

  @override
  Future<void> sendFriendRequest({
    required String userId,
    String comment = '',
  }) async {
    final response = await _request('friend_request', {
      'user_id': ImSourceAddress.localIdOf(userId),
      if (comment.trim().isNotEmpty) 'comment': comment.trim(),
    });
    _requireOk(response, 'Send friend request');
    await getFriendRequests();
  }

  @override
  Future<void> handleFriendRequest({
    required String requestId,
    required bool accept,
  }) async {
    final response = await _request('friend_request_handle', {
      'flag': ImSourceAddress.localIdOf(requestId),
      'action': accept ? 'accept' : 'reject',
    });
    _requireOk(
      response,
      accept ? 'Accept friend request' : 'Reject friend request',
    );
    if (accept) await _syncUsers();
    await getFriendRequests();
  }

  @override
  Future<void> removeFriend(String userId) async {
    final localId = ImSourceAddress.localIdOf(userId);
    final response = await _request('remove_friend', {'user_id': localId});
    _requireOk(response, 'Remove friend');
    _users.remove(localId);
    _friendIds.remove(localId);
    _emitUsers();
    _conversations.removeWhere(
      (id, conversation) =>
          conversation.isDirect &&
          conversation.participantIds.contains(localId),
    );
    _emitConversations();
  }

  @override
  Future<List<ImConversation>> getGroupList() async {
    if (_status == ConnectionStatus.connected) {
      final response = await _request('get_group_list', const {});
      _requireOk(response, 'Load groups');
      final groups = <ImConversation>[];
      for (final raw in (response['data'] as List? ?? const [])) {
        if (raw is! Map) continue;
        final json = Map<String, dynamic>.from(raw);
        final id = '${json['group_id'] ?? ''}';
        if (id.isEmpty) continue;
        var participants = <String>[_selfId];
        try {
          final info = await _request('get_group_info', {'group_id': id});
          if (info['status'] == 'ok') {
            final infoData = Map<String, dynamic>.from(
              info['data'] as Map? ?? const {},
            );
            participants =
                (infoData['members'] as List? ?? const [])
                    .whereType<Map>()
                    .map((m) => '${m['user_id'] ?? ''}')
                    .where((v) => v.isNotEmpty)
                    .toList();
          }
        } catch (_) {}
        final existing = _conversations[id];
        final conversation = ImConversation(
          id: id,
          type: ImConversationType.group,
          title: '${json['name'] ?? id}',
          participantIds: participants,
          avatarAssetPath: _resolveAvatar(id, json['avatar_url'] as String?),
          avatarLocalPath: existing?.avatarLocalPath,
          subtitle: existing?.subtitle,
          updatedAt: existing?.updatedAt,
          unreadCount: existing?.unreadCount ?? 0,
          isPinned: existing?.isPinned ?? false,
          isMuted: existing?.isMuted ?? false,
        );
        _conversations[id] = conversation;
        groups.add(conversation);
      }
      _emitConversations();
      return groups;
    }
    return _conversations.values
        .where((conversation) => conversation.isGroup)
        .toList(growable: false);
  }

  @override
  Future<ImUser> updateProfile({
    String? nickname,
    ImMediaUpload? avatar,
    String? avatarAssetPath,
  }) async {
    String? avatarUrl;
    if (avatar != null && avatarAssetPath == null) {
      final bytes = await readUploadBytes(avatar);
      if (bytes.length > 5 * 1024 * 1024) {
        throw StateError('Avatars must be 5 MB or smaller.');
      }
      final upload = await _request('upload_file', {
        'file': base64Encode(bytes),
        'file_name': avatar.fileName,
        'file_type': 'image',
        'mime_type': avatar.mimeType ?? 'image/jpeg',
      });
      _requireOk(upload, 'Upload avatar');
      avatarUrl = (upload['data'] as Map?)?['url'] as String?;
    }
    final params = <String, dynamic>{};
    if (nickname != null) params['nickname'] = nickname.trim();
    if (avatarAssetPath != null && avatarAssetPath.isNotEmpty) {
      params['avatar_url'] = avatarAssetPath;
    } else if (avatarUrl != null && avatarUrl.isNotEmpty) {
      params['avatar_url'] = avatarUrl;
    }
    if (params.isEmpty) return getCurrentUser();
    final response = await _request('update_profile', params);
    _requireOk(response, 'Update profile');
    final data = Map<String, dynamic>.from(
      response['data'] as Map? ?? const {},
    );
    final user = _userFromJson(data, fallbackId: _selfId);
    _users[_selfId] = user;
    return user;
  }

  @override
  Future<ImConversation> createGroup({
    required String name,
    List<String> memberIds = const [],
    ImMediaUpload? avatar,
  }) async {
    String? avatarUrl;
    if (avatar != null) {
      final bytes = await readUploadBytes(avatar);
      if (bytes.length > 5 * 1024 * 1024) {
        throw StateError('Group avatars must be 5 MB or smaller.');
      }
      final upload = await _request('upload_file', {
        'file': base64Encode(bytes),
        'file_name': avatar.fileName,
        'file_type': 'image',
        'mime_type': avatar.mimeType ?? 'image/jpeg',
      });
      _requireOk(upload, 'Upload group avatar');
      avatarUrl = (upload['data'] as Map?)?['url'] as String?;
    }
    final response = await _request('create_group', {
      'name': name.trim(),
      if (avatarUrl != null) 'avatar': avatarUrl,
      if (memberIds.isNotEmpty) 'members': memberIds,
    });
    _requireOk(response, 'Create group');
    final data = Map<String, dynamic>.from(
      response['data'] as Map? ?? const {},
    );
    final id = '${data['group_id'] ?? ''}';
    if (id.isEmpty) throw StateError('Create group failed: missing group id');
    final conversation = ImConversation(
      id: id,
      type: ImConversationType.group,
      title: '${data['name'] ?? name.trim()}',
      participantIds:
          (data['participants'] as List?)?.map((v) => '$v').toList() ??
          [_selfId],
      avatarAssetPath: _resolveAvatar(id, data['avatar_url'] as String?),
      sourceId: null,
    );
    _conversations[id] = conversation;
    _emitConversations();
    return conversation;
  }

  @override
  Future<void> joinGroup(String groupId) async {
    final response = await _request('join_group', {'group_id': groupId});
    _requireOk(response, 'Join group');
    await _syncFromServer();
  }

  @override
  Future<void> leaveGroup(String groupId) async {
    final response = await _request('leave_group', {'group_id': groupId});
    _requireOk(response, 'Leave group');
    _conversations.remove(groupId);
    _emitConversations();
  }

  @override
  Future<ImGroupDetails> getGroupDetails(String groupId) async {
    final response = await _request('get_group_info', {'group_id': groupId});
    _requireOk(response, 'Load group details');
    final data = Map<String, dynamic>.from(
      response['data'] as Map? ?? const {},
    );
    final members = <ImGroupMember>[];
    for (final raw in data['members'] as List? ?? const []) {
      if (raw is! Map) continue;
      final json = Map<String, dynamic>.from(raw);
      final userID = '${json['user_id'] ?? ''}';
      if (userID.isEmpty) continue;
      final user = ImUser(
        id: userID,
        displayName: _resolveDisplayName(userID, json['nickname'] as String?),
        avatarAssetPath: _resolveAvatar(userID, json['avatar_url'] as String?),
        isOnline: json['online'] as bool? ?? false,
      );
      _users[userID] = user;
      final joinedAt = (json['joined_at'] as num?)?.toInt();
      final mutedUntil = (json['muted_until'] as num?)?.toInt();
      members.add(
        ImGroupMember(
          user: user,
          role: imGroupRoleFromString(json['role'] as String?),
          joinedAt:
              joinedAt == null || joinedAt <= 0
                  ? null
                  : DateTime.fromMillisecondsSinceEpoch(joinedAt * 1000),
          mutedUntil:
              mutedUntil == null || mutedUntil <= 0
                  ? null
                  : DateTime.fromMillisecondsSinceEpoch(mutedUntil * 1000),
        ),
      );
    }
    final participants = members
        .map((member) => member.user.id)
        .toList(growable: false);
    final existing = _conversations[groupId];
    final conversation = ImConversation(
      id: groupId,
      type: ImConversationType.group,
      title: '${data['name'] ?? existing?.title ?? groupId}',
      participantIds: participants,
      subtitle: existing?.subtitle,
      avatarAssetPath: _resolveAvatar(groupId, data['avatar_url'] as String?),
      avatarLocalPath: existing?.avatarLocalPath,
      updatedAt: existing?.updatedAt,
      unreadCount: existing?.unreadCount ?? 0,
      isPinned: existing?.isPinned ?? false,
      isMuted: existing?.isMuted ?? false,
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
      supportsInvites: true,
      supportsMemberRemoval: true,
      canLeave: currentRole != null && currentRole != ImGroupRole.owner,
      announcement: '${data['announcement'] ?? ''}',
      muteAll: data['mute_all'] as bool? ?? false,
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
    final response = await _request('group_invite', {
      'group_id': groupId,
      'members': userIds,
    });
    _requireOk(response, 'Invite group members');
    await _syncFromServer();
  }

  @override
  Future<void> removeGroupMember({
    required String groupId,
    required String userId,
  }) async {
    final response = await _request('group_kick', {
      'group_id': groupId,
      'user_id': userId,
    });
    _requireOk(response, 'Remove group member');
    await _syncFromServer();
  }

  @override
  Future<void> updateGroup({
    required String groupId,
    String? name,
    ImMediaUpload? avatar,
    String? announcement,
  }) async {
    String? avatarUrl;
    if (avatar != null) {
      final bytes = await readUploadBytes(avatar);
      if (bytes.length > 5 * 1024 * 1024) {
        throw StateError('Group avatars must be 5 MB or smaller.');
      }
      final upload = await _request('upload_file', {
        'file': base64Encode(bytes),
        'file_name': avatar.fileName,
        'file_type': 'image',
        'mime_type': avatar.mimeType ?? 'image/jpeg',
      });
      _requireOk(upload, 'Upload group avatar');
      avatarUrl = (upload['data'] as Map?)?['url'] as String?;
    }
    final response = await _request('update_group', {
      'group_id': groupId,
      if (name != null) 'name': name.trim(),
      if (avatarUrl != null) 'avatar_url': avatarUrl,
      if (announcement != null) 'announcement': announcement.trim(),
    });
    _requireOk(response, 'Update group');
    await getGroupDetails(groupId);
  }

  @override
  Future<void> setGroupAdmin({
    required String groupId,
    required String userId,
    required bool enabled,
  }) async {
    final response = await _request('set_group_admin', {
      'group_id': groupId,
      'user_id': userId,
      'enabled': enabled,
    });
    _requireOk(response, 'Update administrator');
  }

  @override
  Future<void> setGroupMemberMute({
    required String groupId,
    required String userId,
    required Duration duration,
  }) async {
    final response = await _request('group_ban', {
      'group_id': groupId,
      'user_id': userId,
      'duration': duration.inSeconds,
    });
    _requireOk(
      response,
      duration == Duration.zero ? 'Unmute member' : 'Mute member',
    );
  }

  @override
  Future<void> setGroupMuteAll({
    required String groupId,
    required bool enabled,
  }) async {
    final response = await _request('group_mute_all', {
      'group_id': groupId,
      'enabled': enabled,
    });
    _requireOk(response, 'Update whole-group mute');
  }

  @override
  Future<void> transferGroupOwnership({
    required String groupId,
    required String userId,
  }) async {
    final response = await _request('transfer_group', {
      'group_id': groupId,
      'user_id': userId,
    });
    _requireOk(response, 'Transfer group ownership');
  }

  @override
  Future<void> dismissGroup(String groupId) async {
    final response = await _request('dismiss_group', {'group_id': groupId});
    _requireOk(response, 'Dismiss group');
    _conversations.remove(groupId);
    _messages.remove(groupId);
    _emitConversations();
  }

  @override
  Future<void> ensureConversation(ImConversation conversation) async {
    _conversations[conversation.id] = conversation;
    _emitConversations();
    if (_status == ConnectionStatus.connected) {
      await _ensureRemoteConversation(conversation);
    }
  }

  @override
  Future<void> deleteConversation(String conversationId) async {
    _conversations.remove(conversationId);
    _messages.remove(conversationId);
    _emitConversations();
  }

  @override
  Future<void> clearAvatarCache() async {}

  @override
  Future<void> saveForwardRaw(String forwardId, String rawJson) async {}

  @override
  Future<String?> loadForwardRaw(String forwardId) async => null;

  Future<String?> getPushPublicKey() async {
    final response = await _request('get_push_config', const {});
    _requireOk(response, 'Load push configuration');
    return (response['data'] as Map?)?['public_key'] as String?;
  }

  Future<void> registerPushSubscription(
    Map<String, dynamic> subscription,
  ) async {
    final response = await _request('register_push', subscription);
    _requireOk(response, 'Register push subscription');
  }

  Future<void> unregisterPushSubscription(String endpoint) async {
    final response = await _request('unregister_push', {'endpoint': endpoint});
    _requireOk(response, 'Unregister push subscription');
  }

  Future<void> _syncFromServer() async {
    await _syncUsers();
    await getFriendRequests();
    final response = await _request('get_conversations', const {});
    _requireOk(response, 'Load conversations');
    final data = response['data'];
    if (data is! List) return;

    final remoteIds = <String>{};
    for (final raw in data) {
      if (raw is! Map) continue;
      final conversation = _parseConversation(Map<String, dynamic>.from(raw));
      if (conversation == null) continue;
      remoteIds.add(conversation.id);
      _conversations[conversation.id] = conversation;
      await _syncMessages(conversation.id);
    }
    _conversations.removeWhere(
      (id, _) => !remoteIds.contains(id) && !_messages.containsKey(id),
    );
    _emitConversations();
  }

  Future<void> _syncUsers() async {
    final response = await _request('get_friends', const {});
    _requireOk(response, 'Load users');
    final data = response['data'];
    if (data is! List) return;
    _friendIds.clear();
    for (final raw in data) {
      if (raw is! Map) continue;
      final json = Map<String, dynamic>.from(raw);
      final id = '${json['user_id'] ?? ''}';
      if (id.isEmpty) continue;
      _friendIds.add(id);
      _users[id] = ImUser(
        id: id,
        displayName: _resolveDisplayName(id, json['nickname'] as String?),
        isOnline: json['online'] as bool? ?? false,
        avatarAssetPath: _preserveAvatarRevision(
          _users[id]?.avatarAssetPath,
          _resolveAvatar(id, json['avatar_url'] as String?),
        ),
        relationship: imRelationshipFromString(json['relationship'] as String?),
      );
    }
    _emitUsers();
  }

  Future<void> _syncMessages(String conversationId) async {
    final response = await _request('get_messages', {
      'conversation_id': conversationId,
      'limit': _messagePageSize,
    });
    _requireOk(response, 'Load messages');
    final data = response['data'];
    if (data is! List) return;

    _mergeMessages(conversationId, data);
    _hasMoreMessages[conversationId] = data.length >= _messagePageSize;
  }

  void _mergeMessages(String conversationId, List<dynamic> data) {
    final merged = <String, ImMessage>{
      for (final message in _messages[conversationId] ?? const <ImMessage>[])
        message.id: message,
    };
    for (final raw in data) {
      if (raw is! Map) continue;
      final message = _parseMessage(Map<String, dynamic>.from(raw));
      if (message != null) merged[message.id] = message;
    }
    final sorted =
        merged.values.toList()..sort((a, b) => a.sentAt.compareTo(b.sentAt));
    _messages[conversationId] = sorted;
    _emitMessages(conversationId);
  }

  ImConversation? _parseConversation(Map<String, dynamic> json) {
    final id = '${json['conversation_id'] ?? ''}';
    if (id.isEmpty) return null;
    final participants =
        (json['participants'] as List?)
            ?.map((value) => '$value')
            .toList(growable: false) ??
        const <String>[];
    final timestamp = (json['last_timestamp'] as num?)?.toInt() ?? 0;
    final isGroup = json['type'] == 'group';
    ImUser? peer;
    if (!isGroup) {
      for (final participantID in participants) {
        if (participantID != _selfId) {
          peer = _users[participantID];
          break;
        }
      }
    }
    return ImConversation(
      id: id,
      type: isGroup ? ImConversationType.group : ImConversationType.direct,
      title: peer?.displayName ?? '${json['title'] ?? id}',
      participantIds: participants,
      subtitle: json['last_message'] as String?,
      avatarAssetPath:
          peer?.avatarAssetPath ??
          _resolveConversationAvatar(
            id: id,
            isGroup: isGroup,
            participantIds: participants,
            value: json['avatar_url'] as String?,
          ),
      unreadCount: (json['unread_count'] as num?)?.toInt() ?? 0,
      isPinned: json['is_pinned'] as bool? ?? false,
      isMuted: json['is_muted'] as bool? ?? false,
      updatedAt:
          timestamp > 0
              ? DateTime.fromMillisecondsSinceEpoch(timestamp * 1000)
              : null,
    );
  }

  void _onRawMessage(dynamic raw) {
    try {
      final decoded = jsonDecode(raw as String);
      if (decoded is! Map) return;
      final json = Map<String, dynamic>.from(decoded);
      if (json.containsKey('post_type')) {
        _handleEvent(json);
      } else if (json.containsKey('echo')) {
        _handleResponse(json);
      }
    } catch (_) {
      // A malformed frame must not take down the realtime connection.
    }
  }

  void _handleEvent(Map<String, dynamic> json) {
    switch (json['post_type']) {
      case 'message':
        final message = _parseMessage(json);
        if (message != null) _addMessageToStream(message);
        break;
      case 'notice':
        _handleNoticeEvent(json);
        break;
      case 'request':
        _handleRequestEvent(json);
        break;
    }
  }

  void _handleRequestEvent(Map<String, dynamic> json) {
    if (json['request_type'] != 'friend') return;
    final userID = '${json['user_id'] ?? ''}';
    final comment = '${json['comment'] ?? ''}'.trim();
    final name =
        _users[userID]?.displayName ?? _resolveDisplayName(userID, null);
    _onNotification?.call(
      'New friend request',
      comment.isEmpty ? '$name wants to connect' : '$name: $comment',
    );
    unawaited(getFriendRequests().catchError((_) => _friendRequests));
  }

  void _handleNoticeEvent(Map<String, dynamic> json) {
    if (json['notice_type'] == 'conversation_preferences') {
      final conversationId = '${json['conversation_id'] ?? ''}';
      final conversation = _conversations[conversationId];
      if (conversation != null) {
        _conversations[conversationId] = conversation.copyWith(
          isPinned: json['is_pinned'] as bool? ?? conversation.isPinned,
          isMuted: json['is_muted'] as bool? ?? conversation.isMuted,
        );
        _emitConversations();
      }
      return;
    }
    if (json['notice_type'] == 'message_read') {
      _handleMessageRead(json);
      return;
    }
    if (json['notice_type'] == 'message_reaction') {
      _handleMessageReaction(json);
      return;
    }
    final noticeType = json['notice_type'];
    if (noticeType == 'profile_update') {
      _handleProfileUpdate(json);
      return;
    }
    if (noticeType == 'friend_presence') {
      final userID = '${json['user_id'] ?? ''}';
      final user = _users[userID];
      if (user != null && json['online'] is bool) {
        _users[userID] = user.copyWith(isOnline: json['online'] as bool);
        _emitUsers();
      }
      return;
    }
    if (noticeType == 'friend_add' || noticeType == 'friend_remove') {
      unawaited(_syncUsers().catchError((_) {}));
      unawaited(getFriendRequests().catchError((_) => _friendRequests));
      if (noticeType == 'friend_add') {
        final userID = '${json['user_id'] ?? ''}';
        final name =
            _users[userID]?.displayName ?? _resolveDisplayName(userID, null);
        _onNotification?.call(
          'Friend request accepted',
          '$name accepted your friend request',
        );
      }
      return;
    }
    if (noticeType == 'friend_request_result') {
      unawaited(getFriendRequests().catchError((_) => _friendRequests));
      final userID = '${json['user_id'] ?? ''}';
      final name =
          _users[userID]?.displayName ?? _resolveDisplayName(userID, null);
      _onNotification?.call(
        'Friend request updated',
        '$name declined your friend request',
      );
      return;
    }
    if (noticeType == 'group_dismiss') {
      final groupId = '${json['group_id'] ?? ''}';
      if (groupId.isNotEmpty) {
        _conversations.remove(groupId);
        _messages.remove(groupId);
        _emitConversations();
      }
      return;
    }
    if (noticeType == 'group_increase' || noticeType == 'group_decrease') {
      unawaited(_syncFromServer().catchError((_) {}));
      return;
    }
    if (noticeType == 'group_update' ||
        noticeType == 'group_admin' ||
        noticeType == 'group_ban' ||
        noticeType == 'group_transfer' ||
        noticeType == 'group_mute_all') {
      unawaited(_syncFromServer().catchError((_) {}));
      return;
    }
    if (json['notice_type'] != 'friend_recall' &&
        json['notice_type'] != 'group_recall') {
      return;
    }
    final messageId = '${json['message_id'] ?? ''}';
    if (messageId.isEmpty) return;
    for (final entry in _messages.entries) {
      final index = entry.value.indexWhere(
        (message) => message.id == messageId,
      );
      if (index < 0) continue;
      entry.value[index] = entry.value[index].copyWith(recalled: true);
      _emitMessages(entry.key);
      break;
    }
  }

  void _handleProfileUpdate(Map<String, dynamic> json) {
    final userID = '${json['user_id'] ?? ''}';
    if (userID.isEmpty) return;
    final existing = _users[userID];
    var avatar = _resolveAvatar(userID, json['avatar_url'] as String?);
    final version = (json['profile_version'] as num?)?.toInt() ?? 0;
    final avatarUri = avatar == null ? null : Uri.tryParse(avatar);
    if (version > 0 &&
        avatarUri != null &&
        (avatarUri.scheme == 'http' || avatarUri.scheme == 'https')) {
      avatar =
          avatarUri
              .replace(
                queryParameters: {
                  ...avatarUri.queryParameters,
                  'profile_v': '$version',
                },
              )
              .toString();
    }
    final user = ImUser(
      id: userID,
      displayName: _resolveDisplayName(userID, json['nickname'] as String?),
      avatarAssetPath: avatar,
      isOnline: existing?.isOnline ?? true,
      relationship: existing?.relationship ?? ImRelationship.none,
    );
    _users[userID] = user;
    var conversationsChanged = false;
    for (final entry in _conversations.entries.toList()) {
      final conversation = entry.value;
      if (!conversation.isDirect ||
          !conversation.participantIds.contains(userID)) {
        continue;
      }
      _conversations[entry.key] = conversation.copyWith(
        title: user.displayName,
        avatarAssetPath: user.avatarAssetPath,
      );
      conversationsChanged = true;
    }
    _emitUsers();
    if (conversationsChanged) _emitConversations();
  }

  void _handleMessageReaction(Map<String, dynamic> json) {
    final conversationId = '${json['conversation_id'] ?? ''}';
    final messageId = '${json['message_id'] ?? ''}';
    if (conversationId.isEmpty || messageId.isEmpty) return;
    final messages = _messages[conversationId];
    if (messages == null) {
      unawaited(_syncMessages(conversationId).catchError((_) {}));
      return;
    }
    final index = messages.indexWhere((message) => message.id == messageId);
    if (index < 0) {
      unawaited(_syncMessages(conversationId).catchError((_) {}));
      return;
    }
    final previous = messages[index].reactions ?? const <ImReaction>[];
    final aggregate = _parseReactions(json['reactions']);
    final actorID = '${json['user_id'] ?? ''}';
    final emojiID = '${json['emoji_id'] ?? ''}';
    final removed = json['removed'] as bool? ?? false;
    final byEmoji = <String, ImReaction>{
      for (final reaction in aggregate) reaction.emojiId: reaction,
    };
    for (final reaction in previous) {
      final current = byEmoji[reaction.emojiId];
      if (current != null) {
        byEmoji[reaction.emojiId] = current.copyWith(
          reactedByMe: reaction.reactedByMe,
        );
      }
    }
    if (actorID == _selfId && emojiID.isNotEmpty) {
      final current = byEmoji[emojiID];
      if (current != null) {
        byEmoji[emojiID] = current.copyWith(reactedByMe: !removed);
      }
    }
    final updated = byEmoji.values.toList(growable: false);
    messages[index] = messages[index].copyWith(reactions: updated);
    _emitMessages(conversationId);
  }

  void _handleMessageRead(Map<String, dynamic> json) {
    final conversationId = '${json['conversation_id'] ?? ''}';
    final lastReadMessageId = '${json['last_read_message_id'] ?? ''}';
    if (conversationId.isEmpty || lastReadMessageId.isEmpty) return;
    final messages = _messages[conversationId];
    if (messages == null) return;
    final cursor = messages.indexWhere(
      (message) => message.id == lastReadMessageId,
    );
    if (cursor < 0) return;
    var changed = false;
    for (var index = 0; index <= cursor; index++) {
      final message = messages[index];
      if (!message.isMine || message.status == ImMessageStatus.failed) {
        continue;
      }
      final readCount =
          message.recipientCount <= 1
              ? 1
              : message.readCount < 1
              ? 1
              : message.readCount;
      if (message.status == ImMessageStatus.read &&
          message.readCount == readCount) {
        continue;
      }
      messages[index] = message.copyWith(
        status: ImMessageStatus.read,
        readCount: readCount,
      );
      changed = true;
    }
    if (changed) _emitMessages(conversationId);
    if (_conversations[conversationId]?.isGroup ?? false) {
      unawaited(_syncMessages(conversationId).catchError((_) {}));
    }
  }

  void _handleResponse(Map<String, dynamic> json) {
    final echo = json['echo'] as String?;
    if (echo == null) return;
    final completer = _echoCompleters.remove(echo);
    if (completer != null && !completer.isCompleted) completer.complete(json);
  }

  ImMessage? _parseMessage(Map<String, dynamic> json) {
    try {
      final conversationId = '${json['conversation_id'] ?? ''}';
      final sender = Map<String, dynamic>.from(
        json['sender'] as Map? ?? const {},
      );
      final senderId = '${sender['user_id'] ?? ''}';
      if (conversationId.isEmpty || senderId.isEmpty) return null;
      final segments =
          (json['message'] as List?)
              ?.whereType<Map>()
              .map((segment) => Map<String, dynamic>.from(segment))
              .toList() ??
          const <Map<String, dynamic>>[];
      final first = _firstSegmentWhere(segments, (segment) {
        return segment['type'] != 'reply';
      });
      final reply = _firstSegmentWhere(segments, (segment) {
        return segment['type'] == 'reply';
      });
      final data =
          first?['data'] is Map
              ? Map<String, dynamic>.from(first!['data'] as Map)
              : const <String, dynamic>{};
      final myReactionIds = _stringList(json['my_reactions']);

      final knownSender = _users[senderId];
      _users[senderId] = ImUser(
        id: senderId,
        displayName: _resolveDisplayName(
          senderId,
          sender['nickname'] as String?,
        ),
        avatarAssetPath: _preserveAvatarRevision(
          knownSender?.avatarAssetPath,
          _resolveAvatar(senderId, sender['avatar_url'] as String?),
        ),
        isOnline: true,
        relationship: knownSender?.relationship ?? ImRelationship.none,
      );
      if (_friendIds.contains(senderId)) _emitUsers();
      final mediaUrl = (data['url'] as String?) ?? (data['file'] as String?);
      return ImMessage(
        id: '${json['message_id']}',
        conversationId: conversationId,
        senderId: senderId,
        text: segments.map(_segmentDisplayText).join().trim(),
        sentAt: DateTime.fromMillisecondsSinceEpoch(
          ((json['timestamp'] as num?)?.toInt() ?? 0) * 1000,
        ),
        kind: _kindForSegment(first?['type'] as String?),
        status: _statusFromJson(json['status']),
        readCount: (json['read_count'] as num?)?.toInt() ?? 0,
        recipientCount: (json['recipient_count'] as num?)?.toInt() ?? 0,
        isMine: senderId == _selfId,
        segments: oneBotChainFromJson(segments),
        mediaPath: _resolveMediaUrl(mediaUrl),
        mediaUrl: mediaUrl,
        mediaSize: (data['size'] as num?)?.toInt(),
        mediaMime: data['mime_type'] as String?,
        reactions: _parseReactions(
          json['reactions'],
          myReactionIds: myReactionIds,
        ),
        recalled: json['recalled'] as bool? ?? false,
        replyToMessageId: _replyMessageId(reply),
      );
    } catch (_) {
      return null;
    }
  }

  List<String> _stringList(Object? value) {
    if (value is! List) return const <String>[];
    return value
        .map((item) => '$item')
        .where((item) => item.isNotEmpty)
        .toList();
  }

  List<ImReaction> _parseReactions(
    Object? value, {
    Iterable<String> myReactionIds = const <String>[],
  }) {
    if (value is! List) return const <ImReaction>[];
    final mine = myReactionIds.toSet();
    return value
        .whereType<Map>()
        .map((raw) {
          final json = Map<String, dynamic>.from(raw);
          return ImReaction(
            emojiId: '${json['emoji_id'] ?? ''}',
            count: (json['count'] as num?)?.toInt() ?? 0,
            reactedByMe: mine.contains('${json['emoji_id'] ?? ''}'),
          );
        })
        .where((reaction) => reaction.emojiId.isNotEmpty && reaction.count > 0)
        .toList(growable: false);
  }

  String _segmentDisplayText(Map<String, dynamic> segment) {
    final data =
        segment['data'] is Map
            ? Map<String, dynamic>.from(segment['data'] as Map)
            : const <String, dynamic>{};
    return switch (segment['type']) {
      'text' => '${data['text'] ?? ''}',
      'image' => '[图片]',
      'record' => '[语音]',
      'video' => '${data['name'] ?? '[视频]'}',
      'file' => '${data['name'] ?? '[文件]'}',
      'at' => '@${data['qq'] ?? ''}',
      'reply' => '',
      final type => '[${type ?? 'unknown'}]',
    };
  }

  ImMessageKind _kindForSegment(String? type) => switch (type) {
    'image' => ImMessageKind.image,
    'record' => ImMessageKind.record,
    'video' => ImMessageKind.video,
    'file' => ImMessageKind.file,
    'forward' => ImMessageKind.forward,
    'json' => ImMessageKind.json,
    _ => ImMessageKind.text,
  };

  ImMessageStatus _statusFromJson(Object? value) => switch ('$value') {
    'sending' => ImMessageStatus.sending,
    'delivered' => ImMessageStatus.delivered,
    'read' => ImMessageStatus.read,
    'failed' => ImMessageStatus.failed,
    _ => ImMessageStatus.sent,
  };

  void _addMessageToStream(ImMessage message) {
    final messages = _messages.putIfAbsent(message.conversationId, () => []);
    if (messages.any((existing) => existing.id == message.id)) return;
    messages.add(message);
    messages.sort((a, b) => a.sentAt.compareTo(b.sentAt));
    _emitMessages(message.conversationId);

    final conversation = _conversations[message.conversationId];
    if (conversation != null) {
      final sender = _users[message.senderId];
      final refreshPeer = conversation.isDirect && !message.isMine;
      _conversations[message.conversationId] = conversation.copyWith(
        title: refreshPeer ? sender?.displayName : null,
        avatarAssetPath: refreshPeer ? sender?.avatarAssetPath : null,
        subtitle: message.text,
        updatedAt: message.sentAt,
        unreadCount:
            message.isMine
                ? conversation.unreadCount
                : conversation.unreadCount + 1,
      );
    } else {
      final isGroup = message.conversationId.startsWith('group_');
      _conversations[message.conversationId] = ImConversation(
        id: message.conversationId,
        type: isGroup ? ImConversationType.group : ImConversationType.direct,
        title: _users[message.senderId]?.displayName ?? message.conversationId,
        participantIds: [_selfId, message.senderId],
        subtitle: message.text,
        updatedAt: message.sentAt,
        unreadCount: message.isMine ? 0 : 1,
      );
    }
    _emitConversations();
  }

  Future<ImMessage> _sendMessage(
    String conversationId,
    List<Map<String, dynamic>> segments,
  ) async {
    final conversation = _conversations[conversationId];
    if (conversation != null) await _ensureRemoteConversation(conversation);
    final response = await _request('send_message', {
      'conversation_id': conversationId,
      'message': segments,
    });
    _requireOk(response, 'Send message');
    final responseData = response['data'] as Map?;
    final first = segments.firstWhere(
      (segment) => segment['type'] != 'reply',
      orElse: () => segments.first,
    );
    final reply = _firstSegmentWhere(segments, (segment) {
      return segment['type'] == 'reply';
    });
    final firstData = first['data'] as Map?;
    final mediaUrl = firstData?['url'] as String?;
    final message = ImMessage(
      id: '${responseData?['message_id']}',
      conversationId: conversationId,
      senderId: _selfId,
      text: segments.map(_segmentDisplayText).join().trim(),
      sentAt: DateTime.now(),
      kind: _kindForSegment(first['type'] as String?),
      status: ImMessageStatus.sent,
      recipientCount:
          conversation?.participantIds
              .where((participantId) => participantId != _selfId)
              .length ??
          0,
      isMine: true,
      segments: oneBotChainFromJson(segments),
      replyToMessageId: _replyMessageId(reply),
      mediaPath: _resolveMediaUrl(mediaUrl),
      mediaUrl: mediaUrl,
      mediaSize: (firstData?['size'] as num?)?.toInt(),
      mediaMime: firstData?['mime_type'] as String?,
    );
    _addMessageToStream(message);
    return message;
  }

  Map<String, dynamic>? _firstSegmentWhere(
    List<Map<String, dynamic>> segments,
    bool Function(Map<String, dynamic> segment) predicate,
  ) {
    for (final segment in segments) {
      if (predicate(segment)) return segment;
    }
    return null;
  }

  String? _replyMessageId(Map<String, dynamic>? reply) {
    final data = reply?['data'];
    if (data is! Map) return null;
    final id = '${data['id'] ?? ''}'.trim();
    return id.isEmpty ? null : id;
  }

  Future<void> _ensureRemoteConversation(ImConversation conversation) async {
    final response = await _request('ensure_conversation', {
      'conversation_id': conversation.id,
      'type': conversation.isGroup ? 'group' : 'private',
      'title': conversation.title,
      'avatar_url': conversation.avatarLocalPath,
      'participants': conversation.participantIds,
    });
    _requireOk(response, 'Save conversation');
  }

  Future<Map<String, dynamic>> _request(
    String action,
    Map<String, dynamic> params, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    if (_channel == null) throw StateError('ZZZ Server is not connected');
    final echo = 'req_${++_echoCounter}';
    final completer = Completer<Map<String, dynamic>>();
    _echoCompleters[echo] = completer;
    _sendAction(action, params, echo: echo);
    try {
      return await completer.future.timeout(timeout);
    } finally {
      _echoCompleters.remove(echo);
    }
  }

  void _requireOk(Map<String, dynamic> response, String operation) {
    if (response['status'] == 'ok') return;
    throw StateError(
      '$operation failed: ${response['msg'] ?? 'unknown error'}',
    );
  }

  void _sendAction(String action, Map<String, dynamic> params, {String? echo}) {
    final channel = _channel;
    if (channel == null) throw StateError('ZZZ Server is not connected');
    final request = <String, dynamic>{'action': action, 'params': params};
    if (echo != null) request['echo'] = echo;
    channel.sink.add(jsonEncode(request));
  }

  Future<void> _authenticate() async {
    final response = await _request('auth', {
      'token': config.authToken,
      'session_token': config.authToken,
      'user_id': config.selfId,
    });
    if (response['status'] != 'ok' && _onAuthenticationFailed != null) {
      unawaited(_onAuthenticationFailed());
    }
    _requireOk(response, 'Authentication');
    final data = response['data'];
    if (data is! Map) return;
    final json = Map<String, dynamic>.from(data);
    _selfId = '${json['user_id'] ?? config.selfId}';
    _users[_selfId] = ImUser(
      id: _selfId,
      displayName: _resolveDisplayName(_selfId, json['nickname'] as String?),
      isOnline: true,
      avatarAssetPath: _resolveAvatar(_selfId, json['avatar_url'] as String?),
    );
  }

  ImUser _userFromJson(
    Map<String, dynamic> json, {
    required String fallbackId,
  }) {
    final id = '${json['user_id'] ?? json['id'] ?? fallbackId}';
    return ImUser(
      id: id,
      displayName: _resolveDisplayName(id, json['nickname'] as String?),
      avatarAssetPath: _preserveAvatarRevision(
        _users[id]?.avatarAssetPath,
        _resolveAvatar(id, json['avatar_url'] as String?),
      ),
      isOnline: json['online'] as bool? ?? true,
      relationship: imRelationshipFromString(json['relationship'] as String?),
    );
  }

  /// Registers an account without opening an authenticated long-lived source.
  static Future<ZzzAccountResult> registerAccount({
    required String serverUrl,
    required String userId,
    required String password,
    required String inviteCode,
    String? nickname,
    ImMediaUpload? avatar,
    String? avatarAssetPath,
  }) async {
    final params = <String, dynamic>{
      'user_id': userId,
      'password': password,
      'invite_code': inviteCode.trim(),
      if (nickname != null && nickname.trim().isNotEmpty)
        'nickname': nickname.trim(),
      if (avatarAssetPath != null && avatarAssetPath.isNotEmpty)
        'avatar_url': avatarAssetPath,
    };
    if (avatar != null && avatarAssetPath == null) {
      final bytes = await readUploadBytes(avatar);
      if (bytes.length > 5 * 1024 * 1024) {
        throw StateError('Avatars must be 5 MB or smaller.');
      }
      params.addAll({
        'avatar_file': base64Encode(bytes),
        'avatar_file_name': avatar.fileName,
        'avatar_mime_type': avatar.mimeType ?? 'application/octet-stream',
      });
    }
    final response = await _accountRequest(
      serverUrl,
      'register',
      params,
      timeout:
          avatar == null
              ? const Duration(seconds: 12)
              : const Duration(seconds: 30),
    );
    return _accountResult(response);
  }

  /// Logs in with username/password and returns a session token suitable for
  /// [ZzzServerConfig.authToken].
  static Future<ZzzAccountResult> loginAccount({
    required String serverUrl,
    required String userId,
    required String password,
  }) async {
    final response = await _accountRequest(serverUrl, 'auth', {
      'user_id': userId,
      'password': password,
      'device_id': 'pwa-${DateTime.now().millisecondsSinceEpoch}',
    });
    return _accountResult(response);
  }

  /// Revokes a persisted account session. Local sign-out still proceeds when
  /// the server is temporarily unreachable.
  static Future<void> logoutAccount({
    required String serverUrl,
    required String sessionToken,
  }) async {
    if (sessionToken.isEmpty) return;
    await _accountRequest(serverUrl, 'logout', {'session_token': sessionToken});
  }

  static Future<Map<String, dynamic>> _accountRequest(
    String serverUrl,
    String action,
    Map<String, dynamic> params, {
    Duration timeout = const Duration(seconds: 12),
  }) async {
    final channel = WebSocketChannel.connect(Uri.parse(serverUrl));
    final echo = 'account_${DateTime.now().microsecondsSinceEpoch}';
    try {
      await channel.ready.timeout(const Duration(seconds: 10));
      channel.sink.add(
        jsonEncode({'action': action, 'params': params, 'echo': echo}),
      );
      await for (final raw in channel.stream.timeout(timeout)) {
        final decoded = jsonDecode(raw as String);
        if (decoded is! Map || decoded['echo'] != echo) continue;
        final response = Map<String, dynamic>.from(decoded);
        if (response['status'] != 'ok') {
          throw StateError('${response['msg'] ?? 'Request failed'}');
        }
        return response;
      }
      throw StateError('Server closed the connection.');
    } finally {
      await channel.sink.close();
    }
  }

  static ZzzAccountResult _accountResult(Map<String, dynamic> response) {
    final data = Map<String, dynamic>.from(
      response['data'] as Map? ?? const {},
    );
    final token = '${data['session_token'] ?? ''}';
    if (token.isEmpty) {
      throw StateError('Server did not return a session token.');
    }
    return ZzzAccountResult(
      userId: '${data['user_id'] ?? ''}',
      nickname: '${data['nickname'] ?? data['user_id'] ?? ''}',
      avatarUrl: '${data['avatar_url'] ?? ''}',
      sessionToken: token,
    );
  }

  String? _segmentType(ImMessageKind kind) => switch (kind) {
    ImMessageKind.image => 'image',
    ImMessageKind.record => 'record',
    ImMessageKind.video => 'video',
    ImMessageKind.file => 'file',
    _ => null,
  };

  String? _resolveMediaUrl(String? value) {
    if (value == null || value.isEmpty) return null;
    if (value.startsWith('assets/')) return value;
    final parsed = Uri.tryParse(value);
    if (parsed != null && parsed.hasScheme) return parsed.toString();
    final server = Uri.parse(config.serverUrl);
    final scheme = server.scheme == 'wss' ? 'https' : 'http';
    return server.replace(scheme: scheme, path: value, query: null).toString();
  }

  String? _resolveAvatar(String userId, String? value) {
    return _resolveMediaUrl(value) ?? _avatarResolver?.call(userId);
  }

  String? _preserveAvatarRevision(String? previous, String? next) {
    if (previous == null || next == null) return next;
    final previousUri = Uri.tryParse(previous);
    final nextUri = Uri.tryParse(next);
    if (previousUri == null || nextUri == null) return next;
    if (!previousUri.queryParameters.containsKey('profile_v')) return next;
    final previousQuery = {
      for (final entry in previousUri.queryParameters.entries)
        if (entry.key != 'profile_v') entry.key: entry.value,
    };
    final sameResource =
        previousUri.scheme == nextUri.scheme &&
        previousUri.userInfo == nextUri.userInfo &&
        previousUri.host == nextUri.host &&
        previousUri.port == nextUri.port &&
        previousUri.path == nextUri.path &&
        previousUri.fragment == nextUri.fragment &&
        previousQuery.length == nextUri.queryParameters.length &&
        previousQuery.entries.every(
          (entry) => nextUri.queryParameters[entry.key] == entry.value,
        );
    return sameResource ? previous : next;
  }

  String _resolveDisplayName(String userId, String? nickname) {
    final resolved = _displayNameResolver?.call(userId, nickname);
    if (resolved != null && resolved.trim().isNotEmpty) return resolved.trim();
    final supplied = nickname?.trim() ?? '';
    return supplied.isEmpty ? userId : supplied;
  }

  String? _resolveConversationAvatar({
    required String id,
    required bool isGroup,
    required List<String> participantIds,
    required String? value,
  }) {
    final remote = _resolveMediaUrl(value);
    if (remote != null) return remote;
    if (isGroup) return _avatarResolver?.call(id);
    String? otherUserId;
    for (final participantId in participantIds) {
      if (participantId != _selfId) {
        otherUserId = participantId;
        break;
      }
    }
    return _avatarResolver?.call(otherUserId ?? id);
  }

  void _setStatus(ConnectionStatus status) {
    _status = status;
    if (!_statusController.isClosed) _statusController.add(status);
  }

  List<ImConversation> _sortedConversations() {
    final sorted =
        _conversations.values.toList()..sort((a, b) {
          if (a.isPinned != b.isPinned) return a.isPinned ? -1 : 1;
          return (b.updatedAt ?? DateTime(0)).compareTo(
            a.updatedAt ?? DateTime(0),
          );
        });
    return List.unmodifiable(sorted);
  }

  void _emitConversations() {
    if (!_conversationsController.isClosed) {
      _conversationsController.add(_sortedConversations());
    }
  }

  List<ImUser> _visibleUsers() => _friendIds
      .map((id) => _users[id])
      .whereType<ImUser>()
      .toList(growable: false);

  void _emitUsers() {
    if (!_usersController.isClosed) {
      _usersController.add(List.unmodifiable(_visibleUsers()));
    }
  }

  void _emitFriendRequests() {
    if (_friendRequestsController.isClosed) return;
    _friendRequestsController.add(List.unmodifiable(_friendRequests));
  }

  void _emitMessages(String conversationId) {
    final controller = _messageControllers[conversationId];
    if (controller != null && !controller.isClosed) {
      controller.add(List.unmodifiable(_messages[conversationId] ?? const []));
    }
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(_heartbeatInterval, (_) {
      if (_channel != null && !_disposed) _sendAction('ping', const {});
    });
  }

  void _onDisconnected() {
    _heartbeatTimer?.cancel();
    _channel = null;
    _failPending(StateError('ZZZ Server disconnected'));
    if (_disposed || _manualDisconnect) return;
    _markFriendsOffline();
    _setStatus(ConnectionStatus.disconnected);
    _scheduleReconnect();
  }

  void _onError(Object error, StackTrace stackTrace) {
    _heartbeatTimer?.cancel();
    _channel = null;
    _failPending(error);
    if (_disposed || _manualDisconnect) return;
    _markFriendsOffline();
    _setStatus(ConnectionStatus.failed);
    _scheduleReconnect();
  }

  Future<void> _closeChannel() async {
    final subscription = _channelSubscription;
    final channel = _channel;
    _channelSubscription = null;
    _channel = null;
    await subscription?.cancel();
    await channel?.sink.close();
  }

  void _failPending(Object error) {
    for (final completer in _echoCompleters.values) {
      if (!completer.isCompleted) completer.completeError(error);
    }
    _echoCompleters.clear();
  }

  void _markFriendsOffline() {
    for (final userID in _friendIds) {
      final user = _users[userID];
      if (user != null && user.isOnline) {
        _users[userID] = user.copyWith(isOnline: false);
      }
    }
    _emitUsers();
  }

  void _scheduleReconnect() {
    if (!_allowReconnect || _disposed || _manualDisconnect) return;
    if (_reconnectAttempts >= _maxReconnectAttempts) return;
    _reconnectTimer?.cancel();
    final seconds = (1 << _reconnectAttempts).clamp(1, 60);
    _reconnectAttempts++;
    _reconnectTimer = Timer(Duration(seconds: seconds), () {
      connect().catchError((_) {});
    });
  }
}
