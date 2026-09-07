import 'package:flutter/material.dart';

import '../models/im_dynamic_models.dart';
import '../runtime/im_dynamic_registry.dart';
import '../runtime/im_dynamic_runtime.dart';
import '../runtime/im_dynamic_validator.dart';

/// Safely renders a validated dynamic content tree.
class ImDynamicContentView extends StatelessWidget {
  const ImDynamicContentView({
    required this.content,
    this.runtime,
    this.messageId = '',
    this.registry,
    this.validator = const ImDynamicSchemaValidator(),
    this.onEvent,
    super.key,
  });

  final ImDynamicContent content;
  final ImDynamicRuntime? runtime;
  final String messageId;
  final ImDynamicComponentRegistry? registry;
  final ImDynamicSchemaValidator validator;
  final ValueChanged<ImDynamicEvent>? onEvent;

  @override
  Widget build(BuildContext context) {
    final runtime = this.runtime;
    if (runtime != null) {
      return ListenableBuilder(
        listenable: runtime,
        builder:
            (context, _) =>
                _buildContent(context, runtime.content, runtime.state),
      );
    }
    return _buildContent(context, content, const ImDynamicState());
  }

  Widget _buildContent(
    BuildContext context,
    ImDynamicContent content,
    ImDynamicState state,
  ) {
    final validation = validator.validate(content);
    if (!validation.isValid) {
      return _fallback(
        context,
        content.fallback,
        validation.errors.first.message,
      );
    }

    final components = registry ?? ImDynamicComponentRegistry.standard();
    late final ImDynamicRenderContext renderContext;
    renderContext = ImDynamicRenderContext(
      messageId: messageId,
      contentId: content.id,
      onEvent: onEvent,
      state: <String, dynamic>{
        'lifecycle': state.lifecycle.name,
        ...state.values,
      },
      renderNode:
          (buildContext, node) => _buildNode(
            buildContext,
            node,
            components,
            renderContext,
            content.fallback,
          ),
    );
    return _buildNode(
      context,
      content.tree,
      components,
      renderContext,
      content.fallback,
    );
  }

  Widget _buildNode(
    BuildContext context,
    ImDynamicNode node,
    ImDynamicComponentRegistry registry,
    ImDynamicRenderContext renderContext,
    ImDynamicFallback? fallback,
  ) {
    final renderer = registry.find(node.type);
    if (renderer == null) {
      return _fallback(
        context,
        fallback,
        'Unsupported component: ${node.type}',
      );
    }
    // Node IDs are the stable identity across Dynamic Patch updates. Keeping
    // that identity in the widget tree preserves local form state when a
    // sibling is inserted or removed and replaces state when a node changes
    // component type.
    return KeyedSubtree(
      key: ValueKey<String>(
        '${renderContext.messageId}:${renderContext.contentId}:${node.id}:${node.type}',
      ),
      child: renderer.build(context, node, renderContext),
    );
  }

  Widget _fallback(
    BuildContext context,
    ImDynamicFallback? fallback,
    String reason,
  ) {
    final text = fallback?.content.trim();
    if (text != null && text.isNotEmpty) return SelectableText(text);
    return Text(reason, style: Theme.of(context).textTheme.bodySmall);
  }
}
