import 'dart:async';

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
