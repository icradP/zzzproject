import 'package:flutter/material.dart';

import '../../theme/zzz_colors.dart';

class ImBotBadge extends StatelessWidget {
  const ImBotBadge({this.compact = false, super.key});

  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Bot account',
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 4 : 6,
          vertical: compact ? 2 : 3,
        ),
        decoration: BoxDecoration(
          color: ZzzColors.yellow.withValues(alpha: 0.14),
          border: Border.all(color: ZzzColors.yellow.withValues(alpha: 0.45)),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.smart_toy_outlined,
              size: compact ? 11 : 13,
              color: ZzzColors.yellow,
            ),
            const SizedBox(width: 3),
            Text(
              'BOT',
              style: TextStyle(
                color: ZzzColors.yellow,
                fontSize: compact ? 9 : 10,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
