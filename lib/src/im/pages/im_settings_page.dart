import 'package:flutter/material.dart';
import 'package:onebot_flutter/onebot_flutter.dart' show OneBotClient;

import '../../theme/zzz_colors.dart';
import '../../widgets/zzz_widgets.dart';
import '../adapters/nonebot/nonebot_models.dart';
import '../data/im_connection_config.dart';

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
  bool _saving = false;
  bool _testing = false;
  String? _testResult;
  bool _testSuccess = false;
  bool _loaded = false;
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
    _bgController.dispose();
    super.dispose();
  }

  Future<void> _loadConfig() async {
    final config = await ImConnectionConfig.loadOrDefault();
    setState(() {
      _platform = config.platform;
      _wsMode = config.wsMode;
      _httpController.text = config.httpEndpoint ?? '';
      _wsController.text = config.wsEndpoint ?? '';
      _tokenController.text = config.accessToken ?? '';
      _selfIdController.text = config.selfId;
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
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Settings saved. Restart the app to apply changes.'),
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

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
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
                    constraints: const BoxConstraints(maxWidth: 520),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _buildHeader(),
                        const SizedBox(height: 24),
                        _buildPlatformSelector(),
                        if (_platform == ImPlatform.nonebot) ...[
                          const SizedBox(height: 24),
                          _buildNoneBotFields(),
                        ],
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
          'IM Connection Settings',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
        ),
      ],
    );
  }

  Widget _buildPlatformSelector() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Platform',
          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.white54),
        ),
        const SizedBox(height: 8),
        ZzzSegmentedControl<ImPlatform>(
          items: _platformItems,
          value: _platform,
          onChanged: (value) => setState(() => _platform = value),
        ),
      ],
    );
  }

  Widget _buildNoneBotFields() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _SectionLabel('NoneBot / OneBot Connection'),
        const SizedBox(height: 12),
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
        _buildWsModeSelector(),
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
    );
  }

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

  Widget _buildWsModeSelector() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'WebSocket mode',
          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.white54),
        ),
        const SizedBox(height: 8),
        ZzzSegmentedControl<OneBotWsMode>(
          items: _wsModeItems,
          value: _wsMode,
          onChanged: (value) => setState(() => _wsMode = value),
        ),
      ],
    );
  }

  Widget _buildSaveButton() {
    return FilledButton.icon(
      onPressed: _saving ? null : _save,
      icon: _saving
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
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

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.white38),
    );
  }
}
