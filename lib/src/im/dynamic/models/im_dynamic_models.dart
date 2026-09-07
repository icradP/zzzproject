import 'dart:convert';

/// The producer of a dynamic message. The value is part of the wire schema.
enum ImDynamicContentSource { ai, user, system, plugin, server, unknown }

ImDynamicContentSource imDynamicContentSourceFromString(String? value) {
  return switch (value) {
    'ai' => ImDynamicContentSource.ai,
    'user' => ImDynamicContentSource.user,
    'system' => ImDynamicContentSource.system,
    'plugin' => ImDynamicContentSource.plugin,
    'server' => ImDynamicContentSource.server,
    _ => ImDynamicContentSource.unknown,
  };
}

String imDynamicContentSourceValue(ImDynamicContentSource source) {
  return switch (source) {
    ImDynamicContentSource.ai => 'ai',
    ImDynamicContentSource.user => 'user',
    ImDynamicContentSource.system => 'system',
    ImDynamicContentSource.plugin => 'plugin',
    ImDynamicContentSource.server => 'server',
    ImDynamicContentSource.unknown => 'unknown',
  };
}

/// A controlled, serializable content tree embedded in an IM message.
class ImDynamicContent {
  const ImDynamicContent({
    required this.id,
    required this.version,
    required this.source,
    required this.tree,
    this.fallback,
    this.metadata = const <String, dynamic>{},
  });

  final String id;
  final String version;
  final ImDynamicContentSource source;
  final ImDynamicNode tree;
  final ImDynamicFallback? fallback;
  final Map<String, dynamic> metadata;

  factory ImDynamicContent.fromJson(Map<String, dynamic> json) {
    final rawTree = json['tree'];
    if (rawTree is! Map) {
      throw const FormatException('Dynamic content tree is missing');
    }
    return ImDynamicContent(
      id: _stringValue(json['id']) ?? '',
      version: _stringValue(json['version']) ?? '1.0',
      source: imDynamicContentSourceFromString(_stringValue(json['source'])),
      tree: ImDynamicNode.fromJson(Map<String, dynamic>.from(rawTree)),
      fallback:
          json['fallback'] is Map
              ? ImDynamicFallback.fromJson(
                Map<String, dynamic>.from(json['fallback'] as Map),
              )
              : null,
      metadata:
          json['metadata'] is Map
              ? Map.unmodifiable(
                Map<String, dynamic>.from(json['metadata'] as Map),
              )
              : const <String, dynamic>{},
    );
  }

  /// Reads both the documented `{schema: {...}}` envelope and a flat segment.
  factory ImDynamicContent.fromSegmentData(Map<String, dynamic> data) {
    final nested = data['content'] ?? data['schema'];
    Map<String, dynamic> schema;
    if (nested is String) {
      final decoded = jsonDecode(nested);
      if (decoded is! Map) {
        throw const FormatException('Dynamic content schema is not an object');
      }
      schema = Map<String, dynamic>.from(decoded);
    } else if (nested is Map) {
      schema = Map<String, dynamic>.from(nested);
    } else {
      schema = Map<String, dynamic>.from(data);
    }

    // Permit transport metadata to live beside the schema for compact events.
    for (final key in const ['id', 'version', 'source', 'tree', 'fallback']) {
      if (!schema.containsKey(key) && data.containsKey(key)) {
        schema[key] = data[key];
      }
    }
    return ImDynamicContent.fromJson(schema);
  }

  static ImDynamicContent? tryFromSegmentData(Map<String, dynamic> data) {
    try {
      return ImDynamicContent.fromSegmentData(data);
    } on Object {
      return null;
    }
  }

  Map<String, dynamic> toJson() => {
    'type': 'dynamic_content',
    'id': id,
    'version': version,
    'source': imDynamicContentSourceValue(source),
    'tree': tree.toJson(),
    if (fallback != null) 'fallback': fallback!.toJson(),
    if (metadata.isNotEmpty) 'metadata': metadata,
  };

  ImDynamicContent copyWith({
    String? id,
    String? version,
    ImDynamicContentSource? source,
    ImDynamicNode? tree,
    ImDynamicFallback? fallback,
    Map<String, dynamic>? metadata,
  }) {
    return ImDynamicContent(
      id: id ?? this.id,
      version: version ?? this.version,
      source: source ?? this.source,
      tree: tree ?? this.tree,
      fallback: fallback ?? this.fallback,
      metadata: metadata ?? this.metadata,
    );
  }
}

class ImDynamicFallback {
  const ImDynamicFallback({required this.type, required this.content});

