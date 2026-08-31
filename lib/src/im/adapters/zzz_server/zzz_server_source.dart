import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

import '../../models/im_models.dart';
import '../im_message_source.dart';
import 'im_upload_bytes.dart';

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
    Future<void> Function()? onAuthenticationFailed,
  }) : _onAuthenticationFailed = onAuthenticationFailed,
       _allowReconnect = allowReconnect,
       _selfId = config.selfId;

  final ZzzServerConfig config;
  final bool _allowReconnect;
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
  final _echoCompleters = <String, Completer<Map<String, dynamic>>>{};
  int _echoCounter = 0;
  ConnectionStatus _status = ConnectionStatus.disconnected;

  @override
  String get platformName => 'ZZZ Server';

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
    final probe = ZzzServerSource(config: config, allowReconnect: false);
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
      ImUser(id: _selfId, displayName: _selfId, isOnline: true);

  @override
  Future<ImUser?> getUser(String userId) async => _users[userId];

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
  }) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError.value(text, 'text', 'Message cannot be empty.');
    }
    return _sendMessage(conversationId, [
      {
        'type': 'text',
        'data': {'text': trimmed},
      },
    ]);
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
    if (conversation != null && conversation.unreadCount != 0) {
      _conversations[conversationId] = conversation.copyWith(unreadCount: 0);
      _emitConversations();
    }
    if (_status == ConnectionStatus.connected) {
      await _request('mark_read', {'conversation_id': conversationId});
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
  Future<List<ImUser>> getUsers() async =>
      _users.values.where((user) => user.id != _selfId).toList(growable: false);

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
          avatarAssetPath: _resolveMediaUrl(json['avatar_url'] as String?),
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
  }) async {
    String? avatarUrl;
    if (avatar != null) {
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
    if (avatarUrl != null && avatarUrl.isNotEmpty) {
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
      avatarAssetPath: _resolveMediaUrl(data['avatar_url'] as String?),
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
    final response = await _request('get_users', const {});
    _requireOk(response, 'Load users');
    final data = response['data'];
    if (data is! List) return;
    for (final raw in data) {
      if (raw is! Map) continue;
      final json = Map<String, dynamic>.from(raw);
      final id = '${json['user_id'] ?? ''}';
      if (id.isEmpty) continue;
      _users[id] = ImUser(
        id: id,
        displayName: '${json['nickname'] ?? id}',
        isOnline: json['online'] as bool? ?? false,
        avatarAssetPath: _resolveMediaUrl(json['avatar_url'] as String?),
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
      avatarAssetPath: _resolveMediaUrl(json['avatar_url'] as String?),
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
      final first = segments.isEmpty ? null : segments.first;
      final data =
          first?['data'] is Map
              ? Map<String, dynamic>.from(first!['data'] as Map)
              : const <String, dynamic>{};

      _users[senderId] = ImUser(
        id: senderId,
        displayName: '${sender['nickname'] ?? senderId}',
        avatarAssetPath: _resolveMediaUrl(sender['avatar_url'] as String?),
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
        isMine: senderId == _selfId,
        mediaPath: _resolveMediaUrl(mediaUrl),
        mediaUrl: mediaUrl,
        mediaSize: (data['size'] as num?)?.toInt(),
        mediaMime: data['mime_type'] as String?,
        recalled: json['recalled'] as bool? ?? false,
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
    final firstData = segments.first['data'] as Map?;
    final mediaUrl = firstData?['url'] as String?;
    final message = ImMessage(
      id: '${responseData?['message_id']}',
      conversationId: conversationId,
      senderId: _selfId,
      text: segments.map(_segmentDisplayText).join().trim(),
      sentAt: DateTime.now(),
      kind: _kindForSegment(segments.first['type'] as String?),
      isMine: true,
      mediaPath: _resolveMediaUrl(mediaUrl),
      mediaUrl: mediaUrl,
      mediaSize: (firstData?['size'] as num?)?.toInt(),
      mediaMime: firstData?['mime_type'] as String?,
    );
    _addMessageToStream(message);
    return message;
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
      avatarAssetPath: _resolveMediaUrl(json['avatar_url'] as String?),
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
      avatarAssetPath: _resolveMediaUrl(json['avatar_url'] as String?),
      isOnline: json['online'] as bool? ?? true,
    );
  }

  /// Registers an account without opening an authenticated long-lived source.
  static Future<ZzzAccountResult> registerAccount({
    required String serverUrl,
    required String userId,
    required String password,
    String? nickname,
  }) async {
    final response = await _accountRequest(serverUrl, 'register', {
      'user_id': userId,
      'password': password,
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
    final parsed = Uri.tryParse(value);
    if (parsed != null && parsed.hasScheme) return parsed.toString();
    final server = Uri.parse(config.serverUrl);
    final scheme = server.scheme == 'wss' ? 'https' : 'http';
    return server.replace(scheme: scheme, path: value, query: null).toString();
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
