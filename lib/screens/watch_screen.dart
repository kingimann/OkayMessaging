import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/link_preview.dart';
import '../theme/app_theme.dart';
import '../widgets/info_section.dart';
import 'home_screen.dart' show HomeNavBar;
import 'video_player_screen.dart';

/// Paste a link, watch it here.
///
/// The app has been able to play a YouTube link since link previews shipped
/// — but only a link somebody had already sent you in a chat. There was no
/// way to open one yourself, which is the whole of what this adds, now that
/// Twitch plays too.
///
/// **It plays what those two publish a player for, and says so.** There is
/// no stream fetching here and there will not be: both YouTube and Twitch
/// require their own embed, and pulling a playable URL out of either would
/// break their terms and break the app the next time they changed it. A
/// link they do not publish a player for is refused with the reason, rather
/// than opening a black rectangle.
class WatchScreen extends StatefulWidget {
  const WatchScreen({super.key});

  /// What a typed string can be played as, or null.
  ///
  /// Static and public so a test can reach it without a WebView: the parsing
  /// is what decides whether the button does anything, and a URL form is the
  /// thing that gets got wrong.
  static LinkPreview? previewFor(String typed) {
    var text = typed.trim();
    if (text.isEmpty) return null;
    if (!text.contains('://')) text = 'https://$text';
    final uri = Uri.tryParse(text);
    if (uri == null || uri.host.isEmpty) return null;
    final kind = linkKindOf(uri);
    final id = switch (kind) {
      LinkKind.youtube => youtubeIdOf(uri),
      LinkKind.twitch => twitchTargetOf(uri),
      _ => '',
    };
    if (id.isEmpty) return null;
    return LinkPreview(
      url: uri.toString(),
      kind: kind,
      host: prettyHost(uri),
      videoId: id,
    );
  }

  @override
  State<WatchScreen> createState() => _WatchScreenState();
}

class _WatchScreenState extends State<WatchScreen> {
  final _controller = TextEditingController();
  String _problem = '';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    if (text.isEmpty || !mounted) return;
    setState(() {
      _controller.text = text;
      _problem = '';
    });
  }

  void _play() {
    final preview = WatchScreen.previewFor(_controller.text);
    if (preview == null) {
      setState(() => _problem = _controller.text.trim().isEmpty
          ? 'Paste a YouTube or Twitch link.'
          : "That link isn't a YouTube video or a Twitch stream. Those are "
              'the two that publish a player this app is allowed to use.');
      return;
    }
    setState(() => _problem = '');
    FocusScope.of(context).unfocus();
    Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => VideoPlayerScreen(preview: preview)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBody: true,
      appBar: AppBar(title: const Text('Watch')),
      bottomNavigationBar: const HomeNavBar(),
      body: ListView(
        padding: EdgeInsets.fromLTRB(16, 12, 16, HomeNavBar.clearance(context)),
        children: [
          InfoSection(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
              child: TextField(
                controller: _controller,
                autocorrect: false,
                keyboardType: TextInputType.url,
                textInputAction: TextInputAction.go,
                onSubmitted: (_) => _play(),
                onChanged: (_) {
                  if (_problem.isNotEmpty) setState(() => _problem = '');
                },
                decoration: const InputDecoration(
                  labelText: 'Link',
                  hintText: 'youtube.com/watch?v=… or twitch.tv/…',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.link),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 4, 14, 14),
              child: Row(
                children: [
                  OutlinedButton.icon(
                    onPressed: _paste,
                    icon: const Icon(Icons.content_paste, size: 18),
                    label: const Text('Paste'),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _play,
                      icon: const Icon(Icons.play_arrow, size: 20),
                      label: const Text('Watch'),
                    ),
                  ),
                ],
              ),
            ),
          ]),
          if (_problem.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 12, 4, 0),
              child: Text(_problem,
                  style: TextStyle(
                      fontSize: 13.5,
                      color: Theme.of(context).colorScheme.error)),
            ),
          const SizedBox(height: 18),
          Text(
            // Said here rather than discovered by pasting one: the honest
            // shape of the feature, in the place somebody is about to try it.
            'YouTube videos and live streams, and Twitch channels, VODs and '
            'clips — each in its own official player. Other links open as '
            'pages.\n\n'
            'Watching connects your device to them directly, so they see '
            'your address and what you watched, the same as any browser. '
            'Nothing about it goes through OkayMessenger.',
            style: TextStyle(
                fontSize: 13, height: 1.45, color: AppColors.subtle(context)),
          ),
        ],
      ),
    );
  }
}