  final String type;
  final String content;

  factory ImDynamicFallback.fromJson(Map<String, dynamic> json) {
    return ImDynamicFallback(
      type: _stringValue(json['type']) ?? 'text',
      content: _stringValue(json['content']) ?? '',
    );
  }

  Map<String, dynamic> toJson() => {'type': type, 'content': content};
}

/// A node in the dynamic content tree.
class ImDynamicNode {
  const ImDynamicNode({
    required this.id,
    required this.type,
    this.props = const <String, dynamic>{},
    this.children = const <ImDynamicNode>[],
    this.events = const <String, Map<String, dynamic>>{},
  });

  final String id;
  final String type;
  final Map<String, dynamic> props;
  final List<ImDynamicNode> children;
  final Map<String, Map<String, dynamic>> events;

  factory ImDynamicNode.fromJson(Map<String, dynamic> json) {
    final rawChildren = json['children'];
    final children = <ImDynamicNode>[];
    if (rawChildren is List) {
      for (final child in rawChildren) {
        if (child is! Map) {
          throw const FormatException('Dynamic child is not an object');
        }
        children.add(ImDynamicNode.fromJson(Map<String, dynamic>.from(child)));
      }
    }

    final eventMap = <String, Map<String, dynamic>>{};
    final rawEvents = json['events'];
    if (rawEvents is Map) {
      for (final entry in rawEvents.entries) {
        if (entry.value is Map) {
          eventMap['${entry.key}'] = Map<String, dynamic>.from(
            entry.value as Map,
          );
        }
      }
    }

    return ImDynamicNode(
      id: _stringValue(json['id']) ?? '',
      type: _stringValue(json['type']) ?? '',
      props:
          json['props'] is Map
              ? Map.unmodifiable(
                Map<String, dynamic>.from(json['props'] as Map),
              )
              : const <String, dynamic>{},
      children: List.unmodifiable(children),
      events: Map.unmodifiable(eventMap),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'type': type,
    if (props.isNotEmpty) 'props': props,
    if (children.isNotEmpty)
      'children': children.map((e) => e.toJson()).toList(),
    if (events.isNotEmpty) 'events': events,
  };

  ImDynamicNode? findById(String nodeId) {
    if (id == nodeId) return this;
    for (final child in children) {
      final result = child.findById(nodeId);
      if (result != null) return result;
    }
    return null;
  }

  ImDynamicNode copyWith({
    String? id,
    String? type,
    Map<String, dynamic>? props,
    List<ImDynamicNode>? children,
    Map<String, Map<String, dynamic>>? events,
  }) {
    return ImDynamicNode(
      id: id ?? this.id,
      type: type ?? this.type,
      props: props ?? this.props,
      children: children ?? this.children,
      events: events ?? this.events,
    );
  }
}

enum ImDynamicPatchOperation { create, update, replace, remove }

ImDynamicPatchOperation imDynamicPatchOperationFromString(String? value) {
  return switch (value) {
    'create' => ImDynamicPatchOperation.create,
    'update' => ImDynamicPatchOperation.update,
    'replace' => ImDynamicPatchOperation.replace,
    'remove' => ImDynamicPatchOperation.remove,
    _ => throw FormatException('Unknown dynamic patch operation: $value'),
  };
}

String imDynamicPatchOperationValue(ImDynamicPatchOperation operation) =>
    operation.name;

/// A stable node-id patch. It intentionally avoids fragile JSON tree paths.
class ImDynamicPatch {
  const ImDynamicPatch({
    required this.operation,
    required this.nodeId,
    this.parentNodeId,
    this.index,
    this.props = const <String, dynamic>{},
    this.node,
  });

  final ImDynamicPatchOperation operation;
  final String nodeId;
  final String? parentNodeId;
  final int? index;
  final Map<String, dynamic> props;
  final ImDynamicNode? node;

  factory ImDynamicPatch.fromJson(Map<String, dynamic> json) {
    final rawNode = json['node'];
    return ImDynamicPatch(
      operation: imDynamicPatchOperationFromString(
        json['operation']?.toString(),
      ),
      nodeId: json['node_id']?.toString() ?? '',
      parentNodeId: json['parent_node_id']?.toString(),
      index: (json['index'] as num?)?.toInt(),
      props:
          json['props'] is Map
              ? Map.unmodifiable(
                Map<String, dynamic>.from(json['props'] as Map),
              )
              : const <String, dynamic>{},
      node:
          rawNode is Map
              ? ImDynamicNode.fromJson(Map<String, dynamic>.from(rawNode))
              : null,
    );
  }

