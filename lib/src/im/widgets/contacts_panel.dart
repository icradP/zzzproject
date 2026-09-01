import 'dart:async';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../assets/app_assets.dart';
import '../../theme/zzz_colors.dart';
import '../../widgets/zzz_widgets.dart';
import '../data/im_repository.dart';
import '../im_scope.dart';
import '../models/im_models.dart';
import '../models/im_source_address.dart';
import 'contact_tile.dart';
import 'friend_center_panel.dart';

class ContactsPanel extends StatefulWidget {
  const ContactsPanel({required this.onConversationSelected, super.key});

  final ValueChanged<ImConversation> onConversationSelected;

  @override
  State<ContactsPanel> createState() => _ContactsPanelState();
}

class _ContactsPanelState extends State<ContactsPanel> {
  final _searchController = TextEditingController();
  StreamSubscription<List<ImUser>>? _usersSubscription;
  ImRepository? _subscribedRepository;
  String _query = '';

  List<ImUser> _users = const [];
  List<ImConversation> _groups = const [];
  List<ImFriendRequest> _friendRequests = const [];
  String? _selfId;
  bool _loading = true;
  bool _showGroups = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadData());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final repository = ImScope.repositoryOf(context);
    if (identical(repository, _subscribedRepository)) return;
    _subscribedRepository = repository;
    unawaited(_usersSubscription?.cancel());
    _usersSubscription = repository.watchUsers().listen((users) {
      if (!mounted) return;
      setState(() {
        _users = users;
        _loading = false;
      });
    });
  }

  @override
  void dispose() {
    unawaited(_usersSubscription?.cancel());
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    final repo = ImScope.repositoryOf(context);
    try {
      final users = await repo.getUsers();
      final groups = await repo.getGroupList();
      final self = await repo.getCurrentUser();
      final friendRequests =
          repo.supportsFriendManagement
              ? await repo.getFriendRequests()
              : const <ImFriendRequest>[];
      if (mounted) {
        setState(() {
          _users = users;
          _groups = groups;
          _friendRequests = friendRequests;
          _selfId = self.id;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _openFriendCenter() async {
    await showZzzModalPanel<void>(
      context: context,
      builder:
          (_) => FriendCenterPanel(
            onChanged: () async {
              await _loadData();
            },
          ),
    );
    if (mounted) await _loadData();
  }

  List<ImUser> get _filteredUsers {
    if (_query.isEmpty) return _users;
    return _users
        .where((u) => u.displayName.toLowerCase().contains(_query))
        .toList();
  }

  List<ImConversation> get _filteredGroups {
    if (_query.isEmpty) return _groups;
    return _groups
        .where((g) => g.title.toLowerCase().contains(_query))
        .toList();
  }

  void _onUserTap(ImUser user) async {
    final self = await ImScope.repositoryOf(
      context,
    ).getCurrentUser(sourceId: user.sourceId);
    final localIds = [
      ImSourceAddress.localIdOf(self.id),
      ImSourceAddress.localIdOf(user.id),
    ]..sort();
    final localConversationId = 'dm_${localIds[0]}_${localIds[1]}';
    final conversationId =
        user.sourceId == null
            ? localConversationId
            : ImSourceAddress.scope(user.sourceId!, localConversationId);
    final conversation = ImConversation(
      id: conversationId,
      type: ImConversationType.direct,
      title: user.displayName,
      participantIds: [self.id, user.id],
      avatarAssetPath: user.avatarAssetPath,
      avatarLocalPath: user.avatarLocalPath,
      sourceId: user.sourceId,
      sourceLabel: user.sourceLabel,
    );
    if (mounted) widget.onConversationSelected(conversation);
  }

  void _onGroupTap(ImConversation group) {
    widget.onConversationSelected(group);
  }

  Future<void> _createGroup() async {
    final repository = ImScope.repositoryOf(context);
    final self = await repository.getCurrentUser();
    if (!mounted) return;
    final availableUsers = _users
        .where(
          (user) => self.sourceId == null || user.sourceId == self.sourceId,
        )
        .toList(growable: false);
    final request = await showZzzModalPanel<_CreateGroupRequest>(
      context: context,
      builder: (_) => _CreateGroupPanel(users: availableUsers),
    );
    if (request == null || !mounted) return;
    try {
      final group = await repository.createGroup(
        name: request.name,
        memberIds: request.memberIds,
        avatar: request.avatar,
      );
      if (!mounted) return;
      setState(() => _groups = [..._groups, group]);
      widget.onConversationSelected(group);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Unable to create group: $error'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ZzzTextInput(
          controller: _searchController,
          hintText: 'Search contacts',
          prefixIcon: const Icon(Icons.search_rounded),
          fillColor: Colors.white.withValues(alpha: 0.06),
          foregroundColor: Colors.white,
          onChanged: (v) => setState(() => _query = v.trim().toLowerCase()),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: ZzzSegmentedControl<String>(
                value: _showGroups ? 'group' : 'dm',
                items: const [
                  ZzzSegmentItem<String>(
                    value: 'dm',
                    tooltip: '私聊',
                    iconAsset: AppAssets.iconDm,
                  ),
                  ZzzSegmentItem<String>(
                    value: 'group',
                    tooltip: '群聊',
                    iconAsset: AppAssets.iconGroupChat,
                  ),
                ],
                onChanged: (v) => setState(() => _showGroups = v == 'group'),
              ),
            ),
            if (_showGroups)
              ZzzFooterButton(
                tooltip: 'Create group',
                onTap: _createGroup,
                icon: Icons.group_add_outlined,
              ),
            if (!_showGroups &&
                ImScope.repositoryOf(context).supportsFriendManagement)
              PendingFriendButton(
                count:
                    _friendRequests
                        .where((request) => request.isPending)
                        .where((request) => request.toUser.id == _selfId)
                        .length,
                onTap: _openFriendCenter,
              ),
          ],
        ),
        const SizedBox(height: 8),
        Expanded(
          child:
              _loading
                  ? const Center(child: CircularProgressIndicator())
                  : AnimatedSwitcher(
                    duration: const Duration(milliseconds: 200),
                    child:
                        _showGroups
                            ? _buildGroupTab(key: const ValueKey('groups'))
                            : _buildPrivateTab(key: const ValueKey('private')),
                  ),
        ),
      ],
    );
  }

  Widget _buildPrivateTab({Key? key}) {
    final users = _filteredUsers;
    if (users.isEmpty) {
      return _buildEmpty(
        _query.isEmpty ? 'No contacts yet' : 'No matches',
        key: key,
      );
    }
    return ListView.separated(
      key: key,
      itemCount: users.length,
      separatorBuilder: (_, __) => const SizedBox(height: 2),
      itemBuilder:
          (_, i) =>
              ContactTile(user: users[i], onTap: () => _onUserTap(users[i])),
    );
  }

  Widget _buildGroupTab({Key? key}) {
    final groups = _filteredGroups;
    if (groups.isEmpty) {
      return _buildEmpty(
        _query.isEmpty ? 'No groups yet' : 'No matches',
        key: key,
      );
    }
    return ListView.separated(
      key: key,
      itemCount: groups.length,
      separatorBuilder: (_, __) => const SizedBox(height: 2),
      itemBuilder:
          (_, i) => GroupTile(
            conversation: groups[i],
            onTap: () => _onGroupTap(groups[i]),
          ),
    );
  }

  Widget _buildEmpty(String message, {Key? key}) {
    return Center(
      key: key,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Image.asset(AppAssets.stickerEllen, height: 100),
          const SizedBox(height: 10),
          Text(message, style: const TextStyle(color: Colors.white38)),
        ],
      ),
    );
  }
}

