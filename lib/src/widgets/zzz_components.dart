import 'package:flutter/material.dart';

import '../theme/zzz_colors.dart';

const Duration _kZzzAnimFast = Duration(milliseconds: 120);
const Duration _kZzzAnimNormal = Duration(milliseconds: 220);
const Duration _kZzzAnimSegment = Duration(milliseconds: 280);
const Duration _kZzzAnimExpand = Duration(milliseconds: 320);
const Curve _kZzzCurve = Curves.easeOutCubic;
const Curve _kZzzBounce = Cubic(0.34, 1.56, 0.64, 1);

Duration _zzzDuration(bool animated, [Duration duration = _kZzzAnimNormal]) {
  return animated ? duration : Duration.zero;
}

class ZzzPanel extends StatefulWidget {
  const ZzzPanel({
    required this.child,
    this.background,
    this.padding = const EdgeInsets.all(16),
    this.radius = 18,
    this.animateEntrance = false,
    super.key,
  });

  final Widget child;
  final DecorationImage? background;
  final EdgeInsetsGeometry padding;
  final double radius;
  final bool animateEntrance;

  @override
  State<ZzzPanel> createState() => _ZzzPanelState();
}

class _ZzzPanelState extends State<ZzzPanel>
    with SingleTickerProviderStateMixin {
  late final AnimationController _entranceController;
  late final Animation<double> _entranceOpacity;
  late final Animation<Offset> _entranceOffset;

  @override
  void initState() {
    super.initState();
    _entranceController = AnimationController(
      vsync: this,
      duration: _kZzzAnimExpand,
    );
    final curve = CurvedAnimation(
      parent: _entranceController,
      curve: _kZzzCurve,
    );
    _entranceOpacity = curve;
    _entranceOffset = Tween<Offset>(
      begin: const Offset(0, 0.04),
      end: Offset.zero,
    ).animate(curve);
    if (widget.animateEntrance) {
      _entranceController.forward();
    } else {
      _entranceController.value = 1;
    }
  }

  @override
  void didUpdateWidget(covariant ZzzPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.animateEntrance && !oldWidget.animateEntrance) {
      _entranceController.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _entranceController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final panel = Container(
      padding: widget.padding,
      decoration: BoxDecoration(
        color: ZzzColors.panel,
        borderRadius: BorderRadius.circular(widget.radius),
        border: Border.all(color: Colors.white12),
        image: widget.background,
      ),
      child: widget.child,
    );

    if (!widget.animateEntrance) return panel;

    return FadeTransition(
      opacity: _entranceOpacity,
      child: SlideTransition(position: _entranceOffset, child: panel),
    );
  }
}

/// Height + fade reveal for expandable bodies.
///
/// Uses [SizeTransition] instead of [AnimatedSize] to avoid re-entrant layout
/// when nested with other animated size widgets (e.g. [ZzzAnimatedSwap]).
class ZzzReveal extends StatefulWidget {
  const ZzzReveal({
    required this.expanded,
    required this.child,
    this.animated = true,
    this.duration = _kZzzAnimExpand,
    super.key,
  });

  final bool expanded;
  final Widget child;
  final bool animated;
  final Duration duration;

  @override
  State<ZzzReveal> createState() => _ZzzRevealState();
}

class _ZzzRevealState extends State<ZzzReveal>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _sizeAnimation;
  late Animation<double> _popScale;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: _zzzDuration(widget.animated, widget.duration),
    );
    _sizeAnimation = CurvedAnimation(parent: _controller, curve: _kZzzCurve);
    _popScale = Tween<double>(
      begin: 0.96,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _controller, curve: _kZzzBounce));
    if (widget.expanded) {
      _controller.value = 1;
    }
  }

  @override
  void didUpdateWidget(covariant ZzzReveal oldWidget) {
    super.didUpdateWidget(oldWidget);
    _controller.duration = _zzzDuration(widget.animated, widget.duration);
    if (widget.expanded != oldWidget.expanded) {
      if (widget.expanded) {
        _controller.forward();
      } else {
        _controller.reverse();
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: SizeTransition(
        axisAlignment: -1,
        sizeFactor: _sizeAnimation,
        child: FadeTransition(
          opacity: _sizeAnimation,
          child: ScaleTransition(scale: _popScale, child: widget.child),
        ),
      ),
    );
  }
}

