import 'dart:typed_data';

import 'package:flutter/widgets.dart';

import 'package:onebot_flutter/src/onebot_models.dart'
    show OneBotMessageSegment;
import 'im_platform_image_provider.dart';

enum ImConversationType { direct, group }

enum ImGroupRole { owner, admin, member }

ImGroupRole imGroupRoleFromString(String? value) => switch (value) {
  'owner' => ImGroupRole.owner,
  'admin' => ImGroupRole.admin,
  _ => ImGroupRole.member,
};

enum ImMessageStatus { sending, sent, delivered, read, failed }

/// Relationship between the signed-in user and another account.
enum ImRelationship { none, friend, incoming, outgoing }

ImRelationship imRelationshipFromString(String? value) => switch (value) {
  'friend' => ImRelationship.friend,
  'incoming' => ImRelationship.incoming,
  'outgoing' => ImRelationship.outgoing,
  _ => ImRelationship.none,
};

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
  json,
  system,
  poke,
}

class ImMediaUpload {
  const ImMediaUpload({
    required this.kind,
    required this.fileName,
    this.filePath,
    this.bytes,
    this.mimeType,
  }) : assert(filePath != null || bytes != null);

  final ImMessageKind kind;
  final String fileName;
  final String? filePath;
  final Uint8List? bytes;
  final String? mimeType;
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
    this.relationship = ImRelationship.none,
    this.sourceId,
    this.sourceLabel,
  });

  final String id;
  final String displayName;
  final String? avatarAssetPath;
  final Uint8List? avatarBytes;

  /// Local file path to a downloaded avatar (e.g. QQ avatar cached to disk).
  final String? avatarLocalPath;
  final bool isOnline;
  final ImRelationship relationship;
  final String? sourceId;
  final String? sourceLabel;

  /// Builds an [ImageProvider] for this user's avatar, trying local file
  /// cache first, then asset path, then [fallbackAsset].
  ImageProvider avatarImage(String fallbackAsset) {
    if (avatarLocalPath != null) {
      return createFileImageProvider(avatarLocalPath!);
    }
    if (avatarBytes != null) return MemoryImage(avatarBytes!);
    final remote = avatarAssetPath;
    final parsed = remote == null ? null : Uri.tryParse(remote);
    if (parsed != null &&
        (parsed.scheme == 'http' || parsed.scheme == 'https')) {
      return NetworkImage(remote!);
    }
    return AssetImage(avatarAssetPath ?? fallbackAsset);
  }

  ImUser copyWith({
    String? displayName,
    String? avatarAssetPath,
    Uint8List? avatarBytes,
    String? avatarLocalPath,
    bool? isOnline,
    ImRelationship? relationship,
    String? sourceId,
    String? sourceLabel,
  }) {
    return ImUser(
      id: id,
      displayName: displayName ?? this.displayName,
      avatarAssetPath: avatarAssetPath ?? this.avatarAssetPath,
      avatarBytes: avatarBytes ?? this.avatarBytes,
      avatarLocalPath: avatarLocalPath ?? this.avatarLocalPath,
      isOnline: isOnline ?? this.isOnline,
      relationship: relationship ?? this.relationship,
      sourceId: sourceId ?? this.sourceId,
      sourceLabel: sourceLabel ?? this.sourceLabel,
    );
  }
}

/// A pending incoming or outgoing friend request.
class ImFriendRequest {
  const ImFriendRequest({
    required this.id,
    required this.fromUser,
    required this.toUser,
    this.comment = '',
    this.status = 'pending',
    this.createdAt,
    this.sourceId,
    this.sourceLabel,
  });

  final String id;
  final ImUser fromUser;
  final ImUser toUser;
  final String comment;
  final String status;
  final DateTime? createdAt;
  final String? sourceId;
  final String? sourceLabel;

  bool get isPending => status == 'pending';
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
    this.sourceId,
    this.sourceLabel,
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
  final String? sourceId;
  final String? sourceLabel;

  bool get isGroup => type == ImConversationType.group;
  bool get isDirect => type == ImConversationType.direct;

  /// Builds an [ImageProvider] for this conversation's avatar, checking
  /// local file cache first, then asset path.
  ImageProvider avatarImage(String fallbackAsset) {
    if (avatarLocalPath != null) {
      return createFileImageProvider(avatarLocalPath!);
    }
    final remote = avatarAssetPath;
    final parsed = remote == null ? null : Uri.tryParse(remote);
    if (parsed != null &&
        (parsed.scheme == 'http' || parsed.scheme == 'https')) {
      return NetworkImage(remote!);
    }
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
    String? sourceId,
    String? sourceLabel,
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
      sourceId: sourceId ?? this.sourceId,
      sourceLabel: sourceLabel ?? this.sourceLabel,
    );
  }
}

class ImGroupMember {
  const ImGroupMember({
    required this.user,
    required this.role,
    this.joinedAt,
    this.mutedUntil,
  });

  final ImUser user;
  final ImGroupRole role;
  final DateTime? joinedAt;
  final DateTime? mutedUntil;

  bool get isMuted => mutedUntil?.isAfter(DateTime.now()) ?? false;
}

class ImGroupDetails {
  const ImGroupDetails({
    required this.conversation,
    required this.members,
    required this.currentUserId,
    required this.supportsInvites,
    required this.supportsMemberRemoval,
    required this.canLeave,
    this.announcement = '',
    this.muteAll = false,
    this.supportsNameEditing = false,
    this.supportsAvatarEditing = false,
    this.supportsAnnouncementEditing = false,
    this.supportsAdminManagement = false,
    this.supportsMemberMuting = false,
    this.supportsWholeGroupMute = false,
    this.supportsOwnershipTransfer = false,
    this.supportsDismissal = false,
  });

