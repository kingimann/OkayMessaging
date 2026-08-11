import 'package:flutter/material.dart';

import '../crypto/encryption_label.dart';
import '../models/message.dart';
import '../theme/app_theme.dart';
import '../utils/date_formatter.dart';

/// Says how a message was protected, in the same words wherever it appears.
///
/// One widget rather than a copy per screen: the 1:1/group chat and a server
/// channel show the same fact about different ladders, and two copies of that
/// sentence is how one of them ends up describing encryption the message
/// never had.
class EncryptionNote extends StatelessWidget {
  final EncryptionKind kind;

  /// Shows the longer explanation under the title. Off in tight places (a
  /// dialog row) where the title has to carry it alone.
  final bool detailed;

  const EncryptionNote({super.key, required this.kind, this.detailed = true});

  /// The rung recorded on [message].
  factory EncryptionNote.of(Message message, {bool detailed = true}) =>
      EncryptionNote(kind: message.encryptionKind, detailed: detailed);

  /// A padlock for anything that really was sealed; an open one for the two
  /// cases where the app cannot promise it was. Never a shield or a tick —
  /// those read as a verdict on the conversation, and this is a fact about
  /// one message.
  static IconData iconFor(EncryptionKind kind) =>
      EncryptionLabel.isEncrypted(kind) ? Icons.lock_outline : Icons.lock_open;

  @override
  Widget build(BuildContext context) {
    final subtle = AppColors.subtle(context);
    // Only the genuinely unencrypted case is coloured. An amber line beside
    // every message would turn the strongest rung into a warning.
    final warn = kind == EncryptionKind.none;
    final tint = warn ? Theme.of(context).colorScheme.error : subtle;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(iconFor(kind), size: 18, color: tint),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                EncryptionLabel.title(kind),
                style: TextStyle(
                    color: warn ? tint : null, fontWeight: FontWeight.w600),
              ),
              if (detailed) ...[
                const SizedBox(height: 3),
                Text(
                  EncryptionLabel.detail(kind),
                  style: TextStyle(fontSize: 12, color: subtle),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// The "Message info" dialog a server channel gets — when it was sent, who
/// sent it, and which key protected it.
///
/// The 1:1 chat has its own richer dialog (delivery status, edits, view-once)
/// and keeps it; what the two share is [EncryptionNote], which is the part
/// that must not drift.
Future<void> showChannelMessageInfo(BuildContext context, Message message) {
  return showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Message info'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.schedule,
                  size: 18, color: AppColors.subtle(dialogContext)),
              const SizedBox(width: 10),
              Expanded(
                  child: Text(
                      'Sent ${DateFormatter.messageTime(message.time)}')),
            ],
          ),
          const SizedBox(height: 12),
          EncryptionNote.of(message),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('Close'),
        ),
      ],
    ),
  );
}
