import 'package:flutter/material.dart';

import '../app_state.dart';
import '../state/follow_store.dart';
import '../state/public_feed_store.dart';
import '../theme/app_theme.dart';
import '../widgets/feed_post_parts.dart';
import '../widgets/phone_gate.dart';
import 'public_feed_screen.dart';

/// The X-shaped followers/following screen: a full screen titled with whose
/// list it is, a Followers | Following tab bar, and a row per person — avatar,
/// name, @handle, and a Follow/Following button on the right. Replaces the old
/// bottom sheet, which was a bare list of names with nothing to do on it.
class FollowListScreen extends StatefulWidget {
  const FollowListScreen({
    super.key,
    required this.username,
    this.displayName = '',
    this.showFollowers = true,
  });

  /// Whose lists these are (no '@').
  final String username;

  /// Their display name for the title; '@username' when empty.
  final String displayName;

  /// Which tab opens first — tapping the Followers stat lands on Followers,
  /// the Following stat on Following.
  final bool showFollowers;

  @override
  State<FollowListScreen> createState() => _FollowListScreenState();
}

class _FollowListScreenState extends State<FollowListScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(
      length: 2, vsync: this, initialIndex: widget.showFollowers ? 0 : 1);

  /// Null while loading; empty when loaded and there is nobody.
  List<(String, String)>? _followers;
  List<(String, String)>? _following;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    PublicFeedStore.instance.followersOf(widget.username).then((list) {
      if (mounted) setState(() => _followers = list ?? const []);
    });
    PublicFeedStore.instance.followingOf(widget.username).then((list) {
      if (mounted) setState(() => _following = list ?? const []);
    });
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.displayName.trim().isEmpty
        ? '@${widget.username}'
        : widget.displayName.trim();
    return Scaffold(
      appBar: AppBar(
        // Whose lists these are, X-style: the name up top, the handle under it.
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style:
                    const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
            Text('@${widget.username}',
                style:
                    TextStyle(fontSize: 12.5, color: AppColors.subtle(context))),
          ],
        ),
        bottom: TabBar(
          controller: _tabs,
          tabs: const [Tab(text: 'Followers'), Tab(text: 'Following')],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [
          _FollowList(
              people: _followers,
              emptyText: 'No followers yet',
              onRefresh: _load),
          _FollowList(
              people: _following,
              emptyText: 'Not following anyone yet',
              onRefresh: _load),
        ],
      ),
    );
  }
}

class _FollowList extends StatelessWidget {
  const _FollowList({
    required this.people,
    required this.emptyText,
    required this.onRefresh,
  });

  /// (username, display name) rows; null while loading.
  final List<(String, String)>? people;
  final String emptyText;
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) {
    final list = people;
    if (list == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (list.isEmpty) {
      return RefreshIndicator(
        onRefresh: onRefresh,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            const SizedBox(height: 120),
            Icon(Icons.people_outline, size: 48, color: Colors.grey.shade400),
            const SizedBox(height: 12),
            Center(
                child: Text(emptyText,
                    style: TextStyle(color: AppColors.subtle(context)))),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: onRefresh,
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: list.length,
        itemBuilder: (context, i) {
          final (username, name) = list[i];
          return _PersonRow(username: username, name: name);
        },
      ),
    );
  }
}

/// One person: avatar, name, @handle, and the Follow/Following button — the
/// same row X draws. Your own row carries no button (you can't follow you).
class _PersonRow extends StatelessWidget {
  const _PersonRow({required this.username, required this.name});

  final String username;
  final String name;

  @override
  Widget build(BuildContext context) {
    final display = name.trim().isEmpty ? '@$username' : name.trim();
    final me = AppState.profile.value.username.toLowerCase() ==
        username.toLowerCase();
    return ListTile(
      leading: FeedAvatar(username: username, name: name, radius: 22),
      title: Text(display,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w700)),
      subtitle: Text('@$username',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: AppColors.subtle(context))),
      trailing: me
          ? null
          : ListenableBuilder(
              listenable: FollowStore.instance,
              builder: (context, _) {
                final following = FollowStore.instance.isFollowing(username);
                final dense = OutlinedButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  minimumSize: const Size(0, 34),
                );
                void toggle() {
                  if (postNeedsPhone(context, what: 'Following')) return;
                  FollowStore.instance.toggle(username);
                }
                return following
                    ? OutlinedButton(
                        style: dense,
                        onPressed: toggle,
                        child: const Text('Following'))
                    : FilledButton(
                        style: dense,
                        onPressed: toggle,
                        child: const Text('Follow'));
              },
            ),
      onTap: () => openPublicProfile(context, username, name: name),
    );
  }
}
