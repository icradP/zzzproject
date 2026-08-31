import 'package:flutter_test/flutter_test.dart';
import 'package:onebot_flutter/onebot_flutter.dart';
import 'package:zzzproject/src/im/adapters/composite_im_repository.dart';
import 'package:zzzproject/src/im/data/mock_im_repository.dart';
import 'package:zzzproject/src/im/models/im_models.dart';
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

  test('preserves read receipt metadata across source namespacing', () {
    final repository = CompositeImRepository(
      registrations: [
        ImRepositoryRegistration(
          id: 'zzz',
          label: 'ZZZ Server',
          repository: MockImRepository(),
        ),
      ],
      primarySourceId: 'zzz',
    );
    addTearDown(repository.dispose);

    final scoped = repository.scopeMessage(
      'zzz',
      ImMessage(
        id: 'message-1',
        conversationId: 'group-1',
        senderId: 'me',
        text: 'hello',
        sentAt: DateTime(2026, 9, 1),
        status: ImMessageStatus.read,
        readCount: 12,
        recipientCount: 128,
        isMine: true,
        segments: const [
          OneBotMessageSegment(type: 'reply', data: {'id': 'message-0'}),
        ],
        replyToMessageId: 'message-0',
      ),
    );

    expect(scoped.status, ImMessageStatus.read);
    expect(scoped.readCount, 12);
    expect(scoped.recipientCount, 128);
    expect(scoped.replyToMessageId, 'zzz::message-0');
    expect(scoped.segments?.single.data['id'], 'zzz::message-0');
  });

  test('scopes reply targets and routes recalls to the source', () async {
    final repository = CompositeImRepository(
      registrations: [
        ImRepositoryRegistration(
          id: 'zzz',
          label: 'ZZZ Server',
          repository: MockImRepository(),
        ),
      ],
      primarySourceId: 'zzz',
    );
    addTearDown(repository.dispose);

    final initial = await repository.watchMessages('zzz::dm_belle_me').first;
    final target = initial.first;
    final reply = await repository.sendTextMessage(
      conversationId: 'zzz::dm_belle_me',
      text: 'scoped reply',
      replyToMessageId: target.id,
    );

    expect(reply.replyToMessageId, target.id);
    await repository.recallMessage(
      conversationId: reply.conversationId,
      messageId: reply.id,
    );
    final updated = await repository.watchMessages(reply.conversationId).first;
    expect(
      updated.singleWhere((message) => message.id == reply.id).recalled,
      true,
    );
    await expectLater(
      repository.sendTextMessage(
        conversationId: reply.conversationId,
        text: 'wrong source',
        replyToMessageId: 'qq::message-1',
      ),
      throwsArgumentError,
    );
    expect(
      () => repository.recallMessage(
        conversationId: reply.conversationId,
        messageId: 'qq::message-1',
      ),
      throwsArgumentError,
    );
  });

  test(
    'scopes group details and rejects cross-source member operations',
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

      final details = await repository.getGroupDetails(
        'qq::group_cunning_hares',
      );
      expect(details.conversation.id, 'qq::group_cunning_hares');
      expect(details.currentUserId, 'qq::me');
      expect(
        details.members.every((member) => member.user.id.startsWith('qq::')),
        isTrue,
      );
      expect(details.canEditSettings, isTrue);
      expect(details.canTransferOwnership, isTrue);

      await repository.inviteGroupMembers(
        groupId: details.conversation.id,
        userIds: const ['qq::wise'],
      );
      final invited = await repository.getGroupDetails(details.conversation.id);
      expect(
        invited.members.map((member) => member.user.id),
        contains('qq::wise'),
      );
      await repository.removeGroupMember(
        groupId: details.conversation.id,
        userId: 'qq::wise',
      );
      await repository.updateGroup(
        groupId: details.conversation.id,
        name: 'Scoped group',
        announcement: 'Scoped announcement',
      );
      await repository.setGroupAdmin(
        groupId: details.conversation.id,
        userId: 'qq::nicole',
        enabled: true,
      );
      await repository.setGroupMemberMute(
        groupId: details.conversation.id,
        userId: 'qq::nicole',
        duration: const Duration(minutes: 10),
      );
      await repository.setGroupMuteAll(
        groupId: details.conversation.id,
        enabled: true,
      );
      final governed = await repository.getGroupDetails(
        details.conversation.id,
      );
      expect(governed.conversation.title, 'Scoped group');
      expect(governed.announcement, 'Scoped announcement');
      expect(governed.muteAll, isTrue);
      expect(
        governed.members.singleWhere((m) => m.user.id == 'qq::nicole').role,
        ImGroupRole.admin,
      );
      expect(
        governed.members.singleWhere((m) => m.user.id == 'qq::nicole').isMuted,
        isTrue,
      );

      expect(
        () => repository.inviteGroupMembers(
          groupId: details.conversation.id,
          userIds: const ['zzz::wise'],
        ),
        throwsArgumentError,
      );
      expect(
        () => repository.removeGroupMember(
          groupId: details.conversation.id,
          userId: 'zzz::wise',
        ),
        throwsArgumentError,
      );
      expect(
        () => repository.transferGroupOwnership(
          groupId: details.conversation.id,
          userId: 'zzz::nicole',
        ),
        throwsArgumentError,
      );
    },
  );
}
