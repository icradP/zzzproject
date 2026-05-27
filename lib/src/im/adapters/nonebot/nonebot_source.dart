import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../../assets/app_assets.dart';
import '../../models/im_models.dart';
import '../im_message_source.dart';
import 'nonebot_mapper.dart';
import 'nonebot_models.dart';

/// An [ImMessageSource] backed by the OneBot protocol.
///
/// Two modes:
/// - **Mock mode** (default via [NoneBotSource.mock]): fills sample ZZZ-themed
///   data using OneBot event structures, so no real server is needed.
/// - **Connected mode** (via [NoneBotSource.connected]): wires a real
///   NoneBot / OneBot server using the provided [OneBotConnectionConfig].
class NoneBotSource implements ImMessageSource {
  NoneBotSource._({required this.config, required bool mock})
    : _mock = mock {
    _selfId = config.selfId;
    _users[_selfId] = ImUser(
      id: _selfId,
      displayName: config.selfId.isNotEmpty ? 'Bot (${config.selfId})' : 'Proxy',
      avatarAssetPath: AppAssets.characterWise,
      isOnline: true,
    );
    if (_mock) _seedMockData();
  }

  /// Creates a source pre-filled with sample data for development.
  factory NoneBotSource.mock() {
    return NoneBotSource._(
      config: const OneBotConnectionConfig(selfId: 'me'),
      mock: true,
    );
  }

  /// Creates a source that connects to a real NoneBot / OneBot server.
  factory NoneBotSource.connected({required OneBotConnectionConfig config}) {
    return NoneBotSource._(config: config, mock: false);
  }

  final OneBotConnectionConfig config;
  final bool _mock;

  late String _selfId;
  WebSocket? _ws;
  HttpServer? _wsServer;
  StreamSubscription? _wsSubscription;
  StreamSubscription? _wsServerSubscription;

  final _users = <String, ImUser>{};
  final _conversations = <String, ImConversation>{};
  final _messages = <String, List<ImMessage>>{};
  final _conversationControllers =
      <String, StreamController<List<ImConversation>>>{};
  final _messageControllers = <String, StreamController<List<ImMessage>>>{};
  final _statusController = StreamController<ConnectionStatus>.broadcast();

  @override
  String get platformName => 'NoneBot / OneBot';

  @override
  Stream<ConnectionStatus> get connectionStatus => _statusController.stream;

  // -----------------------------------------------------------------
  // Lifecycle
  // -----------------------------------------------------------------

  @override
  Future<void> connect() async {
    if (_mock) {
      _statusController.add(ConnectionStatus.connected);
      return;
    }

    final wsUrl = config.wsEndpoint;
    if (wsUrl == null || wsUrl.isEmpty) {
      _statusController.add(ConnectionStatus.failed);
      return;
    }

    _statusController.add(ConnectionStatus.connecting);
    try {
      if (config.wsMode == OneBotWsMode.reverse) {
        await _startReverseWs(wsUrl);
      } else {
        await _startForwardWs(wsUrl);
      }
      _statusController.add(ConnectionStatus.connected);
    } catch (e) {
      _statusController.add(ConnectionStatus.failed);
      rethrow;
    }
  }

  Future<void> _startForwardWs(String wsUrl) async {
    final headers = <String, dynamic>{};
    if (config.accessToken != null && config.accessToken!.isNotEmpty) {
      headers['Authorization'] = 'Bearer ${config.accessToken}';
    }

    _ws = await WebSocket.connect(wsUrl, headers: headers.isNotEmpty ? headers : null);
    _wsSubscription = _ws!.listen(
      (data) {
        if (data is String) {
          try {
            final json = jsonDecode(data) as Map<String, dynamic>;
            ingestEvent(json);
          } catch (_) {}
        }
      },
      onError: (_) {
        _statusController.add(ConnectionStatus.failed);
      },
      onDone: () {
        _statusController.add(ConnectionStatus.disconnected);
      },
    );
  }

  Future<void> _startReverseWs(String listenUrl) async {
    final uri = Uri.parse(listenUrl);
    final host = uri.host.isNotEmpty ? uri.host : '127.0.0.1';
    final port = uri.port != 0 ? uri.port : 6199;
    final path = uri.path.isNotEmpty ? uri.path : '/ws';

    _wsServer = await HttpServer.bind(InternetAddress(host), port);
    _wsServerSubscription = _wsServer!.listen((request) async {
      if (request.uri.path != path) {
        request.response
          ..statusCode = HttpStatus.notFound
          ..close();
        return;
      }

      final token = config.accessToken;
      if (token != null && token.isNotEmpty) {
        final auth = request.headers.value('Authorization');
        if (auth != 'Bearer $token') {
          request.response
            ..statusCode = HttpStatus.unauthorized
            ..close();
          return;
        }
      }

      final socket = await WebSocketTransformer.upgrade(request);
      socket.listen(
        (data) {
          if (data is String) {
            try {
              final json = jsonDecode(data) as Map<String, dynamic>;
              ingestEvent(json);
            } catch (_) {}
          }
        },
        onError: (_) {},
        onDone: () {},
      );
    });
  }

