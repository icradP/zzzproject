/// OneBot v11 protocol data structures.
///
/// Reference: https://github.com/botuniverse/onebot-11
library;

// ---------------------------------------------------------------------------
// Enums
// ---------------------------------------------------------------------------

enum OneBotPostType { message, notice, request, metaEvent }

enum OneBotWsMode { forward, reverse }

/// Covers all known OneBot v11 `notice_type` values.
///
/// Note: poke, lucky_king, and honor use `notice_type: "notify"` with
/// `sub_type` differentiating them.
enum OneBotNoticeType {
  groupUpload,
  groupAdmin,
  groupDecrease,
  groupIncrease,
  groupBan,
  friendAdd,
  groupRecall,
  friendRecall,
  notify,
}

// ---------------------------------------------------------------------------
// Connection config
// ---------------------------------------------------------------------------

class OneBotConfig {
  const OneBotConfig({
    this.selfId = '',
    this.httpEndpoint,
    this.wsEndpoint,
    this.wsMode = OneBotWsMode.forward,
    this.accessToken,
  });

  final String selfId;
  final String? httpEndpoint;
  final String? wsEndpoint;
  final OneBotWsMode wsMode;
  final String? accessToken;
}

// ---------------------------------------------------------------------------
// Sender
// ---------------------------------------------------------------------------

class OneBotSender {
  const OneBotSender({
    required this.userId,
    required this.nickname,
    this.sex,
    this.age,
    this.card,
    this.area,
    this.level,
    this.role,
    this.title,
  });

  final String userId;
  final String nickname;
  final String? sex;
  final int? age;
  final String? card;
  final String? area;
  final String? level;
  final String? role;
  final String? title;

