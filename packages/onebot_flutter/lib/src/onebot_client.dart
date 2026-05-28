import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'onebot_models.dart';

/// Connection state for a [OneBotClient].
enum OneBotConnectionStatus { disconnected, connecting, connected, failed }

/// Signature for log callbacks on [OneBotClient].
typedef OneBotLogCallback = void Function(String tag, String message);

/// An event-driven client for the OneBot v11 protocol.
class OneBotClient {
  OneBotClient({required this.config, this.onLog});

  final OneBotConfig config;

  /// Optional callback for debug logging (API calls, events, transport).
  final OneBotLogCallback? onLog;

  // -----------------------------------------------------------------------
  // Public streams
  // -----------------------------------------------------------------------

  final _statusController =
      StreamController<OneBotConnectionStatus>.broadcast();
  final _eventController = StreamController<OneBotEvent>.broadcast();
  final _echoCompleters = <dynamic, Completer<OneBotApiResponse>>{};
  int _echoCounter = 0;

  Stream<OneBotConnectionStatus> get statusStream => _statusController.stream;
  Stream<OneBotEvent> get eventStream => _eventController.stream;
  OneBotConnectionStatus get currentStatus => _currentStatus;
  OneBotConnectionStatus _currentStatus = OneBotConnectionStatus.disconnected;

  // Internal transport
  WebSocket? _ws;
  HttpServer? _wsServer;
  HttpServer? _httpPostServer;
  String? _httpPostSecret;
  StreamSubscription? _wsSubscription;
  StreamSubscription? _serverSubscription;
  HttpClient? _httpClient;

  // -----------------------------------------------------------------------
  // Lifecycle
  // -----------------------------------------------------------------------

  /// Establish a connection based on [config].
  ///
  /// In forward mode opens a WebSocket to [OneBotConfig.wsEndpoint].
  /// In reverse mode binds an [HttpServer] and upgrades incoming requests.
  /// Falls back to HTTP if no WS endpoint is configured.
  Future<void> connect() async {
    if (_currentStatus == OneBotConnectionStatus.connected ||
        _currentStatus == OneBotConnectionStatus.connecting) {
      return;
    }

    _setStatus(OneBotConnectionStatus.connecting);

    try {
      final wsUrl = config.wsEndpoint;
      if (wsUrl != null && wsUrl.isNotEmpty) {
        if (config.wsMode == OneBotWsMode.reverse) {
          await _startReverseWs(wsUrl);
        } else {
          await _startForwardWs(wsUrl);
        }
      }
      _setStatus(OneBotConnectionStatus.connected);
    } catch (_) {
      _setStatus(OneBotConnectionStatus.failed);
      rethrow;
    }
  }

  /// Release the connection and all resources.
  void disconnect() {
    _wsSubscription?.cancel();
    _ws?.close();
    _serverSubscription?.cancel();
    _wsServer?.close();
    _httpPostServer?.close();
    _httpClient?.close();
    _setStatus(OneBotConnectionStatus.disconnected);
    for (final c in _echoCompleters.values) {
      if (!c.isCompleted) {
        c.completeError(const OneBotException('Client disconnected'));
      }
    }
    _echoCompleters.clear();
  }

  /// Verify connectivity. Returns null on success or an error message.
  Future<String?> testConnection() async {
    final wsUrl = config.wsEndpoint;
    if (wsUrl == null || wsUrl.isEmpty) {
      return 'No WebSocket endpoint configured';
    }

    try {
      if (config.wsMode == OneBotWsMode.reverse) {
        final uri = Uri.parse(wsUrl);
        final host = uri.host.isNotEmpty ? uri.host : '127.0.0.1';
        final port = uri.port != 0 ? uri.port : 6199;
        final server = await HttpServer.bind(InternetAddress(host), port);
        await server.close();
      } else {
        final ws = await WebSocket.connect(
          wsUrl,
          headers: _authHeaders(),
        ).timeout(const Duration(seconds: 5));
        await ws.close();
      }
      return null;
    } on TimeoutException {
      return 'Connection timed out after 5s';
    } on SocketException catch (e) {
      return 'Socket error: ${e.message}';
    } on HandshakeException catch (e) {
      return 'Handshake failed: ${e.message}';
    } catch (e) {
      return 'Connection failed: $e';
    }
  }

