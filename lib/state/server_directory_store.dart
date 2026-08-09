import 'package:flutter/foundation.dart';

/// One PUBLIC server as it appears in the Discover directory: enough to render
/// a browse card, plus the full [invite] snapshot a device decodes to join.
/// The owner's phone is never part of this — the directory view never carries
/// it and the invite has never carried one.
@immutable
class DiscoverServer {
  final String id;
  final String name;
  final String description;
  final int memberCount;

  /// The invite snapshot (CommunityStore.exportInvite), secret included — this
  /// is what joining decodes, the same shape a tapped invite card carries.
  final Map<String, dynamic> invite;

  const DiscoverServer({
    required this.id,
    required this.name,
    required this.description,
    required this.memberCount,
    required this.invite,
  });

  /// Whether [query] matches this server's name or description (case-folded).
  bool matches(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return true;
    return name.toLowerCase().contains(q) ||
        description.toLowerCase().contains(q);
  }
}

/// Holds the fetched Discover directory, refreshed from the world-readable
/// `server_directory_view` by the relay on start and on pull-to-refresh. Pure
/// state — no network, no crypto — so it stays testable; the relay is the one
/// that talks to Supabase.
class ServerDirectoryStore extends ChangeNotifier {
  ServerDirectoryStore._();
  static final ServerDirectoryStore instance = ServerDirectoryStore._();

  List<DiscoverServer> _servers = const [];
  List<DiscoverServer> get servers => List.unmodifiable(_servers);

  /// Replaces the directory with a freshly fetched set (newest first, as the
  /// query returned them).
  void setAll(List<DiscoverServer> servers) {
    _servers = List.of(servers);
    notifyListeners();
  }

  /// Servers matching [query], preserving fetch order.
  List<DiscoverServer> search(String query) =>
      _servers.where((s) => s.matches(query)).toList();

  @visibleForTesting
  void resetForTest() {
    _servers = const [];
    notifyListeners();
  }
}
