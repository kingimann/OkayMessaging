import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../relay/relay_config.dart';

/// One item of a user's own list, as the server holds it.
class UserItem {
  final String kind;
  final String id;
  final Map<String, dynamic> payload;
  final bool deleted;

  const UserItem({
    required this.kind,
    required this.id,
    this.payload = const {},
    this.deleted = false,
  });
}

/// Per-row sync for the lists that used to ride the backup blob.
///
/// **Why this exists.** The blob is ONE document with last-writer-wins over
/// the whole of it: two devices that both change something offline do not
/// merge — the second uploader wins outright, including for categories it
/// never touched. Per row, that conflict shrinks to the single item both
/// devices actually touched, and everything else on both sides survives.
/// That is the difference between a backup and a sync.
///
/// **One engine, not one per store.** Roughly forty stores are list-shaped.
/// A wrapper each would be forty things to keep in step, and this project
/// has already learned what happens when N copies of one idea drift. A store
/// converts by calling [put]/[remove] where it already saves, and [pull]
/// where it already loads.
///
/// **The clock is the SERVER's** — `docs/user_items.sql` stamps `updated_at`
/// in a trigger. "Last write wins" therefore means the last write to reach
/// the server, not whichever device has the furthest-ahead clock.
class UserItems {
  UserItems._();
  static final UserItems instance = UserItems._();

  static const table = 'user_items';

  /// Why the last call failed, or null. Kept rather than swallowed — this
  /// app has spent several rounds debugging failures the device had already
  /// been told about and thrown away.
  String? lastError;

  SupabaseClient? get _client {
    if (!RelayConfig.hasSession) return null;
    try {
      return Supabase.instance.client;
    } catch (_) {
      return null;
    }
  }

  /// Test hook: stands in for the whole round trip, so a store's conversion
  /// is testable without a server.
  @visibleForTesting
  static Future<List<UserItem>> Function(String kind)? debugPullOverride;

  /// Test hook: records writes instead of sending them.
  @visibleForTesting
  static List<UserItem>? debugWrites;

  /// Saves or updates one item. Fire-and-forget from a store's own save.
  Future<bool> put(String kind, String id,
      {Map<String, dynamic> payload = const {}}) async {
    final writes = debugWrites;
    if (writes != null) {
      writes.add(UserItem(kind: kind, id: id, payload: payload));
      return true;
    }
    final client = _client;
    if (client == null) return false;
    try {
      // owner_phone is deliberately NOT sent: the column defaults from the
      // caller's JWT, so the owner is a value the device cannot forge — and
      // naming it in an upsert would let a second write hand the row to
      // somebody else. Same shape as the market_upsert_fix lesson.
      await client.from(table).upsert({
        'kind': kind,
        'item_id': id,
        'payload': payload,
        'deleted': false,
      }, onConflict: 'owner_phone,kind,item_id');
      lastError = null;
      return true;
    } catch (e) {
      lastError = '$e';
      return false;
    }
  }

  /// Retires an item.
  ///
  /// A TOMBSTONE, not a removal: a row deleted outright would come straight
  /// back from any device that still had it locally, and the delete would
  /// never reach the others at all.
  Future<bool> remove(String kind, String id) async {
    final writes = debugWrites;
    if (writes != null) {
      writes.add(UserItem(kind: kind, id: id, deleted: true));
      return true;
    }
    final client = _client;
    if (client == null) return false;
    try {
      await client.from(table).upsert({
        'kind': kind,
        'item_id': id,
        'deleted': true,
      }, onConflict: 'owner_phone,kind,item_id');
      lastError = null;
      return true;
    } catch (e) {
      lastError = '$e';
      return false;
    }
  }

  /// Everything of one [kind] this account holds, tombstones included.
  ///
  /// The tombstones are returned rather than filtered out on purpose: a
  /// store needs them to REMOVE what another device retired. Dropping them
  /// here would make a delete invisible, which is the failure this whole
  /// mechanism exists to avoid.
  Future<List<UserItem>> pull(String kind) async {
    final override = debugPullOverride;
    if (override != null) return override(kind);
    final client = _client;
    if (client == null) return const [];
    try {
      final rows = await client
          .from(table)
          .select('item_id, payload, deleted')
          .eq('kind', kind) as List<dynamic>;
      lastError = null;
      return [
        for (final raw in rows)
          if (raw is Map)
            UserItem(
              kind: kind,
              id: (raw['item_id'] as String?) ?? '',
              payload: raw['payload'] is Map
                  ? Map<String, dynamic>.from(raw['payload'] as Map)
                  : const {},
              deleted: raw['deleted'] == true,
            ),
      ];
    } catch (e) {
      lastError = '$e';
      return const [];
    }
  }

  @visibleForTesting
  void resetForTest() {
    lastError = null;
    debugPullOverride = null;
    debugWrites = null;
  }
}
