import 'package:flutter/material.dart';

import '../../assets/app_assets.dart';
import '../../theme/zzz_colors.dart';
import '../../widgets/zzz_widgets.dart';
import '../models/im_models.dart';

class ConversationTile extends StatelessWidget {
  const ConversationTile({
    required this.conversation,
    required this.selected,
    required this.onTap,
    super.key,
  });

  final ImConversation conversation;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final avatarPath =
        conversation.avatarAssetPath ?? AppAssets.characterWise;
    final timeLabel = _formatTime(conversation.updatedAt);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color:
                selected
                    ? ZzzColors.yellow.withValues(alpha: 0.12)
                    : Colors.transparent,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: selected ? ZzzColors.yellow : Colors.transparent,
              width: 1.5,
            ),
          ),
          child: Row(
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  ZzzAvatar(
                    image: AssetImage(avatarPath),
                    size: 52,
                  ),
                  if (conversation.isGroup)
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
                          size: 12,
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
                            style: TextStyle(
                              fontWeight:
                                  conversation.unreadCount > 0
                                      ? FontWeight.w800
                                      : FontWeight.w600,
                              fontSize: 16,
                            ),
                          ),
                        ),
                        if (timeLabel != null)
                          Text(
                            timeLabel,
                            style: const TextStyle(
                              color: Colors.white38,
                              fontSize: 12,
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            conversation.subtitle ?? 'No messages yet',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color:
                                  conversation.unreadCount > 0
                                      ? Colors.white70
                                      : Colors.white38,
                              fontSize: 13,
                            ),
                          ),
                        ),
                        if (conversation.unreadCount > 0)
                          Container(
                            margin: const EdgeInsets.only(left: 8),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: ZzzColors.yellow,
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(
                              conversation.unreadCount > 99
                                  ? '99+'
                                  : '${conversation.unreadCount}',
                              style: const TextStyle(
                                color: Colors.black,
                                fontSize: 11,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                      ],
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

  String? _formatTime(DateTime? time) {
    if (time == null) return null;
    final now = DateTime.now();
    final diff = now.difference(time);
    if (diff.inMinutes < 1) return 'now';
    if (diff.inHours < 1) return '${diff.inMinutes}m';
    if (diff.inHours < 24) return '${diff.inHours}h';
    if (diff.inDays < 7) return '${diff.inDays}d';
    return '${time.month}/${time.day}';
  }
}
