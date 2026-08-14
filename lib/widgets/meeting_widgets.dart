import 'package:flutter/material.dart';

import '../models/meeting.dart';
import '../models/message.dart';
import '../theme/app_theme.dart';
import '../utils/date_formatter.dart';

/// What the composer sheet hands back.
typedef MeetingDraft = ({String title, DateTime at, String place});

/// Bottom sheet to plan a meeting. Returns a [MeetingDraft] or null.
///
/// Four fields and no more. A meeting somebody plans in a chat is "coffee,
/// Thursday, that place on the corner" — an end time, a repeat rule and a
/// guest list are what a calendar app is for, and every one of them is a
/// field between the idea and the message.
class MeetingComposerSheet extends StatefulWidget {
  const MeetingComposerSheet({super.key});

  @override
  State<MeetingComposerSheet> createState() => _MeetingComposerSheetState();
}

class _MeetingComposerSheetState extends State<MeetingComposerSheet> {
  final _title = TextEditingController();
  final _place = TextEditingController();

  /// Defaults to the next whole hour tomorrow — a real answer somebody can
  /// accept, rather than "now", which is never when a meeting is.
  late DateTime _at = _defaultWhen();

  static DateTime _defaultWhen() {
    final now = DateTime.now();
    final tomorrow = now.add(const Duration(days: 1));
    return DateTime(tomorrow.year, tomorrow.month, tomorrow.day, 12);
  }

  @override
  void dispose() {
    _title.dispose();
    _place.dispose();
    super.dispose();
  }

  bool get _valid => _title.text.trim().isNotEmpty && _at.isAfter(DateTime.now());

