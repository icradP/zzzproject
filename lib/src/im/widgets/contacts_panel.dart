import 'package:flutter/material.dart';

import '../../assets/app_assets.dart';
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
    final request = await showDialog<_CreateGroupRequest>(
      context: context,
      builder: (_) => _CreateGroupDialog(users: availableUsers),
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
              IconButton(
                tooltip: 'Create group',
                onPressed: _createGroup,
                icon: const Icon(Icons.group_add_outlined),
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

class _CreateGroupDialog extends StatefulWidget {
  const _CreateGroupDialog({required this.users});

  final List<ImUser> users;

  @override
  State<_CreateGroupDialog> createState() => _CreateGroupDialogState();
}

class _CreateGroupDialogState extends State<_CreateGroupDialog> {
  final _nameController = TextEditingController();
  final _selectedMemberIds = <String>{};

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _nameController.text.trim();
    if (name.isEmpty) return;
    Navigator.of(context).pop(
      _CreateGroupRequest(
        name: name,
        memberIds: _selectedMemberIds.toList(growable: false),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Create group'),
      content: SizedBox(
        width: 420,
        height: 320,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _nameController,
              autofocus: true,
              maxLength: 80,
              decoration: const InputDecoration(labelText: 'Group name'),
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => _submit(),
            ),
            const Text(
              'Members',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            Expanded(
              child:
                  widget.users.isEmpty
                      ? const Center(
                        child: Text(
                          'No contacts available',
                          style: TextStyle(color: Colors.white54),
                        ),
                      )
                      : ListView.builder(
                        itemCount: widget.users.length,
                        itemBuilder: (context, index) {
                          final user = widget.users[index];
                          return CheckboxListTile(
                            value: _selectedMemberIds.contains(user.id),
                            secondary: ZzzAvatar(
                              image: user.avatarImage(AppAssets.characterWise),
                              size: 36,
                            ),
                            title: Text(
                              user.displayName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              ImSourceAddress.localIdOf(user.id),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            onChanged: (selected) {
                              setState(() {
                                if (selected == true) {
                                  _selectedMemberIds.add(user.id);
                                } else {
                                  _selectedMemberIds.remove(user.id);
                                }
                              });
                            },
                          );
                        },
                      ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          onPressed: _nameController.text.trim().isEmpty ? null : _submit,
          icon: const Icon(Icons.group_add_outlined),
          label: const Text('Create'),
        ),
      ],
    );
  }
}
