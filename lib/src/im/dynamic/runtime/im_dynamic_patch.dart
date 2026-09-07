import '../models/im_dynamic_models.dart';

class ImDynamicPatchException implements Exception {
  const ImDynamicPatchException(this.message);

  final String message;

  @override
  String toString() => 'ImDynamicPatchException: $message';
}

/// Applies node-id patches atomically to an immutable content tree.
class ImDynamicPatchApplier {
  const ImDynamicPatchApplier();

  ImDynamicContent apply(ImDynamicContent content, ImDynamicPatchSet update) {
    if (update.contentId.isNotEmpty && update.contentId != content.id) {
      throw ImDynamicPatchException(
        'Patch content ${update.contentId} does not match ${content.id}',
      );
    }
    var next = content;
    for (final patch in update.patches) {
      next = _applyOne(next, patch);
    }
    return next;
  }

  ImDynamicContent _applyOne(ImDynamicContent content, ImDynamicPatch patch) {
    if (patch.nodeId.trim().isEmpty) {
      throw const ImDynamicPatchException('Patch node_id is required');
    }
    return switch (patch.operation) {
      ImDynamicPatchOperation.update => content.copyWith(
        tree: _transformNode(content.tree, patch, (node) {
          return node.copyWith(props: {...node.props, ...patch.props});
        }),
      ),
      ImDynamicPatchOperation.replace => content.copyWith(
        tree: _transformNode(content.tree, patch, (_) {
          final replacement = patch.node;
          if (replacement == null) {
            throw const ImDynamicPatchException(
              'Replace patch requires a node',
            );
          }
          if (replacement.id != patch.nodeId) {
            throw const ImDynamicPatchException(
              'Replacement node id must match node_id',
            );
          }
          return replacement;
        }),
      ),
      ImDynamicPatchOperation.remove => content.copyWith(
        tree: _removeNode(content.tree, patch.nodeId),
      ),
      ImDynamicPatchOperation.create => content.copyWith(
        tree: _createNode(content.tree, patch),
      ),
    };
  }

  ImDynamicNode _transformNode(
    ImDynamicNode root,
    ImDynamicPatch patch,
    ImDynamicNode Function(ImDynamicNode node) transform,
  ) {
    var found = false;
    ImDynamicNode visit(ImDynamicNode node) {
      if (node.id == patch.nodeId) {
        found = true;
        return transform(node);
      }
      final children = node.children.map(visit).toList(growable: false);
      return node.copyWith(children: children);
    }

    final result = visit(root);
    if (!found) {
      throw ImDynamicPatchException('Node ${patch.nodeId} was not found');
    }
    return result;
  }

  ImDynamicNode _removeNode(ImDynamicNode root, String nodeId) {
    if (root.id == nodeId) {
      throw const ImDynamicPatchException('The root node cannot be removed');
    }
    var found = false;
    ImDynamicNode visit(ImDynamicNode node) {
      final children = <ImDynamicNode>[];
      for (final child in node.children) {
        if (child.id == nodeId) {
          found = true;
          continue;
        }
        children.add(visit(child));
      }
      return node.copyWith(children: children);
    }

    final result = visit(root);
    if (!found) {
      throw ImDynamicPatchException('Node $nodeId was not found');
    }
    return result;
  }

  ImDynamicNode _createNode(ImDynamicNode root, ImDynamicPatch patch) {
    final created = patch.node;
    final parentId = patch.parentNodeId;
    if (created == null || parentId == null || parentId.isEmpty) {
      throw const ImDynamicPatchException(
        'Create patch requires node and parent_node_id',
      );
    }
    if (created.id != patch.nodeId) {
      throw const ImDynamicPatchException('Created node id must match node_id');
    }
    if (root.findById(patch.nodeId) != null) {
      throw ImDynamicPatchException('Node ${patch.nodeId} already exists');
    }
    var found = false;
    ImDynamicNode visit(ImDynamicNode node) {
      if (node.id == parentId) {
        found = true;
        final children = [...node.children];
        final index =
            patch.index?.clamp(0, children.length).toInt() ?? children.length;
        children.insert(index, created);
        return node.copyWith(children: children);
      }
      return node.copyWith(
        children: node.children.map(visit).toList(growable: false),
      );
    }

    final result = visit(root);
    if (!found) {
      throw ImDynamicPatchException('Parent node $parentId was not found');
    }
    return result;
  }
}
