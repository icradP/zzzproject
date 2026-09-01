import 'dart:io';

bool get isImFlutterTest => Platform.environment.containsKey('FLUTTER_TEST');
