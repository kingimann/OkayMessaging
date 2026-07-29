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
  bool _mineOnly = false;
  bool _searching = false;
  final TextEditingController _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _closeSearch() {
    _search.clear();
    setState(() {
      _searching = false;
      _query = '';
    });
  }

  /// Category and your-listings filters, as a sheet off the filter button.
  /// Out of the body: a permanent search bar and a chip strip spent two rows
  /// of every visit on controls most visits never touch.
  Future<void> _openFilters() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheet) => SafeArea(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SwitchListTile.adaptive(
                  secondary: const Icon(Icons.sell_outlined),
                  title: const Text('Your listings'),
                  value: _mineOnly,
                  onChanged: (v) {
                    setState(() => _mineOnly = v);
                    setSheet(() {});
                  },
                ),
                const Divider(height: 1),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Text('CATEGORY',
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.6,
                          color: Colors.grey.shade600)),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final c in kMarketplaceCategories)
                        ChoiceChip(
                          label: Text(c),
                          selected: _category == c,
                          onSelected: (_) {
                            setState(() =>
                                _category = _category == c ? '' : c);
                            Navigator.of(sheetContext).pop();
                          },
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
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
    // A full screen, not a sheet: a listing is mostly photo, and a sheet
    // gives a photo whatever height is left under the drag handle.
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ListingScreen(listingId: listing.id),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final hasFilter = _category.isNotEmpty || _mineOnly;
    return Scaffold(
      // Search and filters live in the top-right corner; the body is the
      // goods.
      appBar: AppBar(
        title: _searching
            ? TextField(
                controller: _search,
                autofocus: true,
                onChanged: (v) => setState(() => _query = v),
                decoration: const InputDecoration.collapsed(
                    hintText: 'Search Marketplace'),
              )
            : const Text('Marketplace'),
        actions: [
          if (_searching)
            IconButton(
              icon: const Icon(Icons.close),
              tooltip: 'Close search',
              onPressed: _closeSearch,
            )
          else
            IconButton(
              icon: const Icon(Icons.search),
              tooltip: 'Search Marketplace',
              onPressed: () => setState(() => _searching = true),
            ),
          IconButton(
            icon: Badge(
              isLabelVisible: hasFilter,
              smallSize: 8,
              child: const Icon(Icons.tune),
            ),
            tooltip: 'Filter',
            onPressed: _openFilters,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _sell,
        icon: const Icon(Icons.sell_outlined),
        label: const Text('Sell'),
      ),
      body: ListenableBuilder(
        listenable: FeedStore.instance,
        builder: (context, _) {
          var listings = FeedStore.instance.listings();
          if (_mineOnly) {
            listings = [
              for (final l in listings)
                if (_mine(l)) l
            ];
          }
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
          // What's still for sale first; sold sinks to the end rather than
          // being hidden — a buyer mid-conversation can still find it.
          listings = [
            for (final l in listings)
              if (!l.listingSold) l,
            for (final l in listings)
              if (l.listingSold) l,
          ];
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Active filters only. When nothing is filtered, nothing is
              // here — the grid starts at the top.
              if (hasFilter)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                  child: Wrap(
                    spacing: 6,
                    children: [
                      if (_mineOnly)
                        InputChip(
                          avatar: const Icon(Icons.sell_outlined, size: 15),
                          label: const Text('Your listings'),
                          visualDensity: VisualDensity.compact,
                          onDeleted: () =>
                              setState(() => _mineOnly = false),
                        ),
                      if (_category.isNotEmpty)
                        InputChip(
                          label: Text(_category),
                          visualDensity: VisualDensity.compact,
                          onDeleted: () =>
                              setState(() => _category = ''),
                        ),
                    ],
                  ),
                ),
              Expanded(
                child: listings.isEmpty
                    ? _empty(context)
                    : GridView.builder(
                        padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
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
                  // A sold photo fades back so what's still for sale carries
                  // the colour in the grid.
                  child: Opacity(
                    opacity: listing.listingSold ? 0.55 : 1,
                    child: listing.gifUrl != null
                        ? ChatPhoto(
                            url: listing.gifUrl!,
                            fit: BoxFit.cover,
                            errorBuilder: (_) => _placeholder(context),
                          )
                        : _placeholder(context),
                  ),
                ),
                if (listing.listingSold)
                  const Positioned(left: 8, top: 8, child: _SoldBadge()),
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

/// One listing, full screen — mostly photo, like the thing it is.
///
/// Looked up by id on every rebuild so a sold flag arriving over the relay
/// updates the open screen, and a listing deleted under the viewer says so
/// instead of showing a ghost.
class ListingScreen extends StatelessWidget {
  final String listingId;
  const ListingScreen({super.key, required this.listingId});

  bool _mine(FeedPost p) {
    final me = AppState.profile.value.username;
    return p.authorUsername == 'you' ||
        (me.isNotEmpty && p.authorUsername == me);
  }

  String _serverName(String id) {
    for (final c in CommunityStore.instance.communities) {
      if (c.id == id) return c.name;
    }
    return '';
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: FeedStore.instance,
      builder: (context, _) {
        final listing = FeedStore.instance
            .listings()
            .where((l) => l.id == listingId)
            .firstOrNull;
        if (listing == null) {
          return Scaffold(
            appBar: AppBar(),
            body: Center(
              child: Text('This listing was removed.',
                  style: TextStyle(color: Colors.grey.shade600)),
            ),
          );
        }
        final lines = listing.text.split('\n');
        final title = lines.first;
        final description = lines.skip(1).join('\n').trim();
        final mine = _mine(listing);
        final serverName = _serverName(listing.communityId);
        final scheme = Theme.of(context).colorScheme;
        final base =
            TextStyle(fontSize: 15, height: 1.45, color: scheme.onSurface);
        return Scaffold(
          appBar: AppBar(
            title: Text(title, maxLines: 1),
            actions: [
              if (mine)
                IconButton(
                  icon: const Icon(Icons.edit_outlined),
                  tooltip: 'Edit listing',
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      fullscreenDialog: true,
                      builder: (_) => SellScreen(existing: listing),
                    ),
                  ),
                ),
            ],
          ),
          // The next step lives in a bar pinned above the keyboard-safe area,
          // reachable without scrolling past the description.
          bottomNavigationBar: SafeArea(
            minimum: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: mine
                ? Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: () => FeedStore.instance
                              .setListingSold(listing.id, !listing.listingSold),
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
                      ),
                      const SizedBox(width: 10),
                      OutlinedButton(
                        onPressed: () {
                          FeedStore.instance.deletePost(listing.id);
                          Navigator.of(context).pop();
                        },
                        style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.red.shade400,
                            minimumSize: const Size(52, 48),
                            padding: EdgeInsets.zero),
                        child: const Icon(Icons.delete_outline, size: 20),
                      ),
                    ],
                  )
                : FilledButton.icon(
                    onPressed: () => showPersonSheet(context,
                        username: listing.authorUsername,
                        name: listing.authorName),
                    icon: const Icon(Icons.chat_bubble_outline, size: 18),
                    label: Text('Message ${listing.authorName}'),
                    style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(48)),
                  ),
          ),
          body: ListView(
            padding: EdgeInsets.zero,
            children: [
              if (listing.gifUrl != null)
                Stack(
                  children: [
                    // Tapping the photo fills the screen with it — the photo
                    // is the listing, and cover-fit crops it here.
                    GestureDetector(
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => _ListingPhotoScreen(
                              url: listing.gifUrl!, title: title),
                        ),
                      ),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 380),
                        child: SizedBox(
                          width: double.infinity,
                          child: ChatPhoto(
                            url: listing.gifUrl!,
                            fit: BoxFit.cover,
                            errorBuilder: (_) => const SizedBox.shrink(),
                          ),
                        ),
                      ),
                    ),
                    if (listing.listingSold)
                      const Positioned(
                        left: 14,
                        top: 14,
                        child: _SoldBadge(large: true),
                      ),
                  ],
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: const TextStyle(
                            fontSize: 21, fontWeight: FontWeight.w800)),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Text(formatListingPrice(listing.priceCents ?? 0),
                            style: const TextStyle(
                                fontSize: 18, fontWeight: FontWeight.w700)),
                        if (listing.listingSold &&
                            listing.gifUrl == null) ...[
                          const SizedBox(width: 8),
                          const _SoldBadge(),
                        ],
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      [
                        if (listing.listingCategory.isNotEmpty)
                          listing.listingCategory,
                        if (serverName.isNotEmpty) serverName,
                        feedAge(listing.time),
                      ].join(' · '),
                      style: TextStyle(
                          fontSize: 13, color: Colors.grey.shade600),
                    ),
                  ],
                ),
              ),
              const Divider(height: 24, indent: 16, endIndent: 16),
              // The seller, as a row a buyer can act on.
              InkWell(
                onTap: mine
                    ? null
                    : () => showPersonSheet(context,
                        username: listing.authorUsername,
                        name: listing.authorName),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 4),
                  child: Row(
                    children: [
                      CircleAvatar(
                        radius: 18,
                        child: Text(listing.authorName.isEmpty
                            ? '?'
                            : listing.authorName[0].toUpperCase()),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(mine ? 'Your listing' : listing.authorName,
                                style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                    fontSize: 14.5)),
                            if (!mine &&
                                listing.authorUsername.isNotEmpty &&
                                listing.authorUsername != 'you')
                              Text('@${listing.authorUsername}',
                                  style: TextStyle(
                                      fontSize: 12.5,
                                      color: Colors.grey.shade600)),
                          ],
                        ),
                      ),
                      if (!mine)
                        Icon(Icons.chevron_right,
                            size: 20, color: Colors.grey.shade500),
                    ],
                  ),
                ),
              ),
              if (description.isNotEmpty) ...[
                const Divider(height: 24, indent: 16, endIndent: 16),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Details',
                          style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: Colors.grey.shade600)),
                      const SizedBox(height: 6),
                      Text.rich(TextSpan(
                          children: feedSpans(
                              description,
                              base,
                              base.copyWith(
                                  fontWeight: FontWeight.w600,
                                  color: scheme.primary)))),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 24),
            ],
          ),
        );
      },
    );
  }
}

