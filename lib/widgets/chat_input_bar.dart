import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../app_state.dart';
import '../models/message.dart';
import '../state/voice_media.dart';
import '../theme/app_theme.dart';
import '../util/photo_prep.dart';
import 'emoji_gif_sheet.dart';

/// One entry in the composer's inline attachment panel.
class AttachmentOption {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  const AttachmentOption({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });
}

/// The bottom input area: an optional reply preview, an optional emoji picker,
/// attachment icons, a text field and a send/mic button.
class ChatInputBar extends StatefulWidget {
  /// Test seam: when set, recording skips the real microphone and this
  /// supplies the captured clip's raw bytes. Mirrors
  /// [PhotoPrep.debugPickOverride] — there is no mic in a test.
  @visibleForTesting
  static Future<Uint8List?> Function()? debugCaptureOverride;

  final ValueChanged<String> onSend;

  /// Tapping the paperclip opens these inline (in the keyboard's space)
  /// rather than in a modal sheet, so the conversation stays visible. When
  /// empty, [onAttach] fires instead.
  final List<AttachmentOption> attachments;
  final VoidCallback? onAttach;

  /// Called when a voice message is sent. A short clip arrives inline as
  /// [audioUrl] (a `data:audio/…` URI); a long one as a sealed [audioPath] in
  /// the voice-notes bucket plus its [audioKey]. All three are null when
  /// capture or upload failed, so the caller sends nothing.
  final void Function(int seconds,
      {String? audioUrl, String? audioPath, String? audioKey})? onSendVoice;

  /// The message currently being replied to (shows a quote banner).
  final ReplyInfo? replyTo;
  final VoidCallback? onCancelReply;

  /// Called as the user types (used to broadcast a typing indicator).
  final VoidCallback? onTyping;

  /// Long-pressing send offers to schedule the current text; returns true when
  /// a message was scheduled (so the field is cleared).
  final Future<bool> Function(String text)? onSchedule;

  /// Text to pre-fill the composer with (a saved draft).
  final String initialText;

  /// Called as the composer text changes, so the draft can be saved.
  final ValueChanged<String>? onChanged;

  /// Optional guard run before a text or voice message is sent. When it
  /// resolves false, the send is cancelled and the composer text is kept.
  final Future<bool> Function()? confirmSend;

  /// Names that can be @mentioned (group members). Empty disables mentions.
  final List<String> mentionNames;

  /// Called with the chosen GIF's URL when one is picked from the picker.
  final ValueChanged<String>? onSendGif;

  /// Short replies the device suggested for the last incoming message.
  ///
  /// Empty is the normal case — most phones cannot generate these at all, and
  /// nothing is shown when none came back.
  final List<String> suggestedReplies;

  const ChatInputBar({
    super.key,
    required this.onSend,
    this.attachments = const [],
    this.onAttach,
    this.onSendVoice,
    this.replyTo,
    this.onCancelReply,
    this.onTyping,
    this.onSchedule,
    this.initialText = '',
    this.onChanged,
    this.confirmSend,
    this.mentionNames = const [],
    this.onSendGif,
    this.suggestedReplies = const [],
  });

  @override
  State<ChatInputBar> createState() => _ChatInputBarState();
}

