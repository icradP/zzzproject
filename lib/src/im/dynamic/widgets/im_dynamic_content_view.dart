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
    final actionName = action.toLowerCase();
    final hasProgressProjection = _hasProgressProjection(definition);
    var targetId =
        definition['target']?.toString() ??
        definition['target_node_id']?.toString();
    if (targetId == null || targetId.isEmpty) {
      targetId =
          hasProgressProjection
              ? _progressNodeId(runtime.content.tree, definition)
              : _firstNodeId(
                runtime.content.tree,
                actionName == 'set_progress' ||
                        actionName == 'increment_progress'
                    ? 'progress'
                    : 'status',
              );
    }
    final property = definition['property']?.toString() ?? 'text';
    final rawValue = definition['value'];
    var value = _resolveActionValue(rawValue, payload);
    final target =
        targetId == null ? null : runtime.content.tree.findById(targetId);
    if (target == null &&
        (hasProgressProjection ||
            actionName == 'set_status' ||
            actionName.startsWith('approve') ||
            actionName.startsWith('reject'))) {
      targetId = _progressNodeId(runtime.content.tree, definition);
    }
    final resolvedTargetId = targetId;
    if (resolvedTargetId == null || resolvedTargetId.isEmpty) return;
    final resolvedTarget = runtime.content.tree.findById(resolvedTargetId);
    if (resolvedTarget == null) return;
    if (!definition.containsKey('value') &&
        (actionName == 'set_status' ||
            actionName.startsWith('approve') ||
            actionName.startsWith('reject'))) {
      value = true;
    }
    if (value == null &&
        !definition.containsKey('value') &&
        actionName != 'toggle' &&
        actionName != 'increment_progress' &&
        !hasProgressProjection) {
      return;
    }

    // A producer may use a domain-specific action name (for example
    // `mark_read` or `complete_step`). The server does not need to know that
    // name to project progress: declared projection fields are sufficient.
    const supportedActions = {
      'set_property',
      'set_value',
      'set_status',
      'toggle',
      'set_progress',
      'increment_progress',
      'approve',
      'approved',
      'allow',
      'confirm',
      'confirmed',
      'yes',
      'complete',
      'completed',
      'reject',
      'rejected',
      'deny',
      'denied',
      'no',
      'cancel',
      'cancelled',
    };
    if (!supportedActions.contains(actionName)) {
      if (!hasProgressProjection) return;
      final progressNode =
          resolvedTarget.type == 'progress'
              ? resolvedTarget
              : runtime.content.tree.findById(
                _progressNodeId(runtime.content.tree, definition) ?? '',
              );
      if (progressNode == null) return;
      final currentValue = _number(progressNode.props['value']);
      final absoluteValue =
          _projectionValue(definition, 'progress') ??
          _projectionValue(definition, 'progress_value');
      final deltaValue =
          _projectionValue(definition, 'progress_delta') ??
          _projectionValue(definition, 'increment');
      var next = _number(absoluteValue);
      if (_numberValue(absoluteValue) == null) {
        if (_numberValue(deltaValue) != null) {
          next = currentValue + _number(deltaValue);
        } else {
          final total = _number(_projectionValue(definition, 'total'));
          next = currentValue + (total > 0 ? 1 / total : 0.1);
        }
      }
      if (next > 1) next /= 100;
      next = next.clamp(0.0, 1.0);
      final props = <String, dynamic>{'value': next};
      if (progressNode.props.containsKey('text')) {
        props['text'] = '${(next * 100).round()}%';
      }
      runtime.apply(
        ImDynamicPatchSet(
          messageId: widget.messageId,
          contentId: runtime.content.id,
          patches: [
            ImDynamicPatch(
              operation: ImDynamicPatchOperation.update,
              nodeId: progressNode.id,
              props: props,
            ),
          ],
        ),
      );
      return;
    }

    // Actions are declarative and constrained to the same patch surface used
    // by server updates. This keeps a button from executing arbitrary code.
    switch (actionName) {
      case 'set_property':
      case 'set_value':
      case 'set_status':
      case 'toggle':
      case 'set_progress':
      case 'increment_progress':
      case 'approve':
      case 'approved':
      case 'allow':
      case 'confirm':
      case 'confirmed':
      case 'yes':
      case 'complete':
      case 'completed':
      case 'reject':
      case 'rejected':
      case 'deny':
      case 'denied':
      case 'no':
      case 'cancel':
      case 'cancelled':
        final current = resolvedTarget;
        final nextValue =
            actionName == 'toggle' ? !(current.props[property] == true) : value;
        final props = <String, dynamic>{};
        if (actionName.startsWith('approve') ||
            actionName.startsWith('allow') ||
            actionName.startsWith('confirm') ||
            actionName == 'yes' ||
            actionName.startsWith('complete') ||
            actionName.startsWith('reject') ||
            actionName.startsWith('deny') ||
            actionName == 'no' ||
            actionName.startsWith('cancel')) {
          props['text'] =
              actionName.startsWith('reject') ||
                      actionName.startsWith('deny') ||
                      actionName == 'no' ||
                      actionName.startsWith('cancel')
                  ? 'Rejected'
                  : 'Approved';
        } else if (actionName == 'set_progress' ||
            actionName == 'increment_progress') {
          props['value'] = nextValue;
        } else if (actionName != 'set_status' || current.type != 'progress') {
          props[property] = nextValue;
        }
        final patches = <ImDynamicPatch>[];
        if (props.isNotEmpty) {
          patches.add(
            ImDynamicPatch(
              operation: ImDynamicPatchOperation.update,
              nodeId: resolvedTargetId,
              props: props,
            ),
          );
        }
        final isLegacyProgressAction =
            actionName == 'set_status' ||
            actionName == 'set_progress' ||
            actionName == 'increment_progress' ||
            actionName.startsWith('approve') ||
            actionName.startsWith('allow') ||
            actionName.startsWith('confirm') ||
            actionName == 'yes' ||
            actionName.startsWith('complete') ||
            actionName.startsWith('reject') ||
            actionName.startsWith('deny') ||
            actionName == 'no' ||
            actionName.startsWith('cancel');
        if (hasProgressProjection || isLegacyProgressAction) {
          final progressNode =
              resolvedTarget.type == 'progress'
                  ? resolvedTarget
                  : runtime.content.tree.findById(
                    _progressNodeId(runtime.content.tree, definition) ?? '',
                  );
          if (progressNode != null) {
            final currentValue = _number(progressNode.props['value']);
            final absoluteValue =
                _projectionValue(definition, 'progress') ??
                _projectionValue(definition, 'progress_value');
            final deltaValue =
                _projectionValue(definition, 'progress_delta') ??
                _projectionValue(definition, 'increment');
            var next = _number(absoluteValue);
            final hasAbsolute = _numberValue(absoluteValue) != null;
            final hasDelta = _numberValue(deltaValue) != null;
            final numericStatus = _numberValue(value);
            if (!hasAbsolute && hasDelta) {
              next = currentValue + _number(deltaValue);
            } else if (!hasAbsolute && actionName == 'set_progress') {
              next = _number(value);
            } else if (!hasAbsolute && actionName == 'increment_progress') {
              next = currentValue + _number(value);
            } else if (!hasAbsolute &&
                actionName == 'set_status' &&
                numericStatus != null) {
              next = numericStatus;
            } else if (!hasAbsolute && !hasDelta && isLegacyProgressAction) {
              final total = _number(_projectionValue(definition, 'total'));
              next = currentValue + (total > 0 ? 1 / total : 0.1);
            } else if (!hasAbsolute && !hasDelta && !hasProgressProjection) {
              next = currentValue;
            }
            if (next > 1) next /= 100;
            next = next.clamp(0.0, 1.0);
            final progressProps = <String, dynamic>{'value': next};
            if (progressNode.props.containsKey('text')) {
              progressProps['text'] = '${(next * 100).round()}%';
            }
            if (progressNode.id == resolvedTargetId) {
              props.addAll(progressProps);
              if (patches.isEmpty) {
                patches.add(
                  ImDynamicPatch(
                    operation: ImDynamicPatchOperation.update,
                    nodeId: resolvedTargetId,
                    props: props,
                  ),
                );
              } else {
                patches[0] = ImDynamicPatch(
                  operation: ImDynamicPatchOperation.update,
                  nodeId: resolvedTargetId,
                  props: props,
                );
              }
            } else {
              patches.add(
                ImDynamicPatch(
                  operation: ImDynamicPatchOperation.update,
                  nodeId: progressNode.id,
                  props: progressProps,
                ),
              );
            }
          }
        }
        if (patches.isEmpty) return;
        runtime.apply(
          ImDynamicPatchSet(
            messageId: widget.messageId,
            contentId: runtime.content.id,
            patches: patches,
          ),
        );
    }
  }

  String? _firstNodeId(ImDynamicNode node, String type) {
    if (node.type == type) return node.id;
    for (final child in node.children) {
      final found = _firstNodeId(child, type);
      if (found != null) return found;
    }
    return null;
  }

  Object? _projectionValue(Map<String, dynamic> definition, String key) {
    if (definition.containsKey(key)) return definition[key];
    final projection = definition['projection'];
    if (projection is Map && projection.containsKey(key)) {
      return projection[key];
    }
    return null;
  }

  bool _hasProgressProjection(Map<String, dynamic> definition) {
    for (final key in const [
      'progress',
      'progress_value',
      'progress_delta',
      'increment',
      'progress_node_id',
      'progress_target',
      'total',
    ]) {
      final value = _projectionValue(definition, key);
      if (value == null) continue;
      if (key == 'progress_node_id' || key == 'progress_target') {
        if ('$value'.trim().isNotEmpty) return true;
      } else if (_numberValue(value) != null) {
        return true;
      }
    }
    return false;
  }

  String? _progressNodeId(ImDynamicNode root, Map<String, dynamic> definition) {
    for (final key in const ['progress_node_id', 'progress_target']) {
      final value = _projectionValue(definition, key);
      if (value is String && value.trim().isNotEmpty) return value.trim();
    }
    final progress = _projectionValue(definition, 'progress');
    if (progress is String &&
        progress.trim().isNotEmpty &&
        root.findById(progress.trim()) != null) {
      return progress.trim();
    }
    return _firstNodeId(root, 'progress');
  }

  double? _numberValue(Object? value) {
    if (value is num && value.isFinite) return value.toDouble();
    final parsed = double.tryParse('${value ?? ''}'.trim());
    return parsed != null && parsed.isFinite ? parsed : null;
  }

  double _number(Object? value) {
    if (value is num && value.isFinite) return value.toDouble();
    return double.tryParse('${value ?? ''}') ?? 0;
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
