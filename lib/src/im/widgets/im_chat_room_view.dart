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
    super.key,
  });

  final ImMessage message;
  final String senderName;
  final ImageProvider avatar;
  final bool showSenderName;

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

    final isMine = message.isMine;
    final avatarWidget = ZzzAvatar(image: avatar, size: 38);

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
          Container(
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
            child: Text(
              message.text,
              style: TextStyle(
                color: isMine ? Colors.white : Colors.black87,
                fontSize: 15,
                height: 1.35,
              ),
            ),
          ),
          const SizedBox(height: 2),
          Text(
            _formatClock(message.sentAt),
            style: const TextStyle(color: Colors.white30, fontSize: 10),
          ),
        ],
      ),
    );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
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
    this.onBack,
    super.key,
  });

  final ImConversation conversation;
  final List<ImMessage> messages;
  final Future<void> Function(String text) onSend;
  final Future<String> Function(String userId) resolveUserName;
  final Future<ImageProvider> Function(String userId) resolveUserAvatar;
  final VoidCallback? onBack;

  @override
  State<ImChatRoomView> createState() => _ImChatRoomViewState();
}

class _ImChatRoomViewState extends State<ImChatRoomView> {
  final _composerController = TextEditingController();
  final _scrollController = ScrollController();
  bool _sending = false;

  @override
  void dispose() {
    _composerController.dispose();
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

  Future<void> _submit() async {
    final text = _composerController.text;
    if (text.trim().isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      await widget.onSend(text);
      _composerController.clear();
      _scrollToBottom();
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildHeader(),
        const Divider(height: 20, thickness: 1, color: Colors.white12),
        Expanded(child: _buildMessages()),
        const SizedBox(height: 10),
        _buildComposer(),
      ],
    );
  }

  Widget _buildHeader() {
    final avatarPath =
        widget.conversation.avatarAssetPath ?? AppAssets.characterWise;

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
        ZzzAvatar(image: AssetImage(avatarPath), size: 44),
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
        IconButton(
          tooltip: 'More',
          onPressed: () {},
          icon: const Icon(Icons.more_horiz_rounded, color: Colors.white54),
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
        return FutureBuilder<(String, ImageProvider)>(
          future: Future.wait([
            widget.resolveUserName(message.senderId),
            widget.resolveUserAvatar(message.senderId),
          ]).then((values) => (values[0] as String, values[1] as ImageProvider)),
          builder: (context, snapshot) {
            final senderName = snapshot.data?.$1 ?? '...';
            final avatar =
                snapshot.data?.$2 ?? AssetImage(AppAssets.characterWise);
            return ImMessageBubble(
              message: message,
              senderName: senderName,
              avatar: avatar,
              showSenderName:
                  widget.conversation.isGroup && !message.isMine,
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
