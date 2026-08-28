import 'package:flutter/material.dart';

/// File attachment card — follows the demo's `ZzzSystemMessageView`
/// file-uploaded style: label + dark file-name container.
class ImFileCard extends StatelessWidget {
  const ImFileCard({
    required this.fileName,
    this.fileSize,
    required this.isMine,
    this.isVideo = false,
    this.onOpen,
    super.key,
  });

  final String fileName;
  final int? fileSize;
  final bool isMine;
  final bool isVideo;
  final VoidCallback? onOpen;

  String _formatSize(int? bytes) {
    if (bytes == null || bytes <= 0) return '';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  @override
  Widget build(BuildContext context) {
    final sizeLabel = _formatSize(fileSize);
    return SizedBox(
      width: 260,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.grey.shade500,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(
                  isVideo
                      ? Icons.videocam_rounded
                      : Icons.insert_drive_file_rounded,
                  size: 16,
                  color: Colors.black,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    isVideo ? 'Video' : 'File',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.black,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (sizeLabel.isNotEmpty)
                  Text(
                    sizeLabel,
                    style: const TextStyle(color: Colors.black54, fontSize: 11),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Material(
              color: Colors.black,
              borderRadius: BorderRadius.circular(8),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: onOpen,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          fileName,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 13,
                          ),
                        ),
                      ),
                      if (onOpen != null) ...[
                        const SizedBox(width: 8),
                        Icon(
                          isVideo
                              ? Icons.play_circle_outline_rounded
                              : Icons.open_in_new_rounded,
                          color: Colors.white70,
                          size: 20,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
