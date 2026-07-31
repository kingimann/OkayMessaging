import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

import '../models/platform_role.dart';
import '../state/platform_moderation.dart';

/// Tells an account what has been done to it, and why.
///
/// A locked-out account must never just quietly stop working — a directory it
/// has vanished from and a username it can no longer claim read as a broken
/// app, not as a decision somebody made. So the reason, the length, and the
/// fact that the conversations already on the device still work all get said
/// out loud.
class SanctionNotice extends StatelessWidget {
  const SanctionNotice({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: PlatformModeration.instance,
      builder: (context, _) {
        final sanction = PlatformModeration.instance.sanction;
        if (sanction == null) return const SizedBox.shrink();
        final scheme = Theme.of(context).colorScheme;
        final now = DateTime.now().toUtc();
        final left = sanctionRemaining(sanction.until, now);
        final locked = sanction.blocksAccessAt(now);
        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 2),
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: scheme.errorContainer.withValues(alpha: 0.55),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(locked ? Icons.block : Icons.timer_outlined,
                    color: scheme.error, size: 20),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        switch (sanction.kind) {
                          SanctionKind.ban =>
                            'Your account has been banned',
                          SanctionKind.suspend =>
                            'Your account is suspended',
                          _ => 'You are timed out',
                        },
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        [
                          if (sanction.reason.isNotEmpty) sanction.reason,
                          if (left.isNotEmpty) 'Ends in $left.',
                          if (sanction.until == null &&
                              sanction.kind == SanctionKind.ban)
                            'This does not expire.',
                          locked
                              ? 'You can\'t be found or send anything. Chats '
                                  'already on this device stay readable.'
                              : 'You can read, but not send, post, or list.',
                        ].join(' '),
                        style: const TextStyle(fontSize: 12.5),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Files a report to the moderation queue. Replaces the old "this goes
/// nowhere" reporting, which was honest at the time — there was no central
/// moderator — and now would be wrong.
Future<void> showReportSheet(
  BuildContext context, {
  required String context_,
  String targetPhone = '',
  String targetHandle = '',
}) async {
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => _ReportSheet(
      context_: context_,
      targetPhone: targetPhone,
      targetHandle: targetHandle,
    ),
  );
}

class _ReportSheet extends StatefulWidget {
  final String context_;
  final String targetPhone;
  final String targetHandle;
  const _ReportSheet({
    required this.context_,
    required this.targetPhone,
    required this.targetHandle,
  });

  @override
  State<_ReportSheet> createState() => _ReportSheetState();
}

class _ReportSheetState extends State<_ReportSheet> {
  final _detail = TextEditingController();
  String _reason = reportReasons.first;
  bool _sending = false;

  @override
  void dispose() {
    _detail.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    setState(() => _sending = true);
    final ok = await PlatformModeration.instance.report(
      reason: _reason,
      targetPhone: widget.targetPhone,
      targetHandle: widget.targetHandle,
      detail: _detail.text.trim(),
      context: widget.context_,
    );
    if (!mounted) return;
    setState(() => _sending = false);
    Navigator.of(context).pop();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(ok
            ? 'Report sent to moderators'
            : 'Couldn\'t send the report — check your connection.')));
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
            left: 20,
            right: 20,
            bottom: MediaQuery.of(context).viewInsets.bottom + 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Report',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text(
                'Goes to the app\'s moderators. Only what you write here is '
                'sent — never your messages, which stay encrypted on your '
                'device.',
                style:
                    TextStyle(fontSize: 12.5, color: AppColors.subtle(context))),
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final r in reportReasons)
                  ChoiceChip(
                    label: Text(r),
                    selected: _reason == r,
                    onSelected: (_) => setState(() => _reason = r),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _detail,
              maxLines: 3,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'What happened? (optional)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _sending ? null : _send,
              style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(48)),
              child: Text(_sending ? 'Sending…' : 'Send report'),
            ),
          ],
        ),
      ),
    );
  }
}
