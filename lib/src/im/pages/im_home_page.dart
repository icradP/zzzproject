import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/routes/index.dart';
import '../../assets/app_assets.dart';
import '../../theme/zzz_colors.dart';
import '../../widgets/zzz_widgets.dart';
import '../data/im_animation_config.dart';
import '../data/im_backdrop_config.dart';
import '../data/im_push_manager.dart';
import '../data/im_repository.dart';
import '../im_scope.dart';
import '../models/im_models.dart';
import '../widgets/conversation_list_view.dart';
import '../widgets/contacts_panel.dart';
import '../widgets/im_chat_room_view.dart';
import '../widgets/im_conversation_avatar.dart';
import '../widgets/im_group_details_panel.dart';
import '../widgets/im_profile_card_panel.dart';
import 'im_settings_page.dart';

enum _MobileHomeSection { conversations, contacts, settings }

class ImHomePage extends StatefulWidget {
  const ImHomePage({this.initialConversationId, super.key});

  final String? initialConversationId;

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
  _MobileHomeSection _mobileSection = _MobileHomeSection.conversations;
  late final AnimationController _backgroundController;

  /// Cached snapshot data so switching conversations doesn't flash empty.
  final _conversationCache = <String, List<ImConversation>>{};
  final _messageCache = <String, List<ImMessage>>{};
  final _readMarksInFlight = <String>{};

