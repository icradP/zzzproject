import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zzzproject/src/im/models/im_models.dart';
import 'package:zzzproject/src/im/widgets/contact_tile.dart';
import 'package:zzzproject/src/im/widgets/im_conversation_avatar.dart';

void main() {
  const user = ImUser(id: 'alice', displayName: 'Alice');

  testWidgets('contact tap opens chat and swipe action opens profile', (
    tester,
  ) async {
    var chatOpened = false;
    var profileOpened = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
          body: ContactTile(
            user: user,
            onTap: () => chatOpened = true,
            onProfile: () => profileOpened = true,
          ),
        ),
      ),
    );

    await tester.tap(find.text('Alice'));
    expect(chatOpened, isTrue);
    expect(profileOpened, isFalse);

    await tester.drag(find.text('Alice'), const Offset(-120, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('profile-alice')));
    expect(profileOpened, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('group without an image composes member avatars', (tester) async {
    const conversation = ImConversation(
      id: 'group-one',
      type: ImConversationType.group,
      title: 'Group one',
      participantIds: ['alice', 'bob', 'carol', 'dave'],
    );
    const members = [
      ImUser(id: 'alice', displayName: 'Alice'),
      ImUser(id: 'bob', displayName: 'Bob'),
      ImUser(id: 'carol', displayName: 'Carol'),
      ImUser(id: 'dave', displayName: 'Dave'),
    ];
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ImConversationAvatar(
            conversation: conversation,
            memberUsers: members,
            size: 52,
          ),
        ),
      ),
    );

    expect(find.byType(GridView), findsOneWidget);
    expect(find.byType(Image), findsNWidgets(4));
    expect(
      tester.getSize(find.byType(ImConversationAvatar)),
      const Size(52, 52),
    );
  });
}
