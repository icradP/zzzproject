import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'src/chat/system_message_widgets.dart';
import 'src/models/chat_models.dart';
import 'src/theme/zzz_colors.dart';
import 'src/utils/iterable_extensions.dart';
import 'src/widgets/zzz_widgets.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ZZZ Chat',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        fontFamily: 'InpinHongmengti',
        colorScheme: ColorScheme.fromSeed(
          seedColor: ZzzColors.yellow,
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: Colors.black,
      ),
      home: const ChatHomePage(),
    );
  }
}

class ChatHomePage extends StatefulWidget {
  const ChatHomePage({super.key});

  @override
  State<ChatHomePage> createState() => _ChatHomePageState();
}

class _ChatHomePageState extends State<ChatHomePage>
    with SingleTickerProviderStateMixin {
  final _messageController = TextEditingController();
  final _chatExportKey = GlobalKey();

  List<ChatCharacter> _characters = [];
  List<ChatMessage> _messages = [];
  List<ChatIdentity> _groupMembers = [];

  ChatIdentity _leftIdentity = const ChatIdentity(
    name: 'Untitled',
    assetPath: 'assets/characters/Wise.png',
  );
  ChatIdentity _rightIdentity = const ChatIdentity(
    name: 'Untitled',
    assetPath: 'assets/characters/Belle.png',
  );

  ChatSide _selectedSide = ChatSide.left;
  bool _isGroupChat = false;
  int _activeGroupIndex = -1;
  bool _isChangingColorsEnabled = true;
  bool _isAnimatedBackgroundEnabled = true;
  bool _wideImageExportEnabled = false;

  late final AnimationController _backgroundController;
  bool _showHowToUse = false;
  bool _isExportingImage = false;
  bool _isLoadingCharacters = true;

  @override
  void initState() {
    super.initState();
    _backgroundController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 30),
    )..repeat();
    _loadCharacters();
    _loadSettings();
  }

  @override
  void dispose() {
    _backgroundController.dispose();
    _messageController.dispose();
    super.dispose();
  }

  Future<void> _loadCharacters() async {
    try {
      final raw = await rootBundle.loadString('assets/data/characters.json');
      final decoded = jsonDecode(raw) as List<dynamic>;
      setState(() {
        _characters =
            decoded
                .map(
                  (item) =>
                      ChatCharacter.fromJson(item as Map<String, dynamic>),
                )
                .toList();
        _isLoadingCharacters = false;
      });
    } catch (_) {
      setState(() => _isLoadingCharacters = false);
      _showSnack('角色数据加载失败。');
    }
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _isChangingColorsEnabled =
          prefs.getBool('isChangingColorsEnabled') ?? true;
      _isAnimatedBackgroundEnabled =
          prefs.getBool('isAnimatedBackgroundEnabled') ?? true;
      _wideImageExportEnabled =
          prefs.getBool('wideImageExportEnabled') ?? false;
    });
  }

  Future<void> _saveBoolSetting(String key, bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(key, value);
  }

  ChatIdentity get _activeDmIdentity =>
      _selectedSide == ChatSide.left ? _leftIdentity : _rightIdentity;

  ChatIdentity get _activeGroupIdentity {
    if (_activeGroupIndex >= 0 && _activeGroupIndex < _groupMembers.length) {
      return _groupMembers[_activeGroupIndex];
    }
    return _rightIdentity;
  }

  ChatSide get _activeGroupSide =>
      _activeGroupIndex == -1 ? ChatSide.right : ChatSide.left;

  String get _leftName => _leftIdentity.name;

  String get _rightName => _rightIdentity.name;

  ImageProvider _imageForIdentity(ChatIdentity identity, String fallbackAsset) {
    return identity.imageBytes != null
        ? MemoryImage(identity.imageBytes!)
        : AssetImage(identity.assetPath ?? fallbackAsset);
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }

  Future<void> _openCharacterPicker(ChatSide side) async {
    if (_isLoadingCharacters) {
      _showSnack('角色库还在加载。');
      return;
    }
    final character = await showDialog<ChatCharacter>(
      context: context,
      builder: (context) {
        return CharacterPickerDialog(
          characters: _characters,
          sideLabel: side == ChatSide.left ? 'left' : 'right',
        );
      },
    );
    if (character == null) return;

    setState(() {
      final identity = ChatIdentity.fromCharacter(character);
      if (side == ChatSide.left && _isGroupChat) {
        _groupMembers = [..._groupMembers, identity];
        if (_activeGroupIndex == -1 && _groupMembers.length == 1) {
          _activeGroupIndex = 0;
        }
      } else if (side == ChatSide.left) {
        _leftIdentity = identity;
      } else {
        _rightIdentity = identity;
      }
    });
  }

  Future<void> _pickCustomAvatar(ChatSide side) async {
    final bytes = await _pickImageBytes();
    if (bytes == null) return;

    setState(() {
      if (side == ChatSide.left) {
        _leftIdentity = _leftIdentity.copyWith(imageBytes: bytes);
      } else {
        _rightIdentity = _rightIdentity.copyWith(imageBytes: bytes);
      }
    });
  }

  Future<Uint8List?> _pickImageBytes() async {
    final result = await FilePicker.pickFiles(
      type: FileType.image,
      withData: true,
    );
    if (result == null || result.files.isEmpty) return null;
    final bytes = result.files.single.bytes;
    if (bytes == null) {
      _showSnack('没有读取到图片内容。');
    }
    return bytes;
  }

  void _addTextMessage() {
    final text = _messageController.text.trim();
    if (text.isEmpty) return;
    final message = _buildOutgoingMessage(MessageKind.text, text: text);
    if (message == null) return;
    setState(() {
      _messages = [..._messages, message];
      _messageController.clear();
    });
  }

  Future<void> _addImageMessage() async {
    final bytes = await _pickImageBytes();
    if (bytes == null) return;
    final message = _buildOutgoingMessage(
      MessageKind.image,
      text: '[ Image ]',
      imageBytes: bytes,
    );
    if (message == null) return;
    setState(() => _messages = [..._messages, message]);
  }

  ChatMessage? _buildOutgoingMessage(
    MessageKind kind, {
    required String text,
    Uint8List? imageBytes,
  }) {
    if (_isGroupChat && _activeGroupIndex >= 0 && _groupMembers.isEmpty) {
      _showSnack('请先添加群聊成员。');
      return null;
    }

    final side = _isGroupChat ? _activeGroupSide : _selectedSide;
    final sender = _isGroupChat ? _activeGroupIdentity : _activeDmIdentity;

    return ChatMessage(
      side: side,
      kind: kind,
      text: text,
      sender: sender,
      imageBytes: imageBytes,
    );
  }

  Future<void> _openSystemMessageDialog() async {
    final message = await showDialog<ChatMessage>(
      context: context,
      builder: (context) => const SystemMessageDialog(),
    );
    if (message == null) return;
    setState(() => _messages = [..._messages, message]);
  }

  Future<void> _editMessage(int index) async {
    final message = _messages[index];
    if (message.kind != MessageKind.text) return;
    final edited = await showDialog<String>(
      context: context,
      builder:
          (context) => _TextInputDialog(
            title: 'Edit Message',
            initialText: message.text,
            saveLabel: 'Save',
            minLines: 1,
            maxLines: 4,
          ),
    );
    if (edited == null || edited.trim().isEmpty) return;
    setState(() {
      final next = [..._messages];
      next[index] = message.copyWith(text: edited.trim());
      _messages = next;
    });
  }

  void _deleteMessage(int index) {
    setState(() {
      _messages = [
        for (var i = 0; i < _messages.length; i++)
          if (i != index) _messages[i],
      ];
    });
  }

  Future<void> _renameIdentity(ChatSide side) async {
    final current = side == ChatSide.left ? _leftIdentity : _rightIdentity;
    final nextName = await showDialog<String>(
      context: context,
      builder:
          (context) => _TextInputDialog(
            title: 'Rename Character',
            initialText: current.name,
            hintText: 'Enter character name',
            saveLabel: 'Rename',
          ),
    );
    if (nextName == null || nextName.trim().isEmpty) return;
    setState(() {
      if (side == ChatSide.left) {
        _leftIdentity = _leftIdentity.copyWith(name: nextName.trim());
      } else {
        _rightIdentity = _rightIdentity.copyWith(name: nextName.trim());
      }
    });
  }

  void _removeGroupMember(int index) {
    setState(() {
      _groupMembers = [
        for (var i = 0; i < _groupMembers.length; i++)
          if (i != index) _groupMembers[i],
      ];
      if (_groupMembers.isEmpty) {
        _activeGroupIndex = -1;
      } else if (_activeGroupIndex >= _groupMembers.length) {
        _activeGroupIndex = _groupMembers.length - 1;
      }
    });
  }

  Future<void> _exportChatAsText() async {
    final content = _messages
        .map((message) {
          if (message.side == ChatSide.system) {
            return 'System: ${message.text}';
          }
          final sender =
              message.sender?.name ??
              (message.side == ChatSide.left ? _leftName : _rightName);
          final body =
              message.kind == MessageKind.image ? '[ Image ]' : message.text;
          return '$sender: $body';
        })
        .join('\n');
    await _shareBytes(
      utf8.encode(content),
      _exportFileName('txt'),
      'text/plain',
      successMessage: 'TXT 导出已打开分享/保存面板。',
    );
  }

  Future<void> _exportChatAsJson() async {
    final payload = {
      'leftName': _leftName,
      'rightName': _rightName,
      'isGroupChat': _isGroupChat,
      'messages': _messages.map((message) => message.toJson()).toList(),
    };
    final content = const JsonEncoder.withIndent('  ').convert(payload);
    await _shareBytes(
      utf8.encode(content),
      _exportFileName('json'),
      'application/json',
      successMessage: 'JSON 导出已打开分享/保存面板。',
    );
  }

  Future<void> _exportChatAsImage() async {
    final boundary =
        _chatExportKey.currentContext?.findRenderObject()
            as RenderRepaintBoundary?;
    if (boundary == null) {
      _showSnack('没有找到聊天区域。');
      return;
    }

    setState(() => _isExportingImage = true);
    try {
      await Future<void>.delayed(const Duration(milliseconds: 80));
      final image = await boundary.toImage(
        pixelRatio: _wideImageExportEnabled ? 3 : 2,
      );
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) {
        _showSnack('图片导出失败。');
        return;
      }
      await _shareBytes(
        byteData.buffer.asUint8List(),
        _exportFileName('png'),
        'image/png',
        successMessage: '图片导出已打开分享/保存面板。',
      );
    } finally {
      if (mounted) setState(() => _isExportingImage = false);
    }
  }

  Future<void> _shareBytes(
    List<int> bytes,
    String fileName,
    String mimeType, {
    required String successMessage,
  }) async {
    try {
      final result = await SharePlus.instance.share(
        ShareParams(
          title: 'ZZZ Chat Export',
          files: [
            XFile.fromData(
              Uint8List.fromList(bytes),
              name: fileName,
              mimeType: mimeType,
            ),
          ],
          fileNameOverrides: [fileName],
          downloadFallbackEnabled: true,
        ),
      );
      if (result.status != ShareResultStatus.dismissed) {
        _showSnack(successMessage);
      }
    } catch (_) {
      if (mimeType.startsWith('text') || mimeType.contains('json')) {
        await Clipboard.setData(
          ClipboardData(text: utf8.decode(bytes, allowMalformed: true)),
        );
        _showSnack('当前平台分享不可用，内容已复制到剪贴板。');
      } else {
        _showSnack('当前平台暂时无法分享图片。');
      }
    }
  }

  String _exportFileName(String extension) {
    final date = DateTime.now().toIso8601String().replaceAll(':', '-');
    return 'ZZZChat $_leftName - $_rightName - $date.$extension';
  }

  String _lastMessageFor(ChatSide side) {
    final last =
        _messages.where((message) {
          return message.side == side && message.kind == MessageKind.text;
        }).lastOrNull;
    final text = last?.text ?? 'Click to switch';
    return text.length > 18 ? '${text.substring(0, 18)}...' : text;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        clipBehavior: Clip.none,
        children: [
          ZzzBackground(
            controller: _backgroundController,
            animated: _isAnimatedBackgroundEnabled,
          ),
          SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final usesSplitLayout = constraints.maxWidth >= 720;
                final profilePanelWidth =
                    constraints.maxWidth >= 980 ? 330.0 : 300.0;
                return Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      _buildHeader(),
                      const SizedBox(height: 12),
                      Expanded(
                        child:
                            usesSplitLayout
                                ? Row(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    SizedBox(
                                      width: profilePanelWidth,
                                      child: _buildProfilePanel(),
                                    ),
                                    const SizedBox(width: 14),
                                    Expanded(child: _buildChatPanel()),
                                  ],
                                )
                                : SingleChildScrollView(
                                  child: Column(
                                    children: [
                                      _buildProfilePanel(),
                                      const SizedBox(height: 14),
                                      SizedBox(
                                        height: math.max(
                                          640,
                                          constraints.maxHeight * 0.76,
                                        ),
                                        child: _buildChatPanel(),
                                      ),
                                    ],
                                  ),
                                ),
                      ),
                      const SizedBox(height: 12),
                      _buildFooter(),
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

  Widget _buildHeader() {
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
            child: const Icon(Icons.sms_rounded, color: Colors.black),
          ),
          const SizedBox(width: 12),
          const Expanded(
            child: Text(
              'Knock Knock',
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800),
            ),
          ),
          Tooltip(
            message: _isGroupChat ? 'Group Chat' : 'Direct Message',
            child: Icon(
              _isGroupChat ? Icons.groups_rounded : Icons.person_rounded,
              color: ZzzColors.yellow,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildProfilePanel() {
    final animated = _isChangingColorsEnabled;

    return ZzzPanel(
      animateEntrance: animated,
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildModeSwitch(),
            ZzzExpandableSection(
              title: 'Choose',
              subtitle: 'Messaging participants',
              animated: animated,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'Messaging',
                    style: TextStyle(color: Colors.white54, fontSize: 16),
                  ),
                  const SizedBox(height: 10),
                  ZzzAnimatedSwap(
                    value: _isGroupChat,
                    animated: animated,
                    builder:
                        (_) =>
                            _isGroupChat
                                ? _buildGroupMemberPicker()
                                : _buildDmLeftPicker(),
                  ),
                  const SizedBox(height: 18),
                  const Text(
                    'as',
                    style: TextStyle(color: Colors.white54, fontSize: 16),
                  ),
                  const SizedBox(height: 10),
                  _buildRightPicker(),
                ],
              ),
            ),
            ZzzExpandableSection(
              title: 'Info',
              subtitle: 'Simulation summary',
              animated: animated,
              initiallyExpanded: false,
              child: ZzzAnimatedSwap(
                value:
                    '$_isGroupChat-${_messages.length}-${_groupMembers.length}',
                animated: animated,
                builder: (_) => _buildInfoBlock(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildModeSwitch() {
    return ZzzSegmentedControl<String>(
      value: _isGroupChat ? 'group' : 'dm',
      animated: _isChangingColorsEnabled,
      items: const [
        ZzzSegmentItem<String>(
          value: 'profiles',
          tooltip: 'Profiles',
          iconAsset: 'assets/icons/ZZZ_agent_profile_icon.png',
          enabled: false,
        ),
        ZzzSegmentItem<String>(
          value: 'dm',
          tooltip: 'DM',
          iconAsset: 'assets/icons/ZZZ_dm_icon.png',
        ),
        ZzzSegmentItem<String>(
          value: 'group',
          tooltip: 'Group Chat',
          iconAsset: 'assets/icons/ZZZ_group_chat_icon.png',
        ),
      ],
      onChanged: (value) {
        setState(() => _isGroupChat = value == 'group');
      },
    );
  }

  Widget _identityPill({
    required ChatIdentity identity,
    required String fallbackAsset,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return ZzzPillButton(
      title: identity.name,
      subtitle: subtitle,
      animated: _isChangingColorsEnabled,
      onPressed: onTap,
      leading: ZzzAvatar(
        image: _imageForIdentity(identity, fallbackAsset),
        size: 50,
      ),
    );
  }

  Widget _profileActions(ChatSide side) {
    return Column(
      children: [
        ZzzTextAction(
          icon: Icons.upload_rounded,
          label: 'Upload custom avatar',
          onTap: () => _pickCustomAvatar(side),
        ),
        ZzzTextAction(
          icon: Icons.edit_rounded,
          label: 'Rename character',
          onTap: () => _renameIdentity(side),
        ),
      ],
    );
  }

  Widget _buildDmLeftPicker() {
    return Column(
      children: [
        _identityPill(
          identity: _leftIdentity,
          fallbackAsset: 'assets/characters/Wise.png',
          subtitle: _lastMessageFor(ChatSide.left),
          onTap: () => _openCharacterPicker(ChatSide.left),
        ),
        const SizedBox(height: 8),
        _profileActions(ChatSide.left),
      ],
    );
  }

  Widget _buildGroupMemberPicker() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_groupMembers.isEmpty)
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.white10),
            ),
            child: const Text(
              'No profiles yet. Click + to add.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white54),
            ),
          )
        else
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              for (var i = 0; i < _groupMembers.length; i++)
                ZzzSelectableAvatar(
                  image: _imageForIdentity(
                    _groupMembers[i],
                    'assets/characters/Wise.png',
                  ),
                  label: _groupMembers[i].name,
                  selected: _activeGroupIndex == i,
                  onSelect: () => setState(() => _activeGroupIndex = i),
                  onRemove: () => _removeGroupMember(i),
                ),
            ],
          ),
        const SizedBox(height: 12),
        FilledButton.icon(
          style: _yellowButtonStyle(),
          onPressed: () => _openCharacterPicker(ChatSide.left),
          icon: const Icon(Icons.add_rounded),
          label: const Text('Add character'),
        ),
      ],
    );
  }

  Widget _buildRightPicker() {
    return Column(
      children: [
        _identityPill(
          identity: _rightIdentity,
          fallbackAsset: 'assets/characters/Belle.png',
          subtitle: _lastMessageFor(ChatSide.right),
          onTap: () => _openCharacterPicker(ChatSide.right),
        ),
        const SizedBox(height: 8),
        _profileActions(ChatSide.right),
      ],
    );
  }

  Widget _buildInfoBlock() {
    final groupNames = _groupMembers.map((profile) => profile.name).join(', ');
    return DefaultTextStyle(
      style: const TextStyle(color: Colors.white38, height: 1.45),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text.rich(
            TextSpan(
              children: [
                const TextSpan(text: 'You are simulating a '),
                TextSpan(
                  text: _isGroupChat ? 'Group Chat' : 'DM',
                  style: const TextStyle(color: ZzzColors.yellow),
                ),
                const TextSpan(text: ' where '),
                TextSpan(
                  text: _rightName,
                  style: const TextStyle(color: ZzzColors.yellow),
                ),
                TextSpan(
                  text:
                      _isGroupChat
                          ? ' is messaging ${groupNames.isEmpty ? 'nobody yet' : groupNames}.'
                          : ' is messaging $_leftName.',
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Text(
            _isGroupChat
                ? 'Total messages: ${_messages.length}'
                : 'Total messages: ${_messages.length}, with ${_messages.where((m) => m.side == ChatSide.left).length} sent by $_leftName and ${_messages.where((m) => m.side == ChatSide.right).length} by $_rightName.',
          ),
        ],
      ),
    );
  }

  Widget _buildChatPanel() {
    return RepaintBoundary(
      key: _chatExportKey,
      child: ZzzPanel(
        animateEntrance: _isChangingColorsEnabled,
        background: const DecorationImage(
          image: AssetImage(
            'assets/BG_background_ZZZChat_with_pattern_dark-2.png',
          ),
          repeat: ImageRepeat.repeat,
          opacity: 0.12,
        ),
        child: Column(
          children: [
            _buildChatTitle(),
            const Divider(height: 26, thickness: 2, color: Colors.white12),
            Expanded(child: _buildMessages()),
            if (!_isExportingImage) ...[
              const SizedBox(height: 12),
              _buildSenderStatus(),
              const SizedBox(height: 10),
              _buildMessageComposer(),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildChatTitle() {
    final title =
        _isGroupChat
            ? '${_groupMembers.map((profile) => profile.name).join(', ')}${_groupMembers.isEmpty ? '' : ', '}and you - Group Chat'
            : _leftName;
    return Row(
      children: [
        const Icon(Icons.chat_bubble_rounded, color: Colors.white54),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            title.isEmpty ? 'Group Chat' : title,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }

  Widget _buildMessages() {
    if (_messages.isEmpty) {
      return Center(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'No messages yet.',
                style: TextStyle(color: Colors.white54, fontSize: 20),
              ),
              const SizedBox(height: 8),
              const Text(
                'Start a conversation!',
                style: TextStyle(color: Colors.white54, fontSize: 24),
              ),
              const SizedBox(height: 26),
              if (_showHowToUse)
                const _HowToUse()
              else
                Image.asset(
                  'assets/media/EllenSticker01.png',
                  height: 150,
                  fit: BoxFit.contain,
                ),
              TextButton(
                onPressed: () => setState(() => _showHowToUse = !_showHowToUse),
                child: Text(
                  _showHowToUse
                      ? '▼ Okay, I got it!'
                      : 'So, how do I use it? ▲',
                ),
              ),
              const SizedBox(height: 18),
              Text(
                _emptyStateWish(),
                style: const TextStyle(color: Colors.white70),
              ),
            ],
          ),
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.only(top: 8, bottom: 8),
      itemCount: _messages.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (context, index) => _buildMessageRow(index),
    );
  }

  String _emptyStateWish() {
    if (_leftName == 'Nicole Demara' || _rightName == 'Nicole Demara') {
      return 'May the skies rain dennies today.';
    }
    if (_leftName == 'Anby Demara' || _rightName == 'Anby Demara') {
      return 'Have a borgar!';
    }
    if (_leftName == 'Fairy' || _rightName == 'Fairy') {
      return 'Enjoy a high electricity bill!';
    }
    if (_leftName == 'Grace Howard' || _rightName == 'Grace Howard') {
      return 'Have fun with your machines!';
    }
    return 'Have fun!';
  }

  Widget _buildMessageRow(int index) {
    final message = _messages[index];
    if (message.side == ChatSide.system) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Flexible(child: ZzzSystemMessageView(message: message)),
          if (!_isExportingImage)
            _HoverActionHotspot(
              child: IconButton(
                tooltip: 'Delete',
                onPressed: () => _deleteMessage(index),
                icon: const Icon(Icons.delete_rounded, color: ZzzColors.red),
              ),
            ),
        ],
      );
    }

    final isLeft = message.side == ChatSide.left;
    final sender = message.sender ?? (isLeft ? _leftIdentity : _rightIdentity);
    final avatar = ZzzAvatar(
      image: _imageForIdentity(
        sender,
        isLeft ? 'assets/characters/Wise.png' : 'assets/characters/Belle.png',
      ),
      size: 42,
    );

    final bubble = Flexible(
      child: Column(
        crossAxisAlignment:
            isLeft ? CrossAxisAlignment.start : CrossAxisAlignment.end,
        children: [
          if (!_isExportingImage)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                sender.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.48),
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          GestureDetector(
            onTap:
                message.kind == MessageKind.text
                    ? () => _editMessage(index)
                    : null,
            child: Tooltip(
              message: message.kind == MessageKind.text ? 'Tap to edit' : '',
              child: _buildMessageBubble(
                message: message,
                isLeft: isLeft,
                onDelete: () => _deleteMessage(index),
              ),
            ),
          ),
        ],
      ),
    );

    return Row(
      mainAxisAlignment:
          isLeft ? MainAxisAlignment.start : MainAxisAlignment.end,
      crossAxisAlignment: CrossAxisAlignment.start,
      children:
          isLeft
              ? [avatar, const SizedBox(width: 10), bubble]
              : [bubble, const SizedBox(width: 10), avatar],
    );
  }

  Widget _buildMessageBubble({
    required ChatMessage message,
    required bool isLeft,
    required VoidCallback onDelete,
  }) {
    final radius = BorderRadius.circular(
      message.kind == MessageKind.text ? 18 : 12,
    );
    final contentMaxWidth = _isExportingImage ? 560.0 : 518.0;
    final content =
        message.kind == MessageKind.image
            ? ConstrainedBox(
              constraints: BoxConstraints(maxWidth: contentMaxWidth),
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.memory(
                    message.imageBytes!,
                    fit: BoxFit.contain,
                    height: 240,
                  ),
                ),
              ),
            )
            : ConstrainedBox(
              constraints: BoxConstraints(maxWidth: contentMaxWidth),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  message.text,
                  textAlign:
                      message.text.length < 3
                          ? TextAlign.center
                          : TextAlign.left,
                  style: TextStyle(
                    color: isLeft ? Colors.black : Colors.white,
                    fontSize: 16,
                  ),
                ),
              ),
            );

    return Container(
      constraints: const BoxConstraints(maxWidth: 560),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: isLeft ? Colors.grey.shade200 : ZzzColors.blue,
        borderRadius: radius,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.18),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child:
          _isExportingImage
              ? content
              : _ExpandingBubbleAction(
                actionOnRight: isLeft,
                tint:
                    isLeft
                        ? Colors.black.withValues(alpha: 0.07)
                        : Colors.white.withValues(alpha: 0.13),
                action: IconButton(
                  tooltip: 'Delete',
                  onPressed: onDelete,
                  style: IconButton.styleFrom(
                    minimumSize: const Size.square(34),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    padding: EdgeInsets.zero,
                  ),
                  icon: Image.asset(
                    'assets/icons/ZZZ_trash_icon.png',
                    width: 21,
                  ),
                ),
                child: content,
              ),
    );
  }

  Widget _buildSenderStatus() {
    final isLeft = _selectedSide == ChatSide.left;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: (_isGroupChat
                ? Colors.grey
                : isLeft
                ? Colors.grey
                : ZzzColors.blue)
            .withValues(alpha: 0.75),
        borderRadius: BorderRadius.circular(16),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 430;
          final status = _buildSenderStatusText(isLeft);
          final actions = _buildSenderActions(compact: compact);

          if (compact) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [status, const SizedBox(height: 8), actions],
            );
          }

          return Row(
            children: [
              Expanded(child: status),
              const SizedBox(width: 8),
              actions,
            ],
          );
        },
      ),
    );
  }

  Widget _buildSenderStatusText(bool isLeft) {
    if (_isGroupChat) return _buildGroupSenderDropdown();
    return Text(
      'Currently sending message as ${isLeft ? _leftName : _rightName}',
      overflow: TextOverflow.ellipsis,
      style: TextStyle(color: isLeft ? Colors.black87 : Colors.white),
    );
  }

  Widget _buildSenderActions({required bool compact}) {
    final buttons = [
      if (!_isGroupChat)
        FilledButton.icon(
          onPressed: () {
            setState(() {
              _selectedSide =
                  _selectedSide == ChatSide.left
                      ? ChatSide.right
                      : ChatSide.left;
            });
          },
          style: _senderActionStyle(),
          icon: const Icon(Icons.swap_horiz_rounded),
          label: const Text('Switch'),
        ),
      FilledButton.icon(
        onPressed: _openSystemMessageDialog,
        style: _senderActionStyle(),
        icon: const Icon(Icons.add_comment_rounded),
        label: const Text('System'),
      ),
    ];

    if (compact) {
      return Row(
        children: [
          for (var i = 0; i < buttons.length; i++) ...[
            if (i > 0) const SizedBox(width: 8),
            Expanded(child: buttons[i]),
          ],
        ],
      );
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < buttons.length; i++) ...[
          if (i > 0) const SizedBox(width: 8),
          buttons[i],
        ],
      ],
    );
  }

  ButtonStyle _senderActionStyle() {
    return FilledButton.styleFrom(
      backgroundColor: Colors.black,
      foregroundColor: ZzzColors.yellow,
      side: const BorderSide(color: ZzzColors.yellow, width: 2),
      visualDensity: VisualDensity.compact,
    );
  }

  Widget _buildGroupSenderDropdown() {
    final value = _activeGroupIndex == -1 ? 'right' : 'left:$_activeGroupIndex';
    return ZzzSelect<String>(
      value: value,
      labelText: 'Sending as',
      items: [
        for (var i = 0; i < _groupMembers.length; i++)
          ZzzSelectItem(value: 'left:$i', label: _groupMembers[i].name),
        ZzzSelectItem(value: 'right', label: _rightName),
      ],
      onChanged: (value) {
        setState(() {
          _activeGroupIndex =
              value == 'right' ? -1 : int.parse(value.split(':').last);
        });
      },
    );
  }

  Widget _buildMessageComposer() {
    return Row(
      children: [
        Expanded(
          child: ZzzTextInput(
            controller: _messageController,
            minLines: 1,
            maxLines: 3,
            textInputAction: TextInputAction.send,
            hintText: 'Type a message',
            onSubmitted: (_) => _addTextMessage(),
          ),
        ),
        const SizedBox(width: 8),
        FilledButton(
          onPressed: _addTextMessage,
          style: FilledButton.styleFrom(
            backgroundColor: ZzzColors.blue,
            foregroundColor: Colors.white,
            minimumSize: const Size(64, 52),
          ),
          child: const Text('Send'),
        ),
        const SizedBox(width: 8),
        IconButton.filled(
          tooltip: 'Send image',
          onPressed: _addImageMessage,
          style: IconButton.styleFrom(
            backgroundColor: Colors.white,
            foregroundColor: Colors.black,
            minimumSize: const Size(52, 52),
          ),
          icon: Image.asset('assets/icons/photo_icon.png', width: 24),
        ),
      ],
    );
  }

  Widget _buildFooter() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.86),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.white12),
      ),
      child: Wrap(
        alignment: WrapAlignment.center,
        spacing: 10,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          OutlinedButton.icon(
            onPressed: _openAboutDialog,
            icon: const Icon(Icons.info_outline_rounded),
            label: const Text('About'),
          ),
          FilledButton.icon(
            onPressed: _exportChatAsImage,
            icon: const Icon(Icons.image_rounded),
            label: const Text('Export Image'),
          ),
          PopupMenuButton<String>(
            tooltip: 'Export options',
            onSelected: (value) {
              if (value == 'txt') _exportChatAsText();
              if (value == 'json') _exportChatAsJson();
            },
            itemBuilder:
                (context) => const [
                  PopupMenuItem(
                    value: 'txt',
                    child: Text('Export Chat as TXT'),
                  ),
                  PopupMenuItem(
                    value: 'json',
                    child: Text('Export Chat as JSON'),
                  ),
                ],
            child: const ZzzFooterButton(icon: Icons.expand_less_rounded),
          ),
          OutlinedButton.icon(
            onPressed: _openSettingsDialog,
            icon: const Icon(Icons.settings_rounded),
            label: const Text('Settings'),
          ),
        ],
      ),
    );
  }

  void _openSettingsDialog() {
    showDialog<void>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              backgroundColor: Colors.black,
              title: const Text('Settings'),
              content: SizedBox(
                width: 520,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ZzzExpandableSection(
                      title: 'Visual effects',
                      subtitle: 'Motion and accent animations',
                      animated: _isChangingColorsEnabled,
                      child: Column(
                        children: [
                          ZzzSwitchTile(
                            value: _isChangingColorsEnabled,
                            title: 'Flashing colors',
                            subtitle: 'ZZZ-like animated menu accents.',
                            animated: _isChangingColorsEnabled,
                            onChanged: (value) {
                              setState(() => _isChangingColorsEnabled = value);
                              setDialogState(() {});
                              _saveBoolSetting(
                                'isChangingColorsEnabled',
                                value,
                              );
                            },
                          ),
                          ZzzSwitchTile(
                            value: _isAnimatedBackgroundEnabled,
                            title: 'Animated background',
                            subtitle: 'Moving ZERO ZONE style backdrop.',
                            animated: _isChangingColorsEnabled,
                            onChanged: (value) {
                              setState(
                                () => _isAnimatedBackgroundEnabled = value,
                              );
                              setDialogState(() {});
                              _saveBoolSetting(
                                'isAnimatedBackgroundEnabled',
                                value,
                              );
                            },
                          ),
                        ],
                      ),
                    ),
                    ZzzExpandableSection(
                      title: 'Export',
                      subtitle: 'Image output options',
                      animated: _isChangingColorsEnabled,
                      initiallyExpanded: false,
                      child: ZzzSwitchTile(
                        value: _wideImageExportEnabled,
                        title: 'Wide export',
                        subtitle: 'Exports images at a higher scale.',
                        animated: _isChangingColorsEnabled,
                        onChanged: (value) {
                          setState(() => _wideImageExportEnabled = value);
                          setDialogState(() {});
                          _saveBoolSetting('wideImageExportEnabled', value);
                        },
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Done'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _openAboutDialog() {
    showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: Colors.black,
          title: const Text('About'),
          content: const SizedBox(
            width: 560,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'A Flutter port of the ZZZ-Chat web app for simulating Zenless Zone Zero style DMs and group chats.',
                ),
                SizedBox(height: 14),
                Text(
                  'Character icons come from the original ZZZ-Chat assets. Original design and character rights belong to miHoYo/HoYoVerse. This is a fan project and is not affiliated with miHoYo or HoYoVerse.',
                  style: TextStyle(color: Colors.white60, height: 1.4),
                ),
              ],
            ),
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Close'),
            ),
          ],
        );
      },
    );
  }

  ButtonStyle _yellowButtonStyle() {
    return FilledButton.styleFrom(
      backgroundColor: ZzzColors.yellow,
      foregroundColor: Colors.black,
      minimumSize: const Size.fromHeight(48),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
    );
  }
}

