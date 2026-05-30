import 'package:shared_preferences/shared_preferences.dart';

/// Abstract interface for NSFW image detection.
///
/// Pluggable: switch between local ONNX inference, a remote API, or a no-op
/// stub without changing any UI code.
abstract class ImNsfwChecker {
  /// Whether this checker is initialised and ready to use.
  bool get isAvailable;

  /// One-time setup (load model, warm up, etc.).
  Future<void> initialize();

  /// Returns `true` if the image at [imagePath] is NSFW, `false` if safe,
  /// or `null` when the check could not be completed.
  Future<bool?> check(String imagePath);

  /// Release resources.
  void dispose();
}

/// Per-message NSFW state (not persisted — ephemeral UI state).
class NsfwState {
  const NsfwState({required this.checked, this.nsfw, this.revealed = false});

  /// Whether this image has been checked yet.
  final bool checked;

  /// `true` = NSFW, `false` = safe, `null` = check failed / not done.
  final bool? nsfw;

  /// Whether the user has tapped to reveal a blurred image.
  final bool revealed;

  NsfwState copyWith({bool? checked, bool? nsfw, bool? revealed}) {
    return NsfwState(
      checked: checked ?? this.checked,
      nsfw: nsfw ?? this.nsfw,
      revealed: revealed ?? this.revealed,
    );
  }

  static const unchecked = NsfwState(checked: false);
}

/// In-memory cache of [NsfwState] keyed by message id.
///
/// When [ImNsfwConfig.persistReveal] is true, revealed message IDs are saved
/// to shared preferences so images stay unblurred across sessions.
class NsfwStateCache {
  final _states = <String, NsfwState>{};
  bool _persistLoaded = false;

  static const _revealedKey = 'im_nsfw_revealed_ids';

  NsfwState get(String messageId) => _states[messageId] ?? NsfwState.unchecked;

  void put(String messageId, NsfwState state) {
    _states[messageId] = state;
    if (state.revealed) _saveRevealedIds();
  }

  void remove(String messageId) => _states.remove(messageId);

  void clear() => _states.clear();

  // -- reveal persistence --------------------------------------------------

  Future<void> loadRevealed() async {
    if (_persistLoaded) return;
    _persistLoaded = true;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_revealedKey);
    if (raw == null || raw.isEmpty) return;
    for (final id in raw) {
      _states[id] = const NsfwState(
          checked: true, nsfw: true, revealed: true);
    }
  }

  void _saveRevealedIds() {
    final revealed = _states.entries
        .where((e) => e.value.revealed)
        .map((e) => e.key)
        .toList();
    SharedPreferences.getInstance().then((prefs) {
      prefs.setStringList(_revealedKey, revealed);
    });
  }
}
