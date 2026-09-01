import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../models/im_models.dart';
import '../../../theme/zzz_colors.dart';

Map<String, dynamic> _segmentData(ImMessage message) {
  for (final segment in message.segments ?? const []) {
    if (segment.type == 'share' || segment.type == 'location') {
      return segment.data;
    }
  }
  return const {};
}

class ImLinkBubble extends StatelessWidget {
  const ImLinkBubble({required this.message, super.key});

  final ImMessage message;

  @override
  Widget build(BuildContext context) {
    final data = _segmentData(message);
    final rawUrl = '${data['url'] ?? ''}';
    final parsed = Uri.tryParse(rawUrl);
    final uri =
        parsed != null &&
                (parsed.scheme == 'http' || parsed.scheme == 'https') &&
                parsed.host.isNotEmpty &&
                parsed.userInfo.isEmpty
            ? parsed
            : null;
    final domain = uri?.host ?? '';
    final title = '${data['title'] ?? domain}'.trim();
    return Semantics(
      button: uri != null,
      label: 'Open link $rawUrl',
      child: InkWell(
        key: const ValueKey('message-link-card'),
        borderRadius: BorderRadius.circular(8),
        onTap: uri == null ? null : () => _open(context, uri),
        child: Container(
          width: 280,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: message.isMine ? ZzzColors.blue : Colors.grey.shade200,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: message.isMine ? Colors.white12 : Colors.black12,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.link_rounded,
                  color: message.isMine ? Colors.white : Colors.black87,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title.isEmpty ? 'Shared link' : title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: message.isMine ? Colors.white : Colors.black87,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (domain.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        domain,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color:
                              message.isMine ? Colors.white70 : Colors.black54,
                          fontSize: 12,
                        ),
                      ),
                    ],
                    const SizedBox(height: 5),
                    Text(
                      rawUrl,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: message.isMine ? Colors.white60 : Colors.black45,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 4),
              Icon(
                Icons.open_in_new_rounded,
                size: 18,
                color: message.isMine ? Colors.white60 : Colors.black45,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _open(BuildContext context, Uri uri) async {
    try {
      if (await launchUrl(uri, mode: LaunchMode.externalApplication)) return;
    } catch (_) {}
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Unable to open this link.')));
  }
}

class ImLocationBubble extends StatelessWidget {
  const ImLocationBubble({required this.message, super.key});

  final ImMessage message;

  @override
  Widget build(BuildContext context) {
    final data = _segmentData(message);
    final name = '${data['name'] ?? 'Shared location'}';
    final lat = (data['lat'] as num?)?.toDouble();
    final lon = (data['lon'] as num?)?.toDouble();
    final hasCoordinates = lat != null && lon != null;
    return Container(
      key: const ValueKey('message-location-card'),
      width: 280,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: message.isMine ? ZzzColors.blue : Colors.grey.shade200,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: message.isMine ? Colors.white12 : Colors.black12,
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.location_on_rounded,
              color: message.isMine ? Colors.white : ZzzColors.red,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: message.isMine ? Colors.white : Colors.black87,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  hasCoordinates
                      ? '${lat.toStringAsFixed(5)}, ${lon.toStringAsFixed(5)}'
                      : 'Place name only',
                  style: TextStyle(
                    color: message.isMine ? Colors.white70 : Colors.black54,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          if (hasCoordinates)
            IconButton(
              key: const ValueKey('open-shared-location'),
              tooltip: 'Open location',
              onPressed: () => _open(context, lat, lon),
              icon: const Icon(Icons.open_in_new_rounded),
              color: message.isMine ? Colors.white70 : Colors.black54,
            ),
        ],
      ),
    );
  }

  Future<void> _open(BuildContext context, double lat, double lon) async {
    final uri = Uri(
      scheme: 'https',
      host: 'www.openstreetmap.org',
      path: '/',
      queryParameters: {'mlat': '$lat', 'mlon': '$lon'},
      fragment: 'map=16/$lat/$lon',
    );
    try {
      if (await launchUrl(uri, mode: LaunchMode.externalApplication)) return;
    } catch (_) {}
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Unable to open this location.')),
    );
  }
}
