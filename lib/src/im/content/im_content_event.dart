/// An interaction emitted by any renderer in the unified content layer.
///
/// The content runtime only describes the interaction. Application code owns
/// routing, network calls, AI requests, and any local operation.
class ImContentEvent {
  const ImContentEvent({
    required this.messageId,
    required this.contentId,
    required this.type,
    this.payload = const <String, dynamic>{},
  });

  final String messageId;
  final String contentId;
  final String type;
  final Map<String, dynamic> payload;
}

typedef ContentEvent = ImContentEvent;