  @override
  void disconnect() {
    _wsSubscription?.cancel();
    _ws?.close();
    _wsServerSubscription?.cancel();
    _wsServer?.close();

    _statusController.add(ConnectionStatus.disconnected);

    for (final c in _conversationControllers.values) {
      c.close();
    }
    for (final c in _messageControllers.values) {
      c.close();
    }
  }

  @override
  Future<String?> testConnection() async {
    if (_mock) return null;

    final wsUrl = config.wsEndpoint;
    if (wsUrl == null || wsUrl.isEmpty) {
      return 'No WebSocket endpoint configured';
    }

    try {
      if (config.wsMode == OneBotWsMode.reverse) {
        final uri = Uri.parse(wsUrl);
        final port = uri.port != 0 ? uri.port : 6199;
        final host = uri.host.isNotEmpty ? uri.host : '127.0.0.1';
        // For reverse mode, just check if the port is available to bind
        final server = await HttpServer.bind(InternetAddress(host), port);
        await server.close();
        return null;
      } else {
        final headers = <String, dynamic>{};
        if (config.accessToken != null && config.accessToken!.isNotEmpty) {
          headers['Authorization'] = 'Bearer ${config.accessToken}';
        }
        final ws = await WebSocket.connect(
          wsUrl,
          headers: headers.isNotEmpty ? headers : null,
        ).timeout(const Duration(seconds: 5));
        await ws.close();
        return null;
      }
    } on TimeoutException {
      return 'Connection timed out after 5s';
    } on SocketException catch (e) {
      return 'Socket error: ${e.message}';
    } on HandshakeException catch (e) {
      return 'Handshake failed: ${e.message}';
    } catch (e) {
      return 'Connection failed: $e';
    }
  }

  // -----------------------------------------------------------------
  // ImMessageSource
  // -----------------------------------------------------------------

  @override
  Future<ImUser> getCurrentUser() async => _users[_selfId]!;

