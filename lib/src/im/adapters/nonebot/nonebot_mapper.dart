import '../../../assets/app_assets.dart';
import '../../models/im_models.dart';
import 'nonebot_models.dart';

/// Maps a OneBot sender to an [ImUser].
ImUser oneBotSenderToImUser(OneBotSender sender) {
  return ImUser(
    id: sender.userId,
    displayName: sender.card ?? sender.nickname,
    isOnline: true,
  );
}

/// Builds a deterministic conversation id for a OneBot chat.
String oneBotConversationId({required String selfId, String? userId, String? groupId}) {
  if (groupId != null) return 'group_$groupId';
  assert(userId != null, 'userId or groupId must be provided');
  // canonical ordering so dm ids are consistent
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
}) {
  return ImConversation(
    id: conversationId,
    type: ImConversationType.direct,
    title: peer.displayName,
    participantIds: [selfId, event.userId],
    avatarAssetPath: _avatarForUser(peer.id),
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

/// Converts an [ImMessage] into the OneBot message-chain format for sending.
List<Map<String, dynamic>> imMessageToOneBotChain(ImMessage message) {
  return [
    {'type': 'text', 'data': {'text': message.text}},
  ];
}

String _avatarForUser(String userId) {
  switch (userId) {
    case 'belle':
      return AppAssets.characterBelle;
    case 'wise':
      return AppAssets.characterWise;
    default:
      return AppAssets.characterWise;
  }
}