  factory OneBotSender.fromJson(Map<String, dynamic> json) {
    return OneBotSender(
      userId: '${json['user_id']}',
      nickname: (json['nickname'] as String?) ?? '',
      sex: json['sex'] as String?,
      age: json['age'] as int?,
      card: json['card'] as String?,
      area: json['area'] as String?,
      level: json['level'] as String?,
      role: json['role'] as String?,
      title: json['title'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
        'user_id': userId,
        if (nickname.isNotEmpty) 'nickname': nickname,
        if (sex != null) 'sex': sex,
        if (age != null) 'age': age,
        if (card != null) 'card': card,
        if (area != null) 'area': area,
        if (level != null) 'level': level,
        if (role != null) 'role': role,
        if (title != null) 'title': title,
      };
}

// ---------------------------------------------------------------------------
// Message segment
// ---------------------------------------------------------------------------

class OneBotMessageSegment {
  const OneBotMessageSegment({required this.type, required this.data});

  final String type;
  final Map<String, dynamic> data;

  factory OneBotMessageSegment.fromJson(Map<String, dynamic> json) {
    return OneBotMessageSegment(
      type: json['type'] as String,
      data: Map<String, dynamic>.from(json['data'] as Map? ?? {}),
    );
  }

  Map<String, dynamic> toJson() => {'type': type, 'data': data};

  String? get textContent => type == 'text' ? data['text'] as String? : null;

  // ---- Convenience factories ----

  static OneBotMessageSegment plain(String text) =>
      OneBotMessageSegment(type: 'text', data: {'text': text});

  static OneBotMessageSegment face(int id) =>
      OneBotMessageSegment(type: 'face', data: {'id': '$id'});

  static OneBotMessageSegment image(
    String file, {
    String? type_,
    String? url,
    bool cache = true,
    bool proxy = true,
    int? timeout,
  }) {
    final d = <String, dynamic>{'file': file};
    if (type_ != null) d['type'] = type_;
    if (url != null) d['url'] = url;
    if (!cache) d['cache'] = '0';
    if (!proxy) d['proxy'] = '0';
    if (timeout != null) d['timeout'] = '$timeout';
    return OneBotMessageSegment(type: 'image', data: d);
  }

  static OneBotMessageSegment record(
    String file, {
    bool magic = false,
    String? url,
    bool cache = true,
    bool proxy = true,
    int? timeout,
  }) {
    final d = <String, dynamic>{'file': file};
    if (magic) d['magic'] = '1';
    if (url != null) d['url'] = url;
    if (!cache) d['cache'] = '0';
    if (!proxy) d['proxy'] = '0';
    if (timeout != null) d['timeout'] = '$timeout';
    return OneBotMessageSegment(type: 'record', data: d);
  }

  static OneBotMessageSegment video(
    String file, {
    String? url,
    bool cache = true,
    bool proxy = true,
    int? timeout,
  }) {
    final d = <String, dynamic>{'file': file};
    if (url != null) d['url'] = url;
    if (!cache) d['cache'] = '0';
    if (!proxy) d['proxy'] = '0';
    if (timeout != null) d['timeout'] = '$timeout';
    return OneBotMessageSegment(type: 'video', data: d);
  }

  static OneBotMessageSegment at(String qq) =>
      OneBotMessageSegment(type: 'at', data: {'qq': qq});

  static OneBotMessageSegment rps() =>
      const OneBotMessageSegment(type: 'rps', data: {});

  static OneBotMessageSegment dice() =>
      const OneBotMessageSegment(type: 'dice', data: {});

  static OneBotMessageSegment shake() =>
      const OneBotMessageSegment(type: 'shake', data: {});

  static OneBotMessageSegment poke({String type_ = '1', String id = '1'}) =>
      OneBotMessageSegment(type: 'poke', data: {'type': type_, 'id': id});

  static OneBotMessageSegment reply(int messageId) =>
      OneBotMessageSegment(type: 'reply', data: {'id': '$messageId'});

  static OneBotMessageSegment share({
    required String url,
    required String title,
    String? content,
    String? image,
  }) {
    final d = <String, dynamic>{'url': url, 'title': title};
    if (content != null) d['content'] = content;
    if (image != null) d['image'] = image;
    return OneBotMessageSegment(type: 'share', data: d);
  }

  static OneBotMessageSegment contact({required String type_, required String id}) =>
      OneBotMessageSegment(type: 'contact', data: {'type': type_, 'id': id});

  static OneBotMessageSegment location({
    required double lat,
    required double lon,
    String? title,
    String? content,
  }) {
    final d = <String, dynamic>{
      'lat': lat.toString(),
      'lon': lon.toString(),
    };
    if (title != null) d['title'] = title;
    if (content != null) d['content'] = content;
    return OneBotMessageSegment(type: 'location', data: d);
  }

  static OneBotMessageSegment music({
    required String type_,
    required String id,
  }) =>
      OneBotMessageSegment(type: 'music', data: {'type': type_, 'id': id});

  static OneBotMessageSegment customMusic({
    required String url,
    required String audio,
    required String title,
    String? content,
    String? image,
  }) {
    final d = <String, dynamic>{
      'type': 'custom',
      'url': url,
      'audio': audio,
      'title': title,
    };
    if (content != null) d['content'] = content;
    if (image != null) d['image'] = image;
    return OneBotMessageSegment(type: 'music', data: d);
  }

  static OneBotMessageSegment forward(String id) =>
      OneBotMessageSegment(type: 'forward', data: {'id': id});

  static OneBotMessageSegment node({
    String? id,
    String? userId,
    String? nickname,
    dynamic content,
  }) {
    final d = <String, dynamic>{};
    if (id != null) {
      d['id'] = id;
    } else {
      if (userId != null) d['user_id'] = userId;
      if (nickname != null) d['nickname'] = nickname;
      if (content != null) d['content'] = content;
    }
    return OneBotMessageSegment(type: 'node', data: d);
  }

  static OneBotMessageSegment xml(String data) =>
      OneBotMessageSegment(type: 'xml', data: {'data': data});

  static OneBotMessageSegment json(String data) =>
      OneBotMessageSegment(type: 'json', data: {'data': data});

  static OneBotMessageSegment anonymous({bool ignore = false}) =>
      OneBotMessageSegment(
        type: 'anonymous',
        data: {if (ignore) 'ignore': '1'},
      );
}

// ---------------------------------------------------------------------------
// Message chain helpers
// ---------------------------------------------------------------------------

/// Extracts plain text from a list of [OneBotMessageSegment]s.
String oneBotPlainText(List<OneBotMessageSegment> segments) =>
    segments.map((s) => s.textContent ?? '').join();

/// Converts a List of [OneBotMessageSegment] to the JSON-serialisable form.
List<Map<String, dynamic>> oneBotChainToJson(
  List<OneBotMessageSegment> segments,
) =>
    segments.map((s) => s.toJson()).toList();

/// Converts a raw JSON array to segments.
List<OneBotMessageSegment> oneBotChainFromJson(List<dynamic> json) => json
    .map((e) => OneBotMessageSegment.fromJson(e as Map<String, dynamic>))
    .toList();

// ---------------------------------------------------------------------------
// CQ code parser / serializer
// ---------------------------------------------------------------------------

/// Parse a CQ-code string into a list of [OneBotMessageSegment]s.
///
/// Handles both plain text and `[CQ:type,key=value,...]` codes with proper
/// unescaping of `&amp;`, `&#91;`, `&#93;`, and `&#44;`.
List<OneBotMessageSegment> parseCqCode(String raw) {
  if (raw.isEmpty) return [];
  final segments = <OneBotMessageSegment>[];
  final re = RegExp(r'\[CQ:([^,\]]+)(?:,([^\]]*))?\]');
  int lastEnd = 0;

  for (final match in re.allMatches(raw)) {
    // Plain text before this CQ code
    if (match.start > lastEnd) {
      final text = _cqUnescape(raw.substring(lastEnd, match.start), inCq: false);
      if (text.isNotEmpty) segments.add(OneBotMessageSegment.plain(text));
    }

    final type = match.group(1)!;
    final data = <String, dynamic>{};
    final params = match.group(2);

    if (params != null && params.isNotEmpty) {
      for (final pair in params.split(',')) {
        final eq = pair.indexOf('=');
        if (eq > 0) {
          final key = pair.substring(0, eq);
          final value = _cqUnescape(pair.substring(eq + 1), inCq: true);
          data[key] = value;
        }
      }
    }

    segments.add(OneBotMessageSegment(type: type, data: data));
    lastEnd = match.end;
  }

  // Trailing plain text
  if (lastEnd < raw.length) {
    final text = _cqUnescape(raw.substring(lastEnd), inCq: false);
    if (text.isNotEmpty) segments.add(OneBotMessageSegment.plain(text));
  }

  return segments;
}

/// Serialise a list of [OneBotMessageSegment]s into a CQ-code string.
String segmentsToCqCode(List<OneBotMessageSegment> segments) {
  final buf = StringBuffer();
  for (final seg in segments) {
    if (seg.type == 'text') {
      buf.write(_cqEscape(seg.data['text'] as String? ?? '', inCq: false));
    } else {
      buf.write('[CQ:${seg.type}');
      final keys = seg.data.keys.toList();
      for (int i = 0; i < keys.length; i++) {
        final key = keys[i];
        var value = seg.data[key]?.toString() ?? '';
        value = _cqEscape(value, inCq: true);
        buf.write(',$key=$value');
      }
      buf.write(']');
    }
  }
  return buf.toString();
}

String _cqUnescape(String s, {required bool inCq}) {
  s = s.replaceAll('&amp;', '&').replaceAll('&#91;', '[').replaceAll('&#93;', ']');
  if (inCq) s = s.replaceAll('&#44;', ',');
  return s;
}

String _cqEscape(String s, {required bool inCq}) {
  s = s.replaceAll('&', '&amp;').replaceAll('[', '&#91;').replaceAll(']', '&#93;');
  if (inCq) s = s.replaceAll(',', '&#44;');
  return s;
}

// ---------------------------------------------------------------------------
// Events
// ---------------------------------------------------------------------------

class OneBotPrivateMessageEvent {
  const OneBotPrivateMessageEvent({
    required this.time,
    required this.selfId,
    required this.messageId,
    required this.userId,
    required this.message,
    required this.rawMessage,
    required this.sender,
    this.subType,
    this.font,
  });

  final int time;
  final String selfId;
  final int messageId;
  final String userId;
  final List<OneBotMessageSegment> message;
  final String rawMessage;
  final OneBotSender sender;
  final String? subType;
  final int? font;

  String get plainText => oneBotPlainText(message);

  factory OneBotPrivateMessageEvent.fromJson(Map<String, dynamic> json) {
    return OneBotPrivateMessageEvent(
      time: json['time'] as int,
      selfId: '${json['self_id']}',
      messageId: json['message_id'] as int,
      userId: '${json['user_id']}',
      message: _parseMessage(json['message']),
      rawMessage: (json['raw_message'] as String?) ?? '',
      sender: OneBotSender.fromJson(json['sender'] as Map<String, dynamic>),
      subType: json['sub_type'] as String?,
      font: json['font'] as int?,
    );
  }
}

class OneBotGroupMessageEvent {
  const OneBotGroupMessageEvent({
    required this.time,
    required this.selfId,
    required this.messageId,
    required this.groupId,
    required this.userId,
    required this.message,
    required this.rawMessage,
    required this.sender,
    this.subType,
    this.anonymous,
    this.font,
  });

  final int time;
  final String selfId;
  final int messageId;
  final String groupId;
  final String userId;
  final List<OneBotMessageSegment> message;
  final String rawMessage;
  final OneBotSender sender;
  final String? subType;
  final OneBotAnonymous? anonymous;
  final int? font;

  String get plainText => oneBotPlainText(message);

  factory OneBotGroupMessageEvent.fromJson(Map<String, dynamic> json) {
    return OneBotGroupMessageEvent(
      time: json['time'] as int,
      selfId: '${json['self_id']}',
      messageId: json['message_id'] as int,
      groupId: '${json['group_id']}',
      userId: '${json['user_id']}',
      message: _parseMessage(json['message']),
      rawMessage: (json['raw_message'] as String?) ?? '',
      sender: OneBotSender.fromJson(json['sender'] as Map<String, dynamic>),
      subType: json['sub_type'] as String?,
      anonymous: json['anonymous'] != null
          ? OneBotAnonymous.fromJson(json['anonymous'] as Map<String, dynamic>)
          : null,
      font: json['font'] as int?,
    );
  }
}

class OneBotNoticeEvent {
  const OneBotNoticeEvent({
    required this.time,
    required this.selfId,
    required this.noticeType,
    this.subType,
    this.userId,
    this.groupId,
    this.operatorId,
    this.targetId,
    this.duration,
    this.file,
    this.messageId,
    this.honorType,
  });

  final int time;
  final String selfId;
  final String noticeType;
  final String? subType;
  final String? userId;
  final String? groupId;
  final String? operatorId;
  final String? targetId;
  final int? duration;
  final OneBotFileInfo? file;
  final int? messageId;
  final String? honorType;

  factory OneBotNoticeEvent.fromJson(Map<String, dynamic> json) {
    return OneBotNoticeEvent(
      time: json['time'] as int,
      selfId: '${json['self_id']}',
      noticeType: json['notice_type'] as String,
      subType: json['sub_type'] as String?,
      userId: json['user_id']?.toString(),
      groupId: json['group_id']?.toString(),
      operatorId: json['operator_id']?.toString(),
      targetId: json['target_id']?.toString(),
      duration: json['duration'] as int?,
      file: json['file'] != null
          ? OneBotFileInfo.fromJson(json['file'] as Map<String, dynamic>)
          : null,
      messageId: json['message_id'] as int?,
      honorType: json['honor_type'] as String?,
    );
  }
}

class OneBotRequestEvent {
  const OneBotRequestEvent({
    required this.time,
    required this.selfId,
    required this.requestType,
    this.subType,
    this.userId,
    this.groupId,
    this.comment,
    this.flag,
  });

  final int time;
  final String selfId;
  final String requestType;
  final String? subType;
  final String? userId;
  final String? groupId;
  final String? comment;
  final String? flag;

  factory OneBotRequestEvent.fromJson(Map<String, dynamic> json) {
    return OneBotRequestEvent(
      time: json['time'] as int,
      selfId: '${json['self_id']}',
      requestType: json['request_type'] as String,
      subType: json['sub_type'] as String?,
      userId: json['user_id']?.toString(),
      groupId: json['group_id']?.toString(),
      comment: json['comment'] as String?,
      flag: json['flag'] as String?,
    );
  }
}

class OneBotMetaEvent {
  const OneBotMetaEvent({
    required this.time,
    required this.selfId,
    required this.metaEventType,
    this.subType,
    this.status,
    this.version,
    this.interval,
  });

  final int time;
  final String selfId;
  final String metaEventType;
  final String? subType;
  final Map<String, dynamic>? status;
  final Map<String, dynamic>? version;
  final int? interval;

  factory OneBotMetaEvent.fromJson(Map<String, dynamic> json) {
    return OneBotMetaEvent(
      time: json['time'] as int,
      selfId: '${json['self_id']}',
      metaEventType: json['meta_event_type'] as String,
      subType: json['sub_type'] as String?,
      status: json['status'] as Map<String, dynamic>?,
      version: json['version'] as Map<String, dynamic>?,
      interval: json['interval'] as int?,
    );
  }
}

/// Union-type container for any OneBot event.
sealed class OneBotEvent {
  const OneBotEvent();
}

class OneBotMessageEvent extends OneBotEvent {
  const OneBotMessageEvent(this.event) : _raw = null;

  const OneBotMessageEvent._raw(this._raw, {OneBotPrivateMessageEvent? private})
      : event = private;

  final OneBotPrivateMessageEvent? event;
  final Map<String, dynamic>? _raw;

  bool get isPrivate => event != null;
  bool get isGroup => _raw != null;

  OneBotGroupMessageEvent? get groupEvent {
    if (_raw == null) return null;
    return OneBotGroupMessageEvent.fromJson(_raw);
  }

  factory OneBotMessageEvent.fromJson(Map<String, dynamic> json) {
    final messageType = json['message_type'] as String?;
    if (messageType == 'private') {
      return OneBotMessageEvent(
        OneBotPrivateMessageEvent.fromJson(json),
      );
    }
    return OneBotMessageEvent._raw(json);
  }
}

class OneBotNoticeEventWrapper extends OneBotEvent {
  const OneBotNoticeEventWrapper(this.event);
  final OneBotNoticeEvent event;
}

class OneBotRequestEventWrapper extends OneBotEvent {
  const OneBotRequestEventWrapper(this.event);
  final OneBotRequestEvent event;
}

class OneBotMetaEventWrapper extends OneBotEvent {
  const OneBotMetaEventWrapper(this.event);
  final OneBotMetaEvent event;
}

// ---------------------------------------------------------------------------
// Anonymous
// ---------------------------------------------------------------------------

class OneBotAnonymous {
  const OneBotAnonymous({
    required this.id,
    required this.name,
    required this.flag,
  });

  final int id;
  final String name;
  final String flag;

  factory OneBotAnonymous.fromJson(Map<String, dynamic> json) {
    return OneBotAnonymous(
      id: json['id'] as int,
      name: json['name'] as String,
      flag: json['flag'] as String,
    );
  }
}

// ---------------------------------------------------------------------------
// File info (for group_upload notice)
// ---------------------------------------------------------------------------

class OneBotFileInfo {
  const OneBotFileInfo({
    required this.id,
    required this.name,
    required this.size,
    required this.busid,
  });

  final String id;
  final String name;
  final int size;
  final int busid;

  factory OneBotFileInfo.fromJson(Map<String, dynamic> json) {
    return OneBotFileInfo(
      id: json['id'] as String,
      name: json['name'] as String,
      size: json['size'] as int,
      busid: json['busid'] as int,
    );
  }
}

// ---------------------------------------------------------------------------
// Quick operation types (HTTP POST response / .handle_quick_operation)
// ---------------------------------------------------------------------------

/// Quick operations that can be returned as a response to a private-message
/// event (HTTP POST) or sent via [.handle_quick_operation].
class OneBotPrivateMessageQuickOp {
  const OneBotPrivateMessageQuickOp({
    this.reply,
    this.autoEscape = false,
  });

  final dynamic reply; // message type
  final bool autoEscape;

  Map<String, dynamic> toJson() => {
        if (reply != null) 'reply': reply,
        if (autoEscape) 'auto_escape': autoEscape,
      };
}

class OneBotGroupMessageQuickOp {
  const OneBotGroupMessageQuickOp({
    this.reply,
    this.autoEscape = false,
    this.atSender = true,
    this.delete = false,
    this.kick = false,
    this.ban = false,
    this.banDuration = 30 * 60,
  });

  final dynamic reply;
  final bool autoEscape;
  final bool atSender;
  final bool delete;
  final bool kick;
  final bool ban;
  final int banDuration;

  Map<String, dynamic> toJson() => {
        if (reply != null) 'reply': reply,
        if (autoEscape) 'auto_escape': autoEscape,
        if (!atSender) 'at_sender': atSender,
        if (delete) 'delete': delete,
        if (kick) 'kick': kick,
        if (ban) 'ban': ban,
        if (ban) 'ban_duration': banDuration,
      };
}

class OneBotFriendRequestQuickOp {
  const OneBotFriendRequestQuickOp({
    this.approve,
    this.remark,
  });

  final bool? approve;
  final String? remark;

  Map<String, dynamic> toJson() => {
        if (approve != null) 'approve': approve,
        if (remark != null) 'remark': remark,
      };
}

class OneBotGroupRequestQuickOp {
  const OneBotGroupRequestQuickOp({
    this.approve,
    this.reason,
  });

  final bool? approve;
  final String? reason;

  Map<String, dynamic> toJson() => {
        if (approve != null) 'approve': approve,
        if (reason != null) 'reason': reason,
      };
}

// ---------------------------------------------------------------------------
// API response
// ---------------------------------------------------------------------------

class OneBotApiResponse<T> {
  const OneBotApiResponse({
    required this.status,
    required this.retcode,
    required this.data,
    this.echo,
  });

  final String status;
  final int retcode;
  final T? data;
  final dynamic echo;

  bool get isOk => status == 'ok' && retcode == 0;

  factory OneBotApiResponse.fromJson(
    Map<String, dynamic> json, {
    T Function(dynamic)? fromData,
    required dynamic Function() echoFrom,
  }) {
    return OneBotApiResponse(
      status: json['status'] as String,
      retcode: json['retcode'] as int,
      data: json['data'] != null && fromData != null
          ? fromData(json['data'])
          : null,
      echo: echoFrom(),
    );
  }
}

// ---------------------------------------------------------------------------
// API result data types
// ---------------------------------------------------------------------------

class OneBotLoginInfo {
  const OneBotLoginInfo({required this.userId, required this.nickname});
  final String userId;
  final String nickname;

  factory OneBotLoginInfo.fromJson(Map<String, dynamic> json) => OneBotLoginInfo(
        userId: '${json['user_id']}',
        nickname: (json['nickname'] as String?) ?? '',
      );
}

class OneBotStrangerInfo {
  const OneBotStrangerInfo({
    required this.userId,
    required this.nickname,
    required this.sex,
    required this.age,
  });
  final String userId;
  final String nickname;
  final String sex;
  final int age;

  factory OneBotStrangerInfo.fromJson(Map<String, dynamic> json) =>
      OneBotStrangerInfo(
        userId: '${json['user_id']}',
        nickname: (json['nickname'] as String?) ?? '',
        sex: json['sex'] as String? ?? 'unknown',
        age: json['age'] as int? ?? 0,
      );
}

class OneBotFriendInfo {
  const OneBotFriendInfo({
    required this.userId,
    required this.nickname,
    required this.remark,
  });
  final String userId;
  final String nickname;
  final String remark;

  factory OneBotFriendInfo.fromJson(Map<String, dynamic> json) =>
      OneBotFriendInfo(
        userId: '${json['user_id']}',
        nickname: (json['nickname'] as String?) ?? '',
        remark: (json['remark'] as String?) ?? '',
      );
}

class OneBotGroupInfo {
  const OneBotGroupInfo({
    required this.groupId,
    required this.groupName,
    required this.memberCount,
    required this.maxMemberCount,
  });
  final String groupId;
  final String groupName;
  final int memberCount;
  final int maxMemberCount;

  factory OneBotGroupInfo.fromJson(Map<String, dynamic> json) =>
      OneBotGroupInfo(
        groupId: '${json['group_id']}',
        groupName: (json['group_name'] as String?) ?? '',
        memberCount: json['member_count'] as int? ?? 0,
        maxMemberCount: json['max_member_count'] as int? ?? 0,
      );
}

class OneBotGroupMemberInfo {
  const OneBotGroupMemberInfo({
    required this.groupId,
    required this.userId,
    required this.nickname,
    this.card,
    this.sex,
    this.age,
    this.area,
    this.joinTime,
    this.lastSentTime,
    this.level,
    this.role,
    this.unfriendly,
    this.title,
    this.titleExpireTime,
    this.cardChangeable,
  });
  final String groupId;
  final String userId;
  final String nickname;
  final String? card;
  final String? sex;
  final int? age;
  final String? area;
  final int? joinTime;
  final int? lastSentTime;
  final String? level;
  final String? role;
  final bool? unfriendly;
  final String? title;
  final int? titleExpireTime;
  final bool? cardChangeable;

  factory OneBotGroupMemberInfo.fromJson(Map<String, dynamic> json) =>
      OneBotGroupMemberInfo(
        groupId: '${json['group_id']}',
        userId: '${json['user_id']}',
        nickname: (json['nickname'] as String?) ?? '',
        card: json['card'] as String?,
        sex: json['sex'] as String?,
        age: json['age'] as int?,
        area: json['area'] as String?,
        joinTime: json['join_time'] as int?,
        lastSentTime: json['last_sent_time'] as int?,
        level: json['level'] as String?,
        role: json['role'] as String?,
        unfriendly: json['unfriendly'] as bool?,
        title: json['title'] as String?,
        titleExpireTime: json['title_expire_time'] as int?,
        cardChangeable: json['card_changeable'] as bool?,
      );
}

class OneBotGroupHonorInfo {
  const OneBotGroupHonorInfo({
    required this.groupId,
    this.currentTalkative,
    this.talkativeList,
    this.performerList,
    this.legendList,
    this.strongNewbieList,
    this.emotionList,
  });
  final String groupId;
  final OneBotHonorUser? currentTalkative;
  final List<OneBotHonorUser>? talkativeList;
  final List<OneBotHonorUser>? performerList;
  final List<OneBotHonorUser>? legendList;
  final List<OneBotHonorUser>? strongNewbieList;
  final List<OneBotHonorUser>? emotionList;

  factory OneBotGroupHonorInfo.fromJson(Map<String, dynamic> json) =>
      OneBotGroupHonorInfo(
        groupId: '${json['group_id']}',
        currentTalkative: json['current_talkative'] != null
            ? OneBotHonorUser.fromJson(
                json['current_talkative'] as Map<String, dynamic>)
            : null,
        talkativeList: _listOrNull(json['talkative_list'], OneBotHonorUser.fromJson),
        performerList: _listOrNull(json['performer_list'], OneBotHonorUser.fromJson),
        legendList: _listOrNull(json['legend_list'], OneBotHonorUser.fromJson),
        strongNewbieList:
            _listOrNull(json['strong_newbie_list'], OneBotHonorUser.fromJson),
        emotionList: _listOrNull(json['emotion_list'], OneBotHonorUser.fromJson),
      );
}

class OneBotHonorUser {
  const OneBotHonorUser({
    required this.userId,
    required this.nickname,
    required this.avatar,
    this.description,
    this.dayCount,
  });
  final String userId;
  final String nickname;
  final String avatar;
  final String? description;
  final int? dayCount;

  factory OneBotHonorUser.fromJson(Map<String, dynamic> json) =>
      OneBotHonorUser(
        userId: '${json['user_id']}',
        nickname: (json['nickname'] as String?) ?? '',
        avatar: (json['avatar'] as String?) ?? '',
        description: json['description'] as String?,
        dayCount: json['day_count'] as int?,
      );
}

class OneBotCredentials {
  const OneBotCredentials({required this.cookies, required this.csrfToken});
  final String cookies;
  final int csrfToken;

  factory OneBotCredentials.fromJson(Map<String, dynamic> json) =>
      OneBotCredentials(
        cookies: (json['cookies'] as String?) ?? '',
        csrfToken: json['csrf_token'] as int? ?? 0,
      );
}

class OneBotVersionInfo {
  const OneBotVersionInfo({
    required this.appName,
    required this.appVersion,
    required this.protocolVersion,
  });
  final String appName;
  final String appVersion;
  final String protocolVersion;

  factory OneBotVersionInfo.fromJson(Map<String, dynamic> json) =>
      OneBotVersionInfo(
        appName: (json['app_name'] as String?) ?? '',
        appVersion: (json['app_version'] as String?) ?? '',
        protocolVersion: (json['protocol_version'] as String?) ?? '',
      );
}

class OneBotStatusInfo {
  const OneBotStatusInfo({required this.online, required this.good});
  final bool? online;
  final bool good;

  factory OneBotStatusInfo.fromJson(Map<String, dynamic> json) =>
      OneBotStatusInfo(
        online: json['online'] as bool?,
        good: json['good'] as bool? ?? false,
      );
}

class OneBotFileResult {
  const OneBotFileResult({required this.file});
  final String file;

  factory OneBotFileResult.fromJson(Map<String, dynamic> json) =>
      OneBotFileResult(file: json['file'] as String? ?? '');
}

class OneBotMsgResult {
  const OneBotMsgResult({required this.messageId});
  final int messageId;

  factory OneBotMsgResult.fromJson(Map<String, dynamic> json) =>
      OneBotMsgResult(messageId: json['message_id'] as int);
}

class OneBotGetMsgResult {
  const OneBotGetMsgResult({
    required this.time,
    required this.messageType,
    required this.messageId,
    required this.realId,
    required this.sender,
    required this.message,
  });
  final int time;
  final String messageType;
  final int messageId;
  final int realId;
  final OneBotSender sender;
  final List<OneBotMessageSegment> message;

  factory OneBotGetMsgResult.fromJson(Map<String, dynamic> json) =>
      OneBotGetMsgResult(
        time: json['time'] as int,
        messageType: json['message_type'] as String,
        messageId: json['message_id'] as int,
        realId: json['real_id'] as int,
        sender: OneBotSender.fromJson(json['sender'] as Map<String, dynamic>),
        message: _parseMessage(json['message']),
      );
}

class OneBotForwardResult {
  const OneBotForwardResult({required this.message});
  final List<OneBotMessageSegment> message;

  factory OneBotForwardResult.fromJson(Map<String, dynamic> json) =>
      OneBotForwardResult(message: _parseMessage(json['message']));
}

class OneBotCanSendResult {
  const OneBotCanSendResult({required this.yes});
  final bool yes;

  factory OneBotCanSendResult.fromJson(Map<String, dynamic> json) =>
      OneBotCanSendResult(yes: json['yes'] as bool? ?? false);
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

List<OneBotMessageSegment> _parseMessage(dynamic message) {
  if (message is List) {
    return oneBotChainFromJson(message);
  }
  if (message is String) {
    // String format — the OneBot server sent plain text
    if (message.isEmpty) return [];
    return [OneBotMessageSegment.plain(message)];
  }
  return [];
}

List<T>? _listOrNull<T>(dynamic json, T Function(Map<String, dynamic>) fromJson) {
  if (json == null) return null;
  final list = json as List<dynamic>;
  return list
      .map((e) => fromJson(e as Map<String, dynamic>))
      .toList();
}
