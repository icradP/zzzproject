import 'package:flutter/material.dart';
import 'package:onebot_flutter/onebot_flutter.dart' show OneBotClient;

import '../../theme/zzz_colors.dart';
import '../../widgets/zzz_widgets.dart';
import '../adapters/nonebot/nonebot_models.dart';
import '../data/im_animation_config.dart';
import '../data/im_backdrop_config.dart';
import '../data/im_connection_config.dart';
import '../data/im_nsfw_config.dart';
import '../data/im_storage_config.dart';
import '../im_scope.dart';

class ImSettingsPage extends StatefulWidget {
  const ImSettingsPage({super.key});

  static const routeName = '/settings';

  @override
  State<ImSettingsPage> createState() => _ImSettingsPageState();
}

class _ImSettingsPageState extends State<ImSettingsPage>
    with SingleTickerProviderStateMixin {
  ImPlatform _platform = ImPlatform.mock;
  OneBotWsMode _wsMode = OneBotWsMode.forward;
  final _httpController = TextEditingController();
  final _wsController = TextEditingController();
  final _tokenController = TextEditingController();
  final _selfIdController = TextEditingController();
  final _storagePathController = TextEditingController();
  bool _saving = false;
  bool _testing = false;
  String? _testResult;
  bool _testSuccess = false;
  bool _loaded = false;
  bool _migrating = false;
  bool _clearingCache = false;
  ImAnimationConfig _animConfig = ImAnimationConfig();
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
  ];

  final _wsModeItems = const [
    ZzzSegmentItem<OneBotWsMode>(
      value: OneBotWsMode.forward,
      icon: Icons.arrow_forward_rounded,
      tooltip: 'Forward (client)',
    ),
    ZzzSegmentItem<OneBotWsMode>(
      value: OneBotWsMode.reverse,
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
    _wsController.dispose();
    _tokenController.dispose();
    _selfIdController.dispose();
    _storagePathController.dispose();
    _bgController.dispose();
    for (final c in _nsfwControllers) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _loadConfig() async {
    final config = await ImConnectionConfig.loadOrDefault();
    final storage = await ImStorageConfig.load();
    final anim = await ImAnimationConfig.load();
    _animConfig = anim;
    final backdrop = await ImBackdropConfig.load();
    _backdropConfig = backdrop;
    _rebuildBackdropControllers();
    final nsfw = await ImNsfwConfig.load();
    _nsfwConfig = nsfw;
    _refreshNsfwControllers();
    setState(() {
      _platform = config.platform;
      _wsMode = config.wsMode;
      _httpController.text = config.httpEndpoint ?? '';
      _wsController.text = config.wsEndpoint ?? '';
      _tokenController.text = config.accessToken ?? '';
      _selfIdController.text = config.selfId;
      _storagePathController.text = storage.basePath ?? '';
      _loaded = true;
    });
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final config = ImConnectionConfig(
        platform: _platform,
        wsMode: _wsMode,
        httpEndpoint: _httpController.text.trim().isEmpty
            ? null
            : _httpController.text.trim(),
        wsEndpoint: _wsController.text.trim().isEmpty
            ? null
            : _wsController.text.trim(),
        accessToken: _tokenController.text.trim().isEmpty
            ? null
            : _tokenController.text.trim(),
        selfId: _selfIdController.text.trim(),
      );
      await config.save();
      final storage = ImStorageConfig(
        basePath: _storagePathController.text.trim().isEmpty
            ? null
            : _storagePathController.text.trim(),
      );
      await storage.save();
      await _animConfig.save();
      await _backdropConfig.save();
      await _nsfwConfig.save();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Saved. Restart the app to apply.'),
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

    final client = OneBotClient(
      config: OneBotConfig(
        selfId: _selfIdController.text.trim(),
        httpEndpoint: _httpController.text.trim().isEmpty
            ? null
            : _httpController.text.trim(),
        wsEndpoint: _wsController.text.trim().isEmpty
            ? null
            : _wsController.text.trim(),
        wsMode: _wsMode,
        accessToken: _tokenController.text.trim().isEmpty
            ? null
            : _tokenController.text.trim(),
      ),
    );

    client.disconnect();    final error = await client.testConnection();


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
                          title: 'Connection',
                          subtitle: 'OneBot / NapCatQQ WebSocket',
                          initiallyExpanded: false,
                          child: _buildConnectionFields(),
                        ),
                        const SizedBox(height: 12),
                        ZzzExpandableSection(
                          title: 'Visual',
                          subtitle: 'Animation and motion effects',
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
        const _FieldLabel('Platform'),
        const SizedBox(height: 8),
        ZzzSegmentedControl<ImPlatform>(
          items: _platformItems,
          value: _platform,
          onChanged: (v) => setState(() => _platform = v),
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
          ZzzSegmentedControl<OneBotWsMode>(
            items: _wsModeItems,
            value: _wsMode,
            onChanged: (v) => setState(() => _wsMode = v),
          ),
          const SizedBox(height: 10),
          ZzzTextInput(
            controller: _tokenController,
            hintText: 'Access token (optional)',
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

  // -- Backdrop text helpers -------------------------------------------------

  void _rebuildBackdropControllers() {
    for (final c in _backdropControllers) { c.dispose(); }
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
          value: _animConfig.conversationListSlide,
          title: 'Conversation list slide',
          subtitle: 'Animate items when they reorder after new messages.',
          onChanged: (v) {
            setState(() => _animConfig = _animConfig.copyWith(
                  conversationListSlide: v,
                ));
          },
        ),
        ZzzSwitchTile(
          value: _animConfig.chatPanelSlide,
          title: 'Chat panel transition',
          subtitle: 'Slide animation when switching between conversations.',
          onChanged: (v) {
            setState(() => _animConfig = _animConfig.copyWith(
                  chatPanelSlide: v,
                ));
          },
        ),
        ZzzSwitchTile(
          value: _animConfig.backgroundMotion,
          title: 'Animated background',
          subtitle: 'Moving ZERO ZONE style backdrop.',
          onChanged: (v) {
            setState(() => _animConfig = _animConfig.copyWith(
                  backgroundMotion: v,
                ));
          },
        ),
        ZzzSwitchTile(
          value: _animConfig.panelEntrance,
          title: 'Panel entrance effects',
          subtitle: 'Fade and slide when panels and dialogs open.',
          onChanged: (v) {
            setState(() => _animConfig = _animConfig.copyWith(
                  panelEntrance: v,
                ));
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
            padding: EdgeInsets.only(bottom: i < _backdropConfig.lines.length - 1 ? 8 : 0),
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
          icon: _migrating
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
          icon: _clearingCache
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

  final _nsfwControllers =
      List.generate(18, (i) => TextEditingController(text: '20'));

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
          subtitle: _nsfwConfig.enabled
              ? 'Images will be blurred until long-pressed'
              : 'All images shown without filtering',
          onChanged: (v) =>
              setState(() => _nsfwConfig = _nsfwConfig.copyWith(enabled: v)),
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
              padding:
                  EdgeInsets.only(bottom: i < ImNsfwConfig.labels.length - 1 ? 8 : 0),
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
          onChanged: (v) => setState(
              () => _nsfwConfig = _nsfwConfig.copyWith(persistReveal: v)),
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
                    _nsfwControllers[classIndex].text.trim());
                _nsfwConfig.setThreshold(
                    classIndex, pct != null ? pct / 100 : 0.2);
              } else {
                _nsfwConfig.setThreshold(classIndex, null);
              }
              setState(() {});
            },
            fillColor: WidgetStateProperty.resolveWith((s) =>
                s.contains(WidgetState.selected)
                    ? Colors.pinkAccent
                    : null),
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
      icon: _testing
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
        color: _testSuccess
            ? Colors.green.withValues(alpha: 0.15)
            : Colors.red.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: _testSuccess
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
      icon: _saving
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
