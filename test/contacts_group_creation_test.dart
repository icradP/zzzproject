import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zzzproject/src/im/data/im_interaction_handler.dart';
import 'package:zzzproject/src/im/data/im_nsfw_checker.dart';
import 'package:zzzproject/src/im/data/im_nsfw_checker_stub.dart';
import 'package:zzzproject/src/im/data/im_push_manager.dart';
import 'package:zzzproject/src/im/data/mock_im_repository.dart';
import 'package:zzzproject/src/im/im_scope.dart';
import 'package:zzzproject/src/im/models/im_models.dart';
import 'package:zzzproject/src/im/widgets/contacts_panel.dart';
import 'package:zzzproject/src/im/widgets/im_bot_badge.dart';
import 'package:zzzproject/src/widgets/zzz_widgets.dart';

void main() {
  testWidgets('shows Fairy as a suggested bot and sends a friend request', (
    tester,
  ) async {
    final repository = _SuggestedContactRepository();
    addTearDown(repository.dispose);

    await tester.pumpWidget(
      ImScope(
        repository: repository,
        interactions: const NoOpImInteractionHandler(),
        nsfwChecker: StubNsfwChecker(),
        nsfwStateCache: NsfwStateCache(),
        pushManager: NoOpImPushManager(),
        onConnectionsChanged: () async {},
        child: MaterialApp(
          home: Scaffold(body: ContactsPanel(onConversationSelected: (_) {})),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('suggested-fairy')), findsOneWidget);
    expect(find.text('AI assistant'), findsOneWidget);
    expect(find.byType(ImBotBadge), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('add-suggested-fairy')));
    await tester.pumpAndSettle();

    expect(repository.requestedUserId, 'fairy');
    expect(find.byTooltip('Request pending'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('does not duplicate a suggested bot already in contacts', (
    tester,
  ) async {
    final repository = _SuggestedContactRepository(fairyIsFriend: true);
    addTearDown(repository.dispose);

    await tester.pumpWidget(
      ImScope(
        repository: repository,
        interactions: const NoOpImInteractionHandler(),
        nsfwChecker: StubNsfwChecker(),
        nsfwStateCache: NsfwStateCache(),
        pushManager: NoOpImPushManager(),
        onConnectionsChanged: () async {},
        child: MaterialApp(
          home: Scaffold(body: ContactsPanel(onConversationSelected: (_) {})),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('suggested-fairy')), findsNothing);
    expect(find.text('Fairy'), findsOneWidget);
    expect(find.byType(ImBotBadge), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('creates a group with selected contacts', (tester) async {
    tester.view
      ..physicalSize = const Size(375, 667)
      ..devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    ImConversation? selectedConversation;
    await tester.pumpWidget(
      ImScope(
        repository: MockImRepository(),
        interactions: const NoOpImInteractionHandler(),
        nsfwChecker: StubNsfwChecker(),
        nsfwStateCache: NsfwStateCache(),
        pushManager: NoOpImPushManager(),
        onConnectionsChanged: () async {},
        child: MaterialApp(
          home: Scaffold(
            body: ContactsPanel(
              onConversationSelected:
                  (conversation) => selectedConversation = conversation,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('群聊'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Create group'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('create-group-panel')), findsOneWidget);
    expect(find.byType(ZzzModalPanel), findsOneWidget);
    expect(find.byType(ZzzExpandablePanel), findsOneWidget);
    expect(find.byType(ZzzExpandableSection), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);

    final nameInput = find.descendant(
      of: find.byKey(const ValueKey('create-group-name')),
      matching: find.byType(TextField),
    );
    await tester.enterText(nameInput, 'Weekend plans');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('create-group-next')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('create-group-members-step')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('create-group-member-belle')));
    await tester.pumpAndSettle();
    expect(find.text('1 selected'), findsWidgets);
    await tester.tap(find.text('Selected members'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('selected-group-members')),
      findsOneWidget,
    );

    final memberSearch = find.descendant(
      of: find.byKey(const ValueKey('create-group-member-search')),
      matching: find.byType(TextField),
    );
    await tester.enterText(memberSearch, 'missing contact');
    await tester.pumpAndSettle();
    expect(find.text('No matching contacts'), findsOneWidget);
    await tester.enterText(memberSearch, '');
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('create-group-next')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('create-group-review-step')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('create-group-avatar-preview')),
      findsOneWidget,
    );
    expect(find.text('Weekend plans'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('create-group-submit')));
    await tester.pumpAndSettle();

    expect(selectedConversation?.title, 'Weekend plans');
    expect(selectedConversation?.participantIds, containsAll(['me', 'belle']));
    expect(tester.takeException(), isNull);
  });

  testWidgets('group panel fits a compact mobile viewport', (tester) async {
    tester.view
      ..physicalSize = const Size(320, 568)
      ..devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      ImScope(
        repository: MockImRepository(),
        interactions: const NoOpImInteractionHandler(),
        nsfwChecker: StubNsfwChecker(),
        nsfwStateCache: NsfwStateCache(),
        pushManager: NoOpImPushManager(),
        onConnectionsChanged: () async {},
        child: MaterialApp(
          home: Scaffold(body: ContactsPanel(onConversationSelected: (_) {})),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('群聊'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Create group'));
    await tester.pumpAndSettle();

    final panelRect = tester.getRect(
      find.byKey(const ValueKey('create-group-panel')),
    );
    expect(
      find.byKey(const ValueKey('create-group-compact-layout')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('create-group-wide-layout')),
      findsNothing,
    );
    expect(panelRect.left, greaterThanOrEqualTo(0));
    expect(panelRect.right, lessThanOrEqualTo(320));
    expect(panelRect.top, greaterThanOrEqualTo(0));
    expect(panelRect.bottom, lessThanOrEqualTo(568));
    expect(tester.takeException(), isNull);
  });

  testWidgets('group panel uses a two-column workspace on desktop', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(1024, 768)
      ..devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      ImScope(
        repository: MockImRepository(),
        interactions: const NoOpImInteractionHandler(),
        nsfwChecker: StubNsfwChecker(),
        nsfwStateCache: NsfwStateCache(),
        pushManager: NoOpImPushManager(),
        onConnectionsChanged: () async {},
        child: MaterialApp(
          home: Scaffold(body: ContactsPanel(onConversationSelected: (_) {})),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('群聊'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Create group'));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('create-group-wide-layout')),
      findsOneWidget,
    );
    expect(find.byType(ZzzExpandablePanel), findsNWidgets(2));
    expect(
      find.byKey(const ValueKey('create-group-compact-layout')),
      findsNothing,
    );

    final expandedHeight =
        tester
            .getRect(find.byKey(const ValueKey('zzz-modal-panel-surface')))
            .height;
    await tester.tap(find.byKey(const ValueKey('zzz-modal-panel-collapse')));
    await tester.pumpAndSettle();
    final collapsedHeight =
        tester
            .getRect(find.byKey(const ValueKey('zzz-modal-panel-surface')))
            .height;
    expect(collapsedHeight, lessThan(expandedHeight));
    expect(
      find.byKey(const ValueKey('create-group-member-browser')),
      findsNothing,
    );
    expect(find.widgetWithText(FilledButton, 'Create'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

class _SuggestedContactRepository extends MockImRepository {
  _SuggestedContactRepository({this.fairyIsFriend = false});

  final bool fairyIsFriend;
  String? requestedUserId;

  @override
  bool get supportsFriendManagement => true;

  Future<List<ImUser>> _contacts() async {
    final users = await super.getUsers();
    return users
        .where((user) => fairyIsFriend || user.id != 'fairy')
        .map(
          (user) =>
              user.id == 'fairy'
                  ? user.copyWith(
                    isBot: true,
                    relationship: ImRelationship.friend,
                  )
                  : user,
        )
        .toList(growable: false);
  }

  @override
  Future<List<ImUser>> getUsers() => _contacts();

  @override
  Stream<List<ImUser>> watchUsers() async* {
    yield await _contacts();
  }

  @override
  Future<List<ImUser>> getSuggestedContacts() async {
    final fairy = await getUser('fairy');
    if (fairy == null) return const [];
    return [
      fairy.copyWith(
        isBot: true,
        relationship:
            requestedUserId == null
                ? ImRelationship.none
                : ImRelationship.outgoing,
      ),
    ];
  }

  @override
  Future<List<ImFriendRequest>> getFriendRequests() async => const [];

  @override
  Stream<List<ImFriendRequest>> watchFriendRequests() => Stream.value(const []);

  @override
  Future<void> sendFriendRequest({
    required String userId,
    String comment = '',
  }) async {
    requestedUserId = userId;
  }
}
