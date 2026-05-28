import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';

import 'package:onebot_flutter/onebot_flutter.dart';

enum ImConversationType { direct, group }

enum ImMessageStatus { sending, sent, delivered, read, failed }

/// Mirrors OneBot segment types for local storage / display decisions.
enum ImMessageKind {
  text,
  image,
  record,
  video,
  file,
  face,
  at,
  reply,
  forward,
  location,
  share,
  music,
  contact,
  system,
  poke,
}

/// A contact or the signed-in user.
class ImUser {
  const ImUser({
    required this.id,
    required this.displayName,
    this.avatarAssetPath,
    this.avatarBytes,
    this.avatarLocalPath,
    this.isOnline = false,
  });

  final String id;
  final String displayName;
  final String? avatarAssetPath;
  final Uint8List? avatarBytes;

  /// Local file path to a downloaded avatar (e.g. QQ avatar cached to disk).
  final String? avatarLocalPath;
  final bool isOnline;

  /// Builds an [ImageProvider] for this user's avatar, trying local file
  /// cache first, then asset path, then [fallbackAsset].
  ImageProvider avatarImage(String fallbackAsset) {
    if (avatarLocalPath != null) return FileImage(File(avatarLocalPath!));
    if (avatarBytes != null) return MemoryImage(avatarBytes!);
    return AssetImage(avatarAssetPath ?? fallbackAsset);
  }

  ImUser copyWith({
    String? displayName,
    String? avatarAssetPath,
    Uint8List? avatarBytes,
    String? avatarLocalPath,
    bool? isOnline,
  }) {
    return ImUser(
      id: id,
      displayName: displayName ?? this.displayName,
      avatarAssetPath: avatarAssetPath ?? this.avatarAssetPath,
      avatarBytes: avatarBytes ?? this.avatarBytes,
      avatarLocalPath: avatarLocalPath ?? this.avatarLocalPath,
      isOnline: isOnline ?? this.isOnline,
    );
  }
}

/// A chat thread shown in the conversation list.
class ImConversation {
  const ImConversation({
    required this.id,
    required this.type,
    required this.title,
    required this.participantIds,
    this.subtitle,
    this.avatarAssetPath,
    this.avatarLocalPath,
    this.updatedAt,
    this.unreadCount = 0,
    this.isPinned = false,
  });

  final String id;
  final ImConversationType type;
  final String title;
  final List<String> participantIds;
  final String? subtitle;
  final String? avatarAssetPath;

  /// Local file path to a downloaded group avatar.
  final String? avatarLocalPath;
  final DateTime? updatedAt;
  final int unreadCount;
  final bool isPinned;

  bool get isGroup => type == ImConversationType.group;

  /// Builds an [ImageProvider] for this conversation's avatar, checking
  /// local file cache first, then asset path.
  ImageProvider avatarImage(String fallbackAsset) {
    if (avatarLocalPath != null) return FileImage(File(avatarLocalPath!));
    return AssetImage(avatarAssetPath ?? fallbackAsset);
  }

  ImConversation copyWith({
    String? title,
    String? subtitle,
    String? avatarAssetPath,
    String? avatarLocalPath,
    DateTime? updatedAt,
    int? unreadCount,
    bool? isPinned,
    List<String>? participantIds,
  }) {
    return ImConversation(
      id: id,
      type: type,
      title: title ?? this.title,
      participantIds: participantIds ?? this.participantIds,
      subtitle: subtitle ?? this.subtitle,
      avatarAssetPath: avatarAssetPath ?? this.avatarAssetPath,
      avatarLocalPath: avatarLocalPath ?? this.avatarLocalPath,
      updatedAt: updatedAt ?? this.updatedAt,
      unreadCount: unreadCount ?? this.unreadCount,
      isPinned: isPinned ?? this.isPinned,
    );
  }
}

/// A single message inside a conversation.
class ImMessage {
  const ImMessage({
    required this.id,
    required this.conversationId,
    required this.senderId,
    required this.text,
    required this.sentAt,
    this.kind = ImMessageKind.text,
    this.status = ImMessageStatus.sent,
    this.isMine = false,
    this.segments,
    this.mediaPath,
    this.mediaUrl,
    this.mediaSize,
    this.thumbnailPath,
    this.mediaMime,
    this.reactions,
    this.replyToMessageId,
  });

  final String id;
  final String conversationId;
  final String senderId;

  /// Human-readable display text (already resolved, e.g. `@Alice hi`).
  final String text;
  final DateTime sentAt;
  final ImMessageKind kind;
  final ImMessageStatus status;
  final bool isMine;

  /// Raw OneBot message segments for reconstructing rich content.
  final List<OneBotMessageSegment>? segments;

  /// Local file path to downloaded / cached media.
  final String? mediaPath;

  /// Original remote URL (from the OneBot segment).
  final String? mediaUrl;

  /// File size in bytes (when known).
  final int? mediaSize;

  /// Local thumbnail path (images / videos).
  final String? thumbnailPath;

  /// MIME type, e.g. `image/png` or `audio/ogg`.
  final String? mediaMime;

  /// Emoji reactions on this message.
  final List<ImReaction>? reactions;

  /// ID of the message this message is replying to (from OneBot `reply` segment).
  final String? replyToMessageId;

  bool get hasMedia => mediaPath != null;
  bool get isReply => replyToMessageId != null;

  ImMessage copyWith({
    String? id,
    String? text,
    ImMessageStatus? status,
    String? mediaPath,
    String? thumbnailPath,
    List<ImReaction>? reactions,
  }) {
    return ImMessage(
      id: id ?? this.id,
      conversationId: conversationId,
      senderId: senderId,
      text: text ?? this.text,
      sentAt: sentAt,
      kind: kind,
      status: status ?? this.status,
      isMine: isMine,
      segments: segments,
      mediaPath: mediaPath ?? this.mediaPath,
      mediaUrl: mediaUrl,
      mediaSize: mediaSize,
      thumbnailPath: thumbnailPath ?? this.thumbnailPath,
      mediaMime: mediaMime,
      reactions: reactions ?? this.reactions,
      replyToMessageId: replyToMessageId ?? this.replyToMessageId,
    );
  }
}

/// An emoji reaction on a message.
class ImReaction {
  const ImReaction({required this.emojiId, required this.count});
  final String emojiId;
  final int count;
}
