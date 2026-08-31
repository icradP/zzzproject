import 'package:flutter_test/flutter_test.dart';
import 'package:zzzproject/src/im/adapters/composite_im_repository.dart';
import 'package:zzzproject/src/im/data/mock_im_repository.dart';
import 'package:zzzproject/src/im/models/im_source_address.dart';

void main() {
  test(
    'namespaces overlapping identities and conversations by source',
    () async {
      final repository = CompositeImRepository(
        registrations: [
          ImRepositoryRegistration(
            id: 'zzz',
            label: 'ZZZ Server',
            repository: MockImRepository(),
          ),
          ImRepositoryRegistration(
            id: 'qq',
            label: 'QQ',
            repository: MockImRepository(),
          ),
        ],
        primarySourceId: 'zzz',
      );
      addTearDown(repository.dispose);

      final conversations = await repository.watchConversations().firstWhere(
        (value) => value.length == 10,
      );

      expect(conversations.map((conversation) => conversation.id).toSet(), {
        'zzz::dm_belle_me',
        'zzz::dm_me_wise',
        'zzz::group_cunning_hares',
        'zzz::dm_me_nicole',
        'zzz::dm_fairy_me',
        'qq::dm_belle_me',
        'qq::dm_me_wise',
        'qq::group_cunning_hares',
        'qq::dm_me_nicole',
        'qq::dm_fairy_me',
      });
      expect(
        conversations
            .firstWhere((conversation) => conversation.id.startsWith('qq::'))
            .sourceLabel,
        'QQ',
      );

      final qqBelle = await repository.getUser('qq::belle');
      expect(qqBelle?.id, 'qq::belle');
      expect(qqBelle?.sourceId, 'qq');
    },
  );

  test('routes sends and current-user lookup to the selected source', () async {
    final repository = CompositeImRepository(
      registrations: [
        ImRepositoryRegistration(
          id: 'zzz',
          label: 'ZZZ Server',
          repository: MockImRepository(),
        ),
        ImRepositoryRegistration(
          id: 'qq',
          label: 'QQ',
          repository: MockImRepository(),
        ),
      ],
      primarySourceId: 'zzz',
    );
    addTearDown(repository.dispose);

    final message = await repository.sendTextMessage(
      conversationId: 'qq::dm_belle_me',
      text: 'routed to QQ',
    );
    final qqMessages = await repository
        .watchMessages('qq::dm_belle_me')
        .firstWhere((messages) => messages.length == 4);
    final zzzMessages =
        await repository.watchMessages('zzz::dm_belle_me').first;
    final qqSelf = await repository.getCurrentUser(sourceId: 'qq');

    expect(message.conversationId, 'qq::dm_belle_me');
    expect(message.senderId, 'qq::me');
    expect(qqMessages.last.text, 'routed to QQ');
    expect(zzzMessages, hasLength(3));
    expect(qqSelf.id, 'qq::me');
    expect(ImSourceAddress.localIdOf(qqSelf.id), 'me');
  });
}
