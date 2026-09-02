import 'dart:io';

import 'package:flutter/material.dart';
import 'package:onebot_flutter/onebot_flutter.dart' show OneBotMessageSegment;

import '../../../assets/app_assets.dart';
import '../../../theme/zzz_colors.dart';
import '../../im_scope.dart';
import '../../models/im_models.dart';
import 'im_nsfw_guard.dart';

/// Forward / combined message bubble — tap to open in a dialog.
class ImForwardBubble extends StatefulWidget {
  const ImForwardBubble({required this.message});
  final ImMessage message;

  @override
  State<ImForwardBubble> createState() => _ImForwardBubbleState();
}

class _ImForwardBubbleState extends State<ImForwardBubble> {
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
      final group = await ImScope.interactionsOf(
        context,
      ).getForwardMessages(id);
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
        final sender =
            msg.senderDisplayName?.trim().isNotEmpty == true
                ? msg.senderDisplayName!
                : msg.senderId;
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
                            Icon(
                              Icons.forward_rounded,
                              size: 13,
                              color: ZzzColors.yellow,
                            ),
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
                                  color: Colors.white54,
                                  fontSize: 11,
                                ),
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
      builder: (_) => ImForwardDialog(forwardId: id),
    );
  }
}

/// Dialog showing the full list of forwarded messages.
class ImForwardDialog extends StatefulWidget {
  const ImForwardDialog({required this.forwardId});
  final String forwardId;

  @override
  State<ImForwardDialog> createState() => _ImForwardDialogState();
}

class _ImForwardDialogState extends State<ImForwardDialog> {
  ForwardGroup? _group;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    try {
      final g = await ImScope.interactionsOf(
        context,
      ).getForwardMessages(widget.forwardId);
      if (mounted) setState(() => _group = g);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  List<Widget> _buildForwardChildren(ForwardGroup group, int depth) =>
      buildForwardList(group, depth);

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF12121e),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420, maxHeight: 560),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Title bar
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
              child: Row(
                children: [
                  const Icon(
                    Icons.forward_rounded,
                    size: 20,
                    color: Colors.white54,
                  ),
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
              child:
                  _error != null
                      ? Padding(
                        padding: const EdgeInsets.all(32),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.error_outline,
                              size: 32,
                              color: Colors.white24,
                            ),
                            const SizedBox(height: 8),
                            Text(
                              _error!,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                color: Colors.white38,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      )
                      : _group == null
                      ? const Padding(
                        padding: EdgeInsets.all(32),
                        child: Center(child: CircularProgressIndicator()),
                      )
                      : _group!.isEmpty
                      ? const Padding(
                        padding: EdgeInsets.all(32),
                        child: Text(
                          'Empty',
                          style: TextStyle(color: Colors.white38),
                        ),
                      )
                      : ListView(
                        shrinkWrap: true,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        children: _buildForwardChildren(_group!, 0),
                      ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Collapsible nested forward group.
class ImNestedForwardGroup extends StatefulWidget {
  const ImNestedForwardGroup({required this.group, required this.depth});
  final ForwardGroup group;
  final int depth;

  @override
  State<ImNestedForwardGroup> createState() => _ImNestedForwardGroupState();
}

class _ImNestedForwardGroupState extends State<ImNestedForwardGroup> {
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
        final sender =
            msg.senderDisplayName?.trim().isNotEmpty == true
                ? msg.senderDisplayName!
                : msg.senderId;
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
      padding: EdgeInsets.only(left: 16.0 * widget.depth, top: 6, bottom: 2),
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
                  const Icon(
                    Icons.forward_rounded,
                    size: 14,
                    color: Colors.white38,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'Chat records ($_msgCount msg${_msgCount == 1 ? '' : 's'})',
                          style: const TextStyle(
                            color: Colors.white38,
                            fontSize: 11,
                          ),
                        ),
                        if (!_expanded && _previewLines!.isNotEmpty)
                          ..._previewLines!
                              .take(3)
                              .map(
                                (l) => Padding(
                                  padding: const EdgeInsets.only(top: 2),
                                  child: Text(
                                    l,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: Colors.white24,
                                      fontSize: 10,
                                    ),
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
              ...buildForwardList(widget.group, widget.depth + 1),
            ],
          ],
        ),
      ),
    );
  }
}

/// Renders a single forwarded message with sender avatar/name + content.
class ImForwardMsgTile extends StatefulWidget {
  const ImForwardMsgTile({required this.msg});
  final ImMessage msg;

  @override
  State<ImForwardMsgTile> createState() => _ImForwardMsgTileState();
}

class _ImForwardMsgTileState extends State<ImForwardMsgTile> {
  ImageProvider? _avatar;

  @override
  void initState() {
    super.initState();
    Future.microtask(() => _loadAvatar());
  }

  Future<void> _loadAvatar() async {
    final path = await ImScope.interactionsOf(
      context,
    ).getUserAvatarPath(widget.msg.senderId);
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
                backgroundImage:
                    _avatar ?? const AssetImage(AppAssets.iconAgentProfile),
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
                  msg.senderDisplayName?.trim().isNotEmpty == true
                      ? msg.senderDisplayName!
                      : msg.senderId,
                  style: const TextStyle(color: Colors.white38, fontSize: 11),
                ),
                const SizedBox(height: 4),
                ...msg.segments?.map((s) => _renderSegment(context, s)) ??
                    [
                      Text(
                        msg.text,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 13,
                        ),
                      ),
                    ],
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
            child: ImNsfwGuard(
              messageId: 'fw_${localPath.hashCode}',
              mediaPath: localPath,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.file(
                  File(localPath),
                  width: 180,
                  fit: BoxFit.cover,
                  errorBuilder:
                      (_, __, ___) => const Icon(
                        Icons.broken_image,
                        size: 32,
                        color: Colors.white24,
                      ),
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
              child: Image.network(
                url,
                width: 180,
                fit: BoxFit.cover,
                errorBuilder:
                    (_, __, ___) => const Icon(
                      Icons.broken_image,
                      size: 32,
                      color: Colors.white24,
                    ),
              ),
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
              Icon(Icons.forward_rounded, size: 14, color: Colors.white38),
              SizedBox(width: 6),
              Text(
                'Chat records',
                style: TextStyle(color: Colors.white38, fontSize: 11),
              ),
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

/// Helper to build a flat list of widgets for a [ForwardGroup].
List<Widget> buildForwardList(ForwardGroup group, int depth) {
  final widgets = <Widget>[];
  for (final msg in group.messages) {
    widgets.add(ImForwardMsgTile(msg: msg));
  }
  for (final child in group.children) {
    widgets.add(ImNestedForwardGroup(group: child, depth: depth));
  }
  return widgets;
}
