import '../models/im_models.dart';

enum ConnectionStatus { disconnected, connecting, connected, failed }

/// Platform-agnostic interface for external IM message sources.
///
/// Each concrete implementation (NoneBot, Matrix, Discord, etc.) handles
/// protocol-specific connection, event parsing, and message translation,
/// exposing a uniform stream-based API consumed by [ImRepository].
abstract class ImMessageSource {
  String get platformName;

  /// Whether this source owns first-class friend relationships.
  bool get supportsFriendManagement => false;

  Stream<ConnectionStatus> get connectionStatus;

  Future<ImUser> getCurrentUser();

  Future<ImUser?> getUser(String userId);

  Future<ImUser?> getProfileCard(String userId, {String? groupId}) =>
      getUser(userId);

  Future<List<ImUser>> getSuggestedContacts() async => const [];

  Stream<List<ImUser>> watchUsers();

  Stream<List<ImConversation>> watchConversations();

  Stream<List<ImMessage>> watchMessages(String conversationId);

  Future<bool> loadOlderMessages(String conversationId) async => false;

  Future<ImConversation?> getConversation(String conversationId);

  Future<ImMessage> sendTextMessage({
    required String conversationId,
    required String text,
    String? replyToMessageId,
  });

  Future<ImMessage> sendComposedTextMessage({
    required String conversationId,
    required ImComposedText message,
    String? replyToMessageId,
  }) => sendTextMessage(
    conversationId: conversationId,
    text: message.plainText,
    replyToMessageId: replyToMessageId,
  );

  Future<ImMessage> sendStickerMessage({
    required String conversationId,
    required ImStickerReference sticker,
  }) => sendTextMessage(conversationId: conversationId, text: '[Sticker]');

  Future<ImMessage> sendLinkMessage({
    required String conversationId,
    required ImLinkShare link,
  }) => sendTextMessage(
    conversationId: conversationId,
    text: link.url.toString(),
  );

  Future<ImMessage> sendLocationMessage({
    required String conversationId,
    required ImLocationShare location,
  }) => sendTextMessage(
    conversationId: conversationId,
    text:
        location.hasCoordinates
            ? '${location.name} (${location.latitude}, ${location.longitude})'
            : location.name,
  );

  Future<ImMessage> sendPoke({
    required String conversationId,
    required String targetUserId,
  }) async {
    throw UnsupportedError('Poke is not supported by this source.');
  }

  Future<ImMessage> forwardMessages({
    required String conversationId,
    required List<ImMessage> messages,
  }) async {
    throw UnsupportedError('Forwarding is not supported by this source.');
  }

  Future<ForwardGroup> getForwardMessages(String forwardId) async =>
      const ForwardGroup();

  Future<void> recallMessage({
    required String conversationId,
    required String messageId,
  });

  /// Add or remove the current user's emoji reaction on a message.
  Future<List<ImReaction>> reactToMessage({
    required String conversationId,
    required String messageId,
    required String emojiId,
    bool remove = false,
  }) async {
    throw UnsupportedError(
      'Message reactions are not supported by this source.',
    );
  }

  Future<ImMessage> sendMediaMessage({
    required String conversationId,
    required ImMediaUpload upload,
  });

  Future<void> markConversationRead(String conversationId);

  Future<void> setConversationPreferences({
    required String conversationId,
    required bool isPinned,
    required ImConversationNotificationLevel notificationLevel,
  }) async {
    throw UnsupportedError(
      'Conversation preferences are not supported by this source.',
    );
  }

  Future<List<ImConversation>> searchConversations(String query);

  /// All known users from the platform (excluding self).
  Future<List<ImUser>> getUsers();

  /// Search accounts owned by this source. Unsupported sources return an
  /// [UnsupportedError] through the default implementation.
  Future<List<ImUser>> searchUsers(String query) async {
    throw UnsupportedError(
      'Friend management is not supported by this source.',
    );
  }

  Future<List<ImFriendRequest>> getFriendRequests() async {
    throw UnsupportedError(
      'Friend management is not supported by this source.',
    );
  }

  Stream<List<ImFriendRequest>> watchFriendRequests() async* {
    yield await getFriendRequests();
  }

  Future<void> sendFriendRequest({
    required String userId,
    String comment = '',
  }) async {
    throw UnsupportedError(
      'Friend management is not supported by this source.',
    );
  }

  Future<void> handleFriendRequest({
    required String requestId,
    required bool accept,
  }) async {
    throw UnsupportedError(
      'Friend management is not supported by this source.',
    );
  }

  Future<void> removeFriend(String userId) async {
    throw UnsupportedError(
      'Friend management is not supported by this source.',
    );
  }

