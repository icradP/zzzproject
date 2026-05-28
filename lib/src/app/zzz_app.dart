import 'package:flutter/material.dart';

import '../../../core/routes/index.dart';
import '../assets/app_assets.dart';
import '../im/adapters/im_message_source.dart';
import '../im/adapters/nonebot/nonebot_models.dart';
import '../im/adapters/nonebot/nonebot_source.dart';
import '../im/adapters/source_repository.dart';
import '../im/data/im_animation_config.dart';
import '../im/data/im_backdrop_config.dart';
import '../im/data/im_connection_config.dart';
import '../im/data/im_storage_config.dart';
import '../im/data/im_interaction_handler.dart';
import '../im/data/im_repository.dart';
import '../im/data/mock_im_repository.dart';
import '../im/im_scope.dart';
import '../theme/zzz_colors.dart';

class ZzzApp extends StatefulWidget {
  const ZzzApp({super.key});

  @override
  State<ZzzApp> createState() => _ZzzAppState();
}

class _ZzzAppState extends State<ZzzApp> {
  ImRepository? _repository;
  Stream<ConnectionStatus>? _connectionStatus;

  @override
  void initState() {
    super.initState();
    _initRepository();
  }

  Future<void> _initRepository() async {
    final config = await ImConnectionConfig.loadOrDefault();
    final storageConfig = await ImStorageConfig.load();
    await ImAnimationConfig.load();
    await ImBackdropConfig.load();
    final repo = _buildRepository(config, storageConfig);
    Stream<ConnectionStatus>? status;
    if (repo is SourceBackedRepository) {
      status = repo.connectionStatus;
    }
    if (mounted) {
      setState(() {
        _repository = repo;
        _connectionStatus = status;
      });
    }
  }

  ImRepository _buildRepository(
    ImConnectionConfig config,
    ImStorageConfig storageConfig,
  ) {
    if (config.isNoneBot && config.wsEndpoint != null) {
      final source = NoneBotSource.connected(
        config: OneBotConfig(
          selfId: config.selfId,
          httpEndpoint: config.httpEndpoint,
          wsEndpoint: config.wsEndpoint,
          wsMode: config.wsMode,
          accessToken: config.accessToken,
        ),
        avatarResolver: _zzzAvatarResolver,
      );
      source.storageConfig = storageConfig;
      return SourceBackedRepository(source);
    }
    return MockImRepository();
  }

  String? _zzzAvatarResolver(String userId) {
    switch (userId) {
      case 'belle':
        return AppAssets.characterBelle;
      case 'wise':
        return AppAssets.characterWise;
      case 'nicole':
        return AppAssets.character('NicoleDemara.png');
      case 'anby':
        return AppAssets.character('AnbyDemara.png');
      case 'fairy':
        return AppAssets.character('temp/Fairy.png');
      default:
        return _randomAvatarForId(userId);
    }
  }

  /// Deterministically picks an avatar from [AppAssets.avatarPool] for [id].
  static String _randomAvatarForId(String id) {
    final hash = id.codeUnits.fold<int>(0, (prev, c) => prev * 31 + c);
    final index = hash.abs() % AppAssets.avatarPool.length;
    return AppAssets.avatarPool[index];
  }

  @override
  void dispose() {
    _repository?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final repo = _repository;
    if (repo == null) {
      return const MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          backgroundColor: Colors.black,
          body: Center(child: CircularProgressIndicator()),
        ),
      );
    }

    return ImScope(
      repository: repo,
      interactions: const NoOpImInteractionHandler(),
      connectionStatus: _connectionStatus,
      child: MaterialApp.router(
        routerConfig: appRouter,
        title: 'ZZZ IM',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          brightness: Brightness.dark,
          fontFamily: 'InpinHongmengti',
          colorScheme: ColorScheme.fromSeed(
            seedColor: ZzzColors.yellow,
            brightness: Brightness.dark,
          ),
          scaffoldBackgroundColor: Colors.black,
        ),
      ),
    );
  }
}
