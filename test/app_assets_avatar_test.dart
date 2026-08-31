import 'package:flutter_test/flutter_test.dart';

import 'package:zzzproject/src/assets/app_assets.dart';

void main() {
  test('fallback avatars are stable and varied for smoke accounts', () {
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
    expect(avatars.toSet().length, greaterThanOrEqualTo(5));
    expect(avatars.every(AppAssets.fallbackAvatarPool.contains), isTrue);
  });
}
