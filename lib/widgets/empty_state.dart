import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// The app's one empty-state look: a tonal icon, a bold line saying what's
/// empty, a grey line saying how it fills, and optionally a button that does
/// it — matching the dialog language, so every blank screen reads the same.
class EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String caption;
  final String? actionLabel;
  final VoidCallback? onAction;

  /// An optional second, quieter action shown as a text button under the
  /// primary one — e.g. "Join with a code" beneath "Create a server".
  final String? secondaryLabel;
  final VoidCallback? onSecondary;

  /// Compact fits inline in a list (e.g. under a section header); the
  /// default centres itself in the space it's given.
  final bool compact;

  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.caption,
    this.actionLabel,
    this.onAction,
    this.secondaryLabel,
    this.onSecondary,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final accent = AppColors.accentOn(context);
    final column = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        CircleAvatar(
          radius: compact ? 26 : 34,
          backgroundColor: accent.withValues(alpha: 0.07),
          child: Icon(icon,
              size: compact ? 26 : 34, color: accent.withValues(alpha: 0.55)),
        ),
        SizedBox(height: compact ? 12 : 16),
        Text(
          title,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: compact ? 15.5 : 17,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 5),
        Text(
          caption,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: compact ? 13 : 13.5,
            height: 1.4,
            color: AppColors.subtle(context),
          ),
        ),
        if (actionLabel != null) ...[
          const SizedBox(height: 16),
          FilledButton(onPressed: onAction, child: Text(actionLabel!)),
        ],
        if (secondaryLabel != null) ...[
          const SizedBox(height: 4),
          TextButton(onPressed: onSecondary, child: Text(secondaryLabel!)),
        ],
      ],
    );
    final padded = Padding(
      padding: EdgeInsets.symmetric(
          horizontal: 36, vertical: compact ? 20 : 32),
      child: column,
    );
    return compact ? Center(child: padded) : Center(child: padded);
  }
}

/// The app's one section-header look — the uppercase, letter-spaced label the
/// Settings screen established, for every list that groups rows under a name.
class SectionHeader extends StatelessWidget {
  final String text;
  const SectionHeader(this.text, {super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
      child: Text(
        text.toUpperCase(),
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.7,
          color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.6),
        ),
      ),
    );
  }
}
