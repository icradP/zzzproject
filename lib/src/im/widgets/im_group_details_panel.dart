import 'dart:async';

import 'package:flutter/material.dart';

import '../../assets/app_assets.dart';
import '../../theme/zzz_colors.dart';
import '../../widgets/zzz_widgets.dart';
import '../data/im_repository.dart';
import '../models/im_models.dart';
import '../models/im_source_address.dart';

class ImGroupDetailsPanel extends StatefulWidget {
  const ImGroupDetailsPanel({
    required this.conversation,
    required this.repository,
    required this.onLeft,
    super.key,
  });

  final ImConversation conversation;
  final ImRepository repository;
  final VoidCallback onLeft;

  @override
  State<ImGroupDetailsPanel> createState() => _ImGroupDetailsPanelState();
}

class _ImGroupDetailsPanelState extends State<ImGroupDetailsPanel> {
  final _searchController = TextEditingController();
  final _selectedInvitees = <String>{};
  ImGroupDetails? _details;
  List<ImUser> _availableUsers = const [];
  String _tab = 'members';
  String _query = '';
  String? _error;
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(covariant ImGroupDetailsPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.conversation.id != widget.conversation.id) {
      _selectedInvitees.clear();
      _tab = 'members';
      unawaited(_load());
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final details = await widget.repository.getGroupDetails(
        widget.conversation.id,
      );
      var users = const <ImUser>[];
      String? userLoadError;
      if (details.canInviteMembers) {
        try {
          users = await widget.repository.getUsers();
        } catch (error) {
          userLoadError = 'Members loaded, but friends are unavailable: $error';
        }
      }
      if (!mounted) return;
      setState(() {
        _details = details;
        _availableUsers = users;
        _error = userLoadError;
        _selectedInvitees.removeWhere(
          (id) => details.members.any((member) => member.user.id == id),
        );
        if (!details.canInviteMembers) _tab = 'members';
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$error';
      });
    }
  }

  List<ImUser> get _inviteCandidates {
    final details = _details;
    if (details == null) return const [];
    final memberIDs = details.members.map((member) => member.user.id).toSet();
    final groupSource =
        ImSourceAddress.sourceIdOf(widget.conversation.id) ??
        widget.conversation.sourceId;
    return _availableUsers
        .where((user) {
          if (memberIDs.contains(user.id)) return false;
          final userSource =
              ImSourceAddress.sourceIdOf(user.id) ?? user.sourceId;
          if (groupSource != null &&
              userSource != null &&
              groupSource != userSource) {
            return false;
          }
          final localID = ImSourceAddress.localIdOf(user.id).toLowerCase();
          return _query.isEmpty ||
              user.displayName.toLowerCase().contains(_query) ||
              localID.contains(_query);
        })
        .toList(growable: false);
  }

  Future<bool> _confirm({
    required String title,
    required String message,
    required String actionLabel,
  }) async {
    final result = await showZzzModalPanel<bool>(
      context: context,
      builder:
          (dialogContext) => ZzzModalPanel(
            title: title,
            icon: Icons.warning_amber_rounded,
            maxWidth: 420,
            maxHeight: 280,
            actions: [
              TextButton.icon(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                icon: const Icon(Icons.close_rounded),
                label: const Text('Cancel'),
              ),
              FilledButton.icon(
                key: ValueKey('group-confirm-${actionLabel.toLowerCase()}'),
                style: FilledButton.styleFrom(
                  backgroundColor: ZzzColors.red,
                  foregroundColor: Colors.white,
                ),
                onPressed: () => Navigator.of(dialogContext).pop(true),
                icon: const Icon(Icons.check_rounded),
                label: Text(actionLabel),
              ),
            ],
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Text(
                message,
                style: const TextStyle(color: Colors.white70, height: 1.45),
              ),
            ),
          ),
    );
    return result ?? false;
  }

  Future<void> _removeMember(ImGroupMember member) async {
    final confirmed = await _confirm(
      title: 'Remove member',
      message:
          '${member.user.displayName} will lose access to this group and its new messages.',
      actionLabel: 'Remove',
    );
    if (!confirmed || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.repository.removeGroupMember(
        groupId: widget.conversation.id,
        userId: member.user.id,
      );
      await _load();
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _inviteSelected() async {
    if (_selectedInvitees.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.repository.inviteGroupMembers(
        groupId: widget.conversation.id,
        userIds: _selectedInvitees.toList(growable: false),
      );
      _selectedInvitees.clear();
      await _load();
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _leaveGroup() async {
    final confirmed = await _confirm(
      title: 'Leave group',
      message:
          'You will stop receiving new messages from ${widget.conversation.title}.',
      actionLabel: 'Leave',
    );
    if (!confirmed || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.repository.leaveGroup(widget.conversation.id);
      if (!mounted) return;
      Navigator.of(context).pop();
      widget.onLeft();
    } catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = '$error';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final details = _details;
    return ZzzModalPanel(
      key: const ValueKey('group-details-panel'),
      title: 'Group management',
      subtitle: widget.conversation.title,
      icon: Icons.manage_accounts_outlined,
      maxWidth: 680,
      maxHeight: 720,
      child:
          _loading && details == null
              ? const Center(child: CircularProgressIndicator())
              : Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (details != null) _buildSummary(details),
                    if (_error != null) ...[
                      const SizedBox(height: 10),
                      _buildError(),
                    ],
                    const SizedBox(height: 12),
                    if (details?.canInviteMembers ?? false) ...[
                      ZzzSegmentedControl<String>(
                        key: const ValueKey('group-management-tabs'),
                        value: _tab,
                        items: const [
                          ZzzSegmentItem<String>(
                            value: 'members',
                            tooltip: 'Members',
                            icon: Icons.groups_rounded,
                          ),
                          ZzzSegmentItem<String>(
                            value: 'invite',
                            tooltip: 'Invite members',
                            icon: Icons.person_add_alt_1_rounded,
                          ),
                        ],
                        onChanged: (value) => setState(() => _tab = value),
                      ),
                      const SizedBox(height: 12),
                    ],
                    Expanded(
                      child:
                          details == null
                              ? _buildRetry()
                              : AnimatedSwitcher(
                                duration: const Duration(milliseconds: 180),
                                child:
                                    _tab == 'invite'
                                        ? _buildInviteList()
                                        : _buildMemberList(details),
                              ),
                    ),
                    if (details?.canLeave ?? false) ...[
                      const Divider(height: 16, color: Colors.white12),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          key: const ValueKey('group-leave'),
                          onPressed: _busy ? null : _leaveGroup,
                          style: TextButton.styleFrom(
                            foregroundColor: Colors.redAccent,
                          ),
                          icon: const Icon(Icons.logout_rounded),
                          label: const Text('Leave group'),
                        ),
                      ),
                    ],
                    if (_busy) const LinearProgressIndicator(minHeight: 2),
                  ],
                ),
              ),
    );
  }

  Widget _buildSummary(ImGroupDetails details) {
    return Row(
      children: [
        ZzzAvatar(
          image: details.conversation.avatarImage(
            AppAssets.fallbackAvatarForId(details.conversation.id),
          ),
          size: 52,
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                details.conversation.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
              Text(
                '${details.members.length} members',
                style: const TextStyle(color: Colors.white54, fontSize: 12),
              ),
            ],
          ),
        ),
        if (_loading)
          const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
      ],
    );
  }

  Widget _buildError() {
    return Container(
      key: const ValueKey('group-details-error'),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: ZzzColors.red.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Colors.redAccent.withValues(alpha: 0.45)),
      ),
      child: Text(
        _error!,
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: Colors.white70, fontSize: 12),
      ),
    );
  }

  Widget _buildRetry() {
    return Center(
      child: IconButton(
        tooltip: 'Retry',
        onPressed: _load,
        icon: const Icon(Icons.refresh_rounded),
      ),
    );
  }

  Widget _buildMemberList(ImGroupDetails details) {
    return ListView.separated(
      key: const ValueKey('group-member-list'),
      itemCount: details.members.length,
      separatorBuilder:
          (_, __) => const Divider(height: 1, color: Colors.white10),
      itemBuilder: (context, index) {
        final member = details.members[index];
        final canRemove = details.canRemoveMember(member);
        return _GroupPersonRow(
          key: ValueKey('group-member-${member.user.id}'),
          user: member.user,
          role: member.role,
          trailing:
              canRemove
                  ? IconButton(
                    key: ValueKey('group-remove-${member.user.id}'),
                    tooltip: 'Remove ${member.user.displayName}',
                    onPressed: _busy ? null : () => _removeMember(member),
                    icon: const Icon(
                      Icons.person_remove_outlined,
                      color: Colors.redAccent,
                    ),
                  )
                  : null,
        );
      },
    );
  }

  Widget _buildInviteList() {
    final candidates = _inviteCandidates;
    return Column(
      key: const ValueKey('group-invite-tab'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ZzzTextInput(
          key: const ValueKey('group-invite-search'),
          controller: _searchController,
          hintText: 'Search friends',
          prefixIcon: const Icon(Icons.search_rounded),
          fillColor: Colors.white.withValues(alpha: 0.08),
          foregroundColor: Colors.white,
          onChanged:
              (value) => setState(() => _query = value.trim().toLowerCase()),
        ),
        const SizedBox(height: 8),
        Expanded(
          child:
              candidates.isEmpty
                  ? const Center(
                    child: Text(
                      'No friends available',
                      style: TextStyle(color: Colors.white38),
                    ),
                  )
                  : ListView.builder(
                    key: const ValueKey('group-invite-list'),
                    itemCount: candidates.length,
                    itemBuilder: (context, index) {
                      final user = candidates[index];
                      final selected = _selectedInvitees.contains(user.id);
                      return _GroupPersonRow(
                        key: ValueKey('group-invite-user-${user.id}'),
                        user: user,
                        selected: selected,
                        onTap: () {
                          setState(() {
                            if (!_selectedInvitees.add(user.id)) {
                              _selectedInvitees.remove(user.id);
                            }
                          });
                        },
                        trailing: Checkbox(
                          value: selected,
                          onChanged: (_) {
                            setState(() {
                              if (!_selectedInvitees.add(user.id)) {
                                _selectedInvitees.remove(user.id);
                              }
                            });
                          },
                        ),
                      );
                    },
                  ),
        ),
        const SizedBox(height: 8),
        FilledButton.icon(
          key: const ValueKey('group-invite-submit'),
          onPressed:
              _selectedInvitees.isEmpty || _busy ? null : _inviteSelected,
          icon: const Icon(Icons.person_add_alt_1_rounded),
          label: Text('Invite (${_selectedInvitees.length})'),
        ),
      ],
    );
  }
}

class _GroupPersonRow extends StatelessWidget {
  const _GroupPersonRow({
    required this.user,
    this.role,
    this.trailing,
    this.selected = false,
    this.onTap,
    super.key,
  });

  final ImUser user;
  final ImGroupRole? role;
  final Widget? trailing;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color:
          selected
              ? ZzzColors.yellow.withValues(alpha: 0.08)
              : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 8),
          child: Row(
            children: [
              ZzzAvatar(
                image: user.avatarImage(AppAssets.fallbackAvatarForId(user.id)),
                size: 40,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      user.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (role != null)
                      Text(
                        switch (role!) {
                          ImGroupRole.owner => 'Owner',
                          ImGroupRole.admin => 'Administrator',
                          ImGroupRole.member => 'Member',
                        },
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color:
                              role == ImGroupRole.owner
                                  ? ZzzColors.yellow
                                  : Colors.white38,
                          fontSize: 11,
                        ),
                      ),
                  ],
                ),
              ),
              if (trailing != null) trailing!,
            ],
          ),
        ),
      ),
    );
  }
}
