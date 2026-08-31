/// Centralized asset paths for resolution-aware images.
///
/// Declare only 1x base paths in code; place [2.0x] and [3.0x] variants in
/// sibling folders under the same directory (see team flutterdoc on 倍图).
class AppAssets {
  AppAssets._();

  static const String _images = 'assets/images/';
  static const String _icons = 'assets/icons/';
  static const String _characters = 'assets/characters/';
  static const String _media = 'assets/media/';
  static const String _data = 'assets/data/';

  // Data
  static const String charactersJson = '${_data}characters.json';

  // Images
  static const String bgChatWithPattern = '${_images}bg_chat_with_pattern.png';
  static const String bgChatWithPatternDark =
      '${_images}bg_chat_with_pattern_dark.png';
  static const String bgChatWithPatternDark2 =
      '${_images}bg_chat_with_pattern_dark_2.png';
  static const String bgLongStripes = '${_images}bg_long_stripes.png';
  static const String bgSlidingAnim = '${_images}bg_sliding_anim.png';
  static const String chatboxPointL = '${_images}chatbox_point_l.png';
  static const String chatboxPointR = '${_images}chatbox_point_r.png';

  // Icons
  static const String iconAgentProfile = '${_icons}zzz_agent_profile_icon.png';
  static const String iconBack = '${_icons}zzz_back_icon.png';
  static const String iconDm = '${_icons}zzz_dm_icon.png';
  static const String iconEdit = '${_icons}edit_icon.png';
  static const String iconGroupChat = '${_icons}zzz_group_chat_icon.png';
  static const String iconPhoto = '${_icons}photo_icon.png';
  static const String iconTrash = '${_icons}zzz_trash_icon.png';

  // Media
  static const String stickerCorin = '${_media}corin_sticker_01.png';
  static const String stickerEllen = '${_media}ellen_sticker_01.png';

  // Default character avatars
  static const String characterWise = '${_characters}Wise.png';
  static const String characterBelle = '${_characters}Belle.png';

  /// Pool of available avatar paths for random assignment.
  static const List<String> avatarPool = [
    '${_characters}AnbyDemara.png',
    '${_characters}AntonIvanov.png',
    '${_characters}Belle.png',
    '${_characters}BenBigger.png',
    '${_characters}BillyKid.png',
    '${_characters}CorinWickes.png',
    '${_characters}JaneDoe.png',
    '${_characters}Lucy.png',
    '${_characters}NicoleDemara.png',
    '${_characters}PiperWheel.png',
    '${_characters}Qingyi.png',
    '${_characters}TsukishiroYanagi.png',
    '${_characters}VonLycaon.png',
    '${_characters}Wise.png',
    '${_characters}ZhuYuan.png',
  ];

  /// Broader pool used when a remote account has not uploaded an avatar.
  static const List<String> fallbackAvatarPool = [
    ...avatarPool,
    '${_characters}npcs/Amy.png',
    '${_characters}npcs/Asha.png',
    '${_characters}npcs/Elfy.png',
    '${_characters}npcs/Enzo.png',
    '${_characters}npcs/Foamy.png',
    '${_characters}npcs/Heddy.png',
    '${_characters}npcs/Monica.png',
    '${_characters}npcs/OfficerMewmew.png',
    '${_characters}npcs/Sjal1.png',
    '${_characters}npcs/Sjal2.png',
    '${_characters}npcs/Sjal3.png',
    '${_characters}npcs/Venus.png',
    '${_characters}temp/AlexandrinaSebastiane.png',
    '${_characters}temp/BurniceWhite.png',
    '${_characters}temp/CaesarKing.png',
    '${_characters}temp/EllenJoe.png',
    '${_characters}temp/GraceHoward.png',
    '${_characters}temp/HoshimiMiyabi.png',
    '${_characters}temp/KoledaBelobog.png',
    '${_characters}temp/Lighter.png',
    '${_characters}temp/NekomiyaMana.png',
    '${_characters}temp/SethLowell.png',
    '${_characters}temp/Soldier11.png',
    '${_characters}temp/Soukaku.png',
  ];

