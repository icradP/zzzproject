import 'package:onebot_flutter/onebot_flutter.dart' show OneBotMessageSegment;

import '../../assets/app_assets.dart';
import '../models/im_models.dart';

class ImStickerDefinition {
  const ImStickerDefinition({
    required this.reference,
    required this.label,
    required this.assetPath,
  });

  final ImStickerReference reference;
  final String label;
  final String assetPath;
}

/// Versioned catalog for sticker IDs persisted in message segments.
///
/// Existing entries must remain in this list when artwork is replaced. Add a
/// new versioned entry instead, so historical messages keep their old mapping.
abstract final class ImStickerCatalog {
  static const segmentType = 'sticker';
  static const corePackId = 'zzz-core';

  static const stickers = <ImStickerDefinition>[
    ImStickerDefinition(
      reference: ImStickerReference(
        packId: corePackId,
        assetId: 'corin-01',
        version: 1,
      ),
      label: 'Corin',
      assetPath: AppAssets.stickerCorin,
    ),
    ImStickerDefinition(
      reference: ImStickerReference(
        packId: corePackId,
        assetId: 'ellen-01',
        version: 1,
      ),
      label: 'Ellen',
      assetPath: AppAssets.stickerEllen,
    ),
  ];

  static ImStickerReference? referenceFromSegment(
    OneBotMessageSegment segment,
  ) {
    if (segment.type != segmentType) return null;
    final packId = segment.data['pack_id'];
    final assetId = segment.data['asset_id'];
    final version = segment.data['version'];
    if (packId is! String || assetId is! String || version is! num) {
      return null;
    }
    final integerVersion = version.toInt();
    if (version != integerVersion || integerVersion < 1) return null;
    return ImStickerReference(
      packId: packId,
      assetId: assetId,
      version: integerVersion,
    );
  }

  static ImStickerDefinition? resolve(ImStickerReference reference) {
    for (final sticker in stickers) {
      if (sticker.reference == reference) return sticker;
    }
    return null;
  }

  static ImStickerDefinition? resolveMessage(ImMessage message) {
    for (final segment in message.segments ?? const <OneBotMessageSegment>[]) {
      final reference = referenceFromSegment(segment);
      if (reference == null) continue;
      return resolve(reference);
    }
    return null;
  }
}
