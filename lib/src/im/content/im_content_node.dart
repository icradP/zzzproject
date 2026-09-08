import '../dynamic/models/im_dynamic_models.dart';

/// The stable semantic types understood by the unified message content layer.
///
/// This type is intentionally independent from the OneBot wire model. A
/// message segment can keep its original payload while the renderer consumes
/// a typed node, which lets legacy content migrate without changing the wire
/// protocol or its persisted representation.
enum ImContentNodeType {
  text,
  markdown,
  icon,
  row,
  column,
  card,
  container,
  divider,
  button,
  input,
  checkbox,
  select,
  progress,
  status,
  badge,
  image,
  video,
  audio,
  file,
  share,
  location,
  forward,
  system,
  sticker,
  reply,
  dynamicContent,
  unknown,
}

extension ImContentNodeTypeValue on ImContentNodeType {
  String get wireName => switch (this) {
    ImContentNodeType.text => 'text',
    ImContentNodeType.markdown => 'markdown',
    ImContentNodeType.icon => 'icon',
    ImContentNodeType.row => 'row',
    ImContentNodeType.column => 'column',
    ImContentNodeType.card => 'card',
    ImContentNodeType.container => 'container',
    ImContentNodeType.divider => 'divider',
    ImContentNodeType.button => 'button',
    ImContentNodeType.input => 'input',
    ImContentNodeType.checkbox => 'checkbox',
    ImContentNodeType.select => 'select',
    ImContentNodeType.progress => 'progress',
    ImContentNodeType.status => 'status',
    ImContentNodeType.badge => 'badge',
    ImContentNodeType.image => 'image',
    ImContentNodeType.video => 'video',
    ImContentNodeType.audio => 'record',
    ImContentNodeType.file => 'file',
    ImContentNodeType.share => 'share',
    ImContentNodeType.location => 'location',
    ImContentNodeType.forward => 'forward',
    ImContentNodeType.system => 'system',
    ImContentNodeType.sticker => 'sticker',
    ImContentNodeType.reply => 'reply',
    ImContentNodeType.dynamicContent => 'dynamic_content',
    ImContentNodeType.unknown => 'unknown',
  };
}

ImContentNodeType imContentNodeTypeFromWire(String value) => switch (value) {
  'text' => ImContentNodeType.text,
  'markdown' => ImContentNodeType.markdown,
  'icon' => ImContentNodeType.icon,
  'row' => ImContentNodeType.row,
  'column' => ImContentNodeType.column,
  'card' => ImContentNodeType.card,
  'container' => ImContentNodeType.container,
  'divider' => ImContentNodeType.divider,
  'button' => ImContentNodeType.button,
  'input' => ImContentNodeType.input,
  'checkbox' => ImContentNodeType.checkbox,
  'select' => ImContentNodeType.select,
  'progress' => ImContentNodeType.progress,
  'status' => ImContentNodeType.status,
  'badge' => ImContentNodeType.badge,
  'image' => ImContentNodeType.image,
  'video' => ImContentNodeType.video,
  'record' || 'audio' => ImContentNodeType.audio,
  'file' => ImContentNodeType.file,
  'share' => ImContentNodeType.share,
  'location' => ImContentNodeType.location,
  'forward' => ImContentNodeType.forward,
  'system' => ImContentNodeType.system,
  'sticker' || 'face' => ImContentNodeType.sticker,
  'reply' => ImContentNodeType.reply,
  'dynamic_content' => ImContentNodeType.dynamicContent,
  _ => ImContentNodeType.unknown,
};

/// A renderer-facing node in the unified content tree.
///
/// `data` remains a deliberately small escape hatch for platform-specific
/// properties. The node kind, identity, children, and dynamic content are
/// typed so future renderers and editors do not need to inspect raw segment
/// type strings to understand the tree.
class ImContentNode {
  const ImContentNode({
    required this.id,
    required this.type,
    this.data = const <String, dynamic>{},
    this.children = const <ImContentNode>[],
    this.events = const <String, Map<String, dynamic>>{},
    this.dynamicContent,
    this.originalType,
  });

  final String id;
  final ImContentNodeType type;
  final Map<String, dynamic> data;
  final List<ImContentNode> children;
  final Map<String, Map<String, dynamic>> events;
  final ImDynamicContent? dynamicContent;

  /// Preserves an extension or unknown wire type for fallback rendering.
  final String? originalType;

  String get wireType => originalType ?? type.wireName;

  bool get isDynamic => dynamicContent != null;

  factory ImContentNode.fromWire({
    required String id,
    required String type,
    required Map<String, dynamic> data,
  }) {
    if (type == 'dynamic_content') {
      final content = ImDynamicContent.tryFromSegmentData(data);
      if (content != null) {
        return ImContentNode.dynamicContent(id: id, content: content);
      }
    }
    return ImContentNode(
      id: id,
      type: imContentNodeTypeFromWire(type),
      data: Map.unmodifiable(Map<String, dynamic>.from(data)),
      originalType: type,
    );
  }

  factory ImContentNode.dynamicContent({
    required String id,
    required ImDynamicContent content,
  }) {
    return ImContentNode(
      id: id,
      type: ImContentNodeType.dynamicContent,
      dynamicContent: content,
      children: [ImContentNode.fromDynamicNode(content.tree)],
    );
  }

  factory ImContentNode.fromDynamicNode(ImDynamicNode node) {
    return ImContentNode(
      id: node.id,
      type: imContentNodeTypeFromWire(node.type),
      data: node.props,
      children: node.children
          .map(ImContentNode.fromDynamicNode)
          .toList(growable: false),
      events: node.events,
      originalType: node.type,
    );
  }

  ImDynamicNode toDynamicNode() {
    return ImDynamicNode(
      id: id,
      type: wireType,
      props: data,
      children: children
          .map((child) => child.toDynamicNode())
          .toList(growable: false),
      events: events,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'type': wireType,
    if (data.isNotEmpty) 'data': data,
    if (children.isNotEmpty)
      'children': children.map((child) => child.toJson()).toList(),
    if (events.isNotEmpty) 'events': events,
    if (dynamicContent != null) 'dynamic_content': dynamicContent!.toJson(),
  };
}

class ImContentTree {
  const ImContentTree({required this.messageId, required this.children});

  final String messageId;
  final List<ImContentNode> children;

  ImContentNode? findById(String nodeId) {
    ImContentNode? visit(ImContentNode node) {
      if (node.id == nodeId) return node;
      for (final child in node.children) {
        final found = visit(child);
        if (found != null) return found;
      }
      return null;
    }

    for (final child in children) {
      final found = visit(child);
      if (found != null) return found;
    }
    return null;
  }
}

/// Alias used in architecture documentation and embedding code.
typedef ContentNode = ImContentNode;