  /// Portrait-first pool for synthetic deployment, probe, and smoke accounts.
  ///
  /// These are deliberately kept separate from the generic fallback pool so a
  /// test environment does not end up with a wall of nearly identical default
  /// avatars when several accounts are created together.
  static const List<String> smokeAvatarPool = [
    '${_characters}npcs/Amy.png',
    '${_characters}npcs/Asha.png',
    '${_characters}npcs/Enzo.png',
    '${_characters}npcs/Monica.png',
    '${_characters}npcs/Venus.png',
    '${_characters}temp/AlexandrinaSebastiane.png',
    '${_characters}temp/BurniceWhite.png',
    '${_characters}temp/CaesarKing.png',
    '${_characters}temp/GraceHoward.png',
    '${_characters}temp/HoshimiMiyabi.png',
    '${_characters}temp/KoledaBelobog.png',
    '${_characters}temp/NekomiyaMana.png',
    '${_characters}temp/Soldier11.png',
    '${_characters}temp/Soukaku.png',
    '${_characters}NicoleDemara.png',
    '${_characters}ZhuYuan.png',
    '${_characters}temp/EllenJoe.png',
    '${_characters}temp/Lighter.png',
    '${_characters}temp/SethLowell.png',
    '${_characters}Lucy.png',
    '${_characters}PiperWheel.png',
    '${_characters}Qingyi.png',
    '${_characters}AntonIvanov.png',
    '${_characters}Belle.png',
    '${_characters}BenBigger.png',
    '${_characters}BillyKid.png',
    '${_characters}CorinWickes.png',
    '${_characters}JaneDoe.png',
    '${_characters}TsukishiroYanagi.png',
    '${_characters}VonLycaon.png',
  ];

  /// Stable profile art for the accounts used by deployment and smoke checks.
  ///
  /// These accounts deliberately carry different visual identities instead of
  /// looking like a sequence produced by the generic fallback hash.
  static const Map<String, String> smokeAccountAvatars = {
    'deployment-check': '${_characters}npcs/Monica.png',
    'smoke-alice': '${_characters}npcs/Amy.png',
    'smoke-bob': '${_characters}npcs/Enzo.png',
    'codex-pwa-probe': '${_characters}npcs/Venus.png',
    'alice': '${_characters}temp/GraceHoward.png',
    'test1': '${_characters}temp/BurniceWhite.png',
    'xiaodeng': '${_characters}npcs/Asha.png',
    'smoke-cathy': '${_characters}temp/AlexandrinaSebastiane.png',
    'smoke-diego': '${_characters}temp/CaesarKing.png',
    'smoke-lina': '${_characters}temp/Soukaku.png',
    'smoke-rin': '${_characters}temp/NekomiyaMana.png',
    'probe-android': '${_characters}temp/Soldier11.png',
    'probe-desktop': '${_characters}temp/KoledaBelobog.png',
    'probe-ios': '${_characters}ZhuYuan.png',
    'probe-web': '${_characters}NicoleDemara.png',
    'smoke-qa': '${_characters}temp/HoshimiMiyabi.png',
    'smoke-ios': '${_characters}temp/EllenJoe.png',
    'smoke-android': '${_characters}temp/Lighter.png',
    'smoke-desktop': '${_characters}temp/SethLowell.png',
    'smoke-mobile': '${_characters}Lucy.png',
    'smoke-user': '${_characters}PiperWheel.png',
    'smoke-user-a': '${_characters}Qingyi.png',
    'smoke-user-b': '${_characters}AntonIvanov.png',
    'alice-account': '${_characters}Belle.png',
    'bob-account': '${_characters}BenBigger.png',
    'bob': '${_characters}BillyKid.png',
    'cathy': '${_characters}CorinWickes.png',
    'diego': '${_characters}JaneDoe.png',
    'lina': '${_characters}TsukishiroYanagi.png',
    'rin': '${_characters}VonLycaon.png',
  };

  /// Keeps generated avatars stable across sessions while distributing users.
  static String fallbackAvatarForId(String id) {
    final normalizedId = id.contains('::') ? id.split('::').last : id;
    final normalized = normalizedId.toLowerCase();
    final smokeAvatar = smokeAccountAvatars[normalized];
    if (smokeAvatar != null) return smokeAvatar;
    var hash = 0x811c9dc5;
    for (final codeUnit in normalized.codeUnits) {
      hash ^= codeUnit;
      hash = (hash * 16777619) & 0x7fffffff;
    }
    final isSynthetic = normalized.startsWith('smoke') ||
        normalized.startsWith('probe') ||
        normalized.startsWith('deployment') ||
        normalized.startsWith('test');
    final pool = isSynthetic ? smokeAvatarPool : fallbackAvatarPool;
    return pool[hash % pool.length];
  }

  /// Path under [assets/characters/] for a file or nested relative path.
  static String character(String relativePath) => '$_characters$relativePath';
}
