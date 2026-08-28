bool isPushSupported() => false;

String pushPermission() => 'unsupported';

Future<String?> currentPushSubscription() async => null;

Future<String?> subscribeToPush(String publicKey) async => null;

Future<void> unsubscribeFromPush() async {}
