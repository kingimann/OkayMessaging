import 'dart:async';

import 'package:flutter/foundation.dart';

/// Someone currently sitting in a voice channel.
@immutable
class VoiceOccupant {
  /// Phone digits — the identity the community bus travels under. Empty for
  /// the local user, who is always [isMe].
  final String digits;
  final String name;
  final bool muted;
  final bool video;
  final bool screen;
  final bool isMe;

  /// When this device last heard from them. Presence is a live signal, so a
  /// member whose app was force-quit has to age out rather than linger.
  final DateTime lastSeen;

  const VoiceOccupant({
    required this.digits,
    required this.name,
    required this.lastSeen,
    this.muted = false,
    this.video = false,
    this.screen = false,
    this.isMe = false,
  });

  VoiceOccupant copyWith({
    String? name,
    bool? muted,
    bool? video,
    bool? screen,
    DateTime? lastSeen,
  }) =>
      VoiceOccupant(
        digits: digits,
        name: name ?? this.name,
        muted: muted ?? this.muted,
        video: video ?? this.video,
        screen: screen ?? this.screen,
        isMe: isMe,
        lastSeen: lastSeen ?? this.lastSeen,
      );
}

/// Who is in which voice channel, right now.
///
/// Deliberately **not** persisted and never queued to the offline mailbox: a
/// join replayed from a mailbox hours later would show a ghost sitting in a
/// channel nobody is in. Presence is broadcast live only, refreshed by a
/// heartbeat, and swept when it goes quiet — so a force-quit or a dead
/// network clears itself instead of leaving someone permanently "in" a room.
class VoicePresenceStore extends ChangeNotifier {
  VoicePresenceStore._();
  static final VoicePresenceStore instance = VoicePresenceStore._();

  /// How often a joined device re-announces itself.
  static const Duration heartbeat = Duration(seconds: 20);

  /// How long an entry survives without being heard from. Comfortably more
  /// than two heartbeats, so one dropped packet doesn't evict anybody.
  static const Duration staleAfter = Duration(seconds: 65);

  /// channelId -> digits -> occupant. The local user is keyed by [_meKey].
  final Map<String, Map<String, VoiceOccupant>> _byChannel = {};

  static const _meKey = '__me__';

  String? _myChannelId;
  String? _myCommunityId;
  Timer? _timer;

  /// Broadcasts this device's presence. Wired to the relay at startup; left
  /// null in tests so nothing touches the network.
  void Function(String communityId, String channelId,
      {required bool joined,
      required bool muted,
      required bool video,
      required bool screen})? onPresence;

  /// The voice channel this device is in, if any.
  String? get myChannelId => _myChannelId;

  /// The server that channel belongs to — what the return-to-voice pill
  /// needs to navigate back.
  String? get myCommunityId => _myCommunityId;

  /// When this device joined its current channel. Held HERE rather than on
  /// the screen, because presence outlives the screen: coming back to the
  /// room must show the real elapsed time, not a timer restarted at zero.
  DateTime? get joinedAt => _joinedAt;
  DateTime? _joinedAt;

  /// Re-announces immediately — called when the app returns to the
  /// foreground, so the heartbeats everyone else aged out during a long
  /// suspension come back the moment you do, not one period later.
  void announceNow() {
    if (_myChannelId == null) return;
    _announce(joined: true);
    sweep();
  }

  bool amIn(String channelId) => _myChannelId == channelId;

