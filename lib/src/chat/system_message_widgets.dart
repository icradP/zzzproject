import 'package:flutter/material.dart';

import '../models/chat_models.dart';

String defaultSystemText(SystemMessageKind kind) {
  switch (kind) {
    case SystemMessageKind.userAdded:
      return 'User added you';
    case SystemMessageKind.history:
      return '- History -';
    case SystemMessageKind.fileUploaded:
      return 'ImportantNotes.txt';
  }
}

class ZzzSystemTemplateButton extends StatelessWidget {
  const ZzzSystemTemplateButton({
    required this.message,
    required this.onTap,
    super.key,
  });

  final ChatMessage message;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: OutlinedButton(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size.fromHeight(70),
          backgroundColor: Colors.white.withValues(alpha: 0.08),
        ),
        onPressed: onTap,
        child: ZzzSystemMessageView(message: message),
      ),
    );
  }
}

class ZzzSystemMessageView extends StatelessWidget {
  const ZzzSystemMessageView({required this.message, super.key});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    switch (message.systemKind) {
      case SystemMessageKind.userAdded:
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(22),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline_rounded, size: 18),
              const SizedBox(width: 8),
              Text(message.text),
            ],
          ),
        );
      case SystemMessageKind.fileUploaded:
        return Container(
          constraints: const BoxConstraints(maxWidth: 360),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.grey.shade500,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'New File uploaded:',
                style: TextStyle(color: Colors.black),
              ),
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.black,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  message.text,
                  style: const TextStyle(color: Colors.white70),
                ),
              ),
            ],
          ),
        );
      case SystemMessageKind.history:
      case null:
        return Text(
          message.text,
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white54),
        );
    }
  }
}
