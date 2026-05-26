import 'dart:typed_data';

enum ChatSide { left, right, system }

enum MessageKind { text, image, system }

enum SystemMessageKind { userAdded, history, fileUploaded }

class ChatCharacter {
  const ChatCharacter({
    required this.name,
    required this.assetPath,
    required this.category,
  });

  final String name;
  final String assetPath;
  final String category;

  factory ChatCharacter.fromJson(Map<String, dynamic> json) {
    return ChatCharacter(
      name: json['name'] as String,
      assetPath: json['image'] as String,
      category: json['category'] as String,
    );
  }
}

class ChatIdentity {
  const ChatIdentity({
    required this.name,
    this.assetPath,
    this.imageBytes,
    this.category,
  });

  final String name;
  final String? assetPath;
  final Uint8List? imageBytes;
  final String? category;

  factory ChatIdentity.fromCharacter(ChatCharacter character) {
    return ChatIdentity(
      name: character.name,
      assetPath: character.assetPath,
      category: character.category,
    );
  }

  ChatIdentity copyWith({
    String? name,
    String? assetPath,
    Uint8List? imageBytes,
    String? category,
  }) {
    return ChatIdentity(
      name: name ?? this.name,
      assetPath: assetPath ?? this.assetPath,
      imageBytes: imageBytes ?? this.imageBytes,
      category: category ?? this.category,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'name': name,
      'assetPath': assetPath,
      'category': category,
      'hasCustomAvatar': imageBytes != null,
    };
  }
}

class ChatMessage {
  const ChatMessage({
    required this.side,
    required this.kind,
    required this.text,
    this.sender,
    this.imageBytes,
    this.systemKind,
  });

  final ChatSide side;
  final MessageKind kind;
  final String text;
  final ChatIdentity? sender;
  final Uint8List? imageBytes;
  final SystemMessageKind? systemKind;

  ChatMessage copyWith({String? text}) {
    return ChatMessage(
      side: side,
      kind: kind,
      text: text ?? this.text,
      sender: sender,
      imageBytes: imageBytes,
      systemKind: systemKind,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'side': side.name,
      'type': kind.name,
      'sender': sender?.toJson(),
      'content': kind == MessageKind.image ? '[image]' : text,
      'systemKind': systemKind?.name,
    };
  }
}
