/// A Dart/Flutter SDK for the OneBot v11 protocol.
///
/// Connect to NoneBot, NapCatQQ, LLOneBot, and other OneBot-compatible
/// implementations via forward/reverse WebSocket or HTTP.
///
/// ```dart
/// final client = OneBotClient(
///   config: OneBotConfig(
///     wsEndpoint: 'ws://127.0.0.1:6199/ws',
///     accessToken: 'my-token',
///   ),
/// );
/// await client.connect();
/// final info = await client.getLoginInfo();
/// client.eventStream.listen((e) { /* handle event */ });
/// ```
library;

export 'src/onebot_models.dart';
export 'src/onebot_client.dart';
