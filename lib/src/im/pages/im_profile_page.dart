import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';

import '../../assets/app_assets.dart';
import '../../widgets/zzz_widgets.dart';
import '../im_scope.dart';
import '../models/im_models.dart';
import '../widgets/im_profile_card_panel.dart';

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
  Uint8List? _backgroundBytes;
  String? _backgroundName;
  String? _backgroundMime;
  late final TextEditingController _nicknameController;
  late final TextEditingController _bioController;
  late final TextEditingController _backgroundController;
  late final TextEditingController _backgroundColorController;
  bool _backgroundSensitive = false;
  bool _showMutualGroups = true;
  bool _showAccountId = true;
  bool _loading = true;
  bool _saving = false;
  bool _signingOut = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _nicknameController = TextEditingController();
    _bioController = TextEditingController();
    _backgroundController = TextEditingController();
    _backgroundColorController = TextEditingController();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _nicknameController.dispose();
    _bioController.dispose();
    _backgroundController.dispose();
    _backgroundColorController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final repository = ImScope.repositoryOf(context);
      final current = await repository.getCurrentUser();
      final user = await repository.getProfileCard(current.id) ?? current;
      if (!mounted) return;
      setState(() {
        _user = user;
        _nicknameController.text = user.displayName;
        _bioController.text = user.bio;
        _backgroundController.text = user.cardBackgroundUrl ?? '';
        _backgroundColorController.text = user.cardBackgroundColor ?? '';
        _backgroundSensitive = user.cardBackgroundSensitive;
        _showMutualGroups = user.showMutualGroups;
        _showAccountId = user.showAccountId;
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

  Future<void> _pickBackground() async {
    final result = await FilePicker.pickFiles(
      type: FileType.image,
      withData: true,
      allowMultiple: false,
    );
    final file = result?.files.single;
    if (file == null || file.bytes == null) return;
    if (file.bytes!.length > 20 * 1024 * 1024) {
      setState(() => _error = 'Card background must be 20 MB or smaller.');
      return;
    }
    setState(() {
      _backgroundBytes = file.bytes;
      _backgroundName = file.name;
      _backgroundMime =
          file.extension == null
              ? null
              : 'image/${file.extension!.toLowerCase()}';
      _backgroundController.clear();
      _backgroundColorController.clear();
      _error = null;
    });
  }

  void _clearSelectedBackground() {
    setState(() {
      _backgroundBytes = null;
      _backgroundName = null;
      _backgroundMime = null;
    });
  }

  Future<void> _pickBackgroundColor() async {
    var selectedColor =
        _parseHexColor(_backgroundColorController.text) ??
        const Color(0xFF17191D);
    final result = await showZzzModalPanel<String>(
      context: context,
      builder:
          (dialogContext) => StatefulBuilder(
            builder: (context, setPanelState) {
              final pickerWidth =
                  (MediaQuery.sizeOf(dialogContext).width - 72)
                      .clamp(220.0, 360.0)
                      .toDouble();
              return ZzzModalPanel(
                key: const ValueKey('background-color-picker-panel'),
                title: 'Solid background color',
                icon: Icons.palette_outlined,
                maxWidth: 460,
                maxHeight: 620,
                actions: [
                  TextButton(
                    key: const ValueKey('clear-background-color'),
                    onPressed: () => Navigator.of(dialogContext).pop(''),
                    child: const Text('Clear'),
                  ),
                  TextButton(
                    onPressed: () => Navigator.of(dialogContext).pop(),
                    child: const Text('Cancel'),
                  ),
                  FilledButton.icon(
                    key: const ValueKey('apply-background-color'),
                    onPressed:
                        () => Navigator.of(
                          dialogContext,
                        ).pop(_colorToHex(selectedColor)),
                    icon: const Icon(Icons.check_rounded),
                    label: const Text('Apply'),
                  ),
                ],
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(20),
                  child: Center(
                    child: ColorPicker(
                      key: const ValueKey('background-color-picker'),
                      pickerColor: selectedColor,
                      onColorChanged:
                          (color) => setPanelState(() => selectedColor = color),
                      paletteType: PaletteType.hsvWithHue,
                      enableAlpha: false,
                      displayThumbColor: true,
                      labelTypes: const [],
                      portraitOnly: true,
                      hexInputBar: true,
                      colorPickerWidth: pickerWidth,
                      pickerAreaHeightPercent: 0.72,
                      pickerAreaBorderRadius: BorderRadius.circular(6),
                    ),
                  ),
                ),
              );
            },
          ),
    );
    if (result == null || !mounted) return;
    setState(() {
      _backgroundColorController.text = result;
      if (result.isNotEmpty) {
        _backgroundController.clear();
        _backgroundBytes = null;
        _backgroundName = null;
        _backgroundMime = null;
      }
      _error = null;
    });
  }

  Future<void> _save() async {
    final nickname = _nicknameController.text.trim();
    if (nickname.isEmpty || nickname.length > 64) {
      setState(() => _error = 'Nickname must be 1-64 characters.');
      return;
    }
    final background = _backgroundController.text.trim();
    final backgroundColor = _backgroundColorController.text.trim();
    final backgroundUri = background.isEmpty ? null : Uri.tryParse(background);
    if (_backgroundBytes == null &&
        backgroundUri != null &&
        (backgroundUri.scheme != 'https' || backgroundUri.host.isEmpty)) {
      setState(() => _error = 'Card background must be an HTTPS image URL.');
      return;
    }
    if (backgroundColor.isNotEmpty &&
        !RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(backgroundColor)) {
      setState(() => _error = 'Background color must use #RRGGBB.');
      return;
    }
    if (_bioController.text.trim().characters.length > 280) {
      setState(() => _error = 'Bio must not exceed 280 characters.');
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
        bio: _bioController.text.trim(),
        cardBackground:
            _backgroundBytes == null
                ? null
                : ImMediaUpload(
                  kind: ImMessageKind.image,
                  fileName: _backgroundName ?? 'card-background.jpg',
                  bytes: _backgroundBytes,
                  mimeType: _backgroundMime,
                ),
        cardBackgroundUrl: background,
        cardBackgroundColor: backgroundColor.toUpperCase(),
        cardBackgroundSensitive: _backgroundSensitive,
        showMutualGroups: _showMutualGroups,
        showAccountId: _showAccountId,
      );
      if (!mounted) return;
      setState(() {
        _user = user;
        _avatarBytes = null;
        _avatarName = null;
        _avatarMime = null;
        _backgroundBytes = null;
        _backgroundName = null;
        _backgroundMime = null;
        _backgroundController.text = user.cardBackgroundUrl ?? '';
        _backgroundColorController.text = user.cardBackgroundColor ?? '';
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
                    constraints: const BoxConstraints(maxWidth: 680),
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
                          ZzzTextInput(
                            controller: _bioController,
                            hintText: 'Bio',
                            minLines: 3,
                            maxLines: 5,
                            maxLength: 280,
                            prefixIcon: const Icon(Icons.notes_rounded),
                            fillColor: Colors.white.withValues(alpha: 0.06),
                            foregroundColor: Colors.white,
                          ),
                          const SizedBox(height: 12),
                          ZzzTextInput(
                            controller: _backgroundController,
                            hintText: 'Card background HTTPS URL',
                            prefixIcon: const Icon(Icons.image_outlined),
                            fillColor: Colors.white.withValues(alpha: 0.06),
                            foregroundColor: Colors.white,
                            onChanged: (_) {
                              if (_backgroundBytes != null) {
                                _backgroundBytes = null;
                                _backgroundName = null;
                                _backgroundMime = null;
                              }
                              _backgroundColorController.clear();
                              setState(() {});
                            },
                          ),
                          const SizedBox(height: 10),
                          Row(
                            children: [
                              Expanded(
                                child: OutlinedButton.icon(
                                  key: const Key('upload-card-background'),
                                  onPressed: _saving ? null : _pickBackground,
                                  icon: const Icon(Icons.cloud_upload_outlined),
                                  label: Text(
                                    _backgroundName ?? 'Upload image',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ),
                              if (_backgroundBytes != null) ...[
                                const SizedBox(width: 6),
                                IconButton(
                                  tooltip: 'Cancel selected background',
                                  onPressed:
                                      _saving ? null : _clearSelectedBackground,
                                  icon: const Icon(Icons.close_rounded),
                                ),
                              ],
                            ],
                          ),
                          const SizedBox(height: 10),
                          _buildBackgroundColorButton(),
                          const SizedBox(height: 10),
                          _buildBackgroundPreview(),
                          const SizedBox(height: 6),
                          Material(
                            color: Colors.transparent,
                            child: SwitchListTile(
                              contentPadding: EdgeInsets.zero,
                              value: _backgroundSensitive,
                              onChanged:
                                  _saving
                                      ? null
                                      : (value) => setState(
                                        () => _backgroundSensitive = value,
                                      ),
                              secondary: const Icon(
                                Icons.visibility_off_outlined,
                              ),
                              title: const Text('Sensitive background'),
                            ),
                          ),
                          Material(
                            color: Colors.transparent,
                            child: SwitchListTile(
                              contentPadding: EdgeInsets.zero,
                              value: _showMutualGroups,
                              onChanged:
                                  _saving
                                      ? null
                                      : (value) => setState(
                                        () => _showMutualGroups = value,
                                      ),
                              secondary: const Icon(Icons.groups_outlined),
                              title: const Text('Show mutual groups'),
                            ),
                          ),
                          Material(
                            color: Colors.transparent,
                            child: SwitchListTile(
                              key: const Key('show-account-id'),
                              contentPadding: EdgeInsets.zero,
                              value: _showAccountId,
                              onChanged:
                                  _saving
                                      ? null
                                      : (value) => setState(
                                        () => _showAccountId = value,
                                      ),
                              secondary: const Icon(Icons.fingerprint_rounded),
                              title: const Text('Show account ID on my card'),
                            ),
                          ),
                          if (user?.titles.isNotEmpty ?? false) ...[
                            const SizedBox(height: 8),
                            const Text(
                              'Titles',
                              style: TextStyle(fontWeight: FontWeight.w700),
                            ),
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: user!.titles
                                  .map((title) => ImTitleBadge(title: title))
                                  .toList(growable: false),
                            ),
                          ],
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

  Widget _buildBackgroundPreview() {
    final selectedBytes = _backgroundBytes;
    final raw = _backgroundController.text.trim();
    final uri = Uri.tryParse(raw);
    final valid = uri != null && uri.scheme == 'https' && uri.host.isNotEmpty;
    final solidColor = _parseHexColor(_backgroundColorController.text);
    return AspectRatio(
      aspectRatio: 16 / 6,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child:
            selectedBytes != null
                ? Image.memory(selectedBytes, fit: BoxFit.cover)
                : valid
                ? Image.network(
                  raw,
                  fit: BoxFit.cover,
                  errorBuilder:
                      (_, __, ___) =>
                          _backgroundPlaceholder(Icons.broken_image_outlined),
                )
                : solidColor != null
                ? ColoredBox(color: solidColor)
                : _backgroundPlaceholder(Icons.image_outlined),
      ),
    );
  }

  Widget _buildBackgroundColorButton() {
    final color = _parseHexColor(_backgroundColorController.text);
    return OutlinedButton(
      key: const ValueKey('card-background-color-picker'),
      onPressed: _saving ? null : _pickBackgroundColor,
      style: OutlinedButton.styleFrom(
        minimumSize: const Size.fromHeight(48),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      ),
      child: Row(
        children: [
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: color ?? const Color(0xFF17191D),
              borderRadius: BorderRadius.circular(5),
              border: Border.all(color: Colors.white24),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              color == null
                  ? 'Choose solid color'
                  : _backgroundColorController.text.toUpperCase(),
              textAlign: TextAlign.left,
            ),
          ),
          const Icon(Icons.palette_outlined, size: 20),
        ],
      ),
    );
  }

  Color? _parseHexColor(String raw) {
    final value = raw.trim();
    if (!RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(value)) return null;
    return Color(int.parse('FF${value.substring(1)}', radix: 16));
  }

  String _colorToHex(Color color) {
    final rgb = color.toARGB32() & 0xFFFFFF;
    return '#${rgb.toRadixString(16).padLeft(6, '0').toUpperCase()}';
  }

  Widget _backgroundPlaceholder(IconData icon) => ColoredBox(
    color: Colors.white.withValues(alpha: 0.04),
    child: Center(child: Icon(icon, color: Colors.white30, size: 34)),
  );
}
