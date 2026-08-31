import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zzzproject/src/assets/app_assets.dart';
import 'package:zzzproject/src/im/models/im_models.dart';
import 'package:zzzproject/src/im/widgets/im_chat_room_view.dart';
import 'package:zzzproject/src/im/widgets/im_chat_room_view/im_member_grid.dart';

void main() {
  testWidgets('group members expand below the chat header', (tester) async {
    tester.view
      ..physicalSize = const Size(360, 640)
      ..devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final participantIds = List.generate(40, (index) => 'member-$index');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ImChatRoomView(
            conversation: ImConversation(
              id: 'group-layout-test',
              type: ImConversationType.group,
              title: 'Layout test',
              participantIds: participantIds,
            ),
            messages: const [],
            onSend: (_) async {},
            resolveUserName: (userId) async => userId,
            resolveUserAvatar:
                (_) async => const AssetImage(AppAssets.characterWise),
          ),
        ),
      ),
    );

    expect(find.byType(ImMemberGrid), findsOneWidget);
    expect(
      tester.getSize(find.byKey(const ValueKey('group-member-reveal'))).height,
      0,
    );

    await tester.tap(find.byIcon(Icons.expand_more_rounded));
    await tester.pumpAndSettle();

    final memberPanel = tester.getRect(find.byType(ImMemberGrid));
    final emptyMessage = tester.getRect(
      find.text('Say hello to start the chat.'),
    );
    expect(memberPanel.top, lessThan(emptyMessage.top));
    expect(memberPanel.height, lessThanOrEqualTo(220));
    expect(tester.takeException(), isNull);
  });
}
