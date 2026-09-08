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
  }) {
    final current = content.tree.findById(nodeId);
    if (current == null) {
      throw ImDynamicPatchException('Node $nodeId was not found');
    }
    final events = <String, Map<String, dynamic>>{...current.events};
    if (action == null || action.trim().isEmpty) {
      events.remove(event);
    } else {
      events[event] = {'action': action};
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
