import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:zzzproject/zzz_im_chat.dart';
import 'package:zzzproject/src/im/data/im_message_store.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  TestWidgetsFlutterBinding.ensureInitialized();

  late ImMessageStore store;
  late Directory dbDirectory;

  setUp(() async {
    dbDirectory = Directory.systemTemp.createTempSync('im_test_');
    store = ImMessageStore(selfId: 'test_bot', debugDbPath: dbDirectory.path);
    await store.open();
  });

  tearDown(() async {
    await store.close();
    try {
      if (await dbDirectory.exists()) {
        await dbDirectory.delete(recursive: true);
      }
    } catch (_) {}
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
    await store.upsertConversation(
      ImConversation(
        id: 'dm_test_002',
        type: ImConversationType.direct,
        title: 'Media User',
        participantIds: ['test_bot', '20001'],
      ),
    );

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
        OneBotMessageSegment.image(
          'abc123.jpg',
          url: 'https://example.com/a.jpg',
        ),
      ],
      mediaUrl: 'https://example.com/a.jpg',
      mediaWidth: 1920,
      mediaHeight: 1080,
      thumbnailUrl: 'https://example.com/a-thumb.jpg',
      mediaMime: 'image/jpeg',
    );

    await store.insertMessage(msg);

    final messages = await store.getMessages('dm_test_002');
    expect(messages.length, 1);
    final read = messages.first;
    expect(read.text, '@Alice check this [图片]');
    expect(read.kind, ImMessageKind.image);
    expect(read.mediaUrl, 'https://example.com/a.jpg');
    expect(read.mediaWidth, 1920);
    expect(read.mediaHeight, 1080);
    expect(read.thumbnailUrl, 'https://example.com/a-thumb.jpg');
    expect(read.segments, isNotNull);
    expect(read.segments!.length, 3);
    expect(read.segments![2].type, 'image');
  });

  test(
    'dynamic content schema survives closing and reopening history',
    () async {
      await store.upsertConversation(
        ImConversation(
          id: 'dm_dynamic',
          type: ImConversationType.direct,
          title: 'Dynamic history',
          participantIds: ['test_bot', 'fairy'],
        ),
      );
      const content = ImDynamicContent(
        id: 'diagnosis-1',
        version: '1.0',
        source: ImDynamicContentSource.ai,
        tree: ImDynamicNode(
          id: 'root',
          type: 'status',
          props: {'text': 'Complete'},
        ),
        fallback: ImDynamicFallback(type: 'text', content: 'Complete'),
      );
      final data = Map<String, dynamic>.from(content.toJson())..remove('type');
      await store.insertMessage(
        ImMessage(
          id: 'dynamic-message-1',
          conversationId: 'dm_dynamic',
          senderId: 'fairy',
          text: 'Complete',
          sentAt: DateTime(2026, 9, 8),
          kind: ImMessageKind.dynamicContent,
          segments: [
            const OneBotMessageSegment(
              type: 'text',
              data: {'text': 'Complete'},
            ),
            OneBotMessageSegment(type: 'dynamic_content', data: data),
          ],
        ),
      );

      await store.close();
      store = ImMessageStore(selfId: 'test_bot', debugDbPath: dbDirectory.path);
      await store.open();

      final restored = (await store.getMessages('dm_dynamic')).single;
      final dynamicSegment = restored.segments!.last;
      final restoredContent = ImDynamicContent.fromSegmentData(
        dynamicSegment.data,
      );
      expect(dynamicSegment.type, 'dynamic_content');
      expect(restoredContent.toJson(), content.toJson());
      expect(restoredContent.tree.props['text'], 'Complete');
    },
  );

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
      notificationLevel: ImConversationNotificationLevel.muted,
    );

    await store.upsertConversation(older);
    await store.upsertConversation(newer);
    await store.upsertConversation(pinned);

    final list = await store.getConversations();
    expect(list.length, 3);
    expect(list[0].title, 'Pinned');
    expect(list[0].isMuted, isTrue);
    expect(list[1].title, 'Newer');
    expect(list[2].title, 'Older');
  });

  test('message insert updates conversation subtitle', () async {
    await store.upsertConversation(
      ImConversation(
        id: 'dm_update',
        type: ImConversationType.direct,
        title: 'Update Test',
        participantIds: ['test_bot', '40001'],
      ),
    );

    await store.insertMessage(
      ImMessage(
        id: 'm1',
        conversationId: 'dm_update',
        senderId: '40001',
        text: 'First message',
        sentAt: DateTime(2026, 5, 28, 10, 0),
      ),
    );
    await store.insertMessage(
      ImMessage(
        id: 'm2',
        conversationId: 'dm_update',
        senderId: '40001',
        text: 'Second message',
        sentAt: DateTime(2026, 5, 28, 10, 1),
      ),
    );

    final conv = await store.getConversation('dm_update');
    expect(conv!.subtitle, 'Second message');
  });

  test('search messages', () async {
    await store.upsertConversation(
      ImConversation(
        id: 'dm_search',
        type: ImConversationType.direct,
        title: 'Search Test',
        participantIds: ['test_bot', '50001'],
      ),
    );

    await store.insertMessage(
      ImMessage(
        id: 's1',
        conversationId: 'dm_search',
        senderId: '50001',
        text: 'Can you send the report?',
        sentAt: DateTime(2026, 5, 28, 9, 0),
      ),
    );
    await store.insertMessage(
      ImMessage(
        id: 's2',
        conversationId: 'dm_search',
        senderId: 'test_bot',
        text: 'I sent it already',
        sentAt: DateTime(2026, 5, 28, 9, 1),
      ),
    );

    final results = await store.searchMessages('report');
    expect(results.length, 1);
    expect(results.first.text, 'Can you send the report?');
  });

  test('delete message and conversation', () async {
    await store.upsertConversation(
      ImConversation(
        id: 'dm_del',
        type: ImConversationType.direct,
        title: 'To Delete',
        participantIds: ['test_bot', '60001'],
      ),
    );
    await store.insertMessage(
      ImMessage(
        id: 'd1',
        conversationId: 'dm_del',
        senderId: '60001',
        text: 'Delete me',
        sentAt: DateTime(2026, 5, 28),
      ),
    );

    await store.deleteMessage('d1', 'dm_del');
    expect(await store.getMessages('dm_del'), isEmpty);

    await store.deleteConversation('dm_del');
    expect(await store.getConversation('dm_del'), isNull);
  });
}
