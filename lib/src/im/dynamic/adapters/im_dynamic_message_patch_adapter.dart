import 'package:onebot_flutter/onebot_flutter.dart' show OneBotMessageSegment;

import '../../models/im_models.dart';
import '../models/im_dynamic_models.dart';
import '../runtime/im_dynamic_patch.dart';
import '../runtime/im_dynamic_validator.dart';

/// Applies a Dynamic Content patch to the matching segment of one IM message.
///
/// This is the integration boundary between the generic content runtime and
/// the existing OneBot-compatible message model.
class ImDynamicMessagePatchAdapter {
  const ImDynamicMessagePatchAdapter({
    this.patchApplier = const ImDynamicPatchApplier(),
  });

  final ImDynamicPatchApplier patchApplier;

  ImMessage replace(
    ImMessage message, {
    required String contentId,
    required ImDynamicContent replacement,
  }) {
    if (replacement.id != contentId) {
      throw const ImDynamicPatchException(
        'Replacement content id does not match content_id',
      );
    }
    final validation = const ImDynamicSchemaValidator().validate(replacement);
    if (!validation.isValid) {
      throw ImDynamicPatchException(validation.errors.join('; '));
    }
    final target = _findTarget(message, contentId);
    final updatedSegments = List<OneBotMessageSegment>.from(target.segments);
    updatedSegments[target.index] = OneBotMessageSegment(
      type: 'dynamic_content',
      data: Map<String, dynamic>.from(replacement.toJson())..remove('type'),
    );
    return message.copyWith(segments: updatedSegments);
  }

  ImMessage remove(ImMessage message, {required String contentId}) {
    final target = _findTarget(message, contentId);
    final updatedSegments = List<OneBotMessageSegment>.from(target.segments)
      ..removeAt(target.index);
    return message.copyWith(segments: updatedSegments);
  }

  ImMessage apply(ImMessage message, ImDynamicPatchSet update) {
    if (message.id != update.messageId) {
      throw ImDynamicPatchException(
        'Patch message ${update.messageId} does not match ${message.id}',
      );
    }
    final target = _findTarget(message, update.contentId);

    final patched = patchApplier.apply(target.content, update);
    final updatedSegments = List<OneBotMessageSegment>.from(target.segments);
    final segmentData = Map<String, dynamic>.from(patched.toJson())
      ..remove('type');
    updatedSegments[target.index] = OneBotMessageSegment(
      type: 'dynamic_content',
      data: segmentData,
    );
    return message.copyWith(segments: updatedSegments);
  }

  _DynamicMessageTarget _findTarget(ImMessage message, String contentId) {
    final segments = message.segments;
    if (segments == null) {
      throw const ImDynamicPatchException(
        'Dynamic target message has no content segments',
      );
    }
    var dynamicIndex = -1;
    ImDynamicContent? content;
    for (var index = 0; index < segments.length; index++) {
      final segment = segments[index];
      if (segment.type != 'dynamic_content') continue;
      final candidate = ImDynamicContent.tryFromSegmentData(segment.data);
      if (candidate?.id != contentId) continue;
      if (dynamicIndex >= 0) {
        throw ImDynamicPatchException(
          'Dynamic content $contentId is ambiguous',
        );
      }
      dynamicIndex = index;
      content = candidate;
    }
    if (dynamicIndex < 0 || content == null) {
      throw ImDynamicPatchException('Dynamic content $contentId was not found');
    }
    return _DynamicMessageTarget(
      segments: segments,
      index: dynamicIndex,
      content: content,
    );
  }
}

class _DynamicMessageTarget {
  const _DynamicMessageTarget({
    required this.segments,
    required this.index,
    required this.content,
  });

  final List<OneBotMessageSegment> segments;
  final int index;
  final ImDynamicContent content;
}