class _ChatInputBarState extends State<ChatInputBar> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initialText);
  bool _hasText = false;
  bool _emojiOpen = false;
  bool _attachOpen = false;

  bool _recording = false;
  int _recordSeconds = 0;
  Timer? _recordTimer;
  final AudioRecorder _recorder = AudioRecorder();

  /// The composer auto-stops here. A note up to this long fits the bucket
  /// (well under [VoiceMedia.maxBytes] at the low bitrate voice records at);
  /// a shorter one that also fits the relay envelope rides inline instead.
  static const int _maxVoiceSeconds = 300;

  Future<Uint8List?> Function()? get debugCaptureOverride =>
      ChatInputBar.debugCaptureOverride;

  List<String> _mentionMatches = const [];

  @override
  void initState() {
    super.initState();
    _hasText = _controller.text.trim().isNotEmpty;
    _controller.addListener(() {
      final has = _controller.text.trim().isNotEmpty;
      if (has != _hasText) setState(() => _hasText = has);
      if (has) widget.onTyping?.call();
      widget.onChanged?.call(_controller.text);
      _updateMentions();
    });
  }

  /// The partial name being typed after an "@" at the cursor, or null when the
  /// cursor isn't inside a mention token.
  String? _mentionQuery() {
    if (widget.mentionNames.isEmpty) return null;
    final sel = _controller.selection;
    if (!sel.isValid || sel.baseOffset != sel.extentOffset) return null;
    final pos = sel.baseOffset;
    if (pos < 0 || pos > _controller.text.length) return null;
    final before = _controller.text.substring(0, pos);
    final at = before.lastIndexOf('@');
    if (at < 0) return null;
    if (at > 0 && !RegExp(r'\s').hasMatch(before[at - 1])) return null;
    final query = before.substring(at + 1);
    if (query.contains(RegExp(r'\s'))) return null;
    return query;
  }

  void _updateMentions() {
    final q = _mentionQuery();
    final matches = q == null
        ? const <String>[]
        : widget.mentionNames
            .where((n) => n.toLowerCase().startsWith(q.toLowerCase()))
            .take(5)
            .toList();
    if (matches.length != _mentionMatches.length ||
        !matches.every(_mentionMatches.contains)) {
      setState(() => _mentionMatches = matches);
    }
  }

  void _applyMention(String name) {
    final pos = _controller.selection.baseOffset;
    final text = _controller.text;
    final before = text.substring(0, pos);
    final at = before.lastIndexOf('@');
    final newBefore = '${before.substring(0, at)}@$name ';
    final newText = newBefore + text.substring(pos);
    _controller.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: newBefore.length),
    );
    setState(() => _mentionMatches = const []);
  }

  @override
  void dispose() {
    _recordTimer?.cancel();
    _recorder.dispose();
    _controller.dispose();
    super.dispose();
  }

  Future<void> _startRecording() async {
    // No permission, no recording — and no fake bubble either. Better to do
    // nothing than to record silence the other end can't play. Skipped under
    // the test seam, which has no mic to ask.
    if (debugCaptureOverride == null && !await _recorder.hasPermission()) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Microphone access is needed for voice notes.')));
      }
      return;
    }
    setState(() {
      _recording = true;
      _recordSeconds = 0;
      _emojiOpen = false;
    });
    if (debugCaptureOverride == null) {
      try {
        // Low-bitrate mono AAC: a voice note is speech, and it has to fit the
        // relay envelope; a path is needed off the web, ignored on it.
        final path = kIsWeb
            ? ''
            : '${(await getTemporaryDirectory()).path}/'
                'vn_${DateTime.now().microsecondsSinceEpoch}.m4a';
        await _recorder.start(
          const RecordConfig(
              encoder: AudioEncoder.aacLc,
              bitRate: 20000,
              sampleRate: 22050,
              numChannels: 1),
          path: path,
        );
      } catch (_) {
        _recordTimer?.cancel();
        if (mounted) setState(() => _recording = false);
        return;
      }
    }
    _recordTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _recordSeconds++);
      // Auto-stop at the ceiling so the clip always fits the envelope.
      if (_recordSeconds >= _maxVoiceSeconds) _finishRecording();
    });
  }

  Future<void> _cancelRecording() async {
    _recordTimer?.cancel();
    if (debugCaptureOverride == null) {
      try {
        await _recorder.stop();
      } catch (_) {}
    }
    if (mounted) setState(() => _recording = false);
  }

  Future<void> _finishRecording() async {
    _recordTimer?.cancel();
    final seconds = _recordSeconds < 1 ? 1 : _recordSeconds;
    if (mounted) setState(() => _recording = false);

    Uint8List? bytes;
    if (debugCaptureOverride != null) {
      bytes = await debugCaptureOverride!();
    } else {
      String? path;
      try {
        path = await _recorder.stop();
      } catch (_) {}
      bytes = path == null ? null : await _readAudio(path);
    }
    if (bytes == null || bytes.isEmpty) {
      _voiceError('Couldn\'t save that voice note — try again.');
      return;
    }
    if (widget.confirmSend != null && !await widget.confirmSend!()) return;

    // Short enough to ride the relay inline (the same budget a chat photo
    // has) → send it as a data: URI. Longer → seal it into the voice-notes
    // bucket and send only the path + key.
    final b64 = base64Encode(bytes);
    if (b64.length <= PhotoPrep.maxBase64Length) {
      widget.onSendVoice?.call(seconds, audioUrl: 'data:audio/mp4;base64,$b64');
      return;
    }
    try {
      final up = await VoiceMedia.instance.upload(bytes);
      widget.onSendVoice
          ?.call(seconds, audioPath: up.path, audioKey: up.key);
    } on VoiceMediaError catch (e) {
      _voiceError(e.reason);
    } catch (_) {
      _voiceError('Couldn\'t upload that voice note — check your connection.');
    }
  }

  void _voiceError(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  }

  /// The recorded clip's raw bytes. On the web `stop()` hands back a `blob:`
  /// URL whose bytes are fetched; elsewhere it is a file path.
  Future<Uint8List?> _readAudio(String path) async {
    try {
      return kIsWeb
          ? (await http.get(Uri.parse(path))).bodyBytes
          : await File(path).readAsBytes();
    } catch (_) {
      return null;
    }
  }

  String get _recordLabel {
    final m = _recordSeconds ~/ 60;
    final s = _recordSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  Future<void> _send() async {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    // Ask for confirmation first when the chat is guarded; keep the text if
    // the user backs out.
    if (widget.confirmSend != null && !await widget.confirmSend!()) return;
    widget.onSend(text);
    _controller.clear();
  }

  Future<void> _schedule() async {
    final text = _controller.text.trim();
    if (text.isEmpty || widget.onSchedule == null) return;
    final scheduled = await widget.onSchedule!(text);
    if (scheduled) _controller.clear();
  }

  /// Opens the picker on its GIF tab and hands the chosen GIF back up.

  void _insertEmoji(String emoji) {
    final sel = _controller.selection;
    final text = _controller.text;
    if (sel.isValid) {
      final newText = text.replaceRange(sel.start, sel.end, emoji);
      _controller.value = TextEditingValue(
        text: newText,
        selection: TextSelection.collapsed(offset: sel.start + emoji.length),
      );
    } else {
      _controller.text = text + emoji;
    }
  }

  /// A tapped suggestion becomes the draft — it is NOT sent.
  ///
  /// The model guessed at what somebody meant to say. Sending that on one tap
  /// puts words in their mouth and into somebody else's chat, and there is no
  /// unsending. Filling the field costs one more tap and keeps the decision
  /// where it belongs.
  void _applySuggestion(String reply) {
    _controller.text = reply;
    _controller.selection =
        TextSelection.collapsed(offset: _controller.text.length);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // The input pill needs to stand out from the (white) chat background, so
    // it uses a soft grey in light mode rather than blending into white.
    final fieldColor =
        isDark ? AppColors.darkAppBar : const Color(0xFFEFF1F3);

    return DecoratedBox(
      // A hairline separates the composer from the conversation above it.
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(
            color: isDark ? const Color(0xFF2A2D31) : const Color(0xFFE8EAED),
            width: 0.6,
          ),
        ),
      ),
      child: SafeArea(
        top: false,
        // A little bottom breathing room so the bar isn't jammed against the
        // browser toolbar / gesture area on the web build.
        minimum: const EdgeInsets.only(bottom: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Only with an empty composer: once somebody starts typing
            // they have said what they want to say, and a row of alternatives
            // under their own words is just something else to dismiss.
            if (widget.suggestedReplies.isNotEmpty && !_hasText && !_recording)
              _SuggestedReplies(
                replies: widget.suggestedReplies,
                isDark: isDark,
                onPick: _applySuggestion,
              ),
            if (_mentionMatches.isNotEmpty && !_recording)
              _MentionSuggestions(
                names: _mentionMatches,
                isDark: isDark,
                onPick: _applyMention,
              ),
            if (widget.replyTo != null && !_recording)
              _ReplyPreview(
                reply: widget.replyTo!,
                onCancel: widget.onCancelReply,
                isDark: isDark,
              ),
            _recording
                ? _buildRecordingBar(isDark, fieldColor)
                : _buildComposer(isDark, fieldColor),
            if (_emojiOpen && !_recording)
              _EmojiPanel(onSelected: _insertEmoji, isDark: isDark),
            if (_attachOpen && !_recording)
              _AttachmentPanel(
                options: widget.attachments,
                isDark: isDark,
                onPicked: () => setState(() => _attachOpen = false),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildComposer(bool isDark, Color fieldColor) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 4, 6, 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: fieldColor,
                borderRadius: BorderRadius.circular(24),
              ),
              child: Row(
                children: [
                  IconButton(
                    icon: Icon(
                      _emojiOpen
                          ? Icons.keyboard
                          : Icons.emoji_emotions_outlined,
                    ),
                    color: Colors.grey,
                    onPressed: () => setState(() {
                      _emojiOpen = !_emojiOpen;
                      _attachOpen = false;
                      // The panel replaces the keyboard — never both at once.
                      if (_emojiOpen) {
                        FocusManager.instance.primaryFocus?.unfocus();
                      }
                    }),
                  ),
                  Expanded(
                    child: ValueListenableBuilder<bool>(
                      valueListenable: AppState.enterToSend,
                      builder: (context, enterToSend, _) => TextField(
                        controller: _controller,
                        minLines: 1,
                        maxLines: 5,
                        textCapitalization: TextCapitalization.sentences,
                        // When enter-to-send is on, the return key submits;
                        // otherwise it inserts a newline and the send button
                        // is used instead.
                        textInputAction: enterToSend
                            ? TextInputAction.send
                            : TextInputAction.newline,
                        onTap: () {
                          if (_emojiOpen || _attachOpen) {
                            setState(() {
                              _emojiOpen = false;
                              _attachOpen = false;
                            });
                          }
                        },
                        decoration: const InputDecoration(
                          hintText: 'Message',
                          border: InputBorder.none,
                        ),
                        onSubmitted: enterToSend ? (_) => _send() : null,
                      ),
                    ),
                  ),
                  // GIFs are a one-tap thing everywhere people know them
                  // from; buried in the attachment panel they read as
                  // missing. Straight onto the picker's GIF tab — which
                  // also has emoji, so the whole expressive kit is one tap.
                  if (widget.onSendGif != null)
                    IconButton(
                      icon: const Icon(Icons.gif_box_outlined),
                      color: Colors.grey,
                      tooltip: 'GIF',
                      onPressed: () async {
                        setState(() {
                          _emojiOpen = false;
                          _attachOpen = false;
                        });
                        final picked =
                            await showEmojiGifSheet(context, initialTab: 1);
                        final url = picked?.gif?.url;
                        if (url != null) widget.onSendGif?.call(url);
                        final emoji = picked?.emoji;
                        if (emoji != null) _insertEmoji(emoji);
                      },
                    ),
                  // One attach button owns everything else that isn't
                  // typing — photos, documents, and the rest live in its
                  // panel, so the bar stays lean.
                  IconButton(
                    icon: Icon(_attachOpen ? Icons.close : Icons.attach_file),
                    color: Colors.grey,
                    tooltip: 'Attach',
                    onPressed: widget.attachments.isEmpty
                        ? widget.onAttach
                        : () => setState(() {
                              _attachOpen = !_attachOpen;
                              _emojiOpen = false;
                              // The panel replaces the keyboard — never
                              // both stacked at once.
                              if (_attachOpen) {
                                FocusManager.instance.primaryFocus?.unfocus();
                              }
                            }),
                  ),
                ],
              ),
            ),
          ),
          // SCHEDULING, WHERE IT CAN BE FOUND. It has worked for a long time
          // by long-pressing send, which nothing advertises and nobody
          // discovers — the long-press still works, and now there is a
          // button too. Only once something is typed: an empty box has
          // nothing to schedule, and a permanently-there clock would be a
          // control that does nothing most of the time.
          if (_hasText && widget.onSchedule != null) ...[
            const SizedBox(width: 2),
            IconButton(
              icon: const Icon(Icons.schedule),
              tooltip: 'Send later',
              onPressed: _schedule,
            ),
          ],
          const SizedBox(width: 6),
          GestureDetector(
            onTap: _hasText ? _send : _startRecording,
            onLongPress: _hasText ? _schedule : null,
            child: CircleAvatar(
              radius: 24,
              backgroundColor: AppColors.accentOn(context),
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                transitionBuilder: (child, animation) =>
                    ScaleTransition(scale: animation, child: child),
                child: Icon(
                  _hasText ? Icons.send : Icons.mic,
                  key: ValueKey(_hasText),
                  color: AppColors.onAccent(context),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRecordingBar(bool isDark, Color fieldColor) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 4, 6, 6),
      child: Row(
        children: [
          Expanded(
            child: Container(
              height: 48,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: fieldColor,
                borderRadius: BorderRadius.circular(24),
              ),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.delete, color: Colors.red),
                    onPressed: _cancelRecording,
                    tooltip: 'Cancel',
                  ),
                  const Icon(Icons.fiber_manual_record,
                      color: Colors.red, size: 14),
                  const SizedBox(width: 8),
                  Text(_recordLabel,
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                  const Spacer(),
                  const Text('Recording…',
                      style: TextStyle(color: Colors.grey)),
                ],
              ),
            ),
          ),
          const SizedBox(width: 6),
          GestureDetector(
            onTap: _finishRecording,
            child: CircleAvatar(
              radius: 24,
              backgroundColor: AppColors.accentOn(context),
              child: Icon(Icons.send, color: AppColors.onAccent(context)),
            ),
          ),
        ],
      ),
    );
  }
}

