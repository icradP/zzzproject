import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../../../core/routes/index.dart';
import '../assets/app_assets.dart';
import '../im/adapters/im_message_source.dart';
import '../im/adapters/composite_im_repository.dart';
import '../im/adapters/im_source_registry.dart';
import '../im/adapters/nonebot/napcat_api.dart';
import '../im/adapters/nonebot/nonebot_source_web.dart'
    if (dart.library.io) '../im/adapters/nonebot/nonebot_source.dart';
import '../im/data/im_animation_config.dart';
import '../im/data/im_backdrop_config.dart';
import '../im/data/im_connection_config.dart';
import '../im/data/im_storage_config_web.dart'
    if (dart.library.io) '../im/data/im_storage_config.dart';
import '../im/data/im_interaction_handler.dart';
import '../im/data/im_logger.dart';
import '../im/data/im_notification_service.dart';
import '../im/data/im_media_cache.dart';
import '../im/models/im_models.dart';
import '../im/models/im_source_address.dart';
import '../im/data/im_nsfw_checker.dart';
import '../im/data/im_nsfw_checker_onnx.dart';
import '../im/data/im_nsfw_checker_stub.dart';
import '../im/data/im_nsfw_config.dart';
import '../im/data/im_repository.dart';
import '../im/data/im_push_manager.dart';
import '../im/im_scope.dart';
import '../im/pages/im_web_setup_page.dart';
import '../theme/zzz_colors.dart';

class ZzzApp extends StatefulWidget {
  const ZzzApp({super.key});

  @override
  State<ZzzApp> createState() => _ZzzAppState();
}

class _ZzzAppState extends State<ZzzApp> {
  ImRepository? _repository;
  Stream<ConnectionStatus>? _connectionStatus;
  ImNsfwChecker? _nsfwChecker;
  final _nsfwStateCache = NsfwStateCache();
  bool _needsWebSetup = false;
  ImPushManager _pushManager = NoOpImPushManager();
  ImClientRuntime? _runtime;
  var _repositoryGeneration = 0;

  @override
  void initState() {
    super.initState();
    _initRepository();
    _initNotifications();
  }

  var _notifyPermissionRequested = false;

