import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A line that is a to-do item: `[ ]` open, `[x]` done, any case, one space or
/// none after the bracket. Group 1 is the indentation, 2 the mark, 3 the text.
/// Checklists are kept as plain text on purpose — a note stays searchable,
/// syncable and free of any new schema, and a shopping list is just a note.
final RegExp _checkboxLine = RegExp(r'^(\s*)\[( |x|X)\]\s?(.*)$');

/// How much of a note's checklist is done, if it has one.
@immutable
class Checklist {
  const Checklist(this.done, this.total);
  final int done;
  final int total;

  /// Whether the note is a checklist at all.
  bool get any => total > 0;

  /// Every box ticked.
  bool get complete => total > 0 && done == total;
}

/// One note. The first line is its title — there is no separate title field,
/// because a notes app that makes you name a note before writing it is one
/// people stop opening.
@immutable
class Note {
  const Note({
    required this.id,
    required this.body,
    required this.createdAt,
    required this.updatedAt,
    this.pinned = false,
  });

  final String id;
  final String body;
  final DateTime createdAt;
  final DateTime updatedAt;
  final bool pinned;

  /// A line as it should read in a title or preview: the checkbox marker is
  /// dropped, so a to-do list shows "Milk", not "[ ] Milk".
  static String _display(String line) {
    final m = _checkboxLine.firstMatch(line);
    return (m == null ? line : m.group(3)!).trim();
  }

  /// The first line with anything in it, which is what a note is called.
  String get title {
    for (final line in body.split('\n')) {
      final t = _display(line);
      if (t.isNotEmpty) return t.length > 80 ? '${t.substring(0, 80)}…' : t;
    }
    return '';
  }

  /// Everything after the title line, flattened, for the second line of a row.
  String get preview {
    final lines = body.split('\n');
    var seenTitle = false;
    final rest = <String>[];
    for (final line in lines) {
      final t = _display(line);
      if (!seenTitle) {
        if (t.isEmpty) continue;
        seenTitle = true;
        continue;
      }
      if (t.isNotEmpty) rest.add(t);
    }
    final joined = rest.join(' ');
    return joined.length > 140 ? '${joined.substring(0, 140)}…' : joined;
  }

  /// How many of this note's to-do lines are ticked. `total` is 0 when the
  /// note isn't a checklist, which is how a row decides whether to show one.
  Checklist get checklist {
    var done = 0, total = 0;
    for (final line in body.split('\n')) {
      final m = _checkboxLine.firstMatch(line);
      if (m == null) continue;
      total++;
      if (m.group(2)!.toLowerCase() == 'x') done++;
    }
    return Checklist(done, total);
  }

  /// Whether there is nothing here worth keeping. An empty note is not saved,
  /// and one emptied out is deleted rather than left as a blank row.
  bool get isEmpty => body.trim().isEmpty;

  Note copyWith({String? body, DateTime? updatedAt, bool? pinned}) => Note(
        id: id,
        body: body ?? this.body,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
        pinned: pinned ?? this.pinned,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'body': body,
        'createdAt': createdAt.toUtc().toIso8601String(),
        'updatedAt': updatedAt.toUtc().toIso8601String(),
        if (pinned) 'pinned': true,
      };

  static Note? fromJson(Map<String, dynamic> j) {
    final id = j['id'] as String? ?? '';
    if (id.isEmpty) return null;
    final created = DateTime.tryParse(j['createdAt'] as String? ?? '');
    final updated = DateTime.tryParse(j['updatedAt'] as String? ?? '');
    return Note(
      id: id,
      body: j['body'] as String? ?? '',
      createdAt: created?.toLocal() ?? DateTime.now(),
      updatedAt: updated?.toLocal() ?? created?.toLocal() ?? DateTime.now(),
      pinned: j['pinned'] == true,
    );
  }
}

/// Notes: things you write to yourself.
///
/// ON THE DEVICE, like the rest of what this app knows about you. There is no
/// notes table and no server column — the list is JSON in shared preferences.
/// It rides the encrypted cloud sync alongside servers, follows and places
/// while a storage subscription is active, which means it is sealed with the
/// same key before it leaves and the server never sees a word of it.
///
/// The consequence, stated rather than discovered: without that subscription a
/// note does not follow you to a new device. That is the same trade everything
/// else here makes.
class NotesStore extends ChangeNotifier {
  NotesStore._();
  static final NotesStore instance = NotesStore._();

  static const _key = 'notes_v1';

  List<Note> _notes = [];
  SharedPreferences? _prefs;

  /// Pinned first, then most recently edited. Both halves matter: a pin is a
  /// statement that this one outranks recency, and without the second a list
  /// of notes is a list you have to search every time.
  List<Note> get notes {
    final list = [..._notes];
    list.sort((a, b) {
      if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
      return b.updatedAt.compareTo(a.updatedAt);
    });
    return List.unmodifiable(list);
  }

  int get count => _notes.length;

  Future<void> load() async {
    _prefs = await SharedPreferences.getInstance();
    _notes = _decode(_prefs!.getString(_key));
    notifyListeners();
  }

  Note? byId(String id) {
    for (final n in _notes) {
      if (n.id == id) return n;
    }
    return null;
  }

