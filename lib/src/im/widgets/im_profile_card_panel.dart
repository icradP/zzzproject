import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';

import '../../assets/app_assets.dart';
import '../../theme/zzz_colors.dart';
import '../../widgets/zzz_widgets.dart';
import '../data/im_animation_config.dart';
import '../data/im_repository.dart';
import '../models/im_models.dart';

class ImTitleBadge extends StatefulWidget {
  const ImTitleBadge({required this.title, super.key});

  final ImUserTitle title;

  @override
  State<ImTitleBadge> createState() => _ImTitleBadgeState();
}

class _ImTitleBadgeState extends State<ImTitleBadge>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 4),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final animate =
        widget.title.isAnimated &&
        ImAnimationConfig.instance.backgroundMotion &&
        !MediaQuery.disableAnimationsOf(context);
    if (animate && !_controller.isAnimating) {
      _controller.repeat();
    } else if (!animate && _controller.isAnimating) {
      _controller.stop();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = switch (widget.title.style) {
      'gold' => const [Color(0xFFFFE083), Color(0xFFB87900)],
      'red' => const [Color(0xFFFF8B8B), Color(0xFFB51F2E)],
      'aurora' => const [
        Color(0xFF7DE7D5),
        Color(0xFF6788FF),
        Color(0xFFFF7AAF),
      ],
      'ember' => const [
        Color(0xFFFFD058),
        Color(0xFFE84C3D),
        Color(0xFF8C1C35),
      ],
      _ => const [Color(0xFFFFE96A), Color(0xFFE0A800)],
    };
    return AnimatedBuilder(
      animation: _controller,
      builder:
          (context, child) => Container(
            constraints: const BoxConstraints(minHeight: 26, maxWidth: 180),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(4),
              gradient: LinearGradient(
                colors: colors,
                transform: GradientRotation(
                  widget.title.isAnimated ? _controller.value * math.pi * 2 : 0,
                ),
              ),
              border: Border.all(color: Colors.white24),
            ),
            child: child,
          ),
      child: Text(
        widget.title.text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          color: Colors.black,
          fontSize: 11,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }
}

class ImProfileCardPanel extends StatefulWidget {
  const ImProfileCardPanel({
    required this.userId,
    required this.repository,
    this.groupId,
    this.onMessage,
    super.key,
  });

  final String userId;
  final String? groupId;
  final ImRepository repository;
  final Future<void> Function(ImUser user)? onMessage;

  @override
  State<ImProfileCardPanel> createState() => _ImProfileCardPanelState();
}

class _ImProfileCardPanelState extends State<ImProfileCardPanel> {
  ImUser? _user;
  String? _selfId;
  String? _error;
  bool _loading = true;
  bool _busy = false;
  bool _backgroundRevealed = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final results = await Future.wait([
        widget.repository.getProfileCard(
          widget.userId,
          groupId: widget.groupId,
        ),
        widget.repository.getCurrentUser(),
      ]);
      if (!mounted) return;
      setState(() {
        _user = results[0];
        _selfId = (results[1] as ImUser).id;
        _loading = false;
        _error = _user == null ? 'Profile is unavailable.' : null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$error';
      });
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
      await _load();
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _addFriend(ImUser user) => _run(
    () => widget.repository.sendFriendRequest(
      userId: user.id,
      comment: 'Sent from profile card',
    ),
  );

