import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:super_sliver_list/super_sliver_list.dart';

import '../../assets/app_assets.dart';
import '../../theme/zzz_colors.dart';
import '../../widgets/zzz_widgets.dart';
import '../data/im_logger.dart';
import '../data/im_nsfw_checker.dart';
import '../im_scope.dart';
import '../models/im_models.dart';
import 'im_nsfw_overlay.dart';
import 'im_platform_image_widget.dart';

class ImMessageBubble extends StatelessWidget {
  const ImMessageBubble({
    required this.message,
    required this.senderName,
    required this.avatar,
    required this.showSenderName,
    this.hideAvatar = false,
    this.compact = false,
    this.hideTimestamp = false,
    this.highlighted = false,
    this.resolveQuote,
    this.onQuoteTap,
    this.resolveUserName,
    super.key,
  });

  final ImMessage message;
  final String senderName;
  final ImageProvider avatar;
  final bool showSenderName;

  /// When true the avatar widget is replaced with an empty spacer so
  /// consecutive bubbles from the same sender align correctly.
  final bool hideAvatar;

  /// When true vertical padding is reduced so split bubbles (text +
  /// image from the same event) appear as a single visual group.
  final bool compact;

  /// When true the clock line is hidden (used for all but the last
  /// bubble in a split group).
  final bool hideTimestamp;

  /// When true the message bubble glows yellow briefly (scroll-to target).
  final bool highlighted;

  /// If this message is a reply, returns the source message being quoted.
  final ImMessage? Function(String messageId)? resolveQuote;

  /// Called when the quote bar is tapped; the caller scrolls to the source.
  final VoidCallback? onQuoteTap;

  /// Resolves a user ID to a display name (for the quote bar sender).
  final Future<String> Function(String userId)? resolveUserName;

