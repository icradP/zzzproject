import '../models/im_models.dart';

/// Data source for IM conversations and messages.
///
/// Replace [MockImRepository] with a network / local DB implementation later.
abstract class ImRepository {
  /// Whether at least one active source supports account relationships.
  bool get supportsFriendManagement => false;

  /// The signed-in user.
  Future<ImUser> getCurrentUser({String? sourceId});

  /// Lookup a user by id.
  Future<ImUser?> getUser(String userId);

  /// Live conversation list for the inbox.
  Stream<List<ImConversation>> watchConversations();

  /// Live messages for a single conversation.
  Stream<List<ImMessage>> watchMessages(String conversationId);

  /// Fetch a conversation by id.
  Future<ImConversation?> getConversation(String conversationId);

  /// Send a text message. Implementations should append to [watchMessages].
  Future<ImMessage> sendTextMessage({
    required String conversationId,
    required String text,
    String? replyToMessageId,
  });

  /// Recall a message remotely when the source and server policy allow it.
  Future<void> recallMessage({
    required String conversationId,
    required String messageId,
  });

  /// Send a media message (image, voice, video, file).
  Future<ImMessage> sendMediaMessage({
    required String conversationId,
    required ImMediaUpload upload,
  });

  /// Mark all messages in a conversation as read.
  Future<void> markConversationRead(String conversationId);

  /// Optional search hook for future inbox filtering.
  Future<List<ImConversation>> searchConversations(String query);

  /// All known users (excluding self).
  Future<List<ImUser>> getUsers();

  Future<List<ImUser>> searchUsers(String query) async {
    throw UnsupportedError(
      'Friend management is not supported by this repository.',
    );
  }

  Future<List<ImFriendRequest>> getFriendRequests() async {
    throw UnsupportedError(
      'Friend management is not supported by this repository.',
    );
  }

  Future<void> sendFriendRequest({
    required String userId,
    String comment = '',
  }) async {
    throw UnsupportedError(
      'Friend management is not supported by this repository.',
    );
  }

  Future<void> handleFriendRequest({
    required String requestId,
    required bool accept,
  }) async {
    throw UnsupportedError(
      'Friend management is not supported by this repository.',
    );
  }

  Future<void> removeFriend(String userId) async {
    throw UnsupportedError(
      'Friend management is not supported by this repository.',
    );
  }

  /// All known groups as lightweight conversation stubs.
  Future<List<ImConversation>> getGroupList();

  /// Update the signed-in user's profile. Sources that do not support remote
  /// profiles may throw [UnsupportedError].
  Future<ImUser> updateProfile({
    String? nickname,
    ImMediaUpload? avatar,
    String? avatarAssetPath,
  }) async {
    throw UnsupportedError('Profile editing is not supported by this source.');
  }

  /// Create a remote group and return its conversation representation.
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

  /// Ensure a conversation appears in [watchConversations], adding it if absent.
  Future<void> ensureConversation(ImConversation conversation);

  /// Delete a conversation and its messages locally.
  Future<void> deleteConversation(String conversationId);

  /// Delete all cached avatar files. They will be re-downloaded on next use.
  Future<void> clearAvatarCache();

  /// Cache forwarded messages raw response for offline access.
  Future<void> saveForwardRaw(String forwardId, String rawJson);

  /// Load cached raw response, or null if not cached.
  Future<String?> loadForwardRaw(String forwardId);

  /// Release streams and subscriptions.
  void dispose();
}
