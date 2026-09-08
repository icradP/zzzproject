import 'im_dynamic_models.dart';

const _maxDynamicCommandIdentifierLength = 128;

enum ImDynamicCommandOperation { create, update, replace, remove }

/// A strongly typed application command for changing Dynamic Content.
///
/// Commands are local runtime/application objects. Transport adapters may map
/// them to their existing message actions, but the runtime does not depend on
/// a server, AI provider, or tool executor.
class ImDynamicCommand {
  const ImDynamicCommand._({
    required this.operation,
    required this.messageId,
    required this.contentId,
    this.content,
    this.update,
  });

  factory ImDynamicCommand.create({
    required String messageId,
    required ImDynamicContent content,
  }) {
    _validateIdentifier(messageId, 'message_id');
    _validateIdentifier(content.id, 'content_id');
    return ImDynamicCommand._(
      operation: ImDynamicCommandOperation.create,
      messageId: messageId,
      contentId: content.id,
      content: content,
    );
  }

  factory ImDynamicCommand.update(ImDynamicPatchSet update) {
    _validateIdentifier(update.messageId, 'message_id');
    _validateIdentifier(update.contentId, 'content_id');
    return ImDynamicCommand._(
      operation: ImDynamicCommandOperation.update,
      messageId: update.messageId,
      contentId: update.contentId,
      update: update,
    );
  }

  factory ImDynamicCommand.replace({
    required String messageId,
    required String contentId,
    required ImDynamicContent content,
  }) {
    _validateIdentifier(messageId, 'message_id');
    _validateIdentifier(contentId, 'content_id');
    if (content.id != contentId) {
      throw const FormatException(
        'Replacement content id does not match content_id',
      );
    }
    return ImDynamicCommand._(
      operation: ImDynamicCommandOperation.replace,
      messageId: messageId,
      contentId: contentId,
      content: content,
    );
  }

  factory ImDynamicCommand.remove({
    required String messageId,
    required String contentId,
  }) {
    _validateIdentifier(messageId, 'message_id');
    _validateIdentifier(contentId, 'content_id');
    return ImDynamicCommand._(
      operation: ImDynamicCommandOperation.remove,
      messageId: messageId,
      contentId: contentId,
    );
  }

  factory ImDynamicCommand.fromJson(Map<String, dynamic> json) {
    final type = json['type'];
    if (type != null && type != 'dynamic_command') {
      throw const FormatException('Dynamic command type is invalid');
    }
    final operation = _operationFromString(json['operation']);
    final messageId = _requiredIdentifier(json, 'message_id');
    final contentId = _requiredIdentifier(json, 'content_id');

    switch (operation) {
      case ImDynamicCommandOperation.create:
        final content = _requiredContent(json);
        if (content.id != contentId) {
          throw const FormatException(
            'Created content id does not match content_id',
          );
        }
        return ImDynamicCommand.create(messageId: messageId, content: content);
      case ImDynamicCommandOperation.update:
        final rawUpdate = json['update'];
        if (rawUpdate is! Map) {
          throw const FormatException('Dynamic update command is missing');
        }
        final updateJson = <String, dynamic>{
          ...Map<String, dynamic>.from(rawUpdate),
          'message_id': messageId,
          'content_id': contentId,
        };
        return ImDynamicCommand.update(ImDynamicPatchSet.fromJson(updateJson));
      case ImDynamicCommandOperation.replace:
        return ImDynamicCommand.replace(
          messageId: messageId,
          contentId: contentId,
          content: _requiredContent(json),
        );
      case ImDynamicCommandOperation.remove:
        if (json.containsKey('content') || json.containsKey('update')) {
          throw const FormatException(
            'Dynamic remove command cannot contain content or update',
          );
        }
        return ImDynamicCommand.remove(
          messageId: messageId,
          contentId: contentId,
        );
    }
  }

  final ImDynamicCommandOperation operation;
  final String messageId;
  final String contentId;
  final ImDynamicContent? content;
  final ImDynamicPatchSet? update;

  Map<String, dynamic> toJson() => {
    'type': 'dynamic_command',
    'operation': operation.name,
    'message_id': messageId,
    'content_id': contentId,
    if (content != null) 'content': content!.toJson(),
    if (update != null)
      'update': {
        'patches': update!.patches
            .map((patch) => patch.toJson())
            .toList(growable: false),
      },
  };
}

ImDynamicCommandOperation _operationFromString(Object? value) {
  if (value is! String) {
    throw const FormatException('Dynamic command operation is missing');
  }
  return switch (value) {
    'create' => ImDynamicCommandOperation.create,
    'update' => ImDynamicCommandOperation.update,
    'replace' => ImDynamicCommandOperation.replace,
    'remove' => ImDynamicCommandOperation.remove,
    _ => throw FormatException('Unknown dynamic command operation: $value'),
  };
}

ImDynamicContent _requiredContent(Map<String, dynamic> json) {
  final rawContent = json['content'];
  if (rawContent is! Map) {
    throw const FormatException('Dynamic command content is missing');
  }
  return ImDynamicContent.fromJson(Map<String, dynamic>.from(rawContent));
}

String _requiredIdentifier(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! String) {
    throw FormatException('Dynamic command $key is not a string');
  }
  _validateIdentifier(value, key);
  return value;
}

void _validateIdentifier(String value, String key) {
  if (value.trim().isEmpty ||
      value.length > _maxDynamicCommandIdentifierLength) {
    throw FormatException('Dynamic command $key is invalid');
  }
}
