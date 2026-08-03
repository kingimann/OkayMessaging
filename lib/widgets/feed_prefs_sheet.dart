import 'package:flutter/material.dart';

import '../state/feed_prefs.dart';
import '../theme/app_theme.dart';

/// The "shape your feed" sheet, shared by BOTH timelines: muted words, the
/// reposts switch, and whoever this feed has muted (with the way back —
/// muting was one tap on a post, but UNmuting had no door at all).
Future<void> showFeedPrefsSheet(
  BuildContext context, {
  required Set<String> mutedPeople,
  required void Function(String username) onUnmute,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) =>
        _FeedPrefsSheet(mutedPeople: mutedPeople, onUnmute: onUnmute),
  );
}

class _FeedPrefsSheet extends StatefulWidget {
  final Set<String> mutedPeople;
  final void Function(String username) onUnmute;
  const _FeedPrefsSheet({required this.mutedPeople, required this.onUnmute});

  @override
  State<_FeedPrefsSheet> createState() => _FeedPrefsSheetState();
}

class _FeedPrefsSheetState extends State<_FeedPrefsSheet> {
  final _word = TextEditingController();
  late final Set<String> _people = {...widget.mutedPeople};

  @override
  void dispose() {
    _word.dispose();
    super.dispose();
  }

  Future<void> _addWord() async {
    final added = await FeedPrefs.instance.muteWord(_word.text);
    if (added) _word.clear();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        // Rides the keyboard, or typing a word hides the field under it.
        padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).viewInsets.bottom),
        child: ListenableBuilder(
          listenable: FeedPrefs.instance,
          builder: (context, _) {
            final prefs = FeedPrefs.instance;
            return SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.tune),
                      const SizedBox(width: 10),
                      Text('Shape your feed',
                          style: Theme.of(context).textTheme.titleMedium),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Applies to your timelines on this device — the public '
                    'feed and every server\'s. Nothing here is shared.',
                    style: TextStyle(
                        fontSize: 12.5, color: AppColors.subtle(context)),
                  ),
                  const SizedBox(height: 16),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Hide reposts'),
                    subtitle: const Text(
                        'Only what people actually wrote',
                        style: TextStyle(fontSize: 12.5)),
                    value: prefs.hideReposts,
                    onChanged: prefs.setHideReposts,
                  ),
                  const SizedBox(height: 8),
                  Text('MUTED WORDS',
                      style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.6,
                          color: AppColors.subtle(context))),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _word,
                          decoration: const InputDecoration(
                            hintText: 'Word or phrase to hide',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                          onSubmitted: (_) => _addWord(),
                        ),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        onPressed: _addWord,
                        child: const Text('Mute'),
                      ),
                    ],
                  ),
                  if (prefs.mutedWords.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      children: [
                        for (final w in prefs.mutedWords)
                          InputChip(
                            label: Text(w),
                            onDeleted: () => prefs.unmuteWord(w),
                          ),
                      ],
                    ),
                  ],
                  if (_people.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    Text('MUTED PEOPLE',
                        style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.6,
                            color: AppColors.subtle(context))),
                    const SizedBox(height: 4),
                    for (final u in _people.toList()..sort())
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        leading: const Icon(Icons.volume_off, size: 20),
                        title: Text('@$u'),
                        trailing: TextButton(
                          onPressed: () {
                            widget.onUnmute(u);
                            setState(() => _people.remove(u));
                          },
                          child: const Text('Unmute'),
                        ),
                      ),
                  ],
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}
