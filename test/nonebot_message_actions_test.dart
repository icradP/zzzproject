import 'package:flutter_test/flutter_test.dart';

import 'package:zzzproject/src/im/adapters/nonebot/nonebot_mapper.dart';
import 'package:zzzproject/src/im/adapters/nonebot/nonebot_source.dart';
import 'package:zzzproject/src/im/models/im_models.dart';

void main() {
  test('NoneBot replies strip only numeric split-message suffixes', () {
    ImMessage replyTo(String id) => ImMessage(
      id: 'outgoing',
      conversationId: 'group_1',
      senderId: 'me',
      text: 'reply',
      sentAt: DateTime(2026, 9, 1),
      replyToMessageId: id,
    );

    expect(
      imMessageToOneBotChain(replyTo('12345_2')).first.data['id'],
      '12345',
    );
    expect(
      imMessageToOneBotChain(replyTo('local_12345')).first.data['id'],
      'local_12345',
    );
  });

  test('NoneBot mock recall changes only the selected local message', () async {
    final source = NoneBotSource.mock();
    addTearDown(source.disconnect);
    final conversation = (await source.watchConversations().first).first;
    final first = await source.sendTextMessage(
      conversationId: conversation.id,
      text: 'first local message',
    );
    final second = await source.sendTextMessage(
      conversationId: conversation.id,
      text: 'second local message',
    );

    await source.recallMessage(
      conversationId: conversation.id,
      messageId: first.id,
    );
    final messages = await source.watchMessages(conversation.id).first;

    expect(
      messages.singleWhere((message) => message.id == first.id).recalled,
      true,
    );
    expect(
      messages.singleWhere((message) => message.id == second.id).recalled,
      false,
    );
  });
}