/// A listing's photo, uncropped and pinch-zoomable on its own screen.
class _ListingPhotoScreen extends StatelessWidget {
  final String url;
  final String title;
  const _ListingPhotoScreen({required this.url, required this.title});

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
          title: Text(title, maxLines: 1),
        ),
        body: Center(
          child: InteractiveViewer(
            maxScale: 5,
            child: ChatPhoto(
              url: url,
              fit: BoxFit.contain,
              errorBuilder: (_) => const Icon(Icons.broken_image_outlined,
                  color: Colors.white38, size: 48),
            ),
          ),
        ),
      );
}

/// The black SOLD tag, shared by the grid tiles and the listing screen.
class _SoldBadge extends StatelessWidget {
  final bool large;
  const _SoldBadge({this.large = false});

  @override
  Widget build(BuildContext context) => Container(
        padding: EdgeInsets.symmetric(
            horizontal: large ? 10 : 8, vertical: large ? 4 : 3),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.72),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text('SOLD',
            style: TextStyle(
                color: Colors.white,
                fontSize: large ? 12.5 : 11,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.5)),
      );
}

/// Creating a listing: photo, title, price, category, description, and which
/// server sees it.
class SellScreen extends StatefulWidget {
  /// When set, the form edits this listing instead of creating one.
  final FeedPost? existing;

