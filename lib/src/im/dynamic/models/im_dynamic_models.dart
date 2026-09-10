import 'dart:convert';

import '../../content/im_content_event.dart';

const _maxDynamicWireIdentifierLength = 128;
const _maxDynamicWirePatches = 100;
const _maxDynamicWirePatchIndex = 50;
const _allowedDynamicWireEvents = <String>{
  'click',
  'tap',
  'submit',
  'change',
  'select',
};

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
    final operation = imDynamicPatchOperationFromString(
      _stringField(json, 'operation'),
    );
    final nodeId = _identifierField(json, 'node_id');
    final parentNodeId = _stringField(json, 'parent_node_id');
    final rawIndex = json['index'];
    if (json.containsKey('index') &&
        (rawIndex is! num ||
            !rawIndex.toDouble().isFinite ||
            rawIndex.toDouble() != rawIndex.truncateToDouble() ||
            rawIndex < 0 ||
            rawIndex > _maxDynamicWirePatchIndex)) {
      throw const FormatException('Dynamic patch index is invalid');
    }
    final rawProps = json['props'];
    if (json.containsKey('props') && rawProps is! Map) {
      throw const FormatException('Dynamic patch props are not an object');
    }
    final rawNode = json['node'];
    if (json.containsKey('node') && rawNode is! Map) {
      throw const FormatException('Dynamic patch node is not an object');
    }
    final node =
        rawNode is Map
            ? ImDynamicNode.fromJson(Map<String, dynamic>.from(rawNode))
            : null;
    if (operation == ImDynamicPatchOperation.create &&
        !_isDynamicIdentifier(parentNodeId)) {
      throw const FormatException(
        'Dynamic create patch requires parent_node_id',
      );
    }
    if ((operation == ImDynamicPatchOperation.create ||
            operation == ImDynamicPatchOperation.replace) &&
        node == null) {
      throw FormatException('Dynamic ${operation.name} patch requires a node');
    }
    if (node != null && node.id != nodeId) {
      throw const FormatException(
        'Dynamic patch node id does not match node_id',
      );
    }
    return ImDynamicPatch(
      operation: operation,
      nodeId: nodeId,
      parentNodeId: parentNodeId,
      index: rawIndex is num ? rawIndex.toInt() : null,
      props:
          rawProps is Map
              ? Map.unmodifiable(Map<String, dynamic>.from(rawProps))
              : const <String, dynamic>{},
      node: node,
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
    if (rawPatches.isEmpty || rawPatches.length > _maxDynamicWirePatches) {
      throw const FormatException('Dynamic update patch count is invalid');
    }
    if (rawPatches.any((patch) => patch is! Map)) {
      throw const FormatException('Dynamic update contains an invalid patch');
    }
    return ImDynamicPatchSet(
      messageId: _identifierField(json, 'message_id'),
      contentId: _identifierField(json, 'content_id'),
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
              if (!nested.containsKey('patches') && data.containsKey('patches'))
                'patches': data['patches'],
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

/// Transport context for a validated in-place content update.
///
/// Keeping updates separate from the conversation message stream lets one
/// bubble rebuild without notifying every row in the chat list.
class ImDynamicUpdateEnvelope {
  const ImDynamicUpdateEnvelope({
    required this.conversationId,
    required this.senderId,
    required this.update,
    required this.sentAt,
  });

  final String conversationId;
  final String senderId;
  final ImDynamicPatchSet update;
  final DateTime sentAt;
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

  factory ImDynamicState.fromJson(Map<String, dynamic> json) {
    final rawValues = json['values'];
    if (json.containsKey('values') && rawValues is! Map) {
      throw const FormatException('Dynamic state values are not an object');
    }
    return ImDynamicState(
      lifecycle: imDynamicLifecycleFromString(_stringField(json, 'lifecycle')),
      values:
          rawValues is Map
              ? Map.unmodifiable(Map<String, dynamic>.from(rawValues))
              : const <String, dynamic>{},
    );
  }

  Map<String, dynamic> toJson() => {
    'lifecycle': lifecycle.name,
    if (values.isNotEmpty) 'values': values,
  };
}

class ImDynamicEvent extends ImContentEvent {
  const ImDynamicEvent({
    required super.messageId,
    required super.contentId,
    required this.nodeId,
    required this.event,
    required this.action,
    this.eventId,
    super.payload = const <String, dynamic>{},
  }) : super(type: event);

  final String nodeId;
  final String event;
  final String? action;
  final String? eventId;

  factory ImDynamicEvent.fromJson(Map<String, dynamic> json) {
    final event = _stringField(json, 'event');
    if (event == null || !_allowedDynamicWireEvents.contains(event)) {
      throw FormatException('Dynamic event type is not allowed: $event');
    }
    final action = _stringField(json, 'action');
    if (action != null && action.length > _maxDynamicWireIdentifierLength) {
      throw const FormatException('Dynamic event action is too long');
    }
    final rawPayload = json['payload'];
    if (json.containsKey('payload') && rawPayload is! Map) {
      throw const FormatException('Dynamic event payload is not an object');
    }
    return ImDynamicEvent(
      messageId: _identifierField(json, 'message_id'),
      contentId: _identifierField(json, 'content_id'),
      nodeId: _identifierField(json, 'node_id'),
      event: event,
      action: action,
      eventId: _stringField(json, 'event_id'),
      payload:
          rawPayload is Map
              ? Map.unmodifiable(Map<String, dynamic>.from(rawPayload))
              : const <String, dynamic>{},
    );
  }

  factory ImDynamicEvent.fromSegmentData(Map<String, dynamic> data) {
    final nested = data['event'];
    if (nested is! Map) return ImDynamicEvent.fromJson(data);
    final json = Map<String, dynamic>.from(nested);
    for (final key in const [
      'message_id',
      'content_id',
      'node_id',
      'action',
      'payload',
    ]) {
      if (!json.containsKey(key) && data.containsKey(key)) {
        json[key] = data[key];
      }
    }
    return ImDynamicEvent.fromJson(json);
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
    if (eventId != null && eventId!.isNotEmpty) 'event_id': eventId,
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

/// One immutable interaction record returned by the server-side event ledger.
/// The server already applies visibility filtering before this model is built;
/// clients must therefore render these fields as-is and never infer hidden
/// actor or payload data.
class ImDynamicInteractionEvent {
  const ImDynamicInteractionEvent({
    required this.eventId,
    required this.nodeId,
    required this.event,
    required this.action,
    required this.payload,
    required this.actorId,
    required this.actorNickname,
    required this.actorKind,
    required this.createdAt,
  });

  final String eventId;
  final String nodeId;
  final String event;
  final String? action;
  final Map<String, dynamic> payload;
  final String? actorId;
  final String? actorNickname;
  final String? actorKind;
  final DateTime? createdAt;

  factory ImDynamicInteractionEvent.fromJson(Map<String, dynamic> json) {
    final rawPayload = json['payload'];
    final createdAtMS = (json['created_at_ms'] as num?)?.toInt();
    DateTime? createdAt;
    if (createdAtMS != null && createdAtMS > 0) {
      createdAt = DateTime.fromMillisecondsSinceEpoch(createdAtMS);
    } else if (json['created_at'] is String) {
      createdAt = DateTime.tryParse(json['created_at'] as String);
    }
    return ImDynamicInteractionEvent(
      eventId: '${json['event_id'] ?? ''}',
      nodeId: '${json['node_id'] ?? ''}',
      event: '${json['event'] ?? ''}',
      action: _optionalString(json['action']),
      payload:
          rawPayload is Map
              ? Map.unmodifiable(Map<String, dynamic>.from(rawPayload))
              : const <String, dynamic>{},
      actorId: _optionalString(json['actor_id']),
      actorNickname: _optionalString(json['actor_nickname']),
      actorKind: _optionalString(json['actor_kind']),
      createdAt: createdAt,
    );
  }

  Map<String, dynamic> toJson() => {
    'event_id': eventId,
    'node_id': nodeId,
    'event': event,
    if (action != null) 'action': action,
    if (payload.isNotEmpty) 'payload': payload,
    if (actorId != null) 'actor_id': actorId,
    if (actorNickname != null) 'actor_nickname': actorNickname,
    if (actorKind != null) 'actor_kind': actorKind,
    if (createdAt != null) 'created_at_ms': createdAt!.millisecondsSinceEpoch,
  };
}

/// Aggregate state plus the visibility-filtered event records for one card.
class ImDynamicInteractionSnapshot {
  const ImDynamicInteractionSnapshot({
    required this.conversationId,
    required this.messageId,
    required this.contentId,
    required this.visibility,
    required this.state,
    required this.events,
  });

  final String conversationId;
  final String messageId;
  final String contentId;
  final String visibility;
  final Map<String, dynamic> state;
  final List<ImDynamicInteractionEvent> events;

  factory ImDynamicInteractionSnapshot.fromJson(
    Map<String, dynamic> json, {
    String? conversationId,
  }) {
    final rawState = json['state'];
    final rawEvents = json['events'];
    return ImDynamicInteractionSnapshot(
      conversationId: '${json['conversation_id'] ?? conversationId ?? ''}',
      messageId: '${json['message_id'] ?? ''}',
      contentId: '${json['content_id'] ?? ''}',
      visibility: '${json['visibility'] ?? 'public_aggregate'}',
      state:
          rawState is Map
              ? Map.unmodifiable(Map<String, dynamic>.from(rawState))
              : const <String, dynamic>{},
      events:
          rawEvents is List
              ? List.unmodifiable(
                rawEvents.whereType<Map>().map(
                  (event) => ImDynamicInteractionEvent.fromJson(
                    Map<String, dynamic>.from(event),
                  ),
                ),
              )
              : const <ImDynamicInteractionEvent>[],
    );
  }

  int get responded => _stateInt('responded');
  int get total => _stateInt('total');
  bool get closed => state['closed'] == true;
  String get status => '${state['status'] ?? 'active'}';
  double get progress {
    if (total <= 0) return 0;
    return (responded / total).clamp(0.0, 1.0);
  }

  int _stateInt(String key) => (state[key] as num?)?.toInt() ?? 0;

  Map<String, dynamic> toJson() => {
    'conversation_id': conversationId,
    'message_id': messageId,
    'content_id': contentId,
    'visibility': visibility,
    'state': state,
    'events': events.map((event) => event.toJson()).toList(growable: false),
  };
}

String? _optionalString(Object? value) {
  if (value is! String || value.trim().isEmpty) return null;
  return value;
}

String? _stringField(Map<String, dynamic> json, String key) {
  if (!json.containsKey(key)) return null;
  final value = json[key];
  if (value is! String) {
    throw FormatException('Dynamic field $key is not a string');
  }
  return value;
}

bool _isDynamicIdentifier(String? value) =>
    value != null &&
    value.trim().isNotEmpty &&
    value.length <= _maxDynamicWireIdentifierLength;

String _identifierField(Map<String, dynamic> json, String key) {
  final value = _stringField(json, key);
  if (!_isDynamicIdentifier(value)) {
    throw FormatException('Dynamic field $key is not a valid identifier');
  }
  return value!;
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
