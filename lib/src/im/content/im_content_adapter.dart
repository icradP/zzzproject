import 'package:onebot_flutter/onebot_flutter.dart' show OneBotMessageSegment;

import '../dynamic/adapters/im_message_content_adapter.dart';
import '../models/im_models.dart';
import 'im_content_node.dart';

class ImContentAdapterContext {
  const ImContentAdapterContext({
    required this.message,
    required this.segment,
    required this.segmentIndex,
  });

  final ImMessage message;
  final OneBotMessageSegment segment;
  final int segmentIndex;
}

/// Converts one persisted message segment into the renderer-facing tree.
///
/// Implementations may add business-specific nodes, but they must return
/// declarative data only. They cannot execute commands or inject Flutter code.
abstract class ImContentAdapter {
  const ImContentAdapter();

  String get segmentType;

  ImContentNode convert(ImContentAdapterContext context);
}

/// Registry for the unified content interface.
///
/// [legacyAdapters] bridges the first-phase Dynamic Content compatibility
/// adapters. This keeps existing ZZZTerm business components source-compatible
/// while allowing the message bubble to consume one ContentNode tree.
class ImContentAdapterRegistry {
  ImContentAdapterRegistry({
    Iterable<ImContentAdapter> adapters = const [],
    this.legacyAdapters,
  }) {
    for (final adapter in adapters) {
      register(adapter);
    }
  }

  final ImMessageContentAdapterRegistry? legacyAdapters;
  final Map<String, ImContentAdapter> _adapters = {};

  void register(ImContentAdapter adapter) {
    final key = adapter.segmentType.trim();
    if (key.isEmpty) throw ArgumentError.value(adapter.segmentType, 'type');
    _adapters[key] = adapter;
  }

  ImContentAdapter? find(String segmentType) => _adapters[segmentType];

  Set<String> get types => Set.unmodifiable(_adapters.keys);

  ImContentNode convert({
    required ImMessage message,
    required OneBotMessageSegment segment,
    required int segmentIndex,
  }) {
    final context = ImContentAdapterContext(
      message: message,
      segment: segment,
      segmentIndex: segmentIndex,
    );
    final adapter = find(segment.type);
    if (adapter != null) return adapter.convert(context);

    final legacy = legacyAdapters?.convert(
      message: message,
      segment: segment,
      segmentIndex: segmentIndex,
    );
    if (legacy != null) {
      return ImContentNode.dynamicContent(id: legacy.id, content: legacy);
    }

    return ImContentNode.fromWire(
      id: '${message.id}:segment:$segmentIndex',
      type: segment.type,
      data: segment.data,
    );
  }

  List<ImContentNode> convertMessage(ImMessage message) {
    final segments = message.segments ?? const <OneBotMessageSegment>[];
    if (segments.isEmpty) return [_fallbackNode(message)];
    return [
      for (var index = 0; index < segments.length; index++)
        convert(
          message: message,
          segment: segments[index],
          segmentIndex: index,
        ),
    ];
  }

  ImContentTree convertMessageTree(ImMessage message) {
    return ImContentTree(
      messageId: message.id,
      children: convertMessage(message),
    );
  }

  ImContentNode _fallbackNode(ImMessage message) {
    final location = message.mediaPath ?? message.mediaUrl;
    return ImContentNode(
      id: '${message.id}:content',
      type: _nodeTypeForMessageKind(message.kind),
      data: <String, dynamic>{
        if (message.text.isNotEmpty) 'text': message.text,
        if (location != null && location.isNotEmpty) 'url': location,
        if (message.mediaSize != null) 'size': message.mediaSize,
        if (message.mediaMime != null) 'mime': message.mediaMime,
        if (message.mediaDuration != null)
          'duration_ms': message.mediaDuration!.inMilliseconds,
      },
    );
  }
}

ImContentNodeType _nodeTypeForMessageKind(ImMessageKind kind) => switch (kind) {
  ImMessageKind.text || ImMessageKind.at => ImContentNodeType.text,
  ImMessageKind.image || ImMessageKind.json => ImContentNodeType.image,
  ImMessageKind.record => ImContentNodeType.audio,
  ImMessageKind.video => ImContentNodeType.video,
  ImMessageKind.file => ImContentNodeType.file,
  ImMessageKind.face => ImContentNodeType.sticker,
  ImMessageKind.reply => ImContentNodeType.reply,
  ImMessageKind.forward => ImContentNodeType.forward,
  ImMessageKind.location => ImContentNodeType.location,
  ImMessageKind.share ||
  ImMessageKind.music ||
  ImMessageKind.contact => ImContentNodeType.share,
  ImMessageKind.dynamicContent => ImContentNodeType.dynamicContent,
  ImMessageKind.system || ImMessageKind.poke => ImContentNodeType.system,
};

typedef ContentAdapter = ImContentAdapter;
