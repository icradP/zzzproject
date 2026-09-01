import 'package:shared_preferences/shared_preferences.dart';

class ImDraftStore {
  const ImDraftStore._();

  static String _key(String ownerId, String conversationId) =>
      'im_draft:${Uri.encodeComponent(ownerId)}:${Uri.encodeComponent(conversationId)}';

  static Future<String> load({
    required String ownerId,
    required String conversationId,
  }) async {
    final preferences = await SharedPreferences.getInstance();
    return preferences.getString(_key(ownerId, conversationId)) ?? '';
  }

  static Future<void> save({
    required String ownerId,
    required String conversationId,
    required String text,
  }) async {
    final preferences = await SharedPreferences.getInstance();
    final key = _key(ownerId, conversationId);
    if (text.trim().isEmpty) {
      await preferences.remove(key);
    } else {
      await preferences.setString(key, text);
    }
  }
}