class _HowToUse extends StatelessWidget {
  const _HowToUse();

  @override
  Widget build(BuildContext context) {
    const style = TextStyle(color: Colors.white54, height: 1.45);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 620),
      child: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'How to use:',
            style: TextStyle(color: Colors.white70, fontSize: 18),
          ),
          SizedBox(height: 8),
          Text('1. Switch between DMs or Group Chat at the top.', style: style),
          Text('2. Choose characters from the profile panel.', style: style),
          Text(
            '3. Send text or image messages, then tap messages to edit them.',
            style: style,
          ),
        ],
      ),
    );
  }
}

class _TextInputDialog extends StatefulWidget {
  const _TextInputDialog({
    required this.title,
    required this.initialText,
    required this.saveLabel,
    this.hintText,
    this.minLines = 1,
    this.maxLines = 1,
  });

  final String title;
  final String initialText;
  final String saveLabel;
  final String? hintText;
  final int minLines;
  final int maxLines;

  @override
  State<_TextInputDialog> createState() => _TextInputDialogState();
}

class _TextInputDialogState extends State<_TextInputDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialText);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    Navigator.of(context).pop(_controller.text);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: Colors.black,
      title: Text(widget.title),
      content: ZzzTextInput(
        controller: _controller,
        autofocus: true,
        hintText: widget.hintText,
        minLines: widget.minLines,
        maxLines: widget.maxLines,
        fillColor: Colors.white.withValues(alpha: 0.08),
        foregroundColor: Colors.white,
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: Text(widget.saveLabel)),
      ],
    );
  }
}