/// Titled section with animated expand / collapse.
class ZzzExpandableSection extends StatefulWidget {
  const ZzzExpandableSection({
    required this.title,
    required this.child,
    this.subtitle,
    this.initiallyExpanded = true,
    this.animated = true,
    this.onExpansionChanged,
    super.key,
  });

  final String title;
  final String? subtitle;
  final Widget child;
  final bool initiallyExpanded;
  final bool animated;
  final ValueChanged<bool>? onExpansionChanged;

  @override
  State<ZzzExpandableSection> createState() => _ZzzExpandableSectionState();
}

class _ZzzExpandableSectionState extends State<ZzzExpandableSection> {
  late bool _expanded;
  bool _headerPressed = false;

  @override
  void initState() {
    super.initState();
    _expanded = widget.initiallyExpanded;
  }

  void _toggle() {
    setState(() => _expanded = !_expanded);
    widget.onExpansionChanged?.call(_expanded);
  }

  @override
  Widget build(BuildContext context) {
    final duration = _zzzDuration(widget.animated);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GestureDetector(
          onTapDown: (_) => setState(() => _headerPressed = true),
          onTapUp: (_) {
            setState(() => _headerPressed = false);
            _toggle();
          },
          onTapCancel: () => setState(() => _headerPressed = false),
          child: AnimatedScale(
            scale: _headerPressed ? 0.985 : 1,
            duration: _kZzzAnimFast,
            curve: _kZzzCurve,
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: null,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              widget.title,
                              style: const TextStyle(
                                color: Colors.white70,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            if (widget.subtitle != null) ...[
                              const SizedBox(height: 2),
                              Text(
                                widget.subtitle!,
                                style: const TextStyle(
                                  color: Colors.white38,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      AnimatedRotation(
                        duration: duration,
                        curve: _kZzzCurve,
                        turns: _expanded ? 0.5 : 0,
                        child: const Icon(
                          Icons.expand_more_rounded,
                          color: Colors.white54,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        ZzzReveal(
          expanded: _expanded,
          animated: widget.animated,
          child: Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: widget.child,
          ),
        ),
      ],
    );
  }
}

/// [ZzzPanel] with a collapsible header and animated body.
class ZzzExpandablePanel extends StatelessWidget {
  const ZzzExpandablePanel({
    required this.title,
    required this.child,
    this.subtitle,
    this.background,
    this.padding = const EdgeInsets.all(16),
    this.radius = 18,
    this.initiallyExpanded = true,
    this.animated = true,
    super.key,
  });

  final String title;
  final String? subtitle;
  final Widget child;
  final DecorationImage? background;
  final EdgeInsetsGeometry padding;
  final double radius;
  final bool initiallyExpanded;
  final bool animated;

  @override
  Widget build(BuildContext context) {
    return ZzzPanel(
      background: background,
      padding: padding,
      radius: radius,
      child: ZzzExpandableSection(
        title: title,
        subtitle: subtitle,
        initiallyExpanded: initiallyExpanded,
        animated: animated,
        child: child,
      ),
    );
  }
}

/// Cross-fades and slides when [value] changes.
class ZzzAnimatedSwap extends StatelessWidget {
  const ZzzAnimatedSwap({
    required this.value,
    required this.builder,
    this.animated = true,
    super.key,
  });

  final Object value;
  final Widget Function(BuildContext context) builder;
  final bool animated;

  @override
  Widget build(BuildContext context) {
    final duration = _zzzDuration(animated);

    return AnimatedSwitcher(
      duration: duration,
      switchInCurve: _kZzzCurve,
      switchOutCurve: Curves.easeInCubic,
      layoutBuilder: (currentChild, previousChildren) {
        return Stack(
          alignment: Alignment.topCenter,
          clipBehavior: Clip.hardEdge,
          children: [
            ...previousChildren,
            if (currentChild != null) currentChild,
          ],
        );
      },
      transitionBuilder: (child, animation) {
        final offsetAnimation = Tween<Offset>(
          begin: const Offset(0, 0.05),
          end: Offset.zero,
        ).animate(CurvedAnimation(parent: animation, curve: _kZzzCurve));
        return FadeTransition(
          opacity: animation,
          child: SlideTransition(position: offsetAnimation, child: child),
        );
      },
      child: KeyedSubtree(key: ValueKey(value), child: builder(context)),
    );
  }
}

class ZzzSectionLabel extends StatelessWidget {
  const ZzzSectionLabel({required this.label, this.animated = true, super.key});

  final String label;
  final bool animated;

  @override
  Widget build(BuildContext context) {
    final content = Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Row(
        children: [
          const Expanded(child: Divider(color: Colors.white24)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(label, style: const TextStyle(color: Colors.white54)),
          ),
          const Expanded(child: Divider(color: Colors.white24)),
        ],
      ),
    );

    if (!animated) return content;

    return TweenAnimationBuilder<double>(
      duration: _kZzzAnimNormal,
      curve: _kZzzCurve,
      tween: Tween(begin: 0, end: 1),
      builder: (context, value, child) {
        return Opacity(opacity: value, child: child);
      },
      child: content,
    );
  }
}

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

class ZzzAvatar extends StatefulWidget {
  const ZzzAvatar({
    required this.image,
    required this.size,
    this.backgroundColor = Colors.white,
    this.animateEntrance = false,
    super.key,
  });

  final ImageProvider image;
  final double size;
  final Color backgroundColor;
  final bool animateEntrance;

  @override
  State<ZzzAvatar> createState() => _ZzzAvatarState();
}

class _ZzzAvatarState extends State<ZzzAvatar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _entranceController;
  late final Animation<double> _entranceScale;

  @override
  void initState() {
    super.initState();
    _entranceController = AnimationController(
      vsync: this,
      duration: _kZzzAnimExpand,
    );
    _entranceScale = CurvedAnimation(
      parent: _entranceController,
      curve: _kZzzBounce,
    );
    if (widget.animateEntrance) {
      _entranceController.forward();
    } else {
      _entranceController.value = 1;
    }
  }

  @override
  void dispose() {
    _entranceController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final avatar = CircleAvatar(
      radius: widget.size / 2,
      backgroundColor: widget.backgroundColor,
      backgroundImage: widget.image,
    );

    if (!widget.animateEntrance) return avatar;

    return ScaleTransition(scale: _entranceScale, child: avatar);
  }
}

class ZzzPillButton extends StatefulWidget {
  const ZzzPillButton({
    required this.title,
    required this.onPressed,
    this.subtitle,
    this.leading,
    this.animated = true,
    this.animateEntrance = false,
    this.backgroundColor = ZzzColors.yellow,
    this.foregroundColor = Colors.black,
    super.key,
  });

  final String title;
  final String? subtitle;
  final Widget? leading;
  final VoidCallback onPressed;
  final bool animated;
  final bool animateEntrance;
  final Color backgroundColor;
  final Color foregroundColor;

  @override
  State<ZzzPillButton> createState() => _ZzzPillButtonState();
}

class _ZzzPillButtonState extends State<ZzzPillButton>
    with SingleTickerProviderStateMixin {
  bool _pressed = false;
  late final AnimationController _entranceController;
  late final Animation<double> _entranceOpacity;
  late final Animation<Offset> _entranceOffset;

  @override
  void initState() {
    super.initState();
    _entranceController = AnimationController(
      vsync: this,
      duration: _kZzzAnimExpand,
    );
    final curve = CurvedAnimation(
      parent: _entranceController,
      curve: _kZzzBounce,
    );
    _entranceOpacity = curve;
    _entranceOffset = Tween<Offset>(
      begin: const Offset(0, 0.06),
      end: Offset.zero,
    ).animate(curve);
    if (widget.animateEntrance) {
      _entranceController.forward();
    } else {
      _entranceController.value = 1;
    }
  }

  @override
  void dispose() {
    _entranceController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scale = widget.animated && _pressed ? 0.97 : 1.0;

    final button = FilledButton(
      style: FilledButton.styleFrom(
        backgroundColor: widget.backgroundColor,
        foregroundColor: widget.foregroundColor,
        padding: const EdgeInsets.all(8),
        minimumSize: const Size.fromHeight(66),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(36)),
        shadowColor:
            widget.animated ? widget.backgroundColor : Colors.transparent,
        animationDuration: _kZzzAnimNormal,
      ),
      onPressed: widget.onPressed,
      child: Row(
        children: [
          if (widget.leading != null) ...[
            widget.leading!,
            const SizedBox(width: 12),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  widget.title,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                if (widget.subtitle != null)
                  Text(
                    widget.subtitle!,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: widget.foregroundColor.withValues(alpha: 0.48),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );

    final content = Listener(
      onPointerDown: (_) => setState(() => _pressed = true),
      onPointerUp: (_) => setState(() => _pressed = false),
      onPointerCancel: (_) => setState(() => _pressed = false),
      child: AnimatedScale(
        scale: scale,
        duration: _kZzzAnimFast,
        curve: _kZzzCurve,
        child: button,
      ),
    );

    if (!widget.animateEntrance) return content;

    return FadeTransition(
      opacity: _entranceOpacity,
      child: SlideTransition(position: _entranceOffset, child: content),
    );
  }
}

class ZzzTextAction extends StatefulWidget {
  const ZzzTextAction({
    required this.icon,
    required this.label,
    required this.onTap,
    super.key,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  State<ZzzTextAction> createState() => _ZzzTextActionState();
}

class _ZzzTextActionState extends State<ZzzTextAction> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      child: AnimatedSlide(
        duration: _kZzzAnimFast,
        curve: _kZzzCurve,
        offset: _pressed ? const Offset(0, 0.03) : Offset.zero,
        child: AnimatedScale(
          scale: _pressed ? 0.97 : 1,
          duration: _kZzzAnimFast,
          curve: _kZzzCurve,
          child: TextButton.icon(
            onPressed: null,
            icon: Icon(widget.icon, size: 20),
            label: Text(widget.label),
            style: TextButton.styleFrom(
              foregroundColor: Colors.white38,
              minimumSize: const Size.fromHeight(40),
              animationDuration: _kZzzAnimNormal,
            ).copyWith(
              overlayColor: WidgetStateProperty.resolveWith((states) {
                if (states.contains(WidgetState.pressed)) {
                  return Colors.white.withValues(alpha: 0.12);
                }
                if (states.contains(WidgetState.hovered)) {
                  return Colors.white.withValues(alpha: 0.06);
                }
                return null;
              }),
            ),
          ),
        ),
      ),
    );
  }
}

class ZzzSelectableAvatar extends StatefulWidget {
  const ZzzSelectableAvatar({
    required this.image,
    required this.label,
    required this.selected,
    required this.onSelect,
    this.onRemove,
    this.size = 58,
    super.key,
  });

  final ImageProvider image;
  final String label;
  final bool selected;
  final VoidCallback onSelect;
  final VoidCallback? onRemove;
  final double size;

  @override
  State<ZzzSelectableAvatar> createState() => _ZzzSelectableAvatarState();
}

class _ZzzSelectableAvatarState extends State<ZzzSelectableAvatar> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final removeVisible = widget.onRemove != null && _hovered;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: SizedBox(
        width: widget.size + 16,
        child: Column(
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                InkWell(
                  onTap: widget.onSelect,
                  customBorder: const CircleBorder(),
                  child: AnimatedContainer(
                    duration: _kZzzAnimNormal,
                    curve: _kZzzCurve,
                    padding: EdgeInsets.all(widget.selected ? 4 : 2),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color:
                          widget.selected ? ZzzColors.yellow : Colors.white24,
                      boxShadow:
                          widget.selected
                              ? [
                                BoxShadow(
                                  color: ZzzColors.yellow.withValues(
                                    alpha: 0.3,
                                  ),
                                  blurRadius: 10,
                                ),
                              ]
                              : null,
                    ),
                    child: AnimatedScale(
                      duration: _kZzzAnimExpand,
                      curve: widget.selected ? _kZzzBounce : _kZzzCurve,
                      scale: widget.selected ? 1 : 0.94,
                      child: ZzzAvatar(image: widget.image, size: widget.size),
                    ),
                  ),
                ),
                if (widget.onRemove != null)
                  Positioned(
                    top: -8,
                    right: -8,
                    child: IgnorePointer(
                      ignoring: !removeVisible,
                      child: AnimatedOpacity(
                        opacity: removeVisible ? 1 : 0,
                        duration: _kZzzAnimNormal,
                        curve: Curves.easeOutCubic,
                        child: AnimatedSlide(
                          offset:
                              removeVisible
                                  ? Offset.zero
                                  : const Offset(0.16, -0.16),
                          duration: _kZzzAnimNormal,
                          curve: _kZzzCurve,
                          child: AnimatedScale(
                            scale: removeVisible ? 1 : 0.62,
                            duration: _kZzzAnimNormal,
                            curve: _kZzzBounce,
                            child: IconButton.filled(
                              tooltip: 'Remove',
                              onPressed: widget.onRemove,
                              style: IconButton.styleFrom(
                                backgroundColor: ZzzColors.red,
                                minimumSize: const Size(28, 28),
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                              icon: const Icon(Icons.close_rounded, size: 16),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              widget.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 11, color: Colors.white70),
            ),
          ],
        ),
      ),
    );
  }
}

class ZzzTextInput extends StatefulWidget {
  const ZzzTextInput({
    this.controller,
    this.hintText,
    this.prefixIcon,
    this.minLines = 1,
    this.maxLines = 1,
    this.autofocus = false,
    this.textInputAction,
    this.onChanged,
    this.onSubmitted,
    this.style,
    this.fillColor = Colors.white,
    this.foregroundColor = Colors.black,
    super.key,
  });

  final TextEditingController? controller;
  final String? hintText;
  final Widget? prefixIcon;
  final int minLines;
  final int maxLines;
  final bool autofocus;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final TextStyle? style;
  final Color fillColor;
  final Color foregroundColor;

  @override
  State<ZzzTextInput> createState() => _ZzzTextInputState();
}

class _ZzzTextInputState extends State<ZzzTextInput> {
  late final FocusNode _focusNode;
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    _focusNode = FocusNode();
    _focusNode.addListener(() {
      if (_focusNode.hasFocus != _focused) {
        setState(() => _focused = _focusNode.hasFocus);
      }
    });
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: _kZzzAnimNormal,
      curve: _kZzzCurve,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        boxShadow:
            _focused
                ? [
                  BoxShadow(
                    color: ZzzColors.yellow.withValues(alpha: 0.35),
                    blurRadius: 16,
                    spreadRadius: 1,
                  ),
                ]
                : null,
      ),
      child: TextField(
        controller: widget.controller,
        focusNode: _focusNode,
        minLines: widget.minLines,
        maxLines: widget.maxLines,
        autofocus: widget.autofocus,
        textInputAction: widget.textInputAction,
        decoration: InputDecoration(
          hintText: widget.hintText,
          prefixIcon: widget.prefixIcon,
          filled: true,
          fillColor: widget.fillColor,
          hintStyle: TextStyle(
            color: widget.foregroundColor.withValues(alpha: 0.45),
          ),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 18,
            vertical: 14,
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(28),
            borderSide: BorderSide.none,
          ),
        ),
        style: widget.style ?? TextStyle(color: widget.foregroundColor),
        onChanged: widget.onChanged,
        onSubmitted: widget.onSubmitted,
      ),
    );
  }
}

class ZzzSelectItem<T> {
  const ZzzSelectItem({required this.value, required this.label, this.leading});