  /// All known groups from the platform, as lightweight conversation stubs.
  /// These may not have any messages yet.
  Future<List<ImConversation>> getGroupList();

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
    throw UnsupportedError('Profile editing is not supported by this source.');
  }

  Future<ImUserTitle> grantGroupTitle({
    required String groupId,
    required String userId,
    required String text,
    required String style,
    DateTime? expiresAt,
  }) async {
    throw UnsupportedError('Group titles are not supported by this source.');
  }

  Future<void> revokeGroupTitle({
    required String groupId,
    required String userId,
    required String titleId,
  }) async {
    throw UnsupportedError('Group titles are not supported by this source.');
  }

  Future<void> setUserBlocked({
    required String userId,
    required bool blocked,
  }) async {
    throw UnsupportedError('User blocking is not supported by this source.');
  }

  Future<void> reportUser({
    required String userId,
    required String reason,
    String details = '',
  }) async {
    throw UnsupportedError('User reporting is not supported by this source.');
  }

  Future<ImConversation> createGroup({
    required String name,
    List<String> memberIds = const [],
    ImMediaUpload? avatar,
  }) async {
    throw UnsupportedError('Group management is not supported by this source.');
  }

  Future<void> joinGroup(String groupId) async {
    throw UnsupportedError('Group management is not supported by this source.');
  }

  Future<void> leaveGroup(String groupId) async {
    throw UnsupportedError('Group management is not supported by this source.');
  }

  Future<ImGroupDetails> getGroupDetails(String groupId) async {
    throw UnsupportedError('Group details are not supported by this source.');
  }

  Future<List<ImGroupAnnouncement>> getGroupAnnouncements(
    String groupId,
  ) async {
    throw UnsupportedError(
      'Group announcements are not supported by this source.',
    );
  }

  Future<ImGroupAnnouncement> createGroupAnnouncement({
    required String groupId,
    required String content,
    required bool isPinned,
  }) async {
    throw UnsupportedError(
      'Group announcements are not supported by this source.',
    );
  }

  Future<ImGroupAnnouncement> updateGroupAnnouncement({
    required String announcementId,
    required String content,
    required bool isPinned,
  }) async {
    throw UnsupportedError(
      'Group announcements are not supported by this source.',
    );
  }

  Future<void> deleteGroupAnnouncement(String announcementId) async {
    throw UnsupportedError(
      'Group announcements are not supported by this source.',
    );
  }

  Future<void> markGroupAnnouncementRead(String announcementId) async {
    throw UnsupportedError(
      'Group announcements are not supported by this source.',
    );
  }

  Future<void> inviteGroupMembers({
    required String groupId,
    required List<String> userIds,
  }) async {
    throw UnsupportedError(
      'Group invitations are not supported by this source.',
    );
  }

  Future<void> removeGroupMember({
    required String groupId,
    required String userId,
  }) async {
    throw UnsupportedError(
      'Removing group members is not supported by this source.',
    );
  }

  Future<void> updateGroup({
    required String groupId,
    String? name,
    ImMediaUpload? avatar,
    String? announcement,
  }) async {
    throw UnsupportedError('Editing groups is not supported by this source.');
  }

  Future<void> setGroupAdmin({
    required String groupId,
    required String userId,
    required bool enabled,
  }) async {
    throw UnsupportedError(
      'Group administrators are not supported by this source.',
    );
  }

  Future<void> setGroupMemberMute({
    required String groupId,
    required String userId,
    required Duration duration,
  }) async {
    throw UnsupportedError('Group muting is not supported by this source.');
  }

  Future<void> setGroupMuteAll({
    required String groupId,
    required bool enabled,
  }) async {
    throw UnsupportedError(
      'Whole-group muting is not supported by this source.',
    );
  }

  Future<void> transferGroupOwnership({
    required String groupId,
    required String userId,
  }) async {
    throw UnsupportedError(
      'Group ownership transfer is not supported by this source.',
    );
  }

  Future<void> dismissGroup(String groupId) async {
    throw UnsupportedError('Group dismissal is not supported by this source.');
  }

  /// Ensure a conversation appears in [watchConversations], adding it if absent.
  Future<void> ensureConversation(ImConversation conversation);

  /// Delete a conversation and its messages locally. This does NOT affect
  /// the remote server — it only removes the local copy.
  Future<void> deleteConversation(String conversationId);

  /// Establish the connection to the platform. No-op for offline / mock sources.
  Future<void> connect();

  /// Tear down the connection and release resources.
  void disconnect();

  /// Verify connectivity. Returns null on success, or an error message.
  Future<String?> testConnection();

  /// Delete all cached avatar files so they are re-downloaded on next use.
  Future<void> clearAvatarCache();

  /// Cache forwarded messages raw response.
  Future<void> saveForwardRaw(String forwardId, String rawJson);

  /// Load cached raw response.
  Future<String?> loadForwardRaw(String forwardId);
}