class _ExpandingBubbleAction extends StatefulWidget {
  const _ExpandingBubbleAction({
    required this.child,
    required this.action,
    required this.actionOnRight,
    required this.tint,
  });

  final Widget child;
  final Widget action;
  final bool actionOnRight;
  final Color tint;

  @override
  State<_ExpandingBubbleAction> createState() => _ExpandingBubbleActionState();
}

class _ExpandingBubbleActionState extends State<_ExpandingBubbleAction> {
  static const _collapsedWidth = 10.0;
  static const _expandedWidth = 42.0;

  bool _hovered = false;

  void _setHovered(bool hovered) {
    if (_hovered == hovered) return;
    setState(() => _hovered = hovered);
  }

  @override
  Widget build(BuildContext context) {
    final rail = MouseRegion(
      onEnter: (_) => _setHovered(true),
      onExit: (_) => _setHovered(false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 210),
        curve: Curves.easeOutCubic,
        width: _hovered ? _expandedWidth : _collapsedWidth,
        alignment: Alignment.topCenter,
        padding: const EdgeInsets.only(top: 5),
        decoration: BoxDecoration(color: _hovered ? widget.tint : null),
        child: _HoverRevealAction(visible: _hovered, child: widget.action),
      ),
    );

    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children:
          widget.actionOnRight
              ? [Flexible(child: widget.child), rail]
              : [rail, Flexible(child: widget.child)],
    );
  }
}

