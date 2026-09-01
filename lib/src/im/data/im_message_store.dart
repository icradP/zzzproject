import 'dart:convert';
import 'dart:io';

import 'package:onebot_flutter/onebot_flutter.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../models/im_models.dart';
import 'im_storage_config.dart';

/// SQLite-backed persistent store for IM conversations and messages.
class ImMessageStore {
  ImMessageStore({required this.selfId, this.debugDbPath, this.storageConfig});

  final String selfId;
  final String? debugDbPath;
  final ImStorageConfig? storageConfig;

  Database? _db;

  static const _version = 8;

  static bool _ffiInitialized = false;

  static void _ensureFfi() {
    if (_ffiInitialized) return;
    _ffiInitialized = true;
    // On desktop, sqflite needs FFI init. On iOS/Android, use native sqflite.
    if (!Platform.isIOS && !Platform.isAndroid) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }
  }

  Future<void> open() async {
    _ensureFfi();
    if (_db != null) return;

    final dbDirPath = await _resolveDbDir();
    _db = await openDatabase(
      '$dbDirPath/im_${_safeId(selfId)}.db',
      version: _version,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  Future<String> _resolveDbDir() async {
    if (debugDbPath != null) return debugDbPath!;
    if (storageConfig != null) {
      return (await storageConfig!.resolveDatabaseDir()).path;
    }
    final appDir = await getApplicationDocumentsDirectory();
    final dir = Directory('${appDir.path}/im_data');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir.path;
  }

  Future<void> close() async {
    await _db?.close();
    _db = null;
  }

  // -----------------------------------------------------------------------
  // Schema
  // -----------------------------------------------------------------------

  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE conversations (
        id              TEXT PRIMARY KEY,
        type            INTEGER NOT NULL DEFAULT 0,
        title           TEXT NOT NULL,
        participant_ids TEXT NOT NULL DEFAULT '[]',
        subtitle        TEXT,
        avatar_path     TEXT,
        avatar_local_path TEXT,
        updated_at      INTEGER,
        unread_count    INTEGER NOT NULL DEFAULT 0,
        is_pinned       INTEGER NOT NULL DEFAULT 0,
        is_muted        INTEGER NOT NULL DEFAULT 0,
        extra           TEXT NOT NULL DEFAULT '{}'
      )
    ''');

    await db.execute('''
      CREATE TABLE messages (
        id              TEXT NOT NULL,
        conversation_id TEXT NOT NULL,
        sender_id       TEXT NOT NULL,
        text            TEXT NOT NULL DEFAULT '',
        sent_at         INTEGER NOT NULL,
        kind            TEXT NOT NULL DEFAULT 'text',
        status          TEXT NOT NULL DEFAULT 'sent',
        is_mine         INTEGER NOT NULL DEFAULT 0,
        segments        TEXT,
        media_path      TEXT,
        media_url       TEXT,
        media_size      INTEGER,
        media_width     INTEGER,
        media_height    INTEGER,
        thumbnail_path  TEXT,
        thumbnail_url   TEXT,
        media_mime      TEXT,
        reactions       TEXT,
        reply_to_message_id TEXT,
        recalled        INTEGER NOT NULL DEFAULT 0,
        extra           TEXT NOT NULL DEFAULT '{}',
        PRIMARY KEY (id, conversation_id)
      )
    ''');

    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_messages_conv
      ON messages(conversation_id, sent_at DESC)
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS forward_messages (
        forward_id  TEXT PRIMARY KEY,
        messages    TEXT NOT NULL,
        fetched_at  INTEGER NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS forward_messages (
        forward_id  TEXT PRIMARY KEY,
        messages    TEXT NOT NULL,
        fetched_at  INTEGER NOT NULL
      )
    ''');
  }

  Future<void> _onUpgrade(Database db, int oldV, int newV) async {
    if (oldV < 2) {
      await db.execute(
        "ALTER TABLE conversations ADD COLUMN avatar_local_path TEXT",
      );
      await db.execute(
        "ALTER TABLE conversations ADD COLUMN extra TEXT NOT NULL DEFAULT '{}'",
      );
      await db.execute("ALTER TABLE messages ADD COLUMN reactions TEXT");
      await db.execute(
        "ALTER TABLE messages ADD COLUMN extra TEXT NOT NULL DEFAULT '{}'",
      );
    }
    if (oldV < 3) {
      await db.execute(
        "ALTER TABLE messages ADD COLUMN reply_to_message_id TEXT",
      );
    }
    if (oldV < 4) {
      await db.execute(
        "ALTER TABLE messages ADD COLUMN recalled INTEGER NOT NULL DEFAULT 0",
      );
    }
    if (oldV < 5) {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS forward_messages (
          forward_id  TEXT PRIMARY KEY,
          messages    TEXT NOT NULL,
          fetched_at  INTEGER NOT NULL
        )
      ''');
    }
    if (oldV < 6) {
      await db.execute(
        'ALTER TABLE conversations ADD COLUMN is_muted INTEGER NOT NULL DEFAULT 0',
      );
    }
    if (oldV < 7) {
      await db.execute('ALTER TABLE messages ADD COLUMN thumbnail_url TEXT');
    }
    if (oldV < 8) {
      await db.execute('ALTER TABLE messages ADD COLUMN media_width INTEGER');
      await db.execute('ALTER TABLE messages ADD COLUMN media_height INTEGER');
    }
  }

  Database get _db_ => _db!; // safe after open(); use _dbOrNull for writes

  /// Returns the database if already opened, otherwise `null`.
  /// Write methods use this so they are no-ops until [open] completes.
  Database? get _dbOrNull => _db;

  // -----------------------------------------------------------------------
  // Conversations
  // -----------------------------------------------------------------------

  Future<void> upsertConversation(ImConversation c) async {
    final db = _dbOrNull;
    if (db == null) return;
    await db.insert(
      'conversations',
      _convToRow(c),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<ImConversation>> getConversations() async {
    final rows = await _db_.query(
      'conversations',
      orderBy: 'is_pinned DESC, updated_at DESC',
    );
    return rows.map(_rowToConv).toList();
  }

  Future<ImConversation?> getConversation(String id) async {
    final rows = await _db_.query(
      'conversations',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return rows.isNotEmpty ? _rowToConv(rows.first) : null;
  }

  Future<void> deleteConversation(String id) async {
    await _db_.delete('conversations', where: 'id = ?', whereArgs: [id]);
    await _db_.delete(
      'messages',
      where: 'conversation_id = ?',
      whereArgs: [id],
    );
  }

  // -----------------------------------------------------------------------
  // Messages
  // -----------------------------------------------------------------------

  Future<void> insertMessage(ImMessage m) async {
    final db = _dbOrNull;
    if (db == null) return;
    await db.insert(
      'messages',
      _msgToRow(m),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    await db.update(
      'conversations',
      {'subtitle': m.text, 'updated_at': m.sentAt.millisecondsSinceEpoch},
      where: 'id = ?',
      whereArgs: [m.conversationId],
    );
  }

  Future<void> insertMessages(List<ImMessage> batch) async {
    final db = _dbOrNull;
    if (db == null) return;
    final batchOp = db.batch();
    for (final m in batch) {
      batchOp.insert(
        'messages',
        _msgToRow(m),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batchOp.commit(noResult: true);
  }

  Future<List<ImMessage>> getMessages(
    String conversationId, {
    int limit = 50,
    int offset = 0,
  }) async {
    final rows = await _db_.query(
      'messages',
      where: 'conversation_id = ?',
      whereArgs: [conversationId],
      orderBy: 'sent_at DESC',
      limit: limit,
      offset: offset,
    );
    return rows.map(_rowToMsg).toList().reversed.toList();
  }

  Future<List<ImMessage>> getLatestMessages({int perConversation = 1}) async {
    final rows = await _db_.rawQuery('''
      SELECT m.* FROM messages m
      INNER JOIN (
        SELECT conversation_id, MAX(sent_at) AS max_sent
        FROM messages GROUP BY conversation_id
      ) latest
      ON m.conversation_id = latest.conversation_id
      AND m.sent_at = latest.max_sent
      ORDER BY m.sent_at DESC
    ''');
    return rows.map(_rowToMsg).toList();
  }

  Future<List<ImMessage>> loadAllMessages({int limitPerConv = 30}) async {
    final convRows = await _db_.query('conversations');
    final result = <ImMessage>[];
    for (final c in convRows) {
      final msgs = await getMessages(c['id'] as String, limit: limitPerConv);
      result.addAll(msgs);
    }
    return result;
  }

  Future<void> updateMessageStatus({
    required String id,
    required String conversationId,
    required ImMessageStatus status,
  }) async {
    final db = _dbOrNull;
    if (db == null) return;
    await db.update(
      'messages',
      {'status': status.name},
      where: 'id = ? AND conversation_id = ?',
      whereArgs: [id, conversationId],
    );
  }

  Future<void> deleteMessage(String id, String conversationId) async {
    final db = _dbOrNull;
    if (db == null) return;
    await db.delete(
      'messages',
      where: 'id = ? AND conversation_id = ?',
      whereArgs: [id, conversationId],
    );
  }

  Future<List<ImMessage>> searchMessages(String query, {int limit = 30}) async {
    final db = _dbOrNull;
    if (db == null) return [];
    final rows = await db.query(
      'messages',
      where: 'text LIKE ?',
      whereArgs: ['%$query%'],
      orderBy: 'sent_at DESC',
      limit: limit,
    );
    return rows.map(_rowToMsg).toList().reversed.toList();
  }

  // -----------------------------------------------------------------------
  // Row ↔ Model converters
  // -----------------------------------------------------------------------

  Map<String, dynamic> _convToRow(ImConversation c) => {
    'id': c.id,
    'type': c.type.index,
    'title': c.title,
    'participant_ids': jsonEncode(c.participantIds),
    'subtitle': c.subtitle,
    'avatar_path': c.avatarAssetPath,
    'avatar_local_path': c.avatarLocalPath,
    'updated_at': c.updatedAt?.millisecondsSinceEpoch,
    'unread_count': c.unreadCount,
    'is_pinned': c.isPinned ? 1 : 0,
    'is_muted': c.isMuted ? 1 : 0,
    'extra': '{}',
  };

  // -----------------------------------------------------------------------
  // Forward messages cache (stores raw API response JSON)
  // -----------------------------------------------------------------------

  Future<void> saveForwardRaw(String forwardId, String rawJson) async {
    final db = _dbOrNull;
    if (db == null) return;
    await db.insert('forward_messages', {
      'forward_id': forwardId,
      'messages': rawJson,
      'fetched_at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<String?> loadForwardRaw(String forwardId) async {
    final db = _dbOrNull;
    if (db == null) return null;
    final rows = await db.query(
      'forward_messages',
      where: 'forward_id = ?',
      whereArgs: [forwardId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.first['messages'] as String?;
  }

  ImConversation _rowToConv(Map<String, dynamic> r) => ImConversation(
    id: r['id'] as String,
    type: ImConversationType.values[(r['type'] as int?) ?? 0],
    title: (r['title'] as String?) ?? '',
    participantIds:
        (jsonDecode((r['participant_ids'] as String?) ?? '[]') as List<dynamic>)
            .cast<String>(),
    subtitle: r['subtitle'] as String?,
    avatarAssetPath: r['avatar_path'] as String?,
    avatarLocalPath: r['avatar_local_path'] as String?,
    updatedAt:
        (r['updated_at'] as int?) != null
            ? DateTime.fromMillisecondsSinceEpoch(r['updated_at'] as int)
            : null,
    unreadCount: (r['unread_count'] as int?) ?? 0,
    isPinned: (r['is_pinned'] as int?) == 1,
    isMuted: (r['is_muted'] as int?) == 1,
  );

  Map<String, dynamic> _msgToRow(ImMessage m) => {
    'id': m.id,
    'conversation_id': m.conversationId,
    'sender_id': m.senderId,
    'text': m.text,
    'sent_at': m.sentAt.millisecondsSinceEpoch,
    'kind': m.kind.name,
    'status': m.status.name,
    'is_mine': m.isMine ? 1 : 0,
    'segments':
        m.segments != null ? jsonEncode(oneBotChainToJson(m.segments!)) : null,
    'media_path': m.mediaPath,
    'media_url': m.mediaUrl,
    'media_size': m.mediaSize,
    'media_width': m.mediaWidth,
    'media_height': m.mediaHeight,
    'thumbnail_path': m.thumbnailPath,
    'thumbnail_url': m.thumbnailUrl,
    'media_mime': m.mediaMime,
    'reactions':
        m.reactions != null
            ? jsonEncode(
              m.reactions!
                  .map(
                    (r) => {
                      'emoji_id': r.emojiId,
                      'count': r.count,
                      'reacted_by_me': r.reactedByMe,
                    },
                  )
                  .toList(),
            )
            : null,
    'reply_to_message_id': m.replyToMessageId,
    'recalled': m.recalled ? 1 : 0,
    'extra': '{}',
  };

  ImMessage _rowToMsg(Map<String, dynamic> r) {
    List<OneBotMessageSegment>? segs;
    final segsRaw = r['segments'] as String?;
    if (segsRaw != null && segsRaw.isNotEmpty) {
      try {
        segs = oneBotChainFromJson(jsonDecode(segsRaw) as List<dynamic>);
      } catch (_) {}
    }

    List<ImReaction>? reactions;
    final rxRaw = r['reactions'] as String?;
    if (rxRaw != null && rxRaw.isNotEmpty) {
      try {
        final list = jsonDecode(rxRaw) as List<dynamic>;
        reactions =
            list
                .map(
                  (e) => ImReaction(
                    emojiId: '${e['emoji_id'] ?? ''}',
                    count: (e['count'] as num?)?.toInt() ?? 0,
                    reactedByMe: e['reacted_by_me'] as bool? ?? false,
                  ),
                )
                .where(
                  (reaction) =>
                      reaction.emojiId.isNotEmpty && reaction.count > 0,
                )
                .toList();
      } catch (_) {}
    }

    return ImMessage(
      id: r['id'] as String,
      conversationId: r['conversation_id'] as String,
      senderId: r['sender_id'] as String,
      text: (r['text'] as String?) ?? '',
      sentAt: DateTime.fromMillisecondsSinceEpoch(r['sent_at'] as int),
      kind: ImMessageKind.values.firstWhere(
        (k) => k.name == r['kind'],
        orElse: () => ImMessageKind.text,
      ),
      status: ImMessageStatus.values.firstWhere(
        (s) => s.name == r['status'],
        orElse: () => ImMessageStatus.sent,
      ),
      isMine: (r['is_mine'] as int?) == 1,
      segments: segs,
      mediaPath: r['media_path'] as String?,
      mediaUrl: r['media_url'] as String?,
      mediaSize: r['media_size'] as int?,
      mediaWidth: r['media_width'] as int?,
      mediaHeight: r['media_height'] as int?,
      thumbnailPath: r['thumbnail_path'] as String?,
      thumbnailUrl: r['thumbnail_url'] as String?,
      mediaMime: r['media_mime'] as String?,
      reactions: reactions,
      replyToMessageId: r['reply_to_message_id'] as String?,
      recalled: (r['recalled'] as int?) == 1,
    );
  }

  static String _safeId(String raw) => raw.replaceAll(RegExp(r'[^\w]'), '_');
}
