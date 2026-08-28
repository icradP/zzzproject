import 'package:flutter/material.dart';

import '../../assets/app_assets.dart';
import '../../theme/zzz_colors.dart';
import '../../widgets/zzz_widgets.dart';
import '../adapters/zzz_server/zzz_server_source.dart';
import '../data/im_connection_config.dart';

class ImWebSetupPage extends StatefulWidget {
  const ImWebSetupPage({required this.onConfigured, super.key});

  final Future<void> Function(ImConnectionConfig config) onConfigured;

  @override
  State<ImWebSetupPage> createState() => _ImWebSetupPageState();
}

class _ImWebSetupPageState extends State<ImWebSetupPage> {
  final _serverController = TextEditingController();
  final _userController = TextEditingController();
  final _tokenController = TextEditingController();
  bool _connecting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _serverController.text = const String.fromEnvironment(
      'ZZZ_SERVER_URL',
      defaultValue: 'ws://localhost:8080/ws',
    );
  }

  @override
  void dispose() {
    _serverController.dispose();
    _userController.dispose();
    _tokenController.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    final serverUrl = _serverController.text.trim();
    final userId = _userController.text.trim();
    final token = _tokenController.text.trim();
    if (serverUrl.isEmpty || userId.isEmpty || token.isEmpty) {
      setState(() => _error = 'Server URL, user ID and token are required.');
      return;
    }

    setState(() {
      _connecting = true;
      _error = null;
    });
    final config = ImConnectionConfig(
      platform: ImPlatform.zzzServer,
      serverUrl: serverUrl,
      selfId: userId,
      accessToken: token,
    );
    final probe = ZzzServerSource(
      config: ZzzServerConfig(
        serverUrl: serverUrl,
        selfId: userId,
        authToken: token,
      ),
      allowReconnect: false,
    );
    try {
      final error = await probe.testConnection();
      if (error != null) throw StateError(error);
      await config.save();
      await widget.onConfigured(config);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      probe.disconnect();
      if (mounted) setState(() => _connecting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          const DecoratedBox(
            decoration: BoxDecoration(
              image: DecorationImage(
                image: AssetImage(AppAssets.bgChatWithPatternDark2),
                fit: BoxFit.cover,
                opacity: 0.18,
              ),
            ),
          ),
          SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 430),
                  child: ZzzPanel(
                    animateEntrance: true,
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            children: [
                              Container(
                                width: 42,
                                height: 42,
                                decoration: const BoxDecoration(
                                  color: ZzzColors.yellow,
                                  shape: BoxShape.circle,
                                ),
                                child: const Icon(
                                  Icons.forum_rounded,
                                  color: Colors.black,
                                ),
                              ),
                              const SizedBox(width: 12),
                              const Expanded(
                                child: Text(
                                  'ZZZ IM',
                                  style: TextStyle(
                                    fontSize: 22,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 24),
                          ZzzTextInput(
                            controller: _serverController,
                            hintText: 'wss://im.example.com/ws',
                            prefixIcon: const Icon(Icons.dns_outlined),
                            fillColor: Colors.white.withValues(alpha: 0.06),
                            foregroundColor: Colors.white,
                          ),
                          const SizedBox(height: 12),
                          ZzzTextInput(
                            controller: _userController,
                            hintText: 'User ID',
                            prefixIcon: const Icon(Icons.person_outline),
                            fillColor: Colors.white.withValues(alpha: 0.06),
                            foregroundColor: Colors.white,
                          ),
                          const SizedBox(height: 12),
                          ZzzTextInput(
                            controller: _tokenController,
                            hintText: 'Access token',
                            obscureText: true,
                            prefixIcon: const Icon(Icons.key_outlined),
                            fillColor: Colors.white.withValues(alpha: 0.06),
                            foregroundColor: Colors.white,
                            onSubmitted: (_) => _connect(),
                          ),
                          if (_error != null) ...[
                            const SizedBox(height: 12),
                            Text(
                              _error!,
                              style: const TextStyle(color: ZzzColors.red),
                            ),
                          ],
                          const SizedBox(height: 18),
                          FilledButton.icon(
                            onPressed: _connecting ? null : _connect,
                            icon:
                                _connecting
                                    ? const SizedBox.square(
                                      dimension: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                    : const Icon(Icons.login_rounded),
                            label: const Text('Connect'),
                          ),
                        ],
                      ),
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
}
