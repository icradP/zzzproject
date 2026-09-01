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
  Stream<List<ImUser>> watchUsers() => _source.watchUsers();

  @override
  Stream<List<ImConversation>> watchConversations() =>
      _source.watchConversations();

  @override
  Stream<List<ImMessage>> watchMessages(String conversationId) =>
      _source.watchMessages(conversationId);

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
  }) => _source.updateProfile(
    nickname: nickname,
    avatar: avatar,
    avatarAssetPath: avatarAssetPath,
  );

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
