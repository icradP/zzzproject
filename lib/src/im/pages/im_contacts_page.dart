import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../assets/app_assets.dart';
import '../../widgets/zzz_widgets.dart';
import '../widgets/contacts_panel.dart';

class ImContactsPage extends StatefulWidget {
  const ImContactsPage({super.key});

  @override
  State<ImContactsPage> createState() => _ImContactsPageState();
}

class _ImContactsPageState extends State<ImContactsPage>
    with SingleTickerProviderStateMixin {
  late final AnimationController _bgController;

  @override
  void initState() {
    super.initState();
    _bgController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 30),
    )..repeat();
  }

  @override
  void dispose() {
    _bgController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          ZzzBackground(controller: _bgController, animated: true),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  _buildHeader(),
                  const SizedBox(height: 12),
                  Expanded(
                    child: ZzzPanel(
                      animateEntrance: true,
                      background: const DecorationImage(
                        image: AssetImage(AppAssets.bgChatWithPatternDark2),
                        repeat: ImageRepeat.repeat,
                        opacity: 0.1,
                      ),
                      child: ContactsPanel(
                        onConversationSelected: (c) => context.pop(c),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: Colors.white12),
      ),
      child: Row(
        children: [
          IconButton(
            onPressed: () => context.pop(),
            icon: const Icon(Icons.arrow_back_rounded),
            tooltip: 'Back',
          ),
          const SizedBox(width: 4),
          const Text(
            'Contacts',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
          ),
        ],
      ),
    );
  }
}