/// A dropdown of @mention candidates shown above the composer while typing.
/// A row of tappable suggested replies above the composer.
class _SuggestedReplies extends StatelessWidget {
  final List<String> replies;
  final bool isDark;
  final ValueChanged<String> onPick;

  const _SuggestedReplies({
    required this.replies,
    required this.isDark,
    required this.onPick,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(10, 4, 10, 4),
        children: [
          for (final reply in replies)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ActionChip(
                label: Text(reply,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13.5)),
                // Tinted rather than filled: a suggestion is an offer, and it
                // should not compete with the send button next to it.
                backgroundColor: isDark
                    ? scheme.surfaceContainerHighest.withValues(alpha: 0.5)
                    : scheme.primary.withValues(alpha: 0.08),
                side: BorderSide(
                    color: scheme.primary.withValues(alpha: 0.25), width: 0.8),
                labelStyle: TextStyle(color: scheme.onSurface),
                onPressed: () => onPick(reply),
              ),
            ),
        ],
      ),
    );
  }
}

class _MentionSuggestions extends StatelessWidget {
  final List<String> names;
  final bool isDark;
  final ValueChanged<String> onPick;

  const _MentionSuggestions({
    required this.names,
    required this.isDark,
    required this.onPick,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(8, 4, 8, 0),
      constraints: const BoxConstraints(maxHeight: 200),
      child: Material(
        color: isDark ? AppColors.darkAppBar : Colors.white,
        elevation: 3,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: ListView(
          shrinkWrap: true,
          padding: EdgeInsets.zero,
          children: [
            for (final name in names)
              ListTile(
                dense: true,
                leading: CircleAvatar(
                  radius: 15,
                  backgroundColor: AppColors.accentOn(context),
                  child: Text(
                    name.isEmpty ? '?' : name[0].toUpperCase(),
                    style: TextStyle(
                        color: AppColors.onAccent(context), fontSize: 13),
                  ),
                ),
                title: Text('@$name'),
                onTap: () => onPick(name),
              ),
          ],
        ),
      ),
    );
  }
}

