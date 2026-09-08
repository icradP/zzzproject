import 'package:flutter_test/flutter_test.dart';
import 'package:zzzproject/zzz_im_chat.dart';

void main() {
  final initial = ImDynamicContent(
    id: 'card-1',
    version: '1.0',
    source: ImDynamicContentSource.user,
    tree: const ImDynamicNode(
      id: 'root',
      type: 'column',
      children: [
        ImDynamicNode(id: 'status', type: 'status', props: {'text': 'Created'}),
      ],
    ),
  );
  final update = ImDynamicPatchSet(
    messageId: 'message-1',
    contentId: 'card-1',
    patches: const [
      ImDynamicPatch(
        operation: ImDynamicPatchOperation.update,
        nodeId: 'status',
        props: {'text': 'Updated'},
      ),
    ],
  );
  final replacement = initial.copyWith(
    tree: const ImDynamicNode(
      id: 'root',
      type: 'status',
      props: {'text': 'Replaced'},
    ),
  );

  test('dynamic commands round-trip create, update, replace, and remove', () {
    final commands = [
      ImDynamicCommand.create(messageId: 'message-1', content: initial),
      ImDynamicCommand.update(update),
      ImDynamicCommand.replace(
        messageId: 'message-1',
        contentId: 'card-1',
        content: replacement,
      ),
      ImDynamicCommand.remove(messageId: 'message-1', contentId: 'card-1'),
    ];

    for (final command in commands) {
      final decoded = ImDynamicCommand.fromJson(command.toJson());
      expect(decoded.operation, command.operation);
      expect(decoded.messageId, command.messageId);
      expect(decoded.contentId, command.contentId);
      expect(decoded.toJson(), command.toJson());
    }
  });

  test('dynamic command rejects ambiguous or mismatched payloads', () {
    expect(
      () => ImDynamicCommand.replace(
        messageId: 'message-1',
        contentId: 'other-card',
        content: replacement,
      ),
      throwsFormatException,
    );
    expect(
      () => ImDynamicCommand.fromJson({
        'type': 'dynamic_command',
        'operation': 'remove',
        'message_id': 'message-1',
        'content_id': 'card-1',
        'content': initial.toJson(),
      }),
      throwsFormatException,
    );
  });

  test('command wire adapter preserves update and maps editor replacement', () {
    const adapter = ImDynamicCommandWireAdapter();
    expect(adapter.toPatchSet(ImDynamicCommand.update(update)), same(update));

    final patchSet = adapter.toPatchSet(
      ImDynamicCommand.replace(
        messageId: 'message-1',
        contentId: 'card-1',
        content: replacement,
      ),
    );
    expect(patchSet.messageId, 'message-1');
    expect(patchSet.contentId, 'card-1');
    expect(patchSet.patches.single.operation, ImDynamicPatchOperation.replace);
    expect(patchSet.patches.single.node, same(replacement.tree));
    expect(
      () => adapter.toPatchSet(
        ImDynamicCommand.create(messageId: 'message-1', content: initial),
      ),
      throwsUnsupportedError,
    );
  });

  test('dynamic store applies each command atomically', () {
    final store = ImDynamicStore();
    var notifications = 0;
    store.addListener(() => notifications++);

    store.apply(
      ImDynamicCommand.create(messageId: 'message-1', content: initial),
    );
    expect(store.contentFor('message-1', 'card-1')?.tree, same(initial.tree));

    store.apply(ImDynamicCommand.update(update));
    expect(
      store.contentFor('message-1', 'card-1')?.tree.findById('status')?.props,
      containsPair('text', 'Updated'),
    );

    store.apply(
      ImDynamicCommand.replace(
        messageId: 'message-1',
        contentId: 'card-1',
        content: replacement,
      ),
    );
    expect(
      store.contentFor('message-1', 'card-1')?.tree.props,
      containsPair('text', 'Replaced'),
    );

    store.apply(
      ImDynamicCommand.remove(messageId: 'message-1', contentId: 'card-1'),
    );
    expect(store.contentFor('message-1', 'card-1'), isNull);
    expect(store.contentsForMessage('message-1'), isEmpty);
    expect(notifications, 4);
  });

  test('a failed store update preserves content and emits no notification', () {
    final store = ImDynamicStore();
    var notifications = 0;
    store.addListener(() => notifications++);
    store.apply(
      ImDynamicCommand.create(messageId: 'message-1', content: initial),
    );
    final before = store.contentFor('message-1', 'card-1');

    expect(
      () => store.apply(
        ImDynamicCommand.update(
          ImDynamicPatchSet(
            messageId: 'message-1',
            contentId: 'card-1',
            patches: const [
              ImDynamicPatch(
                operation: ImDynamicPatchOperation.update,
                nodeId: 'missing',
                props: {'text': 'Invalid'},
              ),
            ],
          ),
        ),
      ),
      throwsA(isA<ImDynamicPatchException>()),
    );
    expect(store.contentFor('message-1', 'card-1'), same(before));
    expect(notifications, 1);
  });

  test('dynamic store rejects invalid content before mutating state', () {
    final store = ImDynamicStore();
    var notifications = 0;
    store.addListener(() => notifications++);
    final invalid = initial.copyWith(
      tree: const ImDynamicNode(id: '', type: 'text'),
    );

    expect(
      () => store.apply(
        ImDynamicCommand.create(messageId: 'message-1', content: invalid),
      ),
      throwsA(isA<ImDynamicStoreException>()),
    );
    expect(store.contentsForMessage('message-1'), isEmpty);
    expect(notifications, 0);
  });
}
