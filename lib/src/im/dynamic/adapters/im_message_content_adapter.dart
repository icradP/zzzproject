import 'package:onebot_flutter/onebot_flutter.dart' show OneBotMessageSegment;

import '../../models/im_models.dart';
import '../models/im_dynamic_models.dart';

/// Context supplied while adapting one legacy message segment into the
/// controlled Dynamic Content schema.
class ImMessageContentAdapterContext {
  const ImMessageContentAdapterContext({
    required this.message,
    required this.segment,
    required this.segmentIndex,
  });

  final ImMessage message;
  final OneBotMessageSegment segment;
  final int segmentIndex;
}

/// Compatibility layer for incrementally moving a legacy business segment
/// into the shared Dynamic Content runtime without changing its wire format.
abstract class ImMessageContentAdapter {
  const ImMessageContentAdapter();

  String get segmentType;

  ImDynamicContent convert(ImMessageContentAdapterContext context);
}

class ImMessageContentAdapterRegistry {
  ImMessageContentAdapterRegistry({
    Iterable<ImMessageContentAdapter> adapters = const [],
  }) {
    for (final adapter in adapters) {
      register(adapter);
    }
  }

  final Map<String, ImMessageContentAdapter> _adapters = {};

  void register(ImMessageContentAdapter adapter) {
    final key = adapter.segmentType.trim();
    if (key.isEmpty) throw ArgumentError.value(adapter.segmentType, 'type');
    _adapters[key] = adapter;
  }

  ImMessageContentAdapter? find(String segmentType) => _adapters[segmentType];

  Set<String> get types => Set.unmodifiable(_adapters.keys);

  ImDynamicContent? convert({
    required ImMessage message,
    required OneBotMessageSegment segment,
    required int segmentIndex,
  }) {
    final adapter = find(segment.type);
    if (adapter == null) return null;
    return adapter.convert(
      ImMessageContentAdapterContext(
        message: message,
        segment: segment,
        segmentIndex: segmentIndex,
      ),
    );
  }
}
