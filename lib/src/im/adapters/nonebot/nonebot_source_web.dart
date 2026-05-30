import 'dart:async';

import '../../models/im_models.dart';
import '../im_message_source.dart';
import 'nonebot_mapper.dart';
import 'nonebot_models_web.dart';

/// Web-safe stub for [NoneBotSource].
///
/// On web, the IM backend is a remote server — no local OneBot WebSocket
/// connection, no sqflite, no file caching.  This stub implements
/// [ImMessageSource] with no-op behaviour so that `zzz_app.dart` compiles
/// on web.  The app will always use [MockImRepository] on web (because
/// `ImConnectionConfig.isNoneBot` is `false`), so these methods are never
/// actually called at runtime.
class NoneBotSource implements ImMessageSource {
  NoneBotSource._({
    required this.config,
    required bool mock,
    AvatarResolver? avatarResolver,
  }) : _mock = mock,
      _avatarResolver = avatarResolver ?? _defaultAvatar;

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

  // ignore: unused_field
  final OneBotConfig config;
  // ignore: unused_field
  final bool _mock;
  // ignore: unused_field
  final AvatarResolver _avatarResolver;

  set storageConfig(dynamic v) {}
  set mediaCache(dynamic v) {}

  static String? _defaultAvatar(String userId) => null;

  // -----------------------------------------------------------------
  // ImMessageSource
  // -----------------------------------------------------------------

  @override
  String get platformName => 'NoneBot / OneBot (web stub)';

  final _statusController = StreamController<ConnectionStatus>.broadcast();

  @override
  Stream<ConnectionStatus> get connectionStatus => _statusController.stream;

  @override
  Future<void> connect() async {}

  @override
  void disconnect() {}

  @override
  Future<String?> testConnection() async => null;

  @override
  Future<ImUser> getCurrentUser() async => ImUser(
    id: 'me',
    displayName: 'Web Proxy',
    isOnline: true,
  );

  @override
  Future<ImUser?> getUser(String userId) async => null;

  @override
  Stream<List<ImConversation>> watchConversations() {
    return Stream.value(const []);
  }

  @override
  Stream<List<ImMessage>> watchMessages(String conversationId) {
    return Stream.value(const []);
  }

  @override
  Future<ImConversation?> getConversation(String conversationId) async => null;

  @override
  Future<ImMessage> sendTextMessage({
    required String conversationId,
    required String text,
  }) async {
    throw UnsupportedError('sendTextMessage is not available on web');
  }

  @override
  Future<void> markConversationRead(String conversationId) async {}

  @override
  Future<List<ImConversation>> searchConversations(String query) async => [];

  @override
  Future<List<ImUser>> getUsers() async => [];

  @override
  Future<List<ImConversation>> getGroupList() async => [];

  @override
  Future<void> deleteConversation(String conversationId) async {}

  @override
  Future<void> clearAvatarCache() async {}

  @override
  Future<void> ensureConversation(ImConversation conversation) async {}
}
