import 'package:flutter/material.dart';

import '../../data/im_logger.dart';
import '../../data/im_nsfw_checker.dart';
import '../../im_scope.dart';
import '../im_nsfw_overlay.dart';

/// Wraps an image child with NSFW blur protection when the checker flags it.
class ImNsfwGuard extends StatefulWidget {
  const ImNsfwGuard({
    required this.messageId,
    required this.mediaPath,
    required this.child,
  });

  final String messageId;
  final String mediaPath;
  final Widget child;

  @override
  State<ImNsfwGuard> createState() => _ImNsfwGuardState();
}

class _ImNsfwGuardState extends State<ImNsfwGuard> {
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
