@JS('zzzPush')
library;

import 'dart:js_interop';

@JS('isSupported')
external JSBoolean _isSupported();

@JS('permission')
external JSString _permission();

@JS('currentSubscription')
external JSPromise<JSString?> _currentSubscription();

@JS('subscribe')
external JSPromise<JSString?> _subscribe(JSString publicKey);

@JS('unsubscribe')
external JSPromise<JSAny?> _unsubscribe();

bool isPushSupported() => _isSupported().toDart;

String pushPermission() => _permission().toDart;

Future<String?> currentPushSubscription() =>
    _currentSubscription().toDart.then((value) => value?.toDart);

Future<String?> subscribeToPush(String publicKey) =>
    _subscribe(publicKey.toJS).toDart.then((value) => value?.toDart);

Future<void> unsubscribeFromPush() => _unsubscribe().toDart.then((_) => null);
