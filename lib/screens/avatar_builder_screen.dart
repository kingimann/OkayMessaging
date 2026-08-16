import 'package:avatar_maker/avatar_maker.dart';
import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../util/avatar_face.dart';

/// Build your own cartoon face — the Snapchat-shaped avatar.
///
/// Pops the SELECTION string (which nose, which hair, which colours) so the
/// caller can store it on the profile, or null if they backed out. It never
/// writes the profile itself: this screen is reached from Edit profile, and
/// the one place that decides what a saved profile contains should stay the
/// one place.
///
/// **The controller is deliberately the NON-persistent one.** The package's
/// persistent controller keeps the selection in SharedPreferences under its
/// own key, which would be a second, invisible copy of the avatar living
/// outside the profile — and outside `account_wipe`, so the next account on
/// this phone would inherit the last one's face. The profile is the only
/// store; this screen just edits a value and hands it back.
class AvatarBuilderScreen extends StatefulWidget {
  const AvatarBuilderScreen({super.key, this.initial = ''});

  /// The face being edited, if there is one. Empty starts from the defaults.
  final String initial;

  @override
  State<AvatarBuilderScreen> createState() => _AvatarBuilderScreenState();
}

class _AvatarBuilderScreenState extends State<AvatarBuilderScreen> {
  late final AvatarMakerController _controller =
      NonPersistentAvatarMakerController(locale: const Locale('en'));
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _restore();
  }

  Future<void> _restore() async {
    // The constructor starts an init it does not wait for, and that init
    // ends by reassigning the selection — so anything applied before it
    // lands is thrown away and the customizer opens on the defaults.
    await _controller.initController();
    if (AvatarFace.looksValid(widget.initial)) {
      // Reopening lands on the face they already have rather than on the
      // defaults — otherwise "change my hair" means rebuilding the whole
      // person.
      try {
        await _controller.saveAvatarSVG(jsonAvatarOptions: widget.initial);
      } catch (_) {
        // A selection this build cannot read: start from the defaults rather
        // than refusing to open the screen.
      }
    }
    if (mounted) setState(() => _ready = true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _save() {
    // Sanitised on the way out, so what is stored is exactly what another
    // device can draw — the package emits three effect keys its own decoder
    // chokes on. See [AvatarFace.faceKeys].
    final built = AvatarFace.sanitize(_controller.getJsonOptionsSync());
    Navigator.of(context).pop(built.isEmpty ? null : built);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Build your avatar'),
        actions: [
          TextButton(
            onPressed: _ready ? _save : null,
            child: const Text('Save'),
          ),
        ],
      ),
      body: !_ready
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Expanded(
                  child: AvatarMakerCustomizer(
                    controller: _controller,
                    // Nothing is written anywhere until Save is tapped — the
                    // profile is saved by Edit profile, and autosaving here
                    // would change the avatar of somebody who backed out.
                    autosave: false,
                    theme: AvatarMakerThemeData(
                      primaryBgColor:
                          Theme.of(context).scaffoldBackgroundColor,
                      secondaryBgColor:
                          Theme.of(context).scaffoldBackgroundColor,
                      selectedIconColor: AppColors.accentOn(context),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                  child: Text(
                    // Worth saying once, because it is the reason this is
                    // built in rather than borrowed from Bitmoji: the face is
                    // drawn on the phone and shared with your contacts the
                    // same way your name is.
                    'Drawn on your phone. Your contacts see it the way they '
                    'see your name — nobody else is involved.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontSize: 12.5, color: AppColors.subtle(context)),
                  ),
                ),
              ],
            ),
    );
  }
}
