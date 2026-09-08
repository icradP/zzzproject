import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../dynamic/runtime/im_dynamic_runtime.dart';
import '../dynamic/runtime/im_dynamic_runtime_store.dart';

/// SharedPreferences-backed persistence for local Dynamic Runtime state.
///
/// The payload is deliberately bounded and stores only the local runtime
/// snapshot. Credentials and server session data never enter this store.
class ImDynamicRuntimePreferencesPersistence
    implements ImDynamicRuntimeSnapshotPersistence {
  ImDynamicRuntimePreferencesPersistence({
    this.storageKey = _defaultStorageKey,
  });

  static const _defaultStorageKey = 'zzz.im.dynamic-runtime.v1';
  static const _maxSnapshots = 256;
  static const _maxEncodedBytes = 1024 * 1024;

  final String storageKey;
  SharedPreferences? _preferences;
  final Map<String, ImDynamicRuntimeSnapshot> _documents = {};
  Future<void>? _loadFuture;

  Future<SharedPreferences> _preferencesInstance() async {
    return _preferences ??= await SharedPreferences.getInstance();
  }

  @override
  Future<Iterable<ImDynamicRuntimeSnapshot>> load() async {
    if (_loadFuture != null) await _loadFuture;
    _loadFuture = _loadDocuments();
    await _loadFuture;
    return List.unmodifiable(_documents.values);
  }

  Future<void> _loadDocuments() async {
    final preferences = await _preferencesInstance();
    final encoded = preferences.getString(storageKey);
    if (encoded == null || encoded.isEmpty) return;
    try {
      final decoded = jsonDecode(encoded);
      if (decoded is! List) return;
      for (final raw in decoded) {
        if (raw is! Map) continue;
        try {
          final snapshot = ImDynamicRuntimeSnapshot.fromJson(
            Map<String, dynamic>.from(raw),
          );
          _documents[_documentKey(snapshot)] = snapshot;
        } on Object {
          // Ignore one malformed snapshot while keeping the others usable.
        }
      }
    } on Object {
      _documents.clear();
    }
  }

  @override
  Future<void> save(ImDynamicRuntimeSnapshot snapshot) async {
    _loadFuture ??= _loadDocuments();
    await _loadFuture;
    _documents[_documentKey(snapshot)] = snapshot;
    while (_documents.length > _maxSnapshots) {
      _documents.remove(_documents.keys.first);
    }
    await _write();
  }

  @override
  Future<void> removeMessage(String messageId) async {
    _loadFuture ??= _loadDocuments();
    await _loadFuture;
    _documents.removeWhere((_, snapshot) => snapshot.messageId == messageId);
    await _write();
  }

  @override
  Future<void> removeContent(String messageId, String contentId) async {
    _loadFuture ??= _loadDocuments();
    await _loadFuture;
    _documents.remove('$messageId\u0000$contentId');
    await _write();
  }

  Future<void> _write() async {
    final encoded = jsonEncode(
      _documents.values.map((snapshot) => snapshot.toJson()).toList(),
    );
    if (utf8.encode(encoded).length > _maxEncodedBytes) return;
    final preferences = await _preferencesInstance();
    await preferences.setString(storageKey, encoded);
  }

  static String _documentKey(ImDynamicRuntimeSnapshot snapshot) =>
      '${snapshot.messageId}\u0000${snapshot.content.id}';
}
