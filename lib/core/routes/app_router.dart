import 'package:go_router/go_router.dart';

import '../../src/demo/demo_pages.dart';
import '../../src/im/pages/im_contacts_page.dart';
import '../../src/im/pages/im_home_page.dart';
import '../../src/im/pages/im_settings_page.dart';

/// Centralized route path constants.
abstract final class AppRoutes {
  static const home = '/';
  static const demo = '/demo';
  static const settings = '/settings';
  static const contacts = '/contacts';
}

final appRouter = GoRouter(
  initialLocation: AppRoutes.home,
  routes: [
    GoRoute(
      path: AppRoutes.home,
      name: 'home',
      builder: (_, __) => const ImHomePage(),
    ),
    GoRoute(
      path: AppRoutes.demo,
      name: 'demo',
      builder: (_, __) => const ChatSimulatorDemoPage(),
    ),
    GoRoute(
      path: AppRoutes.settings,
      name: 'settings',
      builder: (_, __) => const ImSettingsPage(),
    ),
    GoRoute(
      path: AppRoutes.contacts,
      name: 'contacts',
      builder: (_, __) => const ImContactsPage(),
    ),
  ],
);
