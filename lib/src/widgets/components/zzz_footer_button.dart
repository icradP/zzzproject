part of '../zzz_components.dart';

class ZzzFooterButton extends StatefulWidget {
  const ZzzFooterButton({
    required this.icon,
    this.onTap,
    this.tooltip,
    this.animated = true,
    super.key,
  });

  final IconData icon;
  final VoidCallback? onTap;
  final String? tooltip;
  final bool animated;

  @override
  State<ZzzFooterButton> createState() => _ZzzFooterButtonState();
}

class _ZzzFooterButtonState extends State<ZzzFooterButton> {
  bool _hovered = false;
  bool _pressed = false;

  void _handleTap() {
    widget.onTap?.call();
  }

  @override
  Widget build(BuildContext context) {
    final content = MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Listener(
        onPointerDown: (_) => setState(() => _pressed = true),
        onPointerUp: (_) {
          setState(() => _pressed = false);
          _handleTap();
        },
        onPointerCancel: (_) => setState(() => _pressed = false),
        child: AnimatedScale(
          scale: widget.animated && _pressed ? 0.92 : 1,
          duration: _kZzzAnimFast,
          curve: _kZzzCurve,
          child: AnimatedContainer(
            duration: _zzzDuration(widget.animated),
            curve: _kZzzCurve,
            height: 40,
            width: 46,
            decoration: BoxDecoration(
              color:
                  _pressed
                      ? Colors.white10
                      : _hovered
                      ? Colors.white.withValues(alpha: 0.06)
                      : Colors.black,
              borderRadius: BorderRadius.circular(22),
              border: Border.all(
                color:
                    _pressed || _hovered
                        ? ZzzColors.yellow.withValues(alpha: 0.65)
                        : Colors.white24,
              ),
              boxShadow:
                  _hovered && widget.animated
                      ? [
                        BoxShadow(
                          color: ZzzColors.yellow.withValues(alpha: 0.16),
                          blurRadius: 12,
                        ),
                      ]
                      : null,
            ),
            child: AnimatedRotation(
              duration: _kZzzAnimFast,
              curve: _kZzzCurve,
              turns: widget.animated && _pressed ? -0.03 : 0,
              child: Icon(
                widget.icon,
                color:
                    _hovered
                        ? ZzzColors.yellow
                        : Theme.of(context).iconTheme.color,
              ),
            ),
          ),
        ),
      ),
    );

    if (widget.tooltip == null) return content;

    return Tooltip(message: widget.tooltip!, child: content);
  }
}
