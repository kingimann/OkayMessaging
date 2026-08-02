import 'package:flutter/material.dart';

import '../state/screenshot_watch.dart';

/// The one viewing a ghost message gets.
///
/// The words appear here and nowhere else: the transcript bubble never shows
/// them, and closing this screen is what spends the single view (the caller
/// consumes on return). Two kinds of capture are handled differently, because
/// they are different:
///
///  * A screen recording or mirror is happening NOW, so the text is taken off
///    the screen for as long as it lasts — showing it would be reading the
///    message into a camera. This is the honest version of a "black
///    screenshot": it never renders while anything is capturing.
///  * A screenshot can only be noticed after the fact — iOS has no way to
///    block one — so it is announced instead, to both sides, via
///    [onScreenshot].
class GhostViewScreen extends StatefulWidget {
  const GhostViewScreen({
    super.key,
    required this.text,
    required this.senderName,
    this.onScreenshot,
  });

  final String text;
  final String senderName;

  /// Fired once per screenshot taken while this screen is on top.
  final VoidCallback? onScreenshot;

  @override
  State<GhostViewScreen> createState() => _GhostViewScreenState();
}

class _GhostViewScreenState extends State<GhostViewScreen> {
  @override
  void initState() {
    super.initState();
    ScreenshotWatch.instance.taken.addListener(_onShot);
    ScreenshotWatch.instance.capturing.addListener(_onCapture);
  }

  @override
  void dispose() {
    ScreenshotWatch.instance.taken.removeListener(_onShot);
    ScreenshotWatch.instance.capturing.removeListener(_onCapture);
    super.dispose();
  }

  void _onShot() {
    if (!mounted) return;
    // Only while actually on top — a screenshot of whatever replaced this
    // screen is not a screenshot of the message.
    if (ModalRoute.of(context)?.isCurrent ?? true) {
      widget.onScreenshot?.call();
    }
  }

  void _onCapture() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final capturing = ScreenshotWatch.instance.capturing.value;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(widget.senderName,
            style: const TextStyle(fontSize: 16.5)),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(28, 8, 28, 28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: Center(
                  child: capturing
                      ? const Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.videocam_off_outlined,
                                size: 44, color: Colors.white38),
                            SizedBox(height: 14),
                            Text(
                              'Hidden while the screen is being recorded '
                              'or mirrored.',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                  color: Colors.white70, fontSize: 15),
                            ),
                          ],
                        )
                      : SingleChildScrollView(
                          child: Text(
                            widget.text,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 22,
                                height: 1.4),
                          ),
                        ),
                ),
              ),
              const Text(
                // The words this screen can stand behind: a screenshot is
                // announced, never blocked — iOS offers no way to block one.
                'This can be read once. Screenshots can\'t be blocked, '
                'but both of you see a note if one is taken.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white38, fontSize: 12.5),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
