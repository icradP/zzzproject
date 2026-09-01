import 'package:flutter/foundation.dart' show kIsWeb;

import 'package:onebot_flutter/onebot_flutter.dart'
    show OneBotConfig, OneBotWsMode;

import '../data/im_connection_config.dart';
import '../data/im_image_hosting_config.dart';
import '../data/im_image_hosting_uploader.dart';
import '../data/im_repository.dart';
import '../data/im_storage_config_web.dart'
    if (dart.library.io) '../data/im_storage_config.dart';
import '../data/mock_im_repository.dart';
import 'composite_im_repository.dart';
import 'nonebot/nonebot_source_web.dart'
    if (dart.library.io) 'nonebot/nonebot_source.dart';
import 'source_repository.dart';
import 'zzz_server/zzz_server_source.dart';

typedef ImAvatarResolver = String? Function(String userId);
typedef ImDisplayNameResolver =
    String Function(String userId, String? nickname);

class ImClientRuntime {
  const ImClientRuntime({
    required this.repository,
    required this.noneBotSources,
    required this.zzzServerSources,
  });

  final ImRepository repository;
  final Map<String, NoneBotSource> noneBotSources;
  final Map<String, ZzzServerSource> zzzServerSources;

  CompositeImRepository? get compositeRepository =>
      repository is CompositeImRepository
          ? repository as CompositeImRepository
          : null;
}

/// Creates protocol adapters from local profiles and exposes one repository.
class ImSourceRegistry {
  const ImSourceRegistry({
    required this.storageConfig,
    required this.avatarResolver,
    this.imageHostingConfig = const ImImageHostingConfig(),
    this.displayNameResolver,
    this.onZzzNotification,
    this.onZzzAuthenticationFailed,
  });

  final ImStorageConfig storageConfig;
  final ImAvatarResolver avatarResolver;
  final ImImageHostingConfig imageHostingConfig;
  final ImDisplayNameResolver? displayNameResolver;
  final ZzzNotificationHandler? onZzzNotification;
  final Future<void> Function()? onZzzAuthenticationFailed;

  ImClientRuntime build(ImConnectionProfiles settings) {
    final registrations = <ImRepositoryRegistration>[];
    final noneBotSources = <String, NoneBotSource>{};
    final zzzServerSources = <String, ZzzServerSource>{};

    for (final profile in settings.enabledProfiles) {
      final config = profile.config;
      switch (config.platform) {
        case ImPlatform.mock:
          registrations.add(
            ImRepositoryRegistration(
              id: profile.id,
              label: profile.name,
              repository: MockImRepository(),
            ),
          );
        case ImPlatform.nonebot:
          if (kIsWeb || config.wsEndpoint == null) continue;
          final source = NoneBotSource.connected(
            config: OneBotConfig(
              selfId: config.selfId,
              httpEndpoint: config.httpEndpoint,
              wsEndpoint: config.wsEndpoint,
              wsMode:
                  config.wsMode == WsMode.forward
                      ? OneBotWsMode.forward
                      : OneBotWsMode.reverse,
              accessToken: config.accessToken,
            ),
            avatarResolver: avatarResolver,
          );
          source.storageConfig = storageConfig;
          noneBotSources[profile.id] = source;
          final repository = SourceBackedRepository(source);
          registrations.add(
            ImRepositoryRegistration(
              id: profile.id,
              label: profile.name,
              repository: repository,
              connectionStatus: repository.connectionStatus,
            ),
          );
        case ImPlatform.zzzServer:
          if (config.serverUrl == null || config.serverUrl!.isEmpty) continue;
          final source = ZzzServerSource(
            config: ZzzServerConfig(
              serverUrl: config.serverUrl!,
              authToken: config.accessToken ?? '',
              selfId: config.selfId,
            ),
            avatarResolver: avatarResolver,
            displayNameResolver: displayNameResolver,
            onNotification: onZzzNotification,
            imageHostingUploader:
                imageHostingConfig.enabled
                    ? ImImageHostingUploader(config: imageHostingConfig)
                    : null,
            onAuthenticationFailed: onZzzAuthenticationFailed,
          );
          zzzServerSources[profile.id] = source;
          final repository = SourceBackedRepository(source);
          registrations.add(
            ImRepositoryRegistration(
              id: profile.id,
              label: profile.name,
              repository: repository,
              connectionStatus: repository.connectionStatus,
            ),
          );
      }
    }

    if (registrations.isEmpty) {
      return ImClientRuntime(
        repository: MockImRepository(),
        noneBotSources: const {},
        zzzServerSources: const {},
      );
    }

    final primaryId =
        registrations.any(
              (registration) => registration.id == settings.primaryProfileId,
            )
            ? settings.primaryProfileId
            : registrations.first.id;
    return ImClientRuntime(
      repository: CompositeImRepository(
        registrations: registrations,
        primarySourceId: primaryId,
      ),
      noneBotSources: noneBotSources,
      zzzServerSources: zzzServerSources,
    );
  }
}
