import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/form_spec.dart';

/// A form somebody built once and wants again.
///
/// Until now a form existed only as a message: the builder opened blank from
/// a chat's attachment panel, the questions went out, and that was the last
/// anyone saw of them. Anybody running the same RSVP every month rebuilt it
/// every month. This is the saved copy — the questions, not the answers.
class SavedForm {
  final String id;
  final String title;
  final List<FormFieldSpec> fields;

  /// When it was last saved, so the list can lead with what is being worked
  /// on rather than whatever happened to be created first.
  final DateTime updatedAt;

  const SavedForm({
    required this.id,
    required this.title,
    required this.fields,
    required this.updatedAt,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'fields': [for (final f in fields) f.toJson()],
        'updatedAt': updatedAt.toIso8601String(),
      };

  factory SavedForm.fromJson(Map<String, dynamic> j) => SavedForm(
        id: j['id'] as String? ?? '',
        title: j['title'] as String? ?? '',
        fields: [
          for (final f in (j['fields'] as List?) ?? const [])
            if (f is Map) FormFieldSpec.fromJson(Map<String, dynamic>.from(f))
        ],
        updatedAt:
            DateTime.tryParse(j['updatedAt'] as String? ?? '') ?? DateTime(2026),
      );

  /// What the list says under the title: how much there is to answer.
  String get summary =>
      '${fields.length} ${fields.length == 1 ? 'question' : 'questions'}';
}

/// The forms this device has saved.
///
/// **On the device and nowhere else** — no table, no column, no backup blob,
/// and a test holds it there. This is the same rule [QuickReplies] follows
/// and for a stronger reason: `form_spec.dart`'s own doc comment says a form
/// that posted to a table somewhere would be the one feature in this app
/// collecting people's answers in the clear. The QUESTIONS are not the
/// answers, but "what this person keeps asking people" is its own statement
/// about them, and there is nothing a server could do with it that the device
/// cannot do alone.
///
/// Account-scoped, wired into `account_wipe.dart` like [ChatFolders] and
/// [MessageSoundStore]: a saved form belongs to whoever built it, and the
/// next account on this phone has no business inheriting it.
class SavedForms extends ChangeNotifier {
  SavedForms._();
  static final SavedForms instance = SavedForms._();

  static const _key = 'saved_forms_v1';

  /// Enough that nobody hits it in real use, low enough that a bug cannot
  /// grow the stored blob without bound.
  static const int maxForms = 50;

  final List<SavedForm> _forms = [];
  SharedPreferences? _prefs;

  /// Newest first — the one being worked on is the one at the top.
  List<SavedForm> get forms => List.unmodifiable(_forms);

  SavedForm? byId(String id) {
    for (final f in _forms) {
      if (f.id == id) return f;
    }
    return null;
  }

  Future<void> load() async {
    final prefs = _prefs ??= await SharedPreferences.getInstance();
    _forms.clear();
    final raw = prefs.getString(_key);
    if (raw != null && raw.isNotEmpty) {
      try {
        final list = jsonDecode(raw);
        if (list is List) {
          for (final e in list) {
            if (e is Map) {
              _forms.add(SavedForm.fromJson(Map<String, dynamic>.from(e)));
            }
          }
        }
      } catch (_) {
        // A corrupt blob is an empty list, not a crash on launch.
      }
    }
    _sort();
    notifyListeners();
  }

  void _sort() => _forms.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

  Future<void> _save() async {
    final prefs = _prefs ??= await SharedPreferences.getInstance();
    await prefs.setString(
        _key, jsonEncode([for (final f in _forms) f.toJson()]));
  }

  /// Saves a new form, or replaces the one with [id]. Returns the id, so the
  /// editor can go on editing what it just created.
  ///
  /// Takes a [now] rather than reading the clock, for the same reason every
  /// other store here does: a test that has to sleep to get two different
  /// timestamps is a test that sleeps.
  String save({
    String? id,
    required String title,
    required List<FormFieldSpec> fields,
    DateTime? now,
  }) {
    final at = now ?? DateTime.now();
    final formId = id ?? 'form_${at.microsecondsSinceEpoch}';
    final form = SavedForm(
        id: formId, title: title.trim(), fields: List.of(fields), updatedAt: at);
    final i = _forms.indexWhere((f) => f.id == formId);
    if (i >= 0) {
      _forms[i] = form;
    } else {
      _forms.add(form);
      // Oldest first out, so the cap never silently eats what is being used.
      if (_forms.length > maxForms) {
        _sort();
        _forms.removeRange(maxForms, _forms.length);
      }
    }
    _sort();
    notifyListeners();
    _save();
    return formId;
  }

  /// Removes a form. Returns it so the caller can offer an undo — deleting
  /// somebody's own work with no way back is the one thing worth guarding.
  SavedForm? remove(String id) {
    final i = _forms.indexWhere((f) => f.id == id);
    if (i < 0) return null;
    final gone = _forms.removeAt(i);
    notifyListeners();
    _save();
    return gone;
  }

  /// Puts a removed form back, keeping its own id and timestamp.
  void restore(SavedForm form) {
    if (_forms.any((f) => f.id == form.id)) return;
    _forms.add(form);
    _sort();
    notifyListeners();
    _save();
  }

  /// Account switch / wipe.
  ///
  /// Drops the cached [SharedPreferences] handle as well as the list, the
  /// same as [ChatFolders.resetForTest] — a stale handle is what makes the
  /// next `load()` read the previous account's blob back in.
  void reset() {
    _forms.clear();
    _prefs = null;
    notifyListeners();
  }
}
