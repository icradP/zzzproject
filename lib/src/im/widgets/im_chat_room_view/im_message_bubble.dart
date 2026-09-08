import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../theme/zzz_colors.dart';
import '../../../widgets/zzz_widgets.dart';
import '../../models/im_models.dart';
import '../../content/im_content.dart';
import '../../data/im_sticker_catalog.dart';
import '../../dynamic/im_dynamic.dart';
import 'im_file_card.dart';
import 'im_forward_bubble.dart';
import 'im_message_content_view.dart';
import 'im_nsfw_guard.dart';
import '../im_platform_image_widget.dart' show platformImageWidget;
import 'im_reaction_chips.dart';
import 'im_reply_quote_bar.dart';
import 'im_share_bubbles.dart';
import 'im_voice_bubble.dart';

String? _previewLocationFor(ImMessage message) =>
    message.thumbnailPath ??
    message.thumbnailUrl ??
    message.mediaPath ??
    message.mediaUrl;

/// Collapsible recalled-message banner — system-message style.
class _RecalledBanner extends StatefulWidget {
  const _RecalledBanner({required this.senderName, required this.content});

  final String senderName;
  final Widget content;

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
                  _expanded
                      ? Icons.expand_less_rounded
                      : Icons.expand_more_rounded,
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
            child: Opacity(opacity: 0.6, child: widget.content),
          ),
      ],
    );
  }
}

/// A single chat message bubble.
///
/// Handles all message types: text, image, voice, video, file, forward,
/// reply, system, poke, json mini-program, and recalled messages.
class ImMessageBubble extends StatelessWidget {
  const ImMessageBubble({
    required this.message,
    this.assetPackage,
    required this.senderName,
    required this.avatar,
    required this.showSenderName,
    this.hideAvatar = false,
    this.compact = false,
    this.hideTimestamp = false,
    this.showMessageStatus = false,
    this.highlighted = false,
    this.resolveQuote,
    this.onQuoteTap,
    this.resolveUserName,
    this.onReactionTap,
    this.dynamicContentRegistry,
    this.dynamicRuntimeStore,
    this.contentAdapterRegistry,
    this.contentNodeAdapterRegistry,
    this.contentRendererRegistry,
    this.onContentEvent,
    this.onDynamicEvent,
    super.key,
  });

  final ImMessage message;
  final String? assetPackage;
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

  /// Shows sending, delivery, read, and failure indicators for own messages.
  final bool showMessageStatus;

  /// When true the message bubble glows yellow briefly (scroll-to target).
  final bool highlighted;

  /// If this message is a reply, returns the source message being quoted.
  final ImMessage? Function(String messageId)? resolveQuote;

  /// Called when the quote bar is tapped; the caller scrolls to the source.
  final VoidCallback? onQuoteTap;

  /// Resolves a user ID to a display name (for the quote bar sender).
  final Future<String> Function(String userId)? resolveUserName;

  /// Called when the user taps an existing reaction chip.
  final ValueChanged<ImReaction>? onReactionTap;

  final ImDynamicComponentRegistry? dynamicContentRegistry;
  final ImDynamicRuntimeStore? dynamicRuntimeStore;
  final ImMessageContentAdapterRegistry? contentAdapterRegistry;
  final ImContentAdapterRegistry? contentNodeAdapterRegistry;
  final ImContentRendererRegistry? contentRendererRegistry;
  final ValueChanged<ImContentEvent>? onContentEvent;
  final ValueChanged<ImDynamicEvent>? onDynamicEvent;