  Future<void> _pickWhen() async {
    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: _at.isBefore(now) ? now : _at,
      firstDate: now,
      lastDate: now.add(const Duration(days: 365)),
      helpText: 'Meeting date',
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_at),
      helpText: 'Start time',
    );
    if (time == null || !mounted) return;
    setState(() => _at =
        DateTime(date.year, date.month, date.day, time.hour, time.minute));
  }

  @override
  Widget build(BuildContext context) {
    final past = !_at.isAfter(DateTime.now());
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
                child: Text('Plan a meeting',
                    style:
                        TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _title,
                autofocus: true,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  labelText: 'What',
                  hintText: 'Coffee, standup, dinner…',
                  border: OutlineInputBorder(),
                ),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 12),
              InkWell(
                borderRadius: BorderRadius.circular(AppRadius.sm),
                onTap: _pickWhen,
                child: InputDecorator(
                  decoration: InputDecoration(
                    labelText: 'When',
                    border: const OutlineInputBorder(),
                    errorText: past ? 'Pick a time in the future' : null,
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.event_outlined,
                          size: 18, color: AppColors.subtle(context)),
                      const SizedBox(width: 8),
                      Expanded(
                          child: Text(DateFormatter.scheduleLabel(_at),
                              style: const TextStyle(fontSize: 15))),
                      Icon(Icons.edit_outlined,
                          size: 16, color: AppColors.subtle(context)),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _place,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  labelText: 'Where (optional)',
                  hintText: 'An address, a room, a link…',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 10),
              Text(
                'Everyone in this chat can say if they are coming. Nothing is '
                'added to a calendar — the reminder is on this phone only.',
                style:
                    TextStyle(fontSize: 12, color: AppColors.subtle(context)),
              ),
              const SizedBox(height: 12),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.accentOn(context),
                  foregroundColor: AppColors.onAccent(context),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                onPressed: _valid
                    ? () => Navigator.of(context).pop((
                          title: _title.text.trim(),
                          at: _at,
                          place: _place.text.trim(),
                        ))
                    : null,
                child: const Text('Send meeting'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The meeting card in a conversation: when, what, where, and three answers.
///
/// Takes [textColor]/[metaColor] from the bubble it sits in rather than
/// reaching for the app accent — the rule a voice note's play button and a
/// reply quote each had to learn the hard way, because a bubble may carry a
/// custom colour the app accent is invisible against.
class MeetingBubble extends StatelessWidget {
  final Message message;
  final Color textColor;
  final Color metaColor;

  /// Records an RSVP. Null retires the buttons — a meeting already past is
  /// a record of what happened, not something left to answer.
  final ValueChanged<MeetingRsvp>? onRsvp;

  /// Opens the who-is-coming list. Null hides the tap affordance.
  final VoidCallback? onShowWho;

  const MeetingBubble({
    super.key,
    required this.message,
    required this.textColor,
    required this.metaColor,
    this.onRsvp,
    this.onShowWho,
  });

  @override
  Widget build(BuildContext context) {
    final at = message.meetingAt;
    final counts = meetingRsvpCounts(message.pollVotesBy);
    final mine = MeetingRsvp.fromIndex(message.pollMyVote);
    final past = at != null && meetingIsPast(at);
    final going = counts[MeetingRsvp.going.index];
    return SizedBox(
      width: 250,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(Icons.event_outlined, size: 16, color: metaColor),
              const SizedBox(width: 6),
              Text(past ? 'Meeting · past' : 'Meeting',
                  style: TextStyle(
                      color: metaColor,
                      fontSize: 12,
                      fontWeight: FontWeight.w600)),
            ],
          ),
          const SizedBox(height: 6),
          Text(message.meetingTitle,
              style: TextStyle(
                  color: textColor, fontSize: 15.5, fontWeight: FontWeight.w700)),
          if (at != null) ...[
            const SizedBox(height: 4),
            Row(
              children: [
                Icon(Icons.schedule, size: 14, color: metaColor),
                const SizedBox(width: 5),
                Expanded(
                  child: Text(DateFormatter.scheduleLabel(at),
                      style: TextStyle(
                          color: textColor,
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600)),
                ),
              ],
            ),
          ],
          if (message.meetingPlace.isNotEmpty) ...[
            const SizedBox(height: 3),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.place_outlined, size: 14, color: metaColor),
                const SizedBox(width: 5),
                Expanded(
                  child: Text(message.meetingPlace,
                      style: TextStyle(color: metaColor, fontSize: 13)),
                ),
              ],
            ),
          ],
          const SizedBox(height: 10),
          if (onRsvp != null && !past)
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final r in MeetingRsvp.values)
                  _RsvpChip(
                    label: r.label,
                    count: counts[r.index],
                    selected: mine == r,
                    textColor: textColor,
                    onTap: () => onRsvp!(r),
                  ),
              ],
            )
          else
            Text(
              [
                for (final r in MeetingRsvp.values)
                  if (counts[r.index] > 0) '${counts[r.index]} ${r.label.toLowerCase()}'
              ].join(' · '),
              style: TextStyle(color: metaColor, fontSize: 12.5),
            ),
          const SizedBox(height: 6),
          // The headcount, spelled out. Deliberately never a weighted tally
          // the way a group poll's can be: this is how many chairs to find.
          InkWell(
            onTap: onShowWho,
            child: Text(
              going == 0
                  ? 'Nobody has said yes yet'
                  : '$going ${going == 1 ? 'person is' : 'people are'} going'
                      '${onShowWho == null ? '' : ' · see who'}',
              style: TextStyle(color: metaColor, fontSize: 11.5),
            ),
          ),
        ],
      ),
    );
  }
}

class _RsvpChip extends StatelessWidget {
  final String label;
  final int count;
  final bool selected;
  final Color textColor;
  final VoidCallback onTap;

  const _RsvpChip({
    required this.label,
    required this.count,
    required this.selected,
    required this.textColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final accent = AppColors.accentOn(context);
    return InkWell(
      borderRadius: BorderRadius.circular(AppRadius.sm),
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: selected ? accent.withValues(alpha: 0.24) : null,
          border: Border.all(color: accent.withValues(alpha: 0.4)),
          borderRadius: BorderRadius.circular(AppRadius.sm),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (selected)
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Icon(Icons.check, size: 13, color: textColor),
              ),
            Text(count > 0 ? '$label $count' : label,
                style: TextStyle(
                    color: textColor,
                    fontSize: 12.5,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500)),
          ],
        ),
      ),
    );
  }
}