class _HoverActionHotspot extends StatefulWidget {
  const _HoverActionHotspot({required this.child});

  final Widget child;

  @override
  State<_HoverActionHotspot> createState() => _HoverActionHotspotState();
}

class _HoverActionHotspotState extends State<_HoverActionHotspot> {
  bool _hovered = false;

  void _setHovered(bool hovered) {
    if (_hovered == hovered) return;
    setState(() => _hovered = hovered);
  }

  @override
  Widget build(BuildContext context) {
    final child = SizedBox.square(
      dimension: 40,
      child: Center(
        child: _HoverRevealAction(visible: _hovered, child: widget.child),
      ),
    );

    return MouseRegion(
      onEnter: (_) => _setHovered(true),
      onExit: (_) => _setHovered(false),
      child: child,
    );
  }
}

class _HoverRevealAction extends StatelessWidget {
  const _HoverRevealAction({required this.visible, required this.child});

  final bool visible;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      ignoring: !visible,
      child: AnimatedOpacity(
        opacity: visible ? 1 : 0,
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOutCubic,
        child: AnimatedSlide(
          offset: visible ? Offset.zero : const Offset(0, 0.18),
          duration: const Duration(milliseconds: 190),
          curve: Curves.easeOutCubic,
          child: AnimatedScale(
            scale: visible ? 1 : 0.68,
            duration: const Duration(milliseconds: 190),
            curve: Curves.easeOutBack,
            child: child,
          ),
        ),
      ),
    );
  }
}

