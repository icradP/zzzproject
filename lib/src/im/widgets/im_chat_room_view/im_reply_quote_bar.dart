import 'package:flutter/material.dart';

import '../../../theme/zzz_colors.dart';
import '../../models/im_models.dart';

/// Telegram-style reply quote bar showing the source message content.
class ImReplyQuoteBar extends StatelessWidget {
  const ImReplyQuoteBar({this.quote, this.onTap, this.resolveUserName});

  final ImMessage? quote;
  final VoidCallback? onTap;
  final Future<String> Function(String userId)? resolveUserName;

  static const _maxLen = 60;

  @override
  Widget build(BuildContext context) {
    if (quote == null) return const SizedBox.shrink();
    final text = quote!.text;
    final display =
        text.length > _maxLen ? '${text.substring(0, _maxLen)}…' : text;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 6),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
        ),
        clipBehavior: Clip.antiAlias,
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(width: 3, color: ZzzColors.yellow),
              Flexible(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(8, 8, 10, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      FutureBuilder<String>(
                        future:
                            resolveUserName?.call(quote!.senderId) ??
                            Future.value(quote!.senderId),
                        builder: (ctx, snap) {
                          return Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Icons.reply_rounded,
                                size: 13,
                                color: ZzzColors.yellow,
                              ),
                              const SizedBox(width: 4),
                              Flexible(
                                child: Text(
                                  snap.data ?? quote!.senderId,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700,
                                    color: ZzzColors.yellow,
                                  ),
                                ),
                              ),
                            ],
                          );
                        },
                      ),
                      const SizedBox(height: 4),
                      Text(
                        display,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.white,
                          height: 1.3,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
