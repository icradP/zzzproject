import 'package:flutter/material.dart';

import '../../assets/app_assets.dart';
import '../../widgets/zzz_widgets.dart';
import '../data/im_animation_config.dart';
import '../im_scope.dart';
import '../models/im_models.dart';
import 'conversation_tile.dart';

class ConversationListView extends StatefulWidget {
  const ConversationListView({
    required this.selectedConversationId,
    required this.onConversationSelected,
    super.key,
  });

  final String? selectedConversationId;
  final ValueChanged<ImConversation> onConversationSelected;

  @override
  State<ConversationListView> createState() => _ConversationListViewState();
}

class _ConversationListViewState extends State<ConversationListView> {
  final _searchController = TextEditingController();
  String _query = '';
  List<ImConversation>? _cachedConversations;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final repository = ImScope.repositoryOf(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ZzzTextInput(
          controller: _searchController,
          hintText: 'Search conversations',
          prefixIcon: const Icon(Icons.search_rounded),
          fillColor: Colors.white.withValues(alpha: 0.06),
          foregroundColor: Colors.white,
          onChanged: (value) {
            setState(() => _query = value.trim().toLowerCase());
            ImScope.interactionsOf(context).onSearchQueryChanged(value);
          },
        ),
        const SizedBox(height: 12),
        Expanded(
          child: StreamBuilder<List<ImConversation>>(
            stream: repository.watchConversations(),
            initialData: _cachedConversations,
            builder: (context, snapshot) {
              final conversations = snapshot.data ?? const <ImConversation>[];
              _cachedConversations = conversations;
              final filtered = _query.isEmpty
                  ? conversations
                  : conversations.where((conversation) {
                      return conversation.title
                              .toLowerCase()
                              .contains(_query) ||
                          (conversation.subtitle ?? '')
                              .toLowerCase()
                              .contains(_query);
                    }).toList();

              if (filtered.isEmpty) {
                return Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Image.asset(
                        AppAssets.stickerEllen,
                        height: 120,
                        fit: BoxFit.contain,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        _query.isEmpty
                            ? 'No conversations yet'
                            : 'No matches for "$_query"',
                        style: const TextStyle(color: Colors.white54),
                      ),
                    ],
                  ),
                );
              }

              return ListView.builder(
                itemCount: filtered.length,
                itemBuilder: (context, index) {
                  final conv = filtered[index];
                  return _AnimatedListItem(
                    key: ValueKey(conv.id),
                    index: index,
                    child: ConversationTile(
                      conversation: conv,
                      selected: conv.id == widget.selectedConversationId,
                      onTap: () => widget.onConversationSelected(conv),
                      onDelete: () {
                        ImScope.repositoryOf(context)
                            .deleteConversation(conv.id);
                      },
                    ),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }
}

/// Wraps a list tile so it slides into its new position when the index
/// changes (e.g. a conversation moving to the top on new message).
class _AnimatedListItem extends StatefulWidget {
  const _AnimatedListItem({
    required this.index,
    required this.child,
    super.key,
  });

  final int index;
  final Widget child;

  @override
  State<_AnimatedListItem> createState() => _AnimatedListItemState();
}

class _AnimatedListItemState extends State<_AnimatedListItem>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<Offset> _slide;
  int _prevIndex = -1;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _slide = Tween<Offset>(
      begin: Offset.zero,
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutCubic,
    ));
    _prevIndex = widget.index;
  }

  @override
  void didUpdateWidget(covariant _AnimatedListItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    final enabled = ImAnimationConfig.instance.conversationListSlide;
    if (widget.index != _prevIndex && _prevIndex >= 0 && enabled) {
      // Animate from the previous position to the current one.
      // A positive delta means the item moved up in the list.
      final delta = (_prevIndex - widget.index).clamp(-6, 6);
      _slide = Tween<Offset>(
        begin: Offset(0, delta * 0.8),
        end: Offset.zero,
      ).animate(CurvedAnimation(
        parent: _controller,
        curve: Curves.easeOutCubic,
      ));
      _controller.forward(from: 0);
    }
    _prevIndex = widget.index;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SlideTransition(position: _slide, child: widget.child);
  }
}
