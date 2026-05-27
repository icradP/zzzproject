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
}
