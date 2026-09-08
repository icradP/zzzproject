import 'package:flutter/material.dart';

import '../models/im_dynamic_models.dart';
import '../runtime/im_dynamic_registry.dart';
import '../runtime/im_dynamic_runtime.dart';
import '../runtime/im_dynamic_runtime_store.dart';
import '../runtime/im_dynamic_validator.dart';

/// Safely renders a validated dynamic content tree.
class ImDynamicContentView extends StatefulWidget {
  const ImDynamicContentView({
    required this.content,
    this.runtime,
    this.runtimeStore,
    this.messageId = '',
    this.registry,
    this.validator = const ImDynamicSchemaValidator(),
    this.onEvent,
    super.key,
  });

  final ImDynamicContent content;
  final ImDynamicRuntime? runtime;
  final ImDynamicRuntimeStore? runtimeStore;
  final String messageId;
  final ImDynamicComponentRegistry? registry;
  final ImDynamicSchemaValidator validator;
  final ValueChanged<ImDynamicEvent>? onEvent;

  @override
  State<ImDynamicContentView> createState() => _ImDynamicContentViewState();
}

class _ImDynamicContentViewState extends State<ImDynamicContentView> {
  ImDynamicRuntime? _runtime;
  bool _ownsRuntime = false;

  @override
  void initState() {
    super.initState();
    _configureRuntime();
  }

  @override
  void didUpdateWidget(covariant ImDynamicContentView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final runtimeChanged =
        !identical(oldWidget.runtime, widget.runtime) ||
        !identical(oldWidget.runtimeStore, widget.runtimeStore) ||
        oldWidget.messageId != widget.messageId ||
        oldWidget.content.id != widget.content.id;
    if (runtimeChanged) {
      _configureRuntime();
      return;
    }
    if (!identical(oldWidget.content, widget.content) &&
        widget.content.id == _runtime!.content.id) {
      _runtime!.synchronizeContent(widget.content);
    }
  }

  @override
  void dispose() {
    if (_ownsRuntime) _runtime?.dispose();
    super.dispose();
  }

  void _configureRuntime() {
    final previous = _runtime;
    if (_ownsRuntime && previous != null) previous.dispose();
    final supplied = widget.runtime;
    final store = widget.runtimeStore;
    if (supplied != null) {
      _runtime = supplied;
      _ownsRuntime = false;
    } else if (store != null) {
      _runtime = store.runtimeFor(
        messageId: widget.messageId,
        content: widget.content,
      );
      _ownsRuntime = false;
    } else {
      _runtime = ImDynamicRuntime(content: widget.content);
      _ownsRuntime = true;
    }
  }

  @override
  Widget build(BuildContext context) {
    final runtime = _runtime!;
    return ListenableBuilder(
      listenable: runtime,
      builder:
          (context, _) =>
              _buildContent(context, runtime.content, runtime.state),
    );
  }

  Widget _buildContent(
    BuildContext context,
    ImDynamicContent content,
    ImDynamicState state,
  ) {
    final validation = widget.validator.validate(content);
    if (!validation.isValid) {
      return _fallback(
        context,
        content.fallback,
        validation.errors.first.message,
      );
    }

    final components = widget.registry ?? ImDynamicComponentRegistry.standard();
    late final ImDynamicRenderContext renderContext;
    renderContext = ImDynamicRenderContext(
      messageId: widget.messageId,
      contentId: content.id,
      onEvent: widget.onEvent,
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
