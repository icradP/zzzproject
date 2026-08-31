import 'package:flutter_test/flutter_test.dart';

import 'package:zzzproject/src/assets/app_assets.dart';

void main() {
  test('smoke accounts use explicit stable profile art', () {
    const accountIds = [
      'deployment-check',
      'smoke-alice',
      'smoke-bob',
      'codex-pwa-probe',
      'alice',
      'test1',
      'xiaodeng',
    ];

    final avatars = accountIds.map(AppAssets.fallbackAvatarForId).toList();

    expect(
      AppAssets.fallbackAvatarForId('smoke-alice'),
      AppAssets.fallbackAvatarForId('smoke-alice'),
    );
    expect(avatars.toSet(), hasLength(accountIds.length));
    expect(
      AppAssets.fallbackAvatarForId('SMOKE-ALICE'),
      AppAssets.smokeAccountAvatars['smoke-alice'],
    );
    expect(accountIds.every(AppAssets.smokeAccountAvatars.containsKey), isTrue);
    expect(avatars.every(AppAssets.fallbackAvatarPool.contains), isTrue);
  });

  test('ordinary empty profiles retain deterministic fallback art', () {
    final first = AppAssets.fallbackAvatarForId('ordinary-user-42');
    final second = AppAssets.fallbackAvatarForId('ordinary-user-42');

    expect(first, second);
    expect(AppAssets.fallbackAvatarPool, contains(first));
  });
}
