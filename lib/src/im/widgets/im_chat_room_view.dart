import 'dart:io';
import 'dart:math' as math;

import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:onebot_flutter/onebot_flutter.dart' show OneBotMessageSegment;
import 'package:pasteboard/pasteboard.dart';
import 'package:super_sliver_list/super_sliver_list.dart';

import '../../assets/app_assets.dart';
import '../../theme/zzz_colors.dart';
import '../../widgets/zzz_widgets.dart';
import '../adapters/nonebot/napcat_api.dart';
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
    // Recalled message — system-style collapsible banner.
    if (message.recalled) {
      return _RecalledBanner(
        message: message,
        senderName: senderName,
      );
    }
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
    final isRecordOnly =
        message.hasMedia &&
        (message.kind == ImMessageKind.record) &&
        (message.text.isEmpty || message.text == '[语音]');
    final isJsonCard = message.kind == ImMessageKind.json;
    final isForward = message.kind == ImMessageKind.forward;

    Widget buildBubbleContent() {
      // Forward bubble — tap to open merged messages.
      if (message.kind == ImMessageKind.forward) {
        return _ForwardBubble(message: message);
      }
      // Voice bubble — downloads on play tap.
      if (message.kind == ImMessageKind.record) {
        final seg = message.segments?.firstOrNull;
        return _VoiceBubble(
          fileId: seg?.data['file']?.toString(),
          url: seg?.data['url']?.toString(),
          localPath: message.mediaPath,
          isMine: isMine,
          fileSize: message.mediaSize,
        );
      }
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
            : isImageOnly || isRecordOnly || isJsonCard || isForward
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
  bool _showAttach = false;
  String? _highlightMessageId;
  final _pendingImages = <String>[];
  ImMessageKind _pendingKind = ImMessageKind.image;

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

  void _toggleAttach() {
    if (!_showAttach) {
      _composerFocus.unfocus();
      if (_showMembers) setState(() => _showMembers = false);
    }
    setState(() => _showAttach = !_showAttach);
    Future.delayed(const Duration(milliseconds: 350), () {
      if (mounted) _scrollToBottom();
    });
  }

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
    final hasText = text.trim().isNotEmpty;
    final hasMedia = _pendingImages.isNotEmpty;
    if ((!hasText && !hasMedia) || _sending) return;
    setState(() => _sending = true);
    try {
      if (hasMedia) {
        await _sendPending();
      }
      if (hasText) {
        await widget.onSend(text);
        _composerController.clear();
        _composerFocus.requestFocus();
      }
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
                  if (_pendingImages.isNotEmpty) _buildPendingPreview(),
                  _buildComposer(),
                  _buildAttachPanel(),
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
            onPressed: () {
              if (!_showMembers && _showAttach) {
                setState(() => _showAttach = false);
              }
              setState(() => _showMembers = !_showMembers);
            },
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

  Future<void> _pickAndStageMedia(String type) async {
    setState(() => _showAttach = false);

    String? path;
    ImMessageKind kind;

    switch (type) {
      case 'Image':
        final result = await FilePicker.pickFiles(
          type: FileType.image,
          allowMultiple: true,
        );
        if (result == null || result.files.isEmpty) return;
        setState(() {
          _pendingKind = ImMessageKind.image;
          _pendingImages.addAll(result.files.map((f) => f.path!));
        });
        return;
      case 'Voice':
        final result = await FilePicker.pickFiles(type: FileType.audio);
        if (result == null || result.files.isEmpty) return;
        path = result.files.single.path!;
        kind = ImMessageKind.record;
        break;
      case 'Video':
        final result = await FilePicker.pickFiles(type: FileType.video);
        if (result == null || result.files.isEmpty) return;
        path = result.files.single.path!;
        kind = ImMessageKind.video;
        break;
      case 'File':
        final result = await FilePicker.pickFiles(allowMultiple: true);
        if (result == null || result.files.isEmpty) return;
        setState(() {
          _pendingKind = ImMessageKind.file;
          _pendingImages.addAll(result.files.map((f) => f.path!));
        });
        return;
      case 'Location':
        return;
      default:
        return;
    }

    setState(() {
      _pendingImages.add(path!);
      _pendingKind = kind;
    });
  }

  Future<String?> _pasteFromClipboardWithLog() async {
    try {
      final bytes = await Pasteboard.image;
      if (bytes != null && bytes.isNotEmpty) {
        debugPrint(
            '[Paste] clipboard image: ${bytes.length} bytes');
        final tmp = Directory.systemTemp;
        final name =
            'zzz_clip_${DateTime.now().microsecondsSinceEpoch}.png';
        final out = File('${tmp.path}/$name');
        await out.writeAsBytes(bytes);
        return out.path;
      }
      // No image — check for text.
      final text = await Pasteboard.text;
      if (text != null && text.isNotEmpty) {
        debugPrint(
            '[Paste] clipboard text: ${text.length} chars — "${text.substring(0, text.length.clamp(0, 80))}"');
      } else {
        debugPrint('[Paste] clipboard empty or unsupported');
      }
    } catch (e) {
      debugPrint('[Paste] error: $e');
    }
    return null;
  }

  Future<void> _sendPending() async {
    if (_pendingImages.isEmpty) return;
    final images = List<String>.of(_pendingImages);
    final kind = _pendingKind;
    setState(() {
      _pendingImages.clear();
      _sending = true;
    });
    try {
      final repo = ImScope.repositoryOf(context);
      final convId = widget.conversation.id;
      for (final path in images) {
        await repo.sendMediaMessage(
          conversationId: convId,
          filePath: path,
          kind: kind,
        );
      }
    } catch (_) {}
    if (mounted) setState(() => _sending = false);
    Future.delayed(const Duration(milliseconds: 350), () {
      if (mounted) _scrollToBottom();
    });
  }

  Widget _buildPendingPreview() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Container(
        height: 72,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            Expanded(
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: _pendingImages.length,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (_, i) => Stack(
                  clipBehavior: Clip.none,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.file(
                        File(_pendingImages[i]),
                        width: 56,
                        height: 56,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => Container(
                          width: 56,
                          height: 56,
                          color: Colors.white10,
                          child: const Icon(Icons.image,
                              color: Colors.white38),
                        ),
                      ),
                    ),
                    Positioned(
                      top: -6,
                      right: -6,
                      child: GestureDetector(
                        onTap: () => setState(
                            () => _pendingImages.removeAt(i)),
                        child: Container(
                          width: 18,
                          height: 18,
                          decoration: const BoxDecoration(
                            color: Colors.black54,
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(Icons.close_rounded,
                              size: 12, color: Colors.white),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '${_pendingImages.length}',
              style: const TextStyle(color: Colors.white54, fontSize: 13),
            ),
            IconButton(
              onPressed: () => setState(() => _pendingImages.clear()),
              icon: const Icon(Icons.close_rounded, size: 20),
              color: Colors.white54,
              visualDensity: VisualDensity.compact,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAttachPanel() {
    return AnimatedSize(
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: _showAttach
          ? Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.75),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: ZzzColors.grayPanel, width: 3),
                  
                ),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 80),
                  child: SingleChildScrollView(
                    child: Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      alignment: WrapAlignment.spaceEvenly,
                      children: [
                        for (final item in _attachItems)
                          _AttachButton(
                            icon: item.icon,
                            label: item.tooltip,
                            onTap: item.tooltip == 'Location'
                                ? null
                                : () => _pickAndStageMedia(item.tooltip),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            )
          : const SizedBox.shrink(),
    );
  }

  Widget _buildComposer() {
    return Row(
      children: [
        Expanded(
          child: Focus(
            onKeyEvent: (_, event) {
              if (event is KeyDownEvent &&
                  event.logicalKey == LogicalKeyboardKey.keyV &&
                  HardwareKeyboard.instance.isMetaPressed) {
                _pasteFromClipboardWithLog().then((path) {
                  if (path != null && mounted) {
                    setState(() {
                      _pendingImages.add(path);
                      _pendingKind = ImMessageKind.image;
                    });
                  }
                });
              }
              return KeyEventResult.ignored;
            },
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
          onPressed: _toggleAttach,
          style: IconButton.styleFrom(
            backgroundColor: _showAttach ? ZzzColors.yellow : Colors.white,
            foregroundColor: Colors.black,
            minimumSize: const Size(52, 52),
          ),
          icon: AnimatedRotation(
            turns: _showAttach ? 0.125 : 0,
            duration: const Duration(milliseconds: 250),
            child: const Icon(Icons.add_rounded, size: 26),
          ),
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

/// Collapsible recalled-message banner — system-message style.
class _RecalledBanner extends StatefulWidget {
  const _RecalledBanner({required this.message, required this.senderName});
  final ImMessage message;
  final String senderName;

  @override
  State<_RecalledBanner> createState() => _RecalledBannerState();
}

class _RecalledBannerState extends State<_RecalledBanner> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onTap: () => setState(() => _expanded = !_expanded),
          child: Container(
            margin: const EdgeInsets.symmetric(vertical: 4),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  _expanded ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                  size: 16,
                  color: Colors.white38,
                ),
                const SizedBox(width: 6),
                Text(
                  '${widget.senderName} recalled a message',
                  style: const TextStyle(color: Colors.white38, fontSize: 12),
                ),
              ],
            ),
          ),
        ),
        if (_expanded)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Opacity(
              opacity: 0.6,
              child: _RecalledContent(message: widget.message),
            ),
          ),
      ],
    );
  }
}

/// Renders recalled message content without the outer bubble (avoids
/// recursion from [ImMessageBubble] checking `recalled` again).
class _RecalledContent extends StatelessWidget {
  const _RecalledContent({required this.message});
  final ImMessage message;

  @override
  Widget build(BuildContext context) {
    if (message.hasMedia && message.mediaPath != null) {
      if (message.kind == ImMessageKind.image) {
        return ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Image.file(File(message.mediaPath!),
              width: 200, fit: BoxFit.cover),
        );
      }
      if (message.kind == ImMessageKind.record) {
        return _VoiceBubble(
          fileId: null,
          url: null,
          localPath: message.mediaPath,
          isMine: message.isMine,
          fileSize: message.mediaSize,
        );
      }
    }
    return Container(
      constraints: const BoxConstraints(maxWidth: 250),
      child: Text(
        message.text,
        style: const TextStyle(color: Colors.white54, fontSize: 13),
      ),
    );
  }
}

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

/// A single attach-function button (icon + label below).
class _AttachButton extends StatelessWidget {
  const _AttachButton({
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

/// Forward / combined message bubble — tap to open in a dialog.
class _ForwardBubble extends StatefulWidget {
  const _ForwardBubble({required this.message});
  final ImMessage message;

  @override
  State<_ForwardBubble> createState() => _ForwardBubbleState();
}

class _ForwardBubbleState extends State<_ForwardBubble> {
  List<String>? _preview;

  String get _forwardId {
    final seg = widget.message.segments?.firstOrNull;
    return seg?.data['id']?.toString() ?? '';
  }

  @override
  void initState() {
    super.initState();
    Future.microtask(() => _loadPreview());
  }

  Future<void> _loadPreview() async {
    final id = _forwardId;
    if (id.isEmpty) return;
    try {
      final group = await ImScope.interactionsOf(context)
          .getForwardMessages(id);
      if (!mounted) return;
      final lines = _collectPreview(group, 3);
      if (!mounted) return;
      setState(() => _preview = lines);
    } catch (_) {}
  }

  List<String> _collectPreview(ForwardGroup g, int max) {
    final lines = <String>[];
    for (final msg in g.messages) {
      if (lines.length >= max) break;
      if (msg.text.isNotEmpty) {
        final sender = msg.senderId.isNotEmpty ? msg.senderId : '';
        lines.add(sender.isNotEmpty ? '$sender: ${msg.text}' : msg.text);
      }
    }
    for (final child in g.children) {
      if (lines.length >= max) break;
      lines.addAll(_collectPreview(child, max - lines.length));
    }
    return lines;
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => _showForwardDialog(context),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 320),
        child: Container(
          margin: const EdgeInsets.only(bottom: 6),
          decoration: BoxDecoration(
            color: const Color(0xFF12121e).withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: ZzzColors.grayPanel, width: 3),
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
                      const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.forward_rounded,
                              size: 13, color: ZzzColors.yellow),
                          SizedBox(width: 4),
                          Flexible(
                            child: Text(
                              'Chat records',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: ZzzColors.yellow,
                              ),
                            ),
                          ),
                        ],
                      ),
                      if (_preview != null && _preview!.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        ..._preview!.map(
                          (l) => Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(
                              l,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  color: Colors.white54, fontSize: 11),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      ),
    );
  }

  void _showForwardDialog(BuildContext context) {
    final id = _forwardId;
    if (id.isEmpty) return;
    showDialog(
      context: context,
      builder: (_) => _ForwardDialog(forwardId: id),
    );
  }
}

