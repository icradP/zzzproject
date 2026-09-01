import 'dart:async';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../assets/app_assets.dart';
import '../../theme/zzz_colors.dart';
import '../../widgets/zzz_widgets.dart';
import '../data/im_repository.dart';
import '../models/im_models.dart';
import '../models/im_source_address.dart';
import 'im_profile_card_panel.dart';

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
  final _nameController = TextEditingController();
  final _announcementController = TextEditingController();
  final _selectedInvitees = <String>{};
  Uint8List? _avatarBytes;
  String? _avatarName;
  String? _avatarMime;
  ImGroupDetails? _details;
  List<ImUser> _availableUsers = const [];
  String _tab = 'members';
  String _query = '';
  String? _error;
  bool _loading = true;
  bool _busy = false;
  String? _editingAnnouncementId;
  bool _announcementPinned = false;

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
    _nameController.dispose();
    _announcementController.dispose();
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
        _nameController.text = details.conversation.title;
        if (_editingAnnouncementId == null) {
          _announcementController.clear();
          _announcementPinned = false;
        }
        _availableUsers = users;
        _error = userLoadError;
        _selectedInvitees.removeWhere(
          (id) => details.members.any((member) => member.user.id == id),
        );
        final settingsAvailable =
            details.canEditSettings ||
            details.canTransferOwnership ||
            details.canDismiss;
        if (_tab == 'invite' && !details.canInviteMembers ||
            _tab == 'settings' && !settingsAvailable) {
          _tab = 'members';
        }
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

  Future<void> _pickGroupAvatar() async {
    final result = await FilePicker.pickFiles(
      type: FileType.image,
      withData: true,
      allowMultiple: false,
    );
    final file = result?.files.single;
    if (file == null || file.bytes == null) return;
    if (file.bytes!.length > 5 * 1024 * 1024) {
      setState(() => _error = 'Group avatar must be 5 MB or smaller.');
      return;
    }
    setState(() {
      _avatarBytes = file.bytes;
      _avatarName = file.name;
      _avatarMime = file.extension == null ? null : 'image/${file.extension}';
      _error = null;
    });
  }

  Future<void> _runGroupAction(Future<void> Function() action) async {
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

  Future<void> _saveSettings(ImGroupDetails details) async {
    final name = _nameController.text.trim();
    if (details.supportsNameEditing && (name.isEmpty || name.length > 80)) {
      setState(() => _error = 'Group name must be 1-80 characters.');
      return;
    }
    await _runGroupAction(() async {
      await widget.repository.updateGroup(
        groupId: widget.conversation.id,
        name: details.supportsNameEditing ? name : null,
        avatar:
            _avatarBytes == null
                ? null
                : ImMediaUpload(
                  kind: ImMessageKind.image,
                  fileName: _avatarName ?? 'group-avatar.jpg',
                  bytes: _avatarBytes,
                  mimeType: _avatarMime,
                ),
      );
      _avatarBytes = null;
      _avatarName = null;
      _avatarMime = null;
    });
  }

  Future<void> _saveAnnouncement() async {
    final content = _announcementController.text.trim();
    if (content.isEmpty || content.length > 2000) {
      setState(() => _error = 'Announcement must be 1-2000 characters.');
      return;
    }
    final editingId = _editingAnnouncementId;
    await _runGroupAction(() async {
      if (editingId == null) {
        await widget.repository.createGroupAnnouncement(
          groupId: widget.conversation.id,
          content: content,
          isPinned: _announcementPinned,
        );
      } else {
        await widget.repository.updateGroupAnnouncement(
          announcementId: editingId,
          content: content,
          isPinned: _announcementPinned,
        );
      }
      _editingAnnouncementId = null;
      _announcementController.clear();
      _announcementPinned = false;
    });
  }

  void _editAnnouncement(ImGroupAnnouncement announcement) {
    setState(() {
      _editingAnnouncementId = announcement.id;
      _announcementController.text = announcement.content;
      _announcementPinned = announcement.isPinned;
      _error = null;
    });
  }

  void _cancelAnnouncementEdit() {
    setState(() {
      _editingAnnouncementId = null;
      _announcementController.clear();
      _announcementPinned = false;
    });
  }

  Future<void> _toggleAnnouncementPin(ImGroupAnnouncement announcement) =>
      _runGroupAction(
        () => widget.repository.updateGroupAnnouncement(
          announcementId: announcement.id,
          content: announcement.content,
          isPinned: !announcement.isPinned,
        ),
      );

  Future<void> _deleteAnnouncement(ImGroupAnnouncement announcement) async {
    final confirmed = await _confirm(
      title: 'Delete announcement',
      message: 'This removes the announcement from group history.',
      actionLabel: 'Delete',
    );
    if (!confirmed || !mounted) return;
    await _runGroupAction(
      () => widget.repository.deleteGroupAnnouncement(announcement.id),
    );
  }

  Future<void> _markAnnouncementsRead() async {
    final unread =
        _details?.announcements.where((value) => !value.isRead) ??
        const <ImGroupAnnouncement>[];
    if (unread.isEmpty) return;
    try {
      for (final announcement in unread) {
        await widget.repository.markGroupAnnouncementRead(announcement.id);
      }
      await _load();
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
  }

  void _changeTab(String value) {
    setState(() => _tab = value);
    if (value == 'announcements') unawaited(_markAnnouncementsRead());
  }

  Future<void> _setAdministrator(ImGroupMember member, bool enabled) =>
      _runGroupAction(
        () => widget.repository.setGroupAdmin(
          groupId: widget.conversation.id,
          userId: member.user.id,
          enabled: enabled,
        ),
      );

  Future<void> _setMemberMute(ImGroupMember member, Duration duration) =>
      _runGroupAction(
        () => widget.repository.setGroupMemberMute(
          groupId: widget.conversation.id,
          userId: member.user.id,
          duration: duration,
        ),
      );

  Future<void> _chooseMemberMute(ImGroupMember member) async {
    final options = <(String, Duration)>[
      ('10 minutes', const Duration(minutes: 10)),
      ('1 hour', const Duration(hours: 1)),
      ('12 hours', const Duration(hours: 12)),
      ('1 day', const Duration(days: 1)),
      ('7 days', const Duration(days: 7)),
    ];
    final duration = await showZzzModalPanel<Duration>(
      context: context,
      builder:
          (dialogContext) => ZzzModalPanel(
            title: 'Mute member',
            subtitle: member.user.displayName,
            icon: Icons.volume_off_outlined,
            maxWidth: 420,
            maxHeight: 440,
            child: ListView.separated(
              key: const ValueKey('group-mute-duration-list'),
              padding: const EdgeInsets.all(12),
              itemCount: options.length,
              separatorBuilder:
                  (_, __) => const Divider(height: 1, color: Colors.white10),
              itemBuilder: (context, index) {
                final option = options[index];
                return Material(
                  color: Colors.transparent,
                  child: ListTile(
                    leading: const Icon(Icons.schedule_rounded),
                    title: Text(option.$1),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => Navigator.of(dialogContext).pop(option.$2),
                  ),
                );
              },
            ),
          ),
    );
    if (duration != null && mounted) await _setMemberMute(member, duration);
  }

  Future<void> _transferOwnership(ImGroupMember member) async {
    final confirmed = await _confirm(
      title: 'Transfer ownership',
      message:
          '${member.user.displayName} will become the group owner. You will become a regular member.',
      actionLabel: 'Transfer',
    );
    if (!confirmed || !mounted) return;
    await _runGroupAction(
      () => widget.repository.transferGroupOwnership(
        groupId: widget.conversation.id,
        userId: member.user.id,
      ),
    );
  }

  Future<void> _setMuteAll(bool enabled) => _runGroupAction(
    () => widget.repository.setGroupMuteAll(
      groupId: widget.conversation.id,
      enabled: enabled,
    ),
  );

  Future<void> _dismissGroup() async {
    final confirmed = await _confirm(
      title: 'Dismiss group',
      message:
          'This permanently removes the group for every member. This action cannot be undone.',
      actionLabel: 'Dismiss',
    );
    if (!confirmed || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.repository.dismissGroup(widget.conversation.id);
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
    final hasSettings =
        details != null &&
        (details.canEditSettings ||
            details.canTransferOwnership ||
            details.canDismiss);
    final tabs = <ZzzSegmentItem<String>>[
      const ZzzSegmentItem<String>(
        value: 'members',
        tooltip: 'Members',
        icon: Icons.groups_rounded,
      ),
      if (details?.canInviteMembers ?? false)
        const ZzzSegmentItem<String>(
          value: 'invite',
          tooltip: 'Invite members',
          icon: Icons.person_add_alt_1_rounded,
        ),
      if (details != null &&
          (details.supportsAnnouncementEditing ||
              details.announcements.isNotEmpty))
        const ZzzSegmentItem<String>(
          value: 'announcements',
          tooltip: 'Announcements',
          icon: Icons.campaign_outlined,
        ),
      if (hasSettings)
        const ZzzSegmentItem<String>(
          value: 'settings',
          tooltip: 'Group settings',
          icon: Icons.tune_rounded,
        ),
    ];
    return ZzzModalPanel(
      key: const ValueKey('group-details-panel'),
      title: 'Group management',
      subtitle: details?.conversation.title ?? widget.conversation.title,
      icon: Icons.manage_accounts_outlined,
      maxWidth: 760,
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
                    if (tabs.length > 1) ...[
                      ZzzSegmentedControl<String>(
                        key: const ValueKey('group-management-tabs'),
                        value: _tab,
                        items: tabs,
                        onChanged: _changeTab,
                      ),
                      const SizedBox(height: 12),
                    ],
                    Expanded(
                      child:
                          details == null
                              ? _buildRetry()
                              : AnimatedSwitcher(
                                duration: const Duration(milliseconds: 180),
                                child: switch (_tab) {
                                  'invite' => _buildInviteList(),
                                  'announcements' => _buildAnnouncements(
                                    details,
                                  ),
                                  'settings' => _buildSettings(details),
                                  _ => _buildMemberList(details),
                                },
                              ),
                    ),
                    if ((details?.canLeave ?? false) && _tab != 'settings') ...[
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

  Widget _buildAnnouncements(ImGroupDetails details) {
    final announcements = details.announcements;
    return Column(
      key: const ValueKey('group-announcements-tab'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (details.currentUserIsManager &&
            details.supportsAnnouncementEditing) ...[
          ZzzTextInput(
            key: const ValueKey('group-announcement-input'),
            controller: _announcementController,
            hintText:
                _editingAnnouncementId == null
                    ? 'Publish an announcement'
                    : 'Edit announcement',
            minLines: 2,
            maxLines: 4,
            maxLength: 2000,
            prefixIcon: const Icon(Icons.campaign_outlined),
            fillColor: Colors.white.withValues(alpha: 0.08),
            foregroundColor: Colors.white,
          ),
          Row(
            children: [
              Expanded(
                child: Material(
                  color: Colors.transparent,
                  child: CheckboxListTile(
                    key: const ValueKey('group-announcement-pinned'),
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    title: const Text('Pin announcement'),
                    value: _announcementPinned,
                    onChanged:
                        _busy
                            ? null
                            : (value) => setState(
                              () => _announcementPinned = value ?? false,
                            ),
                  ),
                ),
              ),
              if (_editingAnnouncementId != null)
                IconButton(
                  key: const ValueKey('group-announcement-cancel-edit'),
                  tooltip: 'Cancel editing',
                  onPressed: _busy ? null : _cancelAnnouncementEdit,
                  icon: const Icon(Icons.close_rounded),
                ),
              FilledButton.icon(
                key: const ValueKey('group-announcement-save'),
                onPressed: _busy ? null : _saveAnnouncement,
                icon: Icon(
                  _editingAnnouncementId == null
                      ? Icons.send_rounded
                      : Icons.save_outlined,
                ),
                label: Text(
                  _editingAnnouncementId == null ? 'Publish' : 'Save',
                ),
              ),
            ],
          ),
          const Divider(height: 20, color: Colors.white12),
        ],
        Expanded(
          child:
              announcements.isEmpty
                  ? const Center(
                    child: Text(
                      'No announcements yet',
                      style: TextStyle(color: Colors.white38),
                    ),
                  )
                  : ListView.separated(
                    key: const ValueKey('group-announcement-list'),
                    itemCount: announcements.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder:
                        (context, index) => _buildAnnouncementItem(
                          details,
                          announcements[index],
                        ),
                  ),
        ),
      ],
    );
  }

  Widget _buildAnnouncementItem(
    ImGroupDetails details,
    ImGroupAnnouncement announcement,
  ) {
    String? author;
    for (final member in details.members) {
      if (member.user.id == announcement.authorId) {
        author = member.user.displayName;
        break;
      }
    }
    return Container(
      key: ValueKey('group-announcement-${announcement.id}'),
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 12),
      decoration: BoxDecoration(
        color:
            announcement.isRead
                ? Colors.white.withValues(alpha: 0.045)
                : ZzzColors.yellow.withValues(alpha: 0.09),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color:
              announcement.isPinned
                  ? ZzzColors.yellow.withValues(alpha: 0.5)
                  : Colors.white12,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              if (announcement.isPinned) ...[
                const Icon(Icons.push_pin_rounded, size: 16),
                const SizedBox(width: 5),
              ],
              Expanded(
                child: Text(
                  '${author ?? announcement.authorId} · ${_formatAnnouncementTime(announcement.updatedAt)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white54, fontSize: 12),
                ),
              ),
              if (!announcement.isRead)
                Container(
                  width: 7,
                  height: 7,
                  decoration: const BoxDecoration(
                    color: ZzzColors.yellow,
                    shape: BoxShape.circle,
                  ),
                ),
              if (details.currentUserIsManager &&
                  details.supportsAnnouncementEditing)
                PopupMenuButton<String>(
                  key: ValueKey(
                    'group-announcement-actions-${announcement.id}',
                  ),
                  tooltip: 'Manage announcement',
                  enabled: !_busy,
                  onSelected: (action) {
                    switch (action) {
                      case 'edit':
                        _editAnnouncement(announcement);
                      case 'pin':
                        unawaited(_toggleAnnouncementPin(announcement));
                      case 'delete':
                        unawaited(_deleteAnnouncement(announcement));
                    }
                  },
                  itemBuilder:
                      (_) => [
                        const PopupMenuItem(
                          value: 'edit',
                          child: ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: Icon(Icons.edit_outlined),
                            title: Text('Edit'),
                          ),
                        ),
                        PopupMenuItem(
                          value: 'pin',
                          child: ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: Icon(
                              announcement.isPinned
                                  ? Icons.push_pin_outlined
                                  : Icons.push_pin_rounded,
                            ),
                            title: Text(
                              announcement.isPinned ? 'Unpin' : 'Pin',
                            ),
                          ),
                        ),
                        const PopupMenuItem(
                          value: 'delete',
                          child: ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: Icon(
                              Icons.delete_outline_rounded,
                              color: Colors.redAccent,
                            ),
                            title: Text(
                              'Delete',
                              style: TextStyle(color: Colors.redAccent),
                            ),
                          ),
                        ),
                      ],
                  icon: const Icon(Icons.more_vert_rounded),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            announcement.content,
            style: const TextStyle(color: Colors.white, height: 1.4),
          ),
        ],
      ),
    );
  }

  String _formatAnnouncementTime(DateTime value) {
    final local = value.toLocal();
    final minute = local.minute.toString().padLeft(2, '0');
    return '${local.month}/${local.day} ${local.hour}:$minute';
  }

  Widget _buildSettings(ImGroupDetails details) {
    final profile = ZzzExpandableSection(
      key: const ValueKey('group-profile-settings'),
      title: 'Group profile',
      subtitle: 'Name and image',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (details.supportsAvatarEditing) ...[
            Row(
              children: [
                ZzzAvatar(
                  image:
                      _avatarBytes == null
                          ? details.conversation.avatarImage(
                            AppAssets.fallbackAvatarForId(
                              details.conversation.id,
                            ),
                          )
                          : MemoryImage(_avatarBytes!),
                  size: 52,
                ),
                const SizedBox(width: 12),
                Flexible(
                  child: OutlinedButton.icon(
                    key: const ValueKey('group-avatar-pick'),
                    onPressed: _busy ? null : _pickGroupAvatar,
                    icon: const Icon(Icons.photo_camera_outlined),
                    label: Text(
                      _avatarBytes == null ? 'Change image' : 'Image selected',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
          ],
          if (details.supportsNameEditing) ...[
            ZzzTextInput(
              key: const ValueKey('group-name-input'),
              controller: _nameController,
              hintText: 'Group name',
              maxLength: 80,
              prefixIcon: const Icon(Icons.group_outlined),
              fillColor: Colors.white.withValues(alpha: 0.08),
              foregroundColor: Colors.white,
            ),
            const SizedBox(height: 10),
          ],
          FilledButton.icon(
            key: const ValueKey('group-settings-save'),
            onPressed: _busy ? null : () => _saveSettings(details),
            icon: const Icon(Icons.save_outlined),
            label: const Text('Save changes'),
          ),
        ],
      ),
    );
    final governance = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (details.supportsWholeGroupMute && details.currentUserIsManager)
          ZzzExpandableSection(
            key: const ValueKey('group-moderation-settings'),
            title: 'Moderation',
            subtitle: 'Control who can send messages',
            child: Material(
              color: Colors.transparent,
              child: SwitchListTile.adaptive(
                key: const ValueKey('group-mute-all'),
                contentPadding: EdgeInsets.zero,
                title: const Text('Mute all members'),
                subtitle: const Text(
                  'Owners and administrators can still send messages.',
                ),
                value: details.muteAll,
                onChanged: _busy ? null : _setMuteAll,
              ),
            ),
          ),
        if (details.canLeave || details.canDismiss)
          ZzzExpandableSection(
            key: const ValueKey('group-danger-settings'),
            title: 'Group access',
            subtitle: 'Permanent membership actions',
            initiallyExpanded: false,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (details.canLeave)
                  OutlinedButton.icon(
                    key: const ValueKey('group-leave-settings'),
                    onPressed: _busy ? null : _leaveGroup,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.redAccent,
                    ),
                    icon: const Icon(Icons.logout_rounded),
                    label: const Text('Leave group'),
                  ),
                if (details.canDismiss)
                  FilledButton.icon(
                    key: const ValueKey('group-dismiss'),
                    onPressed: _busy ? null : _dismissGroup,
                    style: FilledButton.styleFrom(
                      backgroundColor: ZzzColors.red,
                      foregroundColor: Colors.white,
                    ),
                    icon: const Icon(Icons.delete_forever_outlined),
                    label: const Text('Dismiss group'),
                  ),
              ],
            ),
          ),
      ],
    );

    return LayoutBuilder(
      key: const ValueKey('group-settings-tab'),
      builder: (context, constraints) {
        if (constraints.maxWidth >= 560) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.only(right: 14),
                  children: [profile],
                ),
              ),
              const VerticalDivider(width: 1, color: Colors.white12),
              SizedBox(
                width: 250,
                child: ListView(
                  padding: const EdgeInsets.only(left: 14),
                  children: [governance],
                ),
              ),
            ],
          );
        }
        return ListView(
          padding: EdgeInsets.zero,
          children: [profile, const Divider(color: Colors.white12), governance],
        );
      },
    );
  }

  void _handleMemberAction(String action, ImGroupMember member) {
    switch (action) {
      case 'promote':
        unawaited(_setAdministrator(member, true));
      case 'demote':
        unawaited(_setAdministrator(member, false));
      case 'mute':
        unawaited(_chooseMemberMute(member));
      case 'unmute':
        unawaited(_setMemberMute(member, Duration.zero));
      case 'transfer':
        unawaited(_transferOwnership(member));
      case 'remove':
        unawaited(_removeMember(member));
      case 'title':
        unawaited(_manageTitles(member));
    }
  }

  Future<void> _openMemberProfile(ImGroupMember member) =>
      showZzzModalPanel<void>(
        context: context,
        builder:
            (_) => ImProfileCardPanel(
              userId: member.user.id,
              groupId: widget.conversation.id,
              repository: widget.repository,
            ),
      );

  Future<void> _manageTitles(ImGroupMember member) => showZzzModalPanel<void>(
    context: context,
    builder:
        (_) => _GroupTitlePanel(
          repository: widget.repository,
          groupId: widget.conversation.id,
          user: member.user,
        ),
  );

  Widget? _buildMemberActions(ImGroupDetails details, ImGroupMember member) {
    final canSetAdmin = details.canSetAdministrator(member);
    final canMute = details.canMuteMember(member);
    final canTransfer =
        details.canTransferOwnership &&
        member.user.id != details.currentUserId &&
        member.role != ImGroupRole.owner;
    final canRemove = details.canRemoveMember(member);
    final canManageTitles = details.currentUserIsManager;
    if (!canSetAdmin &&
        !canMute &&
        !canTransfer &&
        !canRemove &&
        !canManageTitles) {
      return null;
    }
    return PopupMenuButton<String>(
      key: ValueKey('group-member-actions-${member.user.id}'),
      tooltip: 'Manage ${member.user.displayName}',
      enabled: !_busy,
      onSelected: (action) => _handleMemberAction(action, member),
      itemBuilder:
          (context) => [
            if (canManageTitles)
              const PopupMenuItem(
                value: 'title',
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.workspace_premium_outlined),
                  title: Text('Manage titles'),
                ),
              ),
            if (canSetAdmin)
              PopupMenuItem(
                value: member.role == ImGroupRole.admin ? 'demote' : 'promote',
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    member.role == ImGroupRole.admin
                        ? Icons.remove_moderator_outlined
                        : Icons.admin_panel_settings_outlined,
                  ),
                  title: Text(
                    member.role == ImGroupRole.admin
                        ? 'Remove administrator'
                        : 'Make administrator',
                  ),
                ),
              ),
            if (canMute)
              PopupMenuItem(
                value: member.isMuted ? 'unmute' : 'mute',
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    member.isMuted
                        ? Icons.volume_up_outlined
                        : Icons.volume_off_outlined,
                  ),
                  title: Text(member.isMuted ? 'Unmute' : 'Mute...'),
                ),
              ),
            if (canTransfer)
              const PopupMenuItem(
                value: 'transfer',
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.swap_horiz_rounded),
                  title: Text('Transfer ownership'),
                ),
              ),
            if (canRemove)
              const PopupMenuItem(
                value: 'remove',
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    Icons.person_remove_outlined,
                    color: Colors.redAccent,
                  ),
                  title: Text(
                    'Remove from group',
                    style: TextStyle(color: Colors.redAccent),
                  ),
                ),
              ),
          ],
      icon: const Icon(Icons.more_vert_rounded),
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
        return _GroupPersonRow(
          key: ValueKey('group-member-${member.user.id}'),
          user: member.user,
          role: member.role,
          mutedUntil: member.mutedUntil,
          onTap: () => _openMemberProfile(member),
          trailing: _buildMemberActions(details, member),
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
    this.mutedUntil,
    this.trailing,
    this.selected = false,
    this.onTap,
    super.key,
  });

  final ImUser user;
  final ImGroupRole? role;
  final DateTime? mutedUntil;
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
                        [
                          switch (role!) {
                            ImGroupRole.owner => 'Owner',
                            ImGroupRole.admin => 'Administrator',
                            ImGroupRole.member => 'Member',
                          },
                          if (mutedUntil?.isAfter(DateTime.now()) ?? false)
                            'Muted',
                        ].join(' | '),
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

