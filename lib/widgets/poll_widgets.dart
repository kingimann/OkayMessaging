import 'package:flutter/material.dart';

import '../models/message.dart';
import '../theme/app_theme.dart';

/// Bottom sheet to compose a poll. Returns `(question, options)` or null.
class PollComposerSheet extends StatefulWidget {
  const PollComposerSheet({super.key});

  @override
  State<PollComposerSheet> createState() => _PollComposerSheetState();
}

class _PollComposerSheetState extends State<PollComposerSheet> {
  final _question = TextEditingController();
  final _options = <TextEditingController>[
    TextEditingController(),
    TextEditingController(),
  ];

  @override
  void dispose() {
    _question.dispose();
    for (final c in _options) {
      c.dispose();
    }
    super.dispose();
  }

  bool get _valid =>
      _question.text.trim().isNotEmpty &&
      _options.where((c) => c.text.trim().isNotEmpty).length >= 2;

  void _addOption() {
    if (_options.length >= 6) return;
    setState(() => _options.add(TextEditingController()));
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Center(
                child: Text('New poll',
                    style:
                        TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _question,
                autofocus: true,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  labelText: 'Question',
                  hintText: 'Ask something…',
                  border: OutlineInputBorder(),
                ),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 14),
              for (var i = 0; i < _options.length; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: TextField(
                    controller: _options[i],
                    textCapitalization: TextCapitalization.sentences,
                    decoration: InputDecoration(
                      hintText: 'Option ${i + 1}',
                      border: const OutlineInputBorder(),
                      isDense: true,
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
              if (_options.length < 6)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: _addOption,
                    icon: const Icon(Icons.add),
                    label: const Text('Add option'),
                  ),
                ),
              const SizedBox(height: 8),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.tealGreenDark,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                onPressed: _valid
                    ? () {
                        final opts = _options
                            .map((c) => c.text.trim())
                            .where((t) => t.isNotEmpty)
                            .toList();
                        Navigator.of(context)
                            .pop((question: _question.text.trim(), options: opts));
                      }
                    : null,
                child: const Text('Create poll'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Renders a poll message with tappable options and live vote bars.
class PollBubble extends StatelessWidget {
  final Message message;
  final Color textColor;
  final Color metaColor;
  final ValueChanged<int> onVote;

  const PollBubble({
    super.key,
    required this.message,
    required this.textColor,
    required this.metaColor,
    required this.onVote,
  });

  @override
  Widget build(BuildContext context) {
    final total = message.pollTotalVotes;
    final votes = message.pollVotes;
    return SizedBox(
      width: 250,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(Icons.poll_outlined, size: 16, color: metaColor),
              const SizedBox(width: 6),
              Text('Poll',
                  style: TextStyle(
                      color: metaColor,
                      fontSize: 12,
                      fontWeight: FontWeight.w600)),
            ],
          ),
          const SizedBox(height: 6),
          Text(message.pollQuestion,
              style: TextStyle(
                  color: textColor,
                  fontSize: 15.5,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 10),
          for (var i = 0; i < message.pollOptions.length; i++)
            _PollOption(
              label: message.pollOptions[i],
              count: i < votes.length ? votes[i] : 0,
              total: total,
              selected: message.pollMyVote == i,
              textColor: textColor,
              onTap: () => onVote(i),
            ),
          const SizedBox(height: 4),
          Text(total == 1 ? '1 vote' : '$total votes',
              style: TextStyle(color: metaColor, fontSize: 11.5)),
        ],
      ),
    );
  }
}

class _PollOption extends StatelessWidget {
  final String label;
  final int count;
  final int total;
  final bool selected;
  final Color textColor;
  final VoidCallback onTap;

  const _PollOption({
    required this.label,
    required this.count,
    required this.total,
    required this.selected,
    required this.textColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final fraction = total == 0 ? 0.0 : count / total;
    final pct = (fraction * 100).round();
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Stack(
          children: [
            // Fill bar.
            Positioned.fill(
              child: FractionallySizedBox(
                alignment: Alignment.centerLeft,
                widthFactor: total == 0 ? 0.0 : fraction.clamp(0.02, 1.0),
                child: Container(
                  decoration: BoxDecoration(
                    color: AppColors.tealGreenDark
                        .withValues(alpha: selected ? 0.30 : 0.16),
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),
            ),
            Container(
              decoration: BoxDecoration(
                border: Border.all(
                    color: AppColors.tealGreenDark.withValues(alpha: 0.4)),
                borderRadius: BorderRadius.circular(10),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              child: Row(
                children: [
                  if (selected)
                    const Padding(
                      padding: EdgeInsets.only(right: 6),
                      child: Icon(Icons.check_circle,
                          size: 16, color: AppColors.tealGreenDark),
                    ),
                  Expanded(
                    child: Text(label,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: textColor,
                            fontSize: 14,
                            fontWeight: selected
                                ? FontWeight.w700
                                : FontWeight.w500)),
                  ),
                  if (total > 0) ...[
                    const SizedBox(width: 8),
                    Text('$pct%',
                        style: TextStyle(
                            color: textColor,
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600)),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
