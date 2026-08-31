import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zzzproject/src/im/data/im_connection_config.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('loads and persists multiple connection profiles', () async {
    const profiles = ImConnectionProfiles(
      profiles: [
        ImConnectionProfile(
          id: 'primary',
          name: 'Private IM',
          config: ImConnectionConfig(
            platform: ImPlatform.zzzServer,
            serverUrl: 'wss://im.example.test/ws',
            selfId: 'alice',
            accessToken: 'server-token',
          ),
        ),
        ImConnectionProfile(
          id: 'qq',
          name: 'QQ account',
          enabled: false,
          config: ImConnectionConfig(
            platform: ImPlatform.nonebot,
            wsEndpoint: 'ws://127.0.0.1:3001',
            selfId: '10001',
          ),
        ),
      ],
      primaryProfileId: 'primary',
    );

    await profiles.save();
    final loaded = await ImConnectionProfiles.load();

    expect(loaded.profiles, hasLength(2));
    expect(loaded.primaryProfile?.name, 'Private IM');
    expect(loaded.enabledProfiles.map((profile) => profile.id), ['primary']);
    expect(loaded.profiles.last.config.platform, ImPlatform.nonebot);
  });

  test('migrates the legacy single connection config', () async {
    final legacy = const ImConnectionConfig(
      platform: ImPlatform.nonebot,
      wsEndpoint: 'ws://127.0.0.1:3001',
      selfId: '10001',
      accessToken: 'qq-token',
    );
    SharedPreferences.setMockInitialValues({
      'im_connection_config': jsonEncode(legacy.toJson()),
    });

    final migrated = await ImConnectionProfiles.load();

    expect(migrated.profiles, hasLength(1));
    expect(migrated.primaryProfile?.config.platform, ImPlatform.nonebot);
    expect(migrated.primaryProfile?.config.accessToken, 'qq-token');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('im_connection_profiles_v1'), isNotNull);
  });

  test('web sign-in updates only the primary ZZZ profile', () async {
    const existing = ImConnectionProfiles(
      profiles: [
        ImConnectionProfile(
          id: 'qq',
          name: 'Work QQ',
          config: ImConnectionConfig(platform: ImPlatform.nonebot),
        ),
      ],
      primaryProfileId: 'qq',
    );
    await existing.save();

    final updated = await ImConnectionProfiles.replacePrimaryZzz(
      const ImConnectionConfig(
        platform: ImPlatform.zzzServer,
        serverUrl: 'wss://im.example.test/ws',
        selfId: 'alice',
        accessToken: 'token',
      ),
    );

    expect(updated.profiles, hasLength(2));
    expect(updated.profiles.any((profile) => profile.id == 'qq'), isTrue);
    expect(updated.primaryProfile?.config.platform, ImPlatform.zzzServer);
  });

  test('web sign-out clears only the primary ZZZ account session', () async {
    const existing = ImConnectionProfiles(
      profiles: [
        ImConnectionProfile(
          id: 'zzz',
          name: 'Private IM',
          config: ImConnectionConfig(
            platform: ImPlatform.zzzServer,
            serverUrl: 'wss://im.example.test/ws',
            selfId: 'alice',
            accessToken: 'session-token',
            extra: {'authMode': 'session', 'theme': 'dark'},
          ),
        ),
        ImConnectionProfile(
          id: 'qq',
          name: 'Work QQ',
          config: ImConnectionConfig(
            platform: ImPlatform.nonebot,
            accessToken: 'qq-token',
          ),
        ),
      ],
      primaryProfileId: 'zzz',
    );
    await existing.save();

    await ImConnectionProfiles.clearPrimaryZzzSession();
    final updated = await ImConnectionProfiles.load();
    final zzz = updated.profiles.firstWhere((profile) => profile.id == 'zzz');
    final qq = updated.profiles.firstWhere((profile) => profile.id == 'qq');

    expect(zzz.config.serverUrl, 'wss://im.example.test/ws');
    expect(zzz.config.selfId, isEmpty);
    expect(zzz.config.accessToken, isNull);
    expect(zzz.config.extra, {'theme': 'dark'});
    expect(qq.config.accessToken, 'qq-token');
  });
}