class _CreateGroupRequest {
  const _CreateGroupRequest({
    required this.name,
    required this.memberIds,
    this.avatar,
  });

  final String name;
  final List<String> memberIds;
  final ImMediaUpload? avatar;
}

enum _CreateGroupStep { profile, members, review }

class _CreateGroupPanel extends StatefulWidget {
  const _CreateGroupPanel({required this.users});

  final List<ImUser> users;

  @override
  State<_CreateGroupPanel> createState() => _CreateGroupPanelState();
}

class _CreateGroupPanelState extends State<_CreateGroupPanel> {
  final _nameController = TextEditingController();
  final _memberSearchController = TextEditingController();
  final _selectedMemberIds = <String>{};
  Uint8List? _avatarBytes;
  String? _avatarName;
  String? _avatarMime;
  String? _avatarError;
  String _memberQuery = '';
  bool _showSelectedOnly = false;
  _CreateGroupStep _step = _CreateGroupStep.profile;

  bool get _hasValidName {
    final name = _nameController.text.trim();
    return name.isNotEmpty && name.length <= 80;
  }

  List<ImUser> get _filteredUsers {
    return widget.users
        .where((user) {
          final id = ImSourceAddress.localIdOf(user.id).toLowerCase();
          final matchesQuery =
              _memberQuery.isEmpty ||
              user.displayName.toLowerCase().contains(_memberQuery) ||
              id.contains(_memberQuery);
          final matchesSelection =
              !_showSelectedOnly || _selectedMemberIds.contains(user.id);
          return matchesQuery && matchesSelection;
        })
        .toList(growable: false);
  }