  final ImConversation conversation;
  final List<ImGroupMember> members;
  final String currentUserId;
  final bool supportsInvites;
  final bool supportsMemberRemoval;
  final bool canLeave;
  final String announcement;
  final bool muteAll;
  final bool supportsNameEditing;
  final bool supportsAvatarEditing;
  final bool supportsAnnouncementEditing;
  final bool supportsAdminManagement;
  final bool supportsMemberMuting;
  final bool supportsWholeGroupMute;
  final bool supportsOwnershipTransfer;
  final bool supportsDismissal;

  ImGroupMember? get currentMember {
    for (final member in members) {
      if (member.user.id == currentUserId) return member;
    }
    return null;
  }

  bool get canInviteMembers {
    final role = currentMember?.role;
    return supportsInvites &&
        (role == ImGroupRole.owner || role == ImGroupRole.admin);
  }

  bool get currentUserIsManager {
    final role = currentMember?.role;
    return role == ImGroupRole.owner || role == ImGroupRole.admin;
  }

  bool get canEditSettings =>
      currentUserIsManager &&
      (supportsNameEditing ||
          supportsAvatarEditing ||
          supportsAnnouncementEditing ||
          supportsWholeGroupMute);

  bool get canManageAdmins =>
      supportsAdminManagement && currentMember?.role == ImGroupRole.owner;

  bool get canTransferOwnership =>
      supportsOwnershipTransfer && currentMember?.role == ImGroupRole.owner;

  bool get canDismiss =>
      supportsDismissal && currentMember?.role == ImGroupRole.owner;

  bool canRemoveMember(ImGroupMember target) {
    if (!supportsMemberRemoval || target.user.id == currentUserId) return false;
    final actorRole = currentMember?.role;
    if (actorRole == ImGroupRole.owner) {
      return target.role != ImGroupRole.owner;
    }
    return actorRole == ImGroupRole.admin && target.role == ImGroupRole.member;
  }

  bool canSetAdministrator(ImGroupMember target) =>
      canManageAdmins &&
      target.user.id != currentUserId &&
      target.role != ImGroupRole.owner;

  bool canMuteMember(ImGroupMember target) {
    if (!supportsMemberMuting || target.user.id == currentUserId) return false;
    final actorRole = currentMember?.role;
    if (actorRole == ImGroupRole.owner) {
      return target.role != ImGroupRole.owner;
    }
    return actorRole == ImGroupRole.admin && target.role == ImGroupRole.member;
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
    this.readCount = 0,
    this.recipientCount = 0,
    this.isMine = false,
    this.segments,
    this.mediaPath,
    this.mediaUrl,
    this.mediaSize,
    this.thumbnailPath,
    this.mediaMime,
    this.reactions,
    this.replyToMessageId,
    this.recalled = false,
    this.sourceId,
    this.sourceLabel,
  });

  final String id;
  final String conversationId;
  final String senderId;

  /// Human-readable display text (already resolved, e.g. `@Alice hi`).
  final String text;
  final DateTime sentAt;
  final ImMessageKind kind;
  final ImMessageStatus status;
  final int readCount;
  final int recipientCount;
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

  /// Whether this message has been recalled by the sender or an admin.
  final bool recalled;
  final String? sourceId;
  final String? sourceLabel;

  bool get hasMedia => mediaPath != null;
  bool get isReply => replyToMessageId != null;

  ImMessage copyWith({
    String? id,
    String? text,
    ImMessageStatus? status,
    int? readCount,
    int? recipientCount,
    String? mediaPath,
    String? thumbnailPath,
    List<ImReaction>? reactions,
    bool? recalled,
    String? sourceId,
    String? sourceLabel,
  }) {
    return ImMessage(
      id: id ?? this.id,
      conversationId: conversationId,
      senderId: senderId,
      text: text ?? this.text,
      sentAt: sentAt,
      kind: kind,
      status: status ?? this.status,
      readCount: readCount ?? this.readCount,
      recipientCount: recipientCount ?? this.recipientCount,
      isMine: isMine,
      segments: segments,
      mediaPath: mediaPath ?? this.mediaPath,
      mediaUrl: mediaUrl,
      mediaSize: mediaSize,
      thumbnailPath: thumbnailPath ?? this.thumbnailPath,
      mediaMime: mediaMime,
      reactions: reactions ?? this.reactions,
      replyToMessageId: replyToMessageId ?? this.replyToMessageId,
      recalled: recalled ?? this.recalled,
      sourceId: sourceId ?? this.sourceId,
      sourceLabel: sourceLabel ?? this.sourceLabel,
    );
  }
}

/// An emoji reaction on a message.
class ImReaction {
  const ImReaction({
    required this.emojiId,
    required this.count,
    this.reactedByMe = false,
  });
  final String emojiId;
  final int count;
  final bool reactedByMe;

  ImReaction copyWith({int? count, bool? reactedByMe}) => ImReaction(
    emojiId: emojiId,
    count: count ?? this.count,
    reactedByMe: reactedByMe ?? this.reactedByMe,
  );
}

/// A tree of forwarded messages.
///
/// Used by both OneBot (NapCat) and ZzzServer sources to represent
/// combined forward message groups.
class ForwardGroup {
  const ForwardGroup({
    this.title,
    this.senderName,
    this.messages = const [],
    this.children = const [],
  });

  final String? title;
  final String? senderName;
  final List<ImMessage> messages;
  final List<ForwardGroup> children;

  bool get isEmpty => messages.isEmpty && children.every((c) => c.isEmpty);
}
