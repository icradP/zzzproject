import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zzzproject/zzz_im_chat.dart';

void main() {
  testWidgets('dynamic editor selects, edits, adds, removes, and saves', (
    tester,
  ) async {
    const content = ImDynamicContent(
      id: 'editor-card',
      version: '1.0',
      source: ImDynamicContentSource.ai,
      tree: ImDynamicNode(
        id: 'root',
        type: 'column',
        children: [
          ImDynamicNode(id: 'title', type: 'text', props: {'text': 'Before'}),
        ],
      ),
    );
    final controller = ImDynamicEditorController(content: content);
    addTearDown(controller.dispose);
    ImDynamicCommand? saved;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 600,
            child: ImDynamicEditor(
              controller: controller,
              messageId: 'message-editor',
              onSave: (command) => saved = command,
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('title').first);
    await tester.enterText(
      find.byKey(const ValueKey('dynamic-editor-text')),
      'After',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(controller.content.tree.findById('title')?.props['text'], 'After');

    await tester.tap(find.byKey(const ValueKey('dynamic-editor-add-type')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Button').last);
    await tester.pump();
    expect(controller.content.tree.findById('button-1'), isNotNull);

    await tester.tap(find.text('button-1'));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('dynamic-editor-delete')));
    await tester.pump();
    expect(controller.content.tree.findById('button-1'), isNull);

    await tester.tap(find.byKey(const ValueKey('dynamic-editor-save')));
    expect(saved?.operation, ImDynamicCommandOperation.replace);
    expect(saved?.messageId, 'message-editor');
  });
}