  /// Start an HTTP server to receive OneBot events via HTTP POST.
  ///
  /// OneBot pushes events as POST requests with JSON bodies. The server
  /// parses incoming events and feeds them into [eventStream]. Responds with
  /// 204 No Content (no quick operation) by default.
  ///
  /// Set [secret] to enable HMAC SHA1 verification of the `X-Signature`
  /// header on each request. Invalid signatures are rejected with 403.
  ///
  /// [quickOpCallback] can return a quick-operation map (e.g. `{"reply":
  /// "got it"}`) which will be sent back as the HTTP response body; return
  /// `null` to send 204 instead.
  Future<HttpServer> listenForHttpPostEvents({
    String host = '127.0.0.1',
    int port = 8080,
    String? secret,
    FutureOr<Map<String, dynamic>?> Function(
      OneBotEvent event,
      Map<String, dynamic> raw,
    )?
    quickOpCallback,
  }) async {
    _httpPostSecret = secret;
    _httpPostServer = await HttpServer.bind(InternetAddress(host), port);
    _httpPostServer!.listen((request) async {
      try {
        if (request.method != 'POST') {
          request.response
            ..statusCode = HttpStatus.methodNotAllowed
            ..close();
          return;
        }

        // Verify HMAC signature if a secret is configured.
        if (_httpPostSecret != null && _httpPostSecret!.isNotEmpty) {
          if (!await _verifyHmacSignature(request)) {
            request.response
              ..statusCode = HttpStatus.forbidden
              ..close();
            return;
          }
        }

        final body = await utf8.decoder.bind(request).join();
        final json = jsonDecode(body) as Map<String, dynamic>;

        // Dispatch event.
        final postType = json['post_type'] as String?;
        if (postType != null) {
          OneBotEvent? event;
          switch (postType) {
            case 'message':
              event = OneBotMessageEvent.fromJson(json);
            case 'notice':
              event = OneBotNoticeEventWrapper(
                OneBotNoticeEvent.fromJson(json),
              );
            case 'request':
              event = OneBotRequestEventWrapper(
                OneBotRequestEvent.fromJson(json),
              );
            case 'meta_event':
              event = OneBotMetaEventWrapper(
                OneBotMetaEvent.fromJson(json),
              );
          }

          if (event != null) {
            _eventController.add(event);

            // Handle quick operation callback.
            if (quickOpCallback != null) {
              final op = await quickOpCallback(event, json);
              if (op != null && op.isNotEmpty) {
                request.response
                  ..statusCode = HttpStatus.ok
                  ..headers.contentType = ContentType.json
                  ..write(jsonEncode(op));
                await request.response.close();
                return;
              }
            }
          }
        }

        request.response
          ..statusCode = HttpStatus.noContent
          ..close();
      } catch (_) {
        // Avoid crashing the server on malformed requests.
        try {
          request.response
            ..statusCode = HttpStatus.badRequest
            ..close();
        } catch (_) {}
      }
    });
    return _httpPostServer!;
  }

  /// Stop a previously started HTTP POST server.
  Future<void> stopHttpPostServer() async {
    await _httpPostServer?.close();
    _httpPostServer = null;
  }

  Future<bool> _verifyHmacSignature(HttpRequest request) async {
    final sigHeader = request.headers.value('x-signature');
    if (sigHeader == null || !sigHeader.startsWith('sha1=')) return false;
    final receivedSig = sigHeader.substring(5);

    final bytes = await request.fold<List<int>>(
      <int>[],
      (prev, chunk) => prev..addAll(chunk),
    );

    final hmac = Hmac(sha1, utf8.encode(_httpPostSecret!));
    final digest = hmac.convert(bytes);
    return digest.toString() == receivedSig;
  }

