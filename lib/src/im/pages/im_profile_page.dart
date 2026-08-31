import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../assets/app_assets.dart';
import '../../widgets/zzz_widgets.dart';
import '../im_scope.dart';
import '../models/im_models.dart';

class ImProfilePage extends StatefulWidget {
  const ImProfilePage({super.key});

  @override
  State<ImProfilePage> createState() => _ImProfilePageState();
}

class _ImProfilePageState extends State<ImProfilePage> {
  ImUser? _user;
  Uint8List? _avatarBytes;
  String? _avatarName;
  String? _avatarMime;
  late final TextEditingController _nicknameController;
  bool _loading = true;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _nicknameController = TextEditingController();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _nicknameController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final user = await ImScope.repositoryOf(context).getCurrentUser();
      if (!mounted) return;
      setState(() {
        _user = user;
        _nicknameController.text = user.displayName;
        _loading = false;
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '$error';
        });
      }
    }
  }

  Future<void> _pickAvatar() async {
    final result = await FilePicker.pickFiles(
      type: FileType.image,
      withData: true,
      allowMultiple: false,
    );
    final file = result?.files.single;
    if (file == null || file.bytes == null) return;
    if (file.bytes!.length > 5 * 1024 * 1024) {
      setState(() => _error = 'Avatar must be 5 MB or smaller.');
      return;
    }
    setState(() {
      _avatarBytes = file.bytes;
      _avatarName = file.name;
      _avatarMime = file.extension == null ? null : 'image/${file.extension}';
      _error = null;
    });
  }

  Future<void> _save() async {
    final nickname = _nicknameController.text.trim();
    if (nickname.isEmpty || nickname.length > 64) {
      setState(() => _error = 'Nickname must be 1-64 characters.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final user = await ImScope.repositoryOf(context).updateProfile(
        nickname: nickname,
        avatar:
            _avatarBytes == null
                ? null
                : ImMediaUpload(
                  kind: ImMessageKind.image,
                  fileName: _avatarName ?? 'avatar.jpg',
                  bytes: _avatarBytes,
                  mimeType: _avatarMime,
                ),
      );
      if (!mounted) return;
      setState(() {
        _user = user;
        _avatarBytes = null;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Profile updated.')));
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = _user;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(title: const Text('Personal profile')),
      body:
          _loading
              ? const Center(child: CircularProgressIndicator())
              : SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 520),
                    child: ZzzPanel(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Center(
                            child: Stack(
                              children: [
                                _avatarBytes != null
                                    ? ZzzAvatar(
                                      image: MemoryImage(_avatarBytes!),
                                      size: 96,
                                    )
                                    : ZzzAvatar(
                                      image:
                                          user?.avatarImage(
                                            AppAssets.characterWise,
                                          ) ??
                                          const AssetImage(
                                            AppAssets.characterWise,
                                          ),
                                      size: 96,
                                    ),
                                Positioned(
                                  right: 0,
                                  bottom: 0,
                                  child: IconButton.filled(
                                    tooltip: 'Choose avatar',
                                    onPressed: _saving ? null : _pickAvatar,
                                    icon: const Icon(Icons.camera_alt_outlined),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 24),
                          ZzzTextInput(
                            controller: _nicknameController,
                            hintText: 'Nickname',
                            prefixIcon: const Icon(Icons.badge_outlined),
                            fillColor: Colors.white.withValues(alpha: 0.06),
                            foregroundColor: Colors.white,
                          ),
                          const SizedBox(height: 12),
                          if (user != null)
                            Text(
                              'Account ID  ${user.id}',
                              style: const TextStyle(color: Colors.white54),
                            ),
                          if (_error != null) ...[
                            const SizedBox(height: 12),
                            Text(
                              _error!,
                              style: const TextStyle(color: Colors.redAccent),
                            ),
                          ],
                          const SizedBox(height: 20),
                          FilledButton.icon(
                            onPressed: _saving ? null : _save,
                            icon:
                                _saving
                                    ? const SizedBox.square(
                                      dimension: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                    : const Icon(Icons.save_outlined),
                            label: const Text('Save profile'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
    );
  }
}