class CharacterPickerDialog extends StatefulWidget {
  const CharacterPickerDialog({
    required this.characters,
    required this.sideLabel,
    super.key,
  });

  final List<ChatCharacter> characters;
  final String sideLabel;

  @override
  State<CharacterPickerDialog> createState() => _CharacterPickerDialogState();
}

class _CharacterPickerDialogState extends State<CharacterPickerDialog> {
  final _searchController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final grouped = <String, List<ChatCharacter>>{};
    for (final character in widget.characters) {
      final matches =
          character.name.toLowerCase().contains(_query) ||
          character.category.toLowerCase().contains(_query);
      if (_query.isNotEmpty && !matches) continue;
      grouped.putIfAbsent(character.category, () => []).add(character);
    }

    return Dialog.fullscreen(
      backgroundColor: Colors.black.withValues(alpha: 0.96),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Choose a Character for ${widget.sideLabel}',
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  IconButton.filled(
                    tooltip: 'Close',
                    onPressed: () => Navigator.of(context).pop(),
                    style: IconButton.styleFrom(backgroundColor: ZzzColors.red),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              ZzzTextInput(
                controller: _searchController,
                hintText: 'Search by name or category...',
                prefixIcon: const Icon(Icons.search_rounded),
                onChanged: (value) {
                  setState(() => _query = value.trim().toLowerCase());
                },
              ),
              const SizedBox(height: 14),
              Expanded(
                child:
                    grouped.isEmpty
                        ? const Center(
                          child: Text(
                            'No matching characters.',
                            style: TextStyle(color: Colors.white54),
                          ),
                        )
                        : ListView(
                          children: [
                            for (final entry in grouped.entries) ...[
                              ZzzSectionLabel(label: entry.key),
                              LayoutBuilder(
                                builder: (context, constraints) {
                                  final width = constraints.maxWidth;
                                  final count =
                                      width > 900
                                          ? 6
                                          : width > 620
                                          ? 4
                                          : 3;
                                  return GridView.builder(
                                    shrinkWrap: true,
                                    physics:
                                        const NeverScrollableScrollPhysics(),
                                    itemCount: entry.value.length,
                                    gridDelegate:
                                        SliverGridDelegateWithFixedCrossAxisCount(
                                          crossAxisCount: count,
                                          mainAxisSpacing: 16,
                                          crossAxisSpacing: 12,
                                          childAspectRatio: 0.86,
                                        ),
                                    itemBuilder: (context, index) {
                                      final character = entry.value[index];
                                      return InkWell(
                                        borderRadius: BorderRadius.circular(12),
                                        onTap:
                                            () => Navigator.of(
                                              context,
                                            ).pop(character),
                                        child: Column(
                                          mainAxisAlignment:
                                              MainAxisAlignment.center,
                                          children: [
                                            Container(
                                              padding: const EdgeInsets.all(3),
                                              decoration: const BoxDecoration(
                                                shape: BoxShape.circle,
                                                color: ZzzColors.yellow,
                                              ),
                                              child: CircleAvatar(
                                                radius: 33,
                                                backgroundColor: Colors.white,
                                                backgroundImage: AssetImage(
                                                  character.assetPath,
                                                ),
                                              ),
                                            ),
                                            const SizedBox(height: 8),
                                            Text(
                                              character.name,
                                              textAlign: TextAlign.center,
                                              maxLines: 2,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ],
                                        ),
                                      );
                                    },
                                  );
                                },
                              ),
                            ],
                            const SizedBox(height: 18),
                            Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: ZzzColors.yellow,
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Row(
                                children: [
                                  Image.asset(
                                    'assets/media/CorinSticker01.png',
                                    width: 60,
                                    height: 60,
                                  ),
                                  const SizedBox(width: 12),
                                  const Expanded(
                                    child: Text(
                                      'Help add more Agents & NPCs through the original ZZZ-Chat repo.',
                                      style: TextStyle(color: Colors.black),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class SystemMessageDialog extends StatefulWidget {
  const SystemMessageDialog({super.key});

  @override
  State<SystemMessageDialog> createState() => _SystemMessageDialogState();
}

class _SystemMessageDialogState extends State<SystemMessageDialog> {
  SystemMessageKind? _selectedKind;
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_selectedKind == null) {
      return AlertDialog(
        backgroundColor: Colors.black,
        title: const Text('Select System Message'),
        content: SizedBox(
          width: 430,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ZzzSystemTemplateButton(
                message: ChatMessage(
                  side: ChatSide.system,
                  kind: MessageKind.system,
                  systemKind: SystemMessageKind.userAdded,
                  text: defaultSystemText(SystemMessageKind.userAdded),
                ),
                onTap: () => _select(SystemMessageKind.userAdded),
              ),
              ZzzSystemTemplateButton(
                message: ChatMessage(
                  side: ChatSide.system,
                  kind: MessageKind.system,
                  systemKind: SystemMessageKind.history,
                  text: defaultSystemText(SystemMessageKind.history),
                ),
                onTap: () => _select(SystemMessageKind.history),
              ),
              ZzzSystemTemplateButton(
                message: ChatMessage(
                  side: ChatSide.system,
                  kind: MessageKind.system,
                  systemKind: SystemMessageKind.fileUploaded,
                  text: defaultSystemText(SystemMessageKind.fileUploaded),
                ),
                onTap: () => _select(SystemMessageKind.fileUploaded),
              ),
            ],
          ),
        ),
      );
    }

    return AlertDialog(
      backgroundColor: Colors.black,
      title: const Text('Customize Message'),
      content: ZzzTextInput(
        controller: _controller,
        autofocus: true,
        fillColor: Colors.white.withValues(alpha: 0.08),
        foregroundColor: Colors.white,
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => setState(() => _selectedKind = null),
          child: const Text('Back'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Okay')),
      ],
    );
  }

  void _select(SystemMessageKind kind) {
    setState(() {
      _selectedKind = kind;
      _controller.text = defaultSystemText(kind);
    });
  }

  void _submit() {
    final kind = _selectedKind;
    if (kind == null) return;
    Navigator.of(context).pop(
      ChatMessage(
        side: ChatSide.system,
        kind: MessageKind.system,
        systemKind: kind,
        text:
            _controller.text.trim().isEmpty
                ? defaultSystemText(kind)
                : _controller.text.trim(),
      ),
    );
  }
}