class _ForwardDialog extends StatefulWidget {
  const _ForwardDialog({required this.forwardId});
  final String forwardId;

  @override
  State<_ForwardDialog> createState() => _ForwardDialogState();
}

class _ForwardDialogState extends State<_ForwardDialog> {
  ForwardGroup? _group;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    try {
      final g = await ImScope.interactionsOf(context)
          .getForwardMessages(widget.forwardId);
      if (mounted) setState(() => _group = g);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  List<Widget> _buildForwardChildren(ForwardGroup group, int depth) =>
      _buildForwardList(group, depth);

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF12121e),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          maxWidth: 420,
          maxHeight: 560,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Title bar
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
              child: Row(
                children: [
                  const Icon(Icons.forward_rounded,
                      size: 20, color: Colors.white54),
                  const SizedBox(width: 8),
                  const Text(
                    'Chat records',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded, size: 20),
                    color: Colors.white54,
                  ),
                ],
              ),
            ),
            const Divider(height: 1, color: Colors.white10),
            // Message list
            Flexible(
              child: _error != null
                  ? Padding(
                      padding: const EdgeInsets.all(32),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.error_outline,
                              size: 32, color: Colors.white24),
                          const SizedBox(height: 8),
                          Text(_error!,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                  color: Colors.white38, fontSize: 12)),
                        ],
                      ),
                    )
                  : _group == null
                      ? const Padding(
                          padding: EdgeInsets.all(32),
                          child:
                              Center(child: CircularProgressIndicator()),
                        )
                      : _group!.isEmpty
                          ? const Padding(
                              padding: EdgeInsets.all(32),
                              child: Text('Empty',
                                  style:
                                      TextStyle(color: Colors.white38)),
                            )
                          : ListView(
                              shrinkWrap: true,
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 8),
                              children:
                                  _buildForwardChildren(_group!, 0),
                            ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Collapsible nested forward group.
