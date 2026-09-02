import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zzzproject/src/im/data/mock_im_repository.dart';
import 'package:zzzproject/src/im/models/im_models.dart';
import 'package:zzzproject/src/im/widgets/im_profile_card_panel.dart';
import 'package:zzzproject/src/im/widgets/im_bot_badge.dart';
import 'package:zzzproject/src/widgets/zzz_widgets.dart';

void main() {
  for (final size in [const Size(390, 844), const Size(1100, 800)]) {
    testWidgets('profile card fits ${size.width.toInt()}px viewport', (
      tester,
    ) async {
      tester.view
        ..physicalSize = size
        ..devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      final repository = _ProfileRepository(isBot: true);
      addTearDown(repository.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder:
                (context) => Scaffold(
                  body: Center(
                    child: IconButton(
                      key: const ValueKey('open-profile-card'),
                      onPressed:
                          () => showZzzModalPanel<void>(
                            context: context,
                            builder:
                                (_) => ImProfileCardPanel(
                                  userId: 'profile-target',
                                  groupId: 'group_test',
                                  repository: repository,
                                  onMessage: (_) async {},
                                ),
                          ),
                      icon: const Icon(Icons.badge_outlined),
                    ),
                  ),
                ),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('open-profile-card')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.text('Anby Demara'), findsOneWidget);
      expect(find.text('Hollow Expert'), findsOneWidget);
      expect(find.text('Random Play'), findsOneWidget);
      expect(find.text('Message'), findsOneWidget);
      expect(find.text('Block'), findsOneWidget);
      expect(find.byType(ImBotBadge), findsOneWidget);
      final rect = tester.getRect(find.byType(ZzzModalPanel));
      expect(rect.left, greaterThanOrEqualTo(0));
      expect(rect.right, lessThanOrEqualTo(size.width));
      expect(rect.top, greaterThanOrEqualTo(0));
      expect(rect.bottom, lessThanOrEqualTo(size.height));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('hides direct messaging when the profile owner blocked me', (
    tester,
  ) async {
    final repository = _ProfileRepository(
      relationship: ImRelationship.blockedBy,
    );
    addTearDown(repository.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder:
              (context) => Scaffold(
                body: TextButton(
                  onPressed:
                      () => showZzzModalPanel<void>(
                        context: context,
                        builder:
                            (_) => ImProfileCardPanel(
                              userId: 'profile-target',
                              repository: repository,
                              onMessage: (_) async {},
                            ),
                      ),
                  child: const Text('Open'),
                ),
              ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('Message'), findsNothing);
    expect(find.text('Block'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('hidden account ID is omitted and avatar is not upscaled', (
    tester,
  ) async {
    final repository = _ProfileRepository(showAccountId: false);
    addTearDown(repository.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder:
              (context) => Scaffold(
                body: TextButton(
                  onPressed:
                      () => showZzzModalPanel<void>(
                        context: context,
                        builder:
                            (_) => ImProfileCardPanel(
                              userId: 'profile-target',
                              repository: repository,
                            ),
                      ),
                  child: const Text('Open hidden profile'),
                ),
              ),
        ),
      ),
    );
    await tester.tap(find.text('Open hidden profile'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('profile-target'), findsNothing);
    final avatar = tester
        .widgetList<Image>(find.byType(Image))
        .firstWhere((image) => image.fit == BoxFit.scaleDown);
    expect(avatar.fit, BoxFit.scaleDown);
  });
}

class _ProfileRepository extends MockImRepository {
  _ProfileRepository({
    this.relationship = ImRelationship.friend,
    this.isBot = false,
    this.showAccountId = true,
  });

  final ImRelationship relationship;
  final bool isBot;
  final bool showAccountId;

  @override
  Future<ImUser?> getProfileCard(String userId, {String? groupId}) async {
    return ImUser(
      id: userId,
      displayName: 'Anby Demara',
      bio: 'Reliable proxy with a taste for movies.',
      isOnline: true,
      isBot: isBot,
      relationship: relationship,
      showAccountId: showAccountId,
      titles: const [
        ImUserTitle(
          id: 'title-one',
          text: 'Hollow Expert',
          style: 'aurora',
          scopeType: 'group',
          scopeId: 'group_test',
          grantedBy: 'owner',
        ),
      ],
      mutualGroups: const [
        ImMutualGroup(id: 'group_test', name: 'Random Play', memberCount: 12),
      ],
    );
  }
}
