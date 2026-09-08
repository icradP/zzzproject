/// Versioned Dynamic Content features advertised during ZZZ Server auth.
/// Protocol, schema, and component versions intentionally remain separate.
class ImDynamicProtocolCapabilities {
  const ImDynamicProtocolCapabilities({
    required this.protocolVersion,
    required this.schemaVersions,
    required this.componentVersion,
    required this.components,
    required this.supportsEvents,
    required this.supportsNodeIdPatch,
  });

  static const current = ImDynamicProtocolCapabilities(
    protocolVersion: '1.0',
    schemaVersions: <String>['1.0'],
    componentVersion: '1.0',
    components: <String>{
      'text',
      'markdown',
      'icon',
      'image',
      'row',
      'column',
      'card',
      'container',
      'divider',
      'button',
      'input',
      'checkbox',
      'select',
      'progress',
      'status',
      'badge',
    },
    supportsEvents: true,
    supportsNodeIdPatch: true,
  );

  final String protocolVersion;
  final List<String> schemaVersions;
  final String componentVersion;
  final Set<String> components;
  final bool supportsEvents;
  final bool supportsNodeIdPatch;

  bool get supportsDynamicContent =>
      protocolVersion.isNotEmpty &&
      schemaVersions.isNotEmpty &&
      componentVersion.isNotEmpty;

  Map<String, dynamic> toJson() => {
    'protocol_version': protocolVersion,
    'dynamic_content': {
      'schema_versions': schemaVersions,
      'component_version': componentVersion,
      'components': components.toList(growable: false)..sort(),
      'events': supportsEvents,
      'node_id_patch': supportsNodeIdPatch,
    },
  };

  factory ImDynamicProtocolCapabilities.fromJson(Map<String, dynamic> json) {
    final dynamicContent = json['dynamic_content'];
    if (dynamicContent is! Map) {
      throw const FormatException('Dynamic content capabilities are missing');
    }
    final data = Map<String, dynamic>.from(dynamicContent);
    final rawSchemas = data['schema_versions'];
    final rawComponents = data['components'];
    if (rawSchemas is! List || rawComponents is! List) {
      throw const FormatException('Dynamic capability lists are invalid');
    }
    return ImDynamicProtocolCapabilities(
      protocolVersion: _requiredCapabilityString(json, 'protocol_version'),
      schemaVersions: List.unmodifiable(
        rawSchemas.map(
          (value) => _requiredCapabilityValue(value, 'schema_versions'),
        ),
      ),
      componentVersion: _requiredCapabilityString(data, 'component_version'),
      components: Set.unmodifiable(
        rawComponents.map(
          (value) => _requiredCapabilityValue(value, 'components'),
        ),
      ),
      supportsEvents: data['events'] == true,
      supportsNodeIdPatch: data['node_id_patch'] == true,
    );
  }

  static ImDynamicProtocolCapabilities? tryFromJson(Object? value) {
    if (value is! Map) return null;
    try {
      return ImDynamicProtocolCapabilities.fromJson(
        Map<String, dynamic>.from(value),
      );
    } on Object {
      return null;
    }
  }
}

String _requiredCapabilityString(Map<String, dynamic> json, String key) =>
    _requiredCapabilityValue(json[key], key);

String _requiredCapabilityValue(Object? value, String field) {
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('Dynamic capability $field is invalid');
  }
  return value;
}