class _ReplyPreview extends StatelessWidget {
  final ReplyInfo reply;
  final VoidCallback? onCancel;
  final bool isDark;

  const _ReplyPreview({
    required this.reply,
    required this.onCancel,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(8, 4, 8, 0),
      padding: const EdgeInsets.fromLTRB(10, 6, 4, 6),
      decoration: BoxDecoration(
        color: isDark ? AppColors.darkAppBar : Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border(
          left: BorderSide(color: AppColors.accentOn(context), width: 4),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  reply.isMe ? 'You' : reply.senderName,
                  style: TextStyle(
                    color: AppColors.accentOn(context),
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
                Text(
                  reply.text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: isDark ? Colors.white70 : Colors.black54,
                    fontSize: 13.5,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 20),
            color: Colors.grey,
            onPressed: onCancel,
          ),
        ],
      ),
    );
  }
}

/// The composer's inline emoji panel: the full catalog, searchable, in the
/// space the keyboard would take.
/// The inline attachment grid: shown where the keyboard sits, so picking
/// what to send never covers the conversation.
class _AttachmentPanel extends StatelessWidget {
  final List<AttachmentOption> options;
  final bool isDark;

  /// Called after an option is tapped so the bar can fold the panel away.
  final VoidCallback onPicked;

  const _AttachmentPanel({
    required this.options,
    required this.isDark,
    required this.onPicked,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: isDark ? AppColors.chatBgDark : const Color(0xFFF0F0F0),
      padding: const EdgeInsets.fromLTRB(12, 14, 12, 14),
      // Two rows that scroll sideways, not a taller and taller grid: this
      // panel has grown past what one screen of rows can hold (a fixed
      // five-across grid wrapped to a third row that fell off a short
      // screen and pushed the composer around). A fixed height keeps the
      // composer where it was however many options exist; scrolling keeps
      // every option reachable.
      child: SizedBox(
        height: 188,
        child: GridView.count(
          scrollDirection: Axis.horizontal,
          crossAxisCount: 2,
          mainAxisSpacing: 8,
          crossAxisSpacing: 12,
          // height/width of a cell; slightly wide so five columns peek on a
          // phone width and the panel visibly wants to be scrolled.
          childAspectRatio: 1.15,
          children: [
            for (final option in options)
              InkWell(
                borderRadius: BorderRadius.circular(14),
                onTap: () {
                  onPicked();
                  option.onTap();
                },
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircleAvatar(
                      radius: 25,
                      backgroundColor: option.color,
                      child: Icon(option.icon, color: Colors.white, size: 24),
                    ),
                    const SizedBox(height: 6),
                    Text(option.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12)),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _EmojiPanel extends StatelessWidget {
  final ValueChanged<String> onSelected;
  final bool isDark;

  const _EmojiPanel({required this.onSelected, required this.isDark});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 260,
      color: isDark ? AppColors.chatBgDark : const Color(0xFFF0F0F0),
      child: EmojiPane(onPick: onSelected),
    );
  }
}
