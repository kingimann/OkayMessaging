import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../state/voice_media.dart';

/// A voice-message row: a play/pause toggle, a static waveform, and the clip
/// length. Shared by the 1:1/group chat bubble and the server text-channel
/// bubble so a voice note plays the same everywhere.
class VoiceNoteBubble extends StatefulWidget {
  final int seconds;

  /// A short note's inline clip; null for a long (bucket-backed) one.
  final String? audioUrl;

  /// A long note's sealed object in the voice-notes bucket, and the key that
  /// unseals it; both null for an inline note.
  final String? audioPath;
  final String? audioKey;
  final Color textColor;
  final Color metaColor;

  const VoiceNoteBubble({
    super.key,
    required this.seconds,
    required this.audioUrl,
    required this.audioPath,
    required this.audioKey,
    required this.textColor,
    required this.metaColor,
  });

  @override
  State<VoiceNoteBubble> createState() => _VoiceNoteBubbleState();
}

class _VoiceNoteBubbleState extends State<VoiceNoteBubble> {
  // One player per bubble, made only when there is real audio to play.
  AudioPlayer? _player;
  bool _playing = false;
  bool _loading = false; // fetching a long note from the bucket
  Duration _position = Duration.zero;
  Duration _total = Duration.zero;
  final List<StreamSubscription<dynamic>> _subs = [];

  /// A long note's bytes, fetched and unsealed from the bucket once and kept
  /// so a replay doesn't download again.
  Uint8List? _fetched;

  /// Native platforms play the clip from a temp file (written once per
  /// bubble); web plays the bytes directly.
  String? _tempPath;

  // A fixed pseudo-waveform so bubbles look varied but stable.
  static const _heights = [
    6.0, 12.0, 18.0, 10.0, 22.0, 14.0, 8.0, 20.0, 16.0, 11.0,
    24.0, 9.0, 15.0, 19.0, 7.0, 13.0, 21.0, 10.0, 17.0, 12.0,
  ];

