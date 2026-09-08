import 'package:flutter/material.dart';

import '../models/im_dynamic_command.dart';
import '../models/im_dynamic_models.dart';
import 'im_dynamic_editor_controller.dart';

/// A compact editor for the controlled Dynamic Schema.
///
/// It intentionally edits schema data rather than Flutter code. Product UIs
/// can place this panel next to a bubble, in a modal, or inside a split view.
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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildToolbar(context, controller),
          const Divider(height: 1),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(width: 220, child: _buildTree(context, controller)),
                const VerticalDivider(width: 1),
                Expanded(
                  child: _buildProperties(context, controller, selected),
                ),
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
    return ListView(
      padding: const EdgeInsets.all(8),
      children: [
        _buildNodeTile(context, controller, controller.content.tree, 0),
        const Divider(),
        DropdownButtonFormField<String>(
          key: const ValueKey('dynamic-editor-add-type'),
          initialValue: 'text',
          decoration: const InputDecoration(labelText: 'Add component'),
          items: const [
            DropdownMenuItem(value: 'text', child: Text('Text')),
            DropdownMenuItem(value: 'markdown', child: Text('Markdown')),
            DropdownMenuItem(value: 'button', child: Text('Button')),
            DropdownMenuItem(value: 'status', child: Text('Status')),
            DropdownMenuItem(value: 'progress', child: Text('Progress')),
          ],
          onChanged: (type) {
            if (type == null) return;
            final parent = controller.selectedNode;
            if (parent == null) return;
            final id = _newNodeId(controller.content.tree, type);
            controller.addNode(
              parentNodeId: parent.id,
              node: ImDynamicNode(
                id: id,
                type: type,
                props: switch (type) {
                  'button' => const {'text': 'Action'},
                  'status' => const {'text': 'Status'},
                  'progress' => const {'value': 0.0, 'text': '0%'},
                  _ => const {'text': 'New text'},
                },
              ),
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          dense: true,
          selected: selected,
          contentPadding: EdgeInsets.only(left: depth * 14.0, right: 0),
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
    if (node == null) {
      return const Center(child: Text('Select a component'));
    }
    final canDelete = node.id != controller.content.tree.id;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(node.type, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 12),
        TextField(
          key: const ValueKey('dynamic-editor-text'),
          controller: _textController,
          decoration: const InputDecoration(labelText: 'Text / content'),
          onSubmitted: (value) {
            final key = node.type == 'markdown' ? 'content' : 'text';
            controller.updateNode(
              nodeId: node.id,
              props: {...node.props, key: value},
            );
          },
        ),
        if (node.type == 'button') ...[
          const SizedBox(height: 12),
          TextFormField(
            key: const ValueKey('dynamic-editor-action'),
            initialValue: node.events['click']?['action']?.toString() ?? '',
            decoration: const InputDecoration(labelText: 'Click action'),
            onFieldSubmitted:
                (value) => controller.setNodeEvent(
                  nodeId: node.id,
                  event: 'click',
                  action: value,
                ),
          ),
        ],
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

  String _newNodeId(ImDynamicNode root, String type) {
    var index = 1;
    while (root.findById('$type-$index') != null) {
      index++;
    }
    return '$type-$index';
  }
}
