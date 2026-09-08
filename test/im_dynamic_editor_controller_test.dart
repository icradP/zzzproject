import 'package:flutter_test/flutter_test.dart';
import 'package:zzzproject/zzz_im_chat.dart';

void main() {
  const aiContent = ImDynamicContent(
    id: 'ai-card',
    version: '1.0',
    source: ImDynamicContentSource.ai,
    tree: ImDynamicNode(
      id: 'root',
      type: 'column',
      children: [
        ImDynamicNode(id: 'title', type: 'text', props: {'text': 'Original'}),
      ],
    ),
  );

  test('user edits AI content through the shared schema', () {
    final controller = ImDynamicEditorController(content: aiContent);
    addTearDown(controller.dispose);

    controller.updateNode(nodeId: 'title', props: const {'text': 'Edited'});
    controller.addNode(
      parentNodeId: 'root',
      node: const ImDynamicNode(
        id: 'approve',
        type: 'button',
        props: {'text': 'Approve'},
      ),
    );
    controller.setNodeEvent(
      nodeId: 'approve',
      event: 'click',
      action: 'approve',
    );

    expect(controller.content.source, ImDynamicContentSource.user);
    expect(controller.content.metadata['edited'], isTrue);
    expect(controller.content.metadata['origin_source'], 'ai');
    expect(controller.content.tree.findById('title')?.props['text'], 'Edited');
    expect(
      controller.content.tree.findById('approve')?.events['click']?['action'],
      'approve',
    );
    expect(controller.validation.isValid, isTrue);
  });

  test('editor supports undo, redo, removal, and save command', () {
    final controller = ImDynamicEditorController(content: aiContent);
    addTearDown(controller.dispose);
    controller.addNode(
      parentNodeId: 'root',
      node: const ImDynamicNode(id: 'status', type: 'status'),
    );
    controller.removeNode('status');
    expect(controller.content.tree.findById('status'), isNull);

    controller.undo();
    expect(controller.content.tree.findById('status'), isNotNull);
    controller.redo();
    expect(controller.content.tree.findById('status'), isNull);

    final command = controller.buildSaveCommand(messageId: 'message-1');
    expect(command.operation, ImDynamicCommandOperation.replace);
    expect(command.contentId, aiContent.id);
    expect(command.content, same(controller.content));
  });

  test('invalid edits are rejected without changing editor history', () {
    final controller = ImDynamicEditorController(content: aiContent);
    addTearDown(controller.dispose);
    final before = controller.content;

    expect(
      () => controller.addNode(
        parentNodeId: 'root',
        node: const ImDynamicNode(
          id: 'unsafe-image',
          type: 'image',
          props: {'url': 'http://example.test/image.png'},
        ),
      ),
      throwsA(isA<ImDynamicEditorException>()),
    );
    expect(controller.content, same(before));
    expect(controller.canUndo, isFalse);
  });
}
