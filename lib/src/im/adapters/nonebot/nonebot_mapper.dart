import '../../models/im_models.dart';
import 'nonebot_models.dart';

/// Resolves an avatar asset path for a user id.
typedef AvatarResolver = String? Function(String userId);

String? _defaultAvatarResolver(String userId) => null;

/// Maps a OneBot sender to an [ImUser].
ImUser oneBotSenderToImUser(
  OneBotSender sender, {
  AvatarResolver avatarResolver = _defaultAvatarResolver,
}) {
  return ImUser(
    id: sender.userId,
    displayName: (sender.card != null && sender.card!.isNotEmpty)
        ? sender.card!
        : sender.nickname,
    avatarAssetPath: avatarResolver(sender.userId),
    isOnline: true,
  );
}

/// Builds a deterministic conversation id for a OneBot chat.
String oneBotConversationId({
  required String selfId,
  String? userId,
  String? groupId,
}) {
  if (groupId != null) return 'group_$groupId';
  assert(userId != null, 'userId or groupId must be provided');
  final sorted = [selfId, userId!]..sort();
  return 'dm_${sorted[0]}_${sorted[1]}';
}

/// Converts a private-message event to an [ImMessage].
ImMessage oneBotPrivateMessageToImMessage({
  required OneBotPrivateMessageEvent event,
  required String conversationId,
  required String selfId,
}) {
  return ImMessage(
    id: '${event.messageId}',
    conversationId: conversationId,
    senderId: event.userId,
    text: event.rawMessage.isNotEmpty ? event.rawMessage : event.plainText,
    sentAt: DateTime.fromMillisecondsSinceEpoch(event.time * 1000),
    kind: ImMessageKind.text,
    isMine: event.userId == selfId,
  );
}

/// Converts a group-message event to an [ImMessage].
ImMessage oneBotGroupMessageToImMessage({
  required OneBotGroupMessageEvent event,
  required String conversationId,
  required String selfId,
}) {
  return ImMessage(
    id: '${event.messageId}',
    conversationId: conversationId,
    senderId: event.userId,
    text: event.rawMessage.isNotEmpty ? event.rawMessage : event.plainText,
    sentAt: DateTime.fromMillisecondsSinceEpoch(event.time * 1000),
    kind: ImMessageKind.text,
    isMine: event.userId == selfId,
  );
}

/// Builds an [ImConversation] from a private message event.
ImConversation oneBotPrivateEventToConversation({
  required OneBotPrivateMessageEvent event,
  required String conversationId,
  required String selfId,
  required ImUser peer,
  required String subtitle,
  required DateTime updatedAt,
  String? avatarAssetPath,
}) {
  return ImConversation(
    id: conversationId,
    type: ImConversationType.direct,
    title: peer.displayName,
    participantIds: [selfId, event.userId],
    avatarAssetPath: avatarAssetPath ?? peer.avatarAssetPath,
    subtitle: subtitle,
    updatedAt: updatedAt,
  );
}

/// Builds an [ImConversation] from a group message event.
ImConversation oneBotGroupEventToConversation({
  required OneBotGroupMessageEvent event,
  required String conversationId,
  required String selfId,
  required String title,
  required List<String> participantIds,
  required String subtitle,
  required DateTime updatedAt,
}) {
  return ImConversation(
    id: conversationId,
    type: ImConversationType.group,
    title: title,
    participantIds: participantIds,
    subtitle: subtitle,
    updatedAt: updatedAt,
  );
}

/// Converts an [ImMessage] into OneBot message segments for sending.
List<OneBotMessageSegment> imMessageToOneBotChain(ImMessage message) {
  return [OneBotMessageSegment.plain(message.text)];
}

/// Result type for `parseConversationId`.
({String targetId, bool isGroup}) parseConversationId(
  String conversationId,
  String selfId,
) {
  if (conversationId.startsWith('group_')) {
    return (targetId: conversationId.substring(6), isGroup: true);
  }
  if (conversationId.startsWith('dm_')) {
    final suffix = conversationId.substring(3);
    final parts = suffix.split('_');
    final target = parts.firstWhere(
      (p) => p != selfId,
      orElse: () => parts.last,
    );
    return (targetId: target, isGroup: false);
  }
  return (targetId: conversationId, isGroup: false);
}