  List<ImUser> get _selectedUsers => widget.users
      .where((user) => _selectedMemberIds.contains(user.id))
      .toList(growable: false);

  @override
  void dispose() {
    _nameController.dispose();
    _memberSearchController.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _nameController.text.trim();
    if (!_hasValidName) return;
    Navigator.of(context).pop(
      _CreateGroupRequest(
        name: name,
        memberIds: _selectedMemberIds.toList(growable: false),
        avatar:
            _avatarBytes == null
                ? null
                : ImMediaUpload(
                  kind: ImMessageKind.image,
                  fileName: _avatarName ?? 'group-avatar.jpg',
                  bytes: _avatarBytes,
                  mimeType: _avatarMime,
                ),
      ),
    );
  }

  Future<void> _pickGroupAvatar() async {
    final result = await FilePicker.pickFiles(
      type: FileType.image,
      withData: true,
      allowMultiple: false,
    );
    final file = result?.files.single;
    if (file == null || file.bytes == null || !mounted) return;
    if (file.bytes!.length > 5 * 1024 * 1024) {
      setState(() => _avatarError = 'Group avatar must be 5 MB or smaller.');
      return;
    }
    setState(() {
      _avatarBytes = file.bytes;
      _avatarName = file.name;
      _avatarMime = file.extension == null ? null : 'image/${file.extension}';
      _avatarError = null;
    });
  }

  void _toggleMember(ImUser user) {
    setState(() {
      if (!_selectedMemberIds.add(user.id)) {
        _selectedMemberIds.remove(user.id);
      }
    });
  }

  bool get _allMembersSelected =>
      widget.users.isNotEmpty &&
      widget.users.every((user) => _selectedMemberIds.contains(user.id));

  void _toggleAllMembers() {
    setState(() {
      if (_allMembersSelected) {
        _selectedMemberIds.clear();
      } else {
        _selectedMemberIds.addAll(widget.users.map((user) => user.id));
      }
    });
  }

  void _setStep(_CreateGroupStep step) {
    if (_step == step) return;
    setState(() => _step = step);
  }

