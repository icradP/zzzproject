import 'dart:io';

import 'package:flutter/material.dart';

import '../../assets/app_assets.dart';
import '../../theme/zzz_colors.dart';
import '../../widgets/zzz_widgets.dart';
import '../models/im_models.dart';

class ImMessageBubble extends StatelessWidget {
  const ImMessageBubble({
    required this.message,
    required this.senderName,
    required this.avatar,
    required this.showSenderName,
    this.hideAvatar = false,
    this.compact = false,
    this.hideTimestamp = false,
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
    final avatarWidget = hideAvatar
        ? const SizedBox(width: 38)
        : ZzzAvatar(image: avatar, size: 38);
    final isImageOnly = message.hasMedia &&
        message.kind == ImMessageKind.image &&
        (message.text.isEmpty || message.text == '[图片]');

    Widget buildBubbleContent() {
      if (message.hasMedia && message.kind == ImMessageKind.image) {
        return ClipRRect(
          borderRadius: BorderRadius.circular(isImageOnly ? 18 : 12),
          child: Image.file(
            File(message.mediaPath!),
            fit: BoxFit.cover,
            width: 180,
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
        );
      }
      return Text(
        message.text,
        style: TextStyle(
          color: isMine ? Colors.white : Colors.black87,
          fontSize: 15,
          height: 1.35,
        ),
      );
    }

    final bubbleContent = buildBubbleContent();
    final wrappedContent = isImageOnly
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

    return Padding(
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
  bool _initialScrollDone = false;

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
    if (widget.messages.length != oldWidget.messages.length) {
      _scrollToBottom();
    }
  }

  void _jumpToBottom() {
    if (!_scrollController.hasClients) return;
    _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
    });
  }

  void _scrollToMessage(String messageId) {
    final key = _messageKeys[messageId];
    if (key?.currentContext == null) return;
    Scrollable.ensureVisible(
      key!.currentContext!,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
      alignment: 0.3,
    );
  }

  Future<void> _submit() async {
    final text = _composerController.text;
    if (text.trim().isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      await widget.onSend(text);
      _composerController.clear();
      _composerFocus.requestFocus();
      _scrollToBottom();
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_initialScrollDone && widget.messages.isNotEmpty) {
      _initialScrollDone = true;
      // Double post-frame to ensure ListView layout is complete.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _jumpToBottom());
      });
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxPanelHeight =
            (constraints.maxHeight * 0.5).clamp(200.0, 420.0);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildHeader(),
            if (widget.conversation.isGroup)
              AnimatedSize(
                duration: const Duration(milliseconds: 280),
                curve: Curves.easeOutCubic,
                alignment: Alignment.topCenter,
                child: _showMembers
                    ? Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: ConstrainedBox(
                          constraints: BoxConstraints(maxHeight: maxPanelHeight),
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

    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.only(bottom: 8),
      itemCount: widget.messages.length,
      itemBuilder: (context, index) {
        final message = widget.messages[index];
        // Consecutive bubbles from the same sender within 2 s are
        // joined: no gap, no avatar, no repeated sender name.
        final prev = index > 0 ? widget.messages[index - 1] : null;
        final sameSender = prev != null &&
            prev.senderId == message.senderId &&
            message.sentAt.difference(prev.sentAt).inSeconds.abs() < 2;
        final hasNext = index + 1 < widget.messages.length &&
            widget.messages[index + 1].senderId == message.senderId &&
            widget.messages[index + 1]
                .sentAt
                .difference(message.sentAt)
                .inSeconds
                .abs() < 2;
        final compact = sameSender;
        final hideAvatar = sameSender;
        final hideTimestamp = hasNext;
        final showName = widget.conversation.isGroup &&
            !message.isMine &&
            !sameSender;

        return FutureBuilder<(String, ImageProvider)>(
          future: Future.wait([
            widget.resolveUserName(message.senderId),
            widget.resolveUserAvatar(message.senderId),
          ]).then((values) => (values[0] as String, values[1] as ImageProvider)),
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
              onQuoteTap: message.isReply
                  ? () => _scrollToMessage(message.replyToMessageId!)
                  : null,
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
            hintText: 'Message ${widget.conversation.title}',
            minLines: 1,
            maxLines: 4,
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
              FutureBuilder<
                ({String name, ImageProvider avatar})>(
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
  const _ReplyQuoteBar({
    this.quote,
    this.onTap,
    this.resolveUserName,
  });

  final ImMessage? quote;
  final VoidCallback? onTap;
  final Future<String> Function(String userId)? resolveUserName;

  static const _maxLen = 60;

  @override
  Widget build(BuildContext context) {
    if (quote == null) return const SizedBox.shrink();
    final text = quote!.text;
    final display = text.length > _maxLen
        ? '${text.substring(0, _maxLen)}…'
        : text;
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
              Container(
                width: 3,
                color: ZzzColors.yellow,
              ),
              Flexible(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(8, 8, 10, 8),
                  child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            FutureBuilder<String>(
              future: resolveUserName?.call(quote!.senderId) ??
                  Future.value(quote!.senderId),
              builder: (ctx, snap) {
                return Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.reply_rounded, size: 13, color: ZzzColors.yellow),
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
    '76': '👍', '66': '❤️', '63': '😂', '15': '😭',
    '12': '😊', '14': '😍', '2': '😢', '32': '😡',
    '4': '😲', '3': '😜', '21': '😘', '109': '👏',
    '5': '😴', '6': '😝', '10': '😎', '24': '🙏',
    '75': '💪', '33': '🤔', '0': '😮', '1': '😀',
    '74': '🌙', '59': '🍺', '53': '🎉',
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
