import 'package:flutter/material.dart';

import '../../../assets/app_assets.dart';
import '../../../widgets/zzz_widgets.dart';

/// Grid display of group members with avatars and names.
class ImMemberGrid extends StatelessWidget {
  const ImMemberGrid({
    required this.participantIds,
    required this.resolveUserName,
    required this.resolveUserAvatar,
    super.key,
  });

  final List<String> participantIds;
  final Future<String> Function(String userId) resolveUserName;
  final Future<ImageProvider> Function(String userId) resolveUserAvatar;

  @override
  Widget build(BuildContext context) {
    return ZzzPanel(
      padding: const EdgeInsets.all(12),
      child: SingleChildScrollView(
        child: Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            for (final userId in participantIds)
              FutureBuilder<({String name, ImageProvider avatar})>(
                future: Future.wait([
                  resolveUserName(userId),
                  resolveUserAvatar(userId),
                ]).then(
                  (v) => (name: v[0] as String, avatar: v[1] as ImageProvider),
                ),
                builder: (context, snapshot) {
                  final name = snapshot.data?.name ?? userId;
                  final avatar =
                      snapshot.data?.avatar ??
                      AssetImage(AppAssets.fallbackAvatarForId(userId));
                  return SizedBox(
                    width: 66,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          padding: const EdgeInsets.all(2),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: Colors.white24,
                          ),
                          child: ZzzAvatar(image: avatar, size: 44),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 11,
                            color: Colors.white70,
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
          ],
        ),
      ),
    );
  }
}
