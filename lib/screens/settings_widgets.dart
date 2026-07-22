import 'package:flutter/material.dart';

import '../app_state.dart';

/// Rounded shape shared by all settings list tiles.
const RoundedRectangleBorder kSettingsTileShape = RoundedRectangleBorder(
  borderRadius: BorderRadius.all(Radius.circular(16)),
);

/// A small uppercase section header used throughout Settings.
Widget settingsSectionLabel(BuildContext context, String text) => Padding(
      padding: const EdgeInsets.fromLTRB(24, 18, 24, 2),
      child: Text(
        text.toUpperCase(),
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.7,
          color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.7),
        ),
      ),
    );

/// A settings row that opens a picker for an Everyone / My contacts / Nobody
/// audience, backed by [notifier].
class AudienceTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final ValueNotifier<PrivacyAudience> notifier;

  const AudienceTile({
    super.key,
    required this.icon,
    required this.title,
    required this.notifier,
  });

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<PrivacyAudience>(
      valueListenable: notifier,
      builder: (context, value, _) => ListTile(
        shape: kSettingsTileShape,
        leading: Icon(icon),
        title: Text(title),
        subtitle: Text(value.label),
        trailing: const Icon(Icons.chevron_right, color: Colors.grey),
        onTap: () => _pick(context),
      ),
    );
  }

  Future<void> _pick(BuildContext context) async {
    final chosen = await showModalBottomSheet<PrivacyAudience>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
              child: Text(title,
                  style: Theme.of(sheetContext).textTheme.titleMedium),
            ),
            for (final a in PrivacyAudience.values)
              ListTile(
                title: Text(a.label),
                trailing: a == notifier.value
                    ? Icon(Icons.check,
                        color: Theme.of(sheetContext).colorScheme.primary)
                    : null,
                onTap: () => Navigator.of(sheetContext).pop(a),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (chosen != null) notifier.value = chosen;
  }
}
