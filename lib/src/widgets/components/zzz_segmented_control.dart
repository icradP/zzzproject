part of '../zzz_components.dart';

class ZzzSegmentItem<T> {
  const ZzzSegmentItem({
    required this.value,
    required this.tooltip,
    this.icon,
    this.iconAsset,
    this.enabled = true,
  }) : assert(icon != null || iconAsset != null);

  final T value;
  final String tooltip;
  final IconData? icon;
  final String? iconAsset;
  final bool enabled;
}

class ZzzSegmentedControl<T> extends StatelessWidget {
  const ZzzSegmentedControl({
    required this.items,
    required this.value,
    required this.onChanged,
    this.animated = true,
    super.key,
  });

  final List<ZzzSegmentItem<T>> items;
  final T value;
  final ValueChanged<T> onChanged;
  final bool animated;

  @override
  Widget build(BuildContext context) {
    final selectedIndex = items.indexWhere((item) => item.value == value);

    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(28),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final segmentWidth = constraints.maxWidth / items.length;

          return Stack(
            children: [
              if (selectedIndex >= 0)
                _ZzzSegmentIndicator(
                  animated: animated,
                  left: selectedIndex * segmentWidth,
                  width: segmentWidth,
                ),
              Row(
                children: [
                  for (final item in items)
                    Expanded(
                      child: _ZzzSegmentButton<T>(
                        item: item,
                        selected: item.value == value,
                        animated: animated,
                        onTap:
                            item.enabled ? () => onChanged(item.value) : null,
                      ),
                    ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}

class _ZzzSegmentIndicator extends StatelessWidget {
  const _ZzzSegmentIndicator({
    required this.animated,
    required this.left,
    required this.width,
  });

  final bool animated;
  final double left;
  final double width;

  @override
  Widget build(BuildContext context) {
    final indicator = Container(
      height: 42,
      decoration: BoxDecoration(
        color: ZzzColors.yellow,
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: ZzzColors.yellow.withValues(alpha: 0.35),
            blurRadius: 12,
          ),
        ],
      ),
    );

    if (!animated) {
      return Positioned(left: left, width: width, child: indicator);
    }

    return AnimatedPositioned(
      duration: _kZzzAnimSegment,
      curve: _kZzzCurve,
      left: left,
      width: width,
      child: TweenAnimationBuilder<double>(
        key: ValueKey(left),
        duration: _kZzzAnimSegment,
        curve: _kZzzBounce,
        tween: Tween(begin: 0.92, end: 1.0),
        builder: (context, scale, child) {
          return Transform.scale(scale: scale, child: child);
        },
        child: indicator,
      ),
    );
  }
}

class _ZzzSegmentButton<T> extends StatelessWidget {
  const _ZzzSegmentButton({
    required this.item,
    required this.selected,
    required this.animated,
    required this.onTap,
  });

  final ZzzSegmentItem<T> item;
  final bool selected;
  final bool animated;
  final VoidCallback? onTap;

  Color _foregroundColor() {
    if (!item.enabled) return Colors.white24;
    return selected ? Colors.black : Colors.white;
  }

  @override
  Widget build(BuildContext context) {
    final foreground = _foregroundColor();
    final duration = animated ? _kZzzAnimNormal : Duration.zero;

    return Tooltip(
      message: item.tooltip,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(24),
          onTap: onTap,
          child: SizedBox(
            height: 42,
            child: Center(
              child: TweenAnimationBuilder<double>(
                duration: duration,
                curve: _kZzzCurve,
                tween: Tween(end: selected ? 1.08 : 1),
                builder: (context, scale, child) {
                  return Transform.scale(scale: scale, child: child);
                },
                child: TweenAnimationBuilder<Color?>(
                  duration: duration,
                  curve: _kZzzCurve,
                  tween: ColorTween(end: foreground),
                  builder: (context, color, _) {
                    if (item.iconAsset == null) {
                      return Icon(item.icon, color: color);
                    }
                    return Image.asset(
                      item.iconAsset!,
                      height: 28,
                      color: color,
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
