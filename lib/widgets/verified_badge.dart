import 'package:flutter/material.dart';

/// The blue verified check mark. A filled circle with a white tick, sized to
/// sit next to a name.
class VerifiedBadge extends StatelessWidget {
  final double size;
  const VerifiedBadge({super.key, this.size = 16});

  @override
  Widget build(BuildContext context) {
    return Icon(
      Icons.verified,
      size: size,
      color: const Color(0xFF1D9BF0),
      semanticLabel: 'Verified',
    );
  }
}

/// A name followed by a verified check when [verified] is true, laid out so the
/// name ellipsizes but the badge is never clipped. Drop-in for a Row/Expanded.
class NameWithBadge extends StatelessWidget {
  final String name;
  final bool verified;
  final TextStyle? style;
  final double badgeSize;

  /// Draws the storefront glyph after the name — the business
  /// self-declaration, deliberately quieter than the verified check and
  /// never a substitute for it (both can show at once).
  final bool business;

  /// An optional trailing widget (e.g. a featured badge emoji).
  final Widget? trailing;

  const NameWithBadge({
    super.key,
    required this.name,
    required this.verified,
    this.style,
    this.badgeSize = 16,
    this.business = false,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Flexible(
          child: Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: style,
          ),
        ),
        if (verified) ...[
          const SizedBox(width: 4),
          VerifiedBadge(size: badgeSize),
        ],
        if (business) ...[
          const SizedBox(width: 4),
          Icon(Icons.storefront_outlined,
              size: badgeSize - 1,
              color: Theme.of(context).colorScheme.onSurfaceVariant),
        ],
        if (trailing != null) ...[
          const SizedBox(width: 4),
          trailing!,
        ],
      ],
    );
  }
}