  // -----------------------------------------------------------------------
  // Transport: forward WS
  // -----------------------------------------------------------------------

  Future<void> _startForwardWs(String wsUrl) async {
    _ws = await WebSocket.connect(wsUrl, headers: _authHeaders());
    _wsSubscription = _ws!.listen(
      (data) {
        if (data is String) _onMessage(data);
      },
      onError: (_) => _setStatus(OneBotConnectionStatus.failed),
      onDone: () => _setStatus(OneBotConnectionStatus.disconnected),
    );
  }

  // -----------------------------------------------------------------------
  // Transport: reverse WS
  // -----------------------------------------------------------------------

  Future<void> _startReverseWs(String listenUrl) async {
    final uri = Uri.parse(listenUrl);
    final host = uri.host.isNotEmpty ? uri.host : '127.0.0.1';
    final port = uri.port != 0 ? uri.port : 6199;
    final path = uri.path.isNotEmpty ? uri.path : '/ws';

    _wsServer = await HttpServer.bind(InternetAddress(host), port);
    _serverSubscription = _wsServer!.listen((request) async {
      if (request.uri.path != path) {
        request.response
          ..statusCode = HttpStatus.notFound
          ..close();
        return;
      }

      // Check access token in Authorization header or query parameter.
      final token = config.accessToken;
      if (token != null && token.isNotEmpty) {
        final auth = request.headers.value('Authorization');
        final queryToken = request.uri.queryParameters['access_token'];
        if (auth != 'Bearer $token' && queryToken != token) {
          request.response
            ..statusCode = HttpStatus.unauthorized
            ..close();
          return;
        }
      }

      // Parse X-Client-Role header (API, Event, Universal).
      final role = request.headers.value('x-client-role') ?? 'Universal';

      final socket = await WebSocketTransformer.upgrade(request);
      socket.listen(
        (data) {
          if (data is String) {
            switch (role.toLowerCase()) {
              case 'api':
                _onApiMessage(data);
              case 'event':
                _onEventMessage(data);
              default:
                _onMessage(data);
            }
          }
        },
        onError: (_) {},
        onDone: () {},
      );
    });
  }

