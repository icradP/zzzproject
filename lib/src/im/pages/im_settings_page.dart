import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:onebot_flutter/onebot_flutter.dart'
    show OneBotClient, OneBotConfig, OneBotWsMode;

import '../../theme/zzz_colors.dart';
import '../../widgets/zzz_widgets.dart';
import '../data/im_animation_config.dart';
import '../data/im_backdrop_config.dart';
import '../data/im_connection_config.dart';
import '../data/im_message_display_config.dart';
import '../data/im_nsfw_config.dart';
import '../data/im_push_manager.dart';
import '../data/im_storage_config.dart';
import '../im_scope.dart';
import '../adapters/zzz_server/zzz_server_source.dart';

class ImSettingsPage extends StatefulWidget {
  const ImSettingsPage({super.key});

  static const routeName = '/settings';

  @override
  State<ImSettingsPage> createState() => _ImSettingsPageState();
}

class _ImSettingsPageState extends State<ImSettingsPage>
    with SingleTickerProviderStateMixin {
  ImPlatform _platform = ImPlatform.mock;
  WsMode _wsMode = WsMode.forward;
  final _profileNameController = TextEditingController();
  final _httpController = TextEditingController();
  final _wsController = TextEditingController();
  final _tokenController = TextEditingController();
  final _selfIdController = TextEditingController();
  final _serverUrlController = TextEditingController();
  final _storagePathController = TextEditingController();
  List<ImConnectionProfile> _profiles = const [];
  String? _selectedProfileId;
  String? _primaryProfileId;
  bool _profileEnabled = true;
  bool _saving = false;
  bool _testing = false;
  String? _testResult;
  bool _testSuccess = false;
  bool _loaded = false;
  bool _migrating = false;
  bool _clearingCache = false;
  ImAnimationConfig _animConfig = ImAnimationConfig();
  bool _showMessageStatus = false;
  ImBackdropConfig _backdropConfig = ImBackdropConfig();
  final _backdropControllers = <TextEditingController>[];
  ImNsfwConfig _nsfwConfig = ImNsfwConfig();
  late final AnimationController _bgController;

  final _platformItems = const [
    ZzzSegmentItem<ImPlatform>(
      value: ImPlatform.mock,
      icon: Icons.science_outlined,
      tooltip: 'Mock (offline)',
    ),
    ZzzSegmentItem<ImPlatform>(
      value: ImPlatform.nonebot,
      icon: Icons.hub_outlined,
      tooltip: 'NoneBot v1 (OneBot)',
    ),
    ZzzSegmentItem<ImPlatform>(
      value: ImPlatform.zzzServer,
      icon: Icons.dns_outlined,
      tooltip: 'ZZZ Server',
    ),
  ];

  final _wsModeItems = const [
    ZzzSegmentItem<WsMode>(
      value: WsMode.forward,
      icon: Icons.arrow_forward_rounded,
      tooltip: 'Forward (client)',
    ),
    ZzzSegmentItem<WsMode>(
      value: WsMode.reverse,
      icon: Icons.arrow_back_rounded,
      tooltip: 'Reverse (server)',
    ),
  ];

  @override
  void initState() {
    super.initState();
    _bgController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 30),
    )..repeat();
    _loadConfig();
  }

  @override
  void dispose() {
    _httpController.dispose();
    _profileNameController.dispose();
    _wsController.dispose();
    _tokenController.dispose();
    _selfIdController.dispose();
    _serverUrlController.dispose();
    _storagePathController.dispose();
    _bgController.dispose();
    for (final c in _nsfwControllers) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _loadConfig() async {
    var profiles = await ImConnectionProfiles.load();
    if (profiles.profiles.isEmpty) {
      final platform = kIsWeb ? ImPlatform.zzzServer : ImPlatform.mock;
      final profile = ImConnectionProfile(
        id: ImConnectionProfile.createId(platform),
        name: ImConnectionProfile.defaultName(platform),
        config: ImConnectionConfig(platform: platform),
      );
      profiles = ImConnectionProfiles(
        profiles: [profile],
        primaryProfileId: profile.id,
      );
    }
    final storage = await ImStorageConfig.load();
    final anim = await ImAnimationConfig.load();
    _animConfig = anim;
    final showMessageStatus = await ImMessageDisplayConfig.load();
    final backdrop = await ImBackdropConfig.load();
    _backdropConfig = backdrop;
    _rebuildBackdropControllers();
    final nsfw = await ImNsfwConfig.load();
    _nsfwConfig = nsfw;
    _refreshNsfwControllers();
    setState(() {
      _profiles = [...profiles.profiles];
      _primaryProfileId = profiles.primaryProfileId ?? _profiles.first.id;
      _loadProfileIntoEditor(
        profiles.primaryProfile ?? profiles.profiles.first,
      );
      _storagePathController.text = storage.basePath ?? '';
      _showMessageStatus = showMessageStatus;
      _loaded = true;
    });
  }

  void _loadProfileIntoEditor(ImConnectionProfile profile) {
    final config = profile.config;
    _selectedProfileId = profile.id;
    _profileNameController.text = profile.name;
    _profileEnabled = profile.enabled;
    _platform = config.platform;
    _wsMode = config.wsMode;
    _httpController.text = config.httpEndpoint ?? '';
    _wsController.text = config.wsEndpoint ?? '';
    _tokenController.text = config.accessToken ?? '';
    _selfIdController.text = config.selfId;
    _serverUrlController.text = config.serverUrl ?? '';
    _testResult = null;
    _testSuccess = false;
  }

  ImConnectionProfile _profileFromEditor() {
    final selectedId = _selectedProfileId;
    if (selectedId == null) {
      throw StateError('No connection profile is selected.');
    }
    final name = _profileNameController.text.trim();
    return ImConnectionProfile(
      id: selectedId,
      name: name.isEmpty ? ImConnectionProfile.defaultName(_platform) : name,
      enabled: _profileEnabled,
      config: ImConnectionConfig(
        platform: _platform,
        wsMode: _wsMode,
        httpEndpoint: _optionalText(_httpController),
        wsEndpoint: _optionalText(_wsController),
        accessToken: _optionalText(_tokenController),
        selfId: _selfIdController.text.trim(),
        serverUrl: _optionalText(_serverUrlController),
      ),
    );
  }

  String? _optionalText(TextEditingController controller) {
    final value = controller.text.trim();
    return value.isEmpty ? null : value;
  }

  void _commitProfileEditor() {
    final selectedId = _selectedProfileId;
    if (selectedId == null) return;
    final index = _profiles.indexWhere((profile) => profile.id == selectedId);
    if (index < 0) return;
    _profiles = [..._profiles]..[index] = _profileFromEditor();
  }

  void _selectProfile(ImConnectionProfile profile) {
    _commitProfileEditor();
    setState(() => _loadProfileIntoEditor(profile));
  }

  void _addProfile(ImPlatform platform) {
    _commitProfileEditor();
    final profile = ImConnectionProfile(
      id: ImConnectionProfile.createId(platform),
      name: ImConnectionProfile.defaultName(platform),
      config: ImConnectionConfig(platform: platform),
    );
    setState(() {
      _profiles = [..._profiles, profile];
      _primaryProfileId ??= profile.id;
      _loadProfileIntoEditor(profile);
    });
  }

  void _deleteSelectedProfile() {
    if (_profiles.length <= 1 || _selectedProfileId == null) return;
    final deletedId = _selectedProfileId;
    setState(() {
      _profiles =
          _profiles.where((profile) => profile.id != deletedId).toList();
      if (_primaryProfileId == deletedId) {
        _primaryProfileId = _profiles.first.id;
      }
      _loadProfileIntoEditor(_profiles.first);
    });
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      _commitProfileEditor();
      final profiles = ImConnectionProfiles(
        profiles: _profiles,
        primaryProfileId: _primaryProfileId,
      );
      await profiles.save();
      final storage = ImStorageConfig(
        basePath:
            _storagePathController.text.trim().isEmpty
                ? null
                : _storagePathController.text.trim(),
      );
      await storage.save();
      await _animConfig.save();
      await _backdropConfig.save();
      await _nsfwConfig.save();
      if (mounted) await ImScope.reloadConnections(context);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Saved and applied.'),
            behavior: SnackBarBehavior.floating,
          ),
        );
        Navigator.of(context).pop();
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _testConnection() async {
    setState(() {
      _testing = true;
      _testResult = null;
      _testSuccess = false;
    });

    if (_platform == ImPlatform.mock) {
      setState(() {
        _testing = false;
        _testSuccess = true;
        _testResult = 'Local demo is ready';
      });
      return;
    }

    if (_platform == ImPlatform.zzzServer) {
      final source = ZzzServerSource(
        config: ZzzServerConfig(
          serverUrl: _serverUrlController.text.trim(),
          selfId: _selfIdController.text.trim(),
          authToken: _tokenController.text.trim(),
        ),
        allowReconnect: false,
      );
      final error = await source.testConnection();
      source.disconnect();
      if (mounted) {
        setState(() {
          _testing = false;
          _testSuccess = error == null;
          _testResult = error ?? 'Connection successful';
        });
      }
      return;
    }

    final client = OneBotClient(
      config: OneBotConfig(
        selfId: _selfIdController.text.trim(),
        httpEndpoint:
            _httpController.text.trim().isEmpty
                ? null
                : _httpController.text.trim(),
        wsEndpoint:
            _wsController.text.trim().isEmpty
                ? null
                : _wsController.text.trim(),
        wsMode:
            _wsMode == WsMode.forward
                ? OneBotWsMode.forward
                : OneBotWsMode.reverse,
        accessToken:
            _tokenController.text.trim().isEmpty
                ? null
                : _tokenController.text.trim(),
      ),
    );

    final error = await client.testConnection();
    client.disconnect();
    if (mounted) {
      setState(() {
        _testing = false;
        _testSuccess = error == null;
        _testResult = error ?? 'Connection successful';
      });
    }
  }

  Future<void> _migrateData() async {
    final newPath = _storagePathController.text.trim();
    if (newPath.isEmpty) return;
    final oldConfig = await ImStorageConfig.load();
    final oldPath = oldConfig.basePath ?? '';
    if (oldPath == newPath) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Source and destination are the same.'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return;
    }

    setState(() => _migrating = true);
    try {
      final count = await ImStorageConfig.migrate(oldPath, newPath);
      await ImStorageConfig(basePath: newPath).save();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Migrated $count files to $newPath. Saved.'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Migration failed: $e'),
            behavior: SnackBarBehavior.floating,
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _migrating = false);
    }
  }

  Future<void> _clearAvatarCache() async {
    setState(() => _clearingCache = true);
    try {
      await ImScope.repositoryOf(context).clearAvatarCache();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Avatar cache cleared.'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed: $e'),
            behavior: SnackBarBehavior.floating,
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _clearingCache = false);
    }
  }

  // -----------------------------------------------------------------------
  // Build
  // -----------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          ZzzBackground(controller: _bgController, animated: false),
          SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: ZzzPanel(
                  animateEntrance: true,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 560),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _buildHeader(),
                        const SizedBox(height: 20),
                        ZzzExpandableSection(
                          title: 'Connections',
                          subtitle: 'Client-managed IM sources',
                          initiallyExpanded: false,
                          child: _buildConnectionFields(),
                        ),
                        const SizedBox(height: 12),
                        ZzzExpandableSection(
                          title: 'Notifications',
                          subtitle: 'Background message alerts',
                          initiallyExpanded: false,
                          child: _buildNotificationFields(),
                        ),
                        const SizedBox(height: 12),
                        ZzzExpandableSection(
                          title: 'Visual',
                          subtitle: 'Message display, animation, and motion',
                          initiallyExpanded: false,
                          child: _buildAnimationToggles(),
                        ),
                        const SizedBox(height: 12),
                        ZzzExpandableSection(
                          title: 'Backdrop',
                          subtitle: 'Scrolling background text lines',
                          initiallyExpanded: false,
                          child: _buildBackdropEditor(),
                        ),
                        const SizedBox(height: 12),
                        ZzzExpandableSection(
                          title: 'NSFW Detection',
                          subtitle: 'Content filtering with NudeNet ONNX',
                          initiallyExpanded: false,
                          child: _buildNsfwFields(),
                        ),
                        const SizedBox(height: 12),
                        ZzzExpandableSection(
                          title: 'Storage',
                          subtitle: 'Media cache, avatars, chat history',
                          initiallyExpanded: false,
                          child: _buildStorageFields(),
                        ),
                        const SizedBox(height: 24),
                        _buildSaveButton(),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Row(
      children: [
        IconButton(
          tooltip: 'Back',
          onPressed: () => Navigator.of(context).pop(),
          icon: const Icon(Icons.arrow_back_rounded),
        ),
        const SizedBox(width: 8),
        const Text(
          'IM Settings',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
        ),
      ],
    );
  }

  // -----------------------------------------------------------------------
  // Connection section
  // -----------------------------------------------------------------------

  Widget _buildConnectionFields() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Expanded(child: _FieldLabel('Connection profiles')),
            PopupMenuButton<ImPlatform>(
              tooltip: 'Add connection',
              icon: const Icon(Icons.add_rounded),
              onSelected: _addProfile,
              itemBuilder:
                  (context) => [
                    if (!kIsWeb)
                      const PopupMenuItem(
                        value: ImPlatform.nonebot,
                        child: ListTile(
                          leading: Icon(Icons.hub_outlined),
                          title: Text('QQ / NoneBot'),
                        ),
                      ),
                    const PopupMenuItem(
                      value: ImPlatform.zzzServer,
                      child: ListTile(
                        leading: Icon(Icons.dns_outlined),
                        title: Text('ZZZ Server'),
                      ),
                    ),
                    const PopupMenuItem(
                      value: ImPlatform.mock,
                      child: ListTile(
                        leading: Icon(Icons.science_outlined),
                        title: Text('Local demo'),
                      ),
                    ),
                  ],
            ),
          ],
        ),
        const SizedBox(height: 6),
        ..._profiles.map(_buildProfileTile),
        const SizedBox(height: 14),
        ZzzTextInput(
          controller: _profileNameController,
          hintText: 'Connection name',
          prefixIcon: const Icon(Icons.label_outline),
          fillColor: Colors.white.withValues(alpha: 0.06),
          foregroundColor: Colors.white,
        ),
        const SizedBox(height: 10),
        ZzzSwitchTile(
          value: _profileEnabled,
          title: 'Enabled',
          subtitle: _profileEnabled ? 'Connected on app start' : 'Kept offline',
          onChanged: (value) => setState(() => _profileEnabled = value),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed:
                    _selectedProfileId == _primaryProfileId
                        ? null
                        : () => setState(
                          () => _primaryProfileId = _selectedProfileId,
                        ),
                icon: const Icon(Icons.star_outline_rounded, size: 18),
                label: Text(
                  _selectedProfileId == _primaryProfileId
                      ? 'Primary connection'
                      : 'Make primary',
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              tooltip: 'Delete connection',
              onPressed: _profiles.length > 1 ? _deleteSelectedProfile : null,
              icon: const Icon(Icons.delete_outline_rounded),
            ),
          ],
        ),
        const Divider(color: Colors.white12, height: 28),
        const _FieldLabel('Platform'),
        const SizedBox(height: 8),
        ZzzSegmentedControl<ImPlatform>(
          items: _platformItems
              .where((item) => !kIsWeb || item.value != ImPlatform.nonebot)
              .toList(growable: false),
          value: _platform,
          onChanged: (value) {
            final oldDefault = ImConnectionProfile.defaultName(_platform);
            setState(() {
              _platform = value;
              if (_profileNameController.text.trim().isEmpty ||
                  _profileNameController.text.trim() == oldDefault) {
                _profileNameController.text = ImConnectionProfile.defaultName(
                  value,
                );
              }
            });
          },
        ),
        if (_platform == ImPlatform.nonebot) ...[
          const SizedBox(height: 14),
          ZzzTextInput(
            controller: _selfIdController,
            hintText: 'Self ID (QQ / bot account)',
            prefixIcon: const Icon(Icons.badge_outlined),
            fillColor: Colors.white.withValues(alpha: 0.06),
            foregroundColor: Colors.white,
          ),
          const SizedBox(height: 10),
          ZzzTextInput(
            controller: _httpController,
            hintText: 'HTTP endpoint (e.g. http://127.0.0.1:5700)',
            prefixIcon: const Icon(Icons.http_outlined),
            fillColor: Colors.white.withValues(alpha: 0.06),
            foregroundColor: Colors.white,
          ),
          const SizedBox(height: 10),
          ZzzTextInput(
            controller: _wsController,
            hintText: 'WS endpoint (e.g. ws://127.0.0.1:6199/ws)',
            prefixIcon: const Icon(Icons.cable_outlined),
            fillColor: Colors.white.withValues(alpha: 0.06),
            foregroundColor: Colors.white,
          ),
          const SizedBox(height: 10),
          const _FieldLabel('WebSocket mode'),
          const SizedBox(height: 8),
          ZzzSegmentedControl<WsMode>(
            items: _wsModeItems,
            value: _wsMode,
            onChanged: (v) => setState(() => _wsMode = v),
          ),
          const SizedBox(height: 10),
          ZzzTextInput(
            controller: _tokenController,
            hintText: 'Access token (optional)',
            obscureText: true,
            prefixIcon: const Icon(Icons.key_outlined),
            fillColor: Colors.white.withValues(alpha: 0.06),
            foregroundColor: Colors.white,
          ),
          const SizedBox(height: 12),
          _buildTestButton(),
          if (_testResult != null) ...[
            const SizedBox(height: 8),
            _buildTestResult(),
          ],
        ],
        if (_platform == ImPlatform.zzzServer) ...[
          const SizedBox(height: 14),
          ZzzTextInput(
            controller: _serverUrlController,
            hintText: 'Server URL (e.g. ws://your-server:8080/ws)',
            prefixIcon: const Icon(Icons.dns_outlined),
            fillColor: Colors.white.withValues(alpha: 0.06),
            foregroundColor: Colors.white,
          ),
          const SizedBox(height: 10),
          ZzzTextInput(
            controller: _selfIdController,
            hintText: 'User ID',
            prefixIcon: const Icon(Icons.badge_outlined),
            fillColor: Colors.white.withValues(alpha: 0.06),
            foregroundColor: Colors.white,
          ),
          const SizedBox(height: 10),
          ZzzTextInput(
            controller: _tokenController,
            hintText: 'Auth token',
            obscureText: true,
            prefixIcon: const Icon(Icons.key_outlined),
            fillColor: Colors.white.withValues(alpha: 0.06),
            foregroundColor: Colors.white,
          ),
          const SizedBox(height: 12),
          _buildTestButton(),
          if (_testResult != null) ...[
            const SizedBox(height: 8),
            _buildTestResult(),
          ],
        ],
      ],
    );
  }

  Widget _buildProfileTile(ImConnectionProfile profile) {
    final selected = profile.id == _selectedProfileId;
    final primary = profile.id == _primaryProfileId;
    return Material(
      color:
          selected
              ? ZzzColors.yellow.withValues(alpha: 0.12)
              : Colors.transparent,
      child: ListTile(
        dense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 10),
        leading: Icon(switch (profile.config.platform) {
          ImPlatform.mock => Icons.science_outlined,
          ImPlatform.nonebot => Icons.hub_outlined,
          ImPlatform.zzzServer => Icons.dns_outlined,
        }, color: selected ? ZzzColors.yellow : Colors.white54),
        title: Text(profile.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          '${_platformName(profile.config.platform)}${profile.enabled ? '' : ' · Disabled'}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing:
            primary
                ? const Tooltip(
                  message: 'Primary connection',
                  child: Icon(Icons.star_rounded, color: ZzzColors.yellow),
                )
                : null,
        selected: selected,
        onTap: () => _selectProfile(profile),
      ),
    );
  }

  String _platformName(ImPlatform platform) => switch (platform) {
    ImPlatform.mock => 'Local demo',
    ImPlatform.nonebot => 'QQ / NoneBot',
    ImPlatform.zzzServer => 'ZZZ Server',
  };

  Widget _buildNotificationFields() {
    final manager = ImScope.pushManagerOf(context);
    return ListenableBuilder(
      listenable: manager,
      builder: (context, _) {
        final enabled = manager.permission == ImPushPermission.enabled;
        final denied = manager.permission == ImPushPermission.denied;
        final status = switch (manager.permission) {
          ImPushPermission.unsupported =>
            'Unavailable in this browser or app mode',
          ImPushPermission.defaultState => 'Off',
          ImPushPermission.denied => 'Blocked by browser settings',
          ImPushPermission.enabled => 'On for this device',
        };
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ZzzSwitchTile(
              value: enabled,
              title: 'Message notifications',
              subtitle: manager.error ?? status,
              onChanged:
                  manager.isSupported && !manager.isBusy && !denied
                      ? (value) {
                        if (value) {
                          manager.enable();
                        } else {
                          manager.disable();
                        }
                      }
                      : null,
            ),
            if (manager.isBusy) ...[
              const SizedBox(height: 8),
              const LinearProgressIndicator(minHeight: 2),
            ],
          ],
        );
      },
    );
  }

  // -- Backdrop text helpers -------------------------------------------------

  void _rebuildBackdropControllers() {
    for (final c in _backdropControllers) {
      c.dispose();
    }
    _backdropControllers.clear();
    for (final line in _backdropConfig.lines) {
      _backdropControllers.add(TextEditingController(text: line));
    }
  }

  void _addBackdropLine() {
    setState(() {
      final lines = [..._backdropConfig.lines, ''];
      _backdropConfig = _backdropConfig.copyWith(lines: lines);
      _backdropControllers.add(TextEditingController());
    });
  }

  void _removeBackdropLine(int i) {
    if (_backdropConfig.lines.length <= 1) return;
    setState(() {
      final lines = [..._backdropConfig.lines]..removeAt(i);
      _backdropConfig = _backdropConfig.copyWith(lines: lines);
      _backdropControllers[i].dispose();
      _backdropControllers.removeAt(i);
    });
  }

  void _onBackdropLineChanged(int i, String value) {
    final lines = [..._backdropConfig.lines];
    lines[i] = value;
    _backdropConfig = _backdropConfig.copyWith(lines: lines);
  }

  // -----------------------------------------------------------------------
  // Visual / Animation section
  // -----------------------------------------------------------------------

  Widget _buildAnimationToggles() {
    return Column(
      children: [
        ZzzSwitchTile(
          value: _showMessageStatus,
          title: 'Message status',
          subtitle: 'Show sending, delivered, and read indicators.',
          onChanged: (value) {
            setState(() => _showMessageStatus = value);
            ImMessageDisplayConfig.setShowMessageStatus(value);
          },
        ),
        ZzzSwitchTile(
          value: _animConfig.conversationListSlide,
          title: 'Conversation list slide',
          subtitle: 'Animate items when they reorder after new messages.',
          onChanged: (v) {
            setState(
              () =>
                  _animConfig = _animConfig.copyWith(conversationListSlide: v),
            );
          },
        ),
        ZzzSwitchTile(
          value: _animConfig.chatPanelSlide,
          title: 'Chat panel transition',
          subtitle: 'Slide animation when switching between conversations.',
          onChanged: (v) {
            setState(
              () => _animConfig = _animConfig.copyWith(chatPanelSlide: v),
            );
          },
        ),
        ZzzSwitchTile(
          value: _animConfig.backgroundMotion,
          title: 'Animated background',
          subtitle: 'Moving ZERO ZONE style backdrop.',
          onChanged: (v) {
            setState(
              () => _animConfig = _animConfig.copyWith(backgroundMotion: v),
            );
          },
        ),
        ZzzSwitchTile(
          value: _animConfig.panelEntrance,
          title: 'Panel entrance effects',
          subtitle: 'Fade and slide when panels and dialogs open.',
          onChanged: (v) {
            setState(
              () => _animConfig = _animConfig.copyWith(panelEntrance: v),
            );
          },
        ),
      ],
    );
  }

  // -----------------------------------------------------------------------
  // Backdrop editor
  // -----------------------------------------------------------------------

  Widget _buildBackdropEditor() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < _backdropConfig.lines.length; i++)
          Padding(
            padding: EdgeInsets.only(
              bottom: i < _backdropConfig.lines.length - 1 ? 8 : 0,
            ),
            child: Row(
              children: [
                Expanded(
                  child: ZzzTextInput(
                    controller: _backdropControllers[i],
                    hintText: 'Line ${i + 1}',
                    fillColor: Colors.white.withValues(alpha: 0.06),
                    foregroundColor: Colors.white,
                    onChanged: (v) => _onBackdropLineChanged(i, v),
                  ),
                ),
                const SizedBox(width: 6),
                IconButton(
                  tooltip: 'Remove',
                  onPressed: () => _removeBackdropLine(i),
                  icon: const Icon(Icons.remove_circle_outline, size: 20),
                  style: IconButton.styleFrom(foregroundColor: Colors.white38),
                ),
              ],
            ),
          ),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          onPressed: _addBackdropLine,
          icon: const Icon(Icons.add_rounded, size: 18),
          label: const Text('Add line'),
          style: OutlinedButton.styleFrom(
            foregroundColor: Colors.white54,
            side: const BorderSide(color: Colors.white12),
            padding: const EdgeInsets.symmetric(vertical: 10),
          ),
        ),
      ],
    );
  }

  // -----------------------------------------------------------------------
  // Storage section
  // -----------------------------------------------------------------------

  Widget _buildStorageFields() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ZzzTextInput(
          controller: _storagePathController,
          hintText: 'Storage path (default: App Documents/ZZZIM)',
          prefixIcon: const Icon(Icons.folder_outlined),
          fillColor: Colors.white.withValues(alpha: 0.06),
          foregroundColor: Colors.white,
        ),
        const SizedBox(height: 6),
        Text(
          'Subdirectories: onebot_media_cache / avatars / im_data',
          style: const TextStyle(fontSize: 11, color: Colors.white30),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: _migrating ? null : _migrateData,
          icon:
              _migrating
                  ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                  : const Icon(Icons.drive_file_move_outlined, size: 18),
          label: Text(_migrating ? 'Migrating...' : 'Migrate existing data'),
          style: OutlinedButton.styleFrom(
            foregroundColor: Colors.white54,
            side: const BorderSide(color: Colors.white12),
            padding: const EdgeInsets.symmetric(vertical: 10),
          ),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: _clearingCache ? null : _clearAvatarCache,
          icon:
              _clearingCache
                  ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                  : const Icon(Icons.delete_sweep_outlined, size: 18),
          label: Text(_clearingCache ? 'Clearing...' : 'Clear avatar cache'),
          style: OutlinedButton.styleFrom(
            foregroundColor: Colors.white54,
            side: const BorderSide(color: Colors.white12),
            padding: const EdgeInsets.symmetric(vertical: 10),
          ),
        ),
      ],
    );
  }

  // -----------------------------------------------------------------------
  // NSFW section
  // -----------------------------------------------------------------------

  final _nsfwControllers = List.generate(
    18,
    (i) => TextEditingController(text: '20'),
  );

  void _refreshNsfwControllers() {
    for (var i = 0; i < 18; i++) {
      final pct = (_nsfwConfig.thresholdFor(i) * 100).round();
      final text = pct.toString();
      if (_nsfwControllers[i].text != text) {
        _nsfwControllers[i].text = text;
      }
    }
  }

  Widget _buildNsfwFields() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Master toggle
        ZzzSwitchTile(
          value: _nsfwConfig.enabled,
          title: 'Enable NSFW detection',
          subtitle:
              _nsfwConfig.enabled
                  ? 'Images will be blurred until long-pressed'
                  : 'All images shown without filtering',
          onChanged:
              (v) => setState(
                () => _nsfwConfig = _nsfwConfig.copyWith(enabled: v),
              ),
        ),
        const SizedBox(height: 12),

        // Per-class thresholds
        if (_nsfwConfig.enabled) ...[
          const Text(
            'Detection thresholds',
            style: TextStyle(
              color: Colors.white54,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          for (var i = 0; i < ImNsfwConfig.labels.length; i++)
            Padding(
              padding: EdgeInsets.only(
                bottom: i < ImNsfwConfig.labels.length - 1 ? 8 : 0,
              ),
              child: _buildClassRow(i),
            ),
        ],

        const SizedBox(height: 8),
        const Divider(color: Colors.white10, height: 1),
        const SizedBox(height: 8),

        // Reveal persistence
        ZzzSwitchTile(
          value: _nsfwConfig.persistReveal,
          title: 'Remember revealed images',
          subtitle: 'Revealed images stay unblurred after app restart',
          onChanged:
              (v) => setState(
                () => _nsfwConfig = _nsfwConfig.copyWith(persistReveal: v),
              ),
        ),
      ],
    );
  }

  Widget _buildClassRow(int classIndex) {
    final label = ImNsfwConfig.labels[classIndex];
    final enabled = _nsfwConfig.isClassEnabled(classIndex);
    return Row(
      children: [
        SizedBox(
          width: 24,
          child: Checkbox(
            value: enabled,
            onChanged: (v) {
              if (v == true) {
                final pct = double.tryParse(
                  _nsfwControllers[classIndex].text.trim(),
                );
                _nsfwConfig.setThreshold(
                  classIndex,
                  pct != null ? pct / 100 : 0.2,
                );
              } else {
                _nsfwConfig.setThreshold(classIndex, null);
              }
              setState(() {});
            },
            fillColor: WidgetStateProperty.resolveWith(
              (s) =>
                  s.contains(WidgetState.selected) ? Colors.pinkAccent : null,
            ),
            side: const BorderSide(color: Colors.white24),
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            label,
            style: TextStyle(
              color: enabled ? Colors.white : Colors.white30,
              fontSize: 13,
            ),
          ),
        ),
        SizedBox(
          width: 64,
          child: ZzzTextInput(
            controller: _nsfwControllers[classIndex],
            hintText: '20',
            fillColor: Colors.white.withValues(alpha: 0.06),
            foregroundColor: Colors.white,
            onChanged: (v) {
              final pct = double.tryParse(v.trim());
              if (pct != null) {
                _nsfwConfig.setThreshold(classIndex, pct / 100);
              }
            },
          ),
        ),
      ],
    );
  }

  // -----------------------------------------------------------------------
  // Shared widgets
  // -----------------------------------------------------------------------

  Widget _buildTestButton() {
    return OutlinedButton.icon(
      onPressed: _testing ? null : _testConnection,
      icon:
          _testing
              ? const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
              : const Icon(Icons.wifi_find_outlined, size: 18),
      label: Text(_testing ? 'Testing...' : 'Test Connection'),
      style: OutlinedButton.styleFrom(
        foregroundColor: Colors.white,
        side: const BorderSide(color: Colors.white24),
        padding: const EdgeInsets.symmetric(vertical: 12),
      ),
    );
  }

  Widget _buildTestResult() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color:
            _testSuccess
                ? Colors.green.withValues(alpha: 0.15)
                : Colors.red.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color:
              _testSuccess
                  ? Colors.green.withValues(alpha: 0.4)
                  : Colors.red.withValues(alpha: 0.4),
        ),
      ),
      child: Row(
        children: [
          Icon(
            _testSuccess ? Icons.check_circle_outline : Icons.error_outline,
            size: 18,
            color: _testSuccess ? Colors.greenAccent : Colors.redAccent,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _testResult!,
              style: TextStyle(
                fontSize: 13,
                color: _testSuccess ? Colors.greenAccent : Colors.redAccent,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSaveButton() {
    return FilledButton.icon(
      onPressed: _saving ? null : _save,
      icon:
          _saving
              ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.black,
                ),
              )
              : const Icon(Icons.save_rounded),
      label: Text(_saving ? 'Saving...' : 'Save'),
      style: FilledButton.styleFrom(
        backgroundColor: ZzzColors.yellow,
        foregroundColor: Colors.black,
        padding: const EdgeInsets.symmetric(vertical: 14),
        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
      ),
    );
  }
}

class _FieldLabel extends StatelessWidget {
  const _FieldLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        color: Colors.white54,
      ),
    );
  }
}
