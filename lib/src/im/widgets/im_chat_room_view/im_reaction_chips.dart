import 'package:flutter/material.dart';

import '../../models/im_models.dart';

/// Compact emoji reaction chips shown below a message bubble.
///
/// Styled after Telegram / QQ — small rounded pills with a card-like
/// background and subtle shadow.
class ImReactionChips extends StatelessWidget {
  const ImReactionChips({required this.reactions, required this.isMine});

  final List<ImReaction> reactions;
  final bool isMine;

  static const _emojiMap = <String, String>{
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

  String _emojiFor(String id) => _emojiMap[id] ?? '#$id';

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 3,
      runSpacing: 3,
      children: [
        for (final r in reactions)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
            decoration: BoxDecoration(
              color: const Color(0xFF2a2a3a),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.white10),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _emojiFor(r.emojiId),
                  style: const TextStyle(fontSize: 14),
                ),
                const SizedBox(width: 3),
                Text(
                  '${r.count}',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: Colors.white.withValues(alpha: 0.6),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
