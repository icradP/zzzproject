import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'src/app/zzz_app.dart';
import 'src/im/data/im_web_plugin_setup.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  registerImWebPlugins();
  if (!kIsWeb) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }
  runApp(const ZzzApp());
}
