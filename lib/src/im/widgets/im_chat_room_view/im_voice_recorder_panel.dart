import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:record/record.dart';

import '../../../theme/zzz_colors.dart';
import '../../../widgets/zzz_widgets.dart';
import '../../models/im_models.dart';
import 'im_voice_bubble.dart';

const imVoiceMessageLimit = Duration(minutes: 2);
const imVoiceMessageMaxBytes = 10 * 1024 * 1024;

class ImVoiceRecorderPanel extends StatefulWidget {
  const ImVoiceRecorderPanel({super.key});

  @override
  State<ImVoiceRecorderPanel> createState() => _ImVoiceRecorderPanelState();
}

class _ImVoiceRecorderPanelState extends State<ImVoiceRecorderPanel>
    with WidgetsBindingObserver {
  final AudioRecorder _recorder = AudioRecorder();
  Timer? _timer;
  Duration _elapsed = Duration.zero;
  bool _isRecording = false;
  bool _working = false;
  String? _error;
  ImMediaUpload? _preview;
  String _recordingExtension = 'm4a';
  String _recordingMime = 'audio/mp4';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_isRecording && state != AppLifecycleState.resumed) {
      unawaited(_stopRecording());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    if (_isRecording) unawaited(_recorder.cancel());
    unawaited(_recorder.dispose());
    super.dispose();
  }

  Future<void> _startRecording() async {
    if (_working || _isRecording) return;
    setState(() {
      _working = true;
      _error = null;
      _preview = null;
      _elapsed = Duration.zero;
    });
    try {
      if (!await _recorder.hasPermission()) {
        throw StateError('Microphone permission is required to record.');
      }
      late final AudioEncoder encoder;
      late final String extension;
      late final String mimeType;
      if (kIsWeb && await _recorder.isEncoderSupported(AudioEncoder.opus)) {
        encoder = AudioEncoder.opus;
        extension = 'webm';
        mimeType = 'audio/webm';
      } else if (await _recorder.isEncoderSupported(AudioEncoder.aacLc)) {
        encoder = AudioEncoder.aacLc;
        extension = 'm4a';
        mimeType = 'audio/mp4';
      } else if (await _recorder.isEncoderSupported(AudioEncoder.wav)) {
        encoder = AudioEncoder.wav;
        extension = 'wav';
        mimeType = 'audio/wav';
      } else {
        throw StateError('This browser has no supported recording format.');
      }
      final name = 'voice_${DateTime.now().millisecondsSinceEpoch}.$extension';
      final path = kIsWeb ? name : '${Directory.systemTemp.path}/$name';
      await _recorder.start(
        RecordConfig(
          encoder: encoder,
          bitRate: 32000,
          sampleRate: 16000,
          numChannels: 1,
        ),
        path: path,
      );
      if (!mounted) return;
      setState(() {
        _recordingExtension = extension;
        _recordingMime = mimeType;
        _isRecording = true;
        _working = false;
      });
      _timer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        final next = _elapsed + const Duration(seconds: 1);
        setState(() => _elapsed = next);
        if (next >= imVoiceMessageLimit) unawaited(_stopRecording());
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _working = false;
        _error = error.toString().replaceFirst('Bad state: ', '');
      });
    }
  }

  Future<void> _stopRecording() async {
    if (!_isRecording || _working) return;
    _timer?.cancel();
    setState(() => _working = true);
    try {
      final path = await _recorder.stop();
      if (path == null || path.isEmpty) {
        throw StateError('Recording did not produce an audio file.');
      }
      final upload = ImMediaUpload(
        kind: ImMessageKind.record,
        fileName:
            'voice_${DateTime.now().millisecondsSinceEpoch}.$_recordingExtension',
        filePath: path,
        mimeType: _recordingMime,
        duration: _elapsed,
      );
      if (!mounted) return;
      setState(() {
        _isRecording = false;
        _working = false;
        _preview = upload;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _isRecording = false;
        _working = false;
        _error = error.toString().replaceFirst('Bad state: ', '');
      });
    }
  }

  Future<void> _cancelRecording() async {
    _timer?.cancel();
    if (_isRecording) await _recorder.cancel();
    if (!mounted) return;
    setState(() {
      _isRecording = false;
      _working = false;
      _preview = null;
      _elapsed = Duration.zero;
      _error = null;
    });
  }

  String _clock(Duration duration) {
    final minutes = duration.inMinutes.toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    return ZzzModalPanel(
      key: const ValueKey('voice-recorder-panel'),
      title: 'Voice message',
      subtitle: 'Up to 2 minutes / 10 MB',
      icon: Icons.mic_rounded,
      maxWidth: 460,
      maxHeight: 520,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_isRecording) ...[
              const _RecordingPulse(),
              const SizedBox(height: 14),
              Text(
                _clock(_elapsed),
                key: const ValueKey('voice-recording-duration'),
                style: const TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w800,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(height: 18),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  OutlinedButton.icon(
                    key: const ValueKey('cancel-voice-recording'),
                    onPressed: _working ? null : _cancelRecording,
                    icon: const Icon(Icons.delete_outline_rounded),
                    label: const Text('Cancel'),
                  ),
                  const SizedBox(width: 12),
                  FilledButton.icon(
                    key: const ValueKey('stop-voice-recording'),
                    onPressed: _working ? null : _stopRecording,
                    icon: const Icon(Icons.stop_rounded),
                    label: const Text('Stop'),
                  ),
                ],
              ),
            ] else if (_preview != null) ...[
              ImVoiceBubble(
                localPath: _preview!.filePath,
                isMine: true,
                declaredDuration: _preview!.duration,
              ),
              const SizedBox(height: 18),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  OutlinedButton.icon(
                    onPressed: _working ? null : _cancelRecording,
                    icon: const Icon(Icons.refresh_rounded),
                    label: const Text('Record again'),
                  ),
                  const SizedBox(width: 12),
                  FilledButton.icon(
                    key: const ValueKey('use-voice-recording'),
                    onPressed:
                        _working
                            ? null
                            : () => Navigator.of(context).pop(_preview),
                    icon: const Icon(Icons.check_rounded),
                    label: const Text('Use recording'),
                  ),
                ],
              ),
            ] else ...[
              IconButton.filled(
                key: const ValueKey('start-voice-recording'),
                tooltip: 'Start recording',
                onPressed: _working ? null : _startRecording,
                icon: const Icon(Icons.mic_rounded, size: 34),
                style: IconButton.styleFrom(
                  backgroundColor: ZzzColors.red,
                  foregroundColor: Colors.white,
                  minimumSize: const Size.square(74),
                ),
              ),
              const SizedBox(height: 14),
              const Text(
                'Tap to record',
                style: TextStyle(color: Colors.white70),
              ),
            ],
            if (_working) ...[
              const SizedBox(height: 18),
              const LinearProgressIndicator(minHeight: 2),
            ],
            if (_error != null) ...[
              const SizedBox(height: 14),
              Text(
                _error!,
                key: const ValueKey('voice-recording-error'),
                textAlign: TextAlign.center,
                style: const TextStyle(color: ZzzColors.red, fontSize: 12),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _RecordingPulse extends StatelessWidget {
  const _RecordingPulse();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 58,
      height: 58,
      decoration: BoxDecoration(
        color: ZzzColors.red.withValues(alpha: 0.18),
        shape: BoxShape.circle,
      ),
      child: const Icon(
        Icons.graphic_eq_rounded,
        color: ZzzColors.red,
        size: 32,
      ),
    );
  }
}
