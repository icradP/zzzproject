import '../models/im_models.dart';

/// UI-level callbacks reserved for navigation and side effects.
///
/// Wire real auth, profile pages, or push notifications here later.
abstract class ImInteractionHandler {
  void onConversationOpened(ImConversation conversation);

  void onConversationClosed();

  Future<void> onSendMessage({
    required ImConversation conversation,
    required String text,
  });

  void onUserAvatarTap(ImUser user);

  void onMessageLongPress(ImMessage message);

  void onSearchQueryChanged(String query);

  void onComposeNewChat();

  /// Request download of a voice/record file.
  /// Returns the local file path, or `null` if download failed.
  Future<String?> downloadRecord({required String fileId, String? url});

  /// Fetch a combined forward message by its ID.
  Future<ForwardGroup> getForwardMessages(String forwardId);

  /// Resolve a user avatar local path, or null if unavailable.
  Future<String?> getUserAvatarPath(String userId);

  /// Send a media file (image, voice, video, file).
  Future<void> sendMedia({
    required ImConversation conversation,
    required ImMediaUpload upload,
  });
}

/// Default no-op handler used until product flows are connected.
class NoOpImInteractionHandler implements ImInteractionHandler {
  const NoOpImInteractionHandler();

  @override
  void onComposeNewChat() {}

  @override
  void onConversationClosed() {}

  @override
  void onConversationOpened(ImConversation conversation) {}

  @override
  void onMessageLongPress(ImMessage message) {}

  @override
  void onSearchQueryChanged(String query) {}

  @override
  Future<void> onSendMessage({
    required ImConversation conversation,
    required String text,
  }) async {}

  @override
  void onUserAvatarTap(ImUser user) {}

  @override
  Future<ForwardGroup> getForwardMessages(String forwardId) async =>
      const ForwardGroup();

  @override
  Future<String?> getUserAvatarPath(String userId) async => null;

  @override
  Future<String?> downloadRecord({required String fileId, String? url}) async =>
      null;

  @override
  Future<void> sendMedia({
    required ImConversation conversation,
    required ImMediaUpload upload,
  }) async {}
}