  /// Notes containing [query], title and body alike, case-insensitively.
  /// An empty query is everything, in the usual order.
  List<Note> search(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return notes;
    return [
      for (final n in notes)
        if (n.body.toLowerCase().contains(q)) n
    ];
  }

  /// Writes [body] to [id], or creates a note when [id] is null or unknown.
  ///
  /// Returns the note, or null when there was nothing to save — an empty body
  /// creates nothing, and emptying an existing note deletes it. A blank row in
  /// a list of notes is a thing you have to tidy up later.
  Future<Note?> save({String? id, required String body}) async {
    final now = DateTime.now();
    final existing = id == null ? null : byId(id);

    if (body.trim().isEmpty) {
      if (existing != null) await delete(existing.id);
      return null;
    }

    final note = existing == null
        ? Note(id: newId(), body: body, createdAt: now, updatedAt: now)
        : existing.copyWith(body: body, updatedAt: now);

    _notes = existing == null
        ? [note, ..._notes]
        : [for (final n in _notes) n.id == note.id ? note : n];
    notifyListeners();
    await _persist();
    return note;
  }

  Future<void> delete(String id) async {
    final kept = [for (final n in _notes) if (n.id != id) n];
    if (kept.length == _notes.length) return;
    _notes = kept;
    notifyListeners();
    await _persist();
  }

  /// Puts a just-deleted note back exactly as it was — same id, same dates,
  /// same pin. This is what Undo hangs on: deletion here is immediate and a
  /// note has no other copy, so the one safety net is being able to take it
  /// back. A no-op if the id is already present.
  Future<void> restore(Note note) async {
    if (byId(note.id) != null) return;
    _notes = [note, ..._notes];
    notifyListeners();
    await _persist();
  }

  /// Pins or unpins [id]. Returns whether it is now pinned.
  Future<bool> togglePin(String id) async {
    final note = byId(id);
    if (note == null) return false;
    final next = !note.pinned;
    _notes = [
      for (final n in _notes) n.id == id ? n.copyWith(pinned: next) : n
    ];
    notifyListeners();
    await _persist();
    return next;
  }

  // --- Cloud sync ---------------------------------------------------------

  /// What the encrypted backup carries. Sealed before it leaves the device,
  /// exactly like servers and saved places.
  List<Map<String, dynamic>> exportNotes() =>
      [for (final n in notes) n.toJson()];

  /// Merges a restored backup in. Newest edit wins per id, so restoring on a
  /// device that has been used since does not throw away what it wrote.
  void hydrateNotes(List<dynamic> rows) {
    final byIdMap = {for (final n in _notes) n.id: n};
    for (final r in rows.whereType<Map>()) {
      final incoming = Note.fromJson(Map<String, dynamic>.from(r));
      if (incoming == null) continue;
      final mine = byIdMap[incoming.id];
      if (mine == null || incoming.updatedAt.isAfter(mine.updatedAt)) {
        byIdMap[incoming.id] = incoming;
      }
    }
    _notes = byIdMap.values.toList();
    notifyListeners();
    _persist();
  }

  /// Turns the line under [caret] into a to-do item, or ticks/unticks it if it
  /// already is one — the single gesture behind the editor's checkbox button.
  /// Returns the new text and where the caret should sit afterwards. Pure, so
  /// it can be tested without a widget.
  static (String, int) toggleCheckbox(String text, int caret) {
    caret = caret.clamp(0, text.length);
    final lineStart = caret == 0 ? 0 : text.lastIndexOf('\n', caret - 1) + 1;
    var lineEnd = text.indexOf('\n', caret);
    if (lineEnd < 0) lineEnd = text.length;
    final line = text.substring(lineStart, lineEnd);

    final box = _checkboxLine.firstMatch(line);
    late final String newLine;
    late final int caretDelta;
    if (box == null) {
      // Not a to-do yet — make it one, keeping any indentation. '[ ] ' is four
      // characters, so the caret slides right to stay by the same word.
      final m = RegExp(r'^(\s*)(.*)$').firstMatch(line)!;
      newLine = '${m.group(1)}[ ] ${m.group(2)}';
      caretDelta = 4;
    } else {
      final done = box.group(2)!.toLowerCase() == 'x';
      newLine = '${box.group(1)}[${done ? ' ' : 'x'}] ${box.group(3)}';
      caretDelta = 0; // same length, only the mark flips
    }
    final next = text.replaceRange(lineStart, lineEnd, newLine);
    return (next, (caret + caretDelta).clamp(0, next.length));
  }

  static String newId() {
    final rng = Random.secure();
    final n = List<int>.generate(8, (_) => rng.nextInt(256))
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    return 'nt_$n';
  }

  Future<void> _persist() async {
    await _prefs?.setString(
        _key, jsonEncode([for (final n in _notes) n.toJson()]));
  }

  static List<Note> _decode(String? raw) {
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw);
      if (list is! List) return [];
      return [
        for (final r in list.whereType<Map>())
          if (Note.fromJson(Map<String, dynamic>.from(r)) case final Note n) n
      ];
    } catch (_) {
      return [];
    }
  }

  @visibleForTesting
  void resetForTest() {
    _notes = [];
    _prefs = null;
    notifyListeners();
  }
}
