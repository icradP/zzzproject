import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zzzproject/zzz_im_chat.dart';

void main() {
  final message = ImMessage(
    id: 'message-content-tree',
    conversationId: 'conversation-content-tree',
    senderId: 'alice',
    text: 'hello',
    sentAt: DateTime(2026),
    segments: const [
      OneBotMessageSegment(type: 'text', data: {'text': 'hello'}),
      OneBotMessageSegment(
        type: 'dynamic_content',
        data: {
          'id': 'status-card',
          'version': '1.0',
          'source': 'ai',
          'tree': {
            'id': 'root',
            'type': 'column',
            'children': [
              {
                'id': 'status',
                'type': 'status',
                'props': {'text': 'Ready'},
              },
            ],
          },
        },
      ),
      OneBotMessageSegment(type: 'legacy_card', data: {'title': 'Legacy'}),
    ],
  );

  test(
    'wire segments become typed nodes while preserving dynamic children',
    () {
      final nodes = ImContentAdapterRegistry().convertMessage(message);

      expect(nodes.map((node) => node.type), [
        ImContentNodeType.text,
        ImContentNodeType.dynamicContent,
        ImContentNodeType.unknown,
      ]);
      expect(nodes[0].id, 'message-content-tree:segment:0');
      expect(nodes[1].isDynamic, isTrue);
      expect(nodes[1].children.single.type, ImContentNodeType.column);
      expect(
        nodes[1].children.single.children.single.type,
        ImContentNodeType.status,
      );
      expect(nodes[2].wireType, 'legacy_card');
    },
  );

  test('legacy dynamic adapters bridge into the unified node interface', () {
    final registry = ImContentAdapterRegistry(
      legacyAdapters: ImMessageContentAdapterRegistry(
        adapters: const [_LegacyCardAdapter()],
      ),
    );
    final node = registry.convert(
      message: message,
      segment: message.segments!.last,
      segmentIndex: 2,
    );

    expect(node.type, ImContentNodeType.dynamicContent);
    expect(node.dynamicContent?.id, 'legacy-card-message-content-tree-2');
    expect(node.children.single.type, ImContentNodeType.card);
  });

  test(
    'typed adapters can provide business nodes without changing wire data',
    () {
      final registry = ImContentAdapterRegistry(
        adapters: const [_TypedCardAdapter()],
      );
      final node = registry.convert(
        message: message,
        segment: message.segments!.last,
        segmentIndex: 2,
      );

      expect(registry.types, contains('legacy_card'));
      expect(node.type, ImContentNodeType.card);
      expect(node.data['title'], 'Legacy');
    },
  );

  test('messages without wire segments still produce a typed content tree', () {
    final media = ImMessage(
      id: 'local-file',
      conversationId: 'local',
      senderId: 'alice',
      text: 'report.pdf',
      sentAt: DateTime(2026),
      kind: ImMessageKind.file,
      mediaPath: '/downloads/report.pdf',
      mediaSize: 1024,
    );

    final tree = ImContentAdapterRegistry().convertMessageTree(media);

    expect(tree.messageId, 'local-file');
    expect(tree.children.single.type, ImContentNodeType.file);
    expect(tree.children.single.data['url'], '/downloads/report.pdf');
    expect(tree.children.single.data['size'], 1024);
    expect(tree.findById('local-file:content'), same(tree.children.single));
  });

  test('dynamic events implement the shared content event contract', () {
    const ImContentEvent event = ImDynamicEvent(
      messageId: 'message-1',
      contentId: 'card-1',
      nodeId: 'approve',
      event: 'click',
      action: 'approve',
    );

    expect(event.type, 'click');
    expect(event.messageId, 'message-1');
  });

  test('legacy message kinds map to the expected unified node types', () {
    final expected = <ImMessageKind, ImContentNodeType>{
      ImMessageKind.text: ImContentNodeType.text,
      ImMessageKind.image: ImContentNodeType.image,
      ImMessageKind.video: ImContentNodeType.video,
      ImMessageKind.record: ImContentNodeType.audio,
      ImMessageKind.file: ImContentNodeType.file,
      ImMessageKind.share: ImContentNodeType.share,
      ImMessageKind.system: ImContentNodeType.system,
    };
    final registry = ImContentAdapterRegistry();

    for (final entry in expected.entries) {
      final tree = registry.convertMessageTree(
        ImMessage(
          id: 'legacy-${entry.key.name}',
          conversationId: 'legacy',
          senderId: 'alice',
          text: entry.key.name,
          sentAt: DateTime(2026),
          kind: entry.key,
        ),
      );
      expect(tree.children.single.type, entry.value);
    }
  });

  testWidgets('content runtime traverses registered renderers recursively', (
    tester,
  ) async {
    ImContentEvent? emitted;
    final registry = ImContentRendererRegistry(
      renderers: const [
        _TestColumnRenderer(),
        _TestTextRenderer(),
        _TestButtonRenderer(),
      ],
    );
    const tree = ImContentTree(
      messageId: 'runtime-message',
      children: [
        ImContentNode(
          id: 'root',
          type: ImContentNodeType.column,
          children: [
            ImContentNode(
              id: 'body',
              type: ImContentNodeType.text,
              data: {'text': 'Runtime text'},
            ),
            ImContentNode(
              id: 'run',
              type: ImContentNodeType.button,
              data: {'text': 'Run'},
            ),
          ],
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            final children = ImContentRuntime(registry: registry).renderTree(
              context,
              tree,
              onEvent: (event) => emitted = event,
              fallback: (_, node, __) => Text('fallback:${node.wireType}'),
            );
            return Column(children: children);
          },
        ),
      ),
    );

    expect(find.text('Runtime text'), findsOneWidget);
    expect(find.textContaining('fallback:'), findsNothing);
    expect(
      find.byKey(const ValueKey('runtime-message:root:column')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('runtime-message:body:text')),
      findsOneWidget,
    );
    await tester.tap(find.text('Run'));
    expect(emitted?.messageId, 'runtime-message');
    expect(emitted?.contentId, 'run');
    expect(emitted?.type, 'click');
    expect(emitted?.payload['source'], 'test');
  });

  testWidgets('all legacy bubble kinds pass through unified renderers', (
    tester,
  ) async {
    final registry = ImContentRendererRegistry(
      renderers: const [
        _TestLabelRenderer(type: 'text', prefix: 'Unified text'),
        _TestLabelRenderer(type: 'image', prefix: 'Unified image'),
        _TestLabelRenderer(type: 'video', prefix: 'Unified video'),
        _TestLabelRenderer(type: 'record', prefix: 'Unified audio'),
        _TestLabelRenderer(type: 'file', prefix: 'Unified file'),
        _TestLabelRenderer(type: 'share', prefix: 'Unified share'),
        _TestLabelRenderer(type: 'system', prefix: 'Unified system'),
      ],
    );
    final messages = [
      ImMessage(
        id: 'legacy-text',
        conversationId: 'legacy',
        senderId: 'alice',
        text: 'hello',
        sentAt: DateTime(2026),
      ),
      ImMessage(
        id: 'legacy-image',
        conversationId: 'legacy',
        senderId: 'alice',
        text: 'photo.png',
        sentAt: DateTime(2026),
        kind: ImMessageKind.image,
      ),
      ImMessage(
        id: 'legacy-video',
        conversationId: 'legacy',
        senderId: 'alice',
        text: 'clip.mp4',
        sentAt: DateTime(2026),
        kind: ImMessageKind.video,
      ),
      ImMessage(
        id: 'legacy-audio',
        conversationId: 'legacy',
        senderId: 'alice',
        text: 'voice.ogg',
        sentAt: DateTime(2026),
        kind: ImMessageKind.record,
      ),
      ImMessage(
        id: 'legacy-file',
        conversationId: 'legacy',
        senderId: 'alice',
        text: 'report.pdf',
        sentAt: DateTime(2026),
        kind: ImMessageKind.file,
      ),
      ImMessage(
        id: 'legacy-share',
        conversationId: 'legacy',
        senderId: 'alice',
        text: 'Shared page',
        sentAt: DateTime(2026),
        kind: ImMessageKind.share,
      ),
      ImMessage(
        id: 'legacy-system',
        conversationId: 'legacy',
        senderId: 'system',
        text: 'joined',
        sentAt: DateTime(2026),
        kind: ImMessageKind.system,
      ),
    ];
    final avatar = MemoryImage(
      base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              for (final message in messages)
                ImMessageBubble(
                  message: message,
                  senderName: message.senderId,
                  avatar: avatar,
                  showSenderName: false,
                  contentRendererRegistry: registry,
                ),
            ],
          ),
        ),
      ),
    );

    expect(find.text('Unified text:hello'), findsOneWidget);
    expect(find.text('Unified image:photo.png'), findsOneWidget);
    expect(find.text('Unified video:clip.mp4'), findsOneWidget);
    expect(find.text('Unified audio:voice.ogg'), findsOneWidget);
    expect(find.text('Unified file:report.pdf'), findsOneWidget);
    expect(find.text('Unified share:Shared page'), findsOneWidget);
    expect(find.text('Unified system:joined'), findsOneWidget);
  });

  testWidgets('typed standard nodes render through the unified runtime', (
    tester,
  ) async {
    final message = ImMessage(
      id: 'typed-status-message',
      conversationId: 'legacy',
      senderId: 'system',
      text: 'Status',
      sentAt: DateTime(2026),
      segments: const [OneBotMessageSegment(type: 'typed_status', data: {})],
    );
    final avatar = MemoryImage(
      base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ImMessageBubble(
            message: message,
            senderName: 'System',
            avatar: avatar,
            showSenderName: false,
            contentNodeAdapterRegistry: ImContentAdapterRegistry(
              adapters: const [_TypedStatusAdapter()],
            ),
          ),
        ),
      ),
    );

    expect(find.text('Typed status'), findsOneWidget);
  });

  testWidgets('recalled content uses the runtime as a read-only preview', (
    tester,
  ) async {
    ImContentEvent? emitted;
    final recalled = ImMessage(
      id: 'recalled-runtime-message',
      conversationId: 'legacy',
      senderId: 'alice',
      text: 'Run',
      sentAt: DateTime(2026),
      recalled: true,
      segments: const [OneBotMessageSegment(type: 'typed_button', data: {})],
    );
    final avatar = MemoryImage(
      base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ImMessageBubble(
            message: recalled,
            senderName: 'Alice',
            avatar: avatar,
            showSenderName: false,
            contentNodeAdapterRegistry: ImContentAdapterRegistry(
              adapters: const [_TypedButtonAdapter()],
            ),
            contentRendererRegistry: ImContentRendererRegistry(
              renderers: const [_TestButtonRenderer()],
            ),
            onContentEvent: (event) => emitted = event,
          ),
        ),
      ),
    );

    expect(find.text('Run'), findsNothing);
    await tester.tap(find.text('Alice recalled a message'));
    await tester.pump();

    expect(find.text('Run'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) => widget is IgnorePointer && widget.ignoring,
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('Run'), warnIfMissed: false);
    expect(emitted, isNull);
  });
}

