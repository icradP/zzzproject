import 'im_dynamic_models.dart';

const _maxTemplateIdentifierLength = 128;
const _maxTemplateNameLength = 256;
final _templateVariablePattern = RegExp(r'^[A-Za-z_][A-Za-z0-9_.-]{0,63}$');
final _templatePlaceholderPattern = RegExp(
  r'\{\{([A-Za-z_][A-Za-z0-9_.-]{0,63})\}\}',
);

/// A reusable Dynamic Content schema with a controlled variable surface.
class ImDynamicTemplate {
  ImDynamicTemplate({
    required this.id,
    required this.name,
    required this.version,
    required List<String> variables,
    required this.schema,
    Map<String, dynamic> metadata = const <String, dynamic>{},
  }) : variables = List.unmodifiable(variables),
       metadata = Map.unmodifiable(metadata) {
    _validateTemplate();
  }

  final String id;
  final String name;
  final String version;
  final List<String> variables;
  final ImDynamicContent schema;
  final Map<String, dynamic> metadata;

  factory ImDynamicTemplate.fromJson(Map<String, dynamic> json) {
    final rawVariables = json['variables'];
    if (rawVariables is! List ||
        rawVariables.any((value) => value is! String)) {
      throw const FormatException('Dynamic template variables are invalid');
    }
    final rawSchema = json['schema'];
    if (rawSchema is! Map) {
      throw const FormatException('Dynamic template schema is missing');
    }
    final rawMetadata = json['metadata'];
    if (json.containsKey('metadata') && rawMetadata is! Map) {
      throw const FormatException('Dynamic template metadata is invalid');
    }
    return ImDynamicTemplate(
      id: _requiredTemplateString(json, 'id'),
      name: _requiredTemplateString(json, 'name'),
      version: _requiredTemplateString(json, 'version'),
      variables: rawVariables.cast<String>(),
      schema: ImDynamicContent.fromJson(Map<String, dynamic>.from(rawSchema)),
      metadata:
          rawMetadata is Map
              ? Map<String, dynamic>.from(rawMetadata)
              : const <String, dynamic>{},
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'version': version,
    'variables': variables,
    'schema': schema.toJson(),
    if (metadata.isNotEmpty) 'metadata': metadata,
  };

  /// Produces the same schema consumed by AI, user editing, and rendering.
  ImDynamicContent instantiate({
    required String contentId,
    required ImDynamicContentSource source,
    required Map<String, Object?> values,
  }) {
    if (contentId.trim().isEmpty ||
        contentId.length > _maxTemplateIdentifierLength) {
      throw const FormatException('Dynamic template content id is invalid');
    }
    final declared = variables.toSet();
    final missing = declared.difference(values.keys.toSet());
    if (missing.isNotEmpty) {
      throw FormatException(
        'Dynamic template variables are missing: ${missing.join(', ')}',
      );
    }
    final unknown = values.keys.toSet().difference(declared);
    if (unknown.isNotEmpty) {
      throw FormatException(
        'Dynamic template variables are unknown: ${unknown.join(', ')}',
      );
    }

    final resolved = _resolveTemplateValue(schema.toJson(), values);
    if (resolved is! Map) {
      throw const FormatException('Resolved dynamic template is invalid');
    }
    return ImDynamicContent.fromJson(
      Map<String, dynamic>.from(resolved),
    ).copyWith(id: contentId, source: source);
  }

  void _validateTemplate() {
    if (id.trim().isEmpty || id.length > _maxTemplateIdentifierLength) {
      throw const FormatException('Dynamic template id is invalid');
    }
    if (name.trim().isEmpty || name.length > _maxTemplateNameLength) {
      throw const FormatException('Dynamic template name is invalid');
    }
    if (version.trim().isEmpty || version.length > 32) {
      throw const FormatException('Dynamic template version is invalid');
    }
    final unique = <String>{};
    for (final variable in variables) {
      if (!_templateVariablePattern.hasMatch(variable) ||
          !unique.add(variable)) {
        throw FormatException(
          'Dynamic template variable is invalid: $variable',
        );
      }
    }
    final undeclared = _templateReferences(schema.toJson()).difference(unique);
    if (undeclared.isNotEmpty) {
      throw FormatException(
        'Dynamic template placeholders are undeclared: ${undeclared.join(', ')}',
      );
    }
  }
}

/// Version-aware registry for application and plugin templates.
class ImDynamicTemplateRegistry {
  ImDynamicTemplateRegistry({
    Iterable<ImDynamicTemplate> templates = const <ImDynamicTemplate>[],
  }) {
    for (final template in templates) {
      register(template);
    }
  }

  final Map<String, Map<String, ImDynamicTemplate>> _templates = {};

  void register(ImDynamicTemplate template) {
    (_templates[template.id] ??= {})[template.version] = template;
  }

  ImDynamicTemplate? find(String id, {String? version}) {
    final versions = _templates[id];
    if (versions == null || versions.isEmpty) return null;
    if (version != null) return versions[version];
    return versions.values.last;
  }

  Set<String> get ids => Set.unmodifiable(_templates.keys);

  Set<String> versionsFor(String id) =>
      Set.unmodifiable(_templates[id]?.keys ?? const <String>[]);
}

String _requiredTemplateString(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! String) {
    throw FormatException('Dynamic template $key is not a string');
  }
  return value;
}

Object? _resolveTemplateValue(Object? value, Map<String, Object?> variables) {
  if (value is String) {
    final exact = _templatePlaceholderPattern.firstMatch(value);
    if (exact != null && exact.group(0) == value) {
      return variables[exact.group(1)!];
    }
    return value.replaceAllMapped(
      _templatePlaceholderPattern,
      (match) => variables[match.group(1)!]?.toString() ?? '',
    );
  }
  if (value is List) {
    return value
        .map((item) => _resolveTemplateValue(item, variables))
        .toList(growable: false);
  }
  if (value is Map) {
    return <String, dynamic>{
      for (final entry in value.entries)
        entry.key.toString(): _resolveTemplateValue(entry.value, variables),
    };
  }
  return value;
}

Set<String> _templateReferences(Object? value) {
  final references = <String>{};

  void visit(Object? current) {
    if (current is String) {
      references.addAll(
        _templatePlaceholderPattern
            .allMatches(current)
            .map((match) => match.group(1)!),
      );
    } else if (current is List) {
      current.forEach(visit);
    } else if (current is Map) {
      current.values.forEach(visit);
    }
  }

  visit(value);
  return references;
}
