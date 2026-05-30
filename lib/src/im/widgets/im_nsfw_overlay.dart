import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Blur overlay for NSFW images.
///
/// The image is fully blurred and a semi-transparent mask is overlaid.
/// The user must long-press for ~3 seconds; a circular progress ring fills
/// up.  Release before completion resets the progress — the image stays
/// hidden.
class ImNsfwOverlay extends StatefulWidget {
  const ImNsfwOverlay({
    required this.child,
    required this.label,
    this.onReveal,
    super.key,
  });

  final Widget child;
  final String label;
  final VoidCallback? onReveal;

  @override
  State<ImNsfwOverlay> createState() => _ImNsfwOverlayState();
}

class _ImNsfwOverlayState extends State<ImNsfwOverlay>
    with SingleTickerProviderStateMixin {
  bool _revealed = false;

  // blur animation
  late final AnimationController _blurCtrl;
  late final Animation<double> _blurAmount;

  // long-press progress
  double _pressProgress = 0.0;
  Timer? _pressTimer;
  DateTime? _pressStart;
  static const _holdDuration = Duration(seconds: 3);

  @override
  void initState() {
    super.initState();
    _blurCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _blurAmount = Tween<double>(
      begin: 20,
      end: 0,
    ).animate(CurvedAnimation(parent: _blurCtrl, curve: Curves.easeOutCubic));
  }

  @override
  void dispose() {
    _blurCtrl.dispose();
    _pressTimer?.cancel();
    super.dispose();
  }

  // -- press handling -------------------------------------------------------

  void _onPressStart(LongPressStartDetails _) {
    if (_revealed) return;
    _pressStart = DateTime.now();
    _pressTimer?.cancel();
    _pressTimer = Timer.periodic(const Duration(milliseconds: 16), (_) {
      final elapsed = DateTime.now().difference(_pressStart!);
      final p = (elapsed.inMilliseconds / _holdDuration.inMilliseconds).clamp(
        0.0,
        1.0,
      );
      setState(() => _pressProgress = p);
      if (p >= 1.0) {
        _pressTimer?.cancel();
        _reveal();
      }
    });
  }

  void _onPressEnd(LongPressEndDetails _) {
    _cancelPress();
  }

  void _onPressCancel() {
    _cancelPress();
  }

  void _cancelPress() {
    _pressTimer?.cancel();
    _pressStart = null;
    if (_pressProgress > 0 && _pressProgress < 1.0) {
      setState(() => _pressProgress = 0.0);
    }
  }

  void _reveal() {
    setState(() => _revealed = true);
    _blurCtrl.forward();
    widget.onReveal?.call();
  }

  // -- build ----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Container(
      clipBehavior: Clip.hardEdge,
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(12)),
      child: Stack(
        alignment: Alignment.center,
        children: [
          // 1. blurred image — clipped to prevent blur bleed at edges
          ClipRect(
            child: AnimatedBuilder(
              animation: _blurAmount,
              builder:
                  (context, child) => ImageFiltered(
                    imageFilter: ui.ImageFilter.blur(
                      sigmaX: _blurAmount.value,
                      sigmaY: _blurAmount.value,
                      tileMode: TileMode.clamp,
                    ),
                    child: child!,
                  ),
              child: widget.child,
            ),
          ),

          // 2. dark mask + long-press interaction (only while hidden)
          if (!_revealed)
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onLongPressStart: _onPressStart,
                onLongPressEnd: _onPressEnd,
                onLongPressCancel: _onPressCancel,
                child: DecoratedBox(
                  decoration: const BoxDecoration(color: Color(0x55FFFFFF)),
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // progress ring (visible during press)
                        SizedBox(
                          width: 64,
                          height: 64,
                          child:
                              _pressProgress > 0
                                  ? CircularProgressIndicator(
                                    value: _pressProgress,
                                    strokeWidth: 3.5,
                                    strokeCap: StrokeCap.round,
                                    color: Colors.white,
                                    backgroundColor: Colors.white24,
                                  )
                                  : const Icon(
                                    Icons.visibility_off_rounded,
                                    color: Colors.white70,
                                    size: 28,
                                  ),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          widget.label,
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          _pressProgress > 0
                              ? '${(_pressProgress * 100).toInt()}%'
                              : 'Hold to view',
                          style: const TextStyle(
                            color: Colors.white54,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
