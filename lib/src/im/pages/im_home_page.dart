import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/routes/index.dart';
import '../../assets/app_assets.dart';
import '../../theme/zzz_colors.dart';
import '../../widgets/zzz_widgets.dart';
import '../data/im_animation_config.dart';
import '../data/im_backdrop_config.dart';
import '../data/im_repository.dart';
import '../im_scope.dart';
import '../models/im_models.dart';
import '../widgets/conversation_list_view.dart';
import '../widgets/contacts_panel.dart';
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
  String? _previousConversationId;
  ImConversation? _pendingConversation;
  bool _showContacts = false;
  double _dragOffset = 0.0;
  late final AnimationController _backgroundController;

  /// Cached snapshot data so switching conversations doesn't flash empty.
  final _conversationCache = <String, List<ImConversation>>{};
  final _messageCache = <String, List<ImMessage>>{};

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
    setState(() {
      if (_selectedConversationId != null &&
          _selectedConversationId != conversation.id) {
        _previousConversationId = _selectedConversationId;
      }
      _selectedConversationId = conversation.id;
      _pendingConversation = conversation;
    });
    ImScope.interactionsOf(context).onConversationOpened(conversation);
    ImScope.repositoryOf(context).markConversationRead(conversation.id);
  }

  void _clearSelection() {
    setState(() {
      _dragOffset = 0.0;
      _selectedConversationId = null;
      _previousConversationId = null;
    });
    ImScope.interactionsOf(context).onConversationClosed();
  }

  void _openDemoPage() {
    context.push(AppRoutes.demo);
  }

  Future<void> _openContactsPage() async {
    final result = await context.push<ImConversation>(AppRoutes.contacts);
    if (result != null && mounted) {
      ImScope.repositoryOf(context).ensureConversation(result);
      _selectConversation(result);
    }
  }

  void _onNewChatPressed(bool isWide) {
    if (isWide) {
      setState(() => _showContacts = true);
    } else {
      _openContactsPage();
    }
  }

  void _closeContacts() {
    setState(() => _showContacts = false);
  }

  void _onContactsSelection(ImConversation conversation) {
    setState(() => _showContacts = false);
    ImScope.repositoryOf(context).ensureConversation(conversation);
    _selectConversation(conversation);
  }

  Future<String> _resolveUserName(String userId) async {
    final user = await ImScope.repositoryOf(context).getUser(userId);
    return user?.displayName ?? 'Unknown';
  }

  ImMessage? _findMessage(String id, List<ImMessage> messages) {
    // Exact match first.
    try {
      return messages.firstWhere((m) => m.id == id);
    } catch (_) {}
    // Split messages use ids like "1234567_0" — try any prefix match.
    for (final m in messages) {
      if (m.id.startsWith('${id}_')) return m;
    }
    return null;
  }

  Future<ImageProvider> _resolveUserAvatar(String userId) async {
    final user = await ImScope.repositoryOf(context).getUser(userId);
    return user?.avatarImage(AppAssets.characterWise) ??
        AssetImage(AppAssets.characterWise);
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
            backdropLines: ImBackdropConfig.instance.lines,
          ),
          SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final isWide = constraints.maxWidth >= 860;
                return Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      // Hide the "Messages" header when inside a conversation
                      // on compact screens — the chat panel has its own header.
                      if (!(!isWide && _selectedConversationId != null))
                        _buildAppHeader(isWide: isWide),
                      if (!(!isWide && _selectedConversationId != null))
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
          if (isWide && _showContacts)
            IconButton(
              tooltip: 'Close contacts',
              onPressed: _closeContacts,
              icon: const Icon(Icons.close_rounded),
            ),
          if (!isWide && _selectedConversationId != null)
            IconButton(
              tooltip: 'Back to inbox',
              onPressed: _clearSelection,
              icon: const Icon(Icons.inbox_rounded),
            ),
          if (!(isWide && _showContacts))
            IconButton(
              tooltip: 'New chat',
              onPressed: () => _onNewChatPressed(isWide),
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
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            child: _showContacts
                ? ZzzPanel(
                    key: const ValueKey('contacts'),
                    animateEntrance: true,
                    background: const DecorationImage(
                      image: AssetImage(AppAssets.bgChatWithPatternDark2),
                      repeat: ImageRepeat.repeat,
                      opacity: 0.1,
                    ),
                    child: ContactsPanel(
                      onConversationSelected: _onContactsSelection,
                    ),
                  )
                : ZzzPanel(
                    key: const ValueKey('inbox'),
                    animateEntrance: true,
                    child: ConversationListView(
                      selectedConversationId: _selectedConversationId,
                      onConversationSelected: _selectConversation,
                    ),
                  ),
          ),
        ),
        const SizedBox(width: 14),
        Expanded(child: _buildChatPanel(repository)),
      ],
    );
  }

  Widget _buildCompactLayout(ImRepository repository) {
    final isInChat = _selectedConversationId != null;
    final screenWidth = MediaQuery.of(context).size.width;

    Widget child;
    if (!isInChat) {
      child = ZzzPanel(
        key: const ValueKey('inbox'),
        animateEntrance: true,
        child: ConversationListView(
          selectedConversationId: _selectedConversationId,
          onConversationSelected: _selectConversation,
        ),
      );
    } else {
      child = GestureDetector(
        onHorizontalDragUpdate: (details) {
          if (details.delta.dx > 0 || _dragOffset > 0) {
            setState(() {
              _dragOffset = (_dragOffset + details.delta.dx).clamp(0.0, screenWidth);
            });
          }
        },
        onHorizontalDragEnd: (details) {
          final shouldDismiss =
              _dragOffset > screenWidth * 0.25 ||
              (details.primaryVelocity ?? 0) > 200;
          if (shouldDismiss) {
            _clearSelection();
          }
          setState(() => _dragOffset = 0.0);
        },
        child: Transform.translate(
          offset: Offset(_dragOffset, 0),
          child: _buildChatPanel(repository),
        ),
      );
    }

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 300),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, animation) {
        return SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0.3, 0),
            end: Offset.zero,
          ).animate(CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
          )),
          child: FadeTransition(
            opacity: CurvedAnimation(parent: animation, curve: Curves.easeIn),
            child: child,
          ),
        );
      },
      child: child,
    );
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
        initialData: _conversationCache['all'],
        builder: (context, conversationSnapshot) {
          final conversations = conversationSnapshot.data ?? const [];
          _conversationCache['all'] = conversations;
          ImConversation? selected;
          for (final conversation in conversations) {
            if (conversation.id == _selectedConversationId) {
              selected = conversation;
              break;
            }
          }

          if (_selectedConversationId == null || selected == null) {
            final pending = _pendingConversation;
            if (pending != null && pending.id == _selectedConversationId) {
              selected = pending;
            } else {
              return _buildEmptyChatPlaceholder();
            }
          }
          // Promote to non-null for use inside nested closures.
          final conv = selected;

          // Determine slide direction and distance from the conversation
          // list order so the panel slides in from the right direction.
          final prevIdx = _previousConversationId != null
              ? conversations.indexWhere(
                  (c) => c.id == _previousConversationId)
              : -1;
          final curIdx = conversations.indexWhere(
              (c) => c.id == conv.id);
          final rawDelta = curIdx >= 0 && prevIdx >= 0 ? prevIdx - curIdx : 0;
          final delta = rawDelta.clamp(-4, 4);

          return StreamBuilder<List<ImMessage>>(
            stream: repository.watchMessages(conv.id),
            initialData: _messageCache[conv.id],
            builder: (context, messageSnapshot) {
              final messages = messageSnapshot.data ?? const [];
              _messageCache[conv.id] = messages;
              final animDuration = ImAnimationConfig.instance.chatPanelSlide
                  ? const Duration(milliseconds: 350)
                  : Duration.zero;
              return AnimatedSwitcher(
                duration: animDuration,
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                transitionBuilder: (child, animation) {
                  final begin = Offset(0, delta * 0.3);
                  final offset = Tween<Offset>(
                    begin: begin,
                    end: Offset.zero,
                  ).animate(CurvedAnimation(
                    parent: animation,
                    curve: Curves.easeOutCubic,
                  ));
                  return FadeTransition(
                    opacity: animation,
                    child: SlideTransition(
                      position: offset,
                      child: child,
                    ),
                  );
                },
                child: ImChatRoomView(
                  key: ValueKey(conv.id),
                  conversation: conv,
                  messages: messages,
                  onBack: showBack ? _clearSelection : null,
                  resolveUserName: _resolveUserName,
                  resolveUserAvatar: _resolveUserAvatar,
                  resolveMessage: (id) => _findMessage(id, messages),
                  onSend: (text) async {
                    await ImScope.interactionsOf(context).onSendMessage(
                      conversation: conv,
                      text: text,
                    );
                    await repository.sendTextMessage(
                      conversationId: conv.id,
                      text: text,
                    );
                  },
                ),
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
