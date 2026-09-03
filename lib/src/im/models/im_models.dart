import 'dart:typed_data';

import 'package:flutter/widgets.dart';

import 'package:onebot_flutter/src/onebot_models.dart'
    show OneBotMessageSegment;
import 'im_platform_image_provider.dart';

enum ImConversationType { direct, group }

enum ImConversationNotificationLevel { normal, mentionsOnly, muted }

ImConversationNotificationLevel imConversationNotificationLevelFromString(
  String? value, {
  bool legacyMuted = false,
}) => switch (value) {
  'mentions_only' => ImConversationNotificationLevel.mentionsOnly,
  'muted' => ImConversationNotificationLevel.muted,
  'normal' => ImConversationNotificationLevel.normal,
  _ =>
    legacyMuted
        ? ImConversationNotificationLevel.muted
        : ImConversationNotificationLevel.normal,
};

extension ImConversationNotificationLevelValue
    on ImConversationNotificationLevel {
  String get wireValue => switch (this) {
    ImConversationNotificationLevel.normal => 'normal',
    ImConversationNotificationLevel.mentionsOnly => 'mentions_only',
    ImConversationNotificationLevel.muted => 'muted',
  };
}

enum ImGroupRole { owner, admin, member }

ImGroupRole imGroupRoleFromString(String? value) => switch (value) {
  'owner' => ImGroupRole.owner,
  'admin' => ImGroupRole.admin,
  _ => ImGroupRole.member,
};

enum ImMessageStatus { sending, sent, delivered, read, failed }

/// Relationship between the signed-in user and another account.
enum ImRelationship { none, friend, incoming, outgoing, blocked, blockedBy }

ImRelationship imRelationshipFromString(String? value) => switch (value) {
  'friend' => ImRelationship.friend,
  'incoming' => ImRelationship.incoming,
  'outgoing' => ImRelationship.outgoing,
  'blocked' => ImRelationship.blocked,
  'blocked_by' => ImRelationship.blockedBy,
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
    this.duration,
  }) : assert(filePath != null || bytes != null);

  final ImMessageKind kind;
  final String fileName;
  final String? filePath;
  final Uint8List? bytes;
  final String? mimeType;
  final Duration? duration;
}

class ImLinkShare {
  const ImLinkShare({required this.url, required this.title});

  final Uri url;
  final String title;

  static ImLinkShare? tryParse(String value) {
    final trimmed = value.trim();
    if (trimmed.contains(RegExp(r'\s'))) return null;
    final uri = Uri.tryParse(trimmed);
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      return null;
    }
    return ImLinkShare(url: uri, title: uri.host);
  }
}

class ImLocationShare {
  const ImLocationShare({required this.name, this.latitude, this.longitude})
    : assert(
        (latitude == null && longitude == null) ||
            (latitude != null && longitude != null),
      );

  final String name;
  final double? latitude;
  final double? longitude;

  bool get hasCoordinates => latitude != null && longitude != null;
}

/// A user-authored text message split into visible text and semantic mentions.
///
/// Sources that support message segments can send mentions as native `at`
/// segments. Other sources fall back to [plainText] without losing what the
/// author saw in the composer.
class ImComposedText {
  const ImComposedText(this.parts);

  factory ImComposedText.plain(String text) =>
      ImComposedText([ImComposedTextPart.text(text)]);

  final List<ImComposedTextPart> parts;

  String get plainText => parts.map((part) => part.text).join();

  bool get hasMentions => parts.any((part) => part.isMention);

  ImComposedText mapMentionUserIds(String Function(String userId) transform) {
    return ImComposedText([
      for (final part in parts)
        part.isMention
            ? ImComposedTextPart.mention(
              userId: transform(part.mentionedUserId!),
              label: part.text,
            )
            : part,
    ]);
  }
}

class ImComposedTextPart {
  const ImComposedTextPart.text(this.text) : mentionedUserId = null;

  const ImComposedTextPart.mention({
    required String userId,
    required String label,
  }) : text = label,
       mentionedUserId = userId;

  final String text;
  final String? mentionedUserId;

  bool get isMention => mentionedUserId != null;
}

/// Stable reference to an application-bundled sticker asset.
///
/// The version is part of the identity so catalog updates can keep rendering
/// messages sent by older clients without storing or uploading image bytes.
class ImStickerReference {
  const ImStickerReference({
    required this.packId,
    required this.assetId,
    required this.version,
  });

  final String packId;
  final String assetId;
  final int version;

  Map<String, dynamic> toSegmentData() => {
    'pack_id': packId,
    'asset_id': assetId,
    'version': version,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ImStickerReference &&
          packId == other.packId &&
          assetId == other.assetId &&
          version == other.version;

  @override
  int get hashCode => Object.hash(packId, assetId, version);
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
    this.isBot = false,
    this.relationship = ImRelationship.none,
    this.bio = '',
    this.cardBackgroundUrl,
    this.cardBackgroundColor,
    this.cardBackgroundSensitive = false,
    this.showMutualGroups = true,
    this.showAccountId = true,
    this.titles = const [],
    this.mutualGroups = const [],
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
  final bool isBot;
  final ImRelationship relationship;
  final String bio;
  final String? cardBackgroundUrl;
  final String? cardBackgroundColor;
  final bool cardBackgroundSensitive;
  final bool showMutualGroups;
  final bool showAccountId;
  final List<ImUserTitle> titles;
  final List<ImMutualGroup> mutualGroups;
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
    bool? isBot,
    ImRelationship? relationship,
    String? bio,
    String? cardBackgroundUrl,
    String? cardBackgroundColor,
    bool clearCardBackground = false,
    bool? cardBackgroundSensitive,
    bool? showMutualGroups,
    bool? showAccountId,
    List<ImUserTitle>? titles,
    List<ImMutualGroup>? mutualGroups,
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
      isBot: isBot ?? this.isBot,
      relationship: relationship ?? this.relationship,
      bio: bio ?? this.bio,
      cardBackgroundUrl:
          clearCardBackground
              ? null
              : (cardBackgroundUrl ?? this.cardBackgroundUrl),
      cardBackgroundColor:
          clearCardBackground
              ? null
              : (cardBackgroundColor ?? this.cardBackgroundColor),
      cardBackgroundSensitive:
          cardBackgroundSensitive ?? this.cardBackgroundSensitive,
      showMutualGroups: showMutualGroups ?? this.showMutualGroups,
      showAccountId: showAccountId ?? this.showAccountId,
      titles: titles ?? this.titles,
      mutualGroups: mutualGroups ?? this.mutualGroups,
      sourceId: sourceId ?? this.sourceId,
      sourceLabel: sourceLabel ?? this.sourceLabel,
    );
  }
}