  void _initNotifications() {
    ImNotificationService.init();
    NoneBotSource.onNewMessage = (convId, sender, text) {
      // Request permission on first incoming message.
      if (!_notifyPermissionRequested) {
        _notifyPermissionRequested = true;
        ImNotificationService.requestPermission();
      }
      // Show notification when backgrounded.
      if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.paused) {
        ImNotificationService.show(
          id: DateTime.now().millisecondsSinceEpoch.remainder(100000),
          title: sender,
          body: text,
        );
      }
    };
  }

  Future<void> _initRepository() async {
    final generation = ++_repositoryGeneration;
    final profiles = await ImConnectionProfiles.load();
    final storageConfig = await ImStorageConfig.load();
    await ImAnimationConfig.load();
    await ImBackdropConfig.load();
    await ImNsfwConfig.load();
    final hasWebServer = profiles.enabledProfiles.any((profile) {
      final config = profile.config;
      if (!config.isZzzServer ||
          config.serverUrl == null ||
          config.serverUrl!.isEmpty) {
        return false;
      }
      // Web clients must use account sessions. This sends installations that
      // still contain the legacy shared-token profile back to the login page.
      return !kIsWeb || config.extra['authMode'] == 'session';
    });
    if (kIsWeb && !hasWebServer) {
      if (mounted) setState(() => _needsWebSetup = true);
      return;
    }
    if (ImNsfwConfig.instance.persistReveal) {
      await _nsfwStateCache.loadRevealed();
    }
    final runtime = ImSourceRegistry(
      storageConfig: storageConfig,
      avatarResolver: _zzzAvatarResolver,
    ).build(profiles);
    final repo = runtime.repository;
    final status = runtime.compositeRepository?.connectionStatus;
    if (!mounted || generation != _repositoryGeneration) {
      repo.dispose();
      return;
    }

    _pushManager.dispose();
    _pushManager = NoOpImPushManager();
    final preferredPushSource =
        runtime.zzzServerSources[profiles.primaryProfileId] ??
        (runtime.zzzServerSources.isEmpty
            ? null
            : runtime.zzzServerSources.values.first);
    if (preferredPushSource != null) {
      _pushManager = ZzzServerPushManager(source: preferredPushSource)..start();
    }
    final fallbackNsfw = StubNsfwChecker();
    _nsfwChecker?.dispose();
    _nsfwChecker = fallbackNsfw;
    final oldRepository = _repository;
    setState(() {
      _runtime = runtime;
      _repository = repo;
      _connectionStatus = status;
      _needsWebSetup = false;
    });
    oldRepository?.dispose();
    unawaited(_initializeNsfwChecker(fallbackNsfw));
  }

  Future<void> _initializeNsfwChecker(ImNsfwChecker fallback) async {
    ImLogger.nsfwInitStart();
    final nsfw = OnnxNsfwChecker();
    await nsfw.initialize();
    if (!mounted || !identical(_nsfwChecker, fallback)) {
      nsfw.dispose();
      return;
    }
    if (!nsfw.isAvailable) {
      nsfw.dispose();
      return;
    }
    ImLogger.nsfwInitOk();
    fallback.dispose();
    setState(() => _nsfwChecker = nsfw);
  }

  Future<void> _applyWebConfig(ImConnectionConfig config) async {
    await ImConnectionProfiles.replacePrimaryZzz(config);
    if (!mounted) return;
    setState(() {
      _needsWebSetup = false;
    });
    await _initRepository();
  }

  /// Interaction handler wired to the active source.
  ImInteractionHandler _buildInteractionHandler(ImRepository repository) =>
      _ZzzImInteractionHandler(
        repository: repository,
        compositeRepository: _runtime?.compositeRepository,
        sources: _runtime?.noneBotSources ?? const {},
      );

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
    _pushManager.dispose();
    _nsfwChecker?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_needsWebSetup) {
      return MaterialApp(
        title: 'ZZZ IM',
        debugShowCheckedModeBanner: false,
        theme: _buildTheme(),
        home: ImWebSetupPage(onConfigured: _applyWebConfig),
      );
    }
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
      interactions: _buildInteractionHandler(repo),
      nsfwChecker: _nsfwChecker!,
      nsfwStateCache: _nsfwStateCache,
      pushManager: _pushManager,
      onConnectionsChanged: _initRepository,
      connectionStatus: _connectionStatus,
      child: MaterialApp.router(
        routerConfig: appRouter,
        title: 'ZZZ IM',
        debugShowCheckedModeBanner: false,
        theme: _buildTheme(),
      ),
    );
  }

  ThemeData _buildTheme() => ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    fontFamily: 'InpinHongmengti',
    colorScheme: ColorScheme.fromSeed(
      seedColor: ZzzColors.yellow,
      brightness: Brightness.dark,
    ),
    scaffoldBackgroundColor: Colors.black,
  );
}

/// Interaction handler that delegates record downloads to the source's
/// media cache (on-demand, triggered by the voice bubble play button).
class _ZzzImInteractionHandler implements ImInteractionHandler {
  _ZzzImInteractionHandler({
    required this.repository,
    required this.sources,
    this.compositeRepository,
  });

  final ImRepository repository;
  final Map<String, NoneBotSource> sources;
  final CompositeImRepository? compositeRepository;
  final Map<String, ImMediaCache> _caches = {};

  NoneBotSource? _sourceFor(String value) {
    final sourceId = ImSourceAddress.sourceIdOf(value);
    if (sourceId != null) return sources[sourceId];
    return sources.length == 1 ? sources.values.first : null;
  }

  ImMediaCache? _getCache(String value) {
    final sourceId = ImSourceAddress.sourceIdOf(value);
    final source = _sourceFor(value);
    final c = source?.client;
    if (c == null) return null;
    final key = sourceId ?? sources.keys.first;
    return _caches.putIfAbsent(key, () => ImMediaCache(client: c));
  }

  @override
  Future<String?> getUserAvatarPath(String userId) async {
    // Try cached first.
    final user = await repository.getUser(userId);
    if (user?.avatarLocalPath != null) return user!.avatarLocalPath;
    if (user?.avatarAssetPath != null) return user!.avatarAssetPath;
    // Not cached — fetch from QQ via OneBot API.
    return _sourceFor(
      userId,
    )?.fetchUserAvatar(ImSourceAddress.localIdOf(userId));
  }

