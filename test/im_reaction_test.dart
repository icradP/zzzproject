import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zzzproject/src/im/data/mock_im_repository.dart';
import 'package:zzzproject/src/im/models/im_models.dart';
import 'package:zzzproject/src/im/widgets/im_chat_room_view/im_reaction_chips.dart';

void main() {
  test('mock repository adds and removes the current user reaction', () async {
    final repository = MockImRepository();
    final messages = await repository.watchMessages('dm_belle_me').first;
    final target = messages.first;

    final added = await repository.reactToMessage(
      conversationId: target.conversationId,
      messageId: target.id,
      emojiId: '76',
    );
    expect(added.single.emojiId, '76');
    expect(added.single.count, 1);
    expect(added.single.reactedByMe, isTrue);

    final removed = await repository.reactToMessage(
      conversationId: target.conversationId,
      messageId: target.id,
      emojiId: '76',
      remove: true,
    );
    expect(removed, isEmpty);
  });

  testWidgets('reaction chips expose a tap target and selected state', (
    tester,
  ) async {
    ImReaction? tapped;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ImReactionChips(
            reactions: const [
              ImReaction(emojiId: '76', count: 2, reactedByMe: true),
            ],
            isMine: false,
            onTap: (reaction) => tapped = reaction,
          ),
        ),
      ),
    );
    expect(find.byKey(const ValueKey('reaction-chip-76')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('reaction-chip-76')));
    expect(tapped?.reactedByMe, isTrue);
  });
}
