import 'package:flutter/material.dart';

import '../state/parental_controls.dart';
import '../theme/app_theme.dart';

/// Stands in front of a surface a parent has turned off.
///
/// Wrapped around the SCREEN, never the row that opens it — the same rule as
/// [PhoneGate] and for the same reason: a drawer row is one way in of
/// several. There is deliberately no PIN entry here: a gate that unlocks
/// where it stands teaches the PIN in front of the child. Changing what is
/// blocked happens in Settings → Privacy & security → Parental controls,
/// which asks for the PIN before showing its toggles.
class ParentalGate extends StatelessWidget {
  const ParentalGate({
    super.key,
    required this.restriction,
    required this.title,
    required this.child,
    this.scaffold = true,
  });

  final ParentalRestriction restriction;

  /// What is behind the gate — "Wallet", "Marketplace", "Newsfeed".
  final String title;

  /// False when this is a tab body rather than a pushed screen.
  final bool scaffold;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ParentalControls.instance,
      builder: (context, _) {
        if (!ParentalControls.instance.blocks(restriction)) return child;
        final body = Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(28, 24, 28, 40),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.family_restroom,
                    size: 54, color: AppColors.subtle(context)),
                const SizedBox(height: 18),
                Text(
                  '$title is turned off',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontSize: 19, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 10),
                Text(
                  'Parental controls on this phone have turned this off. '
                  'A parent can change that in Settings → Privacy & '
                  'security → Parental controls.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 14.5,
                      height: 1.45,
                      color: AppColors.subtle(context)),
                ),
              ],
            ),
          ),
        );
        if (!scaffold) return body;
        return Scaffold(appBar: AppBar(title: Text(title)), body: body);
      },
    );
  }
}
