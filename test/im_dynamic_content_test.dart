import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zzzproject/zzz_im_chat.dart';
import 'package:zzzproject/src/im/adapters/nonebot/nonebot_mapper.dart';

void main() {
  test(
    'mock repository creates and emits idempotent dynamic content',
    () async {
      final repository = MockImRepository();
      addTearDown(repository.dispose);
      const content = ImDynamicContent(
        id: 'mock-card-1',
        version: '1.0',
        source: ImDynamicContentSource.user,
        tree: ImDynamicNode(
          id: 'root',
          type: 'text',
          props: {'text': 'Local preview'},
        ),
      );
      final emitted = repository
          .watchMessages('dm_belle_me')
          .firstWhere(
            (messages) => messages.any(
              (message) =>
                  message.segments?.any(
                    (segment) => segment.type == 'dynamic_content',
                  ) ==
                  true,
            ),
          );

      final sent = await repository.sendDynamicContent(
        conversationId: 'dm_belle_me',
        content: content,
        text: 'Preview',
        clientMessageId: 'mock-client-1',
      );
      final messages = await emitted;
      final retried = await repository.sendDynamicContent(
        conversationId: 'dm_belle_me',
        content: content,
        text: 'Preview',
        clientMessageId: 'mock-client-1',
      );
      final afterRetry = await repository.watchMessages('dm_belle_me').first;

      expect(sent.kind, ImMessageKind.dynamicContent);
      expect(sent.segments?.map((segment) => segment.type), [
        'text',
        'dynamic_content',
      ]);
      expect(messages.last.id, sent.id);
      expect(retried.id, sent.id);
      expect(
        afterRetry.where((message) => message.id == sent.id),
        hasLength(1),
      );
    },
  );

  test('dynamic content round-trips its schema and ignores unknown fields', () {
    final content = ImDynamicContent.fromJson({
      'type': 'dynamic_content',
      'id': 'diagnosis-1',
      'version': '1.0',
      'source': 'ai',
      'unknown': 'ignored',
      'tree': {
        'id': 'root',
        'type': 'column',
        'children': [
          {
            'id': 'title',
            'type': 'text',
            'props': {'text': 'Network check'},
          },
          {
            'id': 'retry',
            'type': 'button',
            'props': {'text': 'Retry'},
            'events': {
              'click': {'action': 'retry'},
            },
          },
        ],
      },
    });

    final decoded = ImDynamicContent.fromJson(content.toJson());
    expect(decoded.id, 'diagnosis-1');
    expect(decoded.source, ImDynamicContentSource.ai);
    expect(decoded.tree.findById('retry')?.events['click']?['action'], 'retry');
    expect(decoded.toJson()['unknown'], isNull);
  });

  test('segment envelope supports nested schema and transport metadata', () {
    final content = ImDynamicContent.fromSegmentData({
      'id': 'nested-1',
      'source': 'server',
      'metadata': {'template': 'diagnosis'},
      'schema': {
        'version': '1.1',
        'tree': {
          'id': 'root',
          'type': 'text',
          'props': {'text': 'Ready'},
        },
      },
    });
    expect(content.id, 'nested-1');
    expect(content.version, '1.1');
    expect(content.source, ImDynamicContentSource.server);
    expect(content.metadata['template'], 'diagnosis');
  });

  test('dynamic model rejects malformed known fields', () {
    Map<String, dynamic> schemaWithTree(Map<String, dynamic> tree) => {
      'id': 'strict-1',
      'version': '1.0',
      'source': 'ai',
      'tree': tree,
    };

    for (final tree in <Map<String, dynamic>>[
      {'id': 'root', 'type': 'text', 'props': []},
      {'id': 'root', 'type': 'column', 'children': {}},
      {'id': 'root', 'type': 'button', 'events': []},
      {
        'id': 'root',
        'type': 'button',
        'events': {'click': 'run'},
      },
    ]) {
      expect(
        () => ImDynamicContent.fromJson(schemaWithTree(tree)),
        throwsA(isA<FormatException>()),
      );
    }
    expect(
      () => ImDynamicContent.fromJson({
        ...schemaWithTree({'id': 'root', 'type': 'text'}),
        'metadata': [],
      }),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => ImDynamicContent.fromJson({
        ...schemaWithTree({'id': 'root', 'type': 'text'}),
        'fallback': {'type': 'text', 'content': 42},
      }),
      throwsA(isA<FormatException>()),
    );
  });

  test('dynamic patch and event models reject lossy wire values', () {
    expect(
      () => ImDynamicPatchSet.fromJson({
        'message_id': 42,
        'content_id': 'content-1',
        'patches': [
          {
            'operation': 'update',
            'node_id': 'status',
            'props': {'text': 'Done'},
          },
        ],
      }),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => ImDynamicPatch.fromJson({
        'operation': 'create',
        'node_id': 'new-node',
        'parent_node_id': 'root',
        'index': 1.5,
        'node': {'id': 'new-node', 'type': 'text'},
      }),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => ImDynamicPatch.fromJson({
        'operation': 'update',
        'node_id': 'status',
        'props': [],
      }),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => ImDynamicEvent.fromJson({
        'message_id': 'message-1',
        'content_id': 'content-1',
        'node_id': 'retry',
        'event': 'click',
        'payload': [],
      }),
      throwsA(isA<FormatException>()),
    );

    final update = ImDynamicPatchSet.fromSegmentData({
      'message_id': 'message-1',
      'content_id': 'content-1',
      'patches': [
        {
          'operation': 'update',
          'node_id': 'status',
          'props': {'text': 'Done'},
        },
      ],
      'update': <String, dynamic>{},
    });
    expect(update.patches.single.nodeId, 'status');

    final event = ImDynamicEvent.fromSegmentData({
      'message_id': 'message-1',
      'content_id': 'content-1',
      'node_id': 'retry',
      'action': 'retry',
      'payload': {'source': 'test'},
      'event': {'event': 'click'},
    });
    expect(event.messageId, 'message-1');
    expect(event.event, 'click');
    expect(event.payload['source'], 'test');

    final selectEvent = ImDynamicEvent.fromJson({
      'message_id': 'message-1',
      'content_id': 'content-1',
      'node_id': 'choice',
      'event': 'select',
      'action': 'select_option',
    });
    expect(selectEvent.event, 'select');
  });

  test(
    'dynamic content has an explicit message kind in both segment adapters',
    () {
      final segment = OneBotMessageSegment(
        type: 'dynamic_content',
        data: {
          'id': 'kind-1',
          'version': '1.0',
          'tree': {'id': 'root', 'type': 'text'},
        },
      );
      expect(oneBotSegmentToMessageKind(segment), ImMessageKind.dynamicContent);
    },
  );

  test(
    'validator rejects unsafe shape and reports unknown components as warnings',
    () {
      final content = ImDynamicContent(
        id: 'invalid',
        version: '1.0',
        source: ImDynamicContentSource.ai,
        tree: const ImDynamicNode(
          id: 'root',
          type: 'future_component',
          props: {'text': 'x'},
          children: [
            ImDynamicNode(id: 'duplicate', type: 'text'),
            ImDynamicNode(id: 'duplicate', type: 'text'),
          ],
        ),
      );
      final result = const ImDynamicSchemaValidator().validate(content);
      expect(result.isValid, isFalse);
      expect(
        result.errors.any((issue) => issue.message.contains('unique')),
        isTrue,
      );
      expect(
        result.warnings.any((issue) => issue.message.contains('unknown')),
        isTrue,
      );

      final imageHeavy = ImDynamicContent(
        id: 'too-many-images',
        version: '1.0',
        source: ImDynamicContentSource.user,
        tree: ImDynamicNode(
          id: 'root',
          type: 'column',
          children: List.generate(
            2,
            (index) => ImDynamicNode(
              id: 'image-$index',
              type: 'image',
              props: {'url': 'https://example.test/$index.png'},
            ),
          ),
        ),
      );
      final imageResult = const ImDynamicSchemaValidator(
        maxImages: 1,
      ).validate(imageHeavy);
      expect(
        imageResult.errors.any(
          (issue) => issue.message.contains('image limit'),
        ),
        isTrue,
      );
    },
  );

  test(
    'validator aligns transport identifiers, values, and image URL policy',
    () {
      final invalid = ImDynamicContent(
        id: List.filled(129, 'i').join(),
        version: List.filled(33, 'v').join(),
        source: ImDynamicContentSource.unknown,
        metadata: {'values': List.generate(51, (index) => index)},
        fallback: ImDynamicFallback(
          type: 'text',
          content: List.filled(10001, 'x').join(),
        ),
        tree: const ImDynamicNode(
          id: 'root',
          type: 'image',
          props: {'url': 'http://example.test/image.png'},
          events: {
            'click': {'action': 1},
          },
        ),
      );

      final result = const ImDynamicSchemaValidator().validate(invalid);
      expect(result.isValid, isFalse);
      for (final expectedPath in const [
        'id',
        'version',
        'source',
        'metadata.values',
        'fallback.content',
        'tree.props.url',
        'tree.events.click',
      ]) {
        expect(
          result.errors.any((issue) => issue.path == expectedPath),
          isTrue,
          reason: 'missing validation issue for $expectedPath',
        );
      }

      const valid = ImDynamicContent(
        id: 'valid',
        version: '1.0',
        source: ImDynamicContentSource.plugin,
        tree: ImDynamicNode(
          id: 'image',
          type: 'image',
          props: {'url': 'https://example.test/image.png'},
        ),
      );
      expect(const ImDynamicSchemaValidator().validate(valid).isValid, isTrue);
    },
  );

  test('node-id patches update, create, replace, and remove atomically', () {
    const content = ImDynamicContent(
      id: 'patchable',
      version: '1.0',
      source: ImDynamicContentSource.system,
      tree: ImDynamicNode(
        id: 'root',
        type: 'column',
        children: [
          ImDynamicNode(
            id: 'progress',
            type: 'progress',
            props: {'value': 0.2, 'text': '20%'},
          ),
        ],
      ),
    );
    const applier = ImDynamicPatchApplier();
    final updated = applier.apply(
      content,
      const ImDynamicPatchSet(
        messageId: 'message-1',
        contentId: 'patchable',
        patches: [
          ImDynamicPatch(
            operation: ImDynamicPatchOperation.update,
            nodeId: 'progress',
            props: {'value': 0.8, 'text': '80%'},
          ),
          ImDynamicPatch(
            operation: ImDynamicPatchOperation.create,
            nodeId: 'status',
            parentNodeId: 'root',
            node: ImDynamicNode(
              id: 'status',
              type: 'status',
              props: {'text': 'Ready'},
            ),
          ),
        ],
      ),
    );
    expect(updated.tree.findById('progress')?.props['value'], 0.8);
    expect(updated.tree.findById('status')?.props['text'], 'Ready');

    final replaced = applier.apply(
      updated,
      const ImDynamicPatchSet(
        messageId: 'message-1',
        contentId: 'patchable',
        patches: [
          ImDynamicPatch(
            operation: ImDynamicPatchOperation.replace,
            nodeId: 'status',
            node: ImDynamicNode(
              id: 'status',
              type: 'badge',
              props: {'text': 'Done'},
            ),
          ),
        ],
      ),
    );
    expect(replaced.tree.findById('status')?.type, 'badge');
    final removed = applier.apply(
      replaced,
      const ImDynamicPatchSet(
        messageId: 'message-1',
        contentId: 'patchable',
        patches: [
          ImDynamicPatch(
            operation: ImDynamicPatchOperation.remove,
            nodeId: 'status',
          ),
        ],
      ),
    );
    expect(removed.tree.findById('status'), isNull);
    expect(
      () => applier.apply(
        content,
        const ImDynamicPatchSet(
          messageId: 'message-1',
          contentId: 'other',
          patches: [],
        ),
      ),
      throwsA(isA<ImDynamicPatchException>()),
    );
  });

  test(
    'runtime keeps lifecycle state separate and notifies on patch updates',
    () {
      const content = ImDynamicContent(
        id: 'runtime-1',
        version: '1.0',
        source: ImDynamicContentSource.ai,
        tree: ImDynamicNode(
          id: 'root',
          type: 'text',
          props: {'text': 'Working'},
        ),
      );
      final runtime = ImDynamicRuntime(content: content);
      var notifications = 0;
      runtime.addListener(() => notifications++);
      runtime.updateState(
        lifecycle: ImDynamicLifecycle.processing,
        values: {'progress': 0.4},
      );
      runtime.apply(
        const ImDynamicPatchSet(
          messageId: 'message-1',
          contentId: 'runtime-1',
          patches: [
            ImDynamicPatch(
              operation: ImDynamicPatchOperation.update,
              nodeId: 'root',
              props: {'text': 'Done'},
            ),
          ],
        ),
      );
      expect(runtime.state.lifecycle, ImDynamicLifecycle.processing);
      expect(runtime.state.values['progress'], 0.4);
      expect(runtime.content.tree.props['text'], 'Done');
      expect(notifications, 2);
      runtime.dispose();
    },
  );

  testWidgets(
    'dynamic button renders inside the shared message bubble and emits an event',
    (tester) async {
      ImDynamicEvent? event;
      final message = ImMessage(
        id: 'message-1',
        conversationId: 'conversation-1',
        senderId: 'fairy',
        text: 'Ready',
        sentAt: DateTime(2026),
        segments: [
          OneBotMessageSegment(
            type: 'dynamic_content',
            data: {
              'id': 'content-1',
              'version': '1.0',
              'source': 'ai',
              'tree': {
                'id': 'root',
                'type': 'column',
                'children': [
                  {
                    'id': 'title',
                    'type': 'text',
                    'props': {'text': 'Plan'},
                  },
                  {
                    'id': 'run',
                    'type': 'button',
                    'props': {'text': 'Run'},
                    'events': {
                      'click': {'action': 'run_plan'},
                    },
                  },
                ],
              },
            },
          ),
        ],
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ImMessageBubble(
              message: message,
              senderName: 'Fairy',
              avatar: MemoryImage(
                base64Decode(
                  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
                ),
              ),
              showSenderName: false,
              onDynamicEvent: (value) => event = value,
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('Plan'), findsOneWidget);
      await tester.tap(find.text('Run'));
      expect(event?.messageId, 'message-1');
      expect(event?.contentId, 'content-1');
      expect(event?.nodeId, 'run');
      expect(event?.action, 'run_plan');
    },
  );

  testWidgets('dynamic content preserves sibling text in the same bubble', (
    tester,
  ) async {
    final message = ImMessage(
      id: 'message-2',
      conversationId: 'conversation-1',
      senderId: 'fairy',
      text: 'Summary',
      sentAt: DateTime(2026),
      segments: [
        OneBotMessageSegment(type: 'text', data: {'text': 'Summary'}),
        OneBotMessageSegment(
          type: 'dynamic_content',
          data: {
            'id': 'content-2',
            'version': '1.0',
            'source': 'ai',
            'tree': {
              'id': 'root',
              'type': 'status',
              'props': {'text': 'Ready'},
            },
          },
        ),
      ],
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ImMessageBubble(
            message: message,
            senderName: 'Fairy',
            avatar: MemoryImage(
              base64Decode(
                'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
              ),
            ),
            showSenderName: false,
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Summary'), findsOneWidget);
    expect(find.text('Ready'), findsOneWidget);
  });

  testWidgets('dynamic content preserves the existing sibling voice renderer', (
    tester,
  ) async {
    final message = ImMessage(
      id: 'message-with-voice',
      conversationId: 'conversation-1',
      senderId: 'fairy',
      text: '[Dynamic content][Voice]',
      sentAt: DateTime(2026),
      kind: ImMessageKind.dynamicContent,
      segments: [
        OneBotMessageSegment(
          type: 'dynamic_content',
          data: {
            'id': 'voice-content',
            'version': '1.0',
            'source': 'ai',
            'tree': {
              'id': 'root',
              'type': 'status',
              'props': {'text': 'Voice reply'},
            },
          },
        ),
        OneBotMessageSegment(
          type: 'record',
          data: {'file': 'voice-file-1', 'size': 4000, 'duration_ms': 2000},
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ImMessageBubble(
            message: message,
            senderName: 'Fairy',
            avatar: MemoryImage(
              base64Decode(
                'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
              ),
            ),
            showSenderName: false,
          ),
        ),
      ),
    );

    expect(find.text('Voice reply'), findsOneWidget);
    expect(find.byType(ImVoiceBubble), findsOneWidget);
    final voice = tester.widget<ImVoiceBubble>(find.byType(ImVoiceBubble));
    expect(voice.fileId, 'voice-file-1');
    expect(voice.declaredDuration, const Duration(seconds: 2));
    expect(find.text('[record]'), findsNothing);
  });

  testWidgets('malformed dynamic content preserves its fallback and siblings', (
    tester,
  ) async {
    final message = ImMessage(
      id: 'message-malformed',
      conversationId: 'conversation-1',
      senderId: 'fairy',
      text: 'Summary',
      sentAt: DateTime(2026),
      segments: [
        OneBotMessageSegment(type: 'text', data: {'text': 'Summary'}),
        OneBotMessageSegment(
          type: 'dynamic_content',
          data: {
            'id': 'malformed-content',
            'version': '1.0',
            'source': 'ai',
            'fallback': {
              'type': 'text',
              'content': 'Please update ZZZ to view this content.',
            },
            'tree': {'id': 'root', 'type': 'text', 'props': []},
          },
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ImMessageBubble(
            message: message,
            senderName: 'Fairy',
            avatar: MemoryImage(
              base64Decode(
                'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
              ),
            ),
            showSenderName: false,
          ),
        ),
      ),
    );

    expect(find.text('Summary'), findsOneWidget);
    expect(
      find.text('Please update ZZZ to view this content.'),
      findsOneWidget,
    );
  });

  testWidgets(
    'standard layout, input, select, and progress components emit events',
    (tester) async {
      final events = <ImDynamicEvent>[];
      const content = ImDynamicContent(
        id: 'form-1',
        version: '1.0',
        source: ImDynamicContentSource.user,
        tree: ImDynamicNode(
          id: 'root',
          type: 'column',
          children: [
            ImDynamicNode(
              id: 'markdown',
              type: 'markdown',
              props: {'content': 'Formatted summary'},
            ),
            ImDynamicNode(
              id: 'row',
              type: 'row',
              children: [
                ImDynamicNode(
                  id: 'row-text',
                  type: 'text',
                  props: {'text': 'Row item'},
                ),
              ],
            ),
            ImDynamicNode(
              id: 'reason',
              type: 'input',
              props: {'label': 'Reason'},
              events: {
                'submit': {'action': 'submit_reason'},
              },
            ),
            ImDynamicNode(
              id: 'choice',
              type: 'select',
              props: {
                'label': 'Choice',
                'value': 'One',
                'options': ['One', 'Two'],
              },
              events: {
                'change': {'action': 'change_choice'},
              },
            ),
            ImDynamicNode(
              id: 'progress',
              type: 'progress',
              props: {'value': 0.4, 'text': '40%'},
            ),
          ],
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ImDynamicContentView(
              content: content,
              messageId: 'message-form',
              onEvent: events.add,
            ),
          ),
        ),
      );

      expect(find.text('Formatted summary'), findsOneWidget);
      expect(find.text('Row item'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'Need more detail');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(events.single.nodeId, 'reason');
      expect(events.single.action, 'submit_reason');
      expect(events.single.payload['value'], 'Need more detail');

      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Two').last);
      await tester.pumpAndSettle();
      expect(events.last.nodeId, 'choice');
      expect(events.last.action, 'change_choice');
      expect(events.last.payload['value'], 'Two');
    },
  );

  testWidgets('dynamic node IDs preserve local state across tree patches', (
    tester,
  ) async {
    const content = ImDynamicContent(
      id: 'stateful-form',
      version: '1.0',
      source: ImDynamicContentSource.user,
      tree: ImDynamicNode(
        id: 'root',
        type: 'column',
        children: [
          ImDynamicNode(
            id: 'confirm',
            type: 'checkbox',
            props: {'text': 'Confirm'},
            events: {
              'change': {'action': 'confirm'},
            },
          ),
        ],
      ),
    );
    final runtime = ImDynamicRuntime(content: content);
    addTearDown(runtime.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ImDynamicContentView(content: content, runtime: runtime),
        ),
      ),
    );
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pump();
    expect(
      tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
      true,
    );

    runtime.apply(
      const ImDynamicPatchSet(
        messageId: 'message-stateful',
        contentId: 'stateful-form',
        patches: [
          ImDynamicPatch(
            operation: ImDynamicPatchOperation.create,
            nodeId: 'status',
            parentNodeId: 'root',
            index: 0,
            node: ImDynamicNode(id: 'status', type: 'status'),
          ),
        ],
      ),
    );
    await tester.pump();
    expect(
      tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
      true,
    );
  });

  testWidgets(
    'dynamic controls only emit declared events and sync patched props',
    (tester) async {
      const content = ImDynamicContent(
        id: 'controlled-form',
        version: '1.0',
        source: ImDynamicContentSource.user,
        tree: ImDynamicNode(
          id: 'root',
          type: 'column',
          children: [
            ImDynamicNode(
              id: 'reason',
              type: 'input',
              props: {'value': 'before'},
            ),
            ImDynamicNode(id: 'confirm', type: 'checkbox'),
            ImDynamicNode(
              id: 'choice',
              type: 'select',
              props: {
                'options': ['One', 'Two'],
                'value': 'One',
              },
            ),
          ],
        ),
      );
      final runtime = ImDynamicRuntime(content: content);
      addTearDown(runtime.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ImDynamicContentView(content: content, runtime: runtime),
          ),
        ),
      );
      expect(
        tester.widget<TextField>(find.byType(TextField)).onSubmitted,
        isNull,
      );
      expect(
        tester
            .widget<CheckboxListTile>(find.byType(CheckboxListTile))
            .onChanged,
        isNull,
      );
      expect(
        tester
            .widget<DropdownButtonFormField<String>>(
              find.byType(DropdownButtonFormField<String>),
            )
            .onChanged,
        isNull,
      );

      runtime.apply(
        const ImDynamicPatchSet(
          messageId: 'message-controlled',
          contentId: 'controlled-form',
          patches: [
            ImDynamicPatch(
              operation: ImDynamicPatchOperation.update,
              nodeId: 'reason',
              props: {'value': 'after'},
            ),
            ImDynamicPatch(
              operation: ImDynamicPatchOperation.update,
              nodeId: 'confirm',
              props: {'value': true},
            ),
            ImDynamicPatch(
              operation: ImDynamicPatchOperation.update,
              nodeId: 'choice',
              props: {'value': 'Two'},
            ),
          ],
        ),
      );
      await tester.pump();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller?.text,
        'after',
      );
      expect(
        tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
        true,
      );
      expect(
        tester
            .widget<DropdownButtonFormField<String>>(
              find.byType(DropdownButtonFormField<String>),
            )
            .initialValue,
        'Two',
      );
    },
  );

  testWidgets('closed dynamic content disables interactive components', (
    tester,
  ) async {
    const content = ImDynamicContent(
      id: 'closed-1',
      version: '1.0',
      source: ImDynamicContentSource.system,
      tree: ImDynamicNode(
        id: 'root',
        type: 'column',
        children: [
          ImDynamicNode(
            id: 'input',
            type: 'input',
            events: {
              'submit': {'action': 'submit'},
            },
          ),
          ImDynamicNode(
            id: 'checkbox',
            type: 'checkbox',
            props: {'text': 'Confirm'},
            events: {
              'change': {'action': 'confirm'},
            },
          ),
          ImDynamicNode(
            id: 'select',
            type: 'select',
            props: {
              'options': ['One'],
            },
            events: {
              'change': {'action': 'select'},
            },
          ),
          ImDynamicNode(
            id: 'button',
            type: 'button',
            props: {'text': 'Run'},
            events: {
              'click': {'action': 'run'},
            },
          ),
        ],
      ),
    );
    final runtime = ImDynamicRuntime(
      content: content,
      state: const ImDynamicState(lifecycle: ImDynamicLifecycle.closed),
    );
    addTearDown(runtime.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ImDynamicContentView(content: content, runtime: runtime),
        ),
      ),
    );

    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
    expect(
      tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).onChanged,
      isNull,
    );
    expect(
      tester
          .widget<DropdownButtonFormField<String>>(
            find.byType(DropdownButtonFormField<String>),
          )
          .onChanged,
      isNull,
    );
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );
  });

  testWidgets('multiple dynamic contents render their own trees', (
    tester,
  ) async {
    final message = ImMessage(
      id: 'message-multiple',
      conversationId: 'conversation-1',
      senderId: 'fairy',
      text: 'Between',
      sentAt: DateTime(2026),
      segments: [
        OneBotMessageSegment(
          type: 'dynamic_content',
          data: {
            'id': 'first-content',
            'version': '1.0',
            'source': 'ai',
            'tree': {
              'id': 'first-root',
              'type': 'text',
              'props': {'text': 'First dynamic'},
            },
          },
        ),
        OneBotMessageSegment(type: 'text', data: {'text': 'Between'}),
        OneBotMessageSegment(
          type: 'dynamic_content',
          data: {
            'id': 'second-content',
            'version': '1.0',
            'source': 'ai',
            'tree': {
              'id': 'second-root',
              'type': 'text',
              'props': {'text': 'Second dynamic'},
            },
          },
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ImMessageBubble(
            message: message,
            senderName: 'Fairy',
            avatar: MemoryImage(
              base64Decode(
                'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
              ),
            ),
            showSenderName: false,
          ),
        ),
      ),
    );

    expect(find.text('First dynamic'), findsOneWidget);
    expect(find.text('Between'), findsOneWidget);
    expect(find.text('Second dynamic'), findsOneWidget);
  });

  testWidgets(
    'legacy adapter renders a registered business component in the shared bubble',
    (tester) async {
      ImDynamicEvent? event;
      final message = ImMessage(
        id: 'message-legacy',
        conversationId: 'conversation-1',
        senderId: 'fairy',
        text: 'Review this action',
        sentAt: DateTime(2026),
        segments: [
          OneBotMessageSegment(
            type: 'text',
            data: {'text': 'Review this action'},
          ),
          OneBotMessageSegment(
            type: 'legacy_approval',
            data: {'request_id': 'request-1'},
          ),
        ],
      );
      final componentRegistry =
          ImDynamicComponentRegistry.standard()
            ..register(const _TestApprovalRenderer());

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ImMessageBubble(
              message: message,
              senderName: 'Fairy',
              avatar: MemoryImage(
                base64Decode(
                  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
                ),
              ),
              showSenderName: false,
              contentAdapterRegistry: ImMessageContentAdapterRegistry(
                adapters: const [_TestApprovalAdapter()],
              ),
              dynamicContentRegistry: componentRegistry,
              onDynamicEvent: (value) => event = value,
            ),
          ),
        ),
      );

      expect(find.text('Review this action'), findsOneWidget);
      expect(find.text('Approve request-1'), findsOneWidget);
      await tester.tap(find.text('Approve request-1'));
      expect(event?.messageId, 'message-legacy');
      expect(event?.contentId, 'adapted-message-legacy-1');
      expect(event?.action, 'approve');
    },
  );
}

class _TestApprovalAdapter extends ImMessageContentAdapter {
  const _TestApprovalAdapter();

  @override
  String get segmentType => 'legacy_approval';

  @override
  ImDynamicContent convert(ImMessageContentAdapterContext context) {
    final requestId = context.segment.data['request_id']?.toString() ?? '';
    return ImDynamicContent(
      id: 'adapted-${context.message.id}-${context.segmentIndex}',
      version: '1.0',
      source: ImDynamicContentSource.system,
      tree: ImDynamicNode(
        id: 'approval-$requestId',
        type: 'test_approval',
        props: {'request_id': requestId},
        events: const {
          'click': {'action': 'approve'},
        },
      ),
    );
  }
}

class _TestApprovalRenderer extends ImDynamicComponentRenderer {
  const _TestApprovalRenderer();

  @override
  String get type => 'test_approval';

  @override
  Widget build(
    BuildContext context,
    ImDynamicNode node,
    ImDynamicRenderContext renderContext,
  ) {
    final requestId = node.props['request_id']?.toString() ?? '';
    return FilledButton(
      onPressed: () => renderContext.emit(node, 'click'),
      child: Text('Approve $requestId'),
    );
  }
}
