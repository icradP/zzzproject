import 'package:flutter/material.dart';

import 'package:go_router/go_router.dart';

import '../../../core/routes/index.dart';
import '../../assets/app_assets.dart';
import '../../theme/zzz_colors.dart';
import '../../widgets/zzz_widgets.dart';
import '../data/im_repository.dart';
import '../im_scope.dart';
import '../models/im_models.dart';
import '../widgets/conversation_list_view.dart';
import '../widgets/im_chat_room_view.dart';

class ImHomePage extends StatefulWidget {
  const ImHomePage({super.key});

  static const routeName = '/';

  @override
  State<ImHomePage> createState() => _ImHomePageState();
}

class _ImHomePageState extends State<ImHomePage>
    with SingleTickerProviderStateMixin {
  String? _selectedConversationId;
  late final AnimationController _backgroundController;

  @override
  void initState() {
    super.initState();
    _backgroundController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 30),
    )..repeat();
  }

  @override
  void dispose() {
    _backgroundController.dispose();
    super.dispose();
  }

  void _selectConversation(ImConversation conversation) {
    setState(() => _selectedConversationId = conversation.id);
    ImScope.interactionsOf(context).onConversationOpened(conversation);
    ImScope.repositoryOf(context).markConversationRead(conversation.id);
  }

  void _clearSelection() {
    setState(() => _selectedConversationId = null);
    ImScope.interactionsOf(context).onConversationClosed();
  }

  void _openDemoPage() {
    context.push(AppRoutes.demo);
  }

  Future<String> _resolveUserName(String userId) async {
    final user = await ImScope.repositoryOf(context).getUser(userId);
    return user?.displayName ?? 'Unknown';
  }

  Future<ImageProvider> _resolveUserAvatar(String userId) async {
    final user = await ImScope.repositoryOf(context).getUser(userId);
    if (user?.avatarBytes != null) {
      return MemoryImage(user!.avatarBytes!);
    }
    return AssetImage(user?.avatarAssetPath ?? AppAssets.characterWise);
  }

  @override
  Widget build(BuildContext context) {
    final repository = ImScope.repositoryOf(context);

    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          ZzzBackground(
            controller: _backgroundController,
            animated: true,
          ),
          SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final isWide = constraints.maxWidth >= 860;
                return Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      _buildAppHeader(isWide: isWide),
                      const SizedBox(height: 12),
                      Expanded(
                        child:
                            isWide
                                ? _buildWideLayout(repository)
                                : _buildCompactLayout(repository),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAppHeader({required bool isWide}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: Colors.white12),
      ),
      child: Row(
        children: [
          Container(
            height: 42,
            width: 42,
            decoration: const BoxDecoration(
              color: ZzzColors.yellow,
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.forum_rounded, color: Colors.black),
          ),
          const SizedBox(width: 12),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Messages',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
                ),
                Text(
                  'ZZZ IM',
                  style: TextStyle(color: Colors.white38, fontSize: 12),
                ),
              ],
            ),
          ),
          if (!isWide && _selectedConversationId != null)
            IconButton(
              tooltip: 'Back to inbox',
              onPressed: _clearSelection,
              icon: const Icon(Icons.inbox_rounded),
            ),
          IconButton(
            tooltip: 'New chat',
            onPressed: () {
              ImScope.interactionsOf(context).onComposeNewChat();
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('New chat flow is not wired yet.'),
                  behavior: SnackBarBehavior.floating,
                ),
              );
            },
            icon: const Icon(Icons.edit_square, color: ZzzColors.yellow),
          ),
          IconButton(
            tooltip: 'Settings',
            onPressed: () => context.push(AppRoutes.settings),
            icon: const Icon(Icons.settings_outlined, color: Colors.white54),
          ),
        ],
      ),
    );
  }

  Widget _buildWideLayout(ImRepository repository) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: 340,
          child: ZzzPanel(
            animateEntrance: true,
            child: ConversationListView(
              selectedConversationId: _selectedConversationId,
              onConversationSelected: _selectConversation,
            ),
          ),
        ),
        const SizedBox(width: 14),
        Expanded(child: _buildChatPanel(repository)),
      ],
    );
  }

  Widget _buildCompactLayout(ImRepository repository) {
    if (_selectedConversationId == null) {
      return ZzzPanel(
        animateEntrance: true,
        child: ConversationListView(
          selectedConversationId: _selectedConversationId,
          onConversationSelected: _selectConversation,
        ),
      );
    }
    return _buildChatPanel(repository, showBack: true);
  }

  Widget _buildChatPanel(ImRepository repository, {bool showBack = false}) {
    return ZzzPanel(
      animateEntrance: true,
      background: const DecorationImage(
        image: AssetImage(AppAssets.bgChatWithPatternDark2),
        repeat: ImageRepeat.repeat,
        opacity: 0.1,
      ),
      child: StreamBuilder<List<ImConversation>>(
        stream: repository.watchConversations(),
        builder: (context, conversationSnapshot) {
          final conversations = conversationSnapshot.data ?? const [];
          ImConversation? selected;
          for (final conversation in conversations) {
            if (conversation.id == _selectedConversationId) {
              selected = conversation;
              break;
            }
          }

          if (_selectedConversationId == null || selected == null) {
            return _buildEmptyChatPlaceholder();
          }

          return StreamBuilder<List<ImMessage>>(
            stream: repository.watchMessages(selected.id),
            builder: (context, messageSnapshot) {
              final messages = messageSnapshot.data ?? const [];
              return ImChatRoomView(
                conversation: selected!,
                messages: messages,
                onBack: showBack ? _clearSelection : null,
                resolveUserName: _resolveUserName,
                resolveUserAvatar: _resolveUserAvatar,
                onSend: (text) async {
                  await ImScope.interactionsOf(context).onSendMessage(
                    conversation: selected!,
                    text: text,
                  );
                  await repository.sendTextMessage(
                    conversationId: selected.id,
                    text: text,
                  );
                },
              );
            },
          );
        },
      ),
    );
  }

  Widget _buildEmptyChatPlaceholder() {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Image.asset(AppAssets.stickerEllen, height: 140),
            const SizedBox(height: 16),
            const Text(
              'Select a conversation',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            const Text(
              'Pick a chat from the inbox, or open the simulator demo to test the legacy ZZZ-Chat UI.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white54, height: 1.45),
            ),
            const SizedBox(height: 18),
            OutlinedButton.icon(
              onPressed: _openDemoPage,
              icon: const Icon(Icons.science_outlined),
              label: const Text('Open Chat Simulator Demo'),
            ),
          ],
        ),
      ),
    );
  }
}