  @override
  void initState() {
    super.initState();
    _selectedConversationId = widget.initialConversationId;
    _backgroundController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 30),
    )..repeat();
  }

  @override
  void didUpdateWidget(covariant ImHomePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialConversationId != oldWidget.initialConversationId) {
      setState(() => _selectedConversationId = widget.initialConversationId);
    }
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
    _requestMarkRead(ImScope.repositoryOf(context), conversation.id);
  }

  void _requestMarkRead(ImRepository repository, String conversationId) {
    if (!_readMarksInFlight.add(conversationId)) return;
    unawaited(
      repository
          .markConversationRead(conversationId)
          .catchError((_) {})
          .whenComplete(() => _readMarksInFlight.remove(conversationId)),
    );
  }

  void _clearSelection() {
    setState(() {
      _dragOffset = 0.0;
      _selectedConversationId = null;
      _previousConversationId = null;
    });
    ImScope.interactionsOf(context).onConversationClosed();
    if (widget.initialConversationId != null) {
      context.go(AppRoutes.home);
    }
  }

  void _openDemoPage() {
    context.push(AppRoutes.demo);
  }

  void _onNewChatPressed(bool isWide) {
    if (isWide) {
      setState(() => _showContacts = true);
    } else {
      setState(() => _mobileSection = _MobileHomeSection.contacts);
    }
  }

  void _closeContacts() {
    setState(() => _showContacts = false);
  }

  void _onContactsSelection(ImConversation conversation) {
    setState(() {
      _showContacts = false;
      _mobileSection = _MobileHomeSection.conversations;
    });
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
    return user?.avatarImage(AppAssets.fallbackAvatarForId(userId)) ??
        AssetImage(AppAssets.fallbackAvatarForId(userId));
  }

  Future<void> _openGroupManagement(
    ImRepository repository,
    ImConversation conversation,
  ) async {
    await showZzzModalPanel<void>(
      context: context,
      builder:
          (_) => ImGroupDetailsPanel(
            conversation: conversation,
            repository: repository,
            onLeft: _clearSelection,
          ),
    );
  }

  Future<void> _openMemberProfile(
    ImRepository repository,
    ImConversation conversation,
    String userId,
  ) => showZzzModalPanel<void>(
    context: context,
    builder:
        (_) => ImProfileCardPanel(
          userId: userId,
          groupId: conversation.id,
          repository: repository,
        ),
  );

  Future<void> _sendComposedMessage(
    ImRepository repository,
    ImConversation conversation,
    ImComposedText message, {
    String? replyToMessageId,
  }) async {
    final text = message.plainText;
    await ImScope.interactionsOf(
      context,
    ).onSendMessage(conversation: conversation, text: text);
    final link = message.hasMentions ? null : ImLinkShare.tryParse(text);
    if (link != null && replyToMessageId == null) {
      await repository.sendLinkMessage(
        conversationId: conversation.id,
        link: link,
      );
      return;
    }
    await repository.sendComposedTextMessage(
      conversationId: conversation.id,
      message: message,
      replyToMessageId: replyToMessageId,
    );
  }

  Future<void> _forwardMessages(
    ImRepository repository,
    List<ImMessage> messages,
  ) async {
    if (messages.isEmpty) return;
    final sourceId = messages.first.sourceId;
    final conversations = (_conversationCache['all'] ??
            const <ImConversation>[])
        .where(
          (conversation) =>
              sourceId == null || conversation.sourceId == sourceId,
        )
        .toList(growable: false);
    final target = await showZzzModalPanel<ImConversation>(
      context: context,
      builder:
          (dialogContext) => ZzzModalPanel(
            key: const ValueKey('forward-target-panel'),
            title: 'Forward to',
            subtitle:
                messages.length == 1
                    ? '1 message selected'
                    : '${messages.length} messages selected',
            icon: Icons.forward_rounded,
            maxWidth: 500,
            maxHeight: 620,
            child:
                conversations.isEmpty
                    ? const Padding(
                      padding: EdgeInsets.all(28),
                      child: Text(
                        'No conversation is available for this source.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.white54),
                      ),
                    )
                    : ListView.separated(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      itemCount: conversations.length,
                      separatorBuilder:
                          (_, __) =>
                              const Divider(height: 1, color: Colors.white10),
                      itemBuilder: (context, index) {
                        final conversation = conversations[index];
                        return Material(
                          color: Colors.transparent,
                          child: ListTile(
                            key: ValueKey('forward-target-${conversation.id}'),
                            leading: ImConversationAvatar(
                              conversation: conversation,
                              size: 40,
                            ),
                            title: Text(
                              conversation.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              conversation.isGroup ? 'Group' : 'Direct message',
                              style: const TextStyle(color: Colors.white54),
                            ),
                            trailing: const Icon(Icons.chevron_right_rounded),
                            onTap:
                                () => Navigator.of(
                                  dialogContext,
                                ).pop(conversation),
                          ),
                        );
                      },
                    ),
          ),
    );
    if (!mounted || target == null) return;
    await repository.forwardMessages(
      conversationId: target.id,
      messages: messages,
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          messages.length == 1
              ? 'Message forwarded to ${target.title}.'
              : '${messages.length} messages forwarded to ${target.title}.',
        ),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final repository = ImScope.repositoryOf(context);
    final isCompact = MediaQuery.sizeOf(context).width < 860;

    return Scaffold(
      bottomNavigationBar:
          isCompact && _selectedConversationId == null
              ? _buildMobileNavigationBar()
              : null,
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
                if (!isWide && _selectedConversationId == null) {
                  return Padding(
                    padding: const EdgeInsets.all(16),
                    child: _buildCompactInboxLayout(repository),
                  );
                }
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
                      if (!(!isWide && _selectedConversationId != null)) ...[
                        _buildPushNotificationBanner(),
                      ],
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
    final mobileTitle = switch (_mobileSection) {
      _MobileHomeSection.conversations => 'Messages',
      _MobileHomeSection.contacts => 'Contacts',
      _MobileHomeSection.settings => 'Settings',
    };
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
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isWide ? 'Messages' : mobileTitle,
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
          if (!(isWide && _showContacts) &&
              (isWide || _mobileSection == _MobileHomeSection.conversations))
            IconButton(
              tooltip: 'New chat',
              onPressed: () => _onNewChatPressed(isWide),
              icon: Image.asset(
                AppAssets.iconAgentProfile,
                width: 24,
                height: 24,
                color: ZzzColors.yellow,
              ),
            ),
          IconButton(
            tooltip: 'Profile',
            onPressed: () => context.push(AppRoutes.profile),
            icon: const Icon(
              Icons.account_circle_outlined,
              color: Colors.white70,
            ),
          ),
          if (isWide)
            IconButton(
              tooltip: 'Settings',
              onPressed: () => context.push(AppRoutes.settings),
              icon: const Icon(Icons.settings_outlined, color: Colors.white54),
            ),
        ],
      ),
    );
  }

  Widget _buildPushNotificationBanner() {
    final manager = ImScope.pushManagerOf(context);
    return ListenableBuilder(
      listenable: manager,
      builder: (context, _) {
        if (!manager.isSupported ||
            manager.permission == ImPushPermission.enabled) {
          return const SizedBox.shrink();
        }

        final denied = manager.permission == ImPushPermission.denied;
        final subtitle =
            manager.error ??
            (denied
                ? 'Notifications are blocked in this device\'s browser settings.'
                : 'Receive new messages when ZZZ IM is in the background.');
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.9),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color:
                    denied
                        ? Colors.redAccent.withValues(alpha: 0.55)
                        : ZzzColors.yellow.withValues(alpha: 0.55),
              ),
            ),
            child: Row(
              children: [
                Icon(
                  denied
                      ? Icons.notifications_off_outlined
                      : Icons.notifications_outlined,
                  color: denied ? Colors.redAccent : ZzzColors.yellow,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Message notifications',
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white60,
                          fontSize: 12,
                          height: 1.25,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                if (manager.isBusy)
                  const SizedBox.square(
                    dimension: 24,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  FilledButton.icon(
                    onPressed: denied ? null : () => _enablePush(manager),
                    icon: const Icon(Icons.notifications_active_outlined),
                    label: Text(denied ? 'Blocked' : 'Turn on'),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _enablePush(ImPushManager manager) async {
    await manager.enable();
    if (!mounted || manager.permission != ImPushPermission.enabled) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Notifications enabled on this device.')),
    );
  }

  Widget _buildCompactInboxLayout(ImRepository repository) {
    return Column(
      children: [
        _buildAppHeader(isWide: false),
        const SizedBox(height: 12),
        if (_mobileSection == _MobileHomeSection.conversations)
          _buildPushNotificationBanner(),
        Expanded(child: _buildMobileSection(repository)),
      ],
    );
  }

  Widget _buildMobileSection(ImRepository repository) {
    return switch (_mobileSection) {
      _MobileHomeSection.conversations => _buildCompactLayout(repository),
      _MobileHomeSection.contacts => ZzzPanel(
        key: const ValueKey('mobile-contacts'),
        animateEntrance: true,
        background: const DecorationImage(
          image: AssetImage(AppAssets.bgChatWithPatternDark2),
          repeat: ImageRepeat.repeat,
          opacity: 0.1,
        ),
        child: ContactsPanel(onConversationSelected: _onContactsSelection),
      ),
      _MobileHomeSection.settings => const ImSettingsPage(embedded: true),
    };
  }

  Widget _buildMobileNavigationBar() {
    final selectedIndex = switch (_mobileSection) {
      _MobileHomeSection.conversations => 0,
      _MobileHomeSection.contacts => 1,
      _MobileHomeSection.settings => 2,
    };
    return NavigationBar(
      key: const ValueKey('mobile-bottom-navigation'),
      selectedIndex: selectedIndex,
      onDestinationSelected: (index) {
        final section = switch (index) {
          0 => _MobileHomeSection.conversations,
          1 => _MobileHomeSection.contacts,
          _ => _MobileHomeSection.settings,
        };
        if (section == _mobileSection) return;
        setState(() => _mobileSection = section);
      },
      destinations: const [
        NavigationDestination(
          icon: Icon(Icons.forum_outlined),
          selectedIcon: Icon(Icons.forum_rounded),
          label: 'Conversations',
        ),
        NavigationDestination(
          icon: Icon(Icons.people_outline_rounded),
          selectedIcon: Icon(Icons.people_rounded),
          label: 'Contacts',
        ),
        NavigationDestination(
          icon: Icon(Icons.settings_outlined),
          selectedIcon: Icon(Icons.settings_rounded),
          label: 'Settings',
        ),
      ],
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
            child:
                _showContacts
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
              _dragOffset = (_dragOffset + details.delta.dx).clamp(
                0.0,
                screenWidth,
              );
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
          child: _buildChatPanel(repository, showBack: true),
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
          ).animate(
            CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
          ),
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
              final unavailable = _selectedConversationId != null;
              return _buildEmptyChatPlaceholder(
                unavailable: unavailable,
                showBack: showBack && unavailable,
              );
            }
          }
          // Promote to non-null for use inside nested closures.
          final conv = selected;
          if (conv.unreadCount > 0) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted || _selectedConversationId != conv.id) return;
              _requestMarkRead(repository, conv.id);
            });
          }

          // Determine slide direction and distance from the conversation
          // list order so the panel slides in from the right direction.
          final prevIdx =
              _previousConversationId != null
                  ? conversations.indexWhere(
                    (c) => c.id == _previousConversationId,
                  )
                  : -1;
          final curIdx = conversations.indexWhere((c) => c.id == conv.id);
          final rawDelta = curIdx >= 0 && prevIdx >= 0 ? prevIdx - curIdx : 0;
          final delta = rawDelta.clamp(-4, 4);

          return StreamBuilder<List<ImMessage>>(
            stream: repository.watchMessages(conv.id),
            initialData: _messageCache[conv.id],
            builder: (context, messageSnapshot) {
              final messages = messageSnapshot.data ?? const [];
              _messageCache[conv.id] = messages;
              final animDuration =
                  ImAnimationConfig.instance.chatPanelSlide
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
                  ).animate(
                    CurvedAnimation(
                      parent: animation,
                      curve: Curves.easeOutCubic,
                    ),
                  );
                  return FadeTransition(
                    opacity: animation,
                    child: SlideTransition(position: offset, child: child),
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
                  onLoadOlder: () => repository.loadOlderMessages(conv.id),
                  onManageGroup:
                      conv.isGroup
                          ? () => _openGroupManagement(repository, conv)
                          : null,
                  onMemberTap:
                      conv.isGroup
                          ? (userId) =>
                              _openMemberProfile(repository, conv, userId)
                          : null,
                  onSend: (text) async {
                    await _sendComposedMessage(
                      repository,
                      conv,
                      ImComposedText.plain(text),
                    );
                  },
                  onSendComposed:
                      (message) =>
                          _sendComposedMessage(repository, conv, message),
                  onReply: (text, replyTo) async {
                    await _sendComposedMessage(
                      repository,
                      conv,
                      ImComposedText.plain(text),
                      replyToMessageId: replyTo.id,
                    );
                  },
                  onReplyComposed:
                      (message, replyTo) => _sendComposedMessage(
                        repository,
                        conv,
                        message,
                        replyToMessageId: replyTo.id,
                      ),
                  onSticker: (sticker) async {
                    await repository.sendStickerMessage(
                      conversationId: conv.id,
                      sticker: sticker,
                    );
                  },
                  onLocation: (location) async {
                    await repository.sendLocationMessage(
                      conversationId: conv.id,
                      location: location,
                    );
                  },
                  onForward:
                      (messages) => _forwardMessages(repository, messages),
                  onPoke: (targetUserId) async {
                    await repository.sendPoke(
                      conversationId: conv.id,
                      targetUserId: targetUserId,
                    );
                  },
                  onRecall: (message) async {
                    await repository.recallMessage(
                      conversationId: conv.id,
                      messageId: message.id,
                    );
                  },
                  onReact: (message, emojiId, remove) async {
                    await repository.reactToMessage(
                      conversationId: conv.id,
                      messageId: message.id,
                      emojiId: emojiId,
                      remove: remove,
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

  Widget _buildEmptyChatPlaceholder({
    bool unavailable = false,
    bool showBack = false,
  }) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Image.asset(AppAssets.stickerEllen, height: 140),
            const SizedBox(height: 16),
            Text(
              unavailable
                  ? 'Conversation unavailable'
                  : 'Select a conversation',
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Text(
              unavailable
                  ? 'This conversation may have been removed or is not available to this account.'
                  : 'Pick a chat from the inbox, or open the simulator demo to test the legacy ZZZ-Chat UI.',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white54, height: 1.45),
            ),
            const SizedBox(height: 18),
            if (showBack) ...[
              FilledButton.icon(
                onPressed: _clearSelection,
                icon: const Icon(Icons.inbox_rounded),
                label: const Text('Back to inbox'),
              ),
              const SizedBox(height: 10),
            ],
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
