import 'dart:async';

import 'package:flutter/material.dart';

import '../../assets/app_assets.dart';
import '../../theme/zzz_colors.dart';
import '../../widgets/zzz_widgets.dart';
import '../im_scope.dart';
import '../models/im_models.dart';
import '../models/im_source_address.dart';

/// Account search and friend-request management for the ZZZ Server source.
class FriendCenterPanel extends StatefulWidget {
  const FriendCenterPanel({this.onChanged, super.key});

  final Future<void> Function()? onChanged;

  @override
  State<FriendCenterPanel> createState() => _FriendCenterPanelState();
}

class _FriendCenterPanelState extends State<FriendCenterPanel> {
  final _searchController = TextEditingController();
  final _noteController = TextEditingController();
  Timer? _searchDebounce;
  StreamSubscription<List<ImFriendRequest>>? _requestsSubscription;
  List<ImUser> _results = const [];
  List<ImFriendRequest> _requests = const [];
  bool _loading = true;
  bool _searching = false;
  String? _busyUserId;
  String? _busyRequestId;
  String _query = '';
  late Future<ImUser> _selfFuture;
  bool _selfFutureInitialized = false;
  Object? _subscribedRepository;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _reload());
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    unawaited(_requestsSubscription?.cancel());
    _searchController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final repository = ImScope.repositoryOf(context);
    if (!_selfFutureInitialized) {
      _selfFuture = repository.getCurrentUser();
      _selfFutureInitialized = true;
    }
    if (identical(repository, _subscribedRepository)) return;
    _subscribedRepository = repository;
    unawaited(_requestsSubscription?.cancel());
    _requestsSubscription = repository.watchFriendRequests().listen((requests) {
      if (!mounted) return;
      setState(() {
        _requests = requests;
        _loading = false;
      });
    });
  }

  Future<void> _reload() async {
    final repository = ImScope.repositoryOf(context);
    if (!repository.supportsFriendManagement) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    try {
      final requests = await repository.getFriendRequests();
      if (mounted) setState(() => _requests = requests);
      if (_query.isNotEmpty) await _search(_query, showSpinner: false);
    } catch (error) {
      if (mounted) _showError(error);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _onQueryChanged(String value) {
    _query = value.trim();
    _searchDebounce?.cancel();
    if (_query.isEmpty) {
      setState(() => _results = const []);
      return;
    }
    _searchDebounce = Timer(
      const Duration(milliseconds: 350),
      () => _search(_query),
    );
  }

  Future<void> _search(String query, {bool showSpinner = true}) async {
    if (query.trim().isEmpty) return;
    final normalized = query.trim();
    if (showSpinner && mounted) setState(() => _searching = true);
    try {
      final results = await ImScope.repositoryOf(
        context,
      ).searchUsers(normalized);
      if (mounted && normalized == _query) setState(() => _results = results);
    } catch (error) {
      if (mounted) _showError(error);
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  Future<void> _sendRequest(ImUser user) async {
    setState(() => _busyUserId = user.id);
    try {
      await ImScope.repositoryOf(
        context,
      ).sendFriendRequest(userId: user.id, comment: _noteController.text);
      _noteController.clear();
      await _reload();
      await widget.onChanged?.call();
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Friend request sent')));
      }
    } catch (error) {
      if (mounted) _showError(error);
    } finally {
      if (mounted) setState(() => _busyUserId = null);
    }
  }

  Future<void> _handleRequest(ImFriendRequest request, bool accept) async {
    setState(() => _busyRequestId = request.id);
    try {
      await ImScope.repositoryOf(
        context,
      ).handleFriendRequest(requestId: request.id, accept: accept);
      await _reload();
      await widget.onChanged?.call();
    } catch (error) {
      if (mounted) _showError(error);
    } finally {
      if (mounted) setState(() => _busyRequestId = null);
    }
  }

  Future<void> _removeFriend(ImUser user) async {
    setState(() => _busyUserId = user.id);
    try {
      await ImScope.repositoryOf(context).removeFriend(user.id);
      await _reload();
      await widget.onChanged?.call();
    } catch (error) {
      if (mounted) _showError(error);
    } finally {
      if (mounted) setState(() => _busyUserId = null);
    }
  }

  void _showError(Object error) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$error'), backgroundColor: Colors.red.shade700),
    );
  }

  bool _isIncoming(ImFriendRequest request, ImUser self) =>
      ImSourceAddress.localIdOf(request.toUser.id) ==
      ImSourceAddress.localIdOf(self.id);

  @override
  Widget build(BuildContext context) {
    return ZzzModalPanel(
      key: const ValueKey('friend-center-panel'),
      title: 'Friend center',
      subtitle: 'Find accounts and manage requests',
      icon: Icons.person_add_alt_1_rounded,
      maxWidth: 680,
      maxHeight: 700,
      actions: [
        TextButton.icon(
          onPressed: () => Navigator.of(context).maybePop(),
          icon: const Icon(Icons.close_rounded),
          label: const Text('Close'),
        ),
      ],
      child: FutureBuilder<ImUser>(
        future: _selfFuture,
        builder: (context, snapshot) {
          final self = snapshot.data;
          return Padding(
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ZzzTextInput(
                  key: const ValueKey('friend-center-search'),
                  controller: _searchController,
                  hintText: 'Search by account or nickname',
                  prefixIcon: const Icon(Icons.search_rounded),
                  fillColor: Colors.white.withValues(alpha: 0.08),
                  foregroundColor: Colors.white,
                  textInputAction: TextInputAction.search,
                  onChanged: _onQueryChanged,
                  onSubmitted: (value) => _search(value),
                ),
                const SizedBox(height: 8),
                ZzzTextInput(
                  key: const ValueKey('friend-center-note'),
                  controller: _noteController,
                  hintText: 'Request note (optional)',
                  prefixIcon: const Icon(Icons.chat_bubble_outline_rounded),
                  fillColor: Colors.white.withValues(alpha: 0.06),
                  foregroundColor: Colors.white,
                  maxLength: 200,
                ),
                const SizedBox(height: 8),
                Expanded(
                  child:
                      _loading
                          ? const Center(child: CircularProgressIndicator())
                          : ListView(
                            children: [
                              if (_searching)
                                const LinearProgressIndicator(minHeight: 2),
                              if (_query.isNotEmpty) ...[
                                _SectionHeader(
                                  title: 'Search results',
                                  count: _results.length,
                                ),
                                if (_results.isEmpty && !_searching)
                                  const _EmptyLine(text: 'No matching accounts')
                                else
                                  for (final user in _results)
                                    _FriendResultTile(
                                      user: user,
                                      busy: _busyUserId == user.id,
                                      onAdd: () => _sendRequest(user),
                                      onRemove: () => _removeFriend(user),
                                    ),
                              ],
                              _SectionHeader(
                                title: 'Pending requests',
                                count: _requests.length,
                              ),
                              if (_requests.isEmpty)
                                const _EmptyLine(text: 'No pending requests')
                              else if (self == null)
                                const _EmptyLine(text: 'Loading account…')
                              else
                                for (final request in _requests)
                                  _FriendRequestTile(
                                    request: request,
                                    incoming: _isIncoming(request, self),
                                    busy: _busyRequestId == request.id,
                                    onAccept:
                                        () => _handleRequest(request, true),
                                    onReject:
                                        () => _handleRequest(request, false),
                                  ),
                            ],
                          ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class PendingFriendButton extends StatelessWidget {
  const PendingFriendButton({
    required this.count,
    required this.onTap,
    super.key,
  });

  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        ZzzFooterButton(
          tooltip: 'Friend center',
          onTap: onTap,
          icon: Icons.person_add_alt_1_rounded,
        ),
        if (count > 0)
          Positioned(
            right: -1,
            top: -3,
            child: Container(
              constraints: const BoxConstraints(minWidth: 17, minHeight: 17),
              padding: const EdgeInsets.symmetric(horizontal: 4),
              decoration: const BoxDecoration(
                color: ZzzColors.yellow,
                shape: BoxShape.circle,
              ),
              child: Text(
                '$count',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.black,
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, required this.count});

  final String title;
  final int count;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 5),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
          Text('$count', style: const TextStyle(color: Colors.white38)),
        ],
      ),
    );
  }
}

class _EmptyLine extends StatelessWidget {
  const _EmptyLine({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 14),
    child: Text(text, style: const TextStyle(color: Colors.white38)),
  );
}

class _FriendResultTile extends StatelessWidget {
  const _FriendResultTile({
    required this.user,
    required this.busy,
    required this.onAdd,
    required this.onRemove,
  });

  final ImUser user;
  final bool busy;
  final VoidCallback onAdd;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final relationship = user.relationship;
    final action = switch (relationship) {
      ImRelationship.friend => TextButton.icon(
        onPressed: busy ? null : onRemove,
        icon: const Icon(Icons.person_remove_alt_1_rounded, size: 17),
        label: const Text('Remove'),
      ),
      ImRelationship.outgoing => const Text(
        'Pending',
        style: TextStyle(color: Colors.white38),
      ),
      ImRelationship.incoming => const Text(
        'Incoming request below',
        style: TextStyle(color: Colors.white38, fontSize: 11),
      ),
      ImRelationship.none => FilledButton.icon(
        onPressed: busy ? null : onAdd,
        icon: const Icon(Icons.person_add_alt_1_rounded, size: 17),
        label: busy ? const Text('Sending…') : const Text('Add'),
      ),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          ZzzAvatar(
            image: user.avatarImage(AppAssets.fallbackAvatarForId(user.id)),
            size: 42,
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
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                Text(
                  ImSourceAddress.localIdOf(user.id),
                  style: const TextStyle(color: Colors.white38, fontSize: 11),
                ),
              ],
            ),
          ),
          action,
        ],
      ),
    );
  }
}

