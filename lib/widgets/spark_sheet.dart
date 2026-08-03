import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// One-tap preset amounts for a Spark — 21 is the community's number.
/// Shared by the server feed and the public one, so the gesture costs the
/// same everywhere. Returns the chosen cents, or null.
Future<int?> showSparkSheet(BuildContext context, {required String toLabel}) {
  return showModalBottomSheet<int>(
    context: context,
    builder: (_) => _SparkSheet(toLabel: toLabel),
  );
}

class _SparkSheet extends StatelessWidget {
  /// Who the money goes to, as the caller wants it shown — '@handle' on the
  /// feeds, a plain name in a chat.
  final String toLabel;
  const _SparkSheet({required this.toLabel});

  static const presets = <int>[21, 100, 500, 2100];

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.bolt, color: Color(0xFFF7931A)),
                const SizedBox(width: 8),
                Text('Spark $toLabel',
                    style: const TextStyle(
                        fontSize: 17, fontWeight: FontWeight.w700)),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'Real money, straight to them — the same person-to-person '
              'transfer as Send money in a chat. Sparks are final.',
              style:
                  TextStyle(fontSize: 12.5, color: AppColors.subtle(context)),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                for (final cents in presets) ...[
                  Expanded(
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                      onPressed: () => Navigator.of(context).pop(cents),
                      child: Text(
                        cents % 100 == 0
                            ? '\$${cents ~/ 100}'
                            : '\$${(cents / 100).toStringAsFixed(2)}',
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                  ),
                  if (cents != presets.last) const SizedBox(width: 8),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}
