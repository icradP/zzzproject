import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

abstract interface class ImSecretStore {
  Future<String?> read(String key);

  Future<void> write(String key, String value);

  Future<void> delete(String key);
}

class FlutterImSecretStore implements ImSecretStore {
  const FlutterImSecretStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

/// Client-only settings for uploading images directly to an external host.
///
/// The authentication token is deliberately excluded from [toJson] and is
/// persisted through [ImSecretStore].
class ImImageHostingConfig {
  const ImImageHostingConfig({
    this.enabled = false,
    this.endpoint = '',
    this.fileField = 'file',
    this.authorizationHeader = 'Authorization',
    this.authorizationScheme = 'Bearer',
    this.responseUrlPath = 'data.url',
    this.token = '',
  });

  final bool enabled;
  final String endpoint;
  final String fileField;
  final String authorizationHeader;
  final String authorizationScheme;
  final String responseUrlPath;
  final String token;

  static const preferencesKey = 'im_image_hosting_config_v1';
  static const tokenKey = 'im_image_hosting_token_v1';

  ImImageHostingConfig copyWith({
    bool? enabled,
    String? endpoint,
    String? fileField,
    String? authorizationHeader,
    String? authorizationScheme,
    String? responseUrlPath,
    String? token,
  }) {
    return ImImageHostingConfig(
      enabled: enabled ?? this.enabled,
      endpoint: endpoint ?? this.endpoint,
      fileField: fileField ?? this.fileField,
      authorizationHeader: authorizationHeader ?? this.authorizationHeader,
      authorizationScheme: authorizationScheme ?? this.authorizationScheme,
      responseUrlPath: responseUrlPath ?? this.responseUrlPath,
      token: token ?? this.token,
    );
  }

  Map<String, Object?> toJson() => {
    'version': 1,
    'enabled': enabled,
    'endpoint': endpoint,
    'fileField': fileField,
    'authorizationHeader': authorizationHeader,
    'authorizationScheme': authorizationScheme,
    'responseUrlPath': responseUrlPath,
    'hasToken': token.isNotEmpty,
  };

  factory ImImageHostingConfig.fromJson(
    Map<String, dynamic> json, {
    String token = '',
  }) {
    return ImImageHostingConfig(
      enabled: json['enabled'] as bool? ?? false,
      endpoint: (json['endpoint'] as String? ?? '').trim(),
      fileField: (json['fileField'] as String? ?? 'file').trim(),
      authorizationHeader:
          (json['authorizationHeader'] as String? ?? 'Authorization').trim(),
      authorizationScheme:
          (json['authorizationScheme'] as String? ?? 'Bearer').trim(),
      responseUrlPath:
          (json['responseUrlPath'] as String? ?? 'data.url').trim(),
      token: token,
    );
  }

  String? validationError() {
    if (!enabled) return null;
    final uri = Uri.tryParse(endpoint.trim());
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment) {
      return 'Image hosting endpoint must be a valid HTTPS URL.';
    }
    if (!_validMultipartName(fileField)) {
      return 'File field must be a valid multipart field name.';
    }
    if (responseUrlPath.trim().isEmpty || responseUrlPath.length > 256) {
      return 'Response URL path is required.';
    }
    if (token.isNotEmpty && !_validHeaderName(authorizationHeader)) {
      return 'Authorization header is invalid.';
    }
    if (token.contains(RegExp(r'[\r\n]')) ||
        authorizationScheme.contains(RegExp(r'[\r\n]'))) {
      return 'Authorization value is invalid.';
    }
    return null;
  }

  String get authorizationValue {
    final scheme = authorizationScheme.trim();
    return scheme.isEmpty ? token : '$scheme $token';
  }

  Future<void> save({ImSecretStore? secretStore}) async {
    final preferences = await SharedPreferences.getInstance();
    final previous = preferences.getString(preferencesKey);
    var previouslyHadToken = false;
    if (previous != null) {
      try {
        previouslyHadToken =
            (jsonDecode(previous) as Map)['hasToken'] as bool? ?? false;
      } catch (_) {}
    }
    if (token.isNotEmpty) {
      await (secretStore ?? const FlutterImSecretStore()).write(
        tokenKey,
        token,
      );
    } else if (previouslyHadToken) {
      await (secretStore ?? const FlutterImSecretStore()).delete(tokenKey);
    }
    await preferences.setString(preferencesKey, jsonEncode(toJson()));
  }

  static Future<ImImageHostingConfig> load({ImSecretStore? secretStore}) async {
    final preferences = await SharedPreferences.getInstance();
    final raw = preferences.getString(preferencesKey);
    if (raw == null) return const ImImageHostingConfig();
    late final Map<String, dynamic> json;
    try {
      json = Map<String, dynamic>.from(jsonDecode(raw) as Map);
    } catch (_) {
      return const ImImageHostingConfig();
    }
    if (json['hasToken'] != true) {
      return ImImageHostingConfig.fromJson(json);
    }
    String token = '';
    try {
      token =
          await (secretStore ?? const FlutterImSecretStore()).read(tokenKey) ??
          '';
    } catch (_) {
      // Some test and unsupported platform environments have no secure-store
      // plugin. Keep image hosting disabled or tokenless in those environments.
    }
    return ImImageHostingConfig.fromJson(json, token: token);
  }

  static bool _validMultipartName(String value) {
    final normalized = value.trim();
    return normalized.isNotEmpty &&
        normalized.length <= 128 &&
        !normalized.contains(RegExp(r'[\r\n"]'));
  }

  static bool _validHeaderName(String value) {
    return RegExp(r"^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$").hasMatch(value.trim());
  }
}
