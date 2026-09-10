import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../models/im_dynamic_command.dart';
import '../models/im_dynamic_models.dart';
import '../widgets/im_dynamic_content_view.dart';
import 'im_dynamic_editor_controller.dart';

/// A low-code editor for the controlled Dynamic Content schema.
///
/// The palette creates schema nodes, never Flutter widgets. Layout nodes are
/// explicit, leaf nodes are automatically inserted beside the selected leaf,
/// and the preview uses the same runtime as a chat bubble.
class ImDynamicEditor extends StatefulWidget {
  const ImDynamicEditor({
    required this.controller,
    required this.messageId,
    this.onSave,
    this.creating = false,
    super.key,
  });

  final ImDynamicEditorController controller;
  final String messageId;
  final ValueChanged<ImDynamicCommand>? onSave;
  final bool creating;

  @override
  State<ImDynamicEditor> createState() => _ImDynamicEditorState();
}

class _ImDynamicEditorState extends State<ImDynamicEditor> {
  late final TextEditingController _textController;

  static const _palette = <String, String>{
    'text': 'Text',
    'markdown': 'Markdown',
    'row': 'Row',
    'column': 'Column',
    'card': 'Card',
    'container': 'Container',
    'divider': 'Divider',
    'icon': 'Icon',
    'badge': 'Badge',
    'button': 'Button',
    'status': 'Status',
    'progress': 'Progress',
    'input': 'Input',
    'checkbox': 'Checkbox',
    'select': 'Select',
  };

  @override
  void initState() {
    super.initState();
    _textController = TextEditingController();
    widget.controller.addListener(_handleControllerChanged);
    _syncText();
  }