class _LegacyCardAdapter extends ImMessageContentAdapter {
  const _LegacyCardAdapter();

  @override
  String get segmentType => 'legacy_card';

  @override
  ImDynamicContent convert(ImMessageContentAdapterContext context) {
    return ImDynamicContent(
      id: 'legacy-card-${context.message.id}-${context.segmentIndex}',
      version: '1.0',
      source: ImDynamicContentSource.system,
      tree: const ImDynamicNode(
        id: 'legacy-root',
        type: 'card',
        props: {'text': 'Legacy'},
      ),
    );
  }
}

class _TypedCardAdapter extends ImContentAdapter {
  const _TypedCardAdapter();

  @override
  String get segmentType => 'legacy_card';

  @override
  ImContentNode convert(ImContentAdapterContext context) {
    return ImContentNode(
      id: '${context.message.id}:typed-card',
      type: ImContentNodeType.card,
      data: context.segment.data,
    );
  }
}

class _TypedStatusAdapter extends ImContentAdapter {
  const _TypedStatusAdapter();

  @override
  String get segmentType => 'typed_status';

  @override
  ImContentNode convert(ImContentAdapterContext context) {
    return ImContentNode(
      id: '${context.message.id}:typed-status',
      type: ImContentNodeType.status,
      data: const {'text': 'Typed status'},
    );
  }
}

