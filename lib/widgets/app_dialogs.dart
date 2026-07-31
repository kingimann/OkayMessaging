import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// The app's one dialog language, replacing the stock [AlertDialog] look
/// (bare title, underlined field, two text buttons in a corner) everywhere a
/// popup asks a question or for a line of text: a tonal icon, centred text,
/// and a full-width filled action — red when it destroys something.

/// A styled yes/no question. Returns true only when [confirmLabel] was
/// tapped; dismissing any other way is a no.
Future<bool> showAppConfirmDialog(
  BuildContext context, {
  required IconData icon,
  required String title,
  required String message,
  required String confirmLabel,

  /// Pass null for a one-button, informational dialog.
  String? cancelLabel = 'Cancel',
  bool destructive = false,
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (dialogContext) {
      final accent = destructive
          ? Colors.red.shade600
          : AppColors.accentOn(dialogContext);
      final onAccent =
          destructive ? Colors.white : AppColors.onAccent(dialogContext);
      return Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 26, 24, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              CircleAvatar(
                radius: 27,
                backgroundColor: accent.withValues(alpha: 0.12),
                child: Icon(icon, color: accent, size: 27),
              ),
              const SizedBox(height: 14),
              Text(
                title,
                textAlign: TextAlign.center,
                style:
                    const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              Text(
                message,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14,
                  height: 1.4,
                  color: AppColors.subtle(context),
                ),
              ),
              const SizedBox(height: 20),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: accent,
                  foregroundColor: onAccent,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(26)),
                  textStyle: const TextStyle(
                      fontSize: 15.5, fontWeight: FontWeight.w600),
                ),
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: Text(confirmLabel),
              ),
              if (cancelLabel != null)
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(false),
                  child: Text(
                    cancelLabel,
                    style: TextStyle(color: AppColors.subtle(context)),
                  ),
                ),
            ],
          ),
        ),
      );
    },
  );
  return ok == true;
}

/// A styled one-field prompt. Returns the trimmed text, or null when
/// cancelled. The confirm button stays disabled until there's something to
/// submit (unless [allowEmpty], for clearing an optional value).
Future<String?> showAppTextPrompt(
  BuildContext context, {
  required IconData icon,
  required String title,
  String? message,
  String hint = '',
  String initial = '',
  String confirmLabel = 'Save',
  TextInputType? keyboardType,
  TextCapitalization capitalization = TextCapitalization.none,
  int maxLines = 1,
  bool allowEmpty = false,
}) {
  final controller = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (dialogContext) {
      final accent = AppColors.accentOn(dialogContext);
      return Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
          child: StatefulBuilder(
            builder: (dialogContext, setState) {
              final canSubmit =
                  allowEmpty || controller.text.trim().isNotEmpty;
              void submit() {
                if (canSubmit) {
                  Navigator.of(dialogContext).pop(controller.text.trim());
                }
              }

              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      CircleAvatar(
                        radius: 19,
                        backgroundColor: accent.withValues(alpha: 0.12),
                        child: Icon(icon, color: accent, size: 20),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          title,
                          style: const TextStyle(
                              fontSize: 17, fontWeight: FontWeight.w700),
                        ),
                      ),
                    ],
                  ),
                  if (message != null) ...[
                    const SizedBox(height: 10),
                    Text(
                      message,
                      style: TextStyle(
                        fontSize: 13.5,
                        height: 1.35,
                        color: AppColors.subtle(context),
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                  TextField(
                    controller: controller,
                    autofocus: true,
                    keyboardType: keyboardType,
                    textCapitalization: capitalization,
                    maxLines: maxLines,
                    onChanged: (_) => setState(() {}),
                    onSubmitted: maxLines == 1 ? (_) => submit() : null,
                    decoration: InputDecoration(
                      hintText: hint,
                      filled: true,
                      isDense: true,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: () => Navigator.of(dialogContext).pop(),
                        child: Text('Cancel',
                            style: TextStyle(color: AppColors.subtle(context))),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        style: FilledButton.styleFrom(
                          backgroundColor: accent,
                          foregroundColor:
                              AppColors.onAccent(dialogContext),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(22)),
                        ),
                        onPressed: canSubmit ? submit : null,
                        child: Text(confirmLabel),
                      ),
                    ],
                  ),
                ],
              );
            },
          ),
        ),
      );
    },
  );
}
