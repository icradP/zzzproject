import 'package:flutter_test/flutter_test.dart';
import 'package:zzzproject/zzz_im_chat.dart';

void main() {
  final template = ImDynamicTemplate(
    id: 'device-status',
    name: 'Device status',
    version: '1.0',
    variables: const ['device_id', 'progress'],
    schema: const ImDynamicContent(
      id: 'template-placeholder',
      version: '1.0',
      source: ImDynamicContentSource.system,
      tree: ImDynamicNode(
        id: 'root',
        type: 'column',
        children: [
          ImDynamicNode(
            id: 'title',
            type: 'text',
            props: {'text': 'Device {{device_id}}'},
          ),
          ImDynamicNode(
            id: 'progress',
            type: 'progress',
            props: {'value': '{{progress}}'},
          ),
        ],
      ),
    ),
    metadata: const {'category': 'device'},
  );

  test('dynamic template round-trips without changing its schema', () {
    final decoded = ImDynamicTemplate.fromJson(template.toJson());

    expect(decoded.id, template.id);
    expect(decoded.variables, template.variables);
    expect(decoded.toJson(), template.toJson());
  });

  test('template instantiation preserves typed values in shared schema', () {
    final content = template.instantiate(
      contentId: 'device-card-1',
      source: ImDynamicContentSource.ai,
      values: const {'device_id': 'IPC-001', 'progress': 0.6},
    );

    expect(content.id, 'device-card-1');
    expect(content.source, ImDynamicContentSource.ai);
    expect(content.tree.findById('title')?.props['text'], 'Device IPC-001');
    expect(content.tree.findById('progress')?.props['value'], 0.6);
    expect(const ImDynamicSchemaValidator().validate(content).isValid, isTrue);
  });

  test('template rejects missing, unknown, and duplicate variables', () {
    expect(
      () => template.instantiate(
        contentId: 'device-card-1',
        source: ImDynamicContentSource.user,
        values: const {'device_id': 'IPC-001'},
      ),
      throwsFormatException,
    );
    expect(
      () => template.instantiate(
        contentId: 'device-card-1',
        source: ImDynamicContentSource.user,
        values: const {'device_id': 'IPC-001', 'progress': 0.6, 'extra': true},
      ),
      throwsFormatException,
    );
    expect(
      () => ImDynamicTemplate(
        id: 'invalid',
        name: 'Invalid',
        version: '1.0',
        variables: const ['value', 'value'],
        schema: template.schema,
      ),
      throwsFormatException,
    );
  });

  test('template registry keeps versions independently', () {
    final registry = ImDynamicTemplateRegistry(templates: [template]);
    final next = ImDynamicTemplate(
      id: template.id,
      name: template.name,
      version: '1.1',
      variables: template.variables,
      schema: template.schema,
    );
    registry.register(next);

    expect(registry.find(template.id, version: '1.0'), same(template));
    expect(registry.find(template.id), same(next));
    expect(registry.versionsFor(template.id), {'1.0', '1.1'});
  });
}
