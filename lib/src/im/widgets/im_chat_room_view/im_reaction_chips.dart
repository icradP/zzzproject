import 'package:flutter/material.dart';

import '../../models/im_models.dart';

/// Compact emoji reaction chips shown below a message bubble.
///
/// Styled after Telegram / QQ with small rounded pills and a distinct state
/// for the current user's reaction.
class ImReactionChips extends StatelessWidget {
  const ImReactionChips({
    required this.reactions,
    required this.isMine,
    this.onTap,
  });

  final List<ImReaction> reactions;
  final bool isMine;
  final ValueChanged<ImReaction>? onTap;

  static const emojiMap = <String, String>{
    '76': '👍',
    '66': '❤️',
    '63': '😂',
    '15': '😭',
    '12': '😊',
    '14': '😍',
    '2': '😢',
    '32': '😡',
    '4': '😲',
    '3': '😜',
    '21': '😘',
    '109': '👏',
    '5': '😴',
    '6': '😝',
    '10': '😎',
    '24': '🙏',
    '75': '💪',
    '33': '🤔',
    '0': '😮',
    '1': '😀',
    '74': '🌙',
    '59': '🍺',
    '53': '🎉',
  };

  static const emojiIds = <String>[
    '76',
    '66',
    '63',
    '15',
    '12',
    '14',
    '2',
    '32',
    '4',
    '3',
    '109',
    '24',
    '75',
    '33',
    '0',
    '1',
    '74',
    '59',
    '53',
  ];

  static String emojiFor(String id) => emojiMap[id] ?? '#$id';

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 3,
      runSpacing: 3,
      children: [
        for (final reaction in reactions)
          Material(
            color: Colors.transparent,
            child: InkWell(
              key: ValueKey('reaction-chip-${reaction.emojiId}'),
              onTap: onTap == null ? null : () => onTap!(reaction),
              borderRadius: BorderRadius.circular(12),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                decoration: BoxDecoration(
                  color:
                      reaction.reactedByMe
                          ? const Color(0xFF63551A)
                          : const Color(0xFF2A2A3A),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color:
                        reaction.reactedByMe ? Colors.amber : Colors.white10,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      emojiFor(reaction.emojiId),
                      style: const TextStyle(fontSize: 14),
                    ),
                    const SizedBox(width: 3),
                    Text(
                      '${reaction.count}',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: Colors.white.withValues(alpha: 0.6),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}
