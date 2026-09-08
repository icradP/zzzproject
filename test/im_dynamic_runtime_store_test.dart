import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zzzproject/zzz_im_chat.dart';

void main() {
  const initial = ImDynamicContent(
    id: 'runtime-card',
    version: '1.0',
    source: ImDynamicContentSource.ai,
    tree: ImDynamicNode(id: 'root', type: 'status', props: {'text': 'Working'}),
  );

  test(
    'runtime store restores state and keeps current schema authoritative',
    () {
      final first = ImDynamicRuntimeStore();
      final runtime = first.runtimeFor(
        messageId: 'message-1',
        content: initial,
      );
      runtime.updateState(
        lifecycle: ImDynamicLifecycle.processing,
        values: const {'progress': 0.5},
      );
      final snapshot = first.snapshots.single;

      final second = ImDynamicRuntimeStore()..restoreSnapshots([snapshot]);
      final updated = initial.copyWith(
        tree: const ImDynamicNode(
          id: 'root',
          type: 'status',
          props: {'text': 'Complete'},
        ),
      );
      final restored = second.runtimeFor(
        messageId: 'message-1',
        content: updated,
      );

      expect(restored.state.lifecycle, ImDynamicLifecycle.processing);
      expect(restored.state.values['progress'], 0.5);
      expect(restored.content.tree.props['text'], 'Complete');
      first.dispose();
      second.dispose();
    },
  );

  test('preferences persistence round-trips snapshots', () async {
    SharedPreferences.setMockInitialValues({});
    final persistence = ImDynamicRuntimePreferencesPersistence(
      storageKey: 'test.dynamic-runtime',
    );
    final runtime = ImDynamicRuntime(content: initial)..updateState(
      lifecycle: ImDynamicLifecycle.completed,
      values: const {'result': 'ok'},
    );
    final snapshot = runtime.snapshot(messageId: 'message-2');

    await persistence.save(snapshot);
    final restored = (await persistence.load()).single;
    expect(restored.messageId, 'message-2');
    expect(restored.state.lifecycle, ImDynamicLifecycle.completed);
    expect(restored.state.values['result'], 'ok');
    runtime.dispose();
  });

  test(
    'late persistence initialization converges an already-rendered runtime',
    () async {
      final persistence = _DelayedRuntimePersistence();
      final store = ImDynamicRuntimeStore(persistence: persistence);
      final initialization = store.initialize();
      final runtime = store.runtimeFor(
        messageId: 'message-3',
        content: initial,
      );
      final snapshot = ImDynamicRuntime(content: initial)..updateState(
        lifecycle: ImDynamicLifecycle.completed,
        values: const {'result': 'restored'},
      );
      persistence.complete(snapshot.snapshot(messageId: 'message-3'));
      await initialization;

      expect(runtime.state.lifecycle, ImDynamicLifecycle.completed);
      expect(runtime.state.values['result'], 'restored');
      snapshot.dispose();
      store.dispose();
    },
  );
}

class _DelayedRuntimePersistence
    implements ImDynamicRuntimeSnapshotPersistence {
  final _loaded = Completer<Iterable<ImDynamicRuntimeSnapshot>>();

  void complete(ImDynamicRuntimeSnapshot snapshot) =>
      _loaded.complete([snapshot]);

  @override
  Future<Iterable<ImDynamicRuntimeSnapshot>> load() => _loaded.future;

  @override
  Future<void> save(ImDynamicRuntimeSnapshot snapshot) async {}

  @override
  Future<void> removeMessage(String messageId) async {}

  @override
  Future<void> removeContent(String messageId, String contentId) async {}
}