  @override
  Future<ForwardGroup> getForwardMessages(String forwardId) async {
    // 1. Try SQLite cache first — re-parse raw JSON to preserve tree.
    final sourceId = ImSourceAddress.sourceIdOf(forwardId);
    final source = _sourceFor(forwardId);
    if (source == null) return const ForwardGroup();
    final localForwardId = ImSourceAddress.localIdOf(forwardId);
    final cachedRaw = await source.loadForwardRaw(localForwardId);
    if (cachedRaw != null) {
      try {
        final data = jsonDecode(cachedRaw) as Map<String, dynamic>;
        final group = NapCatApi.parseResponse(data);
        ImLogger.logRaw(
          ImLogger.event,
          'forward from cache: ${group.messages.length} msgs + ${group.children.length} nested',
        );
        return _scopeForwardGroup(sourceId, group);
      } catch (_) {}
    }

    // 2. Fetch via NapCat API.
    final client = source.client;
    if (client == null) return const ForwardGroup();
    final api = NapCatApi(client);
    final group = await api.getForwardGroup(localForwardId);
    ImLogger.logRaw(
      ImLogger.event,
      'forward api: ${group.messages.length} msgs + ${group.children.length} nested',
    );

    // 3. Download images & persist raw response.
    final flat = NapCatApi.flattenGroup(group);
    await _cacheForwardImages(flat, source);
    if (flat.isNotEmpty && api.lastRawData != null) {
      await source.saveForwardRaw(localForwardId, jsonEncode(api.lastRawData));
    }
    return _scopeForwardGroup(sourceId, group);
  }

  ForwardGroup _scopeForwardGroup(String? sourceId, ForwardGroup group) {
    if (sourceId == null || compositeRepository == null) return group;
    return ForwardGroup(
      title: group.title,
      senderName: group.senderName,
      messages: group.messages
          .map(
            (message) => compositeRepository!.scopeMessage(sourceId, message),
          )
          .toList(growable: false),
      children: group.children
          .map((child) => _scopeForwardGroup(sourceId, child))
          .toList(growable: false),
    );
  }

  Future<void> _cacheForwardImages(
    List<ImMessage> msgs,
    NoneBotSource source,
  ) async {
    final client = source.client;
    if (client == null) return;
    for (final msg in msgs) {
      final segs = msg.segments;
      if (segs == null) continue;
      for (final seg in segs) {
        if (seg.type != 'image') continue;
        final url = seg.data['url'] as String?;
        final fileId = seg.data['file'] as String?;
        if (url == null && fileId == null) continue;
        try {
          // Download to temp dir for local display + NSFW.
          final tmp = File(
            '${Directory.systemTemp.path}/zzz_fw_${url.hashCode}.jpg',
          );
          if (!tmp.existsSync()) {
            if (url != null && url.isNotEmpty) {
              final http = HttpClient();
              final req = await http.getUrl(Uri.parse(url));
              final res = await req.close();
              await res.pipe(tmp.openWrite());
              http.close();
            } else if (fileId != null && fileId.isNotEmpty) {
              final img = await client.getImage(file: fileId);
              if (img.file != null) {
                final src = File(img.file!);
                if (src.existsSync()) await src.copy(tmp.path);
              }
            }
          }
          seg.data['_localPath'] = tmp.path;
        } catch (_) {}
      }
    }
  }

  @override
  Future<String?> downloadRecord({required String fileId, String? url}) async {
    final cache = _getCache(fileId);
    if (cache == null) return null;
    try {
      final cached = await cache.downloadRecord(
        fileId: ImSourceAddress.localIdOf(fileId),
        url: url,
      );
      return cached.localPath;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> sendMedia({
    required ImConversation conversation,
    required ImMediaUpload upload,
  }) async {
    await repository.sendMediaMessage(
      conversationId: conversation.id,
      upload: upload,
    );
  }

  @override
  void onComposeNewChat() {}
  @override
  void onConversationClosed() {}
  @override
  void onConversationOpened(ImConversation conversation) {}
  @override
  void onMessageLongPress(ImMessage message) {}
  @override
  void onSearchQueryChanged(String query) {}
  @override
  Future<void> onSendMessage({
    required ImConversation conversation,
    required String text,
  }) async {}
  @override
  void onUserAvatarTap(ImUser user) {}
}