  const SellScreen({super.key, this.existing});

  @override
  State<SellScreen> createState() => _SellScreenState();
}

class _SellScreenState extends State<SellScreen> {
  late final TextEditingController _title = TextEditingController(
      text: widget.existing?.text.split('\n').first ?? '');
  late final TextEditingController _price = TextEditingController(
      text: switch (widget.existing?.priceCents) {
    null || 0 => '',
    final cents => formatListingPrice(cents).replaceFirst('\$', ''),
  });
  late final TextEditingController _description = TextEditingController(
      text: widget.existing == null
          ? ''
          : widget.existing!.text.split('\n').skip(1).join('\n'));
  late String _category = widget.existing?.listingCategory.isNotEmpty == true
      ? widget.existing!.listingCategory
      : kMarketplaceCategories.first;
  late String? _photo = widget.existing?.gifUrl;
  late String _communityId = widget.existing?.communityId ??
      (CommunityStore.instance.communities.isEmpty
          ? ''
          : CommunityStore.instance.communities.first.id);
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
    // The server's word filter guards its marketplace like its feed and its
    // channels — a rule that applies to posts but not price tags isn't one.
    final hit = CommunityStore.instance
        .filterHit(_communityId, '$title\n${_description.text}');
    if (hit != null) {
      setState(() =>
          _error = '"$hit" is blocked by this server\'s word filter.');
      return;
    }
    final existing = widget.existing;
    if (existing != null) {
      FeedStore.instance.updateListing(
        existing.id,
        title: title,
        priceCents: cents,
        category: _category,
        description: _description.text,
        photoUrl: _photo,
      );
    } else {
      FeedStore.instance.addListing(
        _communityId,
        title: title,
        priceCents: cents,
        category: _category,
        description: _description.text,
        photoUrl: _photo,
      );
    }
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final servers = CommunityStore.instance.communities;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.existing == null ? 'New listing' : 'Edit listing'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            // Live-enabled once there's a title — a Post that can only fail
            // reads better disabled than erroring after the tap.
            child: ValueListenableBuilder<TextEditingValue>(
              valueListenable: _title,
              builder: (context, value, _) => FilledButton(
                onPressed: value.text.trim().isEmpty ? null : _post,
                style: FilledButton.styleFrom(shape: const StadiumBorder()),
                child: Text(widget.existing == null ? 'Post' : 'Save'),
              ),
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
          const SizedBox(height: 16),
          TextField(
            controller: _title,
            textCapitalization: TextCapitalization.sentences,
            // The title carries the listing, so it reads a size up.
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
            decoration: const InputDecoration(hintText: 'What are you selling?'),
          ),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Price and category share a row: both are short, and the form
              // shouldn't scroll for two half-width answers. "Free" belongs
              // in the price field's own hint — as helperText it collided
              // with the next field's label.
              Expanded(
                child: TextField(
                  controller: _price,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(
                      hintText: 'Free', labelText: 'Price', prefixText: '\$ '),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: DropdownButtonFormField<String>(
                  // Sized to its column, not to its widest item — "Home &
                  // Garden" at intrinsic width overflowed the half-width slot.
                  isExpanded: true,
                  initialValue: _category,
                  items: [
                    for (final c in kMarketplaceCategories)
                      DropdownMenuItem(value: c, child: Text(c)),
                  ],
                  onChanged: (v) => setState(() => _category = v ?? _category),
                  decoration: const InputDecoration(labelText: 'Category'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (servers.length > 1 && widget.existing == null) ...[
            DropdownButtonFormField<String>(
              isExpanded: true,
              initialValue: _communityId,
              items: [
                for (final s in servers)
                  DropdownMenuItem(value: s.id, child: Text(s.name)),
              ],
              onChanged: (v) => setState(() => _communityId = v ?? _communityId),
              decoration: const InputDecoration(labelText: 'Server'),
            ),
            const SizedBox(height: 12),
          ],
          TextField(
            controller: _description,
            minLines: 3,
            maxLines: 8,
            maxLength: 600,
            textCapitalization: TextCapitalization.sentences,
            buildCounter: (context,
                    {required currentLength, required isFocused, maxLength}) =>
                currentLength > 500
                    ? Text('$currentLength/$maxLength',
                        style: TextStyle(
                            fontSize: 11,
                            color:
                                Theme.of(context).colorScheme.onSurfaceVariant))
                    : null,
            decoration: const InputDecoration(
                hintText: 'Describe it — condition, size, pickup…'),
          ),
          const SizedBox(height: 10),
          // Who will see this. Stated on the form, not discovered after.
          Row(
            children: [
              Icon(Icons.groups_outlined,
                  size: 16, color: Colors.grey.shade600),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Shared with members of '
                  '${servers.firstWhere((c) => c.id == _communityId, orElse: () => servers.first).name}.',
                  style:
                      TextStyle(fontSize: 12.5, color: Colors.grey.shade600),
                ),
              ),
            ],
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(_error!,
                  style:
                      TextStyle(color: Theme.of(context).colorScheme.error)),
            ),
        ],
      ),
    );
  }
}
