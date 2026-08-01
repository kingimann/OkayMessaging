import 'package:flutter/material.dart';

import '../state/notes_store.dart';
import '../theme/app_theme.dart';
import '../state/feed_store.dart' show feedAge;
import '../widgets/empty_state.dart';

/// Notes: things you write to yourself.
///
/// The list. Search narrows it, a pin keeps one at the top, and everything
/// else is one tap into the editor — which is the whole screen, because
/// writing is the only thing happening once you are in it.
class NotesScreen extends StatefulWidget {
  const NotesScreen({super.key});

  @override
  State<NotesScreen> createState() => _NotesScreenState();
}

class _NotesScreenState extends State<NotesScreen> {
  final _search = TextEditingController();
  bool _searching = false;

  @override
  void initState() {
    super.initState();
    NotesStore.instance.load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _open([Note? note]) async {
    await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => NoteEditorScreen(noteId: note?.id)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: _searching
            ? TextField(
                controller: _search,
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: 'Search notes',
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  filled: false,
                ),
                onChanged: (_) => setState(() {}),
              )
            : const Text('Notes'),
        actions: [
          IconButton(
            icon: Icon(_searching ? Icons.close : Icons.search),
            tooltip: _searching ? 'Stop searching' : 'Search notes',
            onPressed: () => setState(() {
              _searching = !_searching;
              if (!_searching) _search.clear();
            }),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _open,
        tooltip: 'New note',
        child: const Icon(Icons.add),
      ),
      body: ListenableBuilder(
        listenable: NotesStore.instance,
        builder: (context, _) {
          final notes = NotesStore.instance.search(_search.text);
          if (notes.isEmpty) {
            return _search.text.trim().isNotEmpty
                ? EmptyState(
                    icon: Icons.search_off,
                    title: 'Nothing matches',
                    caption: 'No note contains "${_search.text.trim()}".',
                  )
                : EmptyState(
                    icon: Icons.sticky_note_2_outlined,
                    title: 'No notes yet',
                    caption: 'Somewhere to write things down that stays on '
                        'this device.',
                    actionLabel: 'Write one',
                    onAction: _open,
                  );
          }
          return ListView.separated(
            padding: const EdgeInsets.only(bottom: 96),
            itemCount: notes.length + 1,
            separatorBuilder: (_, i) =>
                i == 0 ? const SizedBox.shrink() : const Divider(height: 1),
            itemBuilder: (context, i) {
              if (i == 0) return const _PrivacyLine();
              final note = notes[i - 1];
              return _NoteRow(note: note, onTap: () => _open(note));
            },
          );
        },
      ),
    );
  }
}

/// The one thing worth saying about a note, said once at the top rather than
/// on every row: it does not leave this device unless the encrypted backup is
/// on, and it is sealed before it does.
class _PrivacyLine extends StatelessWidget {
  const _PrivacyLine();

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Row(
          children: [
            Icon(Icons.lock_outline,
                size: 15, color: AppColors.subtle(context)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Kept on this device. Backed up only if cloud storage is on, '
                'and encrypted before it leaves.',
                style:
                    TextStyle(fontSize: 12.5, color: AppColors.subtle(context)),
              ),
            ),
          ],
        ),
      );
}

class _NoteRow extends StatelessWidget {
  const _NoteRow({required this.note, required this.onTap});

  final Note note;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final preview = note.preview;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      title: Row(
        children: [
          if (note.pinned) ...[
            Icon(Icons.push_pin, size: 14, color: AppColors.subtle(context)),
            const SizedBox(width: 6),
          ],
          Expanded(
            child: Text(note.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 3),
        child: Row(
          children: [
            Text(feedAge(note.updatedAt),
                style:
                    TextStyle(fontSize: 12.5, color: AppColors.subtle(context))),
            if (preview.isNotEmpty) ...[
              const SizedBox(width: 8),
              Expanded(
                child: Text(preview,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 13.5, color: AppColors.subtle(context))),
              ),
            ],
          ],
        ),
      ),
      onTap: onTap,
    );
  }
}

/// Writing one. The page is the field, the same shape the composer uses.
///
/// It saves on the way out rather than behind a button: a note you have to
/// remember to save is a note you lose. Emptying one deletes it, so there is
/// no blank row to tidy up afterwards.
class NoteEditorScreen extends StatefulWidget {
  const NoteEditorScreen({super.key, this.noteId});

  /// The note being edited, or null for a new one.
  final String? noteId;

  @override
  State<NoteEditorScreen> createState() => _NoteEditorScreenState();
}

class _NoteEditorScreenState extends State<NoteEditorScreen> {
  late final TextEditingController _text;
  String? _id;

  @override
  void initState() {
    super.initState();
    _id = widget.noteId;
    _text = TextEditingController(
        text: _id == null ? '' : NotesStore.instance.byId(_id!)?.body ?? '');
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final saved = await NotesStore.instance.save(id: _id, body: _text.text);
    _id = saved?.id;
  }

  Future<void> _delete() async {
    final id = _id;
    if (id != null) await NotesStore.instance.delete(id);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final note = _id == null ? null : NotesStore.instance.byId(_id!);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final navigator = Navigator.of(context);
        // Saved on the way out. A note you have to remember to save is a note
        // you lose, and the back gesture is how people leave a screen.
        await _save();
        navigator.pop();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(_id == null ? 'New note' : 'Note'),
          actions: [
            if (note != null)
              IconButton(
                icon: Icon(note.pinned ? Icons.push_pin : Icons.push_pin_outlined),
                tooltip: note.pinned ? 'Unpin' : 'Pin to top',
                onPressed: () async {
                  await NotesStore.instance.togglePin(note.id);
                  if (mounted) setState(() {});
                },
              ),
            if (_id != null)
              IconButton(
                icon: const Icon(Icons.delete_outline),
                tooltip: 'Delete note',
                onPressed: _delete,
              ),
          ],
        ),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: TextField(
              controller: _text,
              autofocus: _id == null,
              maxLines: null,
              expands: true,
              textAlignVertical: TextAlignVertical.top,
              textCapitalization: TextCapitalization.sentences,
              style: const TextStyle(fontSize: 16.5, height: 1.45),
              // No box, for the same reason the composer has none: a bordered
              // rectangle filling a screen that is nothing else reads as a
              // form rather than as a page to write on.
              decoration: const InputDecoration(
                hintText: 'Write something…',
                filled: false,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                contentPadding: EdgeInsets.zero,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
