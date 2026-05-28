import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:onebot_flutter/onebot_flutter.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:zzzproject/src/im/data/im_message_store.dart';
import 'package:zzzproject/src/im/models/im_models.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  TestWidgetsFlutterBinding.ensureInitialized();

  late ImMessageStore store;
  late String dbPath;

  setUp(() async {
    final tmpDir = Directory.systemTemp.createTempSync('im_test_');
    dbPath = '${tmpDir.path}/im_test.db';
    store = ImMessageStore(selfId: 'test_bot', debugDbPath: dbPath);
    await store.open();
  });

  tearDown(() async {
    await store.close();
    // Clean up temp db.
    try {
      final db = File(dbPath);
      if (await db.exists()) await db.delete();
    } catch (_) {}
  });

  tearDown(() async {
    await store.close();
  });

  test('insert and read conversation', () async {
    final conv = ImConversation(
      id: 'dm_test_001',
      type: ImConversationType.direct,
      title: 'Test User',
      participantIds: ['test_bot', '10001'],
      subtitle: 'Hello',
      updatedAt: DateTime(2026, 5, 28, 12, 0),
    );

    await store.upsertConversation(conv);

    final result = await store.getConversation('dm_test_001');
    expect(result, isNotNull);
    expect(result!.title, 'Test User');
    expect(result.participantIds, ['test_bot', '10001']);
  });

  test('insert and read message with media', () async {
    // Seed the conversation first.
    await store.upsertConversation(ImConversation(
      id: 'dm_test_002',
      type: ImConversationType.direct,
      title: 'Media User',
      participantIds: ['test_bot', '20001'],
    ));

    final msg = ImMessage(
      id: 'msg_001',
      conversationId: 'dm_test_002',
      senderId: '20001',
      text: '@Alice check this [图片]',
      sentAt: DateTime(2026, 5, 28, 12, 30),
      kind: ImMessageKind.image,
      status: ImMessageStatus.sent,
      isMine: false,
      segments: [
        OneBotMessageSegment.at('20002'),
        OneBotMessageSegment.plain(' check this '),
        OneBotMessageSegment.image('abc123.jpg', url: 'https://example.com/a.jpg'),
      ],
      mediaUrl: 'https://example.com/a.jpg',
      mediaMime: 'image/jpeg',
    );

    await store.insertMessage(msg);

    final messages = await store.getMessages('dm_test_002');
    expect(messages.length, 1);
    final read = messages.first;
    expect(read.text, '@Alice check this [图片]');
    expect(read.kind, ImMessageKind.image);
    expect(read.mediaUrl, 'https://example.com/a.jpg');
    expect(read.segments, isNotNull);
    expect(read.segments!.length, 3);
    expect(read.segments![2].type, 'image');
  });

  test('conversation list ordering', () async {
    final older = ImConversation(
      id: 'dm_older',
      type: ImConversationType.direct,
      title: 'Older',
      participantIds: ['test_bot', '30001'],
      updatedAt: DateTime(2026, 5, 27),
    );
    final newer = ImConversation(
      id: 'dm_newer',
      type: ImConversationType.direct,
      title: 'Newer',
      participantIds: ['test_bot', '30002'],
      updatedAt: DateTime(2026, 5, 28),
    );
    final pinned = ImConversation(
      id: 'dm_pinned',
      type: ImConversationType.direct,
      title: 'Pinned',
      participantIds: ['test_bot', '30003'],
      updatedAt: DateTime(2026, 5, 26),
      isPinned: true,
    );

    await store.upsertConversation(older);
    await store.upsertConversation(newer);
    await store.upsertConversation(pinned);

    final list = await store.getConversations();
    expect(list.length, 3);
    expect(list[0].title, 'Pinned');
    expect(list[1].title, 'Newer');
    expect(list[2].title, 'Older');
  });

  test('message insert updates conversation subtitle', () async {
    await store.upsertConversation(ImConversation(
      id: 'dm_update',
      type: ImConversationType.direct,
      title: 'Update Test',
      participantIds: ['test_bot', '40001'],
    ));

    await store.insertMessage(ImMessage(
      id: 'm1',
      conversationId: 'dm_update',
      senderId: '40001',
      text: 'First message',
      sentAt: DateTime(2026, 5, 28, 10, 0),
    ));
    await store.insertMessage(ImMessage(
      id: 'm2',
      conversationId: 'dm_update',
      senderId: '40001',
      text: 'Second message',
      sentAt: DateTime(2026, 5, 28, 10, 1),
    ));

    final conv = await store.getConversation('dm_update');
    expect(conv!.subtitle, 'Second message');
  });

  test('search messages', () async {
    await store.upsertConversation(ImConversation(
      id: 'dm_search',
      type: ImConversationType.direct,
      title: 'Search Test',
      participantIds: ['test_bot', '50001'],
    ));

    await store.insertMessage(ImMessage(
      id: 's1',
      conversationId: 'dm_search',
      senderId: '50001',
      text: 'Can you send the report?',
      sentAt: DateTime(2026, 5, 28, 9, 0),
    ));
    await store.insertMessage(ImMessage(
      id: 's2',
      conversationId: 'dm_search',
      senderId: 'test_bot',
      text: 'I sent it already',
      sentAt: DateTime(2026, 5, 28, 9, 1),
    ));

    final results = await store.searchMessages('report');
    expect(results.length, 1);
    expect(results.first.text, 'Can you send the report?');
  });

  test('delete message and conversation', () async {
    await store.upsertConversation(ImConversation(
      id: 'dm_del',
      type: ImConversationType.direct,
      title: 'To Delete',
      participantIds: ['test_bot', '60001'],
    ));
    await store.insertMessage(ImMessage(
      id: 'd1',
      conversationId: 'dm_del',
      senderId: '60001',
      text: 'Delete me',
      sentAt: DateTime(2026, 5, 28),
    ));

    await store.deleteMessage('d1', 'dm_del');
    expect(await store.getMessages('dm_del'), isEmpty);

    await store.deleteConversation('dm_del');
    expect(await store.getConversation('dm_del'), isNull);
  });
}
