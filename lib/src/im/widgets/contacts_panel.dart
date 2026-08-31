import 'package:flutter/material.dart';

import '../../assets/app_assets.dart';
import '../../theme/zzz_colors.dart';
import '../../widgets/zzz_widgets.dart';
import '../im_scope.dart';
import '../models/im_models.dart';
import '../models/im_source_address.dart';
import 'contact_tile.dart';

class ContactsPanel extends StatefulWidget {
  const ContactsPanel({required this.onConversationSelected, super.key});

  final ValueChanged<ImConversation> onConversationSelected;

  @override
  State<ContactsPanel> createState() => _ContactsPanelState();
}

class _ContactsPanelState extends State<ContactsPanel> {
  final _searchController = TextEditingController();
  String _query = '';

  List<ImUser> _users = const [];
  List<ImConversation> _groups = const [];
  bool _loading = true;
  bool _showGroups = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadData());
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    final repo = ImScope.repositoryOf(context);
    try {
      final users = await repo.getUsers();
      final groups = await repo.getGroupList();
      if (mounted) {
        setState(() {
          _users = users;
          _groups = groups;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
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
  const _CreateGroupRequest({required this.name, required this.memberIds});

  final String name;
  final List<String> memberIds;
}

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
  String _memberQuery = '';

  bool get _hasValidName {
    final name = _nameController.text.trim();
    return name.isNotEmpty && name.length <= 80;
  }

  List<ImUser> get _filteredUsers {
    if (_memberQuery.isEmpty) return widget.users;
    return widget.users
        .where((user) {
          final id = ImSourceAddress.localIdOf(user.id).toLowerCase();
          return user.displayName.toLowerCase().contains(_memberQuery) ||
              id.contains(_memberQuery);
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
      ),
    );
  }

  void _toggleMember(ImUser user) {
    setState(() {
      if (!_selectedMemberIds.add(user.id)) {
        _selectedMemberIds.remove(user.id);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final filteredUsers = _filteredUsers;
    final selectedUsers = _selectedUsers;
    final selectedCount = _selectedMemberIds.length;

    return ZzzModalPanel(
      key: const ValueKey('create-group-panel'),
      title: 'Create group',
      subtitle: '$selectedCount selected',
      icon: Icons.group_add_outlined,
      actions: [
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
      ],
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ZzzTextInput(
              key: const ValueKey('create-group-name'),
              controller: _nameController,
              autofocus: true,
              hintText: 'Group name',
              prefixIcon: const Icon(Icons.edit_outlined),
              fillColor: Colors.white.withValues(alpha: 0.08),
              foregroundColor: Colors.white,
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => _submit(),
            ),
            ZzzReveal(
              expanded: selectedUsers.isNotEmpty,
              child: Padding(
                padding: const EdgeInsets.only(top: 14),
                child: SizedBox(
                  height: 68,
                  child: ListView.separated(
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
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 14, bottom: 8),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Members',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                  if (selectedCount > 0)
                    TextButton.icon(
                      onPressed:
                          () => setState(() => _selectedMemberIds.clear()),
                      icon: const Icon(Icons.deselect_rounded, size: 18),
                      label: const Text('Clear'),
                    ),
                ],
              ),
            ),
            ZzzTextInput(
              key: const ValueKey('create-group-member-search'),
              controller: _memberSearchController,
              hintText: 'Search members',
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
                      ? const Center(
                        child: Text(
                          'No matching contacts',
                          style: TextStyle(color: Colors.white54),
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
