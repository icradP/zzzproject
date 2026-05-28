import 'package:flutter/material.dart';

import '../../assets/app_assets.dart';
import '../../widgets/zzz_widgets.dart';
import '../im_scope.dart';
import '../models/im_models.dart';
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
    final self = await ImScope.repositoryOf(context).getCurrentUser();
    final ids = [self.id, user.id]..sort();
    final conversationId = 'dm_${ids[0]}_${ids[1]}';
    final conversation = ImConversation(
      id: conversationId,
      type: ImConversationType.direct,
      title: user.displayName,
      participantIds: [self.id, user.id],
      avatarAssetPath: user.avatarAssetPath,
      avatarLocalPath: user.avatarLocalPath,
    );
    if (mounted) widget.onConversationSelected(conversation);
  }

  void _onGroupTap(ImConversation group) {
    widget.onConversationSelected(group);
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
        ZzzSegmentedControl<String>(
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
      return _buildEmpty(_query.isEmpty ? 'No contacts yet' : 'No matches', key: key);
    }
    return ListView.separated(
      key: key,
      itemCount: users.length,
      separatorBuilder: (_, __) => const SizedBox(height: 2),
      itemBuilder: (_, i) => ContactTile(
        user: users[i],
        onTap: () => _onUserTap(users[i]),
      ),
    );
  }

  Widget _buildGroupTab({Key? key}) {
    final groups = _filteredGroups;
    if (groups.isEmpty) {
      return _buildEmpty(_query.isEmpty ? 'No groups yet' : 'No matches', key: key);
    }
    return ListView.separated(
      key: key,
      itemCount: groups.length,
      separatorBuilder: (_, __) => const SizedBox(height: 2),
      itemBuilder: (_, i) => GroupTile(
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
