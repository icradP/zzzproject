import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:pasteboard/pasteboard.dart';
import 'package:mime/mime.dart';
import 'package:super_sliver_list/super_sliver_list.dart';

import '../../assets/app_assets.dart';
import '../../theme/zzz_colors.dart';
import '../../widgets/zzz_widgets.dart';
import '../im_scope.dart';
import '../data/im_draft_store.dart';
import '../data/im_message_display_config.dart';
import '../data/im_sticker_catalog.dart';
import '../models/im_models.dart';
import 'im_chat_widgets.dart';

/// Main chat room view with message list, composer, and attachments.
class ImChatRoomView extends StatefulWidget {
  const ImChatRoomView({
    required this.conversation,
    required this.messages,
    required this.onSend,
    required this.resolveUserName,
    required this.resolveUserAvatar,
    this.resolveMessage,
    this.onReply,
    this.onRecall,
    this.onReact,
    this.onSticker,
    this.onLoadOlder,
    this.onManageGroup,
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
  final Future<void> Function(String text, ImMessage replyTo)? onReply;
  final Future<void> Function(ImMessage message)? onRecall;
  final Future<void> Function(ImMessage message, String emojiId, bool remove)?
  onReact;
  final Future<void> Function(ImStickerReference sticker)? onSticker;
  final Future<bool> Function()? onLoadOlder;
  final VoidCallback? onManageGroup;
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
  bool _showStickers = false;
  ImMessage? _replyingTo;
  String? _highlightMessageId;
  final _pendingMedia = <ImMediaUpload>[];
  double _lastMaxExtent = 0;
  bool _loadingOlder = false;
  bool _canLoadOlder = true;
  bool _draftRestoreStarted = false;
  String? _draftOwnerId;
  Timer? _draftSaveTimer;
  late bool _showMessageStatus;

  @override
  void initState() {
    super.initState();
    _lastMaxExtent = 0;
    _showMessageStatus = ImMessageDisplayConfig.showsMessageStatus;
    ImMessageDisplayConfig.showMessageStatus.addListener(
      _handleMessageStatusVisibilityChanged,
    );
    _canLoadOlder = widget.onLoadOlder != null;
    _scrollController.addListener(_handleScroll);
    _composerController.addListener(_scheduleDraftSave);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _scrollToBottom();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_draftRestoreStarted) {
      _draftRestoreStarted = true;
      unawaited(_restoreDraft());
    }
  }

  @override
  void dispose() {
    ImMessageDisplayConfig.showMessageStatus.removeListener(
      _handleMessageStatusVisibilityChanged,
    );
    _draftSaveTimer?.cancel();
    final ownerId = _draftOwnerId;
    if (ownerId != null) {
      unawaited(
        ImDraftStore.save(
          ownerId: ownerId,
          conversationId: widget.conversation.id,
          text: _composerController.text,
        ),
      );
    }
    _scrollController.removeListener(_handleScroll);
    _composerController.removeListener(_scheduleDraftSave);
    _composerController.dispose();
    _composerFocus.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _handleMessageStatusVisibilityChanged() {
    if (!mounted) return;
    setState(() {
      _showMessageStatus = ImMessageDisplayConfig.showsMessageStatus;
    });
  }

  @override
  void didUpdateWidget(covariant ImChatRoomView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final convChanged = widget.conversation.id != oldWidget.conversation.id;
    if (convChanged) {
      _lastMaxExtent = 0;
      _showMembers = false;
      _showAttach = false;
      _showStickers = false;
      _replyingTo = null;
      _canLoadOlder = widget.onLoadOlder != null;
    }
    final prepended =
        !convChanged &&
        _loadingOlder &&
        oldWidget.messages.isNotEmpty &&
        widget.messages.isNotEmpty &&
        oldWidget.messages.last.id == widget.messages.last.id;
    if (convChanged ||
        (widget.messages.length != oldWidget.messages.length && !prepended)) {
      _scrollToBottom();
    }
  }

  Future<void> _restoreDraft() async {
    try {
      final user = await ImScope.repositoryOf(
        context,
      ).getCurrentUser(sourceId: widget.conversation.sourceId);
      final draft = await ImDraftStore.load(
        ownerId: user.id,
        conversationId: widget.conversation.id,
      );
      if (!mounted) return;
      _draftOwnerId = user.id;
      if (_composerController.text.isEmpty && draft.isNotEmpty) {
        _composerController.value = TextEditingValue(
          text: draft,
          selection: TextSelection.collapsed(offset: draft.length),
        );
      }
    } catch (_) {
      // Draft persistence must never block the composer.
    }
  }

  void _scheduleDraftSave() {
    final ownerId = _draftOwnerId;
    if (ownerId == null) return;
    _draftSaveTimer?.cancel();
    _draftSaveTimer = Timer(const Duration(milliseconds: 350), () {
      unawaited(
        ImDraftStore.save(
          ownerId: ownerId,
          conversationId: widget.conversation.id,
          text: _composerController.text,
        ),
      );
    });
  }

  void _handleScroll() {
    if (!_scrollController.hasClients ||
        _scrollController.position.pixels > 80 ||
        _loadingOlder ||
        !_canLoadOlder ||
        widget.onLoadOlder == null) {
      return;
    }
    unawaited(_loadOlderMessages());
  }

  Future<void> _loadOlderMessages() async {
    final callback = widget.onLoadOlder;
    if (callback == null || _loadingOlder) return;
    final oldExtent =
        _scrollController.hasClients
            ? _scrollController.position.maxScrollExtent
            : 0.0;
    final oldOffset =
        _scrollController.hasClients ? _scrollController.offset : 0.0;
    setState(() => _loadingOlder = true);
    try {
      _canLoadOlder = await callback();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scrollController.hasClients) return;
        final addedExtent =
            _scrollController.position.maxScrollExtent - oldExtent;
        if (addedExtent > 0) {
          _scrollController.jumpTo(oldOffset + addedExtent);
        }
      });
    } catch (error) {
      if (mounted) _showError(error);
    } finally {
      if (mounted) setState(() => _loadingOlder = false);
    }
  }

  void _toggleAttach() {
    if (!_showAttach) {
      _composerFocus.unfocus();
    }
    setState(() {
      _showAttach = !_showAttach;
      _showStickers = false;
      if (_showAttach) _showMembers = false;
    });
    Future.delayed(const Duration(milliseconds: 350), () {
      if (mounted) _scrollToBottom();
    });
  }

  void _toggleStickers() {
    if (!_showStickers) _composerFocus.unfocus();
    setState(() {
      _showStickers = !_showStickers;
      _showAttach = false;
      if (_showStickers) _showMembers = false;
    });
    Future.delayed(const Duration(milliseconds: 250), () {
      if (mounted) _scrollToBottom();
    });
  }

  Future<void> _sendSticker(ImStickerDefinition sticker) async {
    final callback = widget.onSticker;
    if (callback == null || _sending) return;
    setState(() => _sending = true);
    try {
      await callback(sticker.reference);
      if (mounted) setState(() => _showStickers = false);
    } catch (error) {
      if (mounted) _showError(error);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
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
    if (_messageKeys[sourceId]?.currentContext != null) {
      return _messageKeys[sourceId];
    }
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
      WidgetsBinding.instance.addPostFrameCallback((_) => flash());
    } else {
      Scrollable.ensureVisible(
        ctx,
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeOutCubic,
        alignment: 0.3,
      ).then((_) => flash());
    }
  }

  bool _isWidgetVisible(BuildContext context) {
    final renderObject = context.findRenderObject();
    if (renderObject == null || !renderObject.attached) return false;

    final viewport = RenderAbstractViewport.of(renderObject);
    final reveal = viewport.getOffsetToReveal(renderObject, 0.0);
    final offset = _scrollController.offset;
    final viewportHeight = _scrollController.position.viewportDimension;

    return reveal.offset >= offset && reveal.offset <= offset + viewportHeight;
  }

  Future<void> _submit() async {
    final text = _composerController.text.trim();
    if (text.isEmpty && _pendingMedia.isEmpty) return;

    setState(() => _sending = true);
    try {
      if (_pendingMedia.isNotEmpty) {
        for (final upload in _pendingMedia) {
          await ImScope.interactionsOf(
            context,
          ).sendMedia(conversation: widget.conversation, upload: upload);
        }
        setState(() {
          _pendingMedia.clear();
        });
      }
      if (text.isNotEmpty) {
        final reply = _replyingTo;
        if (reply != null && widget.onReply != null) {
          await widget.onReply!(text, reply);
        } else {
          await widget.onSend(text);
        }
        _composerController.clear();
        if (reply != null && mounted) {
          setState(() => _replyingTo = null);
        }
      }
    } catch (error) {
      if (mounted) _showError(error);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _showError(Object error) {
    final message = error.toString().replaceFirst('Exception: ', '');
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }

  bool _canRecall(ImMessage message) {
    if (widget.onRecall == null ||
        !message.isMine ||
        message.recalled ||
        message.status == ImMessageStatus.sending ||
        message.status == ImMessageStatus.failed) {
      return false;
    }
    return DateTime.now().difference(message.sentAt) <=
        const Duration(minutes: 2);
  }

  Future<void> _applyReaction(
    ImMessage message,
    String emojiId, {
    bool remove = false,
  }) async {
    final callback = widget.onReact;
    if (callback == null) return;
    try {
      await callback(message, emojiId, remove);
    } catch (error) {
      if (mounted) _showError(error);
    }
  }

  Future<void> _showReactionPicker(ImMessage message) async {
    final emojiId = await showZzzModalPanel<String>(
      context: context,
      builder:
          (dialogContext) => ZzzModalPanel(
            key: const ValueKey('message-reaction-panel'),
            title: 'React to message',
            subtitle: 'Choose a reaction',
            icon: Icons.emoji_emotions_outlined,
            maxWidth: 420,
            maxHeight: 360,
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('Close'),
              ),
            ],
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 8, 18, 18),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final id in ImReactionChips.emojiIds)
                    GestureDetector(
                      key: ValueKey('reaction-choice-$id'),
                      onTap: () => Navigator.of(dialogContext).pop(id),
                      child: Container(
                        width: 54,
                        height: 48,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.07),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: Colors.white12),
                        ),
                        child: Text(
                          ImReactionChips.emojiFor(id),
                          style: const TextStyle(fontSize: 24),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
    );
    if (!mounted || emojiId == null) return;
    final existing =
        message.reactions
            ?.where((reaction) => reaction.emojiId == emojiId)
            .firstOrNull;
    await _applyReaction(
      message,
      emojiId,
      remove: existing?.reactedByMe ?? false,
    );
  }

  Future<void> _showMessageActions(
    ImMessage message,
    Offset globalPosition,
  ) async {
    if (message.recalled) return;
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final selected = await showMenu<_MessageAction>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(globalPosition.dx, globalPosition.dy, 1, 1),
        Offset.zero & overlay.size,
      ),
      items: [
        if (widget.onReact != null)
          const PopupMenuItem(
            value: _MessageAction.react,
            child: _MessageActionItem(
              icon: Icons.add_reaction_outlined,
              label: 'React',
            ),
          ),
        if (message.text.trim().isNotEmpty)
          const PopupMenuItem(
            value: _MessageAction.copy,
            child: _MessageActionItem(icon: Icons.copy_rounded, label: 'Copy'),
          ),
        if (widget.onReply != null)
          const PopupMenuItem(
            value: _MessageAction.reply,
            child: _MessageActionItem(
              icon: Icons.reply_rounded,
              label: 'Reply',
            ),
          ),
        if (_canRecall(message))
          const PopupMenuItem(
            value: _MessageAction.recall,
            child: _MessageActionItem(
              icon: Icons.undo_rounded,
              label: 'Recall',
              destructive: true,
            ),
          ),
      ],
    );
    if (!mounted || selected == null) return;
    switch (selected) {
      case _MessageAction.react:
        await _showReactionPicker(message);
      case _MessageAction.copy:
        await Clipboard.setData(ClipboardData(text: message.text));
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Message copied'),
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
      case _MessageAction.reply:
        setState(() {
          _replyingTo = message;
          _showAttach = false;
          _showStickers = false;
        });
        _composerFocus.requestFocus();
      case _MessageAction.recall:
        await _confirmRecall(message);
    }
  }

  Future<void> _confirmRecall(ImMessage message) async {
    final confirmed = await showZzzModalPanel<bool>(
      context: context,
      builder:
          (dialogContext) => ZzzModalPanel(
            key: const ValueKey('recall-message-panel'),
            title: 'Recall message',
            subtitle: 'This replaces the message for everyone.',
            icon: Icons.undo_rounded,
            maxWidth: 420,
            maxHeight: 300,
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('Cancel'),
              ),
              FilledButton.icon(
                key: const ValueKey('confirm-recall-message'),
                onPressed: () => Navigator.of(dialogContext).pop(true),
                icon: const Icon(Icons.undo_rounded),
                label: const Text('Recall'),
              ),
            ],
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Text(
                message.text,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white70),
              ),
            ),
          ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await widget.onRecall!(message);
      if (mounted && _replyingTo?.id == message.id) {
        setState(() => _replyingTo = null);
      }
    } catch (error) {
      if (mounted) _showError(error);
    }
  }

  Future<String?> _pasteFromClipboardWithLog() async {
    try {
      final data = await Pasteboard.image;
      if (data == null) return null;
      final tempDir = Directory.systemTemp;
      final file = File(
        '${tempDir.path}/paste_${DateTime.now().millisecondsSinceEpoch}.png',
      );
      await file.writeAsBytes(data);
      return file.path;
    } catch (_) {
      return null;
    }
  }

  Future<void> _pickAndStageMedia(String type) async {
    setState(() {
      _showAttach = false;
      _showStickers = false;
    });

    switch (type) {
      case 'Image':
        final result = await FilePicker.pickFiles(
          type: FileType.image,
          allowMultiple: true,
          withData: kIsWeb,
        );
        if (result == null || result.files.isEmpty) return;
        _stageFiles(result.files, ImMessageKind.image);
        return;
      case 'Voice':
        final result = await FilePicker.pickFiles(
          type: FileType.audio,
          withData: kIsWeb,
        );
        if (result == null || result.files.isEmpty) return;
        _stageFiles(result.files, ImMessageKind.record);
        return;
      case 'Video':
        final result = await FilePicker.pickFiles(
          type: FileType.video,
          withData: kIsWeb,
        );
        if (result == null || result.files.isEmpty) return;
        _stageFiles(result.files, ImMessageKind.video);
        return;
      case 'File':
        final result = await FilePicker.pickFiles(
          allowMultiple: true,
          withData: kIsWeb,
        );
        if (result == null || result.files.isEmpty) return;
        _stageFiles(result.files, ImMessageKind.file);
        return;
      case 'Location':
        return;
      default:
        return;
    }
  }

  void _stageFiles(List<PlatformFile> files, ImMessageKind kind) {
    final uploads = files
        .where((file) => file.path != null || file.bytes != null)
        .map(
          (file) => ImMediaUpload(
            kind: kind,
            fileName: file.name,
            filePath: file.path,
            bytes: file.bytes,
            mimeType: lookupMimeType(file.name, headerBytes: file.bytes),
          ),
        )
        .toList(growable: false);
    if (uploads.isNotEmpty && mounted) {
      setState(() => _pendingMedia.addAll(uploads));
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final memberPanelHeight = (constraints.maxHeight * 0.32).clamp(
          96.0,
          220.0,
        );
        return Column(
          children: [
            _buildHeader(),
            ZzzReveal(
              key: const ValueKey('group-member-reveal'),
              expanded: _showMembers && widget.conversation.isGroup,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: memberPanelHeight),
                  child: ImMemberGrid(
                    participantIds: widget.conversation.participantIds,
                    resolveUserName: widget.resolveUserName,
                    resolveUserAvatar: widget.resolveUserAvatar,
                  ),
                ),
              ),
            ),
            Expanded(child: _buildMessages()),
            if (_pendingMedia.isNotEmpty) _buildPendingPreview(),
            if (_showStickers) _buildStickerPanel(),
            if (_showAttach) _buildAttachPanel(),
            _buildComposer(),
          ],
        );
      },
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          if (widget.onBack != null)
            IconButton(
              icon: const Icon(Icons.arrow_back_rounded, color: Colors.white54),
              onPressed: widget.onBack,
            ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.conversation.title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (widget.conversation.isGroup)
                  Text(
                    '${widget.conversation.participantIds.length} members',
                    style: const TextStyle(color: Colors.white54, fontSize: 12),
                  ),
              ],
            ),
          ),
          if (widget.conversation.isGroup && widget.onManageGroup != null)
            IconButton(
              tooltip: 'Manage group',
              onPressed: widget.onManageGroup,
              icon: const Icon(
                Icons.manage_accounts_outlined,
                color: Colors.white70,
              ),
            ),
          if (widget.conversation.isGroup)
            IconButton(
              tooltip:
                  _showMembers ? 'Hide group members' : 'Show group members',
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
      ),
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

    return Stack(
      children: [
        SuperListView.builder(
          controller: _scrollController,
          padding: const EdgeInsets.only(bottom: 8),
          itemCount: widget.messages.length,
          itemBuilder: (context, index) {
            final message = widget.messages[index];
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
                    snapshot.data?.$2 ??
                    AssetImage(AppAssets.fallbackAvatarForId(message.senderId));
                _messageKeys.putIfAbsent(message.id, () => GlobalKey());
                return GestureDetector(
                  key: _messageKeys[message.id],
                  behavior: HitTestBehavior.translucent,
                  onLongPressStart:
                      (details) =>
                          _showMessageActions(message, details.globalPosition),
                  onSecondaryTapDown:
                      (details) =>
                          _showMessageActions(message, details.globalPosition),
                  child: ImMessageBubble(
                    message: message,
                    senderName: senderName,
                    avatar: avatar,
                    showSenderName: showName,
                    hideAvatar: hideAvatar,
                    compact: compact,
                    hideTimestamp: hideTimestamp,
                    showMessageStatus: _showMessageStatus,
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
                    onReactionTap:
                        widget.onReact == null
                            ? null
                            : (reaction) => _applyReaction(
                              message,
                              reaction.emojiId,
                              remove: reaction.reactedByMe,
                            ),
                  ),
                );
              },
            );
          },
        ),
        if (_loadingOlder)
          const Positioned(
            top: 0,
            left: 16,
            right: 16,
            child: LinearProgressIndicator(minHeight: 2),
          ),
      ],
    );
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
                itemCount: _pendingMedia.length,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder:
                    (_, i) => Stack(
                      clipBehavior: Clip.none,
                      children: [
                        _buildPendingMediaTile(_pendingMedia[i]),
                        Positioned(
                          top: -6,
                          right: -6,
                          child: GestureDetector(
                            onTap:
                                () => setState(() => _pendingMedia.removeAt(i)),
                            child: Container(
                              width: 18,
                              height: 18,
                              decoration: const BoxDecoration(
                                color: Colors.black54,
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(
                                Icons.close_rounded,
                                size: 12,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '${_pendingMedia.length}',
              style: const TextStyle(color: Colors.white54, fontSize: 13),
            ),
            IconButton(
              onPressed: () => setState(() => _pendingMedia.clear()),
              icon: const Icon(Icons.close_rounded, size: 20),
              color: Colors.white54,
              visualDensity: VisualDensity.compact,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPendingMediaTile(ImMediaUpload upload) {
    Widget fallback(IconData icon) => Container(
      width: 56,
      height: 56,
      color: Colors.white10,
      child: Icon(icon, color: Colors.white38),
    );

    if (upload.kind != ImMessageKind.image) {
      final icon = switch (upload.kind) {
        ImMessageKind.record => Icons.mic_none_rounded,
        ImMessageKind.video => Icons.videocam_outlined,
        _ => Icons.insert_drive_file_outlined,
      };
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: fallback(icon),
      );
    }

    final bytes = upload.bytes;
    final path = upload.filePath;
    final image =
        bytes != null
            ? Image.memory(
              bytes,
              width: 56,
              height: 56,
              fit: BoxFit.cover,
              errorBuilder:
                  (_, __, ___) => fallback(Icons.broken_image_outlined),
            )
            : Image.file(
              File(path!),
              width: 56,
              height: 56,
              fit: BoxFit.cover,
              errorBuilder:
                  (_, __, ___) => fallback(Icons.broken_image_outlined),
            );
    return ClipRRect(borderRadius: BorderRadius.circular(8), child: image);
  }

  Widget _buildAttachPanel() {
    return AnimatedSize(
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child:
          _showAttach
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
                          for (final item in kDefaultAttachItems)
                            ImAttachButton(
                              icon: item.icon,
                              label: item.tooltip,
                              onTap:
                                  item.tooltip == 'Location'
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

  Widget _buildStickerPanel() {
    return Container(
      key: const ValueKey('sticker-panel'),
      height: 132,
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.78),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: ZzzColors.grayPanel, width: 2),
      ),
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: ImStickerCatalog.stickers.length,
        separatorBuilder: (_, __) => const SizedBox(width: 10),
        itemBuilder: (context, index) {
          final sticker = ImStickerCatalog.stickers[index];
          return Tooltip(
            message: sticker.label,
            child: InkWell(
              key: ValueKey(
                'sticker-${sticker.reference.packId}-${sticker.reference.assetId}-${sticker.reference.version}',
              ),
              borderRadius: BorderRadius.circular(8),
              onTap: _sending ? null : () => _sendSticker(sticker),
              child: SizedBox.square(
                dimension: 108,
                child: Padding(
                  padding: const EdgeInsets.all(6),
                  child: Image.asset(
                    sticker.assetPath,
                    fit: BoxFit.contain,
                    errorBuilder:
                        (_, __, ___) => const Icon(
                          Icons.broken_image_outlined,
                          color: Colors.white38,
                        ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildComposer() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_replyingTo != null) _buildReplyComposerBar(_replyingTo!),
        IgnorePointer(
          ignoring: _sending,
          child: Row(
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
                            _pendingMedia.add(
                              ImMediaUpload(
                                kind: ImMessageKind.image,
                                fileName:
                                    path.split(Platform.pathSeparator).last,
                                filePath: path,
                                mimeType: 'image/png',
                              ),
                            );
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
              SizedBox.square(
                dimension: 44,
                child: IconButton(
                  key: const ValueKey('toggle-sticker-panel'),
                  tooltip: _showStickers ? 'Close stickers' : 'Stickers',
                  onPressed: widget.onSticker == null ? null : _toggleStickers,
                  icon: Icon(
                    _showStickers
                        ? Icons.keyboard_rounded
                        : Icons.emoji_emotions_outlined,
                    color: _showStickers ? ZzzColors.yellow : Colors.white70,
                  ),
                ),
              ),
              const SizedBox(width: 4),
              ImCircleButton(onTap: _toggleAttach),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildReplyComposerBar(ImMessage message) {
    return Container(
      key: const ValueKey('reply-composer-bar'),
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: const Border(
          left: BorderSide(color: ZzzColors.yellow, width: 3),
        ),
      ),
      child: Row(
        children: [
          const Icon(Icons.reply_rounded, size: 18, color: ZzzColors.yellow),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message.text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white70, fontSize: 13),
            ),
          ),
          IconButton(
            key: const ValueKey('cancel-message-reply'),
            tooltip: 'Cancel reply',
            visualDensity: VisualDensity.compact,
            onPressed: () => setState(() => _replyingTo = null),
            icon: const Icon(Icons.close_rounded, size: 18),
          ),
        ],
      ),
    );
  }
}

enum _MessageAction { react, copy, reply, recall }

class _MessageActionItem extends StatelessWidget {
  const _MessageActionItem({
    required this.icon,
    required this.label,
    this.destructive = false,
  });

  final IconData icon;
  final String label;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final color = destructive ? ZzzColors.red : null;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 19, color: color),
        const SizedBox(width: 10),
        Text(label, style: TextStyle(color: color)),
      ],
    );
  }
}