  List<Widget> _buildActions({required bool compact}) {
    if (!compact) {
      return [
        TextButton.icon(
          onPressed: () => Navigator.of(context).pop(),
          icon: const Icon(Icons.close_rounded),
          label: const Text('Cancel'),
        ),
        FilledButton.icon(
          onPressed: _hasValidName ? _submit : null,
          icon: const Icon(Icons.group_add_outlined),
          label: const Text('Create'),
        ),
      ];
    }

    return [
      if (_step != _CreateGroupStep.profile)
        TextButton.icon(
          key: const ValueKey('create-group-back'),
          onPressed:
              () => _setStep(
                _step == _CreateGroupStep.review
                    ? _CreateGroupStep.members
                    : _CreateGroupStep.profile,
              ),
          icon: const Icon(Icons.arrow_back_rounded),
          label: const Text('Back'),
        ),
      FilledButton.icon(
        key: ValueKey(
          _step == _CreateGroupStep.review
              ? 'create-group-submit'
              : 'create-group-next',
        ),
        onPressed:
            _step == _CreateGroupStep.review
                ? (_hasValidName ? _submit : null)
                : _step == _CreateGroupStep.profile && !_hasValidName
                ? null
                : () => _setStep(
                  _step == _CreateGroupStep.profile
                      ? _CreateGroupStep.members
                      : _CreateGroupStep.review,
                ),
        icon: Icon(
          _step == _CreateGroupStep.review
              ? Icons.group_add_outlined
              : Icons.arrow_forward_rounded,
        ),
        label: Text(_step == _CreateGroupStep.review ? 'Create' : 'Next'),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final filteredUsers = _filteredUsers;
    final selectedUsers = _selectedUsers;
    final selectedCount = _selectedMemberIds.length;
    final compact = MediaQuery.sizeOf(context).width < 688;

    return ZzzModalPanel(
      key: const ValueKey('create-group-panel'),
      title: 'Create group',
      subtitle:
          compact
              ? '${switch (_step) {
                _CreateGroupStep.profile => 'Profile',
                _CreateGroupStep.members => 'Members',
                _CreateGroupStep.review => 'Review',
              }} / $selectedCount selected'
              : '$selectedCount selected',
      icon: Icons.group_add_outlined,
      maxWidth: 780,
      maxHeight: 700,
      collapsible: true,
      actions: _buildActions(compact: compact),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 12),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final isWide = constraints.maxWidth >= 620;
            final memberBrowser = _buildMemberBrowser(filteredUsers);
            final groupProfile = _buildGroupProfile(
              selectedUsers,
              compact: !isWide,
            );
            final selectedMembers = _buildSelectedMembers(
              selectedUsers,
              initiallyExpanded: isWide,
              compact: !isWide,
            );

            if (!isWide) {
              return Column(
                key: const ValueKey('create-group-compact-layout'),
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ZzzSegmentedControl<_CreateGroupStep>(
                    key: const ValueKey('create-group-steps'),
                    value: _step,
                    items: const [
                      ZzzSegmentItem(
                        value: _CreateGroupStep.profile,
                        tooltip: 'Group profile',
                        icon: Icons.badge_outlined,
                      ),
                      ZzzSegmentItem(
                        value: _CreateGroupStep.members,
                        tooltip: 'Choose members',
                        icon: Icons.group_outlined,
                      ),
                      ZzzSegmentItem(
                        value: _CreateGroupStep.review,
                        tooltip: 'Review group',
                        icon: Icons.fact_check_outlined,
                      ),
                    ],
                    onChanged: _setStep,
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: ZzzAnimatedSwap(
                      value: _step,
                      builder:
                          (_) => switch (_step) {
                            _CreateGroupStep.profile => SingleChildScrollView(
                              key: const ValueKey('create-group-profile-step'),
                              child: groupProfile,
                            ),
                            _CreateGroupStep.members => Column(
                              key: const ValueKey('create-group-members-step'),
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                selectedMembers,
                                const Divider(
                                  height: 12,
                                  color: Colors.white12,
                                ),
                                Expanded(child: memberBrowser),
                              ],
                            ),
                            _CreateGroupStep.review => _buildGroupReview(
                              selectedUsers,
                            ),
                          },
                    ),
                  ),
                ],
              );
            }

            return Row(
              key: const ValueKey('create-group-wide-layout'),
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(flex: 5, child: memberBrowser),
                const VerticalDivider(width: 28, color: Colors.white12),
                SizedBox(
                  width: 270,
                  child: ListView(
                    children: [
                      groupProfile,
                      const SizedBox(height: 8),
                      selectedMembers,
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildGroupProfile(
    List<ImUser> selectedUsers, {
    required bool compact,
  }) {
    final nameInput = ZzzTextInput(
      key: const ValueKey('create-group-name'),
      controller: _nameController,
      autofocus: true,
      hintText: 'Group name',
      prefixIcon: const Icon(Icons.edit_outlined),
      fillColor: Colors.white.withValues(alpha: 0.08),
      foregroundColor: Colors.white,
      onChanged: (_) => setState(() {}),
      onSubmitted: (_) {
        if (MediaQuery.sizeOf(context).width < 688) {
          if (_hasValidName) _setStep(_CreateGroupStep.members);
          return;
        }
        _submit();
      },
    );

    final profile =
        compact
            ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    _buildGroupAvatarWithCount(users: selectedUsers, size: 54),
                    const SizedBox(width: 12),
                    Expanded(child: nameInput),
                    const SizedBox(width: 4),
                    _buildAvatarPickerButton(compact: true),
                  ],
                ),
                if (_avatarError != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    _avatarError!,
                    style: const TextStyle(
                      color: Colors.redAccent,
                      fontSize: 11,
                    ),
                  ),
                ],
              ],
            )
            : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Group identity',
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.2,
                  ),
                ),
                const SizedBox(height: 10),
                Align(
                  alignment: Alignment.centerLeft,
                  child: _buildGroupAvatarWithCount(
                    users: selectedUsers,
                    size: 72,
                  ),
                ),
                const SizedBox(height: 12),
                nameInput,
                const SizedBox(height: 8),
                Text(
                  selectedUsers.isEmpty
                      ? 'Choose contacts to build the group roster.'
                      : '${selectedUsers.length} selected. You can manage members after the group is created.',
                  style: const TextStyle(
                    color: Colors.white38,
                    fontSize: 11,
                    height: 1.35,
                  ),
                ),
                const SizedBox(height: 10),
                _buildAvatarPickerButton(compact: false),
                if (_avatarError != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    _avatarError!,
                    style: const TextStyle(
                      color: Colors.redAccent,
                      fontSize: 11,
                    ),
                  ),
                ],
              ],
            );

    return ZzzExpandablePanel(
      key: const ValueKey('create-group-profile'),
      title: 'Group profile',
      subtitle: _hasValidName ? _nameController.text.trim() : 'Name and avatar',
      padding:
          compact
              ? const EdgeInsets.fromLTRB(12, 2, 12, 2)
              : const EdgeInsets.all(12),
      radius: 14,
      dense: compact,
      child: profile,
    );
  }

  Widget _buildGroupAvatarWithCount({
    required List<ImUser> users,
    required double size,
  }) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        _avatarBytes == null
            ? _GroupAvatarPreview(users: users, size: size)
            : Semantics(
              label: 'Uploaded group avatar',
              child: Container(
                key: const ValueKey('create-group-uploaded-avatar'),
                width: size,
                height: size,
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: ZzzColors.yellow.withValues(alpha: 0.8),
                    width: 2,
                  ),
                ),
                child: ClipOval(
                  child: Image.memory(_avatarBytes!, fit: BoxFit.cover),
                ),
              ),
            ),
        Positioned(
          right: -4,
          bottom: -4,
          child: Container(
            constraints: const BoxConstraints(minWidth: 22, minHeight: 22),
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
            decoration: BoxDecoration(
              color: ZzzColors.yellow,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: ZzzColors.panel, width: 2),
            ),
            child: Text(
              '${users.length}',
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.black,
                fontSize: 10,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildAvatarPickerButton({required bool compact}) {
    if (compact) {
      return IconButton(
        key: const ValueKey('create-group-avatar-pick'),
        tooltip:
            _avatarBytes == null
                ? 'Upload group avatar'
                : 'Change group avatar',
        onPressed: _pickGroupAvatar,
        icon: Icon(
          _avatarBytes == null
              ? Icons.add_a_photo_outlined
              : Icons.edit_outlined,
          size: 20,
        ),
        style: IconButton.styleFrom(
          minimumSize: const Size(40, 40),
          fixedSize: const Size(40, 40),
          padding: EdgeInsets.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      );
    }
    return OutlinedButton.icon(
      key: const ValueKey('create-group-avatar-pick'),
      onPressed: _pickGroupAvatar,
      icon: const Icon(Icons.upload_rounded, size: 18),
      label: Text(
        _avatarBytes == null
            ? 'Upload group avatar'
            : _avatarName ?? 'Image selected',
        overflow: TextOverflow.ellipsis,
      ),
    );
  }

  Widget _buildSelectedMembers(
    List<ImUser> selectedUsers, {
    required bool initiallyExpanded,
    required bool compact,
  }) {
    return ZzzExpandablePanel(
      key: const ValueKey('create-group-selected-panel'),
      title: 'Selected members',
      subtitle:
          selectedUsers.isEmpty
              ? 'No members selected'
              : '${selectedUsers.length} selected',
      padding:
          compact ? EdgeInsets.zero : const EdgeInsets.fromLTRB(12, 2, 12, 2),
      radius: 14,
      initiallyExpanded: initiallyExpanded,
      dense: compact,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: selectedUsers.isEmpty ? 48 : 72,
            child:
                selectedUsers.isEmpty
                    ? const Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'No members selected',
                        style: TextStyle(color: Colors.white38, fontSize: 12),
                      ),
                    )
                    : ListView.separated(
                      key: const ValueKey('selected-group-members'),
                      scrollDirection: Axis.horizontal,
                      itemCount: selectedUsers.length,
                      separatorBuilder: (_, __) => const SizedBox(width: 8),
                      itemBuilder: (context, index) {
                        final user = selectedUsers[index];
                        return ZzzSelectableAvatar(
                          image: user.avatarImage(
                            AppAssets.fallbackAvatarForId(user.id),
                          ),
                          label: user.displayName,
                          selected: true,
                          size: 38,
                          onSelect: () => _toggleMember(user),
                        );
                      },
                    ),
          ),
          if (selectedUsers.isNotEmpty)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: () => setState(() => _selectedMemberIds.clear()),
                icon: const Icon(Icons.deselect_rounded, size: 18),
                label: const Text('Clear'),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildGroupReview(List<ImUser> selectedUsers) {
    final groupName = _nameController.text.trim();
    return ListView(
      key: const ValueKey('create-group-review-step'),
      padding: const EdgeInsets.only(bottom: 4),
      children: [
        Align(
          child: _buildGroupAvatarWithCount(users: selectedUsers, size: 88),
        ),
        const SizedBox(height: 12),
        Text(
          groupName.isEmpty ? 'Unnamed group' : groupName,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 4),
        Text(
          '${selectedUsers.length} members selected',
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white54, fontSize: 12),
        ),
        const SizedBox(height: 18),
        _buildSelectedMembers(
          selectedUsers,
          initiallyExpanded: true,
          compact: false,
        ),
      ],
    );
  }

  Widget _buildMemberBrowser(List<ImUser> filteredUsers) {
    final selectedCount = _selectedMemberIds.length;
    final showSelection = _showSelectedOnly && selectedCount > 0;
    return Column(
      key: const ValueKey('create-group-member-browser'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Expanded(
              child: Text(
                'Contacts',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
            Text(
              showSelection
                  ? '$selectedCount selected'
                  : '${filteredUsers.length} available',
              style: const TextStyle(color: Colors.white38, fontSize: 12),
            ),
            const SizedBox(width: 2),
            IconButton(
              key: const ValueKey('create-group-filter-selected'),
              tooltip: showSelection ? 'Show all contacts' : 'Show selected',
              onPressed:
                  selectedCount == 0
                      ? null
                      : () => setState(
                        () => _showSelectedOnly = !_showSelectedOnly,
                      ),
              style: IconButton.styleFrom(
                minimumSize: const Size(28, 28),
                fixedSize: const Size(28, 28),
                padding: EdgeInsets.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              icon: Icon(
                showSelection
                    ? Icons.filter_alt_rounded
                    : Icons.filter_alt_outlined,
                size: 19,
              ),
            ),
            IconButton(
              key: const ValueKey('create-group-select-all'),
              tooltip: _allMembersSelected ? 'Clear all' : 'Select all',
              onPressed: widget.users.isEmpty ? null : _toggleAllMembers,
              style: IconButton.styleFrom(
                minimumSize: const Size(28, 28),
                fixedSize: const Size(28, 28),
                padding: EdgeInsets.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              icon: Icon(
                _allMembersSelected
                    ? Icons.deselect_rounded
                    : Icons.done_all_rounded,
                size: 19,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        ZzzTextInput(
          key: const ValueKey('create-group-member-search'),
          controller: _memberSearchController,
          hintText: 'Search contacts',
          prefixIcon: const Icon(Icons.search_rounded),
          fillColor: Colors.white.withValues(alpha: 0.08),
          foregroundColor: Colors.white,
          textInputAction: TextInputAction.search,
          onChanged:
              (value) =>
                  setState(() => _memberQuery = value.trim().toLowerCase()),
        ),
        const SizedBox(height: 8),
        Expanded(
          child:
              filteredUsers.isEmpty
                  ? Center(
                    child: Text(
                      _showSelectedOnly
                          ? 'No selected contacts'
                          : 'No matching contacts',
                      style: const TextStyle(color: Colors.white54),
                    ),
                  )
                  : ListView.separated(
                    key: const ValueKey('create-group-member-list'),
                    itemCount: filteredUsers.length,
                    separatorBuilder:
                        (_, __) =>
                            const Divider(height: 1, color: Colors.white10),
                    itemBuilder: (context, index) {
                      final user = filteredUsers[index];
                      final selected = _selectedMemberIds.contains(user.id);
                      return _CreateGroupMemberTile(
                        key: ValueKey('create-group-member-${user.id}'),
                        user: user,
                        selected: selected,
                        onTap: () => _toggleMember(user),
                      );
                    },
                  ),
        ),
      ],
    );
  }
}

class _GroupAvatarPreview extends StatelessWidget {
  const _GroupAvatarPreview({required this.users, required this.size});

  final List<ImUser> users;
  final double size;

  @override
  Widget build(BuildContext context) {
    final visibleUsers = users.take(3).toList(growable: false);
    final avatarSize = size * 0.64;
    return Semantics(
      label: users.isEmpty ? 'Empty group avatar' : 'Group avatar preview',
      child: Container(
        key: const ValueKey('create-group-avatar-preview'),
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.06),
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white12),
        ),
        child:
            visibleUsers.isEmpty
                ? Icon(
                  Icons.groups_2_outlined,
                  color: Colors.white38,
                  size: size * 0.44,
                )
                : Stack(
                  clipBehavior: Clip.none,
                  children: [
                    for (var index = 0; index < visibleUsers.length; index++)
                      Positioned(
                        left: index.isEven ? 0 : size - avatarSize,
                        top:
                            index == 0
                                ? 0
                                : index == 1
                                ? 0
                                : size - avatarSize,
                        child: Container(
                          padding: const EdgeInsets.all(1.5),
                          decoration: const BoxDecoration(
                            color: ZzzColors.panel,
                            shape: BoxShape.circle,
                          ),
                          child: ZzzAvatar(
                            image: visibleUsers[index].avatarImage(
                              AppAssets.fallbackAvatarForId(
                                visibleUsers[index].id,
                              ),
                            ),
                            size: avatarSize,
                            animateEntrance: true,
                          ),
                        ),
                      ),
                  ],
                ),
      ),
    );
  }
}

class _CreateGroupMemberTile extends StatelessWidget {
  const _CreateGroupMemberTile({
    required this.user,
    required this.selected,
    required this.onTap,
    super.key,
  });

  final ImUser user;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          decoration: BoxDecoration(
            color:
                selected
                    ? ZzzColors.yellow.withValues(alpha: 0.09)
                    : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  ZzzAvatar(
                    image: user.avatarImage(
                      AppAssets.fallbackAvatarForId(user.id),
                    ),
                    size: 40,
                  ),
                  Positioned(
                    right: -1,
                    bottom: -1,
                    child: Container(
                      width: 11,
                      height: 11,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color:
                            user.isOnline ? ZzzColors.yellow : Colors.white30,
                        border: Border.all(color: ZzzColors.panel, width: 2),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      user.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    Text(
                      ImSourceAddress.localIdOf(user.id),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white38,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
              Checkbox(
                value: selected,
                onChanged: (_) => onTap(),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(5),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