class ImUserTitle {
  const ImUserTitle({
    required this.id,
    required this.text,
    required this.style,
    required this.scopeType,
    this.scopeId,
    required this.grantedBy,
    this.expiresAt,
    this.createdAt,
  });

  final String id;
  final String text;
  final String style;
  final String scopeType;
  final String? scopeId;
  final String grantedBy;
  final DateTime? expiresAt;
  final DateTime? createdAt;

  bool get isAnimated => style == 'aurora' || style == 'ember';
  bool get isGroupScoped => scopeType == 'group';
}

class ImMutualGroup {
  const ImMutualGroup({
    required this.id,
    required this.name,
    this.avatarUrl,
    this.memberCount = 0,
  });

  final String id;
  final String name;
  final String? avatarUrl;
  final int memberCount;
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
    this.notificationLevel = ImConversationNotificationLevel.normal,
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
  final ImConversationNotificationLevel notificationLevel;
  final String? sourceId;
  final String? sourceLabel;

  bool get isGroup => type == ImConversationType.group;
  bool get isDirect => type == ImConversationType.direct;
  bool get isMuted =>
      notificationLevel == ImConversationNotificationLevel.muted;

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
    ImConversationNotificationLevel? notificationLevel,
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
      notificationLevel: notificationLevel ?? this.notificationLevel,
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

class ImGroupAnnouncement {
  const ImGroupAnnouncement({
    required this.id,
    required this.groupId,
    required this.content,
    required this.authorId,
    required this.createdAt,
    required this.updatedAt,
    this.isPinned = false,
    this.isRead = false,
  });

  final String id;
  final String groupId;
  final String content;
  final String authorId;
  final bool isPinned;
  final bool isRead;
  final DateTime createdAt;
  final DateTime updatedAt;

  ImGroupAnnouncement copyWith({
    String? content,
    bool? isPinned,
    bool? isRead,
    DateTime? updatedAt,
  }) => ImGroupAnnouncement(
    id: id,
    groupId: groupId,
    content: content ?? this.content,
    authorId: authorId,
    isPinned: isPinned ?? this.isPinned,
    isRead: isRead ?? this.isRead,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );
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
    this.announcements = const [],
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
  final List<ImGroupAnnouncement> announcements;
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
    this.senderDisplayName,
    this.kind = ImMessageKind.text,
    this.status = ImMessageStatus.sent,
    this.readCount = 0,
    this.recipientCount = 0,
    this.isMine = false,
    this.segments,
    this.mediaPath,
    this.mediaUrl,
    this.mediaSize,
    this.mediaWidth,
    this.mediaHeight,
    this.thumbnailPath,
    this.thumbnailUrl,
    this.mediaMime,
    this.mediaDuration,
    this.reactions,
    this.replyToMessageId,
    this.recalled = false,
    this.sourceId,
    this.sourceLabel,
  });

  final String id;
  final String conversationId;
  final String senderId;
  final String? senderDisplayName;

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

  /// Original image/video dimensions when supplied by the media server.
  final int? mediaWidth;
  final int? mediaHeight;

  /// Local thumbnail path (images / videos).
  final String? thumbnailPath;

  /// Remote thumbnail URL (usually generated by the ZZZ media server).
  final String? thumbnailUrl;

  /// MIME type, e.g. `image/png` or `audio/ogg`.
  final String? mediaMime;

  /// Voice/video duration supplied by the sender, when known.
  final Duration? mediaDuration;

  /// Emoji reactions on this message.
  final List<ImReaction>? reactions;

  /// ID of the message this message is replying to (from OneBot `reply` segment).
  final String? replyToMessageId;

  /// Whether this message has been recalled by the sender or an admin.
  final bool recalled;
  final String? sourceId;
  final String? sourceLabel;

  /// Remote or local media is available even before a native client downloads
  /// it to disk.
  bool get hasMedia => mediaPath != null || mediaUrl != null;
  bool get isReply => replyToMessageId != null;

  ImMessage copyWith({
    String? id,
    String? text,
    String? senderDisplayName,
    ImMessageStatus? status,
    int? readCount,
    int? recipientCount,
    String? mediaPath,
    String? thumbnailPath,
    String? thumbnailUrl,
    List<ImReaction>? reactions,
    bool? recalled,
    String? sourceId,
    String? sourceLabel,
  }) {
    return ImMessage(
      id: id ?? this.id,
      conversationId: conversationId,
      senderId: senderId,
      senderDisplayName: senderDisplayName ?? this.senderDisplayName,
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
      thumbnailUrl: thumbnailUrl ?? this.thumbnailUrl,
      mediaMime: mediaMime,
      mediaDuration: mediaDuration,
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
