import 'package:flutter/material.dart';

import '../../assets/app_assets.dart';
import '../../theme/zzz_colors.dart';
import '../../widgets/zzz_widgets.dart';
import '../models/im_models.dart';
import 'im_bot_badge.dart';
import 'im_source_badge.dart';

class ContactTile extends StatelessWidget {
  const ContactTile({required this.user, required this.onTap, super.key});

  final ImUser user;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final avatarImage = user.avatarImage(
      AppAssets.fallbackAvatarForId(user.id),
    );

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              ZzzAvatar(image: avatarImage, size: 46),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            user.displayName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        if (user.sourceLabel != null) ...[
                          const SizedBox(width: 6),
                          ImSourceBadge(sourceLabel: user.sourceLabel!),
                        ],
                        if (user.isBot) ...[
                          const SizedBox(width: 6),
                          const ImBotBadge(compact: true),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: user.isOnline ? ZzzColors.yellow : Colors.white24,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class SuggestedContactTile extends StatelessWidget {
  const SuggestedContactTile({
    required this.user,
    required this.onTap,
    required this.onAdd,
    this.adding = false,
    this.requested = false,
    super.key,
  });

  final ImUser user;
  final VoidCallback onTap;
  final VoidCallback onAdd;
  final bool adding;
  final bool requested;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white.withValues(alpha: 0.035),
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
          child: Row(
            children: [
              ZzzAvatar(
                image: user.avatarImage(AppAssets.fallbackAvatarForId(user.id)),
                size: 42,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            user.displayName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                        ),
                        const SizedBox(width: 6),
                        const ImBotBadge(compact: true),
                      ],
                    ),
                    const SizedBox(height: 2),
                    const Text(
                      'AI assistant',
                      style: TextStyle(color: Colors.white54, fontSize: 12),
                    ),
                  ],
                ),
              ),
              IconButton(
                key: ValueKey('add-suggested-${user.id}'),
                onPressed: adding || requested ? null : onAdd,
                tooltip:
                    adding
                        ? 'Sending request'
                        : requested
                        ? 'Request pending'
                        : 'Add friend',
                icon:
                    adding
                        ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                        : Icon(
                          requested
                              ? Icons.schedule_rounded
                              : Icons.person_add_alt_1_rounded,
                        ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class GroupTile extends StatelessWidget {
  const GroupTile({required this.conversation, required this.onTap, super.key});

  final ImConversation conversation;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final avatarImage = conversation.avatarImage(
      AppAssets.fallbackAvatarForId(conversation.id),
    );

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  ZzzAvatar(image: avatarImage, size: 46),
                  Positioned(
                    right: -2,
                    bottom: -2,
                    child: Container(
                      padding: const EdgeInsets.all(3),
                      decoration: BoxDecoration(
                        color: ZzzColors.blue,
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.black, width: 1.5),
                      ),
                      child: const Icon(
                        Icons.groups_rounded,
                        size: 10,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            conversation.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        if (conversation.sourceLabel != null) ...[
                          const SizedBox(width: 6),
                          ImSourceBadge(sourceLabel: conversation.sourceLabel!),
                        ],
                      ],
                    ),
                    if (conversation.participantIds.length > 1)
                      Text(
                        '${conversation.participantIds.length} members',
                        style: const TextStyle(
                          color: Colors.white38,
                          fontSize: 12,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
