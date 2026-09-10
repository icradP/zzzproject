import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zzzproject/src/widgets/zzz_widgets.dart';
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

  testWidgets('dynamic editor switches to tabs on narrow surfaces', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(390, 720)
      ..devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final controller = ImDynamicEditorController(
      content: const ImDynamicContent(
        id: 'mobile-editor-card',
        version: '1.0',
        source: ImDynamicContentSource.user,
        tree: ImDynamicNode(
          id: 'root',
          type: 'column',
          children: [
            ImDynamicNode(
              id: 'title',
              type: 'text',
              props: {'text': 'Mobile preview'},
            ),
          ],
        ),
      ),
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 390,
            height: 600,
            child: ImDynamicEditor(
              controller: controller,
              messageId: 'mobile-editor-message',
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(TabBar), findsOneWidget);
    expect(find.byType(Tab), findsNWidgets(3));
    expect(find.text('Build'), findsOneWidget);
    expect(find.text('Action'), findsOneWidget);
    expect(find.text('Preview'), findsWidgets);
    expect(find.byKey(const ValueKey('dynamic-editor-save')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('creator stays usable at 320px and switches real templates', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(320, 700)
      ..devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    ImDynamicCommand? created;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ZzzModalPanel(
            title: 'Interactive Message',
            icon: Icons.dashboard_customize_outlined,
            maxWidth: 900,
            maxHeight: 680,
            child: ImDynamicContentCreatorPanel(
              messageId: 'mobile-draft',
              onCreate: (command) => created = command,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Progress controls'), findsOneWidget);
    expect(find.text('Build'), findsOneWidget);
    final panelRect = tester.getRect(find.byType(ZzzModalPanel));
    expect(panelRect.left, greaterThanOrEqualTo(0));
    expect(panelRect.right, lessThanOrEqualTo(320));
    expect(panelRect.top, greaterThanOrEqualTo(0));
    expect(panelRect.bottom, lessThanOrEqualTo(700));
    expect(tester.takeException(), isNull);

    await tester.tap(
      find.byKey(const ValueKey('dynamic-editor-template-progressControls')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Survey / vote').last);
    await tester.pumpAndSettle();

    expect(find.text('question'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byKey(const ValueKey('dynamic-editor-save')));
    await tester.pump();
    expect(created?.operation, ImDynamicCommandOperation.create);
    expect(created?.content?.metadata['template'], 'survey');
  });

  testWidgets('action editor creates a generic progress projection', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(390, 720)
      ..devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final controller = ImDynamicEditorController(
      content: const ImDynamicContent(
        id: 'action-editor-card',
        version: '1.0',
        source: ImDynamicContentSource.user,
        tree: ImDynamicNode(
          id: 'root',
          type: 'column',
          children: [
            ImDynamicNode(
              id: 'progress',
              type: 'progress',
              props: {'value': 0.2, 'text': '20%'},
            ),
            ImDynamicNode(
              id: 'change',
              type: 'button',
              props: {'text': 'Change'},
              events: {
                'click': {'action': 'respond'},
              },
            ),
          ],
        ),
      ),
    )..selectNode('change');
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 390,
            height: 700,
            child: ImDynamicEditor(
              controller: controller,
              messageId: 'action-message',
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Action'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('dynamic-editor-action-behavior-response')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Increase progress').last);
    await tester.pumpAndSettle();

    expect(controller.content.tree.findById('change')?.events['click'], {
      'action': 'adjust_progress',
      'projection': {'progress_delta': 0.1, 'progress_node_id': 'progress'},
    });
    expect(tester.takeException(), isNull);
  });

  testWidgets('progress control template changes progress in preview', (
    tester,
  ) async {
    final content = ImDynamicEditorTemplates.build(
      template: ImDynamicEditorTemplate.progressControls,
      contentId: 'progress-preview',
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ImDynamicContentView(
            content: content,
            messageId: 'progress-preview-message',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    double progress() =>
        tester
            .widget<LinearProgressIndicator>(
              find.byType(LinearProgressIndicator).first,
            )
            .value!;
    expect(progress(), closeTo(0.5, 0.001));

    await tester.tap(find.text('+10%'));
    await tester.pump();
    expect(progress(), closeTo(0.6, 0.001));

    await tester.tap(find.text('-10%'));
    await tester.pump();
    expect(progress(), closeTo(0.5, 0.001));
  });
}
