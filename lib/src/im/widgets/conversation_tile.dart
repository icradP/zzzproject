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
    this.onTogglePinned,
    this.onToggleMuted,
    this.onDelete,
    super.key,
  });

  final ImConversation conversation;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback? onTogglePinned;
  final VoidCallback? onToggleMuted;
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

  static const _actionWidth = 56.0;
  static const _actionsWidth = _actionWidth * 3;
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
      end: const Offset(-_actionsWidth, 0),
    ).animate(CurvedAnimation(parent: _slideCtrl, curve: Curves.easeOutCubic));

    _exitCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _exitSlide = CurvedAnimation(parent: _exitCtrl, curve: Curves.easeInCubic);
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

  void _runAction(VoidCallback? action) {
    _close();
    action?.call();
  }

  void _handleTapDown(TapDownDetails details) {
    if (_exiting) return;
    final w = context.size?.width ?? 0;
    if (_isOpen && details.localPosition.dx > w - _actionsWidth) {
      final distanceFromRight = w - details.localPosition.dx;
      if (distanceFromRight < _actionWidth) {
        _onHideTap();
      } else if (distanceFromRight < _actionWidth * 2) {
        _runAction(widget.onToggleMuted);
      } else {
        _runAction(widget.onTogglePinned);
      }
    } else if (_isOpen) {
      _close();
    } else {
      widget.onTap();
    }
  }

  Future<void> _showContextMenu(Offset position) async {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final selected = await showMenu<_ConversationAction>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(position.dx, position.dy, 1, 1),
        Offset.zero & overlay.size,
      ),
      items: [
        PopupMenuItem(
          value: _ConversationAction.pin,
          child: ListTile(
            dense: true,
            leading: Icon(
              widget.conversation.isPinned
                  ? Icons.push_pin_outlined
                  : Icons.push_pin_rounded,
            ),
            title: Text(widget.conversation.isPinned ? 'Unpin' : 'Pin'),
          ),
        ),
        PopupMenuItem(
          value: _ConversationAction.mute,
          child: ListTile(
            dense: true,
            leading: Icon(
              widget.conversation.isMuted
                  ? Icons.notifications_active_outlined
                  : Icons.notifications_off_outlined,
            ),
            title: Text(
              widget.conversation.isMuted
                  ? 'Enable notifications'
                  : 'Mute notifications',
            ),
          ),
        ),
        if (widget.onDelete != null)
          const PopupMenuItem(
            value: _ConversationAction.hide,
            child: ListTile(
              dense: true,
              leading: Icon(Icons.close_rounded),
              title: Text('Hide conversation'),
            ),
          ),
      ],
    );
    if (!mounted || selected == null) return;
    switch (selected) {
      case _ConversationAction.pin:
        widget.onTogglePinned?.call();
      case _ConversationAction.mute:
        widget.onToggleMuted?.call();
      case _ConversationAction.hide:
        _onHideTap();
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
              offset: Offset(
                -_exitSlide.value * MediaQuery.of(context).size.width,
                0,
              ),
              child: child,
            ),
          );
        },
        child: _buildTileContent(),
      );
    }

    return GestureDetector(
      onTapDown: _handleTapDown,
      onLongPressStart: (details) => _showContextMenu(details.globalPosition),
      onSecondaryTapDown: (details) => _showContextMenu(details.globalPosition),
      onHorizontalDragUpdate: (details) {
        if (_exiting) return;
        final newValue = (_slideCtrl.value - details.delta.dx / _actionsWidth)
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
              child: Align(
                alignment: Alignment.centerRight,
                child: SizedBox(
                  width: _actionsWidth,
                  child: Row(
                    children: [
                      _buildSwipeAction(
                        icon:
                            widget.conversation.isPinned
                                ? Icons.push_pin_outlined
                                : Icons.push_pin_rounded,
                        tooltip: widget.conversation.isPinned ? 'Unpin' : 'Pin',
                        color: ZzzColors.blue,
                        onPressed: widget.onTogglePinned,
                      ),
                      _buildSwipeAction(
                        icon:
                            widget.conversation.isMuted
                                ? Icons.notifications_active_outlined
                                : Icons.notifications_off_outlined,
                        tooltip:
                            widget.conversation.isMuted
                                ? 'Enable notifications'
                                : 'Mute notifications',
                        color: Colors.white24,
                        onPressed: widget.onToggleMuted,
                      ),
                      _buildSwipeAction(
                        icon: Icons.close_rounded,
                        tooltip: 'Hide conversation',
                        color: ZzzColors.yellow,
                        foregroundColor: Colors.black,
                        onPressed: _onHideTap,
                      ),
                    ],
                  ),
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

  Widget _buildSwipeAction({
    required IconData icon,
    required String tooltip,
    required Color color,
    required VoidCallback? onPressed,
    Color foregroundColor = Colors.white,
  }) {
    return SizedBox(
      width: _actionWidth,
      height: double.infinity,
      child: Material(
        color: color,
        child: IconButton(
          tooltip: tooltip,
          onPressed: onPressed,
          icon: Icon(icon, color: foregroundColor, size: 22),
        ),
      ),
    );
  }

  Widget _buildTileContent() {
    final avatarImage = widget.conversation.avatarImage(
      AppAssets.characterWise,
    );
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
            boxShadow:
                selected
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
                        if (widget.conversation.isMuted)
                          Padding(
                            padding: const EdgeInsets.only(right: 4),
                            child: Icon(
                              Icons.notifications_off_outlined,
                              size: 14,
                              color: selected ? Colors.black54 : Colors.white38,
                            ),
                          ),
                        if (widget.conversation.isPinned)
                          Padding(
                            padding: const EdgeInsets.only(right: 4),
                            child: Icon(
                              Icons.push_pin_rounded,
                              size: 14,
                              color: selected ? Colors.black54 : Colors.white38,
                            ),
                          ),
                        if (timeLabel != null)
                          Text(
                            timeLabel,
                            style: TextStyle(
                              color:
                                  selected
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
                        if (widget.conversation.sourceLabel != null) ...[
                          Flexible(
                            flex: 0,
                            child: Text(
                              widget.conversation.sourceLabel!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color:
                                    selected
                                        ? Colors.black.withValues(alpha: 0.62)
                                        : ZzzColors.blue,
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                        ],
                        Expanded(
                          child: Text(
                            widget.conversation.subtitle ?? 'No messages yet',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color:
                                  selected
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
                              color: selected ? Colors.black : ZzzColors.yellow,
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(
                              widget.conversation.unreadCount > 99
                                  ? '99+'
                                  : '${widget.conversation.unreadCount}',
                              style: TextStyle(
                                color:
                                    selected ? ZzzColors.yellow : Colors.black,
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

enum _ConversationAction { pin, mute, hide }
