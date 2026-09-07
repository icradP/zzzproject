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
    final rawFallback = json['fallback'];
    if (json.containsKey('fallback') && rawFallback is! Map) {
      throw const FormatException('Dynamic content fallback is not an object');
    }
    final rawMetadata = json['metadata'];
    if (json.containsKey('metadata') && rawMetadata is! Map) {
      throw const FormatException('Dynamic content metadata is not an object');
    }
    return ImDynamicContent(
      id: _stringField(json, 'id') ?? '',
      version: _stringField(json, 'version') ?? '1.0',
      source: imDynamicContentSourceFromString(_stringField(json, 'source')),
      tree: ImDynamicNode.fromJson(Map<String, dynamic>.from(rawTree)),
      fallback:
          rawFallback is Map
              ? ImDynamicFallback.fromJson(
                Map<String, dynamic>.from(rawFallback),
              )
              : null,
      metadata:
          rawMetadata is Map
              ? Map.unmodifiable(Map<String, dynamic>.from(rawMetadata))
              : const <String, dynamic>{},
    );
  }

  /// Reads both the documented `{schema: {...}}` envelope and a flat segment.
  factory ImDynamicContent.fromSegmentData(Map<String, dynamic> data) {
    return ImDynamicContent.fromJson(_dynamicSchemaFromSegmentData(data));
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
      type: _stringField(json, 'type') ?? 'text',
      content: _stringField(json, 'content') ?? '',
    );
  }

  /// Recovers a transport fallback even when the dynamic tree itself cannot
  /// be parsed. This keeps malformed or newer schemas readable.
  static ImDynamicFallback? tryFromSegmentData(Map<String, dynamic> data) {
    Object? rawFallback;
    try {
      rawFallback = _dynamicSchemaFromSegmentData(data)['fallback'];
    } on Object {
      rawFallback = data['fallback'];
    }
    if (rawFallback is! Map) return null;
    try {
      return ImDynamicFallback.fromJson(Map<String, dynamic>.from(rawFallback));
    } on Object {
      return null;
    }
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
    if (json.containsKey('children') && rawChildren is! List) {
      throw const FormatException('Dynamic node children are not a list');
    }
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
    if (json.containsKey('events') && rawEvents is! Map) {
      throw const FormatException('Dynamic node events are not an object');
    }
    if (rawEvents is Map) {
      for (final entry in rawEvents.entries) {
        if (entry.key is! String || entry.value is! Map) {
          throw const FormatException(
            'Dynamic event definition is not an object',
          );
        }
        eventMap[entry.key as String] = Map<String, dynamic>.from(
          entry.value as Map,
        );
      }
    }

    final rawProps = json['props'];
    if (json.containsKey('props') && rawProps is! Map) {
      throw const FormatException('Dynamic node props are not an object');
    }

    return ImDynamicNode(
      id: _stringField(json, 'id') ?? '',
      type: _stringField(json, 'type') ?? '',
      props:
          rawProps is Map
              ? Map.unmodifiable(Map<String, dynamic>.from(rawProps))
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

  factory ImDynamicEvent.fromJson(Map<String, dynamic> json) => ImDynamicEvent(
    messageId: _stringValue(json['message_id']) ?? '',
    contentId: _stringValue(json['content_id']) ?? '',
    nodeId: _stringValue(json['node_id']) ?? '',
    event: _stringValue(json['event']) ?? '',
    action: _stringValue(json['action']),
    payload:
        json['payload'] is Map
            ? Map.unmodifiable(
              Map<String, dynamic>.from(json['payload'] as Map),
            )
            : const <String, dynamic>{},
  );

  factory ImDynamicEvent.fromSegmentData(Map<String, dynamic> data) {
    final nested = data['event'];
    return ImDynamicEvent.fromJson(
      nested is Map ? Map<String, dynamic>.from(nested) : data,
    );
  }

  static ImDynamicEvent? tryFromSegmentData(Map<String, dynamic> data) {
    try {
      return ImDynamicEvent.fromSegmentData(data);
    } on Object {
      return null;
    }
  }

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

/// Transport context for a validated dynamic interaction received from an IM
/// source. It remains outside [ImDynamicEvent] so the component event schema
/// stays independent from conversations and platform adapters.
class ImDynamicEventEnvelope {
  const ImDynamicEventEnvelope({
    required this.conversationId,
    required this.senderId,
    required this.event,
    required this.sentAt,
  });

  final String conversationId;
  final String senderId;
  final ImDynamicEvent event;
  final DateTime sentAt;
}

String? _stringValue(Object? value) =>
    value is String ? value : value?.toString();

String? _stringField(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is! String) {
    throw FormatException('Dynamic field $key is not a string');
  }
  return value;
}

Map<String, dynamic> _dynamicSchemaFromSegmentData(Map<String, dynamic> data) {
  Object? nested = data['content'];
  if (nested is! String && nested is! Map) nested = data['schema'];

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
  for (final key in const [
    'id',
    'version',
    'source',
    'tree',
    'fallback',
    'metadata',
  ]) {
    if (!schema.containsKey(key) && data.containsKey(key)) {
      schema[key] = data[key];
    }
  }
  return schema;
}
