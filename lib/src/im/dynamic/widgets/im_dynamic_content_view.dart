import 'dart:async';
import 'dart:convert';

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
    this.onLoadInteractions,
    super.key,
  });

  final ImDynamicContent content;
  final ImDynamicRuntime? runtime;
  final ImDynamicRuntimeStore? runtimeStore;
  final String messageId;
  final ImDynamicComponentRegistry? registry;
  final ImDynamicSchemaValidator validator;
  final ValueChanged<ImDynamicEvent>? onEvent;
  final Future<ImDynamicInteractionSnapshot> Function()? onLoadInteractions;

  @override
  State<ImDynamicContentView> createState() => _ImDynamicContentViewState();
}

class _ImDynamicContentViewState extends State<ImDynamicContentView> {
  ImDynamicRuntime? _runtime;
  bool _ownsRuntime = false;
  ImDynamicInteractionSnapshot? _interactionSnapshot;
  Object? _interactionError;
  bool _loadingInteractions = false;
  int _interactionLoadGeneration = 0;

  @override
  void initState() {
    super.initState();
    _configureRuntime();
    unawaited(_loadInteractions());
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
      _interactionSnapshot = null;
      _interactionError = null;
      unawaited(_loadInteractions());
      return;
    }
    if (!identical(oldWidget.content, widget.content) &&
        widget.content.id == _runtime!.content.id) {
      _runtime!.synchronizeContent(widget.content);
    }
    if (oldWidget.onLoadInteractions != widget.onLoadInteractions ||
        oldWidget.content.metadata['interaction_state'] !=
            widget.content.metadata['interaction_state']) {
      _interactionSnapshot = null;
      _interactionError = null;
      unawaited(_loadInteractions());
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
    final interactionState =
        _interactionSnapshot?.state ?? _localInteractionState(content);
    late final ImDynamicRenderContext renderContext;
    renderContext = ImDynamicRenderContext(
      messageId: widget.messageId,
      contentId: content.id,
      onEvent: widget.onEvent,
      onAction:
          (source, event, definition, payload) =>
              _applyLocalAction(_runtime!, source, event, definition, payload),
      state: <String, dynamic>{
        'lifecycle': state.lifecycle.name,
        ...state.values,
        ...interactionState,
        'interaction_closed':
            _interactionSnapshot?.closed ?? _interactionClosed(content),
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
    final rendered = _buildNode(
      context,
      content.tree,
      components,
      renderContext,
      content.fallback,
    );
    if (!_hasInteraction(content)) return rendered;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        rendered,
        const SizedBox(height: 10),
        _buildInteractionSummary(context, content),
      ],
    );
  }

  bool _hasInteraction(ImDynamicContent content) {
    return content.metadata['interaction'] is Map ||
        content.metadata['interaction_state'] is Map;
  }

  Future<void> _loadInteractions() async {
    final loader = widget.onLoadInteractions;
    if (loader == null || !_hasInteraction(widget.content)) return;
    final generation = ++_interactionLoadGeneration;
    if (mounted) setState(() => _loadingInteractions = true);
    try {
      final snapshot = await loader();
      if (!mounted || generation != _interactionLoadGeneration) return;
      setState(() {
        _interactionSnapshot = snapshot;
        _interactionError = null;
        _loadingInteractions = false;
      });
    } on Object catch (error) {
      if (!mounted || generation != _interactionLoadGeneration) return;
      setState(() {
        _interactionError = error;
        _loadingInteractions = false;
      });
    }
  }

  Map<String, dynamic> _localInteractionState(ImDynamicContent content) {
    final raw = content.metadata['interaction_state'];
    return raw is Map ? Map<String, dynamic>.from(raw) : const {};
  }

