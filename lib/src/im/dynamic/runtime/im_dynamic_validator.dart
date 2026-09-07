import '../models/im_dynamic_models.dart';

const _maxDynamicIdentifierLength = 128;
const _maxDynamicVersionLength = 32;
const _maxDynamicNodeTypeLength = 64;
const _maxDynamicImageUrlLength = 2048;

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
      } else if (node.id.length > _maxDynamicIdentifierLength) {
        errors.add(
          ImDynamicValidationIssue(path: path, message: 'node id is too long'),
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
      } else if (node.type.length > _maxDynamicNodeTypeLength) {
        errors.add(
          ImDynamicValidationIssue(
            path: path,
            message: 'node type is too long',
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
        final rawUrl = node.props['url'];
        if (rawUrl != null &&
            (rawUrl is! String || !_validDynamicImageUrl(rawUrl))) {
          errors.add(
            ImDynamicValidationIssue(
              path: '$path.props.url',
              message: 'image URL must use HTTPS',
            ),
          );
        }
      }
      if (node.children.length > maxChildren) {
        errors.add(
          ImDynamicValidationIssue(path: path, message: 'child limit exceeded'),
        );
      }
      _validateValues(node.props, '$path.props', errors, 0);
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
        } else if (action is String &&
            action.length > _maxDynamicIdentifierLength) {
          errors.add(
            ImDynamicValidationIssue(
              path: '$path.events.${entry.key}.action',
              message: 'action is too long',
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
    } else if (content.id.length > _maxDynamicIdentifierLength) {
      errors.add(
        const ImDynamicValidationIssue(
          path: 'id',
          message: 'content id is too long',
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
    } else if (content.version.length > _maxDynamicVersionLength) {
      errors.add(
        const ImDynamicValidationIssue(
          path: 'version',
          message: 'version is too long',
        ),
      );
    }
    if (content.source == ImDynamicContentSource.unknown) {
      errors.add(
        const ImDynamicValidationIssue(
          path: 'source',
          message: 'content source is invalid',
        ),
      );
    }
    _validateValues(content.metadata, 'metadata', errors, 0);
    final fallback = content.fallback;
    if (fallback != null && fallback.content.length > maxTextLength) {
      errors.add(
        const ImDynamicValidationIssue(
          path: 'fallback.content',
          message: 'text is too long',
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
    int depth,
  ) {
    if (depth > maxDepth) {
      errors.add(
        ImDynamicValidationIssue(path: path, message: 'value depth exceeded'),
      );
      return;
    }
    if (value is String && value.length > maxTextLength) {
      errors.add(
        ImDynamicValidationIssue(path: path, message: 'text is too long'),
      );
      return;
    }
    if (value is Map) {
      for (final entry in value.entries) {
        _validateValues(entry.value, '$path.${entry.key}', errors, depth + 1);
      }
    } else if (value is List) {
      if (value.length > maxChildren) {
        errors.add(
          ImDynamicValidationIssue(
            path: path,
            message: 'value list is too long',
          ),
        );
        return;
      }
      for (var i = 0; i < value.length; i++) {
        _validateValues(value[i], '$path[$i]', errors, depth + 1);
      }
    }
  }
}

bool _validDynamicImageUrl(String raw) {
  if (raw.isEmpty ||
      raw.length > _maxDynamicImageUrlLength ||
      raw != raw.trim()) {
    return false;
  }
  final uri = Uri.tryParse(raw);
  return uri != null &&
      uri.scheme == 'https' &&
      uri.host.isNotEmpty &&
      uri.userInfo.isEmpty;
}

const _allowedEvents = {'click', 'tap', 'submit', 'change', 'select'};
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
