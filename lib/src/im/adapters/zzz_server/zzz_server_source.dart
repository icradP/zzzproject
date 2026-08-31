import 'dart:async';
import 'dart:convert';

import 'package:onebot_flutter/onebot_flutter.dart' show oneBotChainFromJson;
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../models/im_models.dart';
import '../../models/im_source_address.dart';
import '../im_message_source.dart';
import 'im_upload_bytes.dart';

typedef ZzzAvatarResolver = String? Function(String userId);

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
    Future<void> Function()? onAuthenticationFailed,
  }) : _onAuthenticationFailed = onAuthenticationFailed,
       _avatarResolver = avatarResolver,
       _allowReconnect = allowReconnect,
       _selfId = config.selfId;

  final ZzzServerConfig config;
  final bool _allowReconnect;
  final ZzzAvatarResolver? _avatarResolver;
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

  final _statusController = StreamController<ConnectionStatus>.broadcast();
  final _conversationsController =
      StreamController<List<ImConversation>>.broadcast();
  final _messageControllers = <String, StreamController<List<ImMessage>>>{};

  final _conversations = <String, ImConversation>{};
  final _messages = <String, List<ImMessage>>{};
  final _users = <String, ImUser>{};
  final _friendIds = <String>{};
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
    unawaited(_conversationsController.close());
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
        displayName: _selfId,
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
  Future<List<ImConversation>> searchConversations(String query) async {
    final normalized = query.trim().toLowerCase();
    if (normalized.isEmpty) return _sortedConversations();
    return _conversations.values.where((conversation) {
      return conversation.title.toLowerCase().contains(normalized) ||
          (conversation.subtitle ?? '').toLowerCase().contains(normalized);
    }).toList();
  }

  @override
  Future<List<ImUser>> getUsers() async => _friendIds
      .map((id) => _users[id])
      .whereType<ImUser>()
      .toList(growable: false);

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
    for (final raw in response['data'] as List? ?? const []) {
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
    return requests
        .where((request) => request.id.isNotEmpty)
        .toList(growable: false);
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
  }

  @override
  Future<void> removeFriend(String userId) async {
    final localId = ImSourceAddress.localIdOf(userId);
    final response = await _request('remove_friend', {'user_id': localId});
    _requireOk(response, 'Remove friend');
    _users.remove(localId);
    _friendIds.remove(localId);
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
        final conversation = ImConversation(
          id: id,
          type: ImConversationType.group,
          title: '${json['name'] ?? id}',
          participantIds: participants,
          avatarAssetPath: _resolveAvatar(id, json['avatar_url'] as String?),
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
        displayName: '${json['nickname'] ?? id}',
        isOnline: json['online'] as bool? ?? false,
        avatarAssetPath: _resolveAvatar(id, json['avatar_url'] as String?),
        relationship: imRelationshipFromString(json['relationship'] as String?),
      );
    }
  }

  Future<void> _syncMessages(String conversationId) async {
    final response = await _request('get_messages', {
      'conversation_id': conversationId,
      'limit': 100,
    });
    _requireOk(response, 'Load messages');
    final data = response['data'];
    if (data is! List) return;

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
    return ImConversation(
      id: id,
      type:
          json['type'] == 'group'
              ? ImConversationType.group
              : ImConversationType.direct,
      title: '${json['title'] ?? id}',
      participantIds: participants,
      subtitle: json['last_message'] as String?,
      avatarAssetPath: _resolveConversationAvatar(
        id: id,
        isGroup: json['type'] == 'group',
        participantIds: participants,
        value: json['avatar_url'] as String?,
      ),
      unreadCount: (json['unread_count'] as num?)?.toInt() ?? 0,
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
    }
  }

  void _handleNoticeEvent(Map<String, dynamic> json) {
    if (json['notice_type'] == 'message_read') {
      _handleMessageRead(json);
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

      _users[senderId] = ImUser(
        id: senderId,
        displayName: '${sender['nickname'] ?? senderId}',
        avatarAssetPath: _resolveAvatar(
          senderId,
          sender['avatar_url'] as String?,
        ),
        isOnline: true,
      );
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
        recalled: json['recalled'] as bool? ?? false,
        replyToMessageId: _replyMessageId(reply),
      );
    } catch (_) {
      return null;
    }
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
      _conversations[message.conversationId] = conversation.copyWith(
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
      displayName: '${json['nickname'] ?? _selfId}',
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
      displayName: '${json['nickname'] ?? id}',
      avatarAssetPath: _resolveAvatar(id, json['avatar_url'] as String?),
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
  }) async {
    final response = await _accountRequest(serverUrl, 'register', {
      'user_id': userId,
      'password': password,
      'invite_code': inviteCode.trim(),
      if (nickname != null && nickname.trim().isNotEmpty)
        'nickname': nickname.trim(),
    });
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
    Map<String, dynamic> params,
  ) async {
    final channel = WebSocketChannel.connect(Uri.parse(serverUrl));
    final echo = 'account_${DateTime.now().microsecondsSinceEpoch}';
    try {
      await channel.ready.timeout(const Duration(seconds: 10));
      channel.sink.add(
        jsonEncode({'action': action, 'params': params, 'echo': echo}),
      );
      await for (final raw in channel.stream.timeout(
        const Duration(seconds: 12),
      )) {
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
    _setStatus(ConnectionStatus.disconnected);
    _scheduleReconnect();
  }

  void _onError(Object error, StackTrace stackTrace) {
    _heartbeatTimer?.cancel();
    _channel = null;
    _failPending(error);
    if (_disposed || _manualDisconnect) return;
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