  Widget _buildInteractionSummary(
    BuildContext context,
    ImDynamicContent content,
  ) {
    final snapshot = _interactionSnapshot;
    final localState = _localInteractionState(content);
    final state = snapshot?.state ?? localState;
    final responded =
        snapshot?.responded ?? (state['responded'] as num?)?.toInt() ?? 0;
    final total = snapshot?.total ?? (state['total'] as num?)?.toInt() ?? 0;
    final closed = snapshot?.closed ?? state['closed'] == true;
    final status = snapshot?.status ?? '${state['status'] ?? 'active'}';
    final progress =
        snapshot?.progress ??
        (total > 0 ? (responded / total).clamp(0.0, 1.0) : 0.0);
    final scheme = Theme.of(context).colorScheme;
    final statusColor = closed ? scheme.outline : scheme.primary;
    return Container(
      key: const ValueKey('dynamic-interaction-summary'),
      padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                closed ? Icons.lock_outline : Icons.touch_app_outlined,
                size: 16,
                color: statusColor,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  closed ? 'Closed · $status' : status,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelMedium,
                ),
              ),
              if (_loadingInteractions)
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              IconButton(
                tooltip: 'View responses',
                visualDensity: VisualDensity.compact,
                onPressed: () => _openInteractionDetails(context),
                icon: const Icon(Icons.people_alt_outlined, size: 18),
              ),
            ],
          ),
          if (total > 0) ...[
            const SizedBox(height: 4),
            LinearProgressIndicator(value: progress),
            const SizedBox(height: 4),
            Text(
              '$responded / $total responded',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ] else if (_interactionError != null)
            Text(
              'Response details unavailable',
              style: Theme.of(context).textTheme.bodySmall,
            ),
        ],
      ),
    );
  }

  Future<void> _openInteractionDetails(BuildContext context) async {
    if (_interactionSnapshot == null && widget.onLoadInteractions != null) {
      await _loadInteractions();
    }
    if (!context.mounted) return;
    final snapshot = _interactionSnapshot;
    if (snapshot == null) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('Response details unavailable')),
      );
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => _InteractionDetailsSheet(snapshot: snapshot),
    );
  }

  bool _interactionClosed(ImDynamicContent content) {
    final rawState = content.metadata['interaction_state'];
    return rawState is Map && rawState['closed'] == true;
  }

  void _applyLocalAction(
    ImDynamicRuntime runtime,
    ImDynamicNode source,
    String event,
    Map<String, dynamic> definition,
    Map<String, dynamic> payload,
  ) {
    final action = definition['action']?.toString();
    if (action == null || action.isEmpty) return;
    final targetId =
        definition['target']?.toString() ??
        definition['target_node_id']?.toString();
    if (targetId == null || targetId.isEmpty) return;
    final property = definition['property']?.toString() ?? 'text';
    final rawValue = definition['value'];
    final value = _resolveActionValue(rawValue, payload);
    if (value == null &&
        !definition.containsKey('value') &&
        action != 'toggle') {
      return;
    }

    // Actions are declarative and constrained to the same patch surface used
    // by server updates. This keeps a button from executing arbitrary code.
    switch (action) {
      case 'set_property':
      case 'set_value':
      case 'set_status':
      case 'toggle':
        final current = runtime.content.tree.findById(targetId);
        if (current == null) return;
        final nextValue =
            action == 'toggle' ? !(current.props[property] == true) : value;
        runtime.apply(
          ImDynamicPatchSet(
            messageId: widget.messageId,
            contentId: runtime.content.id,
            patches: [
              ImDynamicPatch(
                operation: ImDynamicPatchOperation.update,
                nodeId: targetId,
                props: {property: nextValue},
              ),
            ],
          ),
        );
    }
  }

  Object? _resolveActionValue(Object? value, Map<String, dynamic> payload) {
    if (value is String && value == r'$payload.value') {
      return payload['value'];
    }
    if (value is String && value.startsWith(r'$payload.')) {
      return payload[value.substring(r'$payload.'.length)];
    }
    return value;
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

class _InteractionDetailsSheet extends StatelessWidget {
  const _InteractionDetailsSheet({required this.snapshot});

  final ImDynamicInteractionSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final events = snapshot.events;
    return SafeArea(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 560),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Responses',
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                  Text(
                    '${snapshot.responded}/${snapshot.total}',
                    style: theme.textTheme.labelLarge,
                  ),
                ],
              ),
              const SizedBox(height: 6),
              LinearProgressIndicator(value: snapshot.progress),
              const SizedBox(height: 12),
              if (events.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 20),
                  child: Text('No visible responses yet.'),
                )
              else
                Flexible(
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: events.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final event = events[index];
                      final actor =
                          event.actorNickname ?? event.actorId ?? 'Anonymous';
                      final value = _interactionValue(event);
                      final timestamp = event.createdAt;
                      return ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: CircleAvatar(
                          radius: 16,
                          child: Text(
                            actor.isEmpty
                                ? '?'
                                : actor.substring(0, 1).toUpperCase(),
                          ),
                        ),
                        title: Text(actor),
                        subtitle: Text(
                          [
                            if (event.actorKind != null) event.actorKind!,
                            if (value.isNotEmpty) value,
                            if (timestamp != null) _formatTime(timestamp),
                          ].join(' · '),
                        ),
                        isThreeLine: false,
                      );
                    },
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  String _interactionValue(ImDynamicInteractionEvent event) {
    final value = event.payload['value'] ?? event.payload['option'];
    if (value != null) return '$value';
    if (event.payload.isNotEmpty) return jsonEncode(event.payload);
    return event.action ?? event.event;
  }

  String _formatTime(DateTime value) {
    final local = value.toLocal();
    final hour = local.hour.toString().padLeft(2, '0');
    final minute = local.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }
}
