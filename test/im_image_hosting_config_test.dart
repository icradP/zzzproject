import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zzzproject/src/im/data/im_image_hosting_config.dart';

class _MemorySecretStore implements ImSecretStore {
  final values = <String, String>{};

  @override
  Future<void> delete(String key) async => values.remove(key);

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('persists image host token only in the secret store', () async {
    final secrets = _MemorySecretStore();
    const config = ImImageHostingConfig(
      enabled: true,
      endpoint: 'https://images.example.test/upload',
      fileField: 'asset',
      authorizationHeader: 'X-API-Key',
      authorizationScheme: '',
      responseUrlPath: 'result.0.url',
      token: 'private-token',
    );

    await config.save(secretStore: secrets);

    final preferences = await SharedPreferences.getInstance();
    final persisted = preferences.getString(
      ImImageHostingConfig.preferencesKey,
    );
    expect(persisted, isNotNull);
    expect(persisted, isNot(contains('private-token')));
    expect(jsonDecode(persisted!)['endpoint'], config.endpoint);
    expect(jsonDecode(persisted)['hasToken'], isTrue);
    expect(secrets.values[ImImageHostingConfig.tokenKey], 'private-token');

    final loaded = await ImImageHostingConfig.load(secretStore: secrets);
    expect(loaded.enabled, isTrue);
    expect(loaded.fileField, 'asset');
    expect(loaded.authorizationHeader, 'X-API-Key');
    expect(loaded.responseUrlPath, 'result.0.url');
    expect(loaded.token, 'private-token');
  });

  test('does not access secure storage when no token is configured', () async {
    final secrets = _TrackingSecretStore();
    await const ImImageHostingConfig().save(secretStore: secrets);
    final loaded = await ImImageHostingConfig.load(secretStore: secrets);

    expect(loaded.enabled, isFalse);
    expect(secrets.operations, isEmpty);
  });

  test('requires HTTPS only when custom hosting is enabled', () {
    expect(const ImImageHostingConfig().validationError(), isNull);
    expect(
      const ImImageHostingConfig(
        enabled: true,
        endpoint: 'http://images.example.test/upload',
      ).validationError(),
      contains('HTTPS'),
    );
  });
}

class _TrackingSecretStore implements ImSecretStore {
  final operations = <String>[];

  @override
  Future<void> delete(String key) async => operations.add('delete');

  @override
  Future<String?> read(String key) async {
    operations.add('read');
    return null;
  }

  @override
  Future<void> write(String key, String value) async => operations.add('write');
}