  final T value;
  final String label;
  final Widget? leading;
}

class ZzzSelect<T> extends StatelessWidget {
  const ZzzSelect({
    required this.value,
    required this.items,
    required this.onChanged,
    this.labelText,
    super.key,
  });

  final T value;
  final List<ZzzSelectItem<T>> items;
  final ValueChanged<T> onChanged;
  final String? labelText;

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<T>(
      value: value,
      dropdownColor: ZzzColors.grayPanel,
      decoration: InputDecoration(
        isDense: true,
        labelText: labelText,
        border: const OutlineInputBorder(),
      ),
      items:
          items
              .map(
                (item) => DropdownMenuItem<T>(
                  value: item.value,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (item.leading != null) ...[
                        item.leading!,
                        const SizedBox(width: 8),
                      ],
                      Flexible(child: Text(item.label)),
                    ],
                  ),
                ),
              )
              .toList(),
      onChanged: (value) {
        if (value != null) onChanged(value);
      },
    );
  }
}

class ZzzSwitchTile extends StatelessWidget {
  const ZzzSwitchTile({
    required this.value,
    required this.title,
    required this.onChanged,
    this.subtitle,
    this.animated = true,
    super.key,
  });

  final bool value;
  final String title;
  final String? subtitle;
  final ValueChanged<bool> onChanged;
  final bool animated;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: _zzzDuration(animated),
      curve: _kZzzCurve,
      margin: const EdgeInsets.symmetric(vertical: 5),
      decoration: BoxDecoration(
        color:
            value
                ? ZzzColors.yellow.withValues(alpha: 0.14)
                : Colors.white.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color:
              value ? ZzzColors.yellow.withValues(alpha: 0.35) : Colors.white10,
        ),
      ),
      child: SwitchListTile(
        value: value,
        title: Text(title),
        subtitle: subtitle == null ? null : Text(subtitle!),
        activeColor: Colors.black,
        activeTrackColor: ZzzColors.yellow,
        onChanged: onChanged,
      ),
    );
  }
}

class ZzzFooterButton extends StatefulWidget {
  const ZzzFooterButton({required this.icon, this.onTap, super.key});

  final IconData icon;
  final VoidCallback? onTap;

  @override
  State<ZzzFooterButton> createState() => _ZzzFooterButtonState();
}

class _ZzzFooterButtonState extends State<ZzzFooterButton> {
  bool _pressed = false;

  void _handleTap() {
    widget.onTap?.call();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (_) => setState(() => _pressed = true),
      onPointerUp: (_) {
        setState(() => _pressed = false);
        _handleTap();
      },
      onPointerCancel: (_) => setState(() => _pressed = false),
      child: AnimatedScale(
        scale: _pressed ? 0.92 : 1,
        duration: _kZzzAnimFast,
        curve: _kZzzCurve,
        child: AnimatedContainer(
          duration: _kZzzAnimNormal,
          curve: _kZzzCurve,
          height: 40,
          width: 46,
          decoration: BoxDecoration(
            color: _pressed ? Colors.white10 : Colors.black,
            borderRadius: BorderRadius.circular(22),
            border: Border.all(
              color: _pressed ? Colors.white38 : Colors.white24,
            ),
          ),
          child: Icon(widget.icon),
        ),
      ),
    );
  }
}
