import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';

import '../../im_scope.dart';

/// Voice message bubble — play / pause button + duration display.
class ImVoiceBubble extends StatefulWidget {
  const ImVoiceBubble({
    super.key,
    this.fileId,
    this.url,
    this.localPath,
    required this.isMine,
    this.fileSize,
    this.declaredDuration,
  });

  final String? fileId;
  final String? url;
  final String? localPath;
  final bool isMine;
  final int? fileSize;
  final Duration? declaredDuration;

  @override
  State<ImVoiceBubble> createState() => _ImVoiceBubbleState();
}

class _ImVoiceBubbleState extends State<ImVoiceBubble> {
  final _player = AudioPlayer();
  PlayerState _playerState = PlayerState.stopped;
  Duration _duration = Duration.zero;
  Duration _position = Duration.zero;
  String? _resolvedPath;
  bool _downloading = false;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _player.onPlayerStateChanged.listen((s) {
      if (mounted) setState(() => _playerState = s);
    });
    _player.onDurationChanged.listen((d) {
      if (mounted) setState(() => _duration = d);
    });
    _player.onPositionChanged.listen((p) {
      if (mounted) setState(() => _position = p);
    });
    _player.onPlayerComplete.listen((_) {
      if (mounted) setState(() {});
    });
    if (widget.localPath != null && widget.localPath!.isNotEmpty) {
      _resolvedPath = widget.localPath;
      _initSource();
    }
  }

  Future<void> _initSource() async {
    if (_resolvedPath == null) return;
    try {
      final uri = Uri.tryParse(_resolvedPath!);
      if (uri != null &&
          (uri.scheme == 'http' ||
              uri.scheme == 'https' ||
              uri.scheme == 'blob')) {
        await _player.setSource(UrlSource(uri.toString()));
      } else {
        await _player.setSourceDeviceFile(_resolvedPath!);
      }
      await _player.setReleaseMode(ReleaseMode.stop);
      if (mounted) setState(() => _ready = true);
    } catch (_) {}
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  Future<void> _ensureDownloaded() async {
    if (_resolvedPath != null) return;
    if (_downloading) return;
    final fid = widget.fileId;
    if (fid == null || fid.isEmpty) return;
    setState(() => _downloading = true);
    try {
      final path = await ImScope.interactionsOf(
        context,
      ).downloadRecord(fileId: fid, url: widget.url);
      if (path != null && path.isNotEmpty) {
        _resolvedPath = path;
        await _initSource();
      }
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }

  void _togglePlay() async {
    if (!_ready) {
      await _ensureDownloaded();
      if (!_ready) return;
    }
    switch (_playerState) {
      case PlayerState.playing:
        _player.pause();
        break;
      case PlayerState.paused:
        _player.resume();
        break;
      case PlayerState.stopped:
      case PlayerState.completed:
        _player.seek(Duration.zero);
        _player.resume();
        break;
      case PlayerState.disposed:
        break;
    }
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  int get _estimatedSecs {
    if (_duration > Duration.zero) return _duration.inSeconds;
    final bytes = widget.fileSize;
    if (bytes != null && bytes > 0) return (bytes / 2000).round();
    return 0;
  }

  Duration get _total =>
      _duration > Duration.zero
          ? _duration
          : widget.declaredDuration ?? Duration(seconds: _estimatedSecs);

  @override
  Widget build(BuildContext context) {
    final isPlaying = _playerState == PlayerState.playing;
    final label = '${_fmt(_position)} / ${_fmt(_total)}';
    final icon =
        _downloading
            ? Icons.downloading_rounded
            : _ready
            ? (isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded)
            : Icons.play_arrow_rounded;

    return SizedBox(
      width: 200,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color:
              widget.isMine ? const Color(0xFF007AFF) : const Color(0xFFe8e8ec),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            GestureDetector(
              onTap: _downloading ? null : _togglePlay,
              child: Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color:
                      widget.isMine
                          ? Colors.white.withValues(alpha: 0.22)
                          : Colors.black12,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  icon,
                  color: widget.isMine ? Colors.white : Colors.black87,
                  size: 24,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  color: widget.isMine ? Colors.white : Colors.black87,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