  Future<void> _toggleBlock(ImUser user) async {
    final blocked = user.relationship == ImRelationship.blocked;
    if (!blocked) {
      final confirmed = await showZzzModalPanel<bool>(
        context: context,
        builder:
            (dialogContext) => ZzzModalPanel(
              title: 'Block ${user.displayName}?',
              icon: Icons.block_rounded,
              maxWidth: 420,
              maxHeight: 280,
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(false),
                  child: const Text('Cancel'),
                ),
                FilledButton.icon(
                  onPressed: () => Navigator.of(dialogContext).pop(true),
                  icon: const Icon(Icons.block_rounded),
                  label: const Text('Block'),
                ),
              ],
              child: const Padding(
                padding: EdgeInsets.all(20),
                child: Text(
                  'Private messages and friend requests between these accounts will be stopped.',
                  style: TextStyle(color: Colors.white70),
                ),
              ),
            ),
      );
      if (confirmed != true || !mounted) return;
    }
    await _run(
      () =>
          widget.repository.setUserBlocked(userId: user.id, blocked: !blocked),
    );
  }

  Future<void> _report(ImUser user) async {
    final reason = ValueNotifier<String>('spam');
    final details = TextEditingController();
    final submitted = await showZzzModalPanel<bool>(
      context: context,
      builder:
          (dialogContext) => ZzzModalPanel(
            title: 'Report ${user.displayName}',
            icon: Icons.flag_outlined,
            maxWidth: 460,
            maxHeight: 430,
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('Cancel'),
              ),
              FilledButton.icon(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                icon: const Icon(Icons.flag_rounded),
                label: const Text('Submit'),
              ),
            ],
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ValueListenableBuilder<String>(
                    valueListenable: reason,
                    builder:
                        (context, value, _) => DropdownButtonFormField<String>(
                          initialValue: value,
                          decoration: const InputDecoration(
                            labelText: 'Reason',
                          ),
                          items: const [
                            DropdownMenuItem(
                              value: 'spam',
                              child: Text('Spam'),
                            ),
                            DropdownMenuItem(
                              value: 'harassment',
                              child: Text('Harassment'),
                            ),
                            DropdownMenuItem(
                              value: 'impersonation',
                              child: Text('Impersonation'),
                            ),
                            DropdownMenuItem(
                              value: 'inappropriate',
                              child: Text('Inappropriate content'),
                            ),
                            DropdownMenuItem(
                              value: 'other',
                              child: Text('Other'),
                            ),
                          ],
                          onChanged: (next) {
                            if (next != null) reason.value = next;
                          },
                        ),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: details,
                    minLines: 3,
                    maxLines: 5,
                    maxLength: 500,
                    decoration: const InputDecoration(
                      labelText: 'Details (optional)',
                      alignLabelWithHint: true,
                    ),
                  ),
                ],
              ),
            ),
          ),
    );
    if (submitted == true && mounted) {
      await _run(
        () => widget.repository.reportUser(
          userId: user.id,
          reason: reason.value,
          details: details.text,
        ),
      );
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Report submitted.')));
      }
    }
    reason.dispose();
    details.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ZzzModalPanel(
      title: 'Profile card',
      subtitle: _user?.id ?? widget.userId,
      icon: Icons.badge_outlined,
      maxWidth: 680,
      maxHeight: 760,
      actions: [
        TextButton.icon(
          onPressed: () => Navigator.of(context).pop(),
          icon: const Icon(Icons.close_rounded),
          label: const Text('Close'),
        ),
      ],
      child:
          _loading
              ? const Center(child: CircularProgressIndicator())
              : _user == null
              ? Center(child: Text(_error ?? 'Profile is unavailable.'))
              : _buildCard(_user!),
    );
  }

  Widget _buildCard(ImUser user) {
    final isSelf = user.id == _selfId;
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 540;
        return ListView(
          padding: EdgeInsets.zero,
          children: [
            _buildCover(user),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
              child: Transform.translate(
                offset: const Offset(0, -28),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (wide)
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          _buildIdentity(user),
                          const SizedBox(width: 18),
                          Expanded(child: _buildName(user)),
                        ],
                      )
                    else ...[
                      _buildIdentity(user),
                      const SizedBox(height: 12),
                      _buildName(user),
                    ],
                    if (user.titles.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: user.titles
                            .map((title) => ImTitleBadge(title: title))
                            .toList(growable: false),
                      ),
                    ],
                    if (user.bio.isNotEmpty) ...[
                      const SizedBox(height: 18),
                      Text(
                        user.bio,
                        style: const TextStyle(
                          color: Colors.white70,
                          height: 1.45,
                        ),
                      ),
                    ],
                    if (user.mutualGroups.isNotEmpty) ...[
                      const SizedBox(height: 20),
                      const Text(
                        'Mutual groups',
                        style: TextStyle(fontWeight: FontWeight.w800),
                      ),
                      const SizedBox(height: 8),
                      ...user.mutualGroups.map(
                        (group) => Material(
                          color: Colors.transparent,
                          child: ListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            leading: CircleAvatar(
                              backgroundImage:
                                  group.avatarUrl == null
                                      ? null
                                      : NetworkImage(group.avatarUrl!),
                              child:
                                  group.avatarUrl == null
                                      ? const Icon(
                                        Icons.groups_rounded,
                                        size: 18,
                                      )
                                      : null,
                            ),
                            title: Text(group.name),
                            subtitle: Text('${group.memberCount} members'),
                          ),
                        ),
                      ),
                    ],
                    if (_error != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        _error!,
                        style: const TextStyle(color: Colors.redAccent),
                      ),
                    ],
                    if (!isSelf) ...[
                      const SizedBox(height: 20),
                      _buildActions(user),
                    ],
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildCover(ImUser user) {
    final background = user.cardBackgroundUrl;
    Widget content = Container(
      height: 210,
      decoration: BoxDecoration(
        color: const Color(0xFF17191D),
        image:
            background == null
                ? null
                : DecorationImage(
                  image: NetworkImage(background),
                  fit: BoxFit.cover,
                  onError: (_, __) {},
                ),
      ),
      child:
          background == null
              ? const Align(
                alignment: Alignment.topRight,
                child: Padding(
                  padding: EdgeInsets.all(18),
                  child: Icon(
                    Icons.bolt_rounded,
                    color: ZzzColors.yellow,
                    size: 38,
                  ),
                ),
              )
              : null,
    );
    if (user.cardBackgroundSensitive && !_backgroundRevealed) {
      content = Stack(
        fit: StackFit.passthrough,
        children: [
          ImageFiltered(
            imageFilter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
            child: content,
          ),
          Positioned.fill(
            child: Material(
              color: Colors.black54,
              child: InkWell(
                onTap: () => setState(() => _backgroundRevealed = true),
                child: const Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.visibility_outlined),
                      SizedBox(height: 8),
                      Text('Sensitive background'),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    }
    return ClipRect(child: content);
  }

  Widget _buildIdentity(ImUser user) => Container(
    padding: const EdgeInsets.all(4),
    decoration: const BoxDecoration(
      color: Colors.black,
      shape: BoxShape.circle,
    ),
    child: ZzzAvatar(
      image: user.avatarImage(AppAssets.fallbackAvatarForId(user.id)),
      size: 88,
    ),
  );

  Widget _buildName(ImUser user) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        user.displayName,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900),
      ),
      const SizedBox(height: 3),
      Text(user.id, style: const TextStyle(color: Colors.white54)),
    ],
  );

  Widget _buildActions(ImUser user) {
    final blocked = user.relationship == ImRelationship.blocked;
    final directMessagesBlocked =
        blocked || user.relationship == ImRelationship.blockedBy;
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        if (widget.onMessage != null && !directMessagesBlocked)
          FilledButton.icon(
            onPressed:
                _busy
                    ? null
                    : () async {
                      await widget.onMessage!(user);
                      if (mounted) Navigator.of(context).pop();
                    },
            icon: const Icon(Icons.chat_bubble_outline_rounded),
            label: const Text('Message'),
          ),
        if (user.relationship == ImRelationship.none)
          OutlinedButton.icon(
            onPressed: _busy ? null : () => _addFriend(user),
            icon: const Icon(Icons.person_add_alt_1_rounded),
            label: const Text('Add friend'),
          ),
        OutlinedButton.icon(
          onPressed: _busy ? null : () => _toggleBlock(user),
          icon: Icon(blocked ? Icons.lock_open_rounded : Icons.block_rounded),
          label: Text(blocked ? 'Unblock' : 'Block'),
        ),
        IconButton(
          onPressed: _busy ? null : () => _report(user),
          icon: const Icon(Icons.flag_outlined),
          tooltip: 'Report user',
        ),
      ],
    );
  }
}
