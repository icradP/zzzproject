import '../models/im_models.dart';

/// Data source for IM conversations and messages.
///
/// Replace [MockImRepository] with a network / local DB implementation later.
abstract class ImRepository {
  /// The signed-in user.
  Future<ImUser> getCurrentUser();

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
  });

  /// Mark all messages in a conversation as read.
  Future<void> markConversationRead(String conversationId);

  /// Optional search hook for future inbox filtering.
  Future<List<ImConversation>> searchConversations(String query);

  /// Release streams and subscriptions.
  void dispose();
}