class _NestedForwardGroup extends StatefulWidget {
  const _NestedForwardGroup({required this.group, required this.depth});
  final ForwardGroup group;
  final int depth;

  @override
  State<_NestedForwardGroup> createState() => _NestedForwardGroupState();
}

class _NestedForwardGroupState extends State<_NestedForwardGroup> {
  bool _expanded = false;
  int? _msgCount;
  List<String>? _previewLines;

  int _countAll(ForwardGroup g) {
    var c = g.messages.length;
    for (final child in g.children) {
      c += _countAll(child);
    }
    return c;
  }

  List<String> _buildPreview(ForwardGroup g, {int max = 3}) {
    final lines = <String>[];
    for (final msg in g.messages) {
      if (lines.length >= max) break;
      if (msg.text.isNotEmpty) {
        final sender = msg.senderId.isNotEmpty ? msg.senderId : '';
        lines.add(sender.isNotEmpty ? '$sender: ${msg.text}' : msg.text);
      }
    }
    for (final child in g.children) {
      if (lines.length >= max) break;
      lines.addAll(_buildPreview(child, max: max - lines.length));
    }
    return lines;
  }

  @override
  Widget build(BuildContext context) {
    _msgCount ??= _countAll(widget.group);
    _previewLines ??= _buildPreview(widget.group);
    return Padding(
      padding:
          EdgeInsets.only(left: 16.0 * widget.depth, top: 6, bottom: 2),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.white10),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            GestureDetector(
              onTap: () => setState(() => _expanded = !_expanded),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 1),
                    child: Icon(
                      _expanded
                          ? Icons.expand_less_rounded
                          : Icons.expand_more_rounded,
                      size: 14,
                      color: Colors.white38,
                    ),
                  ),
                  const SizedBox(width: 6),
                  const Icon(Icons.forward_rounded,
                      size: 14, color: Colors.white38),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'Chat records ($_msgCount msg${_msgCount == 1 ? '' : 's'})',
                          style: const TextStyle(
                              color: Colors.white38, fontSize: 11),
                        ),
                        if (!_expanded && _previewLines!.isNotEmpty)
                          ..._previewLines!.take(3).map(
                                (l) => Padding(
                                  padding: const EdgeInsets.only(top: 2),
                                  child: Text(
                                    l,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                        color: Colors.white24,
                                        fontSize: 10),
                                  ),
                                ),
                              ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            if (_expanded) ...[
              const SizedBox(height: 6),
              ..._buildForwardList(widget.group, widget.depth + 1),
            ],
          ],
        ),
      ),
    );
  }
}

