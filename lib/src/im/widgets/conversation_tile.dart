import 'package:flutter/material.dart';

import '../../assets/app_assets.dart';
import '../../theme/zzz_colors.dart';
import '../../widgets/zzz_widgets.dart';
import '../models/im_models.dart';

class ConversationTile extends StatefulWidget {
  const ConversationTile({
    required this.conversation,
    required this.selected,
    required this.onTap,
    this.onDelete,
    super.key,
  });

  final ImConversation conversation;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback? onDelete;

  @override
  State<ConversationTile> createState() => _ConversationTileState();
}

class _ConversationTileState extends State<ConversationTile>
    with TickerProviderStateMixin {
  late final AnimationController _slideCtrl;
  late final Animation<Offset> _slide;
  late final AnimationController _exitCtrl;
  late final Animation<double> _exitSlide;
  late final Animation<double> _exitFade;
  bool _exiting = false;

  static const _btnWidth = 80.0;
  static const _snapThreshold = 0.4;

  @override
  void initState() {
    super.initState();
    _slideCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
    );
    _slide = Tween<Offset>(
      begin: Offset.zero,
      end: const Offset(-_btnWidth, 0),
    ).animate(CurvedAnimation(
      parent: _slideCtrl,
      curve: Curves.easeOutCubic,
    ));

    _exitCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _exitSlide = CurvedAnimation(
      parent: _exitCtrl,
      curve: Curves.easeInCubic,
    );
    _exitFade = Tween<double>(begin: 1, end: 0).animate(
      CurvedAnimation(parent: _exitCtrl, curve: const Interval(0.3, 1.0)),
    );
    _exitCtrl.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        widget.onDelete?.call();
      }
    });
  }

  @override
  void dispose() {
    _slideCtrl.dispose();
    _exitCtrl.dispose();
    super.dispose();
  }

  bool get _isOpen => _slideCtrl.value > 0.5;

  void _close() {
    if (_isOpen) _slideCtrl.reverse();
  }

  void _onHideTap() {
    setState(() => _exiting = true);
    _exitCtrl.forward();
  }

  void _handleTapDown(TapDownDetails details) {
    if (_exiting) return;
    final w = context.size?.width ?? 0;
    if (_isOpen && details.localPosition.dx > w - _btnWidth) {
      _onHideTap();
    } else if (_isOpen) {
      _close();
    } else {
      widget.onTap();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.onDelete == null) {
      return _buildTileContent();
    }

    if (_exiting) {
      return AnimatedBuilder(
        animation: _exitCtrl,
        builder: (context, child) {
          return Opacity(
            opacity: _exitFade.value,
            child: Transform.translate(
              offset: Offset(-_exitSlide.value * MediaQuery.of(context).size.width, 0),
              child: child,
            ),
          );
        },
        child: _buildTileContent(),
      );
    }

    return GestureDetector(
      onTapDown: _handleTapDown,
      onHorizontalDragUpdate: (details) {
        if (_exiting) return;
        final newValue =
            (_slideCtrl.value - details.delta.dx / _btnWidth)
                .clamp(0.0, 1.0);
        _slideCtrl.value = newValue;
      },
      onHorizontalDragEnd: (details) {
        if (_exiting) return;
        final velocity = details.primaryVelocity ?? 0;
        if (_slideCtrl.value > _snapThreshold || velocity < -800) {
          _slideCtrl.forward();
        } else {
          _slideCtrl.reverse();
        }
      },
      child: ClipRRect(
        borderRadius: BorderRadius.circular(36),
        child: Stack(
          clipBehavior: Clip.hardEdge,
          children: [
            // Fixed hide button behind the content.
            Positioned.fill(
              child: Container(
                alignment: Alignment.centerRight,
                padding: const EdgeInsets.only(right: 20),
                decoration: BoxDecoration(
                  color: ZzzColors.yellow,
                  borderRadius: BorderRadius.circular(36),
                ),
                child: const Icon(
                  Icons.close_rounded,
                  color: Colors.black,
                  size: 28,
                ),
              ),
            ),
            // Sliding content overlay.
            AnimatedBuilder(
              animation: _slide,
              builder: (context, child) {
                return Transform.translate(
                  offset: Offset(_slide.value.dx, 0),
                  child: child,
                );
              },
              child: _buildTileContent(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTileContent() {
    final avatarImage =
        widget.conversation.avatarImage(AppAssets.characterWise);
    final timeLabel = _formatTime(widget.conversation.updatedAt);
    final selected = widget.selected;

    return Container(
      color: Colors.black,
      child: Material(
        color: Colors.transparent,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: selected ? ZzzColors.yellow : Colors.transparent,
            borderRadius: BorderRadius.circular(36),
            boxShadow: selected
                ? [
                    BoxShadow(
                      color: ZzzColors.yellow.withValues(alpha: 0.3),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    ),
                  ]
                : null,
          ),
          child: Row(
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  ZzzAvatar(image: avatarImage, size: 52),
                  if (widget.conversation.isGroup)
                    Positioned(
                      right: -2,
                      bottom: -2,
                      child: Container(
                        padding: const EdgeInsets.all(3),
                        decoration: BoxDecoration(
                          color: ZzzColors.blue,
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.black, width: 1.5),
                        ),
                        child: const Icon(
                          Icons.groups_rounded,
                          size: 12,
                          color: Colors.white,
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            widget.conversation.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: selected ? Colors.black : null,
                              fontWeight:
                                  widget.conversation.unreadCount > 0
                                      ? FontWeight.w800
                                      : FontWeight.w600,
                              fontSize: 16,
                            ),
                          ),
                        ),
                        if (timeLabel != null)
                          Text(
                            timeLabel,
                            style: TextStyle(
                              color: selected
                                  ? Colors.black.withValues(alpha: 0.48)
                                  : Colors.white38,
                              fontSize: 12,
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            widget.conversation.subtitle ?? 'No messages yet',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: selected
                                  ? Colors.black.withValues(alpha: 0.48)
                                  : widget.conversation.unreadCount > 0
                                      ? Colors.white70
                                      : Colors.white38,
                              fontSize: 13,
                            ),
                          ),
                        ),
                        if (widget.conversation.unreadCount > 0)
                          Container(
                            margin: const EdgeInsets.only(left: 8),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: selected
                                  ? Colors.black
                                  : ZzzColors.yellow,
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(
                              widget.conversation.unreadCount > 99
                                  ? '99+'
                                  : '${widget.conversation.unreadCount}',
                              style: TextStyle(
                                color: selected
                                    ? ZzzColors.yellow
                                    : Colors.black,
                                fontSize: 11,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String? _formatTime(DateTime? time) {
    if (time == null) return null;
    final now = DateTime.now();
    final diff = now.difference(time);
    if (diff.inMinutes < 1) return 'now';
    if (diff.inHours < 1) return '${diff.inMinutes}m';
    if (diff.inHours < 24) return '${diff.inHours}h';
    if (diff.inDays < 7) return '${diff.inDays}d';
    return '${time.month}/${time.day}';
  }
}