  @override
  void didUpdateWidget(ImDynamicEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller == widget.controller) return;
    oldWidget.controller.removeListener(_handleControllerChanged);
    widget.controller.addListener(_handleControllerChanged);
    _syncText();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_handleControllerChanged);
    _textController.dispose();
    super.dispose();
  }

  void _handleControllerChanged() {
    if (!mounted) return;
    setState(_syncText);
  }

  void _syncText() {
    final node = widget.controller.selectedNode;
    final value =
        node?.props['text']?.toString() ??
        node?.props['content']?.toString() ??
        '';
    if (_textController.text == value) return;
    _textController.value = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final selected = controller.selectedNode;
    return Card(
      key: const ValueKey('dynamic-editor'),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildToolbar(context, controller),
          const Divider(height: 1),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                if (constraints.maxWidth < 760) {
                  return _buildCompactEditor(context, controller, selected);
                }
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(
                      width: 230,
                      child: _buildTree(context, controller),
                    ),
                    const VerticalDivider(width: 1),
                    SizedBox(
                      width: 300,
                      child: _buildProperties(context, controller, selected),
                    ),
                    const VerticalDivider(width: 1),
                    Expanded(child: _buildPreview(context, controller)),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCompactEditor(
    BuildContext context,
    ImDynamicEditorController controller,
    ImDynamicNode? selected,
  ) {
    return DefaultTabController(
      length: 3,
      child: Column(
        children: [
          const TabBar(
            tabs: [
              Tab(text: 'Components'),
              Tab(text: 'Properties'),
              Tab(text: 'Preview'),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: [
                _buildTree(context, controller),
                _buildProperties(context, controller, selected),
                _buildPreview(context, controller),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildToolbar(
    BuildContext context,
    ImDynamicEditorController controller,
  ) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(
        children: [
          IconButton(
            tooltip: 'Undo',
            onPressed: controller.canUndo ? controller.undo : null,
            icon: const Icon(Icons.undo_rounded),
          ),
          IconButton(
            tooltip: 'Redo',
            onPressed: controller.canRedo ? controller.redo : null,
            icon: const Icon(Icons.redo_rounded),
          ),
          const SizedBox(width: 8),
          Text(
            'Dynamic Content',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(width: 16),
          FilledButton.icon(
            key: const ValueKey('dynamic-editor-save'),
            onPressed:
                widget.onSave == null
                    ? null
                    : () => widget.onSave!(
                      widget.creating
                          ? controller.buildCreateCommand(
                            messageId: widget.messageId,
                          )
                          : controller.buildSaveCommand(
                            messageId: widget.messageId,
                          ),
                    ),
            icon: const Icon(Icons.save_outlined),
            label: Text(widget.creating ? 'Create' : 'Save'),
          ),
          if (!widget.creating && widget.onSave != null) ...[
            const SizedBox(width: 4),
            IconButton(
              key: const ValueKey('dynamic-editor-remove-content'),
              tooltip: 'Remove dynamic content',
              onPressed:
                  () => widget.onSave!(
                    controller.buildRemoveCommand(messageId: widget.messageId),
                  ),
              icon: const Icon(Icons.delete_outline),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildTree(
    BuildContext context,
    ImDynamicEditorController controller,
  ) {
    final target = controller.insertionParent();
    return ListView(
      padding: const EdgeInsets.all(8),
      children: [
        Text('Components', style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 4),
        _buildNodeTile(context, controller, controller.content.tree, 0),
        const Divider(),
        Text(
          'Add to ${target.id} (${target.type})',
          key: const ValueKey('dynamic-editor-insertion-target'),
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 6),
        DropdownButtonFormField<String>(
          key: const ValueKey('dynamic-editor-add-type'),
          initialValue: 'text',
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Add component'),
          items: [
            for (final entry in _palette.entries)
              DropdownMenuItem(value: entry.key, child: Text(entry.value)),
          ],
          onChanged: (type) {
            if (type == null) return;
            final id = _newNodeId(controller.content.tree, type);
            controller.addNode(
              parentNodeId: controller.insertionParent().id,
              node: _defaultNode(id, type),
            );
          },
        ),
      ],
    );
  }

  Widget _buildNodeTile(
    BuildContext context,
    ImDynamicEditorController controller,
    ImDynamicNode node,
    int depth,
  ) {
    final selected = controller.selectedNodeId == node.id;
    final canContain = controller.canContainChildren(node);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          dense: true,
          selected: selected,
          contentPadding: EdgeInsets.only(left: depth * 14.0, right: 0),
          leading: Icon(
            canContain ? Icons.account_tree_outlined : Icons.circle_outlined,
            size: 16,
          ),
          title: Text(node.id, overflow: TextOverflow.ellipsis),
          subtitle: Text(node.type),
          onTap: () => controller.selectNode(node.id),
        ),
        for (final child in node.children)
          _buildNodeTile(context, controller, child, depth + 1),
      ],
    );
  }

  Widget _buildProperties(
    BuildContext context,
    ImDynamicEditorController controller,
    ImDynamicNode? node,
  ) {
    if (node == null) return const Center(child: Text('Select a component'));
    final props = node.props;
    final canDelete = node.id != controller.content.tree.id;
    return ListView(
      padding: const EdgeInsets.all(14),
      children: [
        Text(node.type, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 12),
        TextField(
          key: const ValueKey('dynamic-editor-text'),
          controller: _textController,
          decoration: InputDecoration(
            labelText: node.type == 'markdown' ? 'Content' : 'Text / content',
          ),
          onSubmitted: (value) {
            // Resolve the selection at submit time as well as at build time.
            // This keeps keyboard submission reliable while the tree selection
            // is being changed in the adjacent panel.
            final selected = controller.selectedNode ?? node;
            final key = selected.type == 'markdown' ? 'content' : 'text';
            controller.updateNode(
              nodeId: selected.id,
              props: {...selected.props, key: value},
            );
          },
        ),
        if (node.type == 'progress') ...[
          _numberField(
            key: 'value',
            label: 'Progress (0-1)',
            value: props['value'],
            onChanged:
                (value) => controller.updateNode(
                  nodeId: node.id,
                  props: {...props, 'value': value.clamp(0.0, 1.0)},
                ),
          ),
          const SizedBox(height: 8),
          TextFormField(
            key: const ValueKey('dynamic-editor-progress-label'),
            decoration: const InputDecoration(labelText: 'Progress label'),
            initialValue: props['text']?.toString() ?? '',
            onFieldSubmitted:
                (value) => controller.updateNode(
                  nodeId: node.id,
                  props: {...props, 'text': value},
                ),
          ),
        ],
        if ({'row', 'column', 'card', 'container'}.contains(node.type))
          _buildLayoutProperties(context, controller, node),
        if (node.type == 'icon') ...[
          _textProperty(context, controller, node, 'name', 'Icon name'),
          _numberField(
            key: 'size',
            label: 'Icon size',
            value: props['size'],
            onChanged:
                (value) => controller.updateNode(
                  nodeId: node.id,
                  props: {...props, 'size': value},
                ),
          ),
        ],
        if (node.type == 'button' ||
            node.type == 'checkbox' ||
            node.type == 'input' ||
            node.type == 'select')
          _buildActionProperties(context, controller, node),
        if (canDelete) ...[
          const SizedBox(height: 20),
          OutlinedButton.icon(
            key: const ValueKey('dynamic-editor-delete'),
            onPressed: () => controller.removeNode(node.id),
            icon: const Icon(Icons.delete_outline),
            label: const Text('Remove component'),
          ),
        ],
        const SizedBox(height: 18),
        ImDynamicInteractionPolicyPanel(controller: controller),
      ],
    );
  }

  Widget _buildLayoutProperties(
    BuildContext context,
    ImDynamicEditorController controller,
    ImDynamicNode node,
  ) {
    final props = node.props;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _numberField(
          key: 'spacing',
          label: 'Spacing',
          value: props['spacing'],
          onChanged:
              (value) => controller.updateNode(
                nodeId: node.id,
                props: {...props, 'spacing': value},
              ),
        ),
        if (node.type == 'row') ...[
          const SizedBox(height: 8),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: const Text('Wrap children'),
            value: props['wrap'] == true,
            onChanged:
                (value) => controller.updateNode(
                  nodeId: node.id,
                  props: {...props, 'wrap': value},
                ),
          ),
        ],
        if (node.type == 'container' || node.type == 'card') ...[
          const SizedBox(height: 8),
          _numberField(
            key: 'padding',
            label: 'Padding',
            value: props['padding'],
            onChanged:
                (value) => controller.updateNode(
                  nodeId: node.id,
                  props: {...props, 'padding': value},
                ),
          ),
        ],
        const SizedBox(height: 8),
        DropdownButtonFormField<String>(
          key: const ValueKey('dynamic-editor-main-alignment'),
          initialValue: props['mainAxisAlignment']?.toString() ?? 'start',
          decoration: const InputDecoration(labelText: 'Main alignment'),
          items: const [
            DropdownMenuItem(value: 'start', child: Text('Start')),
            DropdownMenuItem(value: 'center', child: Text('Center')),
            DropdownMenuItem(value: 'end', child: Text('End')),
            DropdownMenuItem(
              value: 'spaceBetween',
              child: Text('Space between'),
            ),
          ],
          onChanged:
              (value) => controller.updateNode(
                nodeId: node.id,
                props: {...props, 'mainAxisAlignment': value},
              ),
        ),
        const SizedBox(height: 8),
        DropdownButtonFormField<String>(
          key: const ValueKey('dynamic-editor-cross-alignment'),
          initialValue: props['crossAxisAlignment']?.toString() ?? 'start',
          decoration: const InputDecoration(labelText: 'Cross alignment'),
          items: const [
            DropdownMenuItem(value: 'start', child: Text('Start')),
            DropdownMenuItem(value: 'center', child: Text('Center')),
            DropdownMenuItem(value: 'end', child: Text('End')),
            DropdownMenuItem(value: 'stretch', child: Text('Stretch')),
          ],
          onChanged:
              (value) => controller.updateNode(
                nodeId: node.id,
                props: {...props, 'crossAxisAlignment': value},
              ),
        ),
      ],
    );
  }

  Widget _buildActionProperties(
    BuildContext context,
    ImDynamicEditorController controller,
    ImDynamicNode node,
  ) {
    final definition =
        node.events['click'] ??
        node.events['change'] ??
        node.events['submit'] ??
        const <String, dynamic>{};
    final event = node.type == 'button' ? 'click' : 'change';
    final targetIds = _nodeIds(
      controller.content.tree,
    ).where((id) => id != node.id).toList(growable: false);
    final target = definition['target']?.toString();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 12),
        Text('Action link', style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 6),
        TextFormField(
          key: const ValueKey('dynamic-editor-action'),
          initialValue: definition['action']?.toString() ?? '',
          decoration: const InputDecoration(labelText: 'Action name'),
          onFieldSubmitted:
              (value) => controller.setNodeEvent(
                nodeId: node.id,
                event: event,
                action: value,
                targetNodeId: target,
                property: definition['property']?.toString(),
                value: definition['value'],
              ),
        ),
        const SizedBox(height: 8),
        DropdownButtonFormField<String>(
          key: const ValueKey('dynamic-editor-action-target'),
          initialValue: targetIds.contains(target) ? target : null,
          decoration: const InputDecoration(labelText: 'Target component'),
          items: [
            for (final id in targetIds)
              DropdownMenuItem(value: id, child: Text(id)),
          ],
          onChanged:
              (value) => controller.setNodeEvent(
                nodeId: node.id,
                event: event,
                action: definition['action']?.toString() ?? 'set_property',
                targetNodeId: value,
                property: definition['property']?.toString() ?? 'text',
                value: definition['value'] ?? 'Updated',
              ),
        ),
        const SizedBox(height: 8),
        TextFormField(
          key: const ValueKey('dynamic-editor-action-property'),
          initialValue: definition['property']?.toString() ?? 'text',
          decoration: const InputDecoration(labelText: 'Target property'),
          onFieldSubmitted:
              (value) => controller.setNodeEvent(
                nodeId: node.id,
                event: event,
                action: definition['action']?.toString() ?? 'set_property',
                targetNodeId: target,
                property: value,
                value: definition['value'] ?? 'Updated',
              ),
        ),
        const SizedBox(height: 8),
        TextFormField(
          key: const ValueKey('dynamic-editor-action-value'),
          initialValue: definition['value']?.toString() ?? 'Updated',
          decoration: const InputDecoration(labelText: 'Target value'),
          onFieldSubmitted:
              (value) => controller.setNodeEvent(
                nodeId: node.id,
                event: event,
                action: definition['action']?.toString() ?? 'set_property',
                targetNodeId: target,
                property: definition['property']?.toString() ?? 'text',
                value: value,
              ),
        ),
      ],
    );
  }

  Widget _textProperty(
    BuildContext context,
    ImDynamicEditorController controller,
    ImDynamicNode node,
    String key,
    String label,
  ) => TextFormField(
    initialValue: node.props[key]?.toString() ?? '',
    decoration: InputDecoration(labelText: label),
    onFieldSubmitted:
        (value) => controller.updateNode(
          nodeId: node.id,
          props: {...node.props, key: value},
        ),
  );

  Widget _numberField({
    required String key,
    required String label,
    required Object? value,
    required ValueChanged<double> onChanged,
  }) => TextFormField(
    key: ValueKey('dynamic-editor-$key'),
    initialValue: value?.toString() ?? '',
    keyboardType: const TextInputType.numberWithOptions(decimal: true),
    decoration: InputDecoration(labelText: label),
    onFieldSubmitted: (raw) {
      final parsed = double.tryParse(raw);
      if (parsed != null) onChanged(parsed);
    },
  );

  Widget _buildPreview(
    BuildContext context,
    ImDynamicEditorController controller,
  ) => ListView(
    padding: const EdgeInsets.all(16),
    children: [
      Text('Preview', style: Theme.of(context).textTheme.titleSmall),
      const SizedBox(height: 12),
      DecoratedBox(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: ImDynamicContentView(
            key: ValueKey('dynamic-editor-preview-${controller.content.id}'),
            content: controller.content,
            messageId: widget.messageId,
          ),
        ),
      ),
    ],
  );

  ImDynamicNode _defaultNode(String id, String type) => ImDynamicNode(
    id: id,
    type: type,
    props: switch (type) {
      'row' => const {'spacing': 8.0},
      'column' => const {'spacing': 6.0},
      'card' => const {'padding': 10.0, 'spacing': 6.0},
      'container' => const {'padding': 8.0, 'spacing': 6.0},
      'button' => const {'text': 'Action'},
      'status' => const {'text': 'Status'},
      'progress' => const {'value': 0.0, 'text': '0%'},
      'icon' => const {'name': 'info'},
      'badge' => const {'text': 'Badge'},
      'input' => const {'placeholder': 'Value'},
      'checkbox' => const {'text': 'Check me', 'value': false},
      'select' => const {
        'label': 'Choose',
        'options': ['One', 'Two'],
      },
      _ => const {'text': 'New text'},
    },
  );

  String _newNodeId(ImDynamicNode root, String type) {
    var index = 1;
    while (root.findById('$type-$index') != null) {
      index++;
    }
    return '$type-$index';
  }

  List<String> _nodeIds(ImDynamicNode root) {
    final result = <String>[];
    void visit(ImDynamicNode node) {
      result.add(node.id);
      for (final child in node.children) {
        visit(child);
      }
    }

    visit(root);
    return result;
  }
}

/// Standalone low-code editor for the behavior of an interactive card.
/// Layout and component actions remain in [ImDynamicEditor]; this panel only
/// edits the transport-safe interaction contract under `metadata.interaction`.
class ImDynamicInteractionPolicyPanel extends StatelessWidget {
  const ImDynamicInteractionPolicyPanel({required this.controller, super.key});

  final ImDynamicEditorController controller;

  @override
  Widget build(BuildContext context) {
    final raw = controller.content.metadata['interaction'];
    final interaction =
        raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{};
    final policy =
        interaction['policy'] is Map
            ? Map<String, dynamic>.from(interaction['policy'] as Map)
            : <String, dynamic>{};
    final routing =
        interaction['routing'] is Map
            ? Map<String, dynamic>.from(interaction['routing'] as Map)
            : <String, dynamic>{};
    final projection =
        interaction['projection'] is Map
            ? Map<String, dynamic>.from(interaction['projection'] as Map)
            : <String, dynamic>{};

    void update({
      String? reducer,
      String? response,
      String? visibility,
      String? fairyRoute,
      int? total,
      int? quorum,
      bool? allowChange,
      bool? allowAgent,
      bool? veto,
      String? initialState,
      int? expiresAtMS,
      int? maxResponsesPerActor,
      List<String>? audience,
      Map<String, dynamic>? transitions,
      int? threshold,
      String? progressNodeId,
      String? statusNodeId,
      String? progressText,
    }) {
      final nextPolicy = <String, dynamic>{...policy};
      if (response != null) nextPolicy['response'] = response;
      if (visibility != null) nextPolicy['visibility'] = visibility;
      if (total != null) nextPolicy['total'] = total;
      if (quorum != null) nextPolicy['quorum'] = quorum;
      if (allowChange != null) nextPolicy['allow_change'] = allowChange;
      if (allowAgent != null) nextPolicy['allow_agent'] = allowAgent;
      if (veto != null) nextPolicy['veto'] = veto;
      if (initialState != null) nextPolicy['initial_state'] = initialState;
      if (expiresAtMS != null) nextPolicy['expires_at_ms'] = expiresAtMS;
      if (maxResponsesPerActor != null) {
        nextPolicy['max_responses_per_actor'] = maxResponsesPerActor;
      }
      if (audience != null) nextPolicy['audience'] = audience;
      if (transitions != null) nextPolicy['transitions'] = transitions;
      final nextRouting = <String, dynamic>{...routing};
      if (fairyRoute != null) nextRouting['fairy'] = fairyRoute;
      if (threshold != null) nextRouting['threshold'] = threshold;
      final nextProjection = <String, dynamic>{...projection};
      if (progressNodeId != null) {
        nextProjection['progress_node_id'] = progressNodeId;
      }
      if (statusNodeId != null) nextProjection['status_node_id'] = statusNodeId;
      if (progressText != null) nextProjection['progress_text'] = progressText;
      controller.updateInteractionConfig({
        ...interaction,
        if (reducer != null) 'reducer': reducer,
        'policy': nextPolicy,
        'routing': nextRouting,
        'projection': nextProjection,
      });
    }

    return ExpansionTile(
      key: const ValueKey('dynamic-interaction-policy-panel'),
      initiallyExpanded: interaction.isNotEmpty,
      tilePadding: EdgeInsets.zero,
      childrenPadding: EdgeInsets.zero,
      leading: const Icon(Icons.tune_outlined),
      title: const Text('Interaction policy'),
      subtitle: Text(
        interaction.isEmpty
            ? 'Optional response, visibility and Fairy routing'
            : '${interaction['reducer'] ?? 'none'} · ${policy['visibility'] ?? 'public_aggregate'}',
      ),
      children: [
        DropdownButtonFormField<String>(
          key: const ValueKey('dynamic-policy-reducer'),
          initialValue:
              const {
                    'set_by_actor',
                    'append',
                    'counter',
                    'checklist',
                    'form',
                    'approval_quorum',
                    'state_machine',
                    'none',
                  }.contains(interaction['reducer'])
                  ? interaction['reducer'] as String
                  : 'none',
          decoration: const InputDecoration(labelText: 'Reducer'),
          items: const [
            DropdownMenuItem(value: 'none', child: Text('None')),
            DropdownMenuItem(
              value: 'set_by_actor',
              child: Text('Set by actor'),
            ),
            DropdownMenuItem(value: 'append', child: Text('Append events')),
            DropdownMenuItem(value: 'counter', child: Text('Counter')),
            DropdownMenuItem(value: 'checklist', child: Text('Checklist')),
            DropdownMenuItem(value: 'form', child: Text('Form')),
            DropdownMenuItem(
              value: 'approval_quorum',
              child: Text('Approval quorum'),
            ),
            DropdownMenuItem(
              value: 'state_machine',
              child: Text('State machine'),
            ),
          ],
          onChanged: (value) => update(reducer: value),
        ),
        const SizedBox(height: 8),
        DropdownButtonFormField<String>(
          key: const ValueKey('dynamic-policy-response'),
          initialValue: policy['response'] == 'many' ? 'many' : 'once',
          decoration: const InputDecoration(labelText: 'Responses per actor'),
          items: const [
            DropdownMenuItem(value: 'once', child: Text('One response')),
            DropdownMenuItem(value: 'many', child: Text('Multiple responses')),
          ],
          onChanged: (value) => update(response: value),
        ),
        const SizedBox(height: 8),
        DropdownButtonFormField<String>(
          key: const ValueKey('dynamic-policy-visibility'),
          initialValue:
              const {
                    'public_aggregate',
                    'public_detail',
                    'admin_detail',
                    'actor_only',
                    'anonymous_aggregate',
                  }.contains(policy['visibility'])
                  ? policy['visibility'] as String
                  : 'public_aggregate',
          decoration: const InputDecoration(labelText: 'Response visibility'),
          items: const [
            DropdownMenuItem(
              value: 'public_aggregate',
              child: Text('Everyone: aggregate'),
            ),
            DropdownMenuItem(
              value: 'public_detail',
              child: Text('Everyone: details'),
            ),
            DropdownMenuItem(
              value: 'admin_detail',
              child: Text('Admins: details'),
            ),
            DropdownMenuItem(value: 'actor_only', child: Text('Actor only')),
            DropdownMenuItem(
              value: 'anonymous_aggregate',
              child: Text('Anonymous aggregate'),
            ),
          ],
          onChanged: (value) => update(visibility: value),
        ),
        const SizedBox(height: 8),
        _InteractionIntField(
          key: const ValueKey('dynamic-policy-total'),
          label: 'Expected participants',
          value: (policy['total'] as num?)?.toInt() ?? 0,
          onChanged: (value) => update(total: value),
        ),
        _InteractionIntField(
          key: const ValueKey('dynamic-policy-quorum'),
          label: 'Approval quorum',
          value: (policy['quorum'] as num?)?.toInt() ?? 0,
          onChanged: (value) => update(quorum: value),
        ),
        _InteractionIntField(
          key: const ValueKey('dynamic-policy-max-responses'),
          label: 'Max responses per actor (0 = unlimited)',
          value: (policy['max_responses_per_actor'] as num?)?.toInt() ?? 0,
          onChanged: (value) => update(maxResponsesPerActor: value),
        ),
        _InteractionIntField(
          key: const ValueKey('dynamic-policy-expires-at'),
          label: 'Expires at (Unix milliseconds, 0 = never)',
          value: (policy['expires_at_ms'] as num?)?.toInt() ?? 0,
          onChanged: (value) => update(expiresAtMS: value),
        ),
        TextFormField(
          key: const ValueKey('dynamic-policy-audience'),
          initialValue:
              (policy['audience'] as List?)
                  ?.map((item) => '$item')
                  .join(', ') ??
              '',
          decoration: const InputDecoration(
            labelText: 'Audience roles (all, users, agents, admins, owner)',
          ),
          onFieldSubmitted:
              (value) => update(
                audience: value
                    .split(',')
                    .map((item) => item.trim())
                    .where((item) => item.isNotEmpty)
                    .toList(growable: false),
              ),
        ),
        SwitchListTile.adaptive(
          contentPadding: EdgeInsets.zero,
          title: const Text('Allow response changes'),
          value: policy['allow_change'] != false,
          onChanged: (value) => update(allowChange: value),
        ),
        SwitchListTile.adaptive(
          contentPadding: EdgeInsets.zero,
          title: const Text('Allow Fairy / Agent responses'),
          value: policy['allow_agent'] == true,
          onChanged: (value) => update(allowAgent: value),
        ),
        SwitchListTile.adaptive(
          contentPadding: EdgeInsets.zero,
          title: const Text('Reject on veto'),
          value: policy['veto'] != false,
          onChanged: (value) => update(veto: value),
        ),
        DropdownButtonFormField<String>(
          key: const ValueKey('dynamic-policy-fairy-route'),
          initialValue:
              const {
                    'manual',
                    'each_event',
                    'on_close',
                    'on_threshold',
                  }.contains(routing['fairy'])
                  ? routing['fairy'] as String
                  : 'manual',
          decoration: const InputDecoration(labelText: 'Fairy routing'),
          items: const [
            DropdownMenuItem(value: 'manual', child: Text('Manual')),
            DropdownMenuItem(
              value: 'each_event',
              child: Text('Every response'),
            ),
            DropdownMenuItem(value: 'on_close', child: Text('When closed')),
            DropdownMenuItem(
              value: 'on_threshold',
              child: Text('At threshold'),
            ),
          ],
          onChanged: (value) => update(fairyRoute: value),
        ),
        _InteractionIntField(
          key: const ValueKey('dynamic-policy-threshold'),
          label: 'Fairy threshold',
          value: (routing['threshold'] as num?)?.toInt() ?? 0,
          onChanged: (value) => update(threshold: value),
        ),
        if (interaction['reducer'] == 'state_machine')
          TextFormField(
            key: const ValueKey('dynamic-policy-initial-state'),
            initialValue: policy['initial_state']?.toString() ?? 'open',
            decoration: const InputDecoration(labelText: 'Initial state'),
            onFieldSubmitted: (value) => update(initialState: value.trim()),
          ),
        if (interaction['reducer'] == 'state_machine')
          TextFormField(
            key: const ValueKey('dynamic-policy-transitions'),
            initialValue: jsonEncode(policy['transitions'] ?? const {}),
            minLines: 2,
            maxLines: 4,
            decoration: const InputDecoration(
              labelText: 'Transitions JSON (state -> allowed states)',
            ),
            onFieldSubmitted: (value) {
              try {
                final decoded = jsonDecode(value);
                if (decoded is Map) {
                  update(transitions: Map<String, dynamic>.from(decoded));
                }
              } on FormatException {
                // Leave the previous transition map intact until valid JSON
                // is submitted again.
              }
            },
          ),
        const SizedBox(height: 8),
        Text('Projection nodes', style: Theme.of(context).textTheme.labelLarge),
        TextFormField(
          key: const ValueKey('dynamic-policy-progress-node'),
          initialValue: projection['progress_node_id']?.toString() ?? '',
          decoration: const InputDecoration(labelText: 'Progress node ID'),
          onFieldSubmitted: (value) => update(progressNodeId: value.trim()),
        ),
        TextFormField(
          key: const ValueKey('dynamic-policy-status-node'),
          initialValue: projection['status_node_id']?.toString() ?? '',
          decoration: const InputDecoration(labelText: 'Status node ID'),
          onFieldSubmitted: (value) => update(statusNodeId: value.trim()),
        ),
        TextFormField(
          key: const ValueKey('dynamic-policy-progress-text'),
          initialValue: projection['progress_text']?.toString() ?? '',
          decoration: const InputDecoration(
            labelText: 'Progress text template',
          ),
          onFieldSubmitted: (value) => update(progressText: value),
        ),
      ],
    );
  }
}

class _InteractionIntField extends StatelessWidget {
  const _InteractionIntField({
    required this.label,
    required this.value,
    required this.onChanged,
    super.key,
  });

  final String label;
  final int value;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) => TextFormField(
    initialValue: value == 0 ? '' : value.toString(),
    keyboardType: TextInputType.number,
    decoration: InputDecoration(labelText: label),
    onFieldSubmitted: (raw) {
      final parsed = int.tryParse(raw.trim());
      if (parsed != null && parsed >= 0) onChanged(parsed);
    },
  );
}

/// Standalone creation surface. Hosts can place it in a modal, side panel, or
/// route without coupling Dynamic Content creation to the chat composer.
class ImDynamicContentCreatorPanel extends StatefulWidget {
  const ImDynamicContentCreatorPanel({
    required this.messageId,
    required this.onCreate,
    super.key,
  });

  final String messageId;
  final FutureOr<void> Function(ImDynamicCommand command) onCreate;

  @override
  State<ImDynamicContentCreatorPanel> createState() =>
      _ImDynamicContentCreatorPanelState();
}

class _ImDynamicContentCreatorPanelState
    extends State<ImDynamicContentCreatorPanel> {
  late final ImDynamicEditorController _controller;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final token = DateTime.now().microsecondsSinceEpoch;
    _controller = ImDynamicEditorController(
      content: ImDynamicContent(
        id: 'user-content-$token',
        version: '1.0',
        source: ImDynamicContentSource.user,
        tree: const ImDynamicNode(
          id: 'root',
          type: 'column',
          props: {'spacing': 8.0},
          children: [
            ImDynamicNode(
              id: 'title',
              type: 'text',
              props: {'text': 'Interactive content'},
            ),
            ImDynamicNode(
              id: 'actions',
              type: 'row',
              props: {'spacing': 8.0},
              children: [
                ImDynamicNode(
                  id: 'status',
                  type: 'status',
                  props: {'text': 'Ready'},
                ),
                ImDynamicNode(
                  id: 'approve',
                  type: 'button',
                  props: {'text': 'Approve'},
                  events: {
                    'click': {
                      'action': 'set_status',
                      'target': 'status',
                      'property': 'text',
                      'value': 'Approved',
                    },
                  },
                ),
              ],
            ),
          ],
        ),
        fallback: const ImDynamicFallback(
          type: 'text',
          content: 'Interactive content',
        ),
        metadata: const {'created_by': 'dynamic_creator_panel'},
      ),
    )..selectNode('title');
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ImDynamicEditor(
    controller: _controller,
    messageId: widget.messageId,
    creating: true,
    onSave:
        _saving
            ? null
            : (command) {
              setState(() => _saving = true);
              final messenger = ScaffoldMessenger.maybeOf(context);
              Future<void>.sync(() => widget.onCreate(command)).catchError((
                error,
              ) {
                if (!mounted) return;
                setState(() => _saving = false);
                messenger?.showSnackBar(
                  SnackBar(content: Text(error.toString())),
                );
              });
            },
  );
}