  @override
  Widget build(BuildContext context) {
    if (message.kind == ImMessageKind.system) {
      return Center(
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            message.text,
            style: const TextStyle(color: Colors.white54, fontSize: 12),
          ),
        ),
      );
    }

    if (message.kind == ImMessageKind.poke) {
      return Center(
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(22),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.touch_app_rounded, size: 16, color: Colors.white54),
              const SizedBox(width: 6),
              Text(
                message.text,
                style: const TextStyle(color: Colors.white54, fontSize: 12),
              ),
            ],
          ),
        ),
      );
    }

    final isMine = message.isMine;
    final avatarWidget =
        hideAvatar
            ? const SizedBox(width: 38)
            : ZzzAvatar(image: avatar, size: 38);
    final isImageOnly =
        message.hasMedia &&
        (message.kind == ImMessageKind.image) &&
        (message.text.isEmpty || message.text == '[图片]');
    final isJsonCard = message.kind == ImMessageKind.json;

    Widget buildBubbleContent() {
      // File card.
      if (message.kind == ImMessageKind.file) {
        return _FileCard(
          fileName: message.text.isNotEmpty ? message.text : '未知文件',
          fileSize: message.mediaSize,
          isMine: isMine,
        );
      }
      final hasImage = message.hasMedia &&
          (message.kind == ImMessageKind.image || isJsonCard);
      if (!hasImage) {
        return Text(
          message.text,
          style: TextStyle(
            color: isMine ? Colors.white : Colors.black87,
            fontSize: 15,
            height: 1.35,
          ),
        );
      }
      // Mini-program card: image + text, adaptive width.
      if (isJsonCard) {
        return ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 250),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              _NsfwGuard(
                messageId: message.id,
                mediaPath: message.mediaPath!,
                child: ClipRRect(
                  borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(14)),
                  child: platformImageWidget(
                    message.mediaPath!,
                    fit: BoxFit.scaleDown,
                    errorBuilder: (context, error, stack) {
                      return const SizedBox.shrink();
                    },
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
                decoration: BoxDecoration(
                  color:
                      isMine ? ZzzColors.blue.withValues(alpha: 0.85) : const Color(0xFFe8e8ec),
                  borderRadius: const BorderRadius.vertical(
                      bottom: Radius.circular(14)),
                ),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                    Text(
                      message.text,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: isMine ? Colors.white70 : Colors.black54,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '小程序',
                      style: TextStyle(
                        fontSize: 10,
                        color: isMine ? Colors.white38 : Colors.black38,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      }
      // Plain image — adaptive sizing via scaleDown.
      // Small stickers/emojis display at natural size, large images
      // (photos, screenshots) scale down to fit the constraints.
      return _NsfwGuard(
        messageId: message.id,
        mediaPath: message.mediaPath!,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(isImageOnly ? 18 : 12),
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: 250,
              maxHeight: 400,
            ),
            child: platformImageWidget(
              message.mediaPath!,
              fit: BoxFit.scaleDown,
              errorBuilder: (context, error, stack) {
                return Text(
                  message.text,
                  style: TextStyle(
                    color: isMine ? Colors.white : Colors.black87,
                    fontSize: 15,
                    height: 1.35,
                  ),
                );
              },
            ),
          ),
        ),
      );
    }

    final bubbleContent = buildBubbleContent();
    final wrappedContent =
        isJsonCard
            ? Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.18),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: bubbleContent,
            )
            : isImageOnly
            ? Container(
              constraints: const BoxConstraints(maxWidth: 520),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(18),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.18),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: bubbleContent,
            )
            : Container(
              constraints: const BoxConstraints(maxWidth: 520),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: isMine ? ZzzColors.blue : Colors.grey.shade200,
                borderRadius: BorderRadius.circular(18),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.16),
                    blurRadius: 8,
                    offset: const Offset(0, 3),
                  ),
                ],
              ),
              child: bubbleContent,
            );

    final bubble = Flexible(
      child: Column(
        crossAxisAlignment:
            isMine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          if (showSenderName)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                senderName,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.45),
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          if (message.isReply)
            Align(
              alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
              child: IntrinsicWidth(
                child: _ReplyQuoteBar(
                  quote: resolveQuote?.call(message.replyToMessageId!),
                  onTap: onQuoteTap,
                  resolveUserName: resolveUserName,
                ),
              ),
            ),
          wrappedContent,
          if (message.reactions != null && message.reactions!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: _ReactionChips(
                reactions: message.reactions!,
                isMine: isMine,
              ),
            ),
          if (!hideTimestamp) ...[
            const SizedBox(height: 2),
            Text(
              _formatClock(message.sentAt),
              style: const TextStyle(color: Colors.white30, fontSize: 10),
            ),
          ],
        ],
      ),
    );

    return TweenAnimationBuilder<Color?>(
      key: ValueKey('hl_${message.id}_$highlighted'),
      tween: ColorTween(
        begin:
            highlighted
                ? ZzzColors.yellow.withValues(alpha: 0.50)
                : Colors.transparent,
        end: Colors.transparent,
      ),
      duration: Duration(milliseconds: highlighted ? 2000 : 0),
      curve: Curves.easeOutCubic,
      builder: (context, color, child) {
        return Container(
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Padding(
            padding: EdgeInsets.symmetric(vertical: compact ? 1 : 4),
            child: Row(
              mainAxisAlignment:
                  isMine ? MainAxisAlignment.end : MainAxisAlignment.start,
              crossAxisAlignment: CrossAxisAlignment.start,
              children:
                  isMine
                      ? [bubble, const SizedBox(width: 8), avatarWidget]
                      : [avatarWidget, const SizedBox(width: 8), bubble],
            ),
          ),
        );
      },
    );
  }

  String _formatClock(DateTime time) {
    final hour = time.hour.toString().padLeft(2, '0');
    final minute = time.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }
}

class ImChatRoomView extends StatefulWidget {
  const ImChatRoomView({
    required this.conversation,
    required this.messages,
    required this.onSend,
    required this.resolveUserName,
    required this.resolveUserAvatar,
    this.resolveMessage,
    this.onBack,
    super.key,
  });