  @override
  Widget build(BuildContext context) {
    final contentTree = resolveImMessageContentTree(
      message: message,
      legacyAdapterRegistry: contentAdapterRegistry,
      adapterRegistry: contentNodeAdapterRegistry,
    );
    final hasStructuredContent = imContentTreeHasStructuredContent(contentTree);
    final sticker = ImStickerCatalog.resolveMessage(message);

    Widget buildMessageContent({required bool readOnlyPreview}) {
      return ImMessageContentView(
        tree: contentTree,
        hasStructuredContent: hasStructuredContent,
        rendererRegistry: contentRendererRegistry,
        onEvent: onContentEvent,
        readOnlyPreview: readOnlyPreview,
        fallback:
            (
              buildContext,
              node, {
              required bool hasStructuredContent,
              required bool readOnlyPreview,
            }) => _buildContentNode(
              buildContext,
              node,
              hasStructuredContent: hasStructuredContent,
              sticker: sticker,
              readOnlyPreview: readOnlyPreview,
            ),
        emptyBuilder:
            (_, {required bool readOnlyPreview}) => Text(
              message.text,
              style: _messageTextStyle(readOnlyPreview: readOnlyPreview),
            ),
      );
    }

    if (message.recalled) {
      return _RecalledBanner(
        senderName: senderName,
        content: buildMessageContent(readOnlyPreview: true),
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
    final bubbleContent = buildMessageContent(readOnlyPreview: false);

    if (message.kind == ImMessageKind.system ||
        message.kind == ImMessageKind.poke) {
      return bubbleContent;
    }

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
            : isImageOnly ||
                isRecordOnly ||
                isJsonCard ||
                isForward ||
                message.kind == ImMessageKind.share ||
                message.kind == ImMessageKind.location ||
                sticker != null
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
                child: ImReplyQuoteBar(
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
              child: ImReactionChips(
                reactions: message.reactions!,
                isMine: isMine,
                onTap: onReactionTap,
              ),
            ),
          if (!hideTimestamp) ...[
            const SizedBox(height: 2),
            _buildMessageMeta(),
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

  Widget _buildMessageMeta() {
    final status =
        showMessageStatus && message.isMine ? _statusPresentation() : null;
    return Wrap(
      alignment: message.isMine ? WrapAlignment.end : WrapAlignment.start,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 6,
      runSpacing: 2,
      children: [
        Text(
          _formatClock(message.sentAt),
          style: const TextStyle(color: Colors.white30, fontSize: 10),
        ),
        if (status != null)
          Semantics(
            label: '消息状态：${status.label}',
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(status.icon, size: 12, color: status.color),
                const SizedBox(width: 3),
                Text(
                  status.label,
                  style: TextStyle(color: status.color, fontSize: 10),
                ),
              ],
            ),
          ),
      ],
    );
  }

  _MessageStatusPresentation _statusPresentation() {
    return switch (message.status) {
      ImMessageStatus.sending => const _MessageStatusPresentation(
        label: '发送中',
        icon: Icons.schedule_rounded,
        color: Colors.white38,
      ),
      ImMessageStatus.sent => const _MessageStatusPresentation(
        label: '已发送',
        icon: Icons.done_rounded,
        color: Colors.white38,
      ),
      ImMessageStatus.delivered => const _MessageStatusPresentation(
        label: '已送达',
        icon: Icons.done_all_rounded,
        color: Colors.white54,
      ),
      ImMessageStatus.read => _MessageStatusPresentation(
        label:
            message.recipientCount > 1
                ? '已读 ${message.readCount}/${message.recipientCount}'
                : '已读',
        icon: Icons.done_all_rounded,
        color: const Color(0xFF61D095),
      ),
      ImMessageStatus.failed => const _MessageStatusPresentation(
        label: '发送失败',
        icon: Icons.error_outline_rounded,
        color: Color(0xFFFF6B6B),
      ),
    };
  }

  String _formatClock(DateTime time) {
    final hour = time.hour.toString().padLeft(2, '0');
    final minute = time.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  Uri? _mediaUri() {
    final location = message.mediaPath ?? message.mediaUrl;
    if (location == null || location.trim().isEmpty) return null;
    final parsed = Uri.tryParse(location);
    if (parsed != null && parsed.hasScheme) return parsed;
    return Uri.file(location);
  }

  Future<void> _openMedia(BuildContext context, Uri uri) async {
    try {
      final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (opened || !context.mounted) return;
    } catch (_) {
      if (!context.mounted) return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Unable to open this attachment.')),
    );
  }

  Widget _buildContentNode(
    BuildContext context,
    ImContentNode node, {
    required bool hasStructuredContent,
    required ImStickerDefinition? sticker,
    required bool readOnlyPreview,
  }) {
    if (message.kind == ImMessageKind.system) {
      return _buildSystemMessage();
    }
    if (message.kind == ImMessageKind.poke) {
      return _buildPokeMessage();
    }
    final content = node.dynamicContent;
    if (content != null) {
      return ImDynamicContentView(
        messageId: message.id,
        content: content,
        registry: dynamicContentRegistry,
        runtimeStore: dynamicRuntimeStore,
        onEvent: _emitDynamicEvent,
      );
    }
    if (_isDynamicPrimitive(node.type)) {
      return ImDynamicContentView(
        messageId: message.id,
        content: ImDynamicContent(
          id: node.id,
          version: '1.0',
          source: ImDynamicContentSource.system,
          tree: node.toDynamicNode(),
        ),
        registry: dynamicContentRegistry,
        runtimeStore: dynamicRuntimeStore,
        onEvent: _emitDynamicEvent,
      );
    }
    if (!hasStructuredContent) {
      return _buildLegacyMessageContent(
        context,
        node,
        sticker,
        readOnlyPreview: readOnlyPreview,
      );
    }
    return _buildCompanionContent(
      context,
      node,
      sticker,
      readOnlyPreview: readOnlyPreview,
    );
  }

  Widget _buildSystemMessage() {
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

  Widget _buildPokeMessage() {
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
            const Icon(
              Icons.touch_app_rounded,
              size: 16,
              color: Colors.white54,
            ),
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

  Widget _buildLegacyMessageContent(
    BuildContext context,
    ImContentNode node,
    ImStickerDefinition? sticker, {
    required bool readOnlyPreview,
  }) {
    if (sticker != null) {
      return _buildSticker(
        sticker,
        onTap: () => _emitContentEvent(node, 'tap', const {}),
      );
    }
    if (message.kind == ImMessageKind.forward) {
      return ImForwardBubble(
        message: message,
        onOpen: () => _emitContentEvent(node, 'open', const {}),
      );
    }
    if (message.kind == ImMessageKind.record) {
      return ImVoiceBubble(
        fileId: node.data['file']?.toString(),
        url: node.data['url']?.toString(),
        localPath: message.mediaPath,
        isMine: message.isMine,
        fileSize: message.mediaSize,
        declaredDuration: message.mediaDuration,
        onPlay: () => _emitContentEvent(node, 'play', const {}),
        onPause: () => _emitContentEvent(node, 'pause', const {}),
      );
    }
    if (message.kind == ImMessageKind.share) {
      return ImLinkBubble(
        message: message,
        onOpen:
            (uri) => _emitContentEvent(node, 'open', {'uri': uri.toString()}),
      );
    }
    if (message.kind == ImMessageKind.location) {
      return ImLocationBubble(
        message: message,
        onOpen:
            (uri) => _emitContentEvent(node, 'open', {'uri': uri.toString()}),
      );
    }
    if (message.kind == ImMessageKind.file ||
        message.kind == ImMessageKind.video) {
      final mediaUri = _mediaUri();
      final isVideo = message.kind == ImMessageKind.video;
      return ImFileCard(
        fileName:
            message.text.isNotEmpty
                ? message.text
                : (isVideo ? 'Video' : 'Unknown file'),
        fileSize: message.mediaSize,
        isMine: message.isMine,
        isVideo: isVideo,
        onOpen:
            mediaUri == null
                ? null
                : () {
                  _emitContentEvent(node, 'open', {'uri': mediaUri.toString()});
                  unawaited(_openMedia(context, mediaUri));
                },
      );
    }
    final isJsonCard = message.kind == ImMessageKind.json;
    final hasImage =
        message.hasMedia && (message.kind == ImMessageKind.image || isJsonCard);
    if (!hasImage) {
      return Text(
        message.text,
        style: _messageTextStyle(readOnlyPreview: readOnlyPreview),
      );
    }
    return _buildImageContent(
      context,
      node: node,
      isJsonCard: isJsonCard,
      readOnlyPreview: readOnlyPreview,
    );
  }

  Widget _buildImageContent(
    BuildContext context, {
    required ImContentNode node,
    required bool isJsonCard,
    required bool readOnlyPreview,
  }) {
    final previewLocation = _previewLocationFor(message);
    if (previewLocation == null) {
      return Text(
        message.text,
        style: _messageTextStyle(readOnlyPreview: readOnlyPreview),
      );
    }
    if (isJsonCard) {
      return ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 250),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            GestureDetector(
              onTap:
                  () =>
                      _emitContentEvent(node, 'tap', {'uri': previewLocation}),
              child: ImNsfwGuard(
                messageId: message.id,
                mediaPath: previewLocation,
                child: ClipRRect(
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(14),
                  ),
                  child: platformImageWidget(
                    previewLocation,
                    fit: BoxFit.scaleDown,
                    errorBuilder:
                        (context, error, stack) => const SizedBox.shrink(),
                  ),
                ),
              ),
            ),
            Container(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
              decoration: BoxDecoration(
                color:
                    message.isMine
                        ? ZzzColors.blue.withValues(alpha: 0.85)
                        : const Color(0xFFe8e8ec),
                borderRadius: const BorderRadius.vertical(
                  bottom: Radius.circular(14),
                ),
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
                      color: message.isMine ? Colors.white70 : Colors.black54,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '小程序',
                    style: TextStyle(
                      fontSize: 10,
                      color: message.isMine ? Colors.white38 : Colors.black38,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }
    final isImageOnly = message.text.isEmpty || message.text == '[图片]';
    return GestureDetector(
      onTap: () => _emitContentEvent(node, 'tap', {'uri': previewLocation}),
      child: ImNsfwGuard(
        messageId: message.id,
        mediaPath: previewLocation,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(isImageOnly ? 18 : 12),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 250, maxHeight: 400),
            child: platformImageWidget(
              previewLocation,
              fit: BoxFit.scaleDown,
              errorBuilder:
                  (context, error, stack) => Text(
                    message.text,
                    style: _messageTextStyle(readOnlyPreview: readOnlyPreview),
                  ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCompanionContent(
    BuildContext context,
    ImContentNode node,
    ImStickerDefinition? sticker, {
    required bool readOnlyPreview,
  }) {
    final data = node.data;
    switch (node.type) {
      case ImContentNodeType.dynamicContent:
        final fallback = ImDynamicFallback.tryFromSegmentData(data);
        final text = fallback?.content.trim();
        return SelectableText(
          text == null || text.isEmpty
              ? 'Unable to display this dynamic content.'
              : text,
          style: _messageTextStyle(readOnlyPreview: readOnlyPreview),
        );
      case ImContentNodeType.text:
        return Text(
          data['text']?.toString() ?? '',
          style: _messageTextStyle(readOnlyPreview: readOnlyPreview),
        );
      case ImContentNodeType.image:
        final location = data['url']?.toString() ?? data['file']?.toString();
        if (location == null || location.trim().isEmpty) {
          return const SizedBox.shrink();
        }
        return GestureDetector(
          onTap: () => _emitContentEvent(node, 'tap', {'uri': location}),
          child: ImNsfwGuard(
            messageId: '${message.id}:${node.id}',
            mediaPath: location,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: 250,
                  maxHeight: 400,
                ),
                child: platformImageWidget(
                  location,
                  fit: BoxFit.scaleDown,
                  errorBuilder:
                      (context, error, stack) => const SizedBox.shrink(),
                ),
              ),
            ),
          ),
        );
      case ImContentNodeType.audio:
        final rawDuration = data['duration_ms'];
        return ImVoiceBubble(
          fileId: data['file']?.toString(),
          url: data['url']?.toString(),
          localPath:
              message.kind == ImMessageKind.record ? message.mediaPath : null,
          isMine: message.isMine,
          fileSize: (data['size'] as num?)?.toInt() ?? message.mediaSize,
          declaredDuration:
              rawDuration is num
                  ? Duration(milliseconds: rawDuration.toInt())
                  : message.mediaDuration,
          onPlay: () => _emitContentEvent(node, 'play', const {}),
          onPause: () => _emitContentEvent(node, 'pause', const {}),
        );
      case ImContentNodeType.file:
      case ImContentNodeType.video:
        final location = data['url']?.toString() ?? data['file']?.toString();
        final parsed = location == null ? null : Uri.tryParse(location);
        final uri =
            location == null || location.trim().isEmpty
                ? null
                : (parsed?.hasScheme == true ? parsed : Uri.file(location));
        return ImFileCard(
          fileName:
              data['name']?.toString() ??
              data['file']?.toString() ??
              (node.type == ImContentNodeType.video ? 'Video' : 'File'),
          fileSize: (data['size'] as num?)?.toInt(),
          isMine: message.isMine,
          isVideo: node.type == ImContentNodeType.video,
          onOpen:
              uri == null
                  ? null
                  : () {
                    _emitContentEvent(node, 'open', {'uri': uri.toString()});
                    unawaited(_openMedia(context, uri));
                  },
        );
      case ImContentNodeType.share:
        return ImLinkBubble(
          message: message,
          onOpen:
              (uri) => _emitContentEvent(node, 'open', {'uri': uri.toString()}),
        );
      case ImContentNodeType.location:
        return ImLocationBubble(
          message: message,
          onOpen:
              (uri) => _emitContentEvent(node, 'open', {'uri': uri.toString()}),
        );
      case ImContentNodeType.forward:
        return ImForwardBubble(
          message: message,
          onOpen: () => _emitContentEvent(node, 'open', const {}),
        );
      case ImContentNodeType.sticker:
        return sticker == null
            ? Text(
              message.text,
              style: _messageTextStyle(readOnlyPreview: readOnlyPreview),
            )
            : _buildSticker(
              sticker,
              onTap: () => _emitContentEvent(node, 'tap', const {}),
            );
      case ImContentNodeType.system:
        return Text(
          message.text,
          style: _messageTextStyle(readOnlyPreview: readOnlyPreview),
        );
      case ImContentNodeType.reply:
        return const SizedBox.shrink();
      case ImContentNodeType.markdown:
      case ImContentNodeType.icon:
      case ImContentNodeType.row:
      case ImContentNodeType.column:
      case ImContentNodeType.card:
      case ImContentNodeType.container:
      case ImContentNodeType.divider:
      case ImContentNodeType.button:
      case ImContentNodeType.input:
      case ImContentNodeType.checkbox:
      case ImContentNodeType.select:
      case ImContentNodeType.progress:
      case ImContentNodeType.status:
      case ImContentNodeType.badge:
        return const SizedBox.shrink();
      case ImContentNodeType.unknown:
        return Text(
          '[${node.wireType}]',
          style: _messageTextStyle(
            fontSize: 13,
            readOnlyPreview: readOnlyPreview,
          ),
        );
    }
  }

  Widget _buildSticker(ImStickerDefinition sticker, {VoidCallback? onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Semantics(
        label: 'Sticker: ${sticker.label}',
        child: SizedBox.square(
          dimension: 150,
          child: Image.asset(
            sticker.assetPath,
            package: assetPackage,
            fit: BoxFit.contain,
            errorBuilder:
                (_, __, ___) => Text(
                  message.text,
                  style: const TextStyle(color: Colors.white70),
                ),
          ),
        ),
      ),
    );
  }

  TextStyle _messageTextStyle({
    double fontSize = 15,
    bool readOnlyPreview = false,
  }) {
    return TextStyle(
      color:
          readOnlyPreview
              ? Colors.white70
              : (message.isMine ? Colors.white : Colors.black87),
      fontSize: fontSize,
      height: 1.35,
    );
  }

  void _emitContentEvent(
    ImContentNode node,
    String type,
    Map<String, dynamic> payload,
  ) {
    onContentEvent?.call(
      ImContentEvent(
        messageId: message.id,
        contentId: node.id,
        type: type,
        payload: payload,
      ),
    );
  }

  void _emitDynamicEvent(ImDynamicEvent event) {
    onDynamicEvent?.call(event);
    onContentEvent?.call(event);
  }

  bool _isDynamicPrimitive(ImContentNodeType type) {
    return switch (type) {
      ImContentNodeType.markdown ||
      ImContentNodeType.icon ||
      ImContentNodeType.row ||
      ImContentNodeType.column ||
      ImContentNodeType.card ||
      ImContentNodeType.container ||
      ImContentNodeType.divider ||
      ImContentNodeType.button ||
      ImContentNodeType.input ||
      ImContentNodeType.checkbox ||
      ImContentNodeType.select ||
      ImContentNodeType.progress ||
      ImContentNodeType.status ||
      ImContentNodeType.badge => true,
      _ => false,
    };
  }
}

class _MessageStatusPresentation {
  const _MessageStatusPresentation({
    required this.label,
    required this.icon,
    required this.color,
  });

  final String label;
  final IconData icon;
  final Color color;
}