class _FriendRequestTile extends StatelessWidget {
  const _FriendRequestTile({
    required this.request,
    required this.incoming,
    required this.busy,
    required this.onAccept,
    required this.onReject,
  });

  final ImFriendRequest request;
  final bool incoming;
  final bool busy;
  final VoidCallback onAccept;
  final VoidCallback onReject;

  @override
  Widget build(BuildContext context) {
    final user = incoming ? request.fromUser : request.toUser;
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.045),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white10),
      ),
      child: Row(
        children: [
          ZzzAvatar(
            image: user.avatarImage(AppAssets.fallbackAvatarForId(user.id)),
            size: 42,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  incoming
                      ? '${user.displayName} wants to connect'
                      : 'Request sent to ${user.displayName}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                if (request.comment.isNotEmpty)
                  Text(
                    request.comment,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                Text(
                  incoming ? 'Incoming' : 'Outgoing',
                  style: const TextStyle(color: Colors.white38, fontSize: 11),
                ),
              ],
            ),
          ),
          if (incoming) ...[
            IconButton(
              tooltip: 'Accept',
              onPressed: busy ? null : onAccept,
              icon: const Icon(Icons.check_circle_outline_rounded),
              color: ZzzColors.yellow,
            ),
            IconButton(
              tooltip: 'Reject',
              onPressed: busy ? null : onReject,
              icon: const Icon(Icons.cancel_outlined),
              color: Colors.white54,
            ),
          ],
        ],
      ),
    );
  }
}
