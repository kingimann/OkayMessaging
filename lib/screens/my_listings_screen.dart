import 'package:flutter/material.dart';

import '../app_state.dart';
import '../payments/earnings.dart';
import '../state/feed_store.dart';
import '../theme/app_theme.dart';
import '../widgets/app_dialogs.dart';
import '../widgets/chat_photo.dart';
import '../widgets/user_avatar.dart';
import 'marketplace_screen.dart' show ListingScreen, SellScreen, SellerScreen;

/// The seller's side of the Marketplace in one place: every listing this
/// account has up, what each one has done (unique viewers, ridden on the
/// same fview tally the feeds use), and the levers — edit, price, sold,
/// bump, delete — without hunting each listing down in the grid.
class MyListingsScreen extends StatelessWidget {
  const MyListingsScreen({super.key});

  /// The handle this account's listings are filed under — its username, or
  /// the 'you' FeedStore writes when there isn't one yet.
  static String myHandle() {
    final me = AppState.profile.value.username;
    return me.isEmpty ? 'you' : me;
  }

  /// The way to your OWN marketplace profile — the page a buyer lands on.
  ///
  /// It had no door. [SellerScreen] has always handled yourself, but the only
  /// route to it was opening one of your own listings and tapping the seller
  /// row, so a seller could not check how they looked without owning a live
  /// listing to go through. This row sits above the management list and in
  /// the empty state, which is exactly when somebody is deciding whether to
  /// sell here at all.
  Widget _profileRow(BuildContext context) {
    final me = AppState.profile.value;
    final (avg, count) = FeedStore.instance.sellerRating(myHandle());
    return ListTile(
      leading: UserAvatar(user: me, radius: 22),
      title: Text(me.name.trim().isEmpty ? 'Your profile' : me.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w700)),
      subtitle: Text(
        count == 0
            ? 'Your marketplace profile — no reviews yet'
            : 'Your marketplace profile · ${avg.toStringAsFixed(1)}★ '
                'from $count ${count == 1 ? 'review' : 'reviews'}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => Navigator.of(context).push(MaterialPageRoute(
          builder: (_) =>
              SellerScreen(username: myHandle(), name: me.name))),
    );
  }

  bool _mine(FeedPost p) {
    final me = AppState.profile.value.username;
    return p.authorUsername == 'you' ||
        (me.isNotEmpty && p.authorUsername == me);
  }

  String _price(FeedPost l) =>
      (l.priceCents ?? 0) == 0 ? 'Free' : moneyLabel(l.priceCents!);

  Future<void> _delete(BuildContext context, FeedPost listing) async {
    final sure = await showAppConfirmDialog(
      context,
      icon: Icons.delete_outline,
      title: 'Delete this listing?',
      // Not "everyone on the server" — a listing has been GLOBAL since the
      // marketplace moved to its own world-readable table, so it disappears
      // for everyone full stop, whether or not they share a server with you.
      message: 'It disappears for everyone, along with its photos and video. '
          'This can\'t be undone.',
      confirmLabel: 'Delete',
      destructive: true,
    );
    if (sure) FeedStore.instance.deletePost(listing.id);
  }

  Widget _row(BuildContext context, FeedPost l) {
    final store = FeedStore.instance;
    final title = l.text.split('\n').first;
    final canBump = !l.listingSold && store.canBumpListing(l.id);
    final bits = [
      _price(l),
      if (l.listingReserved && !l.listingSold) 'Reserved',
      if (l.views > 0) '${l.views} ${l.views == 1 ? 'viewer' : 'viewers'}',
      if (l.listingQuantity > 1) '${l.listingQuantity} available',
    ].join(' · ');
    return ListTile(
      leading: SizedBox(
        width: 48,
        height: 48,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: l.gifUrl != null
              ? Opacity(
                  opacity: l.listingSold ? 0.55 : 1,
                  child: ChatPhoto(
                    url: l.gifUrl!,
                    fit: BoxFit.cover,
                    errorBuilder: (_) =>
                        const Icon(Icons.image_not_supported_outlined),
                  ),
                )
              : Container(
                  color: Theme.of(context)
                      .colorScheme
                      .surfaceContainerHighest,
                  child: const Icon(Icons.sell_outlined, size: 20),
                ),
        ),
      ),
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(bits),
      onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => ListingScreen(listingId: l.id))),
      trailing: PopupMenuButton<String>(
        tooltip: 'Manage',
        onSelected: (action) {
          switch (action) {
            case 'edit':
              Navigator.of(context).push(MaterialPageRoute(
                  fullscreenDialog: true,
                  builder: (_) => SellScreen(existing: l)));
            case 'sold':
              FeedStore.instance.setListingSold(l.id, !l.listingSold);
            case 'reserve':
              FeedStore.instance
                  .setListingReserved(l.id, !l.listingReserved);
            case 'bump':
              FeedStore.instance.bumpListing(l.id);
            case 'duplicate':
              final copy = FeedStore.instance.duplicateListing(l.id);
              if (copy != null) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                    content: Text('Copied to a new listing.')));
              }
            case 'delete':
              _delete(context, l);
          }
        },
        itemBuilder: (context) => [
          const PopupMenuItem(
              value: 'edit', child: Text('Edit listing')),
          PopupMenuItem(
              value: 'sold',
              child:
                  Text(l.listingSold ? 'Mark available' : 'Mark sold')),
          if (!l.listingSold)
            PopupMenuItem(
                value: 'reserve',
                child: Text(
                    l.listingReserved ? 'Clear reserved' : 'Mark reserved')),
          if (canBump)
            const PopupMenuItem(
                value: 'bump', child: Text('Bump to the top')),
          const PopupMenuItem(
              value: 'duplicate', child: Text('Duplicate listing')),
          const PopupMenuItem(value: 'delete', child: Text('Delete')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Your listings')),
      body: ListenableBuilder(
        listenable: FeedStore.instance,
        builder: (context, _) {
          final mine =
              FeedStore.instance.listings().where(_mine).toList();
          final active = mine.where((l) => !l.listingSold).toList();
          final sold = mine.where((l) => l.listingSold).toList();
          final earned = sold.fold(
              0, (sum, l) => sum + ((l.priceCents ?? 0)));
          if (mine.isEmpty) {
            return ListView(children: [
              _profileRow(context),
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.fromLTRB(40, 48, 40, 0),
                child: Column(
                  children: [
                    Icon(Icons.sell_outlined,
                        size: 52, color: Colors.grey.shade400),
                    const SizedBox(height: 14),
                    const Text('Nothing listed yet',
                        style: TextStyle(
                            fontSize: 17, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 8),
                    Text(
                      'When you put something up for sale, this is where '
                      'you manage it — price, sold, bumps, all in one '
                      'place.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          color: AppColors.subtle(context), fontSize: 14),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
            ]);
          }
          return ListView(
            children: [
              _profileRow(context),
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
                child: Text(
                  [
                    '${active.length} active',
                    '${sold.length} sold',
                    if (earned > 0) '${moneyLabel(earned)} in sales',
                  ].join(' · '),
                  style: TextStyle(
                      fontSize: 13, color: AppColors.subtle(context)),
                ),
              ),
              for (final l in active) _row(context, l),
              if (sold.isNotEmpty) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
                  child: Text('SOLD',
                      style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.7,
                          color: AppColors.subtle(context))),
                ),
                for (final l in sold) _row(context, l),
              ],
            ],
          );
        },
      ),
    );
  }
}
