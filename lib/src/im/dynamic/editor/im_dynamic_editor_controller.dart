import 'package:flutter/foundation.dart';

import '../models/im_dynamic_command.dart';
import '../models/im_dynamic_models.dart';
import '../runtime/im_dynamic_patch.dart';
import '../runtime/im_dynamic_validator.dart';

class ImDynamicEditorException implements Exception {
  const ImDynamicEditorException(this.issues);

  final List<ImDynamicValidationIssue> issues;

  @override
  String toString() => issues.map((issue) => issue.toString()).join('; ');
}

/// Edits the same Dynamic Schema consumed by AI and the rendering runtime.
class ImDynamicEditorController extends ChangeNotifier {
  ImDynamicEditorController({
    required ImDynamicContent content,
    this.validator = const ImDynamicSchemaValidator(),
    ImDynamicPatchApplier patchApplier = const ImDynamicPatchApplier(),
  }) : _history = [content],
       _patchApplier = patchApplier,
       _selectedNodeId = content.tree.id {
    _ensureValid(content);
  }

  final ImDynamicSchemaValidator validator;
  final ImDynamicPatchApplier _patchApplier;
  final List<ImDynamicContent> _history;
  int _historyIndex = 0;
  String? _selectedNodeId;

  ImDynamicContent get content => _history[_historyIndex];
  String? get selectedNodeId => _selectedNodeId;
  ImDynamicNode? get selectedNode =>
      _selectedNodeId == null ? null : content.tree.findById(_selectedNodeId!);
  bool get canUndo => _historyIndex > 0;
  bool get canRedo => _historyIndex < _history.length - 1;
  ImDynamicValidationResult get validation => validator.validate(content);

  /// Returns the direct parent of a node in the immutable schema tree.
  ImDynamicNode? parentOf(String nodeId) {
    ImDynamicNode? visit(ImDynamicNode node) {
      for (final child in node.children) {
        if (child.id == nodeId) return node;
        final parent = visit(child);
        if (parent != null) return parent;
      }
      return null;
    }

    return content.tree.id == nodeId ? null : visit(content.tree);
  }

  /// A node can host children only when it is a layout component.
  bool canContainChildren(ImDynamicNode node) =>
      const {'row', 'column', 'card', 'container'}.contains(node.type);

  /// Resolves the actual insertion target for palette operations.
  ///
  /// Selecting a leaf is still useful for editing it, but a new component is
  /// inserted beside that leaf in its nearest layout parent. This prevents
  /// invisible children from being attached to text, button, or input nodes.
  ImDynamicNode insertionParent() {
    final selected = selectedNode;
    if (selected == null) return content.tree;
    if (canContainChildren(selected)) return selected;
    var parent = parentOf(selected.id);
    while (parent != null && !canContainChildren(parent)) {
      parent = parentOf(parent.id);
    }
    return parent ?? content.tree;
  }

  void selectNode(String? nodeId) {
    if (nodeId != null && content.tree.findById(nodeId) == null) {
      throw ImDynamicPatchException('Node $nodeId was not found');
    }
    if (_selectedNodeId == nodeId) return;
    _selectedNodeId = nodeId;
    notifyListeners();
  }

  void addNode({
    required String parentNodeId,
    required ImDynamicNode node,
    int? index,
  }) {
    final parent = content.tree.findById(parentNodeId);
    if (parent == null) {
      throw ImDynamicPatchException('Parent node $parentNodeId was not found');
    }
    if (!canContainChildren(parent)) {
      throw ImDynamicPatchException(
        'Component ${parent.type} cannot contain children',
      );
    }
    _commitPatch(
      ImDynamicPatch(
        operation: ImDynamicPatchOperation.create,
        nodeId: node.id,
        parentNodeId: parentNodeId,
        index: index,
        node: node,
      ),
    );
    _selectedNodeId = node.id;
  }

  void replaceNode(ImDynamicNode node) {
    _commitPatch(
      ImDynamicPatch(
        operation: ImDynamicPatchOperation.replace,
        nodeId: node.id,
        node: node,
      ),
    );
  }

  void updateNode({
    required String nodeId,
    String? type,
    Map<String, dynamic>? props,
    Map<String, Map<String, dynamic>>? events,
  }) {
    final current = content.tree.findById(nodeId);
    if (current == null) {
      throw ImDynamicPatchException('Node $nodeId was not found');
    }
    replaceNode(current.copyWith(type: type, props: props, events: events));
  }