  @override
  Future<ImUser?> getUser(String userId) async => _users[userId];

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
      senderId: _selfId,
      text: trimmed,
      sentAt: DateTime.now(),
      isMine: true,
      status: ImMessageStatus.sent,
    );

    final list = _messages.putIfAbsent(conversationId, () => []);
    list.add(message);
    _emitMessages(conversationId);

    final conv = _conversations[conversationId];
    if (conv != null) {
      _conversations[conversationId] = conv.copyWith(
        subtitle: trimmed,
        updatedAt: message.sentAt,
        unreadCount: 0,
      );
      _emitConversations();
    }

    return message;
  }

  @override
  Future<void> markConversationRead(String conversationId) async {
    final conv = _conversations[conversationId];
    if (conv == null || conv.unreadCount == 0) return;
    _conversations[conversationId] = conv.copyWith(unreadCount: 0);
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

  // -----------------------------------------------------------------
  // Event ingestion (for connected mode)
  // -----------------------------------------------------------------

  /// Feed a raw OneBot event into the source so it updates internal state.
  /// Call this from your WebSocket / HTTP listener in connected mode.
  void ingestEvent(Map<String, dynamic> raw) {
    final postType = raw['post_type'] as String?;
    switch (postType) {
      case 'message':
        _ingestMessageEvent(raw);
      case 'notice':
        // notices can be handled here (e.g. friend-add → new conversation)
        break;
    }
  }

  void _ingestMessageEvent(Map<String, dynamic> raw) {
    final messageType = raw['message_type'] as String?;

    if (messageType == 'private') {
      final event = OneBotPrivateMessageEvent.fromJson(raw);
      final convId = oneBotConversationId(
        selfId: _selfId,
        userId: event.userId,
      );
      final imUser = oneBotSenderToImUser(event.sender);
      _users[imUser.id] = imUser;

      final msg = oneBotPrivateMessageToImMessage(
        event: event,
        conversationId: convId,
        selfId: _selfId,
      );

      _conversations.putIfAbsent(
        convId,
        () => oneBotPrivateEventToConversation(
          event: event,
          conversationId: convId,
          selfId: _selfId,
          peer: imUser,
          subtitle: msg.text,
          updatedAt: msg.sentAt,
        ),
      );

      _messages.putIfAbsent(convId, () => []).add(msg);
      _emitMessages(convId);
      _emitConversations();
    } else if (messageType == 'group') {
      final event = OneBotGroupMessageEvent.fromJson(raw);
      final convId = oneBotConversationId(
        selfId: _selfId,
        groupId: event.groupId,
      );
      final imUser = oneBotSenderToImUser(event.sender);
      _users[imUser.id] = imUser;

      final msg = oneBotGroupMessageToImMessage(
        event: event,
        conversationId: convId,
        selfId: _selfId,
      );

      final existing = _conversations[convId];
      if (existing != null) {
        _conversations[convId] = existing.copyWith(
          subtitle: '${imUser.displayName}: ${msg.text}',
          updatedAt: msg.sentAt,
          unreadCount: existing.unreadCount + 1,
        );
      } else {
        _conversations[convId] = oneBotGroupEventToConversation(
          event: event,
          conversationId: convId,
          selfId: _selfId,
          title: 'Group ${event.groupId}',
          participantIds: [_selfId],
          subtitle: '${imUser.displayName}: ${msg.text}',
          updatedAt: msg.sentAt,
        );
      }

      _messages.putIfAbsent(convId, () => []).add(msg);
      _emitMessages(convId);
      _emitConversations();
    }
  }

  // -----------------------------------------------------------------
  // Internal helpers
  // -----------------------------------------------------------------

  void _emitConversations() {
    final sorted = _conversations.values.toList()
      ..sort((a, b) {
        if (a.isPinned != b.isPinned) return a.isPinned ? -1 : 1;
        final at = a.updatedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        final bt = b.updatedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        return bt.compareTo(at);
      });
    final c = _conversationControllers['all'];
    if (c != null && !c.isClosed) c.add(sorted);
  }

  void _emitMessages(String conversationId) {
    final c = _messageControllers[conversationId];
    if (c != null && !c.isClosed) {
      c.add(List.unmodifiable(_messages[conversationId] ?? const []));
    }
  }

  // -----------------------------------------------------------------
  // Mock data
  // -----------------------------------------------------------------

  void _seedMockData() {
    _users.addAll({
      _selfId: ImUser(
        id: _selfId,
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
        id: 'dm_belle',
        type: ImConversationType.direct,
        title: 'Belle',
        participantIds: [_selfId, 'belle'],
        avatarAssetPath: AppAssets.characterBelle,
        subtitle: 'See you at Sixth Street!',
        updatedAt: now.subtract(const Duration(minutes: 3)),
        unreadCount: 2,
        isPinned: true,
      ),
    );
    _putConversation(
      ImConversation(
        id: 'dm_wise',
        type: ImConversationType.direct,
        title: 'Wise',
        participantIds: [_selfId, 'wise'],
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
        participantIds: [_selfId, 'nicole', 'anby', 'belle'],
        avatarAssetPath: AppAssets.character('NicoleDemara.png'),
        subtitle: 'Nicole: Pay up, buddy.',
        updatedAt: now.subtract(const Duration(hours: 5)),
        unreadCount: 5,
      ),
    );
    _putConversation(
      ImConversation(
        id: 'dm_nicole',
        type: ImConversationType.direct,
        title: 'Nicole Demara',
        participantIds: [_selfId, 'nicole'],
        avatarAssetPath: AppAssets.character('NicoleDemara.png'),
        subtitle: 'Interest is compounding.',
        updatedAt: now.subtract(const Duration(days: 1)),
      ),
    );
    _putConversation(
      ImConversation(
        id: 'sys_fairy',
        type: ImConversationType.direct,
        title: 'Fairy · System',
        participantIds: [_selfId, 'fairy'],
        avatarAssetPath: AppAssets.character('temp/Fairy.png'),
        subtitle: 'Power inspection scheduled.',
        updatedAt: now.subtract(const Duration(days: 2)),
      ),
    );

    _putMessages('dm_belle', [
      _mockMsg('m1', 'dm_belle', 'belle', 'Proxy, are you still at the video store?',
          now.subtract(const Duration(minutes: 18))),
      _mockMsg('m2', 'dm_belle', _selfId, 'Yeah, sorting the new Hollow Observer tapes.',
          now.subtract(const Duration(minutes: 12))),
      _mockMsg('m3', 'dm_belle', 'belle', 'See you at Sixth Street!',
          now.subtract(const Duration(minutes: 3))),
    ]);
    _putMessages('dm_wise', [
      _mockMsg('w1', 'dm_wise', 'wise', "Don't forget the commission.",
          now.subtract(const Duration(hours: 1))),
    ]);
    _putMessages('group_cunning_hares', [
      _mockMsg('g1', 'group_cunning_hares', 'anby', 'I brought snacks.',
          now.subtract(const Duration(hours: 6))),
      _mockMsg('g2', 'group_cunning_hares', 'nicole', 'Pay up, buddy.',
          now.subtract(const Duration(hours: 5))),
      _mockMsg('g3', 'group_cunning_hares', _selfId, 'Invoice sent.',
          now.subtract(const Duration(hours: 4, minutes: 50))),
    ]);
    _putMessages('dm_nicole', [
      _mockMsg('n1', 'dm_nicole', 'nicole', 'Interest is compounding.',
          now.subtract(const Duration(days: 1))),
    ]);
    _putMessages('sys_fairy', [
      ImMessage(
        id: 'f1',
        conversationId: 'sys_fairy',
        senderId: 'fairy',
        text: 'Power inspection scheduled.',
        sentAt: now.subtract(const Duration(days: 2)),
        kind: ImMessageKind.system,
      ),
    ]);
  }

  ImMessage _mockMsg(String id, String convId, String senderId, String text, DateTime sentAt) {
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
