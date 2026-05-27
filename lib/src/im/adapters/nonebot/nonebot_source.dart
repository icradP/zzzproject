import 'dart:async';
import 'dart:io';

import 'package:onebot_flutter/onebot_flutter.dart' show OneBotClient, OneBotException;

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
class NoneBotSource implements ImMessageSource {
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

  late String _selfId;
  OneBotClient? _client;
  StreamSubscription? _eventSubscription;

  final _users = <String, ImUser>{};
  final _conversations = <String, ImConversation>{};
  final _messages = <String, List<ImMessage>>{};
  final _conversationControllers =
      <String, StreamController<List<ImConversation>>>{};
  final _messageControllers = <String, StreamController<List<ImMessage>>>{};
  final _statusController = StreamController<ConnectionStatus>.broadcast();

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
      _client = OneBotClient(config: config);
      await _client!.connect();

      _eventSubscription = _client!.eventStream.listen((event) {
        if (event is OneBotMessageEvent) {
          if (event.isPrivate && event.event != null) {
            _ingestPrivateEvent(event.event!);
          } else if (event.isGroup) {
            _ingestGroupEvent(event.groupEvent!);
          }
        }
      });

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
  // Event ingestion (connected mode)
  // -----------------------------------------------------------------

  void _ingestPrivateEvent(OneBotPrivateMessageEvent event) {
    final convId = oneBotConversationId(selfId: _selfId, userId: event.userId);
    final imUser = oneBotSenderToImUser(event.sender, avatarResolver: _avatarResolver);
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
        avatarAssetPath: _avatarResolver(event.userId),
      ),
    );

    _messages.putIfAbsent(convId, () => []).add(msg);
    _emitMessages(convId);
    _emitConversations();
  }

  void _ingestGroupEvent(OneBotGroupMessageEvent event) {
    final convId = oneBotConversationId(selfId: _selfId, groupId: event.groupId);
    final imUser = oneBotSenderToImUser(event.sender, avatarResolver: _avatarResolver);
    _users[imUser.id] = imUser;

    final msg = oneBotGroupMessageToImMessage(
      event: event,
      conversationId: convId,
      selfId: _selfId,
    );

    final existing = _conversations[convId];
    if (existing != null) {
      _conversations[convId] = existing.copyWith(
        subtitle: '$imUser.displayName: ${msg.text}',
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
        subtitle: '$imUser.displayName: ${msg.text}',
        updatedAt: msg.sentAt,
      );
    }

    _messages.putIfAbsent(convId, () => []).add(msg);
    _emitMessages(convId);
    _emitConversations();
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
        id: 'dm_belle',
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
        id: 'dm_wise',
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
        id: 'dm_nicole',
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
        id: 'sys_fairy',
        type: ImConversationType.direct,
        title: 'Fairy · System',
        participantIds: [_selfId, 'fairy'],
        avatarAssetPath: _avatarResolver('fairy'),
        subtitle: 'Power inspection scheduled.',
        updatedAt: now.subtract(const Duration(days: 2)),
      ),
    );

    _putMessages('dm_belle', [
      _mockMsg('m1', 'dm_belle', 'belle',
          'Proxy, are you still at the video store?',
          now.subtract(const Duration(minutes: 18))),
      _mockMsg('m2', 'dm_belle', _selfId,
          'Yeah, sorting the new Hollow Observer tapes.',
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
