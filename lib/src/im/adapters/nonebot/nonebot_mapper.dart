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

/// Converts OneBot message segments into human-readable display text.
///
/// [CQ:at,qq=xxx] segments are resolved to `@displayName` via [resolveName].
/// Other non-text segments use a short placeholder.
String oneBotSegmentsToDisplayText(
  List<OneBotMessageSegment> segments, {
  required String Function(String qq) resolveName,
}) {
  final buf = StringBuffer();
  for (final seg in segments) {
    switch (seg.type) {
      case 'text':
        buf.write(seg.data['text'] ?? '');
      case 'at':
        final qq = seg.data['qq'] as String?;
        if (qq != null && qq != 'all') {
          buf.write('@${resolveName(qq)} ');
        } else {
          buf.write('@全体成员 ');
        }
      case 'face':
        buf.write('[表情]');
      case 'image':
        buf.write('[图片]');
      case 'record':
        buf.write('[语音]');
      case 'video':
        buf.write('[视频]');
      case 'reply':
        buf.write('[回复]');
      case 'forward':
        buf.write('[合并转发]');
      case 'file':
        buf.write('[文件]');
      default:
        buf.write('[${seg.type}]');
    }
  }
  return buf.toString().trim();
}

/// Maps a OneBot segment type to the corresponding [ImMessageKind].
ImMessageKind oneBotSegmentToMessageKind(OneBotMessageSegment seg) {
  switch (seg.type) {
    case 'text':
      return ImMessageKind.text;
    case 'image':
      return ImMessageKind.image;
    case 'record':
      return ImMessageKind.record;
    case 'video':
      return ImMessageKind.video;
    case 'face':
      return ImMessageKind.face;
    case 'at':
      return ImMessageKind.at;
    case 'reply':
      return ImMessageKind.reply;
    case 'forward':
      return ImMessageKind.forward;
    case 'location':
      return ImMessageKind.location;
    case 'share':
      return ImMessageKind.share;
    case 'music':
      return ImMessageKind.music;
    case 'contact':
      return ImMessageKind.contact;
    default:
      return ImMessageKind.text;
  }
}

/// Determines the primary [ImMessageKind] from a list of segments.
///
/// The first non-text segment wins; otherwise [ImMessageKind.text].
ImMessageKind oneBotPrimaryKind(List<OneBotMessageSegment> segments) {
  for (final s in segments) {
    final k = oneBotSegmentToMessageKind(s);
    if (k != ImMessageKind.text) return k;
  }
  return ImMessageKind.text;
}

/// Extracts media metadata from a segment for caching / storage.
({String? fileId, String? url}) oneBotExtractMedia(
  OneBotMessageSegment seg,
) {
  final d = seg.data;
  return (fileId: d['file']?.toString(), url: d['url']?.toString());
}

/// Converts a private-message event into one or more [ImMessage]s.
///
/// When the message has both text and media segments they are split into
/// separate bubbles that share the same sender / timestamp / avatar.
List<ImMessage> oneBotPrivateMessageToImMessages({
  required OneBotPrivateMessageEvent event,
  required String conversationId,
  required String selfId,
  required String Function(String qq) resolveName,
}) {
  return _buildSplitMessages(
    baseId: '${event.messageId}',
    conversationId: conversationId,
    senderId: event.userId,
    isMine: event.userId == selfId,
    time: event.time,
    segments: event.message,
    resolveName: resolveName,
  );
}

/// Converts a group-message event into one or more [ImMessage]s.
List<ImMessage> oneBotGroupMessageToImMessages({
  required OneBotGroupMessageEvent event,
  required String conversationId,
  required String selfId,
  required String Function(String qq) resolveName,
}) {
  return _buildSplitMessages(
    baseId: '${event.messageId}',
    conversationId: conversationId,
    senderId: event.userId,
    isMine: event.userId == selfId,
    time: event.time,
    segments: event.message,
    resolveName: resolveName,
  );
}

// -- Legacy single-message converters (kept for backward compat) ----------

/// @deprecated Use [oneBotPrivateMessageToImMessages] instead.
ImMessage oneBotPrivateMessageToImMessage({
  required OneBotPrivateMessageEvent event,
  required String conversationId,
  required String selfId,
  required String Function(String qq) resolveName,
}) {
  return oneBotPrivateMessageToImMessages(
    event: event,
    conversationId: conversationId,
    selfId: selfId,
    resolveName: resolveName,
  ).first;
}

/// @deprecated Use [oneBotGroupMessageToImMessages] instead.
ImMessage oneBotGroupMessageToImMessage({
  required OneBotGroupMessageEvent event,
  required String conversationId,
  required String selfId,
  required String Function(String qq) resolveName,
}) {
  return oneBotGroupMessageToImMessages(
    event: event,
    conversationId: conversationId,
    selfId: selfId,
    resolveName: resolveName,
  ).first;
}

// -- Internal -------------------------------------------------------------

List<ImMessage> _buildSplitMessages({
  required String baseId,
  required String conversationId,
  required String senderId,
  required bool isMine,
  required int time,
  required List<OneBotMessageSegment> segments,
  required String Function(String qq) resolveName,
}) {
  final replyId = _extractReplyId(segments);

  // Separate text segments and media segments.
  final textSegs = <OneBotMessageSegment>[];
  final mediaSegs = <OneBotMessageSegment>[];
  for (final s in segments) {
    if (s.type == 'text' || s.type == 'at' || s.type == 'face' || s.type == 'reply') {
      textSegs.add(s);
    } else {
      mediaSegs.add(s);
    }
  }

  final results = <ImMessage>[];
  final sentAt = DateTime.fromMillisecondsSinceEpoch(time * 1000);
  var idx = 0;

  // Text bubble (if any).
  if (textSegs.isNotEmpty) {
    results.add(ImMessage(
      id: '${baseId}_$idx',
      conversationId: conversationId,
      senderId: senderId,
      text: oneBotSegmentsToDisplayText(textSegs, resolveName: resolveName),
      sentAt: sentAt,
      kind: ImMessageKind.text,
      isMine: isMine,
      segments: textSegs,
      replyToMessageId: replyId,
    ));
    idx++;
  }

  // Media bubbles (one per media segment).
  for (final seg in mediaSegs) {
    final kind = oneBotSegmentToMessageKind(seg);
    final media = oneBotExtractMedia(seg);
    results.add(ImMessage(
      id: '${baseId}_$idx',
      conversationId: conversationId,
      senderId: senderId,
      text: oneBotSegmentsToDisplayText([seg], resolveName: resolveName),
      sentAt: sentAt,
      kind: kind,
      isMine: isMine,
      segments: [seg],
      mediaUrl: media.url,
    ));
    idx++;
  }

  return results;
}

String? _extractReplyId(List<OneBotMessageSegment> segments) {
  for (final s in segments) {
    if (s.type == 'reply') {
      return s.data['id']?.toString();
    }
  }
  return null;
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