  /// Parses only API responses (echo completers), suppressing event dispatch.
  void _onApiMessage(String raw) {
    Map<String, dynamic>? json;
    try {
      json = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    if (json.containsKey('echo') && json['echo'] != null) {
      final echo = json['echo'];
      final completer = _echoCompleters.remove(echo);
      if (completer != null && !completer.isCompleted) {
        completer.complete(OneBotApiResponse(
          status: json['status'] as String? ?? 'failed',
          retcode: json['retcode'] as int? ?? -1,
          data: json['data'],
          echo: echo,
        ));
      }
    }
  }

  /// Parses only events, suppressing echo-completer handling.
  void _onEventMessage(String raw) {
    Map<String, dynamic>? json;
    try {
      json = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    final postType = json['post_type'] as String?;
    if (postType == null) return;
    switch (postType) {
      case 'message':
        _eventController.add(OneBotMessageEvent.fromJson(json));
      case 'notice':
        _eventController.add(
          OneBotNoticeEventWrapper(OneBotNoticeEvent.fromJson(json)),
        );
      case 'request':
        _eventController.add(
          OneBotRequestEventWrapper(OneBotRequestEvent.fromJson(json)),
        );
      case 'meta_event':
        _eventController.add(
          OneBotMetaEventWrapper(OneBotMetaEvent.fromJson(json)),
        );
    }
  }

  // -----------------------------------------------------------------------
  // HTTP helpers
  // -----------------------------------------------------------------------

  Map<String, dynamic> _authHeaders() {
    final h = <String, dynamic>{};
    final token = config.accessToken;
    if (token != null && token.isNotEmpty) {
      h['Authorization'] = 'Bearer $token';
    }
    return h;
  }

  // -----------------------------------------------------------------------
  // Message dispatch
  // -----------------------------------------------------------------------

  void _onMessage(String raw) {
    Map<String, dynamic>? json;
    try {
      json = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return;
    }

    // Check if it's a response to a pending echo
    if (json.containsKey('echo') && json['echo'] != null) {
      final echo = json['echo'];
      final completer = _echoCompleters.remove(echo);
      if (completer != null && !completer.isCompleted) {
        completer.complete(OneBotApiResponse(
          status: json['status'] as String? ?? 'failed',
          retcode: json['retcode'] as int? ?? -1,
          data: json['data'],
          echo: echo,
        ));
        return;
      }
    }

    // It's an event
    final postType = json['post_type'] as String?;
    if (postType == null) return;

    onLog?.call('EVENT', _eventSummary(json));

    switch (postType) {
      case 'message':
        _eventController.add(OneBotMessageEvent.fromJson(json));
      case 'notice':
        _eventController.add(
          OneBotNoticeEventWrapper(OneBotNoticeEvent.fromJson(json)),
        );
      case 'request':
        _eventController.add(
          OneBotRequestEventWrapper(OneBotRequestEvent.fromJson(json)),
        );
      case 'meta_event':
        _eventController.add(
          OneBotMetaEventWrapper(OneBotMetaEvent.fromJson(json)),
        );
    }
  }

  void _setStatus(OneBotConnectionStatus s) {
    _currentStatus = s;
    _statusController.add(s);
  }

  // -----------------------------------------------------------------------
  // Low-level API call
  // -----------------------------------------------------------------------

  /// Send a raw API action and await the response.
  ///
  /// Uses WebSocket if connected, otherwise HTTP POST.
  Future<OneBotApiResponse> callApi(
    String action,
    Map<String, dynamic>? params,
  ) async {
    if (_ws != null && _currentStatus == OneBotConnectionStatus.connected) {
      return _callViaWs(action, params);
    }
    if (config.httpEndpoint != null && config.httpEndpoint!.isNotEmpty) {
      return _callViaHttp(action, params);
    }
    throw const OneBotException(
      'Not connected. Call connect() first or configure an HTTP endpoint.',
    );
  }

  Future<OneBotApiResponse> _callViaWs(
    String action,
    Map<String, dynamic>? params,
  ) async {
    final echo = '${++_echoCounter}';
    final payload = <String, dynamic>{
      'action': action,
      'echo': echo,
    };
    if (params != null && params.isNotEmpty) {
      payload['params'] = params;
    }

    final completer = Completer<OneBotApiResponse>();
    _echoCompleters[echo] = completer;
    final rawPayload = jsonEncode(payload);
    onLog?.call('API', '→ $action ${_truncateLog(rawPayload, 300)}');
    _ws!.add(rawPayload);

    return completer.future.then((r) {
      onLog?.call('API', '← $action ret=${r.retcode}');
      return r;
    }).timeout(
      const Duration(seconds: 30),
      onTimeout: () {
        _echoCompleters.remove(echo);
        throw TimeoutException('API call "$action" timed out after 30s');
      },
    );
  }

  Future<OneBotApiResponse> _callViaHttp(
    String action,
    Map<String, dynamic>? params,
  ) async {
    _httpClient ??= HttpClient();
    final uri = Uri.parse('${config.httpEndpoint}/$action');
    final request = await _httpClient!.postUrl(uri);
    final token = config.accessToken;
    if (token != null && token.isNotEmpty) {
      request.headers.set('Authorization', 'Bearer $token');
    }
    request.headers.set('Content-Type', 'application/json');
    final rawParams = jsonEncode(params ?? {});
    onLog?.call('API', '→ HTTP $action ${_truncateLog(rawParams, 200)}');
    request.write(rawParams);
    final response = await request.close().timeout(
      const Duration(seconds: 30),
    );
    final body = await response.transform(utf8.decoder).join();
    final json = jsonDecode(body) as Map<String, dynamic>;
    return OneBotApiResponse(
      status: json['status'] as String? ?? 'failed',
      retcode: json['retcode'] as int? ?? response.statusCode,
      data: json['data'],
      echo: null,
    );
  }

  // -----------------------------------------------------------------------
  // --- Message API ---
  // -----------------------------------------------------------------------

  /// Send a private message.
  Future<int> sendPrivateMsg({
    required String userId,
    required List<OneBotMessageSegment> message,
    bool autoEscape = false,
  }) async {
    final r = await callApi('send_private_msg', {
      'user_id': userId,
      'message': oneBotChainToJson(message),
      if (autoEscape) 'auto_escape': autoEscape,
    });
    _checkResponse(r);
    return (r.data as Map<String, dynamic>)['message_id'] as int;
  }

  /// Send a group message.
  Future<int> sendGroupMsg({
    required String groupId,
    required List<OneBotMessageSegment> message,
    bool autoEscape = false,
  }) async {
    final r = await callApi('send_group_msg', {
      'group_id': groupId,
      'message': oneBotChainToJson(message),
      if (autoEscape) 'auto_escape': autoEscape,
    });
    _checkResponse(r);
    return (r.data as Map<String, dynamic>)['message_id'] as int;
  }

  /// Send a message (auto-detect private vs group).
  ///
  /// [messageType] can be `private` or `group`. When omitted, the type is
  /// inferred from whether [userId] or [groupId] is provided.
  Future<int> sendMsg({
    String? messageType,
    String? userId,
    String? groupId,
    required List<OneBotMessageSegment> message,
    bool autoEscape = false,
  }) async {
    final p = <String, dynamic>{
      'message': oneBotChainToJson(message),
      if (autoEscape) 'auto_escape': autoEscape,
    };
    if (messageType != null) p['message_type'] = messageType;
    if (groupId != null) p['group_id'] = groupId;
    if (userId != null) p['user_id'] = userId;
    final r = await callApi('send_msg', p);
    _checkResponse(r);
    return (r.data as Map<String, dynamic>)['message_id'] as int;
  }

  /// Delete (recall) a message.
  Future<void> deleteMsg(int messageId) async {
    final r = await callApi('delete_msg', {'message_id': messageId});
    _checkResponse(r);
  }

  /// Get a message by ID.
  Future<OneBotGetMsgResult> getMsg(int messageId) async {
    final r = await callApi('get_msg', {'message_id': messageId});
    _checkResponse(r);
    return OneBotGetMsgResult.fromJson(r.data as Map<String, dynamic>);
  }

  /// Get a forward message by ID.
  Future<OneBotForwardResult> getForwardMsg(String id) async {
    final r = await callApi('get_forward_msg', {'id': id});
    _checkResponse(r);
    return OneBotForwardResult.fromJson(r.data as Map<String, dynamic>);
  }

  /// Send a "like" to a user.
  Future<void> sendLike({required String userId, int times = 1}) async {
    final r = await callApi('send_like', {
      'user_id': userId,
      'times': times,
    });
    _checkResponse(r);
  }

  // -----------------------------------------------------------------------
  // --- Group management ---
  // -----------------------------------------------------------------------

  Future<void> setGroupKick({
    required String groupId,
    required String userId,
    bool rejectAddRequest = false,
  }) async {
    final r = await callApi('set_group_kick', {
      'group_id': groupId,
      'user_id': userId,
      'reject_add_request': rejectAddRequest,
    });
    _checkResponse(r);
  }

  Future<void> setGroupBan({
    required String groupId,
    required String userId,
    required int duration,
  }) async {
    final r = await callApi('set_group_ban', {
      'group_id': groupId,
      'user_id': userId,
      'duration': duration,
    });
    _checkResponse(r);
  }

  Future<void> setGroupAnonymousBan({
    required String groupId,
    OneBotAnonymous? anonymous,
    String? flag,
    int duration = 1800,
  }) async {
    final p = <String, dynamic>{
      'group_id': groupId,
      'duration': duration,
    };
    if (anonymous != null) {
      p['anonymous'] = {
        'id': anonymous.id,
        'name': anonymous.name,
        'flag': anonymous.flag,
      };
    } else if (flag != null) {
      p['flag'] = flag;
    }
    final r = await callApi('set_group_anonymous_ban', p);
    _checkResponse(r);
  }

  Future<void> setGroupWholeBan({
    required String groupId,
    bool enable = true,
  }) async {
    final r = await callApi('set_group_whole_ban', {
      'group_id': groupId,
      'enable': enable,
    });
    _checkResponse(r);
  }

  Future<void> setGroupAdmin({
    required String groupId,
    required String userId,
    bool enable = true,
  }) async {
    final r = await callApi('set_group_admin', {
      'group_id': groupId,
      'user_id': userId,
      'enable': enable,
    });
    _checkResponse(r);
  }

  Future<void> setGroupAnonymous({
    required String groupId,
    bool enable = true,
  }) async {
    final r = await callApi('set_group_anonymous', {
      'group_id': groupId,
      'enable': enable,
    });
    _checkResponse(r);
  }

  Future<void> setGroupCard({
    required String groupId,
    required String userId,
    String card = '',
  }) async {
    final r = await callApi('set_group_card', {
      'group_id': groupId,
      'user_id': userId,
      'card': card,
    });
    _checkResponse(r);
  }

  Future<void> setGroupName({
    required String groupId,
    required String groupName,
  }) async {
    final r = await callApi('set_group_name', {
      'group_id': groupId,
      'group_name': groupName,
    });
    _checkResponse(r);
  }

  Future<void> setGroupLeave({
    required String groupId,
    bool isDismiss = false,
  }) async {
    final r = await callApi('set_group_leave', {
      'group_id': groupId,
      'is_dismiss': isDismiss,
    });
    _checkResponse(r);
  }

  Future<void> setGroupSpecialTitle({
    required String groupId,
    required String userId,
    String specialTitle = '',
    int duration = -1,
  }) async {
    final r = await callApi('set_group_special_title', {
      'group_id': groupId,
      'user_id': userId,
      'special_title': specialTitle,
      'duration': duration,
    });
    _checkResponse(r);
  }

  // -----------------------------------------------------------------------
  // --- Request handling ---
  // -----------------------------------------------------------------------

  Future<void> setFriendAddRequest({
    required String flag,
    bool approve = true,
    String remark = '',
  }) async {
    final r = await callApi('set_friend_add_request', {
      'flag': flag,
      'approve': approve,
      'remark': remark,
    });
    _checkResponse(r);
  }

  Future<void> setGroupAddRequest({
    required String flag,
    required String subType,
    bool approve = true,
    String reason = '',
  }) async {
    final r = await callApi('set_group_add_request', {
      'flag': flag,
      'type': subType,
      'approve': approve,
      'reason': reason,
    });
    _checkResponse(r);
  }

  // -----------------------------------------------------------------------
  // --- Info retrieval ---
  // -----------------------------------------------------------------------

  Future<OneBotLoginInfo> getLoginInfo() async {
    final r = await callApi('get_login_info', null);
    _checkResponse(r);
    return OneBotLoginInfo.fromJson(r.data as Map<String, dynamic>);
  }

  Future<OneBotStrangerInfo> getStrangerInfo({
    required String userId,
    bool noCache = false,
  }) async {
    final r = await callApi('get_stranger_info', {
      'user_id': userId,
      'no_cache': noCache,
    });
    _checkResponse(r);
    return OneBotStrangerInfo.fromJson(r.data as Map<String, dynamic>);
  }

  Future<List<OneBotFriendInfo>> getFriendList() async {
    final r = await callApi('get_friend_list', null);
    _checkResponse(r);
    final list = r.data as List<dynamic>;
    return list
        .map((e) => OneBotFriendInfo.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<OneBotGroupInfo> getGroupInfo({
    required String groupId,
    bool noCache = false,
  }) async {
    final r = await callApi('get_group_info', {
      'group_id': groupId,
      'no_cache': noCache,
    });
    _checkResponse(r);
    return OneBotGroupInfo.fromJson(r.data as Map<String, dynamic>);
  }

  Future<List<OneBotGroupInfo>> getGroupList() async {
    final r = await callApi('get_group_list', null);
    _checkResponse(r);
    final list = r.data as List<dynamic>;
    return list
        .map((e) => OneBotGroupInfo.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<OneBotGroupMemberInfo> getGroupMemberInfo({
    required String groupId,
    required String userId,
    bool noCache = false,
  }) async {
    final r = await callApi('get_group_member_info', {
      'group_id': groupId,
      'user_id': userId,
      'no_cache': noCache,
    });
    _checkResponse(r);
    return OneBotGroupMemberInfo.fromJson(r.data as Map<String, dynamic>);
  }

  Future<List<OneBotGroupMemberInfo>> getGroupMemberList({
    required String groupId,
  }) async {
    final r = await callApi('get_group_member_list', {
      'group_id': groupId,
    });
    _checkResponse(r);
    final list = r.data as List<dynamic>;
    return list
        .map(
          (e) => OneBotGroupMemberInfo.fromJson(e as Map<String, dynamic>),
        )
        .toList();
  }

  Future<OneBotGroupHonorInfo> getGroupHonorInfo({
    required String groupId,
    String type = 'all',
  }) async {
    final r = await callApi('get_group_honor_info', {
      'group_id': groupId,
      'type': type,
    });
    _checkResponse(r);
    return OneBotGroupHonorInfo.fromJson(r.data as Map<String, dynamic>);
  }

  // -----------------------------------------------------------------------
  // --- Credentials ---
  // -----------------------------------------------------------------------

  Future<String> getCookies({String domain = ''}) async {
    final r = await callApi('get_cookies', {'domain': domain});
    _checkResponse(r);
    return (r.data as Map<String, dynamic>)['cookies'] as String? ?? '';
  }

  Future<int> getCsrfToken() async {
    final r = await callApi('get_csrf_token', null);
    _checkResponse(r);
    return (r.data as Map<String, dynamic>)['token'] as int? ?? 0;
  }

  Future<OneBotCredentials> getCredentials({String domain = ''}) async {
    final r = await callApi('get_credentials', {'domain': domain});
    _checkResponse(r);
    return OneBotCredentials.fromJson(r.data as Map<String, dynamic>);
  }

  // -----------------------------------------------------------------------
  // --- Files ---
  // -----------------------------------------------------------------------

  Future<OneBotFileResult> getRecord({
    required String file,
    required String outFormat,
  }) async {
    final r = await callApi('get_record', {
      'file': file,
      'out_format': outFormat,
    });
    _checkResponse(r);
    return OneBotFileResult.fromJson(r.data as Map<String, dynamic>);
  }

  Future<OneBotFileResult> getImage({required String file}) async {
    final r = await callApi('get_image', {'file': file});
    _checkResponse(r);
    return OneBotFileResult.fromJson(r.data as Map<String, dynamic>);
  }

  Future<bool> canSendImage() async {
    final r = await callApi('can_send_image', null);
    _checkResponse(r);
    return OneBotCanSendResult.fromJson(r.data as Map<String, dynamic>).yes;
  }

  Future<bool> canSendRecord() async {
    final r = await callApi('can_send_record', null);
    _checkResponse(r);
    return OneBotCanSendResult.fromJson(r.data as Map<String, dynamic>).yes;
  }

  // -----------------------------------------------------------------------
  // --- Status ---
  // -----------------------------------------------------------------------

  Future<OneBotStatusInfo> getStatus() async {
    final r = await callApi('get_status', null);
    _checkResponse(r);
    return OneBotStatusInfo.fromJson(r.data as Map<String, dynamic>);
  }

  Future<OneBotVersionInfo> getVersionInfo() async {
    final r = await callApi('get_version_info', null);
    _checkResponse(r);
    return OneBotVersionInfo.fromJson(r.data as Map<String, dynamic>);
  }

  Future<void> setRestart({int delay = 0}) async {
    await callApi('set_restart', {'delay': delay});
  }

  Future<void> cleanCache() async {
    final r = await callApi('clean_cache', null);
    _checkResponse(r);
  }

  // -----------------------------------------------------------------------
  // Hidden API
  // -----------------------------------------------------------------------

  /// Execute a quick operation against an event (the `.handle_quick_operation`
  /// hidden API).
  ///
  /// [context] should be the raw event JSON that was received (can be
  /// stripped of the `message` field). [operation] is a quick-operation
  /// object such as [OneBotGroupMessageQuickOp].
  Future<void> handleQuickOperation({
    required Map<String, dynamic> context,
    required Map<String, dynamic> operation,
  }) async {
    final r = await callApi('.handle_quick_operation', {
      'context': context,
      'operation': operation,
    });
    _checkResponse(r);
  }

  // -----------------------------------------------------------------------
  // Async / rate-limited variants
  // -----------------------------------------------------------------------

  /// Call an API with the `_async` suffix so the server returns immediately.
  ///
  /// Only makes sense for *send* actions; the caller cannot retrieve the
  /// result of a `get_*` action called this way.
  Future<OneBotApiResponse> callApiAsync(
    String action,
    Map<String, dynamic>? params,
  ) =>
      callApi('${action}_async', params);

  /// Call an API with the `_rate_limited` suffix so the server queues it
  /// according to the configured rate limit.
  Future<OneBotApiResponse> callApiRateLimited(
    String action,
    Map<String, dynamic>? params,
  ) =>
      callApi('${action}_rate_limited', params);

  // -----------------------------------------------------------------------
  // Helpers
  // -----------------------------------------------------------------------

  void _checkResponse(OneBotApiResponse r) {
    if (!r.isOk) {
      throw OneBotException(
        'API call failed: status=${r.status} retcode=${r.retcode}',
      );
    }
  }
}

/// Thrown when a OneBot API call fails.
class OneBotException implements Exception {
  const OneBotException(this.message);
  final String message;
  @override
  String toString() => 'OneBotException: $message';
}

String _truncateLog(String s, int max) =>
    s.length <= max ? s : '${s.substring(0, max)}…';

String _eventSummary(Map<String, dynamic> json) {
  final pt = json['post_type'] ?? '?';
  switch (pt) {
    case 'message':
      final mt = json['message_type'] ?? '?';
      final uid = json['user_id'] ?? json['group_id'] ?? '?';
      final raw = '${json['raw_message'] ?? json['message'] ?? '?'}';
      final sub = json['sub_type'];
      return '↓ $mt${sub != null ? '/$sub' : ''} uid=$uid '
          '"${_truncateLog(raw.toString(), 120)}"';
    case 'notice':
      final nt = json['notice_type'] ?? '?';
      final sub = json['sub_type'];
      return '↓ notice $nt${sub != null ? '/$sub' : ''}';
    case 'request':
      return '↓ request ${json['request_type'] ?? '?'}';
    case 'meta_event':
      return '↓ meta ${json['meta_event_type'] ?? '?'}';
    default:
      return _truncateLog('$json', 200);
  }
}