List<Widget> _buildForwardList(ForwardGroup group, int depth) {
  final widgets = <Widget>[];
  for (final msg in group.messages) {
    widgets.add(_ForwardMsgTile(msg: msg));
  }
  for (final child in group.children) {
    widgets.add(_NestedForwardGroup(group: child, depth: depth));
  }
  return widgets;
}

/// Renders a single forwarded message with sender avatar/name + content.
class _ForwardMsgTile extends StatefulWidget {
  const _ForwardMsgTile({required this.msg});
  final ImMessage msg;

  @override
  State<_ForwardMsgTile> createState() => _ForwardMsgTileState();
}

class _ForwardMsgTileState extends State<_ForwardMsgTile> {
  ImageProvider? _avatar;

  @override
  void initState() {
    super.initState();
    Future.microtask(() => _loadAvatar());
  }

  Future<void> _loadAvatar() async {
    final path = await ImScope.interactionsOf(context)
        .getUserAvatarPath(widget.msg.senderId);
    if (!mounted) return;
    if (path != null) {
      setState(() => _avatar = FileImage(File(path)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final msg = widget.msg;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: SizedBox(
              width: 32,
              height: 32,
              child: CircleAvatar(
                radius: 16,
                backgroundImage: _avatar ??
                    const AssetImage(
                        'assets/icons/zzz_agent_profile_icon.png'),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  msg.senderId,
                  style: const TextStyle(
                    color: Colors.white38,
                    fontSize: 11,
                  ),
                ),
                const SizedBox(height: 4),
                ...msg.segments
                        ?.map((s) =>
                            _renderSegment(context, s)) ??
                    [Text(msg.text,
                        style: const TextStyle(
                            color: Colors.white70, fontSize: 13))],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _renderSegment(BuildContext context, OneBotMessageSegment seg) {
    switch (seg.type) {
      case 'image':
        final localPath = seg.data['_localPath'] as String?;
        final url = seg.data['url'] as String?;
        if (localPath != null) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: _NsfwGuard(
              messageId: 'fw_${localPath.hashCode}',
              mediaPath: localPath,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.file(
                  File(localPath),
                  width: 180,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => const Icon(
                      Icons.broken_image, size: 32, color: Colors.white24),
                ),
              ),
            ),
          );
        }
        if (url != null && url.isNotEmpty) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.network(url, width: 180, fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => const Icon(
                      Icons.broken_image, size: 32, color: Colors.white24)),
            ),
          );
        }
        return const Icon(Icons.image, size: 32, color: Colors.white24);
      case 'text':
        return Text(
          seg.data['text'] as String? ?? '',
          style: const TextStyle(color: Colors.white70, fontSize: 13),
        );
      case 'forward':
        // NapCat already expands nested forwards; the inner messages
        // are in the outer response.  Just show a static label.
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.05),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.white10),
          ),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.forward_rounded,
                  size: 14, color: Colors.white38),
              SizedBox(width: 6),
              Text('Chat records',
                  style:
                      TextStyle(color: Colors.white38, fontSize: 11)),
            ],
          ),
        );
      default:
        return Text(
          '[${seg.type}]',
          style: const TextStyle(color: Colors.white38, fontSize: 12),
        );
    }
  }
}

