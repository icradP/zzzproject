import 'package:flutter/material.dart';

import '../../assets/app_assets.dart';
import '../../widgets/zzz_widgets.dart';
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
            builder: (context, snapshot) {
              final conversations = snapshot.data ?? const <ImConversation>[];
              final filtered =
                  _query.isEmpty
                      ? conversations
                      : conversations.where((conversation) {
                        return conversation.title.toLowerCase().contains(
                              _query,
                            ) ||
                            (conversation.subtitle ?? '').toLowerCase().contains(
                              _query,
                            );
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

              return ListView.separated(
                itemCount: filtered.length,
                separatorBuilder: (_, __) => const SizedBox(height: 4),
                itemBuilder: (context, index) {
                  final conversation = filtered[index];
                  return ConversationTile(
                    conversation: conversation,
                    selected: conversation.id == widget.selectedConversationId,
                    onTap: () => widget.onConversationSelected(conversation),
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
