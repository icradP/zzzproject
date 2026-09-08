import 'package:flutter/widgets.dart';

import 'im_content_event.dart';
import 'im_content_node.dart';

typedef ImContentFallbackRenderer =
    Widget Function(
      BuildContext context,
      ImContentNode node,
      ImContentRenderContext renderContext,
    );

/// Rendering context shared by standard, legacy, and Dynamic Content nodes.
///
/// The runtime owns tree traversal and stable widget identity. Renderers remain
/// presentation-only and delegate events or application work to their caller.
class ImContentRenderContext {
  const ImContentRenderContext({
    required this.messageId,
    required this.renderNode,
    this.onEvent,
  });

  final String messageId;
  final Widget Function(BuildContext context, ImContentNode node) renderNode;
  final ValueChanged<ImContentEvent>? onEvent;

  void emit(
    ImContentNode node,
    String type, {
    Map<String, dynamic> payload = const <String, dynamic>{},
  }) {
    onEvent?.call(
      ImContentEvent(
        messageId: messageId,
        contentId: node.id,
        type: type,
        payload: payload,
      ),
    );
  }
}

abstract class ImContentRenderer {
  const ImContentRenderer();

  /// The wire or semantic content type rendered by this implementation.
  String get type;

  Widget build(
    BuildContext context,
    ImContentNode node,
    ImContentRenderContext renderContext,
  );
}

class ImContentRendererRegistry {
  ImContentRendererRegistry({
    Iterable<ImContentRenderer> renderers = const <ImContentRenderer>[],
  }) {
    for (final renderer in renderers) {
      register(renderer);
    }
  }

  final Map<String, ImContentRenderer> _renderers = {};

  void register(ImContentRenderer renderer) {
    final key = renderer.type.trim();
    if (key.isEmpty) throw ArgumentError.value(renderer.type, 'type');
    _renderers[key] = renderer;
  }

  ImContentRenderer? find(ImContentNode node) {
    return _renderers[node.wireType] ?? _renderers[node.type.wireName];
  }

  Set<String> get types => Set.unmodifiable(_renderers.keys);
}

/// Traverses a unified ContentTree and delegates each node to a registered
/// renderer. The fallback keeps mature legacy renderers usable during the
/// incremental migration.
class ImContentRuntime {
  const ImContentRuntime({this.registry});

  final ImContentRendererRegistry? registry;

  List<Widget> renderTree(
    BuildContext context,
    ImContentTree tree, {
    required ImContentFallbackRenderer fallback,
    Iterable<ImContentNode>? nodes,
    ValueChanged<ImContentEvent>? onEvent,
  }) {
    late final ImContentRenderContext renderContext;
    Widget renderNode(BuildContext buildContext, ImContentNode node) {
      final renderer = registry?.find(node);
      final child =
          renderer?.build(buildContext, node, renderContext) ??
          fallback(buildContext, node, renderContext);
      return KeyedSubtree(
        key: ValueKey<String>('${tree.messageId}:${node.id}:${node.wireType}'),
        child: child,
      );
    }

    renderContext = ImContentRenderContext(
      messageId: tree.messageId,
      renderNode: renderNode,
      onEvent: onEvent,
    );
    return [
      for (final node in nodes ?? tree.children) renderNode(context, node),
    ];
  }
}

typedef ContentRenderer = ImContentRenderer;
