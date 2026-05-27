part of '../zzz_components.dart';

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
    _entranceScale = Tween<double>(
      begin: 0.9,
      end: 1,
    ).animate(CurvedAnimation(parent: _entranceController, curve: _kZzzBounce));
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
    _entranceOpacity = Tween<double>(begin: 0.9, end: 1).animate(curve);
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
