import '../data/im_repository.dart';
import '../models/im_models.dart';
import 'im_message_source.dart';

/// An [ImRepository] backed by an [ImMessageSource].
///
/// This bridges the adapter layer into the app's existing data interface
/// so that swapping platforms requires zero changes to the UI layer.
class SourceBackedRepository implements ImRepository {
  SourceBackedRepository(this._source) {
    // Fire-and-forget: connect in the background so the UI can show
    // connection status while data begins flowing.
    _source.connect().catchError((_) {
      // Connection failures are surfaced via connectionStatus stream;
      // no need to crash the app.
    });
  }

  final ImMessageSource _source;

  @override
  bool get supportsFriendManagement => _source.supportsFriendManagement;

  /// Live connection status for the UI.
  Stream<ConnectionStatus> get connectionStatus => _source.connectionStatus;

  @override
  Future<ImUser> getCurrentUser({String? sourceId}) => _source.getCurrentUser();

  @override
  Future<ImUser?> getUser(String userId) => _source.getUser(userId);

  @override
  Future<ImUser?> getProfileCard(String userId, {String? groupId}) =>
      _source.getProfileCard(userId, groupId: groupId);

  @override
  Future<List<ImUser>> getSuggestedContacts() => _source.getSuggestedContacts();

  @override
  Stream<List<ImUser>> watchUsers() => _source.watchUsers();

  @override
  Stream<List<ImConversation>> watchConversations() =>
      _source.watchConversations();

  @override
  Stream<List<ImMessage>> watchMessages(String conversationId) =>
      _source.watchMessages(conversationId);

  @override
  Future<bool> loadOlderMessages(String conversationId) =>
      _source.loadOlderMessages(conversationId);

  @override
  Future<ImConversation?> getConversation(String conversationId) =>
      _source.getConversation(conversationId);

  @override
  Future<ImMessage> sendTextMessage({
    required String conversationId,
    required String text,
    String? replyToMessageId,
  }) => _source.sendTextMessage(
    conversationId: conversationId,
    text: text,
    replyToMessageId: replyToMessageId,
  );

  @override
  Future<ImMessage> sendComposedTextMessage({
    required String conversationId,
    required ImComposedText message,
    String? replyToMessageId,
  }) => _source.sendComposedTextMessage(
    conversationId: conversationId,
    message: message,
    replyToMessageId: replyToMessageId,
  );

  @override
  Future<ImMessage> sendStickerMessage({
    required String conversationId,
    required ImStickerReference sticker,
  }) => _source.sendStickerMessage(
    conversationId: conversationId,
    sticker: sticker,
  );

  @override
  Future<ImMessage> sendLinkMessage({
    required String conversationId,
    required ImLinkShare link,
  }) => _source.sendLinkMessage(conversationId: conversationId, link: link);

  @override
  Future<ImMessage> sendLocationMessage({
    required String conversationId,
    required ImLocationShare location,
  }) => _source.sendLocationMessage(
    conversationId: conversationId,
    location: location,
  );

  @override
  Future<ImMessage> sendPoke({
    required String conversationId,
    required String targetUserId,
  }) => _source.sendPoke(
    conversationId: conversationId,
    targetUserId: targetUserId,
  );

  @override
  Future<ImMessage> forwardMessages({
    required String conversationId,
    required List<ImMessage> messages,
  }) => _source.forwardMessages(
    conversationId: conversationId,
    messages: messages,
  );

  @override
  Future<ForwardGroup> getForwardMessages(String forwardId) =>
      _source.getForwardMessages(forwardId);

  @override
  Future<void> recallMessage({
    required String conversationId,
    required String messageId,
  }) => _source.recallMessage(
    conversationId: conversationId,
    messageId: messageId,
  );

  @override
  Future<List<ImReaction>> reactToMessage({
    required String conversationId,
    required String messageId,
    required String emojiId,
    bool remove = false,
  }) => _source.reactToMessage(
    conversationId: conversationId,
    messageId: messageId,
    emojiId: emojiId,
    remove: remove,
  );

  @override
  Future<ImMessage> sendMediaMessage({
    required String conversationId,
    required ImMediaUpload upload,
  }) =>
      _source.sendMediaMessage(conversationId: conversationId, upload: upload);

  @override
  Future<void> markConversationRead(String conversationId) =>
      _source.markConversationRead(conversationId);

  @override
  Future<void> setConversationPreferences({
    required String conversationId,
    required bool isPinned,
    required ImConversationNotificationLevel notificationLevel,
  }) => _source.setConversationPreferences(
    conversationId: conversationId,
    isPinned: isPinned,
    notificationLevel: notificationLevel,
  );

  @override
  Future<List<ImConversation>> searchConversations(String query) =>
      _source.searchConversations(query);

  @override
  Future<List<ImUser>> getUsers() => _source.getUsers();

  @override
  Future<List<ImUser>> searchUsers(String query) => _source.searchUsers(query);

  @override
  Future<List<ImFriendRequest>> getFriendRequests() =>
      _source.getFriendRequests();

  @override
  Stream<List<ImFriendRequest>> watchFriendRequests() =>
      _source.watchFriendRequests();

  @override
  Future<void> sendFriendRequest({
    required String userId,
    String comment = '',
  }) => _source.sendFriendRequest(userId: userId, comment: comment);

