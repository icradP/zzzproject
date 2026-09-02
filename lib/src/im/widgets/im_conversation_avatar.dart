import 'dart:async';

import 'package:flutter/material.dart';

import '../../assets/app_assets.dart';
import '../../widgets/zzz_widgets.dart';
import '../data/im_repository.dart';
import '../im_scope.dart';
import '../models/im_models.dart';

class ImConversationAvatar extends StatefulWidget {
  const ImConversationAvatar({
    required this.conversation,
    required this.size,
    this.memberUsers,
    super.key,
  });

  final ImConversation conversation;
  final double size;
  final List<ImUser>? memberUsers;

  @override
  State<ImConversationAvatar> createState() => _ImConversationAvatarState();
}

class _ImConversationAvatarState extends State<ImConversationAvatar> {
  ImRepository? _repository;
  List<ImUser> _members = const [];
  bool _loading = false;

  bool get _hasCustomAvatar =>
      (widget.conversation.avatarAssetPath?.isNotEmpty ?? false) ||
      (widget.conversation.avatarLocalPath?.isNotEmpty ?? false);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_hasCustomAvatar ||
        !widget.conversation.isGroup ||
        widget.memberUsers != null) {
      unawaited(_loadMembers());
      return;
    }
    final repository = ImScope.repositoryOf(context);
    if (!identical(repository, _repository)) {
      _repository = repository;
      unawaited(_loadMembers());
    }
  }

  @override
  void didUpdateWidget(covariant ImConversationAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.conversation.id != widget.conversation.id ||
        oldWidget.conversation.participantIds !=
            widget.conversation.participantIds ||
        oldWidget.memberUsers != widget.memberUsers) {
      unawaited(_loadMembers());
    }
  }

  Future<void> _loadMembers() async {
    if (_hasCustomAvatar || !widget.conversation.isGroup) return;
    final supplied = widget.memberUsers;
    if (supplied != null) {
      if (mounted) setState(() => _members = supplied.take(4).toList());
      return;
    }
    final repository = _repository;
    if (repository == null || _loading) return;
    _loading = true;
    try {
      final details = await repository.getGroupDetails(widget.conversation.id);
      if (!mounted || details.conversation.id != widget.conversation.id) return;
      setState(() {
        _members =
            details.members.map((member) => member.user).take(4).toList();
      });
    } catch (_) {
      // Participant-specific fallback avatars remain available offline.
    } finally {
      _loading = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_hasCustomAvatar && widget.conversation.isGroup) {
      final members =
          _members.isNotEmpty
              ? _members
              : widget.conversation.participantIds
                  .take(4)
                  .map(
                    (id) => ImUser(
                      id: id,
                      displayName: id,
                      avatarAssetPath: AppAssets.fallbackAvatarForId(id),
                    ),
                  )
                  .toList(growable: false);
      return _CompositeGroupAvatar(members: members, size: widget.size);
    }
    return ZzzAvatar(
      image: widget.conversation.avatarImage(
        AppAssets.fallbackAvatarForId(widget.conversation.id),
      ),
      size: widget.size,
    );
  }
}

class _CompositeGroupAvatar extends StatelessWidget {
  const _CompositeGroupAvatar({required this.members, required this.size});

  final List<ImUser> members;
  final double size;

  @override
  Widget build(BuildContext context) {
    final visible = members.take(4).toList(growable: false);
    if (visible.isEmpty) {
      return SizedBox.square(
        dimension: size,
        child: const ColoredBox(
          color: Color(0xFF25272D),
          child: Icon(Icons.groups_rounded, color: Colors.white54),
        ),
      );
    }
    final columns = visible.length == 1 ? 1 : 2;
    return ClipRRect(
      borderRadius: BorderRadius.circular(size * 0.2),
      child: SizedBox.square(
        dimension: size,
        child: GridView.builder(
          padding: EdgeInsets.zero,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            crossAxisSpacing: 1,
            mainAxisSpacing: 1,
          ),
          itemCount: visible.length,
          itemBuilder: (context, index) {
            final user = visible[index];
            return ColoredBox(
              color: const Color(0xFF25272D),
              child: Image(
                image: user.avatarImage(AppAssets.fallbackAvatarForId(user.id)),
                fit: BoxFit.cover,
                gaplessPlayback: true,
              ),
            );
          },
        ),
      ),
    );
  }
}
