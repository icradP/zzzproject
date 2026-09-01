import 'package:flutter/material.dart';

import '../../theme/zzz_colors.dart';

/// Compact, icon-only source marker. The complete source name remains
/// available through the tooltip and semantics label.
class ImSourceBadge extends StatelessWidget {
  const ImSourceBadge({
    required this.sourceLabel,
    this.color = ZzzColors.blue,
    this.size = 17,
    super.key,
  });

  final String sourceLabel;
  final Color color;
  final double size;

  IconData get _icon {
    final normalized = sourceLabel.toLowerCase();
    if (normalized.contains('zzz')) return Icons.dns_outlined;
    if (normalized.contains('qq') || normalized.contains('nonebot')) {
      return Icons.hub_outlined;
    }
    if (normalized.contains('mock') || normalized.contains('demo')) {
      return Icons.science_outlined;
    }
    return Icons.layers_outlined;
  }

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: sourceLabel,
      child: Semantics(
        label: 'Source: $sourceLabel',
        child: SizedBox.square(
          dimension: 22,
          child: Icon(_icon, size: size, color: color),
        ),
      ),
    );
  }
}
