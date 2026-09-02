import 'package:flutter_web_plugins/flutter_web_plugins.dart';
import 'package:geolocator_web/geolocator_web.dart';
import 'package:record_web/record_web.dart';

/// Keeps the browser implementations reachable even when Flutter's generated
/// plugin registrant is stale or tree-shaken in a release build.
void registerImWebPlugins() {
  GeolocatorPlugin.registerWith(webPluginRegistrar);
  RecordPluginWeb.registerWith(webPluginRegistrar);
}
