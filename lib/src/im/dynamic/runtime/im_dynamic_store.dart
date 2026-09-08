import 'package:flutter/foundation.dart';

import '../models/im_dynamic_command.dart';
import '../models/im_dynamic_models.dart';
import 'im_dynamic_patch.dart';
import 'im_dynamic_validator.dart';

class ImDynamicStoreException implements Exception {
  const ImDynamicStoreException(this.message);

  final String message;

  @override
  String toString() => 'ImDynamicStoreException: $message';
}

/// Owns Dynamic Content instances independently from message transport.
///
/// A command is applied fully before listeners are notified, so a failed
/// patch cannot expose a partially updated content tree.
class ImDynamicStore extends ChangeNotifier {
  ImDynamicStore({
    ImDynamicPatchApplier patchApplier = const ImDynamicPatchApplier(),
    this.validator = const ImDynamicSchemaValidator(),
  }) : _patchApplier = patchApplier;

  final ImDynamicPatchApplier _patchApplier;
  final ImDynamicSchemaValidator validator;
  final Map<String, Map<String, ImDynamicContent>> _messages = {};

  ImDynamicContent? contentFor(String messageId, String contentId) =>
      _messages[messageId]?[contentId];

  List<ImDynamicContent> contentsForMessage(String messageId) =>
      List.unmodifiable(_messages[messageId]?.values ?? const []);

  void apply(ImDynamicCommand command) {
    final contents = _messages[command.messageId];
    final existing = contents?[command.contentId];

    switch (command.operation) {
      case ImDynamicCommandOperation.create:
        if (existing != null) {
          throw ImDynamicStoreException(
            'Content ${command.contentId} already exists',
          );
        }
        final content = command.content;
        if (content == null) {
          throw const ImDynamicStoreException('Create command has no content');
        }
        _ensureValid(content);
        (_messages[command.messageId] ??= {})[command.contentId] = content;
      case ImDynamicCommandOperation.update:
        if (existing == null) {
          throw ImDynamicStoreException(
            'Content ${command.contentId} was not found',
          );
        }
        final update = command.update;
        if (update == null) {
          throw const ImDynamicStoreException('Update command has no patches');
        }
        final next = _patchApplier.apply(existing, update);
        _ensureValid(next);
        contents![command.contentId] = next;
      case ImDynamicCommandOperation.replace:
        if (existing == null) {
          throw ImDynamicStoreException(
            'Content ${command.contentId} was not found',
          );
        }
        final replacement = command.content;
        if (replacement == null) {
          throw const ImDynamicStoreException('Replace command has no content');
        }
        _ensureValid(replacement);
        contents![command.contentId] = replacement;
      case ImDynamicCommandOperation.remove:
        if (existing == null) {
          throw ImDynamicStoreException(
            'Content ${command.contentId} was not found',
          );
        }
        contents!.remove(command.contentId);
        if (contents.isEmpty) _messages.remove(command.messageId);
    }
    notifyListeners();
  }

  void clearMessage(String messageId) {
    if (_messages.remove(messageId) != null) notifyListeners();
  }

  void _ensureValid(ImDynamicContent content) {
    final result = validator.validate(content);
    if (!result.isValid) {
      throw ImDynamicStoreException(result.errors.join('; '));
    }
  }
}
