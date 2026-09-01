import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onebot_flutter/onebot_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zzzproject/src/assets/app_assets.dart';
import 'package:zzzproject/src/im/data/im_interaction_handler.dart';
import 'package:zzzproject/src/im/data/im_nsfw_checker.dart';
import 'package:zzzproject/src/im/data/im_nsfw_checker_stub.dart';
import 'package:zzzproject/src/im/data/im_push_manager.dart';
import 'package:zzzproject/src/im/data/im_release_notes.dart';
import 'package:zzzproject/src/im/data/im_sticker_catalog.dart';
import 'package:zzzproject/src/im/data/mock_im_repository.dart';
import 'package:zzzproject/src/im/im_scope.dart';
import 'package:zzzproject/src/im/models/im_models.dart';
import 'package:zzzproject/src/im/widgets/im_chat_room_view.dart';
import 'package:zzzproject/src/im/widgets/im_chat_room_view/im_message_bubble.dart';
import 'package:zzzproject/src/im/widgets/im_release_notes_panel.dart';
import 'package:zzzproject/src/im/widgets/im_source_badge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('release notes current version matches pubspec', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    expect(
      pubspec,
      contains('version: ${ImReleaseNotes.currentVersion}+'),
    );
    expect(ImReleaseNotes.releases.first.version, ImReleaseNotes.currentVersion);
  });

  test('dismissing release notes is scoped to the current version', () async {
    SharedPreferences.setMockInitialValues({});
    expect(await ImReleaseNotes.shouldShowCurrent(), isTrue);
    await ImReleaseNotes.dismissCurrent();
    expect(await ImReleaseNotes.shouldShowCurrent(), isFalse);
  });

  test('sticker catalog resolves only exact versioned references', () {
    const reference = ImStickerReference(
      packId: 'zzz-core',
      assetId: 'corin-01',
      version: 1,
    );
    final segment = OneBotMessageSegment(
      type: ImStickerCatalog.segmentType,
      data: reference.toSegmentData(),
    );
    expect(ImStickerCatalog.referenceFromSegment(segment), reference);
    expect(ImStickerCatalog.resolve(reference)?.assetPath, AppAssets.stickerCorin);
    expect(
      ImStickerCatalog.resolve(
        const ImStickerReference(
          packId: 'zzz-core',
          assetId: 'corin-01',
          version: 2,
        ),
      ),
      isNull,
    );
  });

  testWidgets('release notes gate can suppress the current version', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    ImReleaseNotesGate.resetSession();
    await tester.pumpWidget(
      const MaterialApp(
        home: ImReleaseNotesGate(
          offerDuringTests: true,
          child: Scaffold(body: Text('Inbox')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('release-notes-current')), findsOneWidget);
    await tester.tap(find.text('Do not show again'));
    await tester.pumpAndSettle();
    expect(await ImReleaseNotes.shouldShowCurrent(), isFalse);
  });

  testWidgets('composer sends a stable sticker reference', (tester) async {
    tester.view
      ..physicalSize = const Size(420, 760)
      ..devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    SharedPreferences.setMockInitialValues({});
    final repository = MockImRepository();
    ImStickerReference? sent;
    final conversation = (await repository.getConversation('dm_belle_me'))!;

    await tester.pumpWidget(
      ImScope(
        repository: repository,
        interactions: const NoOpImInteractionHandler(),
        nsfwChecker: StubNsfwChecker(),
        nsfwStateCache: NsfwStateCache(),
        pushManager: NoOpImPushManager(),
        onConnectionsChanged: () async {},
        child: MaterialApp(
          home: Scaffold(
            body: ImChatRoomView(
              conversation: conversation,
              messages: const [],
              onSend: (_) async {},
              onSticker: (sticker) async {
                sent = sticker;
              },
              resolveUserName: (_) async => 'User',
              resolveUserAvatar:
                  (_) async => const AssetImage(AppAssets.characterBelle),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('toggle-sticker-panel')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('sticker-panel')), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('sticker-zzz-core-corin-01-1')),
    );
    await tester.pumpAndSettle();
    expect(
      sent,
      const ImStickerReference(
        packId: 'zzz-core',
        assetId: 'corin-01',
        version: 1,
      ),
    );
  });

  testWidgets('message bubble renders bundled sticker and compact source icon', (
    tester,
  ) async {
    const reference = ImStickerReference(
      packId: 'zzz-core',
      assetId: 'ellen-01',
      version: 1,
    );
    final message = ImMessage(
      id: 'sticker-1',
      conversationId: 'dm',
      senderId: 'me',
      text: '[表情]',
      sentAt: DateTime(2026),
      kind: ImMessageKind.face,
      isMine: true,
      segments: [
        OneBotMessageSegment(
          type: ImStickerCatalog.segmentType,
          data: reference.toSegmentData(),
        ),
      ],
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              const ImSourceBadge(sourceLabel: 'ZZZ Server'),
              ImMessageBubble(
                message: message,
                senderName: 'Me',
                avatar: const AssetImage(AppAssets.characterBelle),
                showSenderName: false,
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.bySemanticsLabel('Source: ZZZ Server'), findsOneWidget);
    expect(find.bySemanticsLabel('Sticker: Ellen'), findsOneWidget);
    expect(find.text('ZZZ Server'), findsNothing);
  });
}