class _TypedButtonAdapter extends ImContentAdapter {
  const _TypedButtonAdapter();

  @override
  String get segmentType => 'typed_button';

  @override
  ImContentNode convert(ImContentAdapterContext context) {
    return ImContentNode(
      id: '${context.message.id}:typed-button',
      type: ImContentNodeType.button,
      data: const {'text': 'Run'},
    );
  }
}

class _TestColumnRenderer extends ImContentRenderer {
  const _TestColumnRenderer();

  @override
  String get type => 'column';

  @override
  Widget build(
    BuildContext context,
    ImContentNode node,
    ImContentRenderContext renderContext,
  ) {
    return Column(
      children: [
        for (final child in node.children)
          renderContext.renderNode(context, child),
      ],
    );
  }
}

class _TestTextRenderer extends ImContentRenderer {
  const _TestTextRenderer();

  @override
  String get type => 'text';

  @override
  Widget build(
    BuildContext context,
    ImContentNode node,
    ImContentRenderContext renderContext,
  ) {
    return Text(node.data['text']?.toString() ?? '');
  }
}

class _TestButtonRenderer extends ImContentRenderer {
  const _TestButtonRenderer();

  @override
  String get type => 'button';

  @override
  Widget build(
    BuildContext context,
    ImContentNode node,
    ImContentRenderContext renderContext,
  ) {
    return TextButton(
      onPressed:
          () => renderContext.emit(
            node,
            'click',
            payload: const {'source': 'test'},
          ),
      child: Text(node.data['text']?.toString() ?? ''),
    );
  }
}

class _TestLabelRenderer extends ImContentRenderer {
  const _TestLabelRenderer({required this.type, required this.prefix});

  @override
  final String type;
  final String prefix;

  @override
  Widget build(
    BuildContext context,
    ImContentNode node,
    ImContentRenderContext renderContext,
  ) {
    return Text('$prefix:${node.data['text']}');
  }
}
