import 'package:flutter/material.dart';

import '../app_state.dart';
import '../state/community_store.dart';
import '../state/feed_store.dart';
import '../util/file_moderation.dart';
import '../util/photo_prep.dart';
import '../widgets/chat_photo.dart';
import 'feed_screen.dart' show showPersonSheet, feedSpans;

/// The categories a listing can file under. A fixed list, because filters
/// only work when sellers and buyers pick from the same words.
const List<String> kMarketplaceCategories = [
  'Electronics',
  'Furniture',
  'Clothing',
  'Vehicles',
  'Home & Garden',
  'Sports',
  'Games & Toys',
  'Books',
  'Free stuff',
  'Other',
];

/// "$20", "$12.50", "Free" — a price tag, not an accounting figure.
/// Pure, so the rounding is testable.
String formatListingPrice(int cents) {
  if (cents <= 0) return 'Free';
  final dollars = cents ~/ 100;
  final rem = cents % 100;
  if (rem == 0) return '\$$dollars';
  return '\$$dollars.${rem.toString().padLeft(2, '0')}';
}

/// Parses a typed price ("20", "12.50", "$1,200") into cents, or null when it
/// isn't a price. Pure.
int? parseListingPrice(String raw) {
  final cleaned = raw.replaceAll(RegExp(r'[\s$,]'), '');
  if (cleaned.isEmpty) return 0; // blank = free, the seller typed nothing
  if (!RegExp(r'^\d+(\.\d{1,2})?$').hasMatch(cleaned)) return null;
  final parts = cleaned.split('.');
  final dollars = int.parse(parts[0]);
  final cents = parts.length == 1
      ? 0
      : int.parse(parts[1].padRight(2, '0').substring(0, 2));
  if (dollars > 1000000) return null; // a typo, not a price
  return dollars * 100 + cents;
}

/// A Facebook-style marketplace over the servers the user is in.
///
/// Listings ride the same sealed relay as feed posts — same encryption, same
/// persistence, same delete tombstones — so nothing new stands between a
/// listing and the people who can see it. The audience is honest: members of
/// your servers, because that is who this app can reach. There is no global
/// listings database; a marketplace with one would mean a server that reads
/// everything sold.
class MarketplaceScreen extends StatefulWidget {
  const MarketplaceScreen({super.key});

  @override
  State<MarketplaceScreen> createState() => _MarketplaceScreenState();
}

class _MarketplaceScreenState extends State<MarketplaceScreen> {
  String _category = '';
  String _query = '';
  final TextEditingController _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  String _serverName(String id) {
    for (final c in CommunityStore.instance.communities) {
      if (c.id == id) return c.name;
    }
    return '';
  }

  bool _mine(FeedPost p) {
    final me = AppState.profile.value.username;
    return p.authorUsername == 'you' ||
        (me.isNotEmpty && p.authorUsername == me);
  }

  Future<void> _sell() async {
    final servers = CommunityStore.instance.communities;
    if (servers.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Join or create a server first — listings are '
              'shared with your servers.')));
      return;
    }
    final created = await Navigator.of(context).push<bool>(MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => const SellScreen(),
    ));
    if (created == true && mounted) setState(() {});
  }

  void _open(FeedPost listing) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => _ListingSheet(
        listing: listing,
        serverName: _serverName(listing.communityId),
        mine: _mine(listing),
        onChanged: () {
          if (mounted) setState(() {});
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Marketplace')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _sell,
        icon: const Icon(Icons.sell_outlined),
        label: const Text('Sell'),
      ),
      body: ListenableBuilder(
        listenable: FeedStore.instance,
        builder: (context, _) {
          var listings = FeedStore.instance.listings();
          if (_category.isNotEmpty) {
            listings = [
              for (final l in listings)
                if (l.listingCategory == _category) l
            ];
          }
          final q = _query.trim().toLowerCase();
          if (q.isNotEmpty) {
            listings = [
              for (final l in listings)
                if (l.text.toLowerCase().contains(q)) l
            ];
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                child: TextField(
                  controller: _search,
                  onChanged: (v) => setState(() => _query = v),
                  decoration: InputDecoration(
                    hintText: 'Search Marketplace',
                    prefixIcon: const Icon(Icons.search),
                    isDense: true,
                    suffixIcon: _query.isEmpty
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.close, size: 18),
                            tooltip: 'Clear search',
                            onPressed: () {
                              _search.clear();
                              setState(() => _query = '');
                            },
                          ),
                  ),
                ),
              ),
              SizedBox(
                height: 46,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                  children: [
                    for (final c in kMarketplaceCategories)
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: ChoiceChip(
                          label: Text(c),
                          selected: _category == c,
                          visualDensity: VisualDensity.compact,
                          onSelected: (_) => setState(
                              () => _category = _category == c ? '' : c),
                        ),
                      ),
                  ],
                ),
              ),
              Expanded(
                child: listings.isEmpty
                    ? _empty(context)
                    : GridView.builder(
                        padding: const EdgeInsets.fromLTRB(12, 4, 12, 96),
                        gridDelegate:
                            const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 2,
                          mainAxisSpacing: 10,
                          crossAxisSpacing: 10,
                          childAspectRatio: 0.72,
                        ),
                        itemCount: listings.length,
                        itemBuilder: (context, i) => _ListingCard(
                          listing: listings[i],
                          serverName: _serverName(listings[i].communityId),
                          onTap: () => _open(listings[i]),
                        ),
                      ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _empty(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 40),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.storefront_outlined,
                  size: 52, color: Colors.grey.shade400),
              const SizedBox(height: 14),
              const Text('Nothing for sale yet',
                  style:
                      TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              Text(
                _query.isNotEmpty || _category.isNotEmpty
                    ? 'Nothing matches that search. Clear the filters to see '
                        'everything.'
                    : 'Listings from members of your servers show up here. '
                        'Be the first — tap Sell.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey.shade600, fontSize: 14),
              ),
            ],
          ),
        ),
      );
}