class _GroupTitlePanel extends StatefulWidget {
  const _GroupTitlePanel({
    required this.repository,
    required this.groupId,
    required this.user,
  });

  final ImRepository repository;
  final String groupId;
  final ImUser user;

  @override
  State<_GroupTitlePanel> createState() => _GroupTitlePanelState();
}

class _GroupTitlePanelState extends State<_GroupTitlePanel> {
  final _textController = TextEditingController();
  ImUser? _profile;
  String _style = 'yellow';
  int _expiryDays = 0;
  bool _loading = true;
  bool _busy = false;
  String? _error;

  List<ImUserTitle> get _titles =>
      _profile?.titles
          .where(
            (title) => title.isGroupScoped && title.scopeId == widget.groupId,
          )
          .toList(growable: false) ??
      const [];

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final profile = await widget.repository.getProfileCard(
        widget.user.id,
        groupId: widget.groupId,
      );
      if (!mounted) return;
      setState(() {
        _profile = profile;
        _loading = false;
        _error = profile == null ? 'Profile is unavailable.' : null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$error';
      });
    }
  }

  Future<void> _grant() async {
    final text = _textController.text.trim();
    if (text.isEmpty || text.characters.length > 24) {
      setState(() => _error = 'Title must be 1-24 characters.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.repository.grantGroupTitle(
        groupId: widget.groupId,
        userId: widget.user.id,
        text: text,
        style: _style,
        expiresAt:
            _expiryDays == 0
                ? null
                : DateTime.now().toUtc().add(Duration(days: _expiryDays)),
      );
      _textController.clear();
      await _load();
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _revoke(ImUserTitle title) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.repository.revokeGroupTitle(
        groupId: widget.groupId,
        userId: widget.user.id,
        titleId: title.id,
      );
      await _load();
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ZzzModalPanel(
      title: 'Group titles',
      subtitle: widget.user.displayName,
      icon: Icons.workspace_premium_outlined,
      maxWidth: 520,
      maxHeight: 680,
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
              : ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  const Text(
                    'Active titles',
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 10),
                  if (_titles.isEmpty)
                    const Text(
                      'No active group titles.',
                      style: TextStyle(color: Colors.white38),
                    )
                  else
                    ..._titles.map(
                      (title) => Material(
                        color: Colors.transparent,
                        child: ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Align(
                            alignment: Alignment.centerLeft,
                            child: ImTitleBadge(title: title),
                          ),
                          subtitle: Text(
                            title.expiresAt == null
                                ? 'No expiry'
                                : 'Expires ${MaterialLocalizations.of(context).formatShortDate(title.expiresAt!.toLocal())}',
                          ),
                          trailing: IconButton(
                            tooltip: 'Revoke title',
                            onPressed: _busy ? null : () => _revoke(title),
                            icon: const Icon(Icons.delete_outline_rounded),
                          ),
                        ),
                      ),
                    ),
                  const Divider(height: 32, color: Colors.white12),
                  ZzzTextInput(
                    controller: _textController,
                    hintText: 'New title',
                    maxLength: 24,
                    prefixIcon: const Icon(Icons.badge_outlined),
                    fillColor: Colors.white.withValues(alpha: 0.08),
                    foregroundColor: Colors.white,
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    initialValue: _style,
                    decoration: const InputDecoration(labelText: 'Style'),
                    items: const [
                      DropdownMenuItem(value: 'gold', child: Text('Gold')),
                      DropdownMenuItem(value: 'red', child: Text('Red')),
                      DropdownMenuItem(value: 'yellow', child: Text('Yellow')),
                      DropdownMenuItem(value: 'aurora', child: Text('Aurora')),
                      DropdownMenuItem(value: 'ember', child: Text('Ember')),
                    ],
                    onChanged:
                        _busy
                            ? null
                            : (value) {
                              if (value != null) setState(() => _style = value);
                            },
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<int>(
                    initialValue: _expiryDays,
                    decoration: const InputDecoration(labelText: 'Expiry'),
                    items: const [
                      DropdownMenuItem(value: 0, child: Text('No expiry')),
                      DropdownMenuItem(value: 7, child: Text('7 days')),
                      DropdownMenuItem(value: 30, child: Text('30 days')),
                      DropdownMenuItem(value: 90, child: Text('90 days')),
                    ],
                    onChanged:
                        _busy
                            ? null
                            : (value) {
                              if (value != null) {
                                setState(() => _expiryDays = value);
                              }
                            },
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      _error!,
                      style: const TextStyle(color: Colors.redAccent),
                    ),
                  ],
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: _busy ? null : _grant,
                    icon:
                        _busy
                            ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                            : const Icon(Icons.add_rounded),
                    label: const Text('Grant title'),
                  ),
                ],
              ),
    );
  }
}
