import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../theme/zzz_colors.dart';
import '../../widgets/zzz_widgets.dart';
import '../data/im_release_notes.dart';

Future<bool?> showImReleaseNotesPanel({
  required BuildContext context,
  bool startup = false,
}) {
  final releases =
      startup ? <ImReleaseNote>[ImReleaseNotes.current] : ImReleaseNotes.releases;
  return showZzzModalPanel<bool>(
    context: context,
    builder: (dialogContext) => ZzzModalPanel(
      key: ValueKey(startup ? 'release-notes-current' : 'release-notes-history'),
      title: startup ? 'What is new' : 'Update history',
      subtitle:
          startup
              ? 'Version ${ImReleaseNotes.currentVersion}'
              : 'Current version ${ImReleaseNotes.currentVersion}',
      icon: Icons.new_releases_outlined,
      maxWidth: 520,
      maxHeight: 600,
      actions: [
        if (startup)
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Later'),
          ),
        FilledButton.icon(
          onPressed: () => Navigator.of(dialogContext).pop(startup),
          icon: Icon(startup ? Icons.visibility_off_outlined : Icons.check),
          label: Text(startup ? 'Do not show again' : 'Close'),
        ),
      ],
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 20),
        shrinkWrap: true,
        itemCount: releases.length,
        separatorBuilder: (_, __) => const Padding(
          padding: EdgeInsets.symmetric(vertical: 14),
          child: Divider(height: 1, color: Colors.white12),
        ),
        itemBuilder: (context, index) {
          final release = releases[index];
          return _ReleaseNoteSection(release: release);
        },
      ),
    ),
  );
}

class ImReleaseNotesGate extends StatefulWidget {
  const ImReleaseNotesGate({required this.child, super.key});

  final Widget child;

  @visibleForTesting
  static void resetSession() => _offeredThisSession = false;

  static bool _offeredThisSession = false;

  @override
  State<ImReleaseNotesGate> createState() => _ImReleaseNotesGateState();
}

class _ImReleaseNotesGateState extends State<ImReleaseNotesGate> {
  bool _scheduled = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_scheduled || ImReleaseNotesGate._offeredThisSession) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_offer()));
  }

  Future<void> _offer() async {
    if (!await ImReleaseNotes.shouldShowCurrent() || !mounted) return;
    ImReleaseNotesGate._offeredThisSession = true;
    final dismiss = await showImReleaseNotesPanel(context: context, startup: true);
    if (dismiss == true) await ImReleaseNotes.dismissCurrent();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _ReleaseNoteSection extends StatelessWidget {
  const _ReleaseNoteSection({required this.release});

  final ImReleaseNote release;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              'v${release.version}',
              style: const TextStyle(
                color: ZzzColors.yellow,
                fontWeight: FontWeight.w800,
                fontSize: 14,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                release.title,
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        for (final item in release.items)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.only(top: 6),
                  child: Icon(Icons.circle, size: 5, color: Colors.white38),
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(
                    item,
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 13,
                      height: 1.35,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
