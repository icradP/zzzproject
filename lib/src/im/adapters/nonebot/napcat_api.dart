import 'package:onebot_flutter/onebot_flutter.dart'
    show OneBotApiResponse, OneBotClient, OneBotException, OneBotMessageSegment;

import '../../models/im_models.dart';
import 'nonebot_mapper.dart';

// ---------------------------------------------------------------------------
// NapCat API helpers
// ---------------------------------------------------------------------------

/// A tree of forwarded messages.  Nested forwards become child [ForwardGroup]s.
class ForwardGroup {
  const ForwardGroup({
    this.title,
    this.senderName,
    this.messages = const [],
    this.children = const [],
  });

  final String? title;
  final String? senderName;
  final List<ImMessage> messages;
  final List<ForwardGroup> children;

  bool get isEmpty =>
      messages.isEmpty && children.every((c) => c.isEmpty);
}

/// NapCat-flavoured wrapper around [OneBotClient].
class NapCatApi {
  NapCatApi(this.client);

  final OneBotClient client;

  /// The raw API response data from the last call (for caching).
  Map<String, dynamic>? lastRawData;

  // -- Forward messages ----------------------------------------------------

  /// Fetch a combined forward message as a tree.
  Future<ForwardGroup> getForwardGroup(String forwardId) async {
    OneBotApiResponse r;
    try {
      r = await client.callApi('get_forward_msg', {'message_id': forwardId});
      _checkResponse(r);
    } on OneBotException {
      r = await client.callApi('get_forward_msg', {'id': forwardId});
      _checkResponse(r);
    }
    lastRawData = r.data as Map<String, dynamic>?;
    return parseResponse(lastRawData ?? {});
  }

  /// Flatten a [ForwardGroup] tree into a single list (for caching).
  static List<ImMessage> flattenGroup(ForwardGroup g) {
    final out = <ImMessage>[...g.messages];
    for (final child in g.children) {
      out.addAll(flattenGroup(child));
    }
    return out;
  }

  // -- Parsing -------------------------------------------------------------

  /// Parse raw API response data into a [ForwardGroup] tree.
  static ForwardGroup parseResponse(Map<String, dynamic> data) {
    final raw = data['messages'] ?? data['message'];
    if (raw == null) return const ForwardGroup();

    if (raw is List &&
        raw.isNotEmpty &&
        raw.first is Map &&
        !(raw.first as Map).containsKey('type')) {
      // NapCat format: [{sender, time, message: [segment, ...]}, ...]
      return _parseWrappers(raw);
    }

    // Standard OneBot v11: segment chain.
    final segs = _parseSegments(raw);
    return ForwardGroup(messages: oneBotChainToImMessages(segs));
  }

  /// Parse NapCat wrapper array into a [ForwardGroup] tree.
  static ForwardGroup _parseWrappers(List<dynamic> wrappers) {
    final messages = <ImMessage>[];
    final children = <ForwardGroup>[];

    for (final w in wrappers) {
      final wrapper = w as Map<String, dynamic>;
      final inner = wrapper['message'];
      if (inner is! List) continue;

      // Split inner segments: non-forward → messages, forward → children.
      final nonFwd = <dynamic>[];
      for (final seg in inner) {
        if (seg is Map<String, dynamic> && seg['type'] == 'forward') {
          final data = seg['data'] as Map<String, dynamic>?;
          final content = data?['content'];
          if (content is List &&
              content.isNotEmpty &&
              content.first is Map &&
              !(content.first as Map).containsKey('type')) {
            // Nested forward: recurse into its wrappers.
            // content is verified as List above
            children.add(_parseWrappers(content));
            continue;
          }
        }
        nonFwd.add(seg);
      }

      if (nonFwd.isNotEmpty) {
        final nodeData = _wrapAsNode(wrapper, nonFwd);
        final segs = [nodeData];
        final msgList = oneBotChainToImMessages(segs);
        messages.addAll(msgList);
      }
    }

    return ForwardGroup(messages: messages, children: children);
  }

  static OneBotMessageSegment _wrapAsNode(
      Map<String, dynamic> wrapper, List<dynamic> content) {
    final sender = wrapper['sender'] as Map<String, dynamic>?;
    return OneBotMessageSegment(
      type: 'node',
      data: {
        'user_id': wrapper['user_id']?.toString() ?? '0',
        'nickname': sender?['nickname'] as String? ?? 'User',
        'time': wrapper['time'] as int?,
        'content': content,
      },
    );
  }

  static void _checkResponse(OneBotApiResponse r) {
    if (r.status != 'ok') {
      throw OneBotException(
        'API call failed: status=${r.status} retcode=${r.retcode}',
      );
    }
  }

  static List<OneBotMessageSegment> _parseSegments(dynamic message) {
    if (message is List) {
      return message
          .map((e) =>
              OneBotMessageSegment.fromJson(e as Map<String, dynamic>))
          .toList();
    }
    if (message is String) {
      if (message.isEmpty) return [];
      return [OneBotMessageSegment.plain(message)];
    }
    return [];
  }
}
