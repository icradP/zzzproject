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

  /// Live connection status for the UI.
  Stream<ConnectionStatus> get connectionStatus => _source.connectionStatus;

  @override
  Future<ImUser> getCurrentUser() => _source.getCurrentUser();

  @override
  Future<ImUser?> getUser(String userId) => _source.getUser(userId);

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
  }) =>
      _source.sendTextMessage(conversationId: conversationId, text: text);

  @override
  Future<void> markConversationRead(String conversationId) =>
      _source.markConversationRead(conversationId);

  @override
  Future<List<ImConversation>> searchConversations(String query) =>
      _source.searchConversations(query);

  @override
  Future<List<ImUser>> getUsers() => _source.getUsers();

  @override
  Future<List<ImConversation>> getGroupList() => _source.getGroupList();

  @override
  Future<void> ensureConversation(ImConversation conversation) =>
      _source.ensureConversation(conversation);

  @override
  Future<void> deleteConversation(String conversationId) =>
      _source.deleteConversation(conversationId);

  @override
  Future<void> clearAvatarCache() => _source.clearAvatarCache();

  @override
  void dispose() => _source.disconnect();
}
