import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/community.dart';
import '../models/message.dart';

/// Local store for Discord-style communities (servers) and their channels.
/// Everything lives on the device and is persisted to [SharedPreferences];
/// nothing is stored on a server.
class CommunityStore extends ChangeNotifier {
  CommunityStore._();
  static final CommunityStore instance = CommunityStore._();

  static const _key = 'communities_v1';

  List<Community> _communities = [];
  SharedPreferences? _prefs;

  List<Community> get communities => List.unmodifiable(_communities);

  /// Loads persisted communities, seeding a sample one on first run.
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _prefs = prefs;
    final raw = prefs.getString(_key);
    if (raw != null) {
      try {
        _communities = (jsonDecode(raw) as List)
            .map((c) => Community.fromJson(Map<String, dynamic>.from(c as Map)))
            .toList();
      } catch (_) {
        _communities = _seed();
      }
    } else {
      _communities = _seed();
      _save();
    }
    notifyListeners();
  }

  List<Community> _seed() => [
        Community(
          id: 'seed_design',
          name: 'Design Team',
          color: '#7A5CFF',
          channels: [
            Channel(id: 'seed_general', name: 'general', messages: [
              Message(
                id: 'seed_m1',
                text: 'Welcome to the Design Team community! 🎨',
                time: DateTime(2024, 1, 1, 9),
                isMe: false,
              ),
            ]),
            const Channel(id: 'seed_ideas', name: 'ideas'),
            const Channel(id: 'seed_random', name: 'random'),
          ],
        ),
      ];

  void _save() {
    _prefs?.setString(
        _key, jsonEncode(_communities.map((c) => c.toJson()).toList()));
  }

  Community? byId(String id) {
    final i = _communities.indexWhere((c) => c.id == id);
    return i == -1 ? null : _communities[i];
  }

  void _replace(Community community) {
    final i = _communities.indexWhere((c) => c.id == community.id);
    if (i != -1) {
      _communities[i] = community;
      _save();
      notifyListeners();
    }
  }

  /// Creates a community with an initial `#general` channel.
  Community createCommunity(String name, {String color = '#7A5CFF'}) {
    final id = 'c_${name.hashCode}_${_communities.length}';
    final community = Community(
      id: id,
      name: name.trim(),
      color: color,
      channels: [Channel(id: '${id}_general', name: 'general')],
    );
    _communities.add(community);
    _save();
    notifyListeners();
    return community;
  }

  void addChannel(String communityId, String channelName) {
    final community = byId(communityId);
    if (community == null) return;
    final clean = channelName
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'\s+'), '-')
        .replaceAll(RegExp(r'[^a-z0-9\-_]'), '');
    if (clean.isEmpty) return;
    final channel = Channel(
        id: '${communityId}_${clean}_${community.channels.length}',
        name: clean);
    _replace(community.copyWith(channels: [...community.channels, channel]));
  }

  void postMessage(String communityId, String channelId, Message message) {
    final community = byId(communityId);
    if (community == null) return;
    final channels = community.channels.map((ch) {
      if (ch.id != channelId) return ch;
      return ch.copyWith(messages: [...ch.messages, message]);
    }).toList();
    _replace(community.copyWith(channels: channels));
  }

  void deleteCommunity(String communityId) {
    _communities.removeWhere((c) => c.id == communityId);
    _save();
    notifyListeners();
  }

  @visibleForTesting
  void resetForTest() {
    _communities = _seed();
    _prefs = null;
    notifyListeners();
  }
}
