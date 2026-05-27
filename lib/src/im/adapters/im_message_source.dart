import '../models/im_models.dart';

enum ConnectionStatus { disconnected, connecting, connected, failed }

/// Platform-agnostic interface for external IM message sources.
///
/// Each concrete implementation (NoneBot, Matrix, Discord, etc.) handles
/// protocol-specific connection, event parsing, and message translation,
/// exposing a uniform stream-based API consumed by [ImRepository].
abstract class ImMessageSource {
  String get platformName;

  Stream<ConnectionStatus> get connectionStatus;

  Future<ImUser> getCurrentUser();

  Future<ImUser?> getUser(String userId);

  Stream<List<ImConversation>> watchConversations();

  Stream<List<ImMessage>> watchMessages(String conversationId);

  Future<ImConversation?> getConversation(String conversationId);

  Future<ImMessage> sendTextMessage({
    required String conversationId,
    required String text,
  });

  Future<void> markConversationRead(String conversationId);

  Future<List<ImConversation>> searchConversations(String query);

  /// All known users from the platform (excluding self).
  Future<List<ImUser>> getUsers();

  /// All known groups from the platform, as lightweight conversation stubs.
  /// These may not have any messages yet.
  Future<List<ImConversation>> getGroupList();

  /// Ensure a conversation appears in [watchConversations], adding it if absent.
  Future<void> ensureConversation(ImConversation conversation);

  /// Establish the connection to the platform. No-op for offline / mock sources.
  Future<void> connect();

  /// Tear down the connection and release resources.
  void disconnect();

  /// Verify connectivity. Returns null on success, or an error message.
  Future<String?> testConnection();
}