/// One tile in the browse grid: photo (or a placeholder), price, title.
class _ListingCard extends StatelessWidget {
  final FeedPost listing;
  final String serverName;
  final VoidCallback onTap;
  const _ListingCard(
      {required this.listing, required this.serverName, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final title = listing.text.split('\n').first;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: listing.gifUrl != null
                      ? ChatPhoto(
                          url: listing.gifUrl!,
                          fit: BoxFit.cover,
                          errorBuilder: (_) => _placeholder(context),
                        )
                      : _placeholder(context),
                ),
                if (listing.listingSold)
                  Positioned(
                    left: 8,
                    top: 8,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.72),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: const Text('SOLD',
                          style: TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.5)),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Text(formatListingPrice(listing.priceCents ?? 0),
              style:
                  const TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
          Text(title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13.5)),
          if (serverName.isNotEmpty)
            Text(serverName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style:
                    TextStyle(fontSize: 11.5, color: Colors.grey.shade600)),
        ],
      ),
    );
  }

  Widget _placeholder(BuildContext context) => Container(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: Icon(Icons.image_outlined,
            size: 36, color: Colors.grey.shade500),
      );
}

/// The listing opened full: photo, price, description, and what to do next —
/// message the seller, or for your own, mark sold / remove.
class _ListingSheet extends StatelessWidget {
  final FeedPost listing;
  final String serverName;
  final bool mine;
  final VoidCallback onChanged;
  const _ListingSheet({
    required this.listing,
    required this.serverName,
    required this.mine,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final lines = listing.text.split('\n');
    final title = lines.first;
    final description = lines.skip(1).join('\n').trim();
    final base = TextStyle(
        fontSize: 14.5,
        height: 1.4,
        color: Theme.of(context).colorScheme.onSurface);
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (listing.gifUrl != null)
              ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: ChatPhoto(
                  url: listing.gifUrl!,
                  fit: BoxFit.cover,
                  errorBuilder: (_) => const SizedBox.shrink(),
                ),
              ),
            const SizedBox(height: 12),
            Text(title,
                style: const TextStyle(
                    fontSize: 19, fontWeight: FontWeight.w800)),
            const SizedBox(height: 2),
            Row(
              children: [
                Text(formatListingPrice(listing.priceCents ?? 0),
                    style: const TextStyle(
                        fontSize: 17, fontWeight: FontWeight.w700)),
                if (listing.listingSold) ...[
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 7, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.grey.shade700,
                      borderRadius: BorderRadius.circular(5),
                    ),
                    child: const Text('SOLD',
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 10.5,
                            fontWeight: FontWeight.w800)),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 4),
            Text(
              [
                if (listing.listingCategory.isNotEmpty) listing.listingCategory,
                if (serverName.isNotEmpty) serverName,
                feedAge(listing.time),
              ].join(' · '),
              style: TextStyle(fontSize: 12.5, color: Colors.grey.shade600),
            ),
            if (description.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text.rich(TextSpan(
                  children: feedSpans(
                      description,
                      base,
                      base.copyWith(
                          fontWeight: FontWeight.w600,
                          color: Theme.of(context).colorScheme.primary)))),
            ],
            const SizedBox(height: 18),
            if (!mine)
              FilledButton.icon(
                onPressed: () {
                  Navigator.of(context).pop();
                  showPersonSheet(context,
                      username: listing.authorUsername,
                      name: listing.authorName);
                },
                icon: const Icon(Icons.chat_bubble_outline, size: 18),
                label: Text('Message ${listing.authorName}'),
                style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(48)),
              )
            else ...[
              FilledButton.icon(
                onPressed: () {
                  FeedStore.instance
                      .setListingSold(listing.id, !listing.listingSold);
                  onChanged();
                  Navigator.of(context).pop();
                },
                icon: Icon(
                    listing.listingSold
                        ? Icons.undo
                        : Icons.check_circle_outline,
                    size: 18),
                label: Text(listing.listingSold
                    ? 'Mark as available'
                    : 'Mark as sold'),
                style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(48)),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: () {
                  FeedStore.instance.deletePost(listing.id);
                  onChanged();
                  Navigator.of(context).pop();
                },
                icon: const Icon(Icons.delete_outline, size: 18),
                label: const Text('Remove listing'),
                style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.red.shade400,
                    minimumSize: const Size.fromHeight(46)),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Creating a listing: photo, title, price, category, description, and which
/// server sees it.
class SellScreen extends StatefulWidget {
  const SellScreen({super.key});

