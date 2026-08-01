import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

  /// The first line with anything in it, which is what a note is called.
  String get title {
    for (final line in body.split('\n')) {
      final t = line.trim();
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
      final t = line.trim();
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
