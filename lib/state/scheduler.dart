import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/message.dart';
import '../models/scheduled_message.dart';
import '../relay/relay_config.dart';
import '../relay/relay_service.dart';
import 'chat_store.dart';

/// Holds messages the user has scheduled to send later, persists them on the
/// device, and delivers each one when its time arrives (while the app is
/// running). Delivery routes through [ChatStore] and, for real number-based
/// peers, the relay — so a scheduled message behaves exactly like one sent by
/// hand at that moment.
class Scheduler extends ChangeNotifier {
  Scheduler._();
  static final Scheduler instance = Scheduler._();

  static const _key = 'scheduled_v1';

  final List<ScheduledMessage> _items = [];
  SharedPreferences? _prefs;
  Timer? _timer;

  /// All pending scheduled messages, soonest first.
  List<ScheduledMessage> get pending {
    final list = List<ScheduledMessage>.from(_items);
    list.sort((a, b) => a.time.compareTo(b.time));
    return list;
  }

  /// Pending scheduled messages for a single conversation.
  List<ScheduledMessage> pendingFor(String chatId) =>
      pending.where((s) => s.chatId == chatId).toList();

  /// Loads saved scheduled messages, flushes any already-due ones, and starts
  /// the delivery timer.
  Future<void> init() async {
    _prefs ??= await SharedPreferences.getInstance();
    final raw = _prefs!.getString(_key);
    if (raw != null) {
      try {
        _items
          ..clear()
          ..addAll((jsonDecode(raw) as List).map((e) =>
              ScheduledMessage.fromJson(Map<String, dynamic>.from(e as Map))));
      } catch (_) {}
    }
    flushDue();
    _timer ??=
        Timer.periodic(const Duration(seconds: 15), (_) => flushDue());
  }

  /// Schedules [text] for [chatId] at [time].
  void schedule({
    required String chatId,
    required String contactPhone,
    required String text,
    required DateTime time,
    String? id,
  }) {
    _items.add(ScheduledMessage(
      id: id ?? 'sch_${time.microsecondsSinceEpoch}_${_items.length}',
      chatId: chatId,
      contactPhone: contactPhone,
      text: text,
      time: time,
    ));
    _persist();
    notifyListeners();
  }

  void cancel(String id) {
    _items.removeWhere((s) => s.id == id);
    _persist();
    notifyListeners();
  }

  /// Delivers every scheduled message whose time has passed. Returns the number
  /// delivered (also used by tests).
  @visibleForTesting
  int flushDue([DateTime? now]) {
    final when = now ?? DateTime.now();
    final due = _items.where((s) => !s.time.isAfter(when)).toList();
    if (due.isEmpty) return 0;
    for (final s in due) {
      _deliver(s, when);
      _items.remove(s);
    }
    _persist();
    notifyListeners();
    return due.length;
  }

  void _deliver(ScheduledMessage s, DateTime when) {
    final chat = ChatStore.instance.chatById(s.chatId);
    if (chat == null) return;
    final message = Message(
      id: 'local_${s.id}',
      text: s.text,
      time: when,
      isMe: true,
      status: MessageStatus.sent,
    );
    ChatStore.instance.addMessage(s.chatId, message);

    final contact = chat.contact;
    final isRealPeer = !contact.isGroup &&
        contact.phone.isNotEmpty &&
        contact.id == contact.phone;
    if (RelayConfig.isEnabled && isRealPeer) {
      RelayService.instance.send(contact.phone, message);
    }
  }

  void _persist() {
    _prefs?.setString(
        _key, jsonEncode(_items.map((s) => s.toJson()).toList()));
  }

  @visibleForTesting
  void resetForTest() {
    _items.clear();
    _timer?.cancel();
    _timer = null;
  }
}
