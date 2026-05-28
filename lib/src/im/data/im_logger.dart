import 'dart:convert';
import 'package:flutter/foundation.dart';

/// Tagged logger for debugging OneBot traffic and IM data flow.
///
/// Set [enabled] to false to silence all output.
/// Each tag can be toggled individually via [enableTag] / [disableTag].
class ImLogger {
  ImLogger._();

  static bool enabled = true;

  static final _disabledTags = <String>{};

  static void enableTag(String tag) => _disabledTags.remove(tag);
  static void disableTag(String tag) => _disabledTags.add(tag);

  // Pre-defined tags
  static const api = 'API';
  static const event = 'EVENT';
  static const ingest = 'INGEST';
  static const media = 'MEDIA';
  static const avatar = 'AVATAR';
  static const store = 'STORE';

  /// Called by external code (e.g. OneBotClient callback) with a pre-built
  /// message. Bypasses the public helpers to avoid double-formatting.
  static void logRaw(String tag, String msg) => _log(tag, msg);

  static void _log(String tag, String msg) {
    if (!enabled || _disabledTags.contains(tag)) return;
    final ts = DateTime.now().toIso8601String().substring(11, 23);
    debugPrint('[$ts] [$tag] $msg');
  }

  // -- API ----------------------------------------------------------------

  static void apiCall(String action, Map<String, dynamic>? params) {
    final p = params != null ? _truncate(jsonEncode(params), 300) : '{}';
    _log(api, '→ $action $p');
  }

  static void apiResponse(String action, int retcode, dynamic data) {
    final d = data != null ? _truncate('$data', 300) : 'null';
    _log(api, '← $action ret=$retcode $d');
  }

  static void apiError(String action, Object error) {
    _log(api, '✗ $action $error');
  }

  // -- Event --------------------------------------------------------------

  static void eventReceived(String postType, Map<String, dynamic> raw) {
    final preview = _eventPreview(postType, raw);
    _log(event, '↓ $postType $preview');
  }

  // -- Ingest -------------------------------------------------------------

  static void ingestMessage(String convId, String senderId, String kind,
      String text, {int? segCount}) {
    final s = segCount != null ? ' ($segCount segs)' : '';
    _log(ingest, 'msg conv=$convId from=$senderId kind=$kind text="${_truncate(text, 80)}"$s');
  }

  static void ingestData(String phase, Map<String, dynamic> data) {
    _log(ingest, '$phase ${_truncate(jsonEncode(data), 500)}');
  }

  static void ingestCount(String label, int count) {
    _log(ingest, '$label: $count');
  }

  // -- Media --------------------------------------------------------------

  static void mediaDownload(String type, String fileId, {String? url}) {
    final u = url != null ? ' url=$url' : '';
    _log(media, '↓ $type file=$fileId$u');
  }

  static void mediaReady(String localPath, {int? size}) {
    final s = size != null ? ' (${_formatBytes(size)})' : '';
    _log(media, '✓ cached → $localPath$s');
  }

  // -- Avatar -------------------------------------------------------------

  static void avatarFetch(String userId) {
    _log(avatar, '↓ fetch avatar for $userId');
  }

  static void avatarReady(String userId, String localPath) {
    _log(avatar, '✓ $userId → $localPath');
  }

  // -- Store --------------------------------------------------------------

  static void storeOp(String op, {String? detail}) {
    final d = detail != null ? ' $detail' : '';
    _log(store, '$op$d');
  }

  // -- Helpers ------------------------------------------------------------

  static String _truncate(String s, int max) =>
      s.length <= max ? s : '${s.substring(0, max)}…';

  static String _eventPreview(String postType, Map<String, dynamic> raw) {
    switch (postType) {
      case 'message':
        final mt = raw['message_type'] ?? '?';
        final uid = raw['user_id'] ?? raw['group_id'] ?? '?';
        final text = _truncate('${raw['raw_message'] ?? raw['message'] ?? '?'}', 120);
        return '$mt uid=$uid "$text"';
      case 'notice':
        final nt = raw['notice_type'] ?? '?';
        final sub = raw['sub_type'];
        return sub != null ? '$nt/$sub' : '$nt';
      case 'request':
        return '${raw['request_type'] ?? '?'}';
      case 'meta_event':
        return '${raw['meta_event_type'] ?? '?'}';
      default:
        return _truncate(jsonEncode(raw), 120);
    }
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}
