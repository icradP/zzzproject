import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zzzproject/src/im/data/mock_im_repository.dart';
import 'package:zzzproject/src/im/models/im_models.dart';
import 'package:zzzproject/src/im/widgets/im_group_details_panel.dart';
import 'package:zzzproject/src/widgets/zzz_widgets.dart';

void main() {
  testWidgets('owner can invite and remove members through ZZZ panels', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(320, 640)
      ..devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final repository = MockImRepository();
    addTearDown(repository.dispose);
    final conversation = await repository.getConversation(
      'group_cunning_hares',
    );

    await _pumpLauncher(tester, repository, conversation!);
    await tester.tap(find.byKey(const ValueKey('open-group-management')));
    await tester.pumpAndSettle();

    expect(find.byType(ZzzModalPanel), findsOneWidget);
    expect(find.text('Owner'), findsOneWidget);
    expect(find.text('Member'), findsNWidgets(3));
    expect(find.byKey(const ValueKey('group-leave')), findsNothing);

    await tester.tap(find.byTooltip('Invite members'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('group-invite-tab')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('group-invite-user-wise')));
    await tester.pump();
    expect(find.text('Invite (1)'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('group-invite-submit')));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Members'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('group-member-wise')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('group-member-actions-wise')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove from group'));
    await tester.pumpAndSettle();
    expect(find.byType(ZzzModalPanel), findsNWidgets(2));
    await tester.tap(find.byKey(const ValueKey('group-confirm-remove')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('group-member-wise')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final size in [const Size(220, 520), const Size(320, 568)]) {
    testWidgets('group management fits ${size.width.toInt()}px viewport', (
      tester,
    ) async {
      tester.view
        ..physicalSize = size
        ..devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      final repository = MockImRepository();
      addTearDown(repository.dispose);
      final conversation = await repository.getConversation(
        'group_cunning_hares',
      );
      await _pumpLauncher(tester, repository, conversation!);
      await tester.tap(find.byKey(const ValueKey('open-group-management')));
      await tester.pumpAndSettle();

      final rect = tester.getRect(
        find.byKey(const ValueKey('group-details-panel')),
      );
      expect(rect.left, greaterThanOrEqualTo(0));
      expect(rect.right, lessThanOrEqualTo(size.width));
      expect(rect.top, greaterThanOrEqualTo(0));
      expect(rect.bottom, lessThanOrEqualTo(size.height));
      await tester.tap(find.byTooltip('Invite members'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('group-invite-tab')), findsOneWidget);
      await tester.tap(find.byTooltip('Group settings'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('group-settings-tab')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('member leaves through a nested confirmation panel', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(320, 568)
      ..devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final repository = _MemberGroupRepository();
    addTearDown(repository.dispose);
    final conversation = await repository.getConversation(
      'group_cunning_hares',
    );
    var left = false;
    await _pumpLauncher(
      tester,
      repository,
      conversation!,
      onLeft: () => left = true,
    );
    await tester.tap(find.byKey(const ValueKey('open-group-management')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('group-leave')));
    await tester.pumpAndSettle();
    expect(find.byType(ZzzModalPanel), findsNWidgets(2));
    await tester.tap(find.byKey(const ValueKey('group-confirm-leave')));
    await tester.pumpAndSettle();

    expect(repository.leftGroup, isTrue);
    expect(left, isTrue);
    expect(find.byKey(const ValueKey('group-details-panel')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('owner edits settings and promotes a member', (tester) async {
    tester.view
      ..physicalSize = const Size(800, 760)
      ..devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final repository = MockImRepository();
    addTearDown(repository.dispose);
    final conversation = await repository.getConversation(
      'group_cunning_hares',
    );
    await _pumpLauncher(tester, repository, conversation!);
    await tester.tap(find.byKey(const ValueKey('open-group-management')));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Group settings'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('group-profile-settings')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('group-moderation-settings')),
      findsOneWidget,
    );
    await tester.enterText(
      find.byKey(const ValueKey('group-name-input')),
      'Commission Board',
    );
    await tester.tap(find.byKey(const ValueKey('group-settings-save')));
    await tester.pumpAndSettle();
    var details = await repository.getGroupDetails('group_cunning_hares');
    expect(details.conversation.title, 'Commission Board');

    await tester.tap(find.byTooltip('Announcements'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('group-announcement-input')),
      'Meet at Random Play.',
    );
    await tester.tap(find.byKey(const ValueKey('group-announcement-save')));
    await tester.pumpAndSettle();
    details = await repository.getGroupDetails('group_cunning_hares');
    expect(details.announcements, hasLength(1));
    expect(details.announcements.single.content, 'Meet at Random Play.');

    await tester.tap(find.byTooltip('Group settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('group-mute-all')));
    await tester.pumpAndSettle();
    details = await repository.getGroupDetails('group_cunning_hares');
    expect(details.muteAll, isTrue);

    await tester.tap(find.byTooltip('Members'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('group-member-actions-nicole')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Make administrator'));
    await tester.pumpAndSettle();
    details = await repository.getGroupDetails('group_cunning_hares');
    expect(
      details.members.singleWhere((m) => m.user.id == 'nicole').role,
      ImGroupRole.admin,
    );
    expect(tester.takeException(), isNull);
  });
}

Future<void> _pumpLauncher(
  WidgetTester tester,
  MockImRepository repository,
  ImConversation conversation, {
  VoidCallback? onLeft,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder:
            (context) => Scaffold(
              body: Center(
                child: IconButton(
                  key: const ValueKey('open-group-management'),
                  onPressed:
                      () => showZzzModalPanel<void>(
                        context: context,
                        builder:
                            (_) => ImGroupDetailsPanel(
                              conversation: conversation,
                              repository: repository,
                              onLeft: onLeft ?? () {},
                            ),
                      ),
                  icon: const Icon(Icons.manage_accounts_outlined),
                ),
              ),
            ),
      ),
    ),
  );
}

class _MemberGroupRepository extends MockImRepository {
  bool leftGroup = false;

  @override
  Future<ImGroupDetails> getGroupDetails(String groupId) async {
    final details = await super.getGroupDetails(groupId);
    return ImGroupDetails(
      conversation: details.conversation,
      members: details.members,
      currentUserId: 'belle',
      supportsInvites: false,
      supportsMemberRemoval: false,
      canLeave: true,
    );
  }

  @override
  Future<void> leaveGroup(String groupId) async {
    leftGroup = true;
    await super.leaveGroup(groupId);
  }
}