  void setNodeEvent({
    required String nodeId,
    required String event,
    String? action,
    String? targetNodeId,
    String? property,
    Object? value,
  }) {
    final current = content.tree.findById(nodeId);
    if (current == null) {
      throw ImDynamicPatchException('Node $nodeId was not found');
    }
    final events = <String, Map<String, dynamic>>{...current.events};
    if (action == null || action.trim().isEmpty) {
      events.remove(event);
    } else {
      events[event] = {
        'action': action,
        if (targetNodeId != null && targetNodeId.trim().isNotEmpty)
          'target': targetNodeId.trim(),
        if (property != null && property.trim().isNotEmpty)
          'property': property.trim(),
        if (value != null) 'value': value,
      };
    }
    updateNode(nodeId: nodeId, events: events);
  }

  void removeNode(String nodeId) {
    _commitPatch(
      ImDynamicPatch(operation: ImDynamicPatchOperation.remove, nodeId: nodeId),
    );
    if (_selectedNodeId == nodeId) _selectedNodeId = content.tree.id;
  }

  void replaceContent(ImDynamicContent replacement) {
    if (replacement.id != content.id) {
      throw const ImDynamicPatchException(
        'Editor replacement must preserve the content id',
      );
    }
    _commit(_asUserEdit(replacement));
    if (_selectedNodeId != null && selectedNode == null) {
      _selectedNodeId = content.tree.id;
    }
  }

  /// Updates the generic interaction contract without coupling the editor to
  /// any particular component type. The server validates the same contract
  /// again before accepting a message.
  void updateInteractionConfig(Map<String, dynamic> interaction) {
    final normalized = <String, dynamic>{...interaction}
      ..removeWhere((key, value) => value == null);
    replaceContent(
      content.copyWith(
        metadata: {
          ...content.metadata,
          if (normalized.isEmpty)
            'interaction': null
          else
            'interaction': normalized,
        }..removeWhere((key, value) => value == null),
      ),
    );
  }

  void undo() {
    if (!canUndo) return;
    _historyIndex--;
    _repairSelection();
    notifyListeners();
  }

  void redo() {
    if (!canRedo) return;
    _historyIndex++;
    _repairSelection();
    notifyListeners();
  }

  ImDynamicCommand buildSaveCommand({required String messageId}) {
    _ensureValid(content);
    return ImDynamicCommand.replace(
      messageId: messageId,
      contentId: content.id,
      content: content,
    );
  }

  ImDynamicCommand buildCreateCommand({required String messageId}) {
    _ensureValid(content);
    return ImDynamicCommand.create(messageId: messageId, content: content);
  }

  ImDynamicCommand buildRemoveCommand({required String messageId}) =>
      ImDynamicCommand.remove(messageId: messageId, contentId: content.id);

  void _commitPatch(ImDynamicPatch patch) {
    final next = _patchApplier.apply(
      content,
      ImDynamicPatchSet(
        messageId: 'editor-preview',
        contentId: content.id,
        patches: [patch],
      ),
    );
    _commit(_asUserEdit(next));
  }

  ImDynamicContent _asUserEdit(ImDynamicContent next) {
    final originalSource = content.metadata['origin_source']?.toString();
    return next.copyWith(
      source: ImDynamicContentSource.user,
      metadata: {
        ...next.metadata,
        'edited': true,
        if (originalSource != null)
          'origin_source': originalSource
        else if (content.source != ImDynamicContentSource.user)
          'origin_source': imDynamicContentSourceValue(content.source),
      },
    );
  }

  void _commit(ImDynamicContent next) {
    _ensureValid(next);
    if (canRedo) {
      _history.removeRange(_historyIndex + 1, _history.length);
    }
    _history.add(next);
    _historyIndex++;
    notifyListeners();
  }

  void _ensureValid(ImDynamicContent candidate) {
    final result = validator.validate(candidate);
    if (!result.isValid) throw ImDynamicEditorException(result.errors);
  }

  void _repairSelection() {
    if (_selectedNodeId != null && selectedNode == null) {
      _selectedNodeId = content.tree.id;
    }
  }
}
