part of '../zzz_components.dart';

Future<T?> showZzzModalPanel<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
}) {
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: Colors.black.withValues(alpha: 0.72),
    transitionDuration: _kZzzAnimExpand,
    pageBuilder: (context, _, __) => builder(context),
    transitionBuilder: (context, animation, secondaryAnimation, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: _kZzzBounce,
        reverseCurve: Curves.easeInCubic,
      );
      return FadeTransition(
        opacity: animation,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 0.04),
            end: Offset.zero,
          ).animate(curved),
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.94, end: 1).animate(curved),
            child: child,
          ),
        ),
      );
    },
  );
}

/// Responsive modal surface with the same visual language as [ZzzPanel].
class ZzzModalPanel extends StatelessWidget {
  const ZzzModalPanel({
    required this.title,
    required this.child,
    this.subtitle,
    this.icon,
    this.actions = const [],
    this.maxWidth = 520,
    this.maxHeight = 640,
    this.onClose,
    super.key,
  });

  final String title;
  final String? subtitle;
  final IconData? icon;
  final Widget child;
  final List<Widget> actions;
  final double maxWidth;
  final double maxHeight;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final availableHeight = media.size.height - media.viewInsets.vertical - 32;
    final resolvedMaxHeight =
        availableHeight < maxHeight ? availableHeight : maxHeight;

    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: maxWidth,
          maxHeight: resolvedMaxHeight < 180 ? 180 : resolvedMaxHeight,
        ),
        child: ZzzPanel(
          padding: EdgeInsets.zero,
          radius: 16,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 14, 10, 12),
                child: Row(
                  children: [
                    if (icon != null) ...[
                      Container(
                        width: 38,
                        height: 38,
                        decoration: const BoxDecoration(
                          color: ZzzColors.yellow,
                          shape: BoxShape.circle,
                        ),
                        child: Icon(icon, color: Colors.black, size: 21),
                      ),
                      const SizedBox(width: 12),
                    ],
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          if (subtitle != null)
                            Text(
                              subtitle!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white54,
                                fontSize: 12,
                              ),
                            ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: 'Close',
                      onPressed:
                          onClose ?? () => Navigator.of(context).maybePop(),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1, color: Colors.white12),
              Flexible(child: child),
              if (actions.isNotEmpty) ...[
                const Divider(height: 1, color: Colors.white12),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
                  child: OverflowBar(
                    alignment: MainAxisAlignment.end,
                    spacing: 8,
                    overflowSpacing: 8,
                    children: actions,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
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
    _entranceOpacity = Tween<double>(begin: 0.9, end: 1).animate(curve);
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
    this.dense = false,
    this.onExpansionChanged,
    super.key,
  });

  final String title;
  final String? subtitle;
  final Widget child;
  final bool initiallyExpanded;
  final bool animated;
  final bool dense;
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
                  padding: EdgeInsets.symmetric(
                    vertical: widget.dense ? 5 : 10,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              widget.title,
                              style: TextStyle(
                                color: Colors.white70,
                                fontWeight: FontWeight.w700,
                                fontSize: widget.dense ? 13 : null,
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
                        child: Icon(
                          Icons.expand_more_rounded,
                          color: Colors.white54,
                          size: widget.dense ? 20 : 24,
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
    this.dense = false,
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
  final bool dense;

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
        dense: dense,
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
