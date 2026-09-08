import 'package:flutter/material.dart';
import 'package:onebot_flutter/onebot_flutter.dart' show OneBotMessageSegment;

import '../../content/im_content.dart';
import '../../dynamic/im_dynamic.dart';
import '../../models/im_models.dart';

typedef ImMessageContentFallback =
    Widget Function(
      BuildContext context,
      ImContentNode node, {
      required bool hasStructuredContent,
      required bool readOnlyPreview,
    });

typedef ImMessageEmptyContentBuilder =
    Widget Function(BuildContext context, {required bool readOnlyPreview});

ImContentTree resolveImMessageContentTree({
  required ImMessage message,
  ImMessageContentAdapterRegistry? legacyAdapterRegistry,
  ImContentAdapterRegistry? adapterRegistry,
}) {
  final registry =
      adapterRegistry ??
      ImContentAdapterRegistry(legacyAdapters: legacyAdapterRegistry);
  final segments = message.segments ?? const <OneBotMessageSegment>[];
  if (segments.isEmpty) return registry.convertMessageTree(message);
  return ImContentTree(
    messageId: message.id,
    children: [
      for (var index = 0; index < segments.length; index++)
        _contentNodeForSegment(registry, message, segments[index], index),
    ],
  );
}

bool imContentTreeHasStructuredContent(ImContentTree tree) {
  return tree.children.any(
    (node) =>
        node.isDynamic ||
        node.type == ImContentNodeType.dynamicContent ||
        _isDynamicPrimitive(node.type),
  );
}

/// Dispatches one message's typed content through the shared Content Runtime.
///
/// Bubble chrome remains owned by the surrounding message bubble. Unregistered
/// standard
/// nodes are delegated to the existing mature message renderers through
/// [fallback], so adopting the runtime does not change their visual behavior.
class ImMessageContentView extends StatelessWidget {
  const ImMessageContentView({
    required this.tree,
    required this.hasStructuredContent,
    required this.fallback,
    required this.emptyBuilder,
    this.rendererRegistry,
    this.onEvent,
    this.readOnlyPreview = false,
    super.key,
  });

  final ImContentTree tree;
  final bool hasStructuredContent;
  final ImMessageContentFallback fallback;
  final ImMessageEmptyContentBuilder emptyBuilder;
  final ImContentRendererRegistry? rendererRegistry;
  final ValueChanged<ImContentEvent>? onEvent;

  /// Used by recalled-message expansion. The same runtime is used, but the
  /// rendered subtree cannot emit interactions from a message that is closed.
  final bool readOnlyPreview;

  @override
  Widget build(BuildContext context) {
    final renderable = tree.children.where(
      (node) => node.type != ImContentNodeType.reply,
    );
    final nodes = hasStructuredContent ? renderable : renderable.take(1);
    final children = ImContentRuntime(registry: rendererRegistry).renderTree(
      context,
      tree,
      nodes: nodes,
      onEvent: readOnlyPreview ? null : onEvent,
      fallback:
          (buildContext, node, _) => fallback(
            buildContext,
            node,
            hasStructuredContent: hasStructuredContent,
            readOnlyPreview: readOnlyPreview,
          ),
    );
    final content = switch (children.length) {
      0 => emptyBuilder(context, readOnlyPreview: readOnlyPreview),
      1 => children.single,
      _ => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var index = 0; index < children.length; index++) ...[
            if (index > 0) const SizedBox(height: 8),
            children[index],
          ],
        ],
      ),
    };
    return readOnlyPreview ? IgnorePointer(child: content) : content;
  }
}

ImContentNode _contentNodeForSegment(
  ImContentAdapterRegistry registry,
  ImMessage message,
  OneBotMessageSegment segment,
  int segmentIndex,
) {
  try {
    return registry.convert(
      message: message,
      segment: segment,
      segmentIndex: segmentIndex,
    );
  } on Object {
    return ImContentNode.fromWire(
      id: '${message.id}:segment:$segmentIndex',
      type: segment.type,
      data: segment.data,
    );
  }
}

bool _isDynamicPrimitive(ImContentNodeType type) {
  return switch (type) {
    ImContentNodeType.markdown ||
    ImContentNodeType.icon ||
    ImContentNodeType.row ||
    ImContentNodeType.column ||
    ImContentNodeType.card ||
    ImContentNodeType.container ||
    ImContentNodeType.divider ||
    ImContentNodeType.button ||
    ImContentNodeType.input ||
    ImContentNodeType.checkbox ||
    ImContentNodeType.select ||
    ImContentNodeType.progress ||
    ImContentNodeType.status ||
    ImContentNodeType.badge => true,
    _ => false,
  };
}
