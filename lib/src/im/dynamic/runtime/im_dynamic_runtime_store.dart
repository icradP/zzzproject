import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/im_dynamic_models.dart';
import 'im_dynamic_runtime.dart';

/// Persistence boundary for Dynamic Runtime snapshots.
///
/// Runtime state is local application state. Keeping persistence behind this
/// interface lets the shared runtime stay independent from SQLite,
/// SharedPreferences, or a platform-specific storage implementation.
abstract interface class ImDynamicRuntimeSnapshotPersistence {
  Future<Iterable<ImDynamicRuntimeSnapshot>> load();

  Future<void> save(ImDynamicRuntimeSnapshot snapshot);

  Future<void> removeMessage(String messageId);

  Future<void> removeContent(String messageId, String contentId);
}

/// Keeps one runtime per message/content pair and restores its state when a
/// message is rendered again. The persisted schema remains authoritative:
/// snapshots contribute state, while the current message supplies content.
class ImDynamicRuntimeStore extends ChangeNotifier {
  ImDynamicRuntimeStore({this.persistence});

  final ImDynamicRuntimeSnapshotPersistence? persistence;
  final Map<String, ImDynamicRuntime> _runtimes = {};
  final Map<String, ImDynamicRuntimeSnapshot> _snapshots = {};
  Future<void> _persistenceQueue = Future<void>.value();
  Future<void>? _initialization;
  bool _disposed = false;

  /// Loads persisted state before the first message view is built.
  ///
  /// Calling this more than once is safe and shares the same in-flight work.
  Future<void> initialize() => _initialization ??= _loadSnapshots();

  Future<void> _loadSnapshots() async {
    final source = persistence;
    if (source == null) return;
    try {
      final snapshots = await source.load();
      for (final snapshot in snapshots) {
        if (snapshot.messageId.trim().isEmpty ||
            snapshot.content.id.trim().isEmpty) {
          continue;
        }
        final key = _key(snapshot.messageId, snapshot.content.id);
        _snapshots[key] = snapshot;
        // A host app may render before async persistence finishes. Converge
        // any lazily-created runtime to the restored snapshot once it arrives.
        final runtime = _runtimes[key];
        if (runtime != null) {
          try {
            runtime.restore(snapshot);
          } on Object {
            // Keep a live runtime usable if a stale snapshot cannot apply.
          }
        }
      }
    } on Object {
      // Corrupt local runtime state must not prevent messages from rendering.
    }
  }

  /// Returns the runtime for a message/content pair, creating it lazily.
  ///
  /// The current content is always synchronized after restoring a snapshot,
  /// so a server-side schema update cannot be replaced by stale local data.
  ImDynamicRuntime runtimeFor({
    required String messageId,
    required ImDynamicContent content,
  }) {
    final key = _key(messageId, content.id);
    final existing = _runtimes[key];
    if (existing != null) {
      if (existing.content.id == content.id) {
        existing.synchronizeContent(content);
      }
      return existing;
    }

    final snapshot = _snapshots[key];
    final runtime =
        snapshot == null
            ? ImDynamicRuntime(content: content)
            : ImDynamicRuntime.fromSnapshot(snapshot);
    runtime.synchronizeContent(content);
    _runtimes[key] = runtime;
    runtime.addListener(() => _runtimeChanged(key));
    return runtime;
  }

  ImDynamicRuntime? find({
    required String messageId,
    required String contentId,
  }) => _runtimes[_key(messageId, contentId)];

  /// Seeds state received from a persistence layer or a test fixture.
  void restoreSnapshots(Iterable<ImDynamicRuntimeSnapshot> snapshots) {
    for (final snapshot in snapshots) {
      if (snapshot.messageId.trim().isEmpty ||
          snapshot.content.id.trim().isEmpty) {
        continue;
      }
      _snapshots[_key(snapshot.messageId, snapshot.content.id)] = snapshot;
    }
  }

  List<ImDynamicRuntimeSnapshot> get snapshots =>
      List.unmodifiable(_snapshots.values);

  Future<void> clearMessage(String messageId) async {
    final prefix = '$messageId\u0000';
    final runtimeKeys =
        _runtimes.keys.where((key) => key.startsWith(prefix)).toList();
    for (final key in runtimeKeys) {
      _runtimes.remove(key)?.dispose();
    }
    _snapshots.removeWhere((key, _) => key.startsWith(prefix));
    final source = persistence;
    if (source != null) {
      await _enqueuePersistence(() => source.removeMessage(messageId));
    }
    if (runtimeKeys.isNotEmpty && !_disposed) notifyListeners();
  }

  Future<void> clearContent({
    required String messageId,
    required String contentId,
  }) async {
    final key = _key(messageId, contentId);
    final removedRuntime = _runtimes.remove(key);
    removedRuntime?.dispose();
    final removedSnapshot = _snapshots.remove(key);
    final source = persistence;
    if (source != null) {
      await _enqueuePersistence(
        () => source.removeContent(messageId, contentId),
      );
    }
    if ((removedRuntime != null || removedSnapshot != null) && !_disposed) {
      notifyListeners();
    }
  }

  /// Waits until all persistence writes queued so far have finished.
  Future<void> flush() => _persistenceQueue;

  void _runtimeChanged(String key) {
    if (_disposed) return;
    final runtime = _runtimes[key];
    if (runtime == null) return;
    final separator = key.indexOf('\u0000');
    if (separator < 0) return;
    final messageId = key.substring(0, separator);
    final snapshot = runtime.snapshot(messageId: messageId);
    _snapshots[key] = snapshot;
    final source = persistence;
    if (source != null) {
      unawaited(_enqueuePersistence(() => source.save(snapshot)));
    }
    notifyListeners();
  }

  Future<void> _enqueuePersistence(Future<void> Function() operation) {
    _persistenceQueue = _persistenceQueue.then((_) async {
      try {
        await operation();
      } on Object {
        // Runtime persistence is best effort and must not break interaction.
      }
    });
    return _persistenceQueue;
  }

  static String _key(String messageId, String contentId) =>
      '$messageId\u0000$contentId';

  @override
  void dispose() {
    _disposed = true;
    for (final runtime in _runtimes.values) {
      runtime.dispose();
    }
    _runtimes.clear();
    super.dispose();
  }
}
