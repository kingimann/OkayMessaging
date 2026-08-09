import 'package:flutter/material.dart';

import '../relay/relay_config.dart';
import '../relay/relay_service.dart';
import '../state/community_store.dart';
import '../state/server_directory_store.dart';
import 'communities.dart';

Color _hex(String s) {
  try {
    return Color(int.parse(s.replaceFirst('#', 'ff'), radix: 16));
  } catch (_) {
    return const Color(0xFF7A5CFF);
  }
}

/// Discover: browse the world-readable directory of PUBLIC servers and join one
/// without an invite. A private server never appears here — this is only the
/// servers whose owners chose to list them. Reading is served by the anon key,
/// so even a name-only account can look; joining follows the same path a tapped
/// invite card uses.
class ServerDiscoverScreen extends StatefulWidget {
  const ServerDiscoverScreen({super.key});

  @override
  State<ServerDiscoverScreen> createState() => _ServerDiscoverScreenState();
}

class _ServerDiscoverScreenState extends State<ServerDiscoverScreen> {
  final _search = TextEditingController();
  String _query = '';

  @override
  void initState() {
    super.initState();
    // Pull the latest directory when the screen opens.
    if (RelayConfig.isEnabled) {
      RelayService.instance.fetchServerDirectory();
    }
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (RelayConfig.isEnabled) {
      await RelayService.instance.fetchServerDirectory();
    }
  }

  void _join(DiscoverServer server) {
    final community = joinServerFromSnapshot(
      server.invite,
      onRefused: (msg) => ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(msg))),
    );
    if (community != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Joined "${community.name}"')));
      setState(() {}); // the row flips to "Joined"
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Discover servers')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: TextField(
              controller: _search,
              onChanged: (v) => setState(() => _query = v),
              decoration: InputDecoration(
                hintText: 'Search public servers',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () {
                          _search.clear();
                          setState(() => _query = '');
                        },
                      ),
                filled: true,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                  borderSide: BorderSide.none,
                ),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 0),
              ),
            ),
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _refresh,
              child: ListenableBuilder(
                listenable: ServerDirectoryStore.instance,
                builder: (context, _) {
                  final servers =
                      ServerDirectoryStore.instance.search(_query);
                  if (servers.isEmpty) {
                    return ListView(
                      children: [
                        const SizedBox(height: 80),
                        Icon(Icons.explore_outlined,
                            size: 56, color: Colors.grey.shade400),
                        const SizedBox(height: 12),
                        Center(
                          child: Text(
                            _query.isEmpty
                                ? 'No public servers yet.\nPull down to refresh.'
                                : 'No servers match "$_query".',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant),
                          ),
                        ),
                      ],
                    );
                  }
                  return ListView.separated(
                    padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
                    itemCount: servers.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (context, i) =>
                        _DiscoverCard(server: servers[i], onJoin: _join),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DiscoverCard extends StatelessWidget {
  final DiscoverServer server;
  final void Function(DiscoverServer) onJoin;
  const _DiscoverCard({required this.server, required this.onJoin});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final invite = server.invite;
    final color = _hex(invite['color'] as String? ?? '#7A5CFF');
    final icon = invite['icon'] as String? ?? '';
    final joined = CommunityStore.instance.byId(server.id) != null;
    final members = server.memberCount;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 24,
            backgroundColor: color,
            child: Text(
              icon.isNotEmpty
                  ? icon
                  : (server.name.isEmpty
                      ? '?'
                      : server.name[0].toUpperCase()),
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w800),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(server.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w700)),
                if (server.description.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(server.description,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 12.5, color: scheme.onSurfaceVariant)),
                ],
                const SizedBox(height: 4),
                Text(
                    '$members ${members == 1 ? 'member' : 'members'}',
                    style: TextStyle(
                        fontSize: 12, color: scheme.onSurfaceVariant)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          joined
              ? const Chip(label: Text('Joined'))
              : FilledButton(
                  onPressed: () => onJoin(server),
                  child: const Text('Join'),
                ),
        ],
      ),
    );
  }
}
