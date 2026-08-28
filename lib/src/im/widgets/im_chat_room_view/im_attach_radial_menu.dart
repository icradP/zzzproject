import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../theme/zzz_colors.dart';

/// Data model for a single attachment menu item.
class ImAttachItem {
  const ImAttachItem(this.icon, this.tooltip);
  final IconData icon;
  final String tooltip;
}

/// Default attachment items.
const kDefaultAttachItems = [
  ImAttachItem(Icons.image_rounded, 'Image'),
  ImAttachItem(Icons.insert_drive_file_rounded, 'File'),
  ImAttachItem(Icons.mic_rounded, 'Voice'),
  ImAttachItem(Icons.videocam_rounded, 'Video'),
  ImAttachItem(Icons.location_on_rounded, 'Location'),
];

/// A single attach-function button (icon + label below).
class ImAttachButton extends StatelessWidget {
  const ImAttachButton({
    required this.icon,
    required this.label,
    this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: 64,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(icon, size: 24, color: ZzzColors.yellow),
            ),
            const SizedBox(height: 6),
            Text(
              label,
              style: const TextStyle(
                color: Colors.white54,
                fontSize: 11,
              ),
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}

/// Simple circular button, 52×52.
class ImCircleButton extends StatelessWidget {
  const ImCircleButton({required this.onTap, this.rotated = false});
  final VoidCallback onTap;
  final bool rotated;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 52,
      height: 52,
      child: Material(
        color: Colors.white,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Center(
            child: AnimatedRotation(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              turns: rotated ? 0.125 : 0,
              child: const Icon(
                Icons.add_rounded,
                size: 26,
                color: Colors.black,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A quarter-circle radial menu centered on the "+" button.
class ImAttachRadialMenu extends StatefulWidget {
  const ImAttachRadialMenu({
    required this.showMenu,
    required this.onToggle,
    required this.onClose,
    this.items = kDefaultAttachItems,
  });

  final bool showMenu;
  final VoidCallback onToggle;
  final VoidCallback onClose;
  final List<ImAttachItem> items;

  @override
  State<ImAttachRadialMenu> createState() => _ImAttachRadialMenuState();
}

class _ImAttachRadialMenuState extends State<ImAttachRadialMenu>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _scale;
  int _hovered = -1;

  static const _diskRadius = 120.0;
  static const _itemRadius = 68.0;
  static const _itemSize = 44.0;
  static const _holeRadius = 34.0;
  static const _btnHalf = 26.0;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _scale = CurvedAnimation(parent: _ctrl, curve: Curves.easeOutBack);
    if (widget.showMenu) _ctrl.forward();
    _ctrl.addListener(() => setState(() {}));
  }

  @override
  void didUpdateWidget(covariant ImAttachRadialMenu old) {
    super.didUpdateWidget(old);
    if (widget.showMenu != old.showMenu) {
      if (widget.showMenu) {
        _ctrl.forward();
      } else {
        _ctrl.reverse();
      }
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _onItemTap(int i) {
    widget.onClose();
  }

  @override
  Widget build(BuildContext context) {
    final n = widget.items.length;
    final diskDiam = _diskRadius * 2 + _itemSize;
    final s = _scale.value;
    final cx = diskDiam / 2;
    final cy = diskDiam / 2;

    return SizedBox(
      width: diskDiam,
      height: diskDiam,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // Ring background
          if (s > 0)
            Positioned(
              left: cx - diskDiam / 2,
              top: cy - diskDiam / 2,
              child: Transform.scale(
                scale: s,
                child: Container(
                  width: diskDiam,
                  height: diskDiam,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: const Color(0xFF1a1a2e),
                    border: Border.all(color: Colors.white12),
                  ),
                ),
              ),
            ),
          // Inner hole
          if (s > 0)
            Positioned(
              left: cx - _holeRadius,
              top: cy - _holeRadius,
              child: Transform.scale(
                scale: s,
                child: Container(
                  width: _holeRadius * 2,
                  height: _holeRadius * 2,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    color: Color(0xFF12121e),
                  ),
                ),
              ),
            ),
          // Function items
          for (var i = 0; i < n; i++)
            Positioned(
              left:
                  cx +
                  _itemRadius * math.cos((i / n) * 2 * math.pi) -
                  _itemSize / 2,
              top:
                  cy +
                  _itemRadius * math.sin((i / n) * 2 * math.pi) -
                  _itemSize / 2,
              child: Transform.scale(
                scale: s,
                child: GestureDetector(
                  onTap: s > 0.8 ? () => _onItemTap(i) : null,
                  child: MouseRegion(
                    onEnter: (_) => setState(() => _hovered = i),
                    onExit: (_) => setState(() => _hovered = -1),
                    child: Container(
                      width: _itemSize,
                      height: _itemSize,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _hovered == i
                            ? ZzzColors.yellow
                            : const Color(0xFF2a2a3e),
                        boxShadow: _hovered == i
                            ? [
                                BoxShadow(
                                  color: ZzzColors.yellow.withValues(
                                    alpha: 0.4,
                                  ),
                                  blurRadius: 14,
                                ),
                              ]
                            : null,
                      ),
                      child: Icon(
                        widget.items[i].icon,
                        size: 21,
                        color:
                            _hovered == i ? Colors.black : Colors.white60,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          // Center + button
          Positioned(
            left: cx - _btnHalf,
            top: cy - _btnHalf,
            child: ImCircleButton(
              onTap: widget.onToggle,
              rotated: widget.showMenu,
            ),
          ),
        ],
      ),
    );
  }
}
