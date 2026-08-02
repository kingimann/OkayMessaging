import 'package:flutter/material.dart';

import '../state/quick_replies.dart';
import '../theme/app_theme.dart';

/// Manage the saved replies: add, edit, reorder, remove.
class QuickRepliesScreen extends StatelessWidget {
  const QuickRepliesScreen({super.key});

  static Future<void> _editSheet(BuildContext context,
      {int? index, String initial = ''}) async {
    final field = TextEditingController(text: initial);
    final text = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(index == null ? 'New quick reply' : 'Edit quick reply'),
        content: TextField(
          controller: field,
          autofocus: true,
          maxLines: 3,
          minLines: 1,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(
              hintText: 'Something you type often',
              border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () =>
                  Navigator.of(dialogContext).pop(field.text.trim()),
              child: const Text('Save')),
        ],
      ),
    );
    field.dispose();
    if (text == null) return;
    final store = QuickReplies.instance;
    if (index == null) {
      await store.add(text);
    } else {
      await store.edit(index, text);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Quick replies')),
      floatingActionButton: ListenableBuilder(
        listenable: QuickReplies.instance,
        builder: (context, _) => QuickReplies.instance.isFull
            ? const SizedBox.shrink()
            : FloatingActionButton(
                onPressed: () => _editSheet(context),
                child: const Icon(Icons.add),
              ),
      ),
      body: ListenableBuilder(
        listenable: QuickReplies.instance,
        builder: (context, _) {
          final store = QuickReplies.instance;
          if (store.isEmpty) {
            return ListView(
              padding: const EdgeInsets.fromLTRB(24, 32, 24, 24),
              children: [
                Icon(Icons.bolt_outlined,
                    size: 48, color: AppColors.subtle(context)),
                const SizedBox(height: 14),
                const Text('Nothing saved yet',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontSize: 18, fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                Text(
                  'Save the things you type often and they are one tap away '
                  'in any chat. They stay on this phone.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 14, height: 1.4,
                      color: AppColors.subtle(context)),
                ),
                const SizedBox(height: 22),
                // Suggestions, not content: tapping one saves it in the
                // person's own list, and nothing is written until they do.
                Text('Start with one of these',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.5,
                        color: AppColors.subtle(context))),
                const SizedBox(height: 10),
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final s in QuickReplies.suggestions)
                      ActionChip(
                        label: Text(s),
                        onPressed: () => QuickReplies.instance.add(s),
                      ),
                  ],
                ),
              ],
            );
          }
          return ReorderableListView.builder(
            padding: const EdgeInsets.only(bottom: 96),
            itemCount: store.all.length,
            onReorderItem: store.reorder,
            itemBuilder: (context, i) {
              final reply = store.all[i];
              return ListTile(
                key: ValueKey('quick_$i'),
                title: Text(reply, maxLines: 3,
                    overflow: TextOverflow.ellipsis),
                onTap: () => _editSheet(context, index: i, initial: reply),
                trailing: IconButton(
                  icon: const Icon(Icons.delete_outline),
                  tooltip: 'Remove',
                  onPressed: () => store.removeAt(i),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

/// The picker shown from the composer: tap one, it goes in the box.
///
/// Inserted rather than sent, so somebody can change a word first — a canned
/// reply that sends itself is a message nobody read before it left.
Future<String?> pickQuickReply(BuildContext context) => showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: ListenableBuilder(
          listenable: QuickReplies.instance,
          builder: (context, _) {
            final replies = QuickReplies.instance.all;
            if (replies.isEmpty) {
              return Padding(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('No quick replies yet',
                        style: TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 8),
                    Text(
                      'Save the things you type often in Settings, or hold any '
                      'message and save it from there.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          fontSize: 13.5, color: AppColors.subtle(context)),
                    ),
                  ],
                ),
              );
            }
            return ListView(
              shrinkWrap: true,
              children: [
                for (final reply in replies)
                  ListTile(
                    leading: const Icon(Icons.bolt_outlined),
                    title: Text(reply,
                        maxLines: 2, overflow: TextOverflow.ellipsis),
                    onTap: () => Navigator.of(sheetContext).pop(reply),
                  ),
              ],
            );
          },
        ),
      ),
    );
