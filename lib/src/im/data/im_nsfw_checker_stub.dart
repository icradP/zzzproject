import 'im_nsfw_checker.dart';

/// No-op NSFW checker — always returns `false` (safe).
///
/// Used when no real checker is configured.
class StubNsfwChecker implements ImNsfwChecker {
  @override
  bool get isAvailable => false;

  @override
  Future<void> initialize() async {}

  @override
  Future<bool?> check(String imagePath) async => false;

  @override
  void dispose() {}
}
