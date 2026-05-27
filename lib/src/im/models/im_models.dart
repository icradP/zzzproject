import 'dart:typed_data';

enum ImConversationType { direct, group }

enum ImMessageStatus { sending, sent, delivered, read, failed }

enum ImMessageKind { text, image, system, poke }

/// A contact or the signed-in user.
class ImUser {
  const ImUser({
    required this.id,
    required this.displayName,
    this.avatarAssetPath,
    this.avatarBytes,
    this.isOnline = false,
  });

  final String id;
  final String displayName;
  final String? avatarAssetPath;
  final Uint8List? avatarBytes;
  final bool isOnline;

  ImUser copyWith({
    String? displayName,
    String? avatarAssetPath,
    Uint8List? avatarBytes,
    bool? isOnline,
  }) {
    return ImUser(
      id: id,
      displayName: displayName ?? this.displayName,
      avatarAssetPath: avatarAssetPath ?? this.avatarAssetPath,
      avatarBytes: avatarBytes ?? this.avatarBytes,
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
  final DateTime? updatedAt;
  final int unreadCount;
  final bool isPinned;

  bool get isGroup => type == ImConversationType.group;

  ImConversation copyWith({
    String? title,
    String? subtitle,
    String? avatarAssetPath,
    DateTime? updatedAt,
    int? unreadCount,
    bool? isPinned,
  }) {
    return ImConversation(
      id: id,
      type: type,
      title: title ?? this.title,
      participantIds: participantIds,
      subtitle: subtitle ?? this.subtitle,
      avatarAssetPath: avatarAssetPath ?? this.avatarAssetPath,
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
  });

  final String id;
  final String conversationId;
  final String senderId;
  final String text;
  final DateTime sentAt;
  final ImMessageKind kind;
  final ImMessageStatus status;
  final bool isMine;

  ImMessage copyWith({
    String? id,
    String? text,
    ImMessageStatus? status,
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
    );
  }
}
