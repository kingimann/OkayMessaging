import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/user.dart';

/// One saved contact — a person the user chose to keep, whether or not they
/// have ever chatted. This is the address book the app never had: People only
/// ever showed people you already had a chat with, so a number somebody hands
/// you had nowhere to live until you messaged it.
@immutable
class SavedContact {
  const SavedContact({
    required this.id,
    required this.name,
    this.phone = '',
    this.username = '',
    this.note = '',
    this.avatarColor = '#64B5F6',
    required this.createdAt,
  });

  final String id;
  final String name;

  /// A phone number and/or a username — either can reach them. At least one is
  /// needed to start a chat; a contact may carry only a name (someone you note
  /// down before you have their number).
  final String phone;
  final String username;

  /// A free-text note the user keeps about them ("plumber", "met at Ana's").
  final String note;
  final String avatarColor;
  final DateTime createdAt;

  /// The username with a leading '@', for display; empty when there is none.
  String get handle =>
      username.isEmpty ? '' : (username.startsWith('@') ? username : '@$username');

  /// What addresses them for a chat: the phone if they have one, else the
  /// username. Empty when the contact is a name and nothing else.
  String get addressKey => phone.isNotEmpty ? phone : username;

  /// Whether this contact can be messaged at all.
  bool get canMessage => addressKey.isNotEmpty;

  /// The one-line subtitle a row shows: note if set, else the handle/number.
  String get subtitle {
    if (note.trim().isNotEmpty) return note.trim();
    if (handle.isNotEmpty) return handle;
    return phone;
  }

  /// An [AppUser] view for avatars, chat creation and the contact card.
  AppUser toUser() => AppUser(
        id: addressKey.isNotEmpty ? addressKey : id,
        name: name,
        avatarColor: avatarColor.isEmpty ? '#64B5F6' : avatarColor,
        about: 'Available',
        phone: phone,
        username: username,
      );

  SavedContact copyWith({
    String? name,
    String? phone,
    String? username,
    String? note,
  }) =>
      SavedContact(
        id: id,
        name: name ?? this.name,
        phone: phone ?? this.phone,
        username: username ?? this.username,
        note: note ?? this.note,
        avatarColor: avatarColor,
        createdAt: createdAt,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        if (phone.isNotEmpty) 'phone': phone,
        if (username.isNotEmpty) 'username': username,
        if (note.isNotEmpty) 'note': note,
        'avatarColor': avatarColor,
        'createdAt': createdAt.toUtc().toIso8601String(),
      };

  static SavedContact? fromJson(Map<String, dynamic> j) {
    final id = j['id'] as String? ?? '';
    final name = (j['name'] as String? ?? '').trim();
    if (id.isEmpty || name.isEmpty) return null;
    return SavedContact(
      id: id,
      name: name,
      phone: (j['phone'] as String? ?? '').trim(),
      username: (j['username'] as String? ?? '').trim(),
      note: j['note'] as String? ?? '',
      avatarColor: j['avatarColor'] as String? ?? '#64B5F6',
      createdAt:
          DateTime.tryParse(j['createdAt'] as String? ?? '')?.toLocal() ??
              DateTime.now(),
    );
  }
}

/// The saved-contacts address book.
///
/// ON THE DEVICE, like the rest of what this app knows about you. There is no
/// contacts table and no server column — the list is JSON in shared
/// preferences. It rides the encrypted cloud sync alongside notes, servers and
/// saved places while a storage subscription is active, sealed with the same
/// key before it leaves.
class ContactsStore extends ChangeNotifier {
  ContactsStore._();
  static final ContactsStore instance = ContactsStore._();

  static const _key = 'saved_contacts_v1';

  List<SavedContact> _contacts = [];
  SharedPreferences? _prefs;

  /// Alphabetical by name — an address book you scan, not a timeline.
  List<SavedContact> get contacts {
    final list = [..._contacts];
    list.sort(
        (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return List.unmodifiable(list);
  }

  int get count => _contacts.length;

  Future<void> load() async {
    _prefs = await SharedPreferences.getInstance();
    _contacts = _decode(_prefs!.getString(_key));
    notifyListeners();
  }

  SavedContact? byId(String id) {
    for (final c in _contacts) {
      if (c.id == id) return c;
    }
    return null;
  }

  /// Contacts matching [query] across name, username, phone and note.
  List<SavedContact> search(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return contacts;
    return [
      for (final c in contacts)
        if ('${c.name} ${c.username} ${c.phone} ${c.note}'
            .toLowerCase()
            .contains(q))
          c
    ];
  }

  /// Creates a contact, or updates [id] when given. A blank name saves nothing.
  Future<SavedContact?> save({
    String? id,
    required String name,
    String phone = '',
    String username = '',
    String note = '',
  }) async {
    final n = name.trim();
    if (n.isEmpty) return null;
    final u = username.trim().replaceFirst(RegExp(r'^@'), '');
    final existing = id == null ? null : byId(id);
    final contact = existing == null
        ? SavedContact(
            id: newId(),
            name: n,
            phone: phone.trim(),
            username: u,
            note: note.trim(),
            createdAt: DateTime.now(),
          )
        : existing.copyWith(
            name: n, phone: phone.trim(), username: u, note: note.trim());
    _contacts = existing == null
        ? [contact, ..._contacts]
        : [for (final c in _contacts) c.id == contact.id ? contact : c];
    notifyListeners();
    await _persist();
    return contact;
  }

  Future<void> delete(String id) async {
    final kept = [for (final c in _contacts) if (c.id != id) c];
    if (kept.length == _contacts.length) return;
    _contacts = kept;
    notifyListeners();
    await _persist();
  }

  // --- Cloud sync ---------------------------------------------------------

  List<Map<String, dynamic>> exportContacts() =>
      [for (final c in contacts) c.toJson()];

  /// Merges a restored backup in, keyed by id — a contact this device already
  /// has is not duplicated, and one it has never seen is added.
  void hydrateContacts(List<dynamic> rows) {
    final byIdMap = {for (final c in _contacts) c.id: c};
    for (final r in rows.whereType<Map>()) {
      final incoming = SavedContact.fromJson(Map<String, dynamic>.from(r));
      if (incoming == null) continue;
      byIdMap[incoming.id] = incoming;
    }
    _contacts = byIdMap.values.toList();
    notifyListeners();
    _persist();
  }

  static String newId() {
    final rng = Random.secure();
    final n = List<int>.generate(8, (_) => rng.nextInt(256))
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    return 'ct_$n';
  }

  Future<void> _persist() async {
    await _prefs?.setString(
        _key, jsonEncode([for (final c in _contacts) c.toJson()]));
  }

  static List<SavedContact> _decode(String? raw) {
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw);
      if (list is! List) return [];
      return [
        for (final r in list.whereType<Map>())
          if (SavedContact.fromJson(Map<String, dynamic>.from(r))
              case final SavedContact c)
            c
      ];
    } catch (_) {
      return [];
    }
  }

  @visibleForTesting
  void resetForTest() {
    _contacts = [];
    _prefs = null;
    notifyListeners();
  }
}
