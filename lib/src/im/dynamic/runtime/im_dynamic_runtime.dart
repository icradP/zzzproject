import 'package:flutter/foundation.dart';

import '../models/im_dynamic_models.dart';
import 'im_dynamic_patch.dart';

/// Serializable local snapshot for restoring Dynamic Content after history
/// reload. It is intentionally separate from the server message schema.
class ImDynamicRuntimeSnapshot {
  const ImDynamicRuntimeSnapshot({
    required this.messageId,
    required this.content,
    required this.state,
  });

  final String messageId;
  final ImDynamicContent content;
  final ImDynamicState state;

  factory ImDynamicRuntimeSnapshot.fromJson(Map<String, dynamic> json) {
    final rawContent = json['content'];
    final rawState = json['state'];
    if (rawContent is! Map || rawState is! Map) {
      throw const FormatException('Dynamic runtime snapshot is incomplete');
    }
    final messageId = json['message_id'];
    if (messageId is! String || messageId.trim().isEmpty) {
      throw const FormatException(
        'Dynamic runtime snapshot message_id is invalid',
      );
    }
    return ImDynamicRuntimeSnapshot(
      messageId: messageId,
      content: ImDynamicContent.fromJson(Map<String, dynamic>.from(rawContent)),
      state: ImDynamicState.fromJson(Map<String, dynamic>.from(rawState)),
    );
  }

  Map<String, dynamic> toJson() => {
    'type': 'dynamic_runtime_snapshot',
    'message_id': messageId,
    'content': content.toJson(),
    'state': state.toJson(),
  };
}

/// Owns mutable runtime state while keeping the schema immutable and
/// serializable. A view can listen to this object without owning business data.
class ImDynamicRuntime extends ChangeNotifier {
  ImDynamicRuntime({
    required ImDynamicContent content,
    ImDynamicState state = const ImDynamicState(),
    ImDynamicPatchApplier patchApplier = const ImDynamicPatchApplier(),
  }) : _content = content,
       _state = state,
       _patchApplier = patchApplier;

  ImDynamicRuntime.fromSnapshot(
    ImDynamicRuntimeSnapshot snapshot, {
    ImDynamicPatchApplier patchApplier = const ImDynamicPatchApplier(),
  }) : this(
         content: snapshot.content,
         state: snapshot.state,
         patchApplier: patchApplier,
       );

  ImDynamicContent _content;
  ImDynamicState _state;
  final ImDynamicPatchApplier _patchApplier;

  ImDynamicContent get content => _content;
  ImDynamicState get state => _state;

  ImDynamicRuntimeSnapshot snapshot({required String messageId}) =>
      ImDynamicRuntimeSnapshot(
        messageId: messageId,
        content: _content,
        state: _state,
      );

  void restore(ImDynamicRuntimeSnapshot snapshot) {
    if (snapshot.content.id != _content.id) {
      throw ArgumentError.value(
        snapshot.content.id,
        'snapshot',
        'Snapshot content id does not match the runtime.',
      );
    }
    _content = snapshot.content;
    _state = snapshot.state;
    notifyListeners();
  }

  /// Synchronizes a fresh persisted schema while preserving runtime state.
  ///
  /// This is used by an owning widget during its own update lifecycle, so the
  /// subsequent widget build observes the new content without a second
  /// notification-driven rebuild.
  void synchronizeContent(ImDynamicContent content) {
    if (content.id != _content.id) {
      throw ArgumentError.value(
        content.id,
        'content',
        'Content id does not match the runtime.',
      );
    }
    _content = content;
  }

  void setState(ImDynamicState state) {
    _state = state;
    notifyListeners();
  }

  void updateState({
    ImDynamicLifecycle? lifecycle,
    Map<String, dynamic>? values,
  }) {
    _state = _state.copyWith(
      lifecycle: lifecycle,
      values: values == null ? null : {..._state.values, ...values},
    );
    notifyListeners();
  }

  void apply(ImDynamicPatchSet update) {
    _content = _patchApplier.apply(_content, update);
    notifyListeners();
  }
}
