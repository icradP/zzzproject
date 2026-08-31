import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
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
  String? _selectedAvatarAsset;
  late final TextEditingController _nicknameController;
  bool _loading = true;
  bool _saving = false;
  bool _signingOut = false;
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
        _selectedAvatarAsset =
            AppAssets.avatarPool.contains(user.avatarAssetPath)
                ? user.avatarAssetPath
                : null;
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
      _selectedAvatarAsset = null;
      _error = null;
    });
  }

  void _selectAvatar(String assetPath) {
    setState(() {
      _selectedAvatarAsset = assetPath;
      _avatarBytes = null;
      _avatarName = null;
      _avatarMime = null;
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
        avatarAssetPath: _selectedAvatarAsset,
      );
      if (!mounted) return;
      setState(() {
        _user = user;
        _avatarBytes = null;
        _avatarName = null;
        _avatarMime = null;
        _selectedAvatarAsset =
            AppAssets.avatarPool.contains(user.avatarAssetPath)
                ? user.avatarAssetPath
                : null;
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

  Future<void> _signOut() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (context) => AlertDialog(
            title: const Text('Sign out?'),
            content: const Text(
              'This device will return to the account login page.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Sign out'),
              ),
            ],
          ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _signingOut = true);
    await ImScope.signOut(context);
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
                            child: ZzzAvatar(
                              image:
                                  _avatarBytes != null
                                      ? MemoryImage(_avatarBytes!)
                                      : _selectedAvatarAsset != null
                                      ? AssetImage(_selectedAvatarAsset!)
                                      : user?.avatarImage(
                                            AppAssets.characterWise,
                                          ) ??
                                          const AssetImage(
                                            AppAssets.characterWise,
                                          ),
                              size: 96,
                            ),
                          ),
                          const SizedBox(height: 20),
                          const Text(
                            'Avatar',
                            style: TextStyle(fontWeight: FontWeight.w700),
                          ),
                          const SizedBox(height: 10),
                          LayoutBuilder(
                            builder: (context, constraints) {
                              final columnCount = (constraints.maxWidth / 72)
                                  .floor()
                                  .clamp(3, 7);
                              return GridView.builder(
                                shrinkWrap: true,
                                physics: const NeverScrollableScrollPhysics(),
                                itemCount: AppAssets.avatarPool.length,
                                gridDelegate:
                                    SliverGridDelegateWithFixedCrossAxisCount(
                                      crossAxisCount: columnCount,
                                      crossAxisSpacing: 10,
                                      mainAxisSpacing: 10,
                                    ),
                                itemBuilder: (context, index) {
                                  final asset = AppAssets.avatarPool[index];
                                  final selected =
                                      _selectedAvatarAsset == asset;
                                  return Semantics(
                                    label: 'Built-in avatar ${index + 1}',
                                    selected: selected,
                                    button: true,
                                    child: InkWell(
                                      key: ValueKey('avatar-option-$index'),
                                      customBorder: const CircleBorder(),
                                      onTap:
                                          _saving
                                              ? null
                                              : () => _selectAvatar(asset),
                                      child: Stack(
                                        fit: StackFit.expand,
                                        children: [
                                          DecoratedBox(
                                            decoration: BoxDecoration(
                                              shape: BoxShape.circle,
                                              border: Border.all(
                                                color:
                                                    selected
                                                        ? Theme.of(
                                                          context,
                                                        ).colorScheme.primary
                                                        : Colors.white24,
                                                width: selected ? 3 : 1,
                                              ),
                                            ),
                                            child: Padding(
                                              padding: const EdgeInsets.all(3),
                                              child: ClipOval(
                                                child: Image.asset(
                                                  asset,
                                                  fit: BoxFit.cover,
                                                ),
                                              ),
                                            ),
                                          ),
                                          if (selected)
                                            const Align(
                                              alignment: Alignment.topRight,
                                              child: CircleAvatar(
                                                radius: 10,
                                                child: Icon(
                                                  Icons.check_rounded,
                                                  size: 14,
                                                ),
                                              ),
                                            ),
                                        ],
                                      ),
                                    ),
                                  );
                                },
                              );
                            },
                          ),
                          const SizedBox(height: 12),
                          OutlinedButton.icon(
                            onPressed: _saving ? null : _pickAvatar,
                            icon: const Icon(Icons.upload_rounded),
                            label: Text(
                              _avatarBytes == null
                                  ? 'Upload image'
                                  : _avatarName ?? 'Image selected',
                            ),
                          ),
                          const SizedBox(height: 20),
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
                          if (kIsWeb) ...[
                            const SizedBox(height: 12),
                            OutlinedButton.icon(
                              onPressed:
                                  _saving || _signingOut ? null : _signOut,
                              icon:
                                  _signingOut
                                      ? const SizedBox.square(
                                        dimension: 18,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      )
                                      : const Icon(Icons.logout_rounded),
                              label: const Text('Sign out'),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
    );
  }
}