  @override
  State<SellScreen> createState() => _SellScreenState();
}

class _SellScreenState extends State<SellScreen> {
  final TextEditingController _title = TextEditingController();
  final TextEditingController _price = TextEditingController();
  final TextEditingController _description = TextEditingController();
  String _category = kMarketplaceCategories.first;
  String? _photo;
  late String _communityId = CommunityStore.instance.communities.isEmpty
      ? ''
      : CommunityStore.instance.communities.first.id;
  String? _error;

  @override
  void dispose() {
    _title.dispose();
    _price.dispose();
    _description.dispose();
    super.dispose();
  }

  Future<void> _pickPhoto() async {
    try {
      final uri = await PhotoPrep.pickPhoto();
      if (uri != null && mounted) setState(() => _photo = uri);
    } on FileRejected catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.reason)));
      }
    }
  }

  void _post() {
    final title = _title.text.trim();
    if (title.isEmpty) {
      setState(() => _error = 'Give it a title.');
      return;
    }
    final cents = parseListingPrice(_price.text);
    if (cents == null) {
      setState(() => _error = 'That price doesn\'t look like a number.');
      return;
    }
    if (_communityId.isEmpty) {
      setState(() => _error = 'Pick a server to list it in.');
      return;
    }
    FeedStore.instance.addListing(
      _communityId,
      title: title,
      priceCents: cents,
      category: _category,
      description: _description.text,
      photoUrl: _photo,
    );
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final servers = CommunityStore.instance.communities;
    return Scaffold(
      appBar: AppBar(
        title: const Text('New listing'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: FilledButton(
              onPressed: _post,
              style: FilledButton.styleFrom(shape: const StadiumBorder()),
              child: const Text('Post'),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          InkWell(
            onTap: _pickPhoto,
            borderRadius: BorderRadius.circular(14),
            child: Container(
              height: 180,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(14),
              ),
              clipBehavior: Clip.antiAlias,
              child: _photo != null
                  ? ChatPhoto(
                      url: _photo!,
                      fit: BoxFit.cover,
                      errorBuilder: (_) => const SizedBox.shrink())
                  : Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.add_a_photo_outlined,
                            size: 34, color: Colors.grey.shade500),
                        const SizedBox(height: 6),
                        Text('Add a photo',
                            style: TextStyle(color: Colors.grey.shade600)),
                      ],
                    ),
            ),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _title,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(hintText: 'What are you selling?'),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _price,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
                hintText: 'Price', prefixText: '\$ ', helperText: 'Leave empty for free'),
          ),
          const SizedBox(height: 10),
          DropdownButtonFormField<String>(
            initialValue: _category,
            items: [
              for (final c in kMarketplaceCategories)
                DropdownMenuItem(value: c, child: Text(c)),
            ],
            onChanged: (v) => setState(() => _category = v ?? _category),
            decoration: const InputDecoration(labelText: 'Category'),
          ),
          const SizedBox(height: 10),
          if (servers.length > 1)
            DropdownButtonFormField<String>(
              initialValue: _communityId,
              items: [
                for (final s in servers)
                  DropdownMenuItem(value: s.id, child: Text(s.name)),
              ],
              onChanged: (v) => setState(() => _communityId = v ?? _communityId),
              decoration: const InputDecoration(
                  labelText: 'Server',
                  helperText: 'Members of this server see the listing'),
            ),
          const SizedBox(height: 10),
          TextField(
            controller: _description,
            minLines: 3,
            maxLines: 8,
            maxLength: 600,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
                hintText: 'Describe it — condition, size, pickup…'),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(_error!,
                  style:
                      TextStyle(color: Theme.of(context).colorScheme.error)),
            ),
        ],
      ),
    );
  }
}
