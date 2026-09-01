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

  @override
  bool get supportsFriendManagement => false;

  set storageConfig(dynamic v) {}
  set mediaCache(dynamic v) {}

  // ignore: avoid_returning_null
  dynamic get client => null;

  static void Function(String, String, String)? onNewMessage;

  Future<String?> fetchUserAvatar(String userId) async => null;

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
  Future<ImUser> getCurrentUser() async =>
      ImUser(id: 'me', displayName: 'Web Proxy', isOnline: true);

  @override
  Future<ImUser?> getUser(String userId) async => null;

  @override
  Stream<List<ImUser>> watchUsers() => Stream.value(const []);

  @override
  Future<ImUser> updateProfile({
    String? nickname,
    ImMediaUpload? avatar,
    String? avatarAssetPath,
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
    throw UnsupportedError('Leave groups through the connected platform.');
  }

  @override
  Future<ImGroupDetails> getGroupDetails(String groupId) async {
    throw UnsupportedError('Group details are unavailable on the web stub.');
  }

  @override
  Future<void> inviteGroupMembers({
    required String groupId,
    required List<String> userIds,
  }) async {
    throw UnsupportedError(
      'Group invitations are unavailable on the web stub.',
    );
  }

  @override
  Future<void> removeGroupMember({
    required String groupId,
    required String userId,
  }) async {
    throw UnsupportedError(
      'Group member removal is unavailable on the web stub.',
    );
  }

  @override
  Future<void> updateGroup({
    required String groupId,
    String? name,
    ImMediaUpload? avatar,
    String? announcement,
  }) async {
    throw UnsupportedError('Group editing is unavailable on the web stub.');
  }

  @override
  Future<void> setGroupAdmin({
    required String groupId,
    required String userId,
    required bool enabled,
  }) async {
    throw UnsupportedError(
      'Group administrators are unavailable on the web stub.',
    );
  }

  @override
  Future<void> setGroupMemberMute({
    required String groupId,
    required String userId,
    required Duration duration,
  }) async {
    throw UnsupportedError('Group muting is unavailable on the web stub.');
  }

  @override
  Future<void> setGroupMuteAll({
    required String groupId,
    required bool enabled,
  }) async {
    throw UnsupportedError('Group muting is unavailable on the web stub.');
  }

  @override
  Future<void> transferGroupOwnership({
    required String groupId,
    required String userId,
  }) async {
    throw UnsupportedError(
      'Group ownership transfer is unavailable on the web stub.',
    );
  }

  @override
  Future<void> dismissGroup(String groupId) async {
    throw UnsupportedError('Group dismissal is unavailable on the web stub.');
  }

  @override
  Stream<List<ImConversation>> watchConversations() {
    return Stream.value(const []);
  }

  @override
  Stream<List<ImMessage>> watchMessages(String conversationId) {
    return Stream.value(const []);
  }

  @override
  Future<bool> loadOlderMessages(String conversationId) async => false;

  @override
  Future<ImConversation?> getConversation(String conversationId) async => null;

  @override
  Future<ImMessage> sendTextMessage({
    required String conversationId,
    required String text,
    String? replyToMessageId,
  }) async {
    throw UnsupportedError('sendTextMessage is not available on web');
  }

  @override
  Future<ImMessage> sendStickerMessage({
    required String conversationId,
    required ImStickerReference sticker,
  }) async {
    throw UnsupportedError('sendStickerMessage is not available on web');
  }

  @override
  Future<void> recallMessage({
    required String conversationId,
    required String messageId,
  }) async {
    throw UnsupportedError('recallMessage is not available on web');
  }

  @override
  Future<List<ImReaction>> reactToMessage({
    required String conversationId,
    required String messageId,
    required String emojiId,
    bool remove = false,
  }) async {
    throw UnsupportedError('reactToMessage is not available on web');
  }

  @override
  Future<ImMessage> sendMediaMessage({
    required String conversationId,
    required ImMediaUpload upload,
  }) async {
    throw UnsupportedError('sendMediaMessage is not available on web');
  }

  @override
  Future<void> markConversationRead(String conversationId) async {}

  @override
  Future<void> setConversationPreferences({
    required String conversationId,
    required bool isPinned,
    required bool isMuted,
  }) async {
    throw UnsupportedError(
      'Conversation preferences are unavailable on the web stub.',
    );
  }

  @override
  Future<List<ImConversation>> searchConversations(String query) async => [];

  @override
  Future<List<ImUser>> getUsers() async => [];

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
  Future<List<ImConversation>> getGroupList() async => [];

  @override
  Future<void> deleteConversation(String conversationId) async {}

  @override
  Future<void> clearAvatarCache() async {}

  @override
  Future<void> saveForwardRaw(String forwardId, String rawJson) async {}

  @override
  Future<String?> loadForwardRaw(String forwardId) async => null;

  @override
  Future<void> ensureConversation(ImConversation conversation) async {}
}