  Map<String, dynamic> toJson() => {
    'operation': imDynamicPatchOperationValue(operation),
    'node_id': nodeId,
    if (parentNodeId != null) 'parent_node_id': parentNodeId,
    if (index != null) 'index': index,
    if (props.isNotEmpty) 'props': props,
    if (node != null) 'node': node!.toJson(),
  };
}

class ImDynamicPatchSet {
  const ImDynamicPatchSet({
    required this.messageId,
    required this.contentId,
    required this.patches,
  });

  final String messageId;
  final String contentId;
  final List<ImDynamicPatch> patches;

  factory ImDynamicPatchSet.fromJson(Map<String, dynamic> json) {
    final rawPatches = json['patches'];
    if (rawPatches is! List) {
      throw const FormatException('Dynamic update patches are missing');
    }
    if (rawPatches.any((patch) => patch is! Map)) {
      throw const FormatException('Dynamic update contains an invalid patch');
    }
    return ImDynamicPatchSet(
      messageId: json['message_id']?.toString() ?? '',
      contentId: json['content_id']?.toString() ?? '',
      patches: List.unmodifiable(
        rawPatches
            .map((patch) => patch as Map)
            .map(
              (patch) =>
                  ImDynamicPatch.fromJson(Map<String, dynamic>.from(patch)),
            ),
      ),
    );
  }

  factory ImDynamicPatchSet.fromSegmentData(Map<String, dynamic> data) {
    final nested = data['update'];
    final json =
        nested is Map
            ? <String, dynamic>{
              ...Map<String, dynamic>.from(nested),
              if (!nested.containsKey('message_id') &&
                  data.containsKey('message_id'))
                'message_id': data['message_id'],
              if (!nested.containsKey('content_id') &&
                  data.containsKey('content_id'))
                'content_id': data['content_id'],
            }
            : data;
    return ImDynamicPatchSet.fromJson(json);
  }

  static ImDynamicPatchSet? tryFromSegmentData(Map<String, dynamic> data) {
    try {
      return ImDynamicPatchSet.fromSegmentData(data);
    } on Object {
      return null;
    }
  }

  Map<String, dynamic> toJson() => {
    'type': 'dynamic_update',
    'message_id': messageId,
    'content_id': contentId,
    'patches': patches.map((patch) => patch.toJson()).toList(),
  };
}

enum ImDynamicLifecycle {
  created,
  active,
  processing,
  completed,
  error,
  closed,
}

ImDynamicLifecycle imDynamicLifecycleFromString(String? value) {
  return ImDynamicLifecycle.values.firstWhere(
    (item) => item.name == value,
    orElse: () => ImDynamicLifecycle.created,
  );
}

/// Runtime state is deliberately separate from the immutable content schema.
class ImDynamicState {
  const ImDynamicState({
    this.lifecycle = ImDynamicLifecycle.created,
    this.values = const <String, dynamic>{},
  });

  final ImDynamicLifecycle lifecycle;
  final Map<String, dynamic> values;

  bool get isInteractive => lifecycle != ImDynamicLifecycle.closed;

  ImDynamicState copyWith({
    ImDynamicLifecycle? lifecycle,
    Map<String, dynamic>? values,
  }) => ImDynamicState(
    lifecycle: lifecycle ?? this.lifecycle,
    values: values ?? this.values,
  );

  factory ImDynamicState.fromJson(Map<String, dynamic> json) => ImDynamicState(
    lifecycle: imDynamicLifecycleFromString(json['lifecycle']?.toString()),
    values:
        json['values'] is Map
            ? Map.unmodifiable(Map<String, dynamic>.from(json['values'] as Map))
            : const <String, dynamic>{},
  );

  Map<String, dynamic> toJson() => {
    'lifecycle': lifecycle.name,
    if (values.isNotEmpty) 'values': values,
  };
}

class ImDynamicEvent {
  const ImDynamicEvent({
    required this.messageId,
    required this.contentId,
    required this.nodeId,
    required this.event,
    required this.action,
    this.payload = const <String, dynamic>{},
  });

  final String messageId;
  final String contentId;
  final String nodeId;
  final String event;
  final String? action;
  final Map<String, dynamic> payload;

  Map<String, dynamic> toJson() => {
    'type': 'dynamic_event',
    'message_id': messageId,
    'content_id': contentId,
    'node_id': nodeId,
    'event': event,
    if (action != null && action!.isNotEmpty) 'action': action,
    'payload': payload,
  };
}

String? _stringValue(Object? value) =>
    value is String ? value : value?.toString();