  final ImConversation conversation;
  final List<ImMessage> messages;
  final Future<void> Function(String text) onSend;
  final Future<String> Function(String userId) resolveUserName;
  final Future<ImageProvider> Function(String userId) resolveUserAvatar;

  /// Look up a quoted message by id across all loaded messages.
  final ImMessage? Function(String messageId)? resolveMessage;
  final VoidCallback? onBack;

  @override
  State<ImChatRoomView> createState() => _ImChatRoomViewState();
}

class _ImChatRoomViewState extends State<ImChatRoomView> {
  final _composerController = TextEditingController();
  final _composerFocus = FocusNode();
  final _scrollController = ScrollController();
  final _messageKeys = <String, GlobalKey>{};
  bool _sending = false;
  bool _showMembers = false;
  String? _highlightMessageId;

  @override
  void initState() {
    super.initState();
    _lastMaxExtent = 0;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _scrollToBottom();
    });
  }

  @override
  void dispose() {
    _composerController.dispose();
    _composerFocus.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant ImChatRoomView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final convChanged =
        widget.conversation.id != oldWidget.conversation.id;
    if (convChanged) {
      _lastMaxExtent = 0;
    }
    if (convChanged || widget.messages.length != oldWidget.messages.length) {
      _scrollToBottom();
    }
  }

  double _lastMaxExtent = 0;

  void _scrollToBottom() {
    bool done = false;

    void doScroll() {
      if (done || !_scrollController.hasClients) return;
      done = true;
      _scrollController.position.removeListener(doScroll);
      final ext = _scrollController.position.maxScrollExtent;
      if (ext > 0) {
        _lastMaxExtent = ext;
        _scrollController.animateTo(
          ext,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
        );
      }
    }

    Future.delayed(const Duration(milliseconds: 500), () {
      if (!done) doScroll();
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      final ext = _scrollController.position.maxScrollExtent;
      if (ext > _lastMaxExtent && ext > 0) {
        doScroll();
      } else {
        _scrollController.position.addListener(doScroll);
      }
    });
  }

  GlobalKey? _findKeyForSourceId(String sourceId) {
    // Exact match first.
    if (_messageKeys[sourceId]?.currentContext != null) {
      return _messageKeys[sourceId];
    }
    // Split messages use suffixes like "1234567_0".
    final prefix = '${sourceId}_';
    for (final entry in _messageKeys.entries) {
      if (entry.key.startsWith(prefix) && entry.value.currentContext != null) {
        return entry.value;
      }
    }
    return null;
  }

  DateTime _lastQuoteTap = DateTime(2000);

  void _scrollToMessage(String sourceId) {
    final now = DateTime.now();
    if (sourceId == _highlightMessageId &&
        now.difference(_lastQuoteTap).inMilliseconds < 500) {
      return;
    }
    _lastQuoteTap = now;

    final key = _findKeyForSourceId(sourceId);
    if (key == null) return;

    // Clear old highlight so the key toggles for re-trigger.
    if (_highlightMessageId != null) {
      setState(() => _highlightMessageId = null);
    }

    final ctx = key.currentContext!;
    final alreadyVisible =
        _scrollController.hasClients && _isWidgetVisible(ctx);

    void flash() {
      if (!mounted) return;
      setState(() => _highlightMessageId = sourceId);
      Future.delayed(const Duration(seconds: 2), () {
        if (mounted && _highlightMessageId == sourceId) {
          setState(() => _highlightMessageId = null);
        }
      });
    }

    if (alreadyVisible) {
      // No scroll needed — flash immediately (next frame for key toggle).
      WidgetsBinding.instance.addPostFrameCallback((_) => flash());
    } else {
      // Scroll to the target, then flash.
      Scrollable.ensureVisible(
        ctx,
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeOutCubic,
        alignment: 0.3,
      ).then((_) => flash());
    }
  }

  /// Checks whether [ctx]'s render box has been laid out and has size.
  bool _isWidgetVisible(BuildContext ctx) {
    final renderBox = ctx.findRenderObject() as RenderBox?;
    return renderBox != null && renderBox.hasSize && renderBox.size.height > 0;
  }

  Future<void> _submit() async {
    final text = _composerController.text;
    if (text.trim().isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      await widget.onSend(text);
      _composerController.clear();
      _composerFocus.requestFocus();
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxPanelHeight = (constraints.maxHeight * 0.5).clamp(
          200.0,
          420.0,
        );
        return Stack(
          clipBehavior: Clip.none,
          children: [
            GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: () => _composerFocus.unfocus(),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildHeader(),
                  if (widget.conversation.isGroup)
                    AnimatedSize(
                      duration: const Duration(milliseconds: 280),
                      curve: Curves.easeOutCubic,
                      alignment: Alignment.topCenter,
                      child:
                          _showMembers
                              ? Padding(
                                padding: const EdgeInsets.only(top: 8),
                                child: ConstrainedBox(
                                  constraints: BoxConstraints(
                                    maxHeight: maxPanelHeight,
                                  ),
                                  child: _MemberGrid(
                                    participantIds:
                                        widget.conversation.participantIds,
                                    resolveUserName: widget.resolveUserName,
                                    resolveUserAvatar: widget.resolveUserAvatar,
                                  ),
                                ),
                              )
                              : const SizedBox.shrink(),
                    ),
                  const Divider(height: 20, thickness: 1, color: Colors.white12),
                  Expanded(child: _buildMessages()),
                  const SizedBox(height: 10),
                  _buildComposer(),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildHeader() {
    final avatarImage = widget.conversation.avatarImage(
      AppAssets.characterWise,
    );

    return Row(
      children: [
        if (widget.onBack != null) ...[
          IconButton(
            tooltip: 'Back',
            onPressed: widget.onBack,
            icon: const Icon(Icons.arrow_back_rounded),
          ),
          const SizedBox(width: 4),
        ],
        ZzzAvatar(image: avatarImage, size: 44),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.conversation.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                ),
              ),
              Text(
                widget.conversation.isGroup
                    ? '${widget.conversation.participantIds.length} members'
                    : 'Direct message',
                style: const TextStyle(color: Colors.white38, fontSize: 12),
              ),
            ],
          ),
        ),
        if (widget.conversation.isGroup)
          IconButton(
            tooltip: 'More',
            onPressed: () => setState(() => _showMembers = !_showMembers),
            icon: AnimatedRotation(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              turns: _showMembers ? 0.5 : 0,
              child: const Icon(
                Icons.expand_more_rounded,
                color: Colors.white54,
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildMessages() {
    if (widget.messages.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Image.asset(AppAssets.stickerCorin, height: 120),
            const SizedBox(height: 12),
            const Text(
              'Say hello to start the chat.',
              style: TextStyle(color: Colors.white54),
            ),
          ],
        ),
      );
    }

    return SuperListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.only(bottom: 8),
      itemCount: widget.messages.length,
      itemBuilder: (context, index) {
        final message = widget.messages[index];
        // Consecutive bubbles from the same sender within 2 s are
        // joined: no gap, no avatar, no repeated sender name.
        final prev = index > 0 ? widget.messages[index - 1] : null;
        final sameSender =
            prev != null &&
            prev.senderId == message.senderId &&
            message.sentAt.difference(prev.sentAt).inSeconds.abs() < 2;
        final hasNext =
            index + 1 < widget.messages.length &&
            widget.messages[index + 1].senderId == message.senderId &&
            widget.messages[index + 1].sentAt
                    .difference(message.sentAt)
                    .inSeconds
                    .abs() <
                2;
        final compact = sameSender;
        final hideAvatar = sameSender;
        final hideTimestamp = hasNext;
        final showName =
            widget.conversation.isGroup && !message.isMine && !sameSender;

        return FutureBuilder<(String, ImageProvider)>(
          future: Future.wait([
            widget.resolveUserName(message.senderId),
            widget.resolveUserAvatar(message.senderId),
          ]).then(
            (values) => (values[0] as String, values[1] as ImageProvider),
          ),
          builder: (context, snapshot) {
            final senderName = snapshot.data?.$1 ?? '...';
            final avatar =
                snapshot.data?.$2 ?? AssetImage(AppAssets.characterWise);
            _messageKeys.putIfAbsent(message.id, () => GlobalKey());
            return Container(
              key: _messageKeys[message.id],
              child: ImMessageBubble(
                message: message,
                senderName: senderName,
                avatar: avatar,
                showSenderName: showName,
                hideAvatar: hideAvatar,
                compact: compact,
                hideTimestamp: hideTimestamp,
                resolveQuote: widget.resolveMessage,
                onQuoteTap:
                    message.isReply
                        ? () => _scrollToMessage(message.replyToMessageId!)
                        : null,
                highlighted:
                    _highlightMessageId != null &&
                    (message.id == _highlightMessageId ||
                        message.id.startsWith('${_highlightMessageId}_')),
                resolveUserName: widget.resolveUserName,
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildComposer() {
    return Row(
      children: [
        Expanded(
          child: ZzzTextInput(
            controller: _composerController,
            focusNode: _composerFocus,
            hintText: 'Message something...',
            minLines: 1,
            maxLines: 3,
            textInputAction: TextInputAction.send,
            fillColor: Colors.white.withValues(alpha: 0.08),
            foregroundColor: Colors.white,
            onSubmitted: (_) => _submit(),
          ),
        ),
        const SizedBox(width: 8),
        FilledButton(
          onPressed: _sending ? null : _submit,
          style: FilledButton.styleFrom(
            backgroundColor: ZzzColors.blue,
            foregroundColor: Colors.white,
            minimumSize: const Size(64, 52),
          ),
          child:
              _sending
                  ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                  : const Text('Send'),
        ),
        const SizedBox(width: 4),
        IconButton.filled(
          tooltip: 'Attach',
          onPressed: () {},
          style: IconButton.styleFrom(
            backgroundColor: Colors.white,
            foregroundColor: Colors.black,
            minimumSize: const Size(52, 52),
          ),
          icon: Image.asset(AppAssets.iconPhoto, width: 22),
        ),
      ],
    );
  }
}

/// Simple circular button, 52×52.
class _CircleButton extends StatelessWidget {
  const _CircleButton({required this.onTap, this.rotated = false});
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

const _attachItems = [
  _AttachItem(Icons.image_rounded, 'Image'),
  _AttachItem(Icons.insert_drive_file_rounded, 'File'),
  _AttachItem(Icons.mic_rounded, 'Voice'),
  _AttachItem(Icons.videocam_rounded, 'Video'),
  _AttachItem(Icons.location_on_rounded, 'Location'),
];

/// A quarter-circle radial menu centered on the "+" button.
class _AttachRadialMenu extends StatefulWidget {
  const _AttachRadialMenu({
    required this.showMenu,
    required this.onToggle,
    required this.onClose,
  });

  final bool showMenu;
  final VoidCallback onToggle;
  final VoidCallback onClose;

  @override
  State<_AttachRadialMenu> createState() => _AttachRadialMenuState();
}

class _AttachRadialMenuState extends State<_AttachRadialMenu>
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
  void didUpdateWidget(covariant _AttachRadialMenu old) {
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
    final n = _attachItems.length;
    final diskDiam = _diskRadius * 2 + _itemSize;
    final s = _scale.value;
    final cx = diskDiam / 2; // center X
    final cy = diskDiam / 2; // center Y

    return SizedBox(
      width: diskDiam,
      height: diskDiam,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // Ring background — centered.
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
          // Inner hole — centered.
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
          // Function items on the full ring.
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
                        color:
                            _hovered == i
                                ? ZzzColors.yellow
                                : const Color(0xFF2a2a3e),
                        boxShadow:
                            _hovered == i
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
                        _attachItems[i].icon,
                        size: 21,
                        color: _hovered == i ? Colors.black : Colors.white60,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          // Center + button.
          Positioned(
            left: cx - _btnHalf,
            top: cy - _btnHalf,
            child: _CircleButton(
              onTap: widget.onToggle,
              rotated: widget.showMenu,
            ),
          ),
        ],
      ),
    );
  }
}

class _AttachItem {
  const _AttachItem(this.icon, this.tooltip);
  final IconData icon;
  final String tooltip;
}

/// File attachment card — follows the demo's `ZzzSystemMessageView`
/// file-uploaded style: label + dark file-name container.
class _FileCard extends StatelessWidget {
  const _FileCard({
    required this.fileName,
    this.fileSize,
    required this.isMine,
  });

  final String fileName;
  final int? fileSize;
  final bool isMine;

  String _formatSize(int? bytes) {
    if (bytes == null || bytes <= 0) return '';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  @override
  Widget build(BuildContext context) {
    final sizeLabel = _formatSize(fileSize);
    return SizedBox(
      width: 260,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.grey.shade500,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                const Icon(Icons.insert_drive_file_rounded,
                    size: 16, color: Colors.black),
                const SizedBox(width: 6),
                const Text(
                  'New File uploaded:',
                  style: TextStyle(
                    color: Colors.black,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (sizeLabel.isNotEmpty) ...[
                  const SizedBox(width: 6),
                  Text(
                    sizeLabel,
                    style: const TextStyle(
                      color: Colors.black54,
                      fontSize: 11,
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.black,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                fileName,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white70, fontSize: 13),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MemberGrid extends StatelessWidget {
  const _MemberGrid({
    required this.participantIds,
    required this.resolveUserName,
    required this.resolveUserAvatar,
  });

  final List<String> participantIds;
  final Future<String> Function(String userId) resolveUserName;
  final Future<ImageProvider> Function(String userId) resolveUserAvatar;

  @override
  Widget build(BuildContext context) {
    return ZzzPanel(
      padding: const EdgeInsets.all(12),
      child: SingleChildScrollView(
        child: Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            for (final userId in participantIds)
              FutureBuilder<({String name, ImageProvider avatar})>(
                future: Future.wait([
                  resolveUserName(userId),
                  resolveUserAvatar(userId),
                ]).then(
                  (v) => (name: v[0] as String, avatar: v[1] as ImageProvider),
                ),
                builder: (context, snapshot) {
                  final name = snapshot.data?.name ?? userId;
                  final avatar =
                      snapshot.data?.avatar ??
                      AssetImage(AppAssets.characterWise);
                  return SizedBox(
                    width: 66,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          padding: const EdgeInsets.all(2),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: Colors.white24,
                          ),
                          child: ZzzAvatar(image: avatar, size: 44),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 11,
                            color: Colors.white70,
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
          ],
        ),
      ),
    );
  }
}

/// Compact emoji reaction chips shown below a message bubble.
///
/// Telegram-style reply quote bar showing the source message content.
class _ReplyQuoteBar extends StatelessWidget {
  const _ReplyQuoteBar({this.quote, this.onTap, this.resolveUserName});

  final ImMessage? quote;
  final VoidCallback? onTap;
  final Future<String> Function(String userId)? resolveUserName;

  static const _maxLen = 60;

  @override
  Widget build(BuildContext context) {
    if (quote == null) return const SizedBox.shrink();
    final text = quote!.text;
    final display =
        text.length > _maxLen ? '${text.substring(0, _maxLen)}…' : text;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 6),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
        ),
        clipBehavior: Clip.antiAlias,
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(width: 3, color: ZzzColors.yellow),
              Flexible(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(8, 8, 10, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      FutureBuilder<String>(
                        future:
                            resolveUserName?.call(quote!.senderId) ??
                            Future.value(quote!.senderId),
                        builder: (ctx, snap) {
                          return Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Icons.reply_rounded,
                                size: 13,
                                color: ZzzColors.yellow,
                              ),
                              const SizedBox(width: 4),
                              Flexible(
                                child: Text(
                                  snap.data ?? quote!.senderId,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700,
                                    color: ZzzColors.yellow,
                                  ),
                                ),
                              ),
                            ],
                          );
                        },
                      ),
                      const SizedBox(height: 4),
                      Text(
                        display,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.white,
                          height: 1.3,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Styled after Telegram / QQ — small rounded pills with a card-like
/// background and subtle shadow.
class _ReactionChips extends StatelessWidget {
  const _ReactionChips({required this.reactions, required this.isMine});

  final List<ImReaction> reactions;
  final bool isMine;

  static const _emojiMap = <String, String>{
    '76': '👍',
    '66': '❤️',
    '63': '😂',
    '15': '😭',
    '12': '😊',
    '14': '😍',
    '2': '😢',
    '32': '😡',
    '4': '😲',
    '3': '😜',
    '21': '😘',
    '109': '👏',
    '5': '😴',
    '6': '😝',
    '10': '😎',
    '24': '🙏',
    '75': '💪',
    '33': '🤔',
    '0': '😮',
    '1': '😀',
    '74': '🌙',
    '59': '🍺',
    '53': '🎉',
  };

  String _emojiFor(String id) => _emojiMap[id] ?? '#$id';

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 3,
      runSpacing: 3,
      children: [
        for (final r in reactions)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
            decoration: BoxDecoration(
              color: const Color(0xFF2a2a3a),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.white10),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _emojiFor(r.emojiId),
                  style: const TextStyle(fontSize: 14),
                ),
                const SizedBox(width: 3),
                Text(
                  '${r.count}',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: Colors.white.withValues(alpha: 0.6),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// Wraps an image child with NSFW blur protection when the checker flags it.
class _NsfwGuard extends StatefulWidget {
  const _NsfwGuard({required this.messageId, required this.mediaPath, required this.child});

  final String messageId;
  final String mediaPath;
  final Widget child;

  @override
  State<_NsfwGuard> createState() => _NsfwGuardState();
}

class _NsfwGuardState extends State<_NsfwGuard> {
  bool _checking = false;
  bool _didCheck = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_didCheck) {
      _didCheck = true;
      _maybeCheck();
    }
  }

  void _maybeCheck() {
    final state = ImScope.nsfwStateCacheOf(context).get(widget.messageId);
    if (state.checked) return; // already checked
    if (_checking) return;
    _checking = true;

    final checker = ImScope.nsfwCheckerOf(context);
    if (!checker.isAvailable) {
      ImLogger.nsfwUnavailable(widget.messageId);
      _checking = false;
      return;
    }

    ImLogger.nsfwCheck(widget.messageId, widget.mediaPath);
    checker.check(widget.mediaPath).then((nsfw) {
      if (!mounted) return;
      ImLogger.nsfwResult(widget.messageId, nsfw);
      ImScope.nsfwStateCacheOf(context).put(
        widget.messageId,
        NsfwState(checked: true, nsfw: nsfw),
      );
      setState(() {}); // rebuild with overlay
    }).whenComplete(() {
      _checking = false;
    });
  }

  void _reveal() {
    final cache = ImScope.nsfwStateCacheOf(context);
    final state = cache.get(widget.messageId);
    cache.put(widget.messageId, state.copyWith(revealed: true));
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final state = ImScope.nsfwStateCacheOf(context).get(widget.messageId);
    final shouldBlur = state.checked && state.nsfw == true && !state.revealed;
    if (!shouldBlur) return widget.child;

    return ImNsfwOverlay(
      label: 'Sensitive content',
      onReveal: _reveal,
      child: widget.child,
    );
  }
}
