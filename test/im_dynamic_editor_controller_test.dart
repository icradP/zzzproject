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

  test(
    'new components selected from a leaf are inserted into its layout parent',
    () {
      final controller = ImDynamicEditorController(content: aiContent)
        ..selectNode('title');
      addTearDown(controller.dispose);

      expect(controller.insertionParent().id, 'root');
      controller.addNode(
        parentNodeId: controller.insertionParent().id,
        node: const ImDynamicNode(id: 'status-1', type: 'status'),
      );

      expect(
        controller.content.tree.children.map((node) => node.id),
        containsAllInOrder(['title', 'status-1']),
      );
      expect(controller.content.tree.findById('title')?.children, isEmpty);
    },
  );

  test('event definitions retain declarative action targets', () {
    final controller = ImDynamicEditorController(content: aiContent);
    addTearDown(controller.dispose);
    controller.setNodeEvent(
      nodeId: 'title',
      event: 'click',
      action: 'set_property',
      targetNodeId: 'root',
      property: 'text',
      value: 'Done',
    );

    expect(controller.content.tree.findById('title')?.events['click'], {
      'action': 'set_property',
      'target': 'root',
      'property': 'text',
      'value': 'Done',
    });
  });

  test('complete event edits retain generic projection fields', () {
    final controller = ImDynamicEditorController(content: aiContent);
    addTearDown(controller.dispose);
    controller.setNodeEventDefinition(
      nodeId: 'title',
      event: 'click',
      definition: const {
        'action': 'advance_stage',
        'projection': {'progress_delta': 0.25, 'progress_node_id': 'progress'},
      },
    );
    final current = controller.content.tree.findById('title')!.events['click']!;
    controller.setNodeEventDefinition(
      nodeId: 'title',
      event: 'click',
      definition: {...current, 'action': 'advance_custom_stage'},
    );

    expect(
      controller.content.tree.findById('title')?.events['click']?['projection'],
      {'progress_delta': 0.25, 'progress_node_id': 'progress'},
    );
  });

  test('editor templates create distinct generic interaction contracts', () {
    for (final template in ImDynamicEditorTemplate.values) {
      final content = ImDynamicEditorTemplates.build(
        template: template,
        contentId: 'template-${template.name}',
      );
      expect(
        const ImDynamicSchemaValidator().validate(content).isValid,
        isTrue,
        reason: template.name,
      );
    }

    final progress = ImDynamicEditorTemplates.build(
      template: ImDynamicEditorTemplate.progressControls,
      contentId: 'progress-template',
    );
    expect(
      progress.tree
          .findById('increase')
          ?.events['click']?['projection']?['progress_delta'],
      0.1,
    );
    expect(
      progress.tree
          .findById('decrease')
          ?.events['click']?['projection']?['progress_delta'],
      -0.1,
    );

    final survey = ImDynamicEditorTemplates.build(
      template: ImDynamicEditorTemplate.survey,
      contentId: 'survey-template',
    );
    expect((survey.metadata['interaction'] as Map)['reducer'], 'set_by_actor');

    final receipt = ImDynamicEditorTemplates.build(
      template: ImDynamicEditorTemplate.readReceipt,
      contentId: 'receipt-template',
    );
    expect(receipt.tree.findById('mark-read'), isNotNull);

    final confirmation = ImDynamicEditorTemplates.build(
      template: ImDynamicEditorTemplate.confirmation,
      contentId: 'confirmation-template',
    );
    expect(
      (confirmation.metadata['interaction'] as Map)['reducer'],
      'approval_quorum',
    );
  });
}