  @override
  Future<void> handleFriendRequest({
    required String requestId,
    required bool accept,
  }) => _source.handleFriendRequest(requestId: requestId, accept: accept);

  @override
  Future<void> removeFriend(String userId) => _source.removeFriend(userId);

  @override
  Future<List<ImConversation>> getGroupList() => _source.getGroupList();

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
  }) => _source.updateProfile(
    nickname: nickname,
    avatar: avatar,
    avatarAssetPath: avatarAssetPath,
    bio: bio,
    cardBackground: cardBackground,
    cardBackgroundUrl: cardBackgroundUrl,
    cardBackgroundColor: cardBackgroundColor,
    cardBackgroundSensitive: cardBackgroundSensitive,
    showMutualGroups: showMutualGroups,
    showAccountId: showAccountId,
  );

  @override
  Future<ImUserTitle> grantGroupTitle({
    required String groupId,
    required String userId,
    required String text,
    required String style,
    DateTime? expiresAt,
  }) => _source.grantGroupTitle(
    groupId: groupId,
    userId: userId,
    text: text,
    style: style,
    expiresAt: expiresAt,
  );

  @override
  Future<void> revokeGroupTitle({
    required String groupId,
    required String userId,
    required String titleId,
  }) => _source.revokeGroupTitle(
    groupId: groupId,
    userId: userId,
    titleId: titleId,
  );

  @override
  Future<void> setUserBlocked({
    required String userId,
    required bool blocked,
  }) => _source.setUserBlocked(userId: userId, blocked: blocked);

  @override
  Future<void> reportUser({
    required String userId,
    required String reason,
    String details = '',
  }) => _source.reportUser(userId: userId, reason: reason, details: details);

  @override
  Future<ImConversation> createGroup({
    required String name,
    List<String> memberIds = const [],
    ImMediaUpload? avatar,
  }) => _source.createGroup(name: name, memberIds: memberIds, avatar: avatar);

  @override
  Future<void> joinGroup(String groupId) => _source.joinGroup(groupId);

  @override
  Future<void> leaveGroup(String groupId) => _source.leaveGroup(groupId);

  @override
  Future<ImGroupDetails> getGroupDetails(String groupId) =>
      _source.getGroupDetails(groupId);

  @override
  Future<List<ImGroupAnnouncement>> getGroupAnnouncements(String groupId) =>
      _source.getGroupAnnouncements(groupId);

  @override
  Future<ImGroupAnnouncement> createGroupAnnouncement({
    required String groupId,
    required String content,
    required bool isPinned,
  }) => _source.createGroupAnnouncement(
    groupId: groupId,
    content: content,
    isPinned: isPinned,
  );

  @override
  Future<ImGroupAnnouncement> updateGroupAnnouncement({
    required String announcementId,
    required String content,
    required bool isPinned,
  }) => _source.updateGroupAnnouncement(
    announcementId: announcementId,
    content: content,
    isPinned: isPinned,
  );

  @override
  Future<void> deleteGroupAnnouncement(String announcementId) =>
      _source.deleteGroupAnnouncement(announcementId);

  @override
  Future<void> markGroupAnnouncementRead(String announcementId) =>
      _source.markGroupAnnouncementRead(announcementId);

  @override
  Future<void> inviteGroupMembers({
    required String groupId,
    required List<String> userIds,
  }) => _source.inviteGroupMembers(groupId: groupId, userIds: userIds);

  @override
  Future<void> removeGroupMember({
    required String groupId,
    required String userId,
  }) => _source.removeGroupMember(groupId: groupId, userId: userId);

  @override
  Future<void> updateGroup({
    required String groupId,
    String? name,
    ImMediaUpload? avatar,
    String? announcement,
  }) => _source.updateGroup(
    groupId: groupId,
    name: name,
    avatar: avatar,
    announcement: announcement,
  );

  @override
  Future<void> setGroupAdmin({
    required String groupId,
    required String userId,
    required bool enabled,
  }) =>
      _source.setGroupAdmin(groupId: groupId, userId: userId, enabled: enabled);

  @override
  Future<void> setGroupMemberMute({
    required String groupId,
    required String userId,
    required Duration duration,
  }) => _source.setGroupMemberMute(
    groupId: groupId,
    userId: userId,
    duration: duration,
  );

  @override
  Future<void> setGroupMuteAll({
    required String groupId,
    required bool enabled,
  }) => _source.setGroupMuteAll(groupId: groupId, enabled: enabled);

  @override
  Future<void> transferGroupOwnership({
    required String groupId,
    required String userId,
  }) => _source.transferGroupOwnership(groupId: groupId, userId: userId);

  @override
  Future<void> dismissGroup(String groupId) => _source.dismissGroup(groupId);

  @override
  Future<void> ensureConversation(ImConversation conversation) =>
      _source.ensureConversation(conversation);

  @override
  Future<void> deleteConversation(String conversationId) =>
      _source.deleteConversation(conversationId);

  @override
  Future<void> clearAvatarCache() => _source.clearAvatarCache();

  @override
  Future<void> saveForwardRaw(String forwardId, String rawJson) =>
      _source.saveForwardRaw(forwardId, rawJson);

  @override
  Future<String?> loadForwardRaw(String forwardId) =>
      _source.loadForwardRaw(forwardId);

  @override
  void dispose() => _source.disconnect();
}