  /// Everyone in [channelId], the local user first, then by name.
  List<VoiceOccupant> occupantsIn(String channelId) {
    final map = _byChannel[channelId];
    if (map == null || map.isEmpty) return const [];
    final list = map.values.toList()
      ..sort((a, b) {
        if (a.isMe != b.isMe) return a.isMe ? -1 : 1;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
    return List.unmodifiable(list);
  }

  int countIn(String channelId) => _byChannel[channelId]?.length ?? 0;

  /// Total people across every voice channel of a server, for the header.
  int countInChannels(Iterable<String> channelIds) {
    var total = 0;
    for (final id in channelIds) {
      total += countIn(id);
    }
    return total;
  }

  /// Joins [channelId], leaving whatever channel this device was in first —
  /// you can only be in one at a time, same as Discord.
  void join({
    required String communityId,
    required String channelId,
    required String myName,
  }) {
    if (_myChannelId != null && _myChannelId != channelId) leave();
    // Re-joining the channel you never left keeps the clock honest.
    _joinedAt = _myChannelId == channelId
        ? (_joinedAt ?? DateTime.now())
        : DateTime.now();
    _myCommunityId = communityId;
    _myChannelId = channelId;
    _byChannel.putIfAbsent(channelId, () => {})[_meKey] = VoiceOccupant(
      digits: '',
      name: myName,
      isMe: true,
      lastSeen: DateTime.now(),
    );
    _announce(joined: true);
    _timer?.cancel();
    _timer = Timer.periodic(heartbeat, (_) {
      _announce(joined: true);
      sweep();
    });
    notifyListeners();
  }

  /// Updates the local user's mic/camera state and tells everyone.
  void setLocalState({bool? muted, bool? video, bool? screen}) {
    final channelId = _myChannelId;
    if (channelId == null) return;
    final me = _byChannel[channelId]?[_meKey];
    if (me == null) return;
    _byChannel[channelId]![_meKey] =
        me.copyWith(muted: muted, video: video, screen: screen);
    _announce(joined: true);
    notifyListeners();
  }

  void leave() {
    final channelId = _myChannelId;
    if (channelId == null) return;
    _announce(joined: false);
    _byChannel[channelId]?.remove(_meKey);
    if (_byChannel[channelId]?.isEmpty ?? false) _byChannel.remove(channelId);
    _myChannelId = null;
    _myCommunityId = null;
    _joinedAt = null;
    _timer?.cancel();
    _timer = null;
    notifyListeners();
  }

  void _announce({required bool joined}) {
    final communityId = _myCommunityId;
    final channelId = _myChannelId;
    if (communityId == null || channelId == null) return;
    final me = _byChannel[channelId]?[_meKey];
    onPresence?.call(
      communityId,
      channelId,
      joined: joined,
      muted: me?.muted ?? false,
      video: me?.video ?? false,
      screen: me?.screen ?? false,
    );
  }

  /// Applies someone else's presence broadcast.
  ///
  /// [lastSeen] defaults to now — right for a live broadcast, which is
  /// current by definition. [applyGroundTruth] passes the real stored
  /// timestamp instead, so a row read back from the authoritative table
  /// (docs/community_voice.sql) ages out on the same clock a live-heard
  /// occupant does, rather than restarting the 65s countdown from the
  /// moment of the READ.
  void applyRemote({
    required String channelId,
    required String digits,
    required String name,
    required bool joined,
    bool muted = false,
    bool video = false,
    bool screen = false,
    DateTime? lastSeen,
  }) {
    if (digits.isEmpty) return;
    if (!joined) {
      _byChannel[channelId]?.remove(digits);
      if (_byChannel[channelId]?.isEmpty ?? false) _byChannel.remove(channelId);
      notifyListeners();
      return;
    }
    // Someone hopping channels shouldn't appear in two at once.
    for (final entry in _byChannel.entries) {
      if (entry.key != channelId) entry.value.remove(digits);
    }
    _byChannel.removeWhere((_, v) => v.isEmpty);
    _byChannel.putIfAbsent(channelId, () => {})[digits] = VoiceOccupant(
      digits: digits,
      name: name.isEmpty ? 'Member' : name,
      muted: muted,
      video: video,
      screen: screen,
      lastSeen: lastSeen ?? DateTime.now(),
    );
    notifyListeners();
  }

  /// A ground-truth read of [channelId]'s occupants from the authoritative
  /// table (docs/community_voice.sql) — the direct answer to "is Discord
  /// voice the same way": one deterministic read for full current occupancy,
  /// rather than only ever knowing who's here from accumulated broadcasts.
  /// Called once when a voice channel screen opens.
  ///
  /// Each [rows] entry is a raw column map — `member_phone`, `member_name`,
  /// `muted`, `video`, `screen`, `last_seen` — reconciled through the same
  /// [applyRemote] a live broadcast already uses, so a fetched occupant ages
  /// out exactly like a broadcast-heard one via the existing [sweep]. Rows
  /// already older than [staleAfter] are applied and then immediately swept,
  /// rather than skipped outright — the sweep is the one place that decides
  /// what counts as stale, so there is only ever one clock to trust.
  ///
  /// [myDigits] is deliberately never applied here: this device's own entry
  /// (keyed under [_meKey]) is already exactly current — it's the one thing
  /// this device knows better than any read could tell it — and applying a
  /// row keyed under this device's own wire digits would draw a SECOND,
  /// stale copy of the local user alongside the real one.
  void applyGroundTruth(String channelId, List<Map<String, dynamic>> rows,
      {required String myDigits}) {
    for (final row in rows) {
      final phone = row['member_phone'] as String? ?? '';
      if (phone.isEmpty || phone == myDigits) continue;
      final lastSeen =
          DateTime.tryParse(row['last_seen'] as String? ?? '') ??
              DateTime.now();
      applyRemote(
        channelId: channelId,
        digits: phone,
        name: row['member_name'] as String? ?? '',
        joined: true,
        muted: row['muted'] as bool? ?? false,
        video: row['video'] as bool? ?? false,
        screen: row['screen'] as bool? ?? false,
        lastSeen: lastSeen,
      );
    }
    sweep();
  }

  /// Drops anyone we haven't heard from within [staleAfter]. The local user is
  /// never swept — this device knows perfectly well whether it is still here.
  void sweep({DateTime? now}) {
    final cutoff = (now ?? DateTime.now()).subtract(staleAfter);
    var changed = false;
    for (final occupants in _byChannel.values) {
      final gone = [
        for (final e in occupants.entries)
          if (!e.value.isMe && e.value.lastSeen.isBefore(cutoff)) e.key
      ];
      for (final key in gone) {
        occupants.remove(key);
        changed = true;
      }
    }
    if (_byChannel.values.any((m) => m.isEmpty)) {
      _byChannel.removeWhere((_, v) => v.isEmpty);
      changed = true;
    }
    if (changed) notifyListeners();
  }

  @visibleForTesting
  void resetForTest() {
    _timer?.cancel();
    _timer = null;
    _byChannel.clear();
    _myChannelId = null;
    _myCommunityId = null;
    _joinedAt = null;
    onPresence = null;
    notifyListeners();
  }
}
