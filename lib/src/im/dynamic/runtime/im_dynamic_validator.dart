import '../models/im_dynamic_models.dart';

class ImDynamicValidationIssue {
  const ImDynamicValidationIssue({required this.path, required this.message});

  final String path;
  final String message;

  @override
  String toString() => '$path: $message';
}

class ImDynamicValidationResult {
  const ImDynamicValidationResult({
    this.errors = const [],
    this.warnings = const [],
  });

  final List<ImDynamicValidationIssue> errors;
  final List<ImDynamicValidationIssue> warnings;

  bool get isValid => errors.isEmpty;
}

/// Validates untrusted content before it reaches the Flutter widget tree.
class ImDynamicSchemaValidator {
  const ImDynamicSchemaValidator({
    this.maxNodes = 100,
    this.maxDepth = 10,
    this.maxChildren = 50,
    this.maxTextLength = 10000,
    this.maxImages = 20,
  });

  final int maxNodes;
  final int maxDepth;
  final int maxChildren;
  final int maxTextLength;
  final int maxImages;

  ImDynamicValidationResult validate(ImDynamicContent content) {
    final errors = <ImDynamicValidationIssue>[];
    final warnings = <ImDynamicValidationIssue>[];
    final ids = <String>{};
    var nodeCount = 0;
    var imageCount = 0;

    void visit(ImDynamicNode node, int depth, String path) {
      nodeCount++;
      if (nodeCount > maxNodes) {
        errors.add(
          ImDynamicValidationIssue(path: path, message: 'node limit exceeded'),
        );
        return;
      }
      if (depth > maxDepth) {
        errors.add(
          ImDynamicValidationIssue(path: path, message: 'tree depth exceeded'),
        );
      }
      if (node.id.trim().isEmpty) {
        errors.add(
          ImDynamicValidationIssue(path: path, message: 'node id is required'),
        );
      } else if (!ids.add(node.id)) {
        errors.add(
          ImDynamicValidationIssue(
            path: path,
            message: 'node id must be unique',
          ),
        );
      }
      if (node.type.trim().isEmpty) {
        errors.add(
          ImDynamicValidationIssue(
            path: path,
            message: 'node type is required',
          ),
        );
      } else if (!_knownTypes.contains(node.type)) {
        warnings.add(
          ImDynamicValidationIssue(
            path: path,
            message: 'unknown component ${node.type}',
          ),
        );
      }
      if (node.type == 'image') {
        imageCount++;
        if (imageCount > maxImages) {
          errors.add(
            ImDynamicValidationIssue(
              path: path,
              message: 'image limit exceeded',
            ),
          );
        }
      }
      if (node.children.length > maxChildren) {
        errors.add(
          ImDynamicValidationIssue(path: path, message: 'child limit exceeded'),
        );
      }
      _validateValues(node.props, '$path.props', errors);
      for (final entry in node.events.entries) {
        if (!_allowedEvents.contains(entry.key)) {
          errors.add(
            ImDynamicValidationIssue(
              path: '$path.events.${entry.key}',
              message: 'event is not allowed',
            ),
          );
        }
        final action = entry.value['action'];
        if (action != null && action is! String) {
          errors.add(
            ImDynamicValidationIssue(
              path: '$path.events.${entry.key}',
              message: 'action must be a string',
            ),
          );
        }
      }
      for (var i = 0; i < node.children.length; i++) {
        visit(node.children[i], depth + 1, '$path.children[$i]');
      }
    }

    if (content.id.trim().isEmpty) {
      errors.add(
        const ImDynamicValidationIssue(
          path: 'id',
          message: 'content id is required',
        ),
      );
    }
    if (content.version.trim().isEmpty) {
      errors.add(
        const ImDynamicValidationIssue(
          path: 'version',
          message: 'version is required',
        ),
      );
    }
    visit(content.tree, 0, 'tree');
    return ImDynamicValidationResult(
      errors: List.unmodifiable(errors),
      warnings: List.unmodifiable(warnings),
    );
  }

  void _validateValues(
    Object? value,
    String path,
    List<ImDynamicValidationIssue> errors,
  ) {
    if (value is String && value.length > maxTextLength) {
      errors.add(
        ImDynamicValidationIssue(path: path, message: 'text is too long'),
      );
      return;
    }
    if (value is Map) {
      for (final entry in value.entries) {
        _validateValues(entry.value, '$path.${entry.key}', errors);
      }
    } else if (value is List) {
      for (var i = 0; i < value.length; i++) {
        _validateValues(value[i], '$path[$i]', errors);
      }
    }
  }
}

const _allowedEvents = {'click', 'tap', 'submit', 'change'};
const _knownTypes = {
  'text',
  'markdown',
  'icon',
  'image',
  'row',
  'column',
  'card',
  'container',
  'divider',
  'button',
  'input',
  'checkbox',
  'select',
  'progress',
  'status',
  'badge',
};