  /// Whether there is a clip to play at all — inline, or a bucket note we can
  /// fetch. Old voice messages carried only a duration, so their bubble says
  /// so rather than pretending to play.
  bool get _inline => (widget.audioUrl ?? '').isNotEmpty;
  bool get _bucketed =>
      (widget.audioPath ?? '').isNotEmpty && (widget.audioKey ?? '').isNotEmpty;
  bool get _playable => _inline || _bucketed;

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _player?.dispose();
    final temp = _tempPath;
    if (temp != null) {
      File(temp).delete().catchError((_) => File(temp));
    }
    super.dispose();
  }

  AudioPlayer _ensurePlayer() {
    final existing = _player;
    if (existing != null) return existing;
    final p = AudioPlayer();
    _subs.add(p.onPlayerStateChanged.listen((s) {
      if (mounted) setState(() => _playing = s == PlayerState.playing);
    }));
    _subs.add(p.onDurationChanged.listen((d) {
      if (mounted) setState(() => _total = d);
    }));
    _subs.add(p.onPositionChanged.listen((d) {
      if (mounted) setState(() => _position = d);
    }));
    _subs.add(p.onPlayerComplete.listen((_) {
      if (mounted) setState(() => _position = Duration.zero);
    }));
    _player = p;
    return p;
  }

  Future<void> _toggle() async {
    if (!_playable || _loading) return;
    final p = _ensurePlayer();
    if (_playing) {
      await p.pause();
      return;
    }
    // A long note is fetched and unsealed from the bucket once, then cached.
    Uint8List? bytes;
    if (_inline) {
      final comma = widget.audioUrl!.indexOf(',');
      bytes = Uint8List.fromList(
          base64Decode(widget.audioUrl!.substring(comma + 1)));
    } else {
      bytes = _fetched;
      if (bytes == null) {
        setState(() => _loading = true);
        bytes =
            await VoiceMedia.instance.download(widget.audioPath!, widget.audioKey!);
        _fetched = bytes;
        if (mounted) setState(() => _loading = false);
        if (bytes == null) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                content: Text('Couldn\'t load that voice note.')));
          }
          return;
        }
      }
    }
    if (_position >= _total && _total > Duration.zero) {
      await p.seek(Duration.zero);
    }
    // The record plugin leaves iOS's audio session in playAndRecord after a
    // voice note is captured, and a call leaves its own configuration too —
    // in both, playback routes to the EARPIECE, which is the "volume drops
    // way low, then jumps back up" report (it depended on what ran last).
    // Reasserting the playback category before every play routes the clip
    // to the speaker at proper volume every time.
    if (!kIsWeb) {
      try {
        await AudioPlayer.global.setAudioContext(AudioContext(
          iOS: AudioContextIOS(category: AVAudioSessionCategory.playback),
        ));
      } catch (_) {}
    }
    try {
      await p.play(await _sourceFor(bytes));
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Couldn\'t play that voice note.')));
      }
    }
  }

  /// Where the player reads the clip from. BytesSource only exists on web
  /// and Android — audioplayers' iOS side answers `setSourceBytes is not
  /// currently implemented` — so native platforms write the decoded clip to
  /// a temp file once and play from that.
  Future<Source> _sourceFor(Uint8List bytes) async {
    if (kIsWeb) return BytesSource(bytes, mimeType: 'audio/mp4');
    var path = _tempPath;
    if (path == null) {
      final dir = await getTemporaryDirectory();
      path = '${dir.path}/vn_play_'
          '${DateTime.now().microsecondsSinceEpoch}.m4a';
      await File(path).writeAsBytes(bytes, flush: true);
      _tempPath = path;
    }
    return DeviceFileSource(path, mimeType: 'audio/mp4');
  }

  /// The elapsed/total counter — real once playing, the recorded length at
  /// rest so the bubble still says how long the note is.
  String get _label {
    final shown = _playing || _position > Duration.zero
        ? _position.inSeconds
        : widget.seconds;
    final m = shown ~/ 60;
    final s = shown % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  /// 0..1 through the clip, for lighting the waveform as it plays.
  double get _progress {
    final total = _total.inMilliseconds;
    if (total <= 0) return 0;
    return (_position.inMilliseconds / total).clamp(0.0, 1.0);
  }

  @override
  Widget build(BuildContext context) {
    // The bubble's OWN text colour, never the app accent.
    //
    // This used to reach for the theme accent (the colorScheme primary), and in
    // both themes that is exactly the outgoing bubble's background: dark mode
    // paints primary and outgoingBubbleDark the same #E7E9EA, light mode
    // paints primary and outgoingBubbleLight the same #0F1419. So a voice
    // note you SENT drew its play button in the colour of the bubble under
    // it and disappeared, while the same widget on an incoming bubble looked
    // fine — which is why it only went wrong sometimes. textColor/metaColor
    // are already computed against this bubble's background (including a
    // custom one), so they are the only safe source here.
    final accent = widget.textColor;
    return SizedBox(
      width: 210,
      child: Row(
        children: [
          GestureDetector(
            onTap: _playable ? _toggle : null,
            child: _loading
                ? SizedBox(
                    width: 26,
                    height: 26,
                    child: Padding(
                      padding: const EdgeInsets.all(3),
                      child: CircularProgressIndicator(
                          strokeWidth: 2.4, color: accent),
                    ),
                  )
                : Icon(
                    !_playable
                        ? Icons.mic_off_outlined
                        : (_playing ? Icons.pause : Icons.play_arrow),
                    color: _playable ? accent : widget.metaColor,
                    size: 30,
                  ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: !_playable
                // An old note with no clip: say it plainly instead of a
                // waveform that does nothing.
                ? Text('Can\'t be played',
                    style: TextStyle(color: widget.metaColor, fontSize: 12.5))
                : SizedBox(
                    height: 26,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        for (var i = 0; i < _heights.length; i++)
                          Expanded(
                            child: Container(
                              margin:
                                  const EdgeInsets.symmetric(horizontal: 0.5),
                              height: _heights[i],
                              decoration: BoxDecoration(
                                // The bars up to the play head take the accent;
                                // the rest stay muted.
                                color: (i / _heights.length) <= _progress
                                    ? accent
                                    : widget.metaColor,
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
          ),
          const SizedBox(width: 8),
          Text(_label, style: TextStyle(color: widget.metaColor, fontSize: 12)),
        ],
      ),
    );
  }
}
