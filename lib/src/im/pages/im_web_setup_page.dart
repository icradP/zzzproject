import 'package:flutter/material.dart';

import '../../assets/app_assets.dart';
import '../../theme/zzz_colors.dart';
import '../../widgets/zzz_widgets.dart';
import '../adapters/zzz_server/zzz_server_source.dart';
import '../data/im_connection_config.dart';

class ImWebSetupPage extends StatefulWidget {
  const ImWebSetupPage({
    required this.onConfigured,
    this.serverUrl = configuredServerUrl,
    super.key,
  });

  static const configuredServerUrl = String.fromEnvironment(
    'ZZZ_SERVER_URL',
    defaultValue: 'ws://localhost:8080/ws',
  );

  final Future<void> Function(ImConnectionConfig config) onConfigured;
  final String serverUrl;

  @override
  State<ImWebSetupPage> createState() => _ImWebSetupPageState();
}

class _ImWebSetupPageState extends State<ImWebSetupPage> {
  final _userController = TextEditingController();
  final _passwordController = TextEditingController();
  final _inviteController = TextEditingController();
  bool _connecting = false;
  bool _registering = false;
  String? _error;

  @override
  void dispose() {
    _userController.dispose();
    _passwordController.dispose();
    _inviteController.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    final serverUrl = widget.serverUrl.trim();
    final userId = _userController.text.trim();
    final password = _passwordController.text;
    final inviteCode = _inviteController.text.trim();
    if (userId.isEmpty || password.isEmpty) {
      setState(() => _error = 'Username and password are required.');
      return;
    }
    if (_registering && inviteCode.isEmpty) {
      setState(() => _error = 'Invitation code is required.');
      return;
    }
    if (!_isValidServerUrl(serverUrl)) {
      setState(() => _error = 'Service is temporarily unavailable.');
      return;
    }

    setState(() {
      _connecting = true;
      _error = null;
    });
    try {
      final account =
          _registering
              ? await ZzzServerSource.registerAccount(
                serverUrl: serverUrl,
                userId: userId,
                password: password,
                inviteCode: inviteCode,
              )
              : await ZzzServerSource.loginAccount(
                serverUrl: serverUrl,
                userId: userId,
                password: password,
              );
      final config = ImConnectionConfig(
        platform: ImPlatform.zzzServer,
        serverUrl: serverUrl,
        selfId: account.userId,
        accessToken: account.sessionToken,
        extra: const {'authMode': 'session'},
      );
      await widget.onConfigured(config);
    } catch (_) {
      if (mounted) {
        setState(
          () =>
              _error =
                  _registering
                      ? 'Unable to create account. Check the invitation code and account details.'
                      : 'Unable to sign in. Check your credentials and retry.',
        );
      }
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  bool _isValidServerUrl(String value) {
    final uri = Uri.tryParse(value);
    return uri != null &&
        (uri.scheme == 'ws' || uri.scheme == 'wss') &&
        uri.host.isNotEmpty;
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
                            controller: _userController,
                            hintText: 'User ID',
                            prefixIcon: const Icon(Icons.person_outline),
                            fillColor: Colors.white.withValues(alpha: 0.06),
                            foregroundColor: Colors.white,
                          ),
                          const SizedBox(height: 12),
                          ZzzTextInput(
                            controller: _passwordController,
                            hintText: 'Password',
                            obscureText: true,
                            prefixIcon: const Icon(Icons.key_outlined),
                            fillColor: Colors.white.withValues(alpha: 0.06),
                            foregroundColor: Colors.white,
                            onSubmitted:
                                _registering ? null : (_) => _connect(),
                          ),
                          if (_registering) ...[
                            const SizedBox(height: 12),
                            ZzzTextInput(
                              key: const ValueKey('invite-code-field'),
                              controller: _inviteController,
                              hintText: 'Invitation code',
                              obscureText: true,
                              prefixIcon: const Icon(
                                Icons.confirmation_number_outlined,
                              ),
                              fillColor: Colors.white.withValues(alpha: 0.06),
                              foregroundColor: Colors.white,
                              onSubmitted: (_) => _connect(),
                            ),
                          ],
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
                            label: Text(
                              _registering ? 'Create account' : 'Sign in',
                            ),
                          ),
                          const SizedBox(height: 10),
                          TextButton(
                            onPressed:
                                _connecting
                                    ? null
                                    : () => setState(() {
                                      _registering = !_registering;
                                      _error = null;
                                    }),
                            child: Text(
                              _registering
                                  ? 'Already have an account? Sign in'
                                  : 'New here? Create an account',
                            ),
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