/// Voice message bubble — play / pause button + duration display.
class _VoiceBubble extends StatefulWidget {
  const _VoiceBubble({
    this.fileId,
    this.url,
    this.localPath,
    required this.isMine,
    this.fileSize,
  });

  final String? fileId;
  final String? url;
  final String? localPath;
  final bool isMine;
  final int? fileSize;

  @override
  State<_VoiceBubble> createState() => _VoiceBubbleState();
}

class _VoiceBubbleState extends State<_VoiceBubble> {
  final _player = AudioPlayer();
  PlayerState _playerState = PlayerState.stopped;
  Duration _duration = Duration.zero;
  Duration _position = Duration.zero;
  String? _resolvedPath;
  bool _downloading = false;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _player.onPlayerStateChanged.listen((s) {
      if (mounted) setState(() => _playerState = s);
    });
    _player.onDurationChanged.listen((d) {
      if (mounted) setState(() => _duration = d);
    });
    _player.onPositionChanged.listen((p) {
      if (mounted) setState(() => _position = p);
    });
    _player.onPlayerComplete.listen((_) {
      if (mounted) setState(() {});
    });
    if (widget.localPath != null && widget.localPath!.isNotEmpty) {
      _resolvedPath = widget.localPath;
      _initSource();
    }
  }

  Future<void> _initSource() async {
    if (_resolvedPath == null) return;
    try {
      await _player.setSourceDeviceFile(_resolvedPath!);
      await _player.setReleaseMode(ReleaseMode.stop);
      if (mounted) setState(() => _ready = true);
    } catch (_) {}
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  Future<void> _ensureDownloaded() async {
    if (_resolvedPath != null) return;
    if (_downloading) return;
    final fid = widget.fileId;
    if (fid == null || fid.isEmpty) return;
    setState(() => _downloading = true);
    try {
      final path = await ImScope.interactionsOf(context).downloadRecord(
        fileId: fid,
        url: widget.url,
      );
      if (path != null && path.isNotEmpty) {
        _resolvedPath = path;
        await _initSource();
      }
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }

  void _togglePlay() async {
    if (!_ready) {
      await _ensureDownloaded();
      if (!_ready) return;
    }
    switch (_playerState) {
      case PlayerState.playing:
        _player.pause();
        break;
      case PlayerState.paused:
        _player.resume();
        break;
      case PlayerState.stopped:
      case PlayerState.completed:
        _player.seek(Duration.zero);
        _player.resume();
        break;
      case PlayerState.disposed:
        break;
    }
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  int get _estimatedSecs {
    if (_duration > Duration.zero) return _duration.inSeconds;
    final bytes = widget.fileSize;
    if (bytes != null && bytes > 0) return (bytes / 2000).round();
    return 0;
  }

  Duration get _total => _duration > Duration.zero
      ? _duration
      : Duration(seconds: _estimatedSecs);

  @override
  Widget build(BuildContext context) {
    final isPlaying = _playerState == PlayerState.playing;
    final label = '${_fmt(_position)} / ${_fmt(_total)}';
    final icon = _downloading
        ? Icons.downloading_rounded
        : _ready
            ? (isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded)
            : Icons.play_arrow_rounded;

    return SizedBox(
      width: 200,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: widget.isMine
              ? const Color(0xFF007AFF)
              : const Color(0xFFe8e8ec),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            GestureDetector(
              onTap: _downloading ? null : _togglePlay,
              child: Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: widget.isMine
                      ? Colors.white.withValues(alpha: 0.22)
                      : Colors.black12,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  icon,
                  color: widget.isMine ? Colors.white : Colors.black87,
                  size: 24,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  color: widget.isMine ? Colors.white : Colors.black87,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
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
