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
  static const String iconAgentProfile =
      '${_icons}zzz_agent_profile_icon.png';
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

  /// Path under [assets/characters/] for a file or nested relative path.
  static String character(String relativePath) => '$_characters$relativePath';
}
