/// OneBot v11 / v12 protocol data structures.
///
/// Reference: https://github.com/botuniverse/onebot-11
library;

enum OneBotPostType { message, notice, request, metaEvent }

enum OneBotMessageType { private, group }

enum OneBotNoticeType {
  groupUpload,
  groupAdmin,
  groupDecrease,
  groupIncrease,
  groupBan,
  friendAdd,
  groupRecall,
  friendRecall,
  poke,
  luckyKing,
  honor,
}

enum OneBotWsMode { forward, reverse }

class OneBotConnectionConfig {
  const OneBotConnectionConfig({
    required this.selfId,
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

class OneBotSender {
  const OneBotSender({
    required this.userId,
    required this.nickname,
    this.sex,
    this.age,
    this.card,
    this.role,
    this.title,
  });

  final String userId;
  final String nickname;
  final String? sex;
  final int? age;
  final String? card;
  final String? role;
  final String? title;

  factory OneBotSender.fromJson(Map<String, dynamic> json) {
    return OneBotSender(
      userId: '${json['user_id']}',
      nickname: json['nickname'] as String? ?? '',
      sex: json['sex'] as String?,
      age: json['age'] as int?,
      card: json['card'] as String?,
      role: json['role'] as String?,
      title: json['title'] as String?,
    );
  }
}

/// A single segment in a OneBot message chain (text, image, at, face, etc.).
class OneBotMessageSegment {
  const OneBotMessageSegment({required this.type, required this.data});

  final String type;
  final Map<String, dynamic> data;

  factory OneBotMessageSegment.fromJson(Map<String, dynamic> json) {
    return OneBotMessageSegment(
      type: json['type'] as String,
      data: Map<String, dynamic>.from(json['data'] as Map),
    );
  }

  Map<String, dynamic> toJson() => {'type': type, 'data': data};

  /// Convenience: extract plain text from a `text` segment.
  String? get text => type == 'text' ? data['text'] as String? : null;
}

class OneBotPrivateMessageEvent {
  const OneBotPrivateMessageEvent({
    required this.time,
    required this.selfId,
    required this.messageId,
    required this.userId,
    required this.message,
    required this.rawMessage,
    required this.sender,
  });

  final int time;
  final String selfId;
  final int messageId;
  final String userId;
  final List<OneBotMessageSegment> message;
  final String rawMessage;
  final OneBotSender sender;

  String get plainText =>
      message.map((s) => s.text ?? '').join();

  factory OneBotPrivateMessageEvent.fromJson(Map<String, dynamic> json) {
    return OneBotPrivateMessageEvent(
      time: json['time'] as int,
      selfId: '${json['self_id']}',
      messageId: json['message_id'] as int,
      userId: '${json['user_id']}',
      message: (json['message'] as List<dynamic>)
          .map(
            (s) => OneBotMessageSegment.fromJson(s as Map<String, dynamic>),
          )
          .toList(),
      rawMessage: json['raw_message'] as String? ?? '',
      sender: OneBotSender.fromJson(json['sender'] as Map<String, dynamic>),
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
  });

  final int time;
  final String selfId;
  final int messageId;
  final String groupId;
  final String userId;
  final List<OneBotMessageSegment> message;
  final String rawMessage;
  final OneBotSender sender;

  String get plainText =>
      message.map((s) => s.text ?? '').join();

  factory OneBotGroupMessageEvent.fromJson(Map<String, dynamic> json) {
    return OneBotGroupMessageEvent(
      time: json['time'] as int,
      selfId: '${json['self_id']}',
      messageId: json['message_id'] as int,
      groupId: '${json['group_id']}',
      userId: '${json['user_id']}',
      message: (json['message'] as List<dynamic>)
          .map(
            (s) => OneBotMessageSegment.fromJson(s as Map<String, dynamic>),
          )
          .toList(),
      rawMessage: json['raw_message'] as String? ?? '',
      sender: OneBotSender.fromJson(json['sender'] as Map<String, dynamic>),
    );
  }
}

class OneBotNoticeEvent {
  const OneBotNoticeEvent({
    required this.time,
    required this.selfId,
    required this.noticeType,
    this.userId,
    this.groupId,
    this.operatorId,
  });

  final int time;
  final String selfId;
  final String noticeType;
  final String? userId;
  final String? groupId;
  final String? operatorId;

  factory OneBotNoticeEvent.fromJson(Map<String, dynamic> json) {
    return OneBotNoticeEvent(
      time: json['time'] as int,
      selfId: '${json['self_id']}',
      noticeType: json['notice_type'] as String,
      userId: json['user_id']?.toString(),
      groupId: json['group_id']?.toString(),
      operatorId: json['operator_id']?.toString(),
    );
  }
}

class OneBotApiResponse<T> {
  const OneBotApiResponse({
    required this.status,
    required this.retcode,
    required this.data,
  });

  final String status;
  final int retcode;
  final T? data;

  bool get isOk => status == 'ok' && retcode == 0;

  factory OneBotApiResponse.fromJson(
    Map<String, dynamic> json,
    T Function(dynamic)? fromData,
  ) {
    return OneBotApiResponse(
      status: json['status'] as String,
      retcode: json['retcode'] as int,
      data: json['data'] != null && fromData != null
          ? fromData(json['data'])
          : null,
    );
  }
}
