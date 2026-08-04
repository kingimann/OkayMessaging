import 'package:file_picker/file_picker.dart';
import '../state/session.dart';
import '../theme/app_theme.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../models/chat.dart';
import '../models/community.dart';
import '../models/user.dart';
import '../state/account_service.dart';
import '../state/chat_store.dart';
import '../ads/ad_service.dart';
import '../relay/relay_service.dart';
import '../state/parental_controls.dart';
import '../widgets/parental_gate.dart';
import '../widgets/pull_to_refresh.dart';
import '../state/community_store.dart';
import '../state/feed_store.dart';
import '../state/market_media.dart';
import '../util/geocoding.dart';
import 'explore_map_screen.dart';
import '../state/storage_store.dart';
import '../util/file_moderation.dart';
import '../util/photo_prep.dart';
import '../widgets/app_dialogs.dart';
import '../widgets/chat_photo.dart';
import '../widgets/listing_video.dart';
import '../widgets/sanction_notice.dart';
import '../widgets/verified_badge.dart';
import 'chat_screen.dart';
import 'feed_screen.dart' show showPersonSheet, feedSpans;
import 'forward_screen.dart';
import '../widgets/verified_gate.dart';

/// The most photos one listing may carry. Each photo is its own relay
/// message near the payload cap, and each is a mailbox row for every offline
/// member — four is generous without turning one listing into a burst.
const int kMaxListingPhotos = 4;

/// The categories a listing can file under. A fixed list, because filters
/// only work when sellers and buyers pick from the same words.
/// Every category name that has EVER shipped must stay in this list —
/// categories live as strings on listings already out on the relay, and
/// renaming one here would orphan every existing listing filed under it.
/// APPEND ONLY, and never reorder above an existing entry — the doc above is
/// the rule, and the second half of it is that `first` is the form's default.
const List<String> kMarketplaceCategories = [
  'Electronics',
  'Phones & Tablets',
  'Appliances',
  'Furniture',
  'Home & Garden',
  'Tools & Home Improvement',
  'Clothing',
  'Jewelry & Accessories',
  'Beauty & Health',
  'Baby & Kids',
  'Vehicles',
  'Sports',
  'Games & Toys',
  'Musical Instruments',
  'Pet Supplies',
  'Books',
  'Tickets',
  'Free stuff',
  'Other',
  // Added later. Each one is a thing people were previously filing under
  // 'Other' or, worse, under a category it did not belong to — which is how
  // a filter stops being worth using.
  'Computers',
  'TV & Audio',
  'Cameras & Photo',
  'Video Games & Consoles',
  'Shoes',
  'Bags & Luggage',
  'Watches',
  'Bikes',
  'Auto Parts',
  'Motorcycles',
  'Boats & Watercraft',
  'Camping & Outdoors',
  'Art & Collectibles',
  'Antiques',
  'Crafts & Hobbies',
  'Movies & Music',
  'Office & Business',
  'Farm & Garden Equipment',
  'Building Materials',
  'Food & Drink',
  'Property & Rentals',
  'Services',
  'Wanted',
];

/// How the picker groups the list. Display only, so unlike the list above
/// this can be reshuffled freely — nothing is stored under a heading.
///
/// A flat menu of forty entries is a wall to scroll, which is the reason a
/// grouped, searchable sheet replaced the dropdown at the same time as the
/// categories were added. Anything not named here falls under "More".
const Map<String, List<String>> kMarketplaceCategoryGroups = {
  'Tech': [
    'Electronics',
    'Phones & Tablets',
    'Computers',
    'TV & Audio',
    'Cameras & Photo',
    'Video Games & Consoles',
  ],
  'Home': [
    'Furniture',
    'Appliances',
    'Home & Garden',
    'Tools & Home Improvement',
    'Building Materials',
    'Farm & Garden Equipment',
  ],
  'Wearables': [
    'Clothing',
    'Shoes',
    'Jewelry & Accessories',
    'Watches',
    'Bags & Luggage',
    'Beauty & Health',
  ],
  'Getting around': [
    'Vehicles',
    'Auto Parts',
    'Motorcycles',
    'Bikes',
    'Boats & Watercraft',
  ],
  'Leisure': [
    'Sports',
    'Camping & Outdoors',
    'Games & Toys',
    'Musical Instruments',
    'Books',
    'Movies & Music',
    'Art & Collectibles',
    'Antiques',
    'Crafts & Hobbies',
    'Tickets',
  ],
  'Everything else': [
    'Baby & Kids',
    'Pet Supplies',
    'Food & Drink',
    'Office & Business',
    'Property & Rentals',
    'Services',
    'Wanted',
    'Free stuff',
    'Other',
  ],
};

/// Every category, in the order the grouped picker shows them, with anything
/// missing from a group appended so a new category can never be unreachable
/// just because somebody forgot to file it.
List<(String, List<String>)> marketplaceCategorySections() {
  final grouped = <String>{};
  final out = <(String, List<String>)>[];
  for (final entry in kMarketplaceCategoryGroups.entries) {
    final present =
        entry.value.where(kMarketplaceCategories.contains).toList();
    if (present.isEmpty) continue;
    grouped.addAll(present);
    out.add((entry.key, present));
  }
  final ungrouped =
      kMarketplaceCategories.where((c) => !grouped.contains(c)).toList();
  if (ungrouped.isNotEmpty) out.add(('More', ungrouped));
  return out;
}

/// How a listing changes hands. The stored value is the first of each pair;
/// the label is display only, so it can be reworded without orphaning a
/// listing already out on the relay — the same rule the categories follow,
/// solved a better way because these were designed after that lesson.
const List<(String, String)> kListingDeliveryOptions = [
  ('pickup', 'Pickup'),
  ('delivery', 'Local delivery'),
  ('shipping', 'Can ship'),
];

/// The label for a stored delivery value, or '' when it is unset or unknown.
/// Unknown rather than crashing: a newer client may send a value this build
/// has never heard of, and a listing that renders is worth more than one that
/// throws.
String listingDeliveryLabel(String value) {
  for (final (v, label) in kListingDeliveryOptions) {
    if (v == value) return label;
  }
  return '';
}

/// How used an item is. Optional on the form — a required condition gets
/// answered with whatever dismisses the field fastest.
const List<String> kListingConditions = [
  'New',
  'Like new',
  'Good',
  'Fair',
  'For parts',
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

/// How the browse grid orders what it shows.
enum ListingSort {
  newest('Newest first'),
  priceLow('Price: low to high'),
  priceHigh('Price: high to low');

  const ListingSort(this.label);
  final String label;
}

/// [listings] in [sort] order, with sold items sunk to the end whatever the
/// order — visible, but never ahead of something that can still be bought.
/// Pure, so the tie-breaking is testable: equal prices keep their newest-
/// first order instead of shuffling on every rebuild.
List<FeedPost> sortListings(List<FeedPost> listings, ListingSort sort) {
  final list = List<FeedPost>.of(listings)
    ..sort((a, b) => b.time.compareTo(a.time));
  if (sort != ListingSort.newest) {
    // Stable merge sort via mergeSort semantics: List.sort is not stable, so
    // sort by price on an already newest-first list using a comparator that
    // never returns 0 ties away — compare price, then time.
    list.sort((a, b) {
      final pa = a.priceCents ?? 0, pb = b.priceCents ?? 0;
      final byPrice =
          sort == ListingSort.priceLow ? pa.compareTo(pb) : pb.compareTo(pa);
      return byPrice != 0 ? byPrice : b.time.compareTo(a.time);
    });
  }
  return [
    for (final l in list)
      if (!l.listingSold) l,
    for (final l in list)
      if (l.listingSold) l,
  ];
}

/// Test hook: replaces the directory lookup that turns a seller's username
/// into a messageable contact.
@visibleForTesting
Future<AppUser?> Function(String username)? debugResolveSellerOverride;

/// Opens (or starts) a chat with [listing]'s seller, seeding the composer
/// with the question every marketplace conversation starts with — unless a
/// draft is already there, because overwriting someone's half-typed words
/// would be worse than no head start.
///
/// Resolution order: an existing chat whose contact carries the username,
/// then the server directory. When neither knows the seller (offline, or a
/// seller who never registered a username), the person sheet opens instead —
/// a follow is still possible there, and pretending a chat exists isn't.
Future<void> messageSeller(BuildContext context, FeedPost listing) =>
    openSellerChat(context,
        username: listing.authorUsername,
        name: listing.authorName,
        about: listing);

/// Whether [l] matches a typed search. Pure so a test can pin what counts:
/// the text (title + description), the brand, and the pickup area — a
/// buyer who types "trek" or "downtown" means the field, not the prose.
bool listingMatchesQuery(FeedPost l, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return true;
  return l.text.toLowerCase().contains(q) ||
      l.listingBrand.toLowerCase().contains(q) ||
      l.listingPlace.toLowerCase().contains(q);
}

/// Whether [l]'s price sits inside a chosen range. Free counts as \$0, so
/// "under \$25" includes it. Pure.
bool listingInPriceRange(FeedPost l, {int? minCents, int? maxCents}) {
  final p = l.priceCents ?? 0;
  if (minCents != null && p < minCents) return false;
  if (maxCents != null && p > maxCents) return false;
  return true;
}

/// Up to [limit] other listings from the same category, newest first —
/// never the listing itself, never something sold. Empty when the category
/// has nothing else: an honest absence beats padding with the unrelated.
List<FeedPost> moreLikeThis(List<FeedPost> all, FeedPost listing,
    {int limit = 6}) {
  final same = [
    for (final l in all)
      if (l.id != listing.id &&
          !l.listingSold &&
          l.listingCategory == listing.listingCategory)
        l
  ]..sort((a, b) => b.time.compareTo(a.time));
  return same.take(limit).toList();
}

/// What a forwarded listing says in the chat it lands in. Pure.
String listingShareText(FeedPost l) {
  final lines = l.text.split('\n');
  final title = lines.first;
  final description = lines.skip(1).join('\n').trim();
  final facts = [
    if (l.listingBrand.isNotEmpty) l.listingBrand,
    if (l.listingCondition.isNotEmpty) l.listingCondition,
    if (l.listingPlace.isNotEmpty) l.listingPlace,
  ].join(' · ');
  return [
    '$title — ${formatListingPrice(l.priceCents ?? 0)}',
    if (facts.isNotEmpty) facts,
    if (description.isNotEmpty) description,
    'Seen on the marketplace — ask me about it!',
  ].join('\n');
}

/// The sentence an offer opens the chat with. Pure for the same reason.
String offerOpener(FeedPost listing, int offerCents) {
  final title = listing.text.split('\n').first;
  final asking = listing.priceCents ?? 0;
  return 'Would you take ${formatListingPrice(offerCents)} for "$title"? '
      '(asking ${formatListingPrice(asking)})';
}

/// Asks for an amount, then opens the seller chat with the offer typed and
/// ready to send — never sent unread. Only offered on listings whose
/// seller said they are open to offers.
Future<void> makeOffer(BuildContext context, FeedPost listing) async {
  final controller = TextEditingController();
  final asking = listing.priceCents ?? 0;
  final cents = await showDialog<int>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Make an offer'),
      content: TextField(
        controller: controller,
        autofocus: true,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(
          prefixText: '\$ ',
          helperText: asking > 0
              ? 'Asking ${formatListingPrice(asking)}'
              : 'Listed as free',
        ),
        onSubmitted: (_) => Navigator.pop(
            dialogContext, parseListingPrice(controller.text)),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel')),
        FilledButton(
            onPressed: () => Navigator.pop(
                dialogContext, parseListingPrice(controller.text)),
            child: const Text('Offer')),
      ],
    ),
  );
  if (cents == null || cents <= 0 || !context.mounted) return;
  await openSellerChat(context,
      username: listing.authorUsername,
      name: listing.authorName,
      opener: offerOpener(listing, cents));
}

/// Opens (or starts) a chat with a seller. With [about], the composer is
/// seeded with the question every marketplace conversation starts with.
Future<void> openSellerChat(
  BuildContext context, {
  required String username,
  required String name,
  FeedPost? about,
  String? opener,
}) async {
  opener ??= about == null
      ? ''
      : 'Is this still available? — "${about.text.split('\n').first}" '
          '(${formatListingPrice(about.priceCents ?? 0)})';

  AppUser? seller;
  for (final c in ChatStore.instance.chats) {
    if (!c.contact.isGroup &&
        c.contact.username.toLowerCase() == username.toLowerCase()) {
      seller = c.contact;
      break;
    }
  }
  if (seller == null) {
    final resolve = debugResolveSellerOverride;
    if (resolve != null) {
      seller = await resolve(username);
    } else {
      final matches = await AccountService.instance.searchByUsername(username);
      for (final u in matches) {
        if (u.username.toLowerCase() == username.toLowerCase()) {
          seller = u;
          break;
        }
      }
    }
  }
  if (!context.mounted) return;
  if (seller == null) {
    showPersonSheet(context, username: username, name: name);
    return;
  }

  final store = ChatStore.instance;
  final existing = store.chatWithContact(seller.id);
  final Chat chat;
  if (existing != null) {
    if (existing.isArchived) store.setArchived(existing.id, false);
    chat = existing;
  } else {
    chat = Chat(id: 'chat_${seller.id}', contact: seller, messages: const []);
    store.upsert(chat);
  }
  if (opener.isNotEmpty && store.draftFor(chat.id).isEmpty) {
    store.setDraft(chat.id, opener);
  }
  await Navigator.of(context).push(
    MaterialPageRoute(builder: (_) => ChatScreen(chat: chat)),
  );
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
  bool _savedOnly = false;
  ListingSort _sort = ListingSort.newest;
  final TextEditingController _minPrice = TextEditingController();
  final TextEditingController _maxPrice = TextEditingController();

  /// A blank field is NO bound — parseListingPrice reads blank as 'free'
  /// (0), which as a ceiling would filter every priced listing out.
  int? _bound(TextEditingController c) {
    final t = c.text.trim();
    if (t.isEmpty) return null;
    final v = parseListingPrice(t);
    return (v == null || v <= 0) ? null : v;
  }

  int? get _minCents => _bound(_minPrice);
  int? get _maxCents => _bound(_maxPrice);
  bool _searching = false;
  final TextEditingController _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    _minPrice.dispose();
    _maxPrice.dispose();
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
                SwitchListTile.adaptive(
                  secondary: const Icon(Icons.bookmark_outline),
                  title: const Text('Saved'),
                  value: _savedOnly,
                  onChanged: (v) {
                    setState(() => _savedOnly = v);
                    setSheet(() {});
                  },
                ),
                const Divider(height: 1),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Text('PRICE',
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.6,
                          color: AppColors.subtle(context))),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _minPrice,
                          keyboardType: const TextInputType.numberWithOptions(
                              decimal: true),
                          decoration: const InputDecoration(
                              labelText: 'Min', prefixText: '\$ ', isDense: true),
                          onChanged: (_) {
                            setState(() {});
                            setSheet(() {});
                          },
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextField(
                          controller: _maxPrice,
                          keyboardType: const TextInputType.numberWithOptions(
                              decimal: true),
                          decoration: const InputDecoration(
                              labelText: 'Max', prefixText: '\$ ', isDense: true),
                          onChanged: (_) {
                            setState(() {});
                            setSheet(() {});
                          },
                        ),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Text('SORT',
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.6,
                          color: AppColors.subtle(context))),
                ),
                for (final sort in ListingSort.values)
                  RadioListTile<ListingSort>(
                    dense: true,
                    title: Text(sort.label),
                    value: sort,
                    // ignore: deprecated_member_use
                    groupValue: _sort,
                    // ignore: deprecated_member_use
                    onChanged: (v) {
                      setState(() => _sort = v ?? _sort);
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
                          color: AppColors.subtle(context))),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      // Only categories with something in them, plus
                      // whichever is currently selected so a filter can
                      // always be switched off from here. Forty-two empty
                      // chips is a wall, and every one of them is a door
                      // that opens on nothing — the counts below used to be
                      // the only hint, on a list a third this long.
                      for (final c in kMarketplaceCategories.where((c) =>
                          c == _category ||
                          FeedStore.instance
                              .listings()
                              .any((l) => l.listingCategory == c)))
                        Builder(builder: (context) {
                          // How much is behind each door, so nobody opens an
                          // empty one to find out.
                          final n = FeedStore.instance
                              .listings()
                              .where((l) => l.listingCategory == c)
                              .length;
                          return ChoiceChip(
                            label: Text(n > 0 ? '$c · $n' : c),
                            selected: _category == c,
                            onSelected: (_) {
                              setState(() =>
                                  _category = _category == c ? '' : c);
                              Navigator.of(sheetContext).pop();
                            },
                          );
                        }),
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
    // Defence in depth: the FAB is already withheld on the browse-only path,
    // but selling needs the wallet and the ID check, neither of which a
    // numberless account has.
    if (Session.instance.isNumberless) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Listing needs a phone number — selling runs on the '
              'wallet and the ID check. You can browse and message sellers.')));
      return;
    }
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
    // The parental gate wraps EVERY path in — including the browse-only
    // numberless one below, which skips the other gates on purpose but is
    // still the marketplace.
    return ParentalGate(
      restriction: ParentalRestriction.marketplace,
      title: 'Marketplace',
      child: Builder(builder: (context) {
        // A numberless account gets a BROWSE-ONLY marketplace: it can see
        // listings and message sellers (both ride the anon-key relay, like
        // chat), but not list its own — selling needs the wallet and the ID
        // check, and both need a number behind the account. Neither gate
        // wraps this path; the Sell action is withheld instead (see
        // _guarded).
        //
        // What it can browse is still whatever server feed reaches the
        // device — servers stay phone-gated — plus any listing shared into
        // a chat. The capability is open; how full the grid is follows from
        // that.
        if (Session.instance.isNumberless) {
          return _guarded(context, browseOnly: true);
        }
        // Gates wrap the SCREEN, not the button that opens it, so every way
        // in (deep link, a listing shared in a chat) is covered.
        return VerifiedGate(
          title: 'Marketplace',
          reason: 'Money and strangers meet here: somebody buying from you '
              'is trusting a name they have never met. Verifying your ID is '
              'what makes that name answerable.',
          // Ours to waive: nothing outside the app needs the verified
          // identity to list or browse. Whoever runs the marketplace is
          // already answerable for it.
          ownerMayPass: true,
          child: _guarded(context),
        );
      }),
    );
  }

  Widget _guarded(BuildContext context, {bool browseOnly = false}) {
    final hasFilter = _category.isNotEmpty ||
        _mineOnly ||
        _savedOnly ||
        _minCents != null ||
        _maxCents != null ||
        _sort != ListingSort.newest;
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
      // Withheld on the browse-only path: a numberless account cannot list,
      // so offering the button and then refusing the tap would be worse than
      // not offering it.
      floatingActionButton: browseOnly
          ? null
          : FloatingActionButton.extended(
              onPressed: _sell,
              icon: const Icon(Icons.sell_outlined),
              label: const Text('Sell'),
            ),
      // A non-personalized banner, on this surface because it is already
      // world-facing commerce. Zero height until an ad really loads, and
      // absent entirely in builds with no ad ids.
      bottomNavigationBar: const AdBannerSlot(),
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
          if (_savedOnly) {
            listings = [
              for (final l in listings)
                if (FeedStore.instance.isSaved(l.id)) l
            ];
          }
          final q = _query.trim();
          if (q.isNotEmpty) {
            listings = [
              for (final l in listings)
                if (listingMatchesQuery(l, q)) l
            ];
          }
          if (_minCents != null || _maxCents != null) {
            listings = [
              for (final l in listings)
                if (listingInPriceRange(l,
                    minCents: _minCents, maxCents: _maxCents))
                  l
            ];
          }
          // Sorted, with sold sunk to the end rather than hidden — a buyer
          // mid-conversation can still find one.
          listings = sortListings(listings, _sort);
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
                      if (_savedOnly)
                        InputChip(
                          avatar: const Icon(Icons.bookmark_outline, size: 15),
                          label: const Text('Saved'),
                          visualDensity: VisualDensity.compact,
                          onDeleted: () =>
                              setState(() => _savedOnly = false),
                        ),
                      if (_category.isNotEmpty)
                        InputChip(
                          label: Text(_category),
                          visualDensity: VisualDensity.compact,
                          onDeleted: () =>
                              setState(() => _category = ''),
                        ),
                      if (_minCents != null || _maxCents != null)
                        InputChip(
                          avatar: const Icon(Icons.attach_money, size: 15),
                          label: Text([
                            if (_minCents != null)
                              'from ${formatListingPrice(_minCents!)}',
                            if (_maxCents != null)
                              'to ${formatListingPrice(_maxCents!)}',
                          ].join(' ')),
                          visualDensity: VisualDensity.compact,
                          onDeleted: () => setState(() {
                            _minPrice.clear();
                            _maxPrice.clear();
                          }),
                        ),
                      if (_sort != ListingSort.newest)
                        InputChip(
                          avatar: const Icon(Icons.swap_vert, size: 15),
                          label: Text(_sort.label),
                          visualDensity: VisualDensity.compact,
                          onDeleted: () =>
                              setState(() => _sort = ListingSort.newest),
                        ),
                    ],
                  ),
                ),
              Expanded(
                // Pull-to-refresh ASKS: a catch-up broadcast to every joined
                // server, answered by each member online with the posts they
                // authored. Broadcast has no history, so an empty grid was
                // otherwise unfixable from this side — which read as "the
                // marketplace doesn't show listings".
                child: listings.isEmpty
                    ? PullToRefresh.emptyState(
                        onRefresh: () =>
                            RelayService.instance.requestFeedCatchup(),
                        child: _empty(context),
                      )
                    : PullToRefresh(
                        onRefresh: () =>
                            RelayService.instance.requestFeedCatchup(),
                        child: GridView.builder(
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
                            onOptions: _mine(listings[i])
                                ? null
                                : () => _listingOptions(listings[i]),
                          ),
                        ),
                      ),
              ),
            ],
          );
        },
      ),
    );
  }

  /// Long-press on someone else's listing: the same shield the feed gives —
  /// hide this one, or mute the seller everywhere. A marketplace without
  /// them makes "just don't look at it" the only moderation tool.
  void _listingOptions(FeedPost listing) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.visibility_off_outlined),
              title: const Text('Hide this listing'),
              onTap: () {
                FeedStore.instance.hidePost(listing.id);
                Navigator.of(sheetContext).pop();
              },
            ),
            ListTile(
              leading: const Icon(Icons.person_off_outlined),
              title: Text('Mute ${listing.authorName}'),
              subtitle: const Text(
                  'Hides their listings and posts on this device'),
              onTap: () {
                FeedStore.instance.toggleMute(listing.authorUsername);
                Navigator.of(sheetContext).pop();
              },
            ),
            ListTile(
              leading: const Icon(Icons.flag_outlined),
              title: const Text('Report'),
              subtitle: const Text('Hides it here and sends it to the app\'s '
                  'moderators'),
              onTap: () {
                FeedStore.instance.hidePost(listing.id);
                Navigator.of(sheetContext).pop();
                showReportSheet(
                  context,
                  context_: 'listing: ${listing.text}',
                  targetHandle: listing.authorUsername,
                );
              },
            ),
          ],
        ),
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
                style: TextStyle(color: AppColors.subtle(context), fontSize: 14),
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
  final VoidCallback? onOptions;
  const _ListingCard(
      {required this.listing,
      required this.serverName,
      required this.onTap,
      this.onOptions});

  @override
  Widget build(BuildContext context) {
    final title = listing.text.split('\n').first;
    return InkWell(
      onTap: onTap,
      onLongPress: onOptions,
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
                if (listing.listingVideo.isNotEmpty)
                  Positioned(
                    right: 8,
                    bottom: 8,
                    child: Container(
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.6),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.play_arrow,
                          size: 14, color: Colors.white),
                    ),
                  ),
                Builder(builder: (context) {
                  final n =
                      FeedStore.instance.listingPhotos(listing.id).length;
                  if (n < 2) return const SizedBox.shrink();
                  return Positioned(
                    right: 8,
                    top: 8,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.6),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.photo_library_outlined,
                              size: 12, color: Colors.white),
                          const SizedBox(width: 3),
                          Text('$n',
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700)),
                        ],
                      ),
                    ),
                  );
                }),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Text(formatListingPrice(listing.priceCents ?? 0),
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w800)),
              // Only a DROP earns the strikethrough — "was \$10, now \$50"
              // is not a selling point.
              if (listing.prevPriceCents > (listing.priceCents ?? 0)) ...[
                const SizedBox(width: 6),
                Text(formatListingPrice(listing.prevPriceCents),
                    style: TextStyle(
                        fontSize: 12.5,
                        color: AppColors.subtle(context),
                        decoration: TextDecoration.lineThrough)),
              ],
            ],
          ),
          Text(title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13.5)),
          if (serverName.isNotEmpty)
            Text(serverName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style:
                    TextStyle(fontSize: 11.5, color: AppColors.subtle(context))),
        ],
      ),
    );
  }

  Widget _placeholder(BuildContext context) => Container(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: Icon(Icons.image_outlined,
            size: 36, color: AppColors.subtle(context)),
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
                  style: TextStyle(color: AppColors.subtle(context))),
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
              IconButton(
                icon: Icon(FeedStore.instance.isSaved(listing.id)
                    ? Icons.bookmark
                    : Icons.bookmark_outline),
                tooltip: FeedStore.instance.isSaved(listing.id)
                    ? 'Unsave'
                    : 'Save',
                onPressed: () => FeedStore.instance.toggleSaved(listing.id),
              ),
              IconButton(
                icon: const Icon(Icons.forward),
                tooltip: 'Forward',
                // Into a chat or a channel, encrypted like any other
                // message — the same door every post already has.
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) =>
                        ForwardScreen(text: listingShareText(listing)))),
              ),
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
                          if (listing.listingVideo.isNotEmpty) {
                            MarketMedia.instance
                                .deleteVideo(listing.listingVideo);
                          }
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
                : Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: () => messageSeller(context, listing),
                          icon: const Icon(Icons.chat_bubble_outline,
                              size: 18),
                          label: Text('Message ${listing.authorName}'),
                          style: FilledButton.styleFrom(
                              minimumSize: const Size.fromHeight(48)),
                        ),
                      ),
                      // Only when the seller said offers are welcome, and
                      // never on something already sold.
                      if (listing.listingOffers && !listing.listingSold) ...[
                        const SizedBox(width: 8),
                        OutlinedButton.icon(
                          onPressed: () => makeOffer(context, listing),
                          icon: const Icon(Icons.handshake_outlined,
                              size: 18),
                          label: const Text('Offer'),
                          style: OutlinedButton.styleFrom(
                              minimumSize: const Size(0, 48)),
                        ),
                      ],
                    ],
                  ),
          ),
          body: ListView(
            padding: EdgeInsets.zero,
            children: [
              Builder(builder: (context) {
                final photos = FeedStore.instance.listingPhotos(listing.id);
                if (photos.isEmpty) return const SizedBox.shrink();
                return _ListingGallery(
                  photos: photos,
                  sold: listing.listingSold,
                  title: title,
                );
              }),
              if (listing.listingVideo.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(0, 8, 0, 0),
                  child: ListingVideoPlayer.isSupported
                      ? ListingVideoPlayer.build(
                          communityId: listing.communityId,
                          path: listing.listingVideo,
                        )
                      : Container(
                          padding: const EdgeInsets.all(14),
                          alignment: Alignment.center,
                          color: Theme.of(context)
                              .colorScheme
                              .surfaceContainerHighest,
                          child: Text(
                            'This listing has a video — watch it in the '
                            'mobile app.',
                            style: TextStyle(
                                fontSize: 13, color: AppColors.subtle(context)),
                          ),
                        ),
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
                        if (listing.listingBrand.isNotEmpty)
                          listing.listingBrand,
                        if (listing.listingCondition.isNotEmpty)
                          listing.listingCondition,
                        if (listing.listingCategory.isNotEmpty)
                          listing.listingCategory,
                        if (serverName.isNotEmpty) serverName,
                        feedAge(listing.time),
                      ].join(' · '),
                      style: TextStyle(
                          fontSize: 13, color: AppColors.subtle(context)),
                    ),
                    // The answers a buyer would otherwise have to ask for.
                    // Each is omitted when unset rather than shown empty: a
                    // row of "—" reads as a seller who could not be bothered.
                    if (listing.listingPlace.isNotEmpty ||
                        listing.listingDelivery.isNotEmpty ||
                        listing.listingQuantity > 1 ||
                        listing.listingOffers) ...[
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        runSpacing: 6,
                        children: [
                          if (listing.listingPlace.isNotEmpty)
                            _ListingFact(
                                icon: Icons.place_outlined,
                                label: listing.listingPlace),
                          if (listingDeliveryLabel(listing.listingDelivery)
                              .isNotEmpty)
                            _ListingFact(
                                icon: Icons.local_shipping_outlined,
                                label: listingDeliveryLabel(
                                    listing.listingDelivery)),
                          if (listing.listingQuantity > 1)
                            _ListingFact(
                                icon: Icons.inventory_2_outlined,
                                label: '${listing.listingQuantity} available'),
                          if (listing.listingOffers)
                            const _ListingFact(
                                icon: Icons.handshake_outlined,
                                label: 'Open to offers'),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              const Divider(height: 24, indent: 16, endIndent: 16),
              // The seller, as a row a buyer can act on.
              InkWell(
                onTap: mine
                    ? null
                    : () => Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => SellerScreen(
                            username: listing.authorUsername,
                            name: listing.authorName))),
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
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Flexible(
                                  child: Text(
                                      mine
                                          ? 'Your listing'
                                          : listing.authorName,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                          fontWeight: FontWeight.w600,
                                          fontSize: 14.5)),
                                ),
                                if (listing.authorVerified) ...[
                                  const SizedBox(width: 4),
                                  const VerifiedBadge(size: 15),
                                ],
                              ],
                            ),
                            Builder(builder: (context) {
                              final (avg, count) = FeedStore.instance
                                  .sellerRating(listing.authorUsername);
                              if (count == 0) {
                                return !mine &&
                                        listing.authorUsername.isNotEmpty &&
                                        listing.authorUsername != 'you'
                                    ? Text('@${listing.authorUsername}',
                                        style: TextStyle(
                                            fontSize: 12.5,
                                            color: AppColors.subtle(context)))
                                    : const SizedBox.shrink();
                              }
                              return Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(Icons.star_rounded,
                                      size: 15, color: Color(0xFFF5A623)),
                                  const SizedBox(width: 2),
                                  Text(
                                    '${avg.toStringAsFixed(1)} · $count '
                                    '${count == 1 ? "review" : "reviews"}',
                                    style: TextStyle(
                                        fontSize: 12.5,
                                        color: AppColors.subtle(context)),
                                  ),
                                ],
                              );
                            }),
                          ],
                        ),
                      ),
                      if (!mine)
                        Icon(Icons.chevron_right,
                            size: 20, color: AppColors.subtle(context)),
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
                              color: AppColors.subtle(context))),
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
              const Divider(height: 24, indent: 16, endIndent: 16),
              _ReviewsSection(listing: listing, mine: mine),
              // The next thing a browser wants: what else is in this
              // category. Absent when nothing else is — an honest gap
              // beats padding with the unrelated.
              ...(() {
                final more =
                    moreLikeThis(FeedStore.instance.listings(), listing);
                if (more.isEmpty) return const <Widget>[];
                return <Widget>[
                  const Divider(height: 24, indent: 16, endIndent: 16),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: Text('More like this',
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: AppColors.subtle(context))),
                  ),
                  SizedBox(
                    height: 168,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      children: [
                        for (final l in more)
                          Padding(
                            padding: const EdgeInsets.only(right: 10),
                            child: _MiniListingCard(listing: l),
                          ),
                      ],
                    ),
                  ),
                ];
              })(),
              const SizedBox(height: 24),
            ],
          ),
        );
      },
    );
  }
}

/// A small stepping-stone card for the "More like this" row: cover, price,
/// title. Opens that listing's own screen.
class _MiniListingCard extends StatelessWidget {
  final FeedPost listing;
  const _MiniListingCard({required this.listing});

  @override
  Widget build(BuildContext context) {
    final cover = FeedStore.instance.listingPhotos(listing.id).firstOrNull ??
        listing.gifUrl ??
        '';
    return InkWell(
      onTap: () => Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => ListingScreen(listingId: listing.id))),
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(
        width: 124,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: SizedBox(
                width: 124,
                height: 100,
                child: cover.isEmpty
                    ? Container(
                        color: Theme.of(context)
                            .colorScheme
                            .surfaceContainerHighest,
                        child: Icon(Icons.image_outlined,
                            color: AppColors.subtle(context)),
                      )
                    : ChatPhoto(
                        url: cover,
                        fit: BoxFit.cover,
                        errorBuilder: (_) => const SizedBox.shrink()),
              ),
            ),
            const SizedBox(height: 4),
            Text(formatListingPrice(listing.priceCents ?? 0),
                style: const TextStyle(
                    fontSize: 13.5, fontWeight: FontWeight.w700)),
            Text(listing.text.split('\n').first,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12)),
          ],
        ),
      ),
    );
  }
}

/// A row of five stars, filled up to [rating]. Tappable when [onRate] is set.
class _Stars extends StatelessWidget {
  final int rating;
  final double size;
  final ValueChanged<int>? onRate;
  const _Stars({required this.rating, this.size = 16, this.onRate});

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 1; i <= 5; i++)
            GestureDetector(
              onTap: onRate == null ? null : () => onRate!(i),
              child: Padding(
                padding: EdgeInsets.all(onRate == null ? 0 : 4),
                child: Icon(
                  i <= rating ? Icons.star_rounded : Icons.star_outline_rounded,
                  size: size,
                  color: i <= rating
                      ? const Color(0xFFF5A623)
                      : AppColors.subtle(context),
                ),
              ),
            ),
        ],
      );
}

/// The listing's reviews: average up top, each voice below, and — for anyone
/// but the seller — a button to add or change their own.
class _ReviewsSection extends StatelessWidget {
  final FeedPost listing;
  final bool mine;
  const _ReviewsSection({required this.listing, required this.mine});

  Future<void> _write(BuildContext context) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => Padding(
        padding: EdgeInsets.only(
            bottom: MediaQuery.of(sheetContext).viewInsets.bottom),
        child: SafeArea(
          child: _ReviewSheet(
            listingId: listing.id,
            existing: FeedStore.instance.myReviewOf(listing.id),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final reviews = FeedStore.instance.reviewsFor(listing.id);
    final myReview = FeedStore.instance.myReviewOf(listing.id);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('Reviews',
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: AppColors.subtle(context))),
              const Spacer(),
              if (!mine)
                TextButton(
                  onPressed: () => _write(context),
                  child: Text(
                      myReview == null ? 'Write a review' : 'Edit your review'),
                ),
            ],
          ),
          if (reviews.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2, bottom: 6),
              child: Text('No reviews yet.',
                  style:
                      TextStyle(fontSize: 13.5, color: AppColors.subtle(context))),
            )
          else
            for (final r in reviews)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        _Stars(rating: r.rating),
                        const SizedBox(width: 8),
                        if (r.authorVerified) ...[
                          const VerifiedBadge(size: 13),
                          const SizedBox(width: 4),
                        ],
                        Expanded(
                          child: Text(
                            '${r.authorName} · ${feedAge(r.time)}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 12.5,
                                color: AppColors.subtle(context)),
                          ),
                        ),
                      ],
                    ),
                    if (r.text.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 3),
                        child: Text(r.text,
                            style: const TextStyle(
                                fontSize: 14, height: 1.35)),
                      ),
                  ],
                ),
              ),
        ],
      ),
    );
  }
}

/// Writing or editing one's review: tappable stars and an optional note.
/// Its own widget so the text controller has a real lifecycle — disposing it
/// after the sheet's future resolved raced the closing animation.
class _ReviewSheet extends StatefulWidget {
  final String listingId;
  final FeedPost? existing;
  const _ReviewSheet({required this.listingId, required this.existing});

  @override
  State<_ReviewSheet> createState() => _ReviewSheetState();
}

class _ReviewSheetState extends State<_ReviewSheet> {
  late int _rating = widget.existing?.rating ?? 0;
  late final TextEditingController _text =
      TextEditingController(text: widget.existing?.text ?? '');

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
                widget.existing == null
                    ? 'Review this listing'
                    : 'Edit your review',
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontSize: 17, fontWeight: FontWeight.w700)),
            const SizedBox(height: 10),
            Center(
              child: _Stars(
                rating: _rating,
                size: 34,
                onRate: (r) => setState(() => _rating = r),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _text,
              minLines: 2,
              maxLines: 5,
              maxLength: 300,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                  hintText: 'How did it go? (optional)'),
            ),
            const SizedBox(height: 4),
            FilledButton(
              // No stars, no review — the rating is the one required part.
              onPressed: _rating == 0
                  ? null
                  : () {
                      FeedStore.instance.addReview(widget.listingId,
                          rating: _rating, text: _text.text);
                      Navigator.of(context).pop();
                    },
              child: Text(widget.existing == null ? 'Post review' : 'Save'),
            ),
          ],
        ),
      );
}

/// The listing's photos as a swipeable gallery with a page pill; any page
/// opens full screen. One photo renders exactly as the single-photo layout
/// did — the pill and dots only appear once there is something to swipe to.
class _ListingGallery extends StatefulWidget {
  final List<String> photos;
  final bool sold;
  final String title;
  const _ListingGallery(
      {required this.photos, required this.sold, required this.title});

  @override
  State<_ListingGallery> createState() => _ListingGalleryState();
}

class _ListingGalleryState extends State<_ListingGallery> {
  int _page = 0;

  @override
  Widget build(BuildContext context) {
    final many = widget.photos.length > 1;
    return Stack(
      children: [
        SizedBox(
          height: 320,
          child: PageView(
            onPageChanged: (i) => setState(() => _page = i),
            children: [
              for (final url in widget.photos)
                GestureDetector(
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => _ListingPhotoScreen(
                          url: url, title: widget.title),
                    ),
                  ),
                  child: ChatPhoto(
                    url: url,
                    fit: BoxFit.cover,
                    errorBuilder: (_) => const SizedBox.shrink(),
                  ),
                ),
            ],
          ),
        ),
        if (widget.sold)
          const Positioned(left: 14, top: 14, child: _SoldBadge(large: true)),
        if (many)
          Positioned(
            right: 12,
            top: 12,
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text('${_page + 1}/${widget.photos.length}',
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w700)),
            ),
          ),
        if (many)
          Positioned(
            left: 0,
            right: 0,
            bottom: 10,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (var i = 0; i < widget.photos.length; i++)
                  Container(
                    width: 7,
                    height: 7,
                    margin: const EdgeInsets.symmetric(horizontal: 3),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: i == _page
                          ? Colors.white
                          : Colors.white.withValues(alpha: 0.45),
                    ),
                  ),
              ],
            ),
          ),
      ],
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
  late String _condition = widget.existing?.listingCondition ?? '';
  late String _delivery = widget.existing?.listingDelivery ?? '';
  late final TextEditingController _quantity = TextEditingController(
      text: (widget.existing?.listingQuantity ?? 1) > 1
          ? '${widget.existing!.listingQuantity}'
          : '');
  late bool _offers = widget.existing?.listingOffers ?? false;
  late String _place = widget.existing?.listingPlace ?? '';
  late final TextEditingController _brand =
      TextEditingController(text: widget.existing?.listingBrand ?? '');

  /// "It was \$X" — only offered while CREATING. On an edit the field
  /// would fight the automatic price-drop history updateListing keeps.
  final TextEditingController _wasPrice = TextEditingController();
  /// Up to [kMaxListingPhotos], cover first. Prefilled from the existing
  /// listing and its photo parts when editing.
  late final List<String> _photos = widget.existing == null
      ? []
      : FeedStore.instance.listingPhotos(widget.existing!.id);
  late String _communityId = widget.existing?.communityId ??
      (CommunityStore.instance.communities.isEmpty
          ? ''
          : CommunityStore.instance.communities.first.id);

  /// The listing's current video: a bucket path when editing one that has a
  /// video, and freshly picked bytes waiting to upload on Post.
  late String _videoPath = widget.existing?.listingVideo ?? '';
  Uint8List? _videoBytes;
  bool _uploadingVideo = false;
  String? _error;

  bool get _hasVideo => _videoBytes != null || _videoPath.isNotEmpty;

  Future<void> _pickVideo() async {
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.video,
        withData: true,
      );
      final bytes = result?.files.firstOrNull?.bytes;
      if (bytes == null || bytes.isEmpty || !mounted) return;
      if (!MarketMedia.looksLikeVideo(bytes)) {
        setState(() => _error = 'That file doesn\'t look like a video.');
        return;
      }
      if (bytes.length > MarketMedia.maxVideoBytes) {
        setState(() => _error =
            'Videos can be up to ${MarketMedia.maxVideoBytes ~/ (1024 * 1024)}'
            ' MB — about 30 seconds.');
        return;
      }
      setState(() {
        _videoBytes = bytes;
        _error = null;
      });
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Couldn\'t read that video.');
      }
    }
  }

  /// The typed quantity, floored at one. An empty field means one, which is
  /// why the field is left blank rather than pre-filled with "1" — a form
  /// that starts full of defaults reads as a form with more to answer.
  int get _quantityValue {
    final n = int.tryParse(_quantity.text.trim()) ?? 1;
    return n < 1 ? 1 : n;
  }

  /// The grouped, searchable category sheet.
  Future<void> _pickCategory() async {
    final chosen = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _CategorySheet(selected: _category),
    );
    if (chosen != null && mounted) setState(() => _category = chosen);
  }

  /// Where the item is, chosen on the app's one map.
  Future<void> _pickPlace() async {
    final picked = await Navigator.of(context).push<GeoResult>(
      MaterialPageRoute(builder: (_) => const ExploreMapScreen(picking: true)),
    );
    if (picked == null || !mounted) return;
    // The NAME only. A listing goes to everyone in the server, and a
    // coordinate pair to five decimals is somebody's address.
    setState(() => _place = picked.name.trim());
  }

  @override
  void dispose() {
    _title.dispose();
    _price.dispose();
    _wasPrice.dispose();
    _brand.dispose();
    _quantity.dispose();
    _description.dispose();
    super.dispose();
  }

  Future<void> _pickPhoto() async {
    if (_photos.length >= kMaxListingPhotos) return;
    try {
      final uri = await PhotoPrep.pickPhoto();
      if (uri != null && mounted) setState(() => _photos.add(uri));
    } on FileRejected catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.reason)));
      }
    }
  }

  /// The form reads as chapters now, not one long column: a label, air
  /// above it, and the fields that answer it underneath.
  Widget _section(String text) => Padding(
        padding: const EdgeInsets.only(top: 22, bottom: 8),
        child: Text(
          text.toUpperCase(),
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.7,
            color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.7),
          ),
        ),
      );

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
    _finish(title, cents);
  }

  Future<void> _finish(String title, int cents) async {
    final existing = widget.existing;
    final bytes = _videoBytes;
    var videoPath = _videoPath;
    final removedVideo =
        existing != null && existing.listingVideo.isNotEmpty && !_hasVideo;

    // The listing's id names its video object, so the listing exists first
    // and the upload follows; a failed upload leaves a listing without a
    // video and says so, never a video without a listing.
    FeedPost listing;
    if (existing != null) {
      FeedStore.instance.updateListing(
        existing.id,
        title: title,
        priceCents: cents,
        category: _category,
        description: _description.text,
        photoUrl: _photos.firstOrNull,
        extraPhotos: _photos.skip(1).toList(),
        videoPath: removedVideo ? '' : videoPath,
        condition: _condition,
        delivery: _delivery,
        quantity: _quantityValue,
        offers: _offers,
        place: _place,
        brand: _brand.text.trim(),
      );
      listing = existing;
    } else {
      listing = FeedStore.instance.addListing(
        _communityId,
        title: title,
        priceCents: cents,
        category: _category,
        description: _description.text,
        photoUrl: _photos.firstOrNull,
        extraPhotos: _photos.skip(1).toList(),
        condition: _condition,
        delivery: _delivery,
        quantity: _quantityValue,
        offers: _offers,
        place: _place,
        brand: _brand.text.trim(),
        prevPriceCents: parseListingPrice(_wasPrice.text) ?? 0,
      );
    }
    if (removedVideo) {
      MarketMedia.instance.deleteVideo(existing.listingVideo);
    }
    if (bytes != null) {
      setState(() => _uploadingVideo = true);
      try {
        videoPath = await MarketMedia.instance.uploadVideo(
          communityId: listing.communityId,
          listingId: listing.id,
          bytes: bytes,
        );
        FeedStore.instance.updateListing(
          listing.id,
          title: title,
          priceCents: cents,
          category: _category,
          description: _description.text,
          photoUrl: _photos.firstOrNull,
          videoPath: videoPath,
        );
      } on MarketMediaError catch (e) {
        if (mounted) {
          setState(() {
            _uploadingVideo = false;
            _error = '${e.reason} The listing posted without its video — '
                'edit it to try again.';
          });
        }
        return;
      }
    }
    if (mounted) Navigator.of(context).pop(true);
  }

  /// The video slot. Hosting a video costs real money (storage + egress per
  /// view), so uploading is part of the cloud storage subscription — the one
  /// paid thing this app sells, with unit economics the suite proves. The
  /// locked tile says exactly that instead of hiding the feature.
  Widget _videoTile(BuildContext context) {
    final subscribed = StorageStore.instance.isPaid;
    if (_uploadingVideo) {
      return Row(
        children: [
          const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2)),
          const SizedBox(width: 10),
          Text('Uploading video…',
              style: TextStyle(color: AppColors.subtle(context))),
        ],
      );
    }
    if (_hasVideo) {
      return Row(
        children: [
          const Icon(Icons.videocam_outlined, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _videoBytes != null
                  ? 'Video attached '
                      '(${(_videoBytes!.length / (1024 * 1024)).toStringAsFixed(1)} MB)'
                  : 'This listing has a video',
              style: const TextStyle(fontSize: 13.5),
            ),
          ),
          TextButton(
            onPressed: () => setState(() {
              _videoBytes = null;
              _videoPath = '';
            }),
            child: const Text('Remove'),
          ),
        ],
      );
    }
    if (!subscribed) {
      return Row(
        children: [
          Icon(Icons.videocam_off_outlined,
              size: 20, color: AppColors.subtle(context)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Add a video with cloud storage — hosting video costs real '
              'storage, and the subscription is what pays for it.',
              style: TextStyle(fontSize: 12.5, color: AppColors.subtle(context)),
            ),
          ),
        ],
      );
    }
    return OutlinedButton.icon(
      onPressed: _pickVideo,
      icon: const Icon(Icons.videocam_outlined, size: 18),
      label: const Text('Add a video (up to 12 MB, ~30s)'),
    );
  }

  /// Whether backing out now would throw work away.
  ///
  /// For a new listing: anything typed or attached. For an edit: anything
  /// actually CHANGED — asking "discard?" on an untouched form teaches
  /// people the dialog is noise and they stop reading it.
  bool get _dirty {
    final existing = widget.existing;
    if (existing == null) {
      return _title.text.trim().isNotEmpty ||
          _description.text.trim().isNotEmpty ||
          _photos.isNotEmpty ||
          _videoBytes != null;
    }
    final lines = existing.text.split('\n');
    return _title.text.trim() != lines.first ||
        _description.text.trim() != lines.skip(1).join('\n').trim() ||
        parseListingPrice(_price.text) != (existing.priceCents ?? 0) ||
        _category != existing.listingCategory ||
        _brand.text.trim() != existing.listingBrand ||
        _condition != existing.listingCondition ||
        _delivery != existing.listingDelivery ||
        _quantityValue != existing.listingQuantity ||
        _offers != existing.listingOffers ||
        _place != existing.listingPlace ||
        _videoBytes != null ||
        (_videoPath.isEmpty) != existing.listingVideo.isEmpty ||
        !listEquals(
            _photos, FeedStore.instance.listingPhotos(existing.id));
  }

  Future<void> _close() async {
    if (!_dirty) {
      Navigator.of(context).pop();
      return;
    }
    final discard = await showAppConfirmDialog(
      context,
      icon: Icons.delete_outline,
      title: widget.existing == null ? 'Discard listing?' : 'Discard changes?',
      message: 'What you\'ve entered here will be lost.',
      confirmLabel: 'Discard',
      destructive: true,
    );
    if (discard && mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final servers = CommunityStore.instance.communities;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _close();
      },
      child: _buildScaffold(context, servers),
    );
  }

  Widget _buildScaffold(BuildContext context, List<Community> servers) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.existing == null ? 'New listing' : 'Edit listing'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: 'Cancel',
          onPressed: _close,
        ),
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
          // AT THE TOP, not the bottom. It used to sit under the last field,
          // which was survivable on a short form and stopped being so the
          // moment this one grew: you tapped Post, the refusal rendered
          // below the fold, and nothing appeared to happen at all.
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.error_outline,
                      size: 18, color: Theme.of(context).colorScheme.error),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(_error!,
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.error)),
                  ),
                ],
              ),
            ),
          // Up to four photos, cover first. Each rides the relay as its own
          // message, which is why the cap exists at all — see mediaPart.
          _section('Photos & video'),
          SizedBox(
            height: 110,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                for (var i = 0; i < _photos.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Stack(
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: SizedBox(
                            width: 110,
                            height: 110,
                            child: ChatPhoto(
                                url: _photos[i],
                                fit: BoxFit.cover,
                                errorBuilder: (_) =>
                                    const SizedBox.shrink()),
                          ),
                        ),
                        if (i == 0)
                          Positioned(
                            left: 6,
                            bottom: 6,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color:
                                    Colors.black.withValues(alpha: 0.6),
                                borderRadius: BorderRadius.circular(5),
                              ),
                              child: const Text('Cover',
                                  style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 10.5,
                                      fontWeight: FontWeight.w700)),
                            ),
                          ),
                        Positioned(
                          right: 4,
                          top: 4,
                          child: InkWell(
                            onTap: () =>
                                setState(() => _photos.removeAt(i)),
                            child: Container(
                              padding: const EdgeInsets.all(3),
                              decoration: BoxDecoration(
                                color:
                                    Colors.black.withValues(alpha: 0.6),
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(Icons.close,
                                  size: 14, color: Colors.white),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                if (_photos.length < kMaxListingPhotos)
                  InkWell(
                    onTap: _pickPhoto,
                    borderRadius: BorderRadius.circular(12),
                    child: Container(
                      width: 110,
                      height: 110,
                      decoration: BoxDecoration(
                        color: Theme.of(context)
                            .colorScheme
                            .surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.add_a_photo_outlined,
                              size: 26, color: AppColors.subtle(context)),
                          const SizedBox(height: 4),
                          Text(
                              _photos.isEmpty
                                  ? 'Add photos'
                                  : '${_photos.length}/$kMaxListingPhotos',
                              style: TextStyle(
                                  fontSize: 11.5,
                                  color: AppColors.subtle(context))),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          _videoTile(context),
          _section('What it is'),
          TextField(
            controller: _title,
            textCapitalization: TextCapitalization.sentences,
            // The title carries the listing, so it reads a size up.
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
            decoration: const InputDecoration(hintText: 'What are you selling?'),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _brand,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(
                labelText: 'Brand (optional)', hintText: 'Apple, IKEA, Trek…'),
          ),
          const SizedBox(height: 14),
          // A field that OPENS A SHEET rather than a dropdown. Forty
          // categories in a menu is a wall to scroll past, and the one you
          // want is never the one on screen; the sheet groups them and
          // takes a search.
          InkWell(
            onTap: _pickCategory,
            child: InputDecorator(
              decoration: const InputDecoration(labelText: 'Category'),
              child: Row(
                children: [
                  Expanded(
                    child: Text(_category,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
                  const Icon(Icons.arrow_drop_down),
                ],
              ),
            ),
          ),
          const SizedBox(height: 14),
          Align(
            alignment: Alignment.centerLeft,
            child: Text('Condition',
                style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: AppColors.subtle(context))),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final c in kListingConditions)
                ChoiceChip(
                  label: Text(c),
                  selected: _condition == c,
                  visualDensity: VisualDensity.compact,
                  onSelected: (_) => setState(
                      () => _condition = _condition == c ? '' : c),
                ),
            ],
          ),
          _section('The price'),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: TextField(
                  controller: _price,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(
                      hintText: 'Free', labelText: 'Price', prefixText: '\$ '),
                ),
              ),
              if (widget.existing == null) ...[
                const SizedBox(width: 10),
                Expanded(
                  // What it USED to cost — drawn struck-through on the
                  // card, and only while it is higher than the ask.
                  child: TextField(
                    controller: _wasPrice,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                        labelText: 'Was (optional)', prefixText: '\$ '),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 14),
          InkWell(
            onTap: () => setState(() => _offers = !_offers),
            child: InputDecorator(
              decoration: const InputDecoration(labelText: 'Negotiable'),
              child: Row(
                children: [
                  Expanded(
                    child: Text(_offers ? 'Open to offers' : 'Firm',
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
                  Switch(
                    value: _offers,
                    onChanged: (v) => setState(() => _offers = v),
                  ),
                ],
              ),
            ),
          ),
          _section('The handoff'),
          Wrap(
            spacing: 8,
            children: [
              for (final (value, label) in kListingDeliveryOptions)
                ChoiceChip(
                  label: Text(label),
                  selected: _delivery == value,
                  onSelected: (_) => setState(
                      () => _delivery = _delivery == value ? '' : value),
                ),
            ],
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _quantity,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration:
                const InputDecoration(labelText: 'Quantity', hintText: '1'),
          ),
          const SizedBox(height: 14),
          // Where it is. A NAME, never coordinates: this rides the relay to
          // everyone in the server, and "Bloor & Bathurst" is what a buyer
          // needs while a lat/lng to five decimals is somebody's front door.
          InkWell(
            onTap: _pickPlace,
            child: InputDecorator(
              decoration: InputDecoration(
                labelText: 'Where it is',
                suffixIcon: _place.isEmpty
                    ? const Icon(Icons.map_outlined)
                    : IconButton(
                        icon: const Icon(Icons.close),
                        tooltip: 'Clear',
                        onPressed: () => setState(() => _place = ''),
                      ),
              ),
              child: Text(
                _place.isEmpty ? 'Add a pickup area' : _place,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: _place.isEmpty
                    ? TextStyle(color: AppColors.subtle(context))
                    : null,
              ),
            ),
          ),
          if (servers.length > 1 && widget.existing == null) ...[
            _section('Where it posts'),
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
          ],
          _section('Description'),
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
                  size: 16, color: AppColors.subtle(context)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Shared with members of '
                  '${servers.firstWhere((c) => c.id == _communityId, orElse: () => servers.first).name}.',
                  style:
                      TextStyle(fontSize: 12.5, color: AppColors.subtle(context)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// One seller, whole: who they are, how they've been rated, everything they
/// have for sale that this device can see. Where the trust question — "who
/// am I buying from?" — gets its one-screen answer.
class SellerScreen extends StatelessWidget {
  final String username;
  final String name;
  const SellerScreen({super.key, required this.username, required this.name});

  String _serverName(String id) {
    for (final c in CommunityStore.instance.communities) {
      if (c.id == id) return c.name;
    }
    return '';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(name)),
      body: ListenableBuilder(
        listenable: FeedStore.instance,
        builder: (context, _) {
          final listings = [
            for (final l in FeedStore.instance.listings())
              if (l.authorUsername.toLowerCase() == username.toLowerCase()) l
          ];
          final (avg, count) = FeedStore.instance.sellerRating(username);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
                child: Row(
                  children: [
                    CircleAvatar(
                      radius: 26,
                      child: Text(
                          name.isEmpty ? '?' : name[0].toUpperCase(),
                          style: const TextStyle(fontSize: 20)),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Flexible(
                                child: Text(name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                        fontSize: 17,
                                        fontWeight: FontWeight.w800)),
                              ),
                              if (listings
                                  .any((l) => l.authorVerified)) ...[
                                const SizedBox(width: 5),
                                const VerifiedBadge(size: 17),
                              ],
                            ],
                          ),
                          if (username.isNotEmpty && username != 'you')
                            Text('@$username',
                                style: TextStyle(
                                    fontSize: 13,
                                    color: AppColors.subtle(context))),
                          Row(
                            children: [
                              if (count > 0) ...[
                                const Icon(Icons.star_rounded,
                                    size: 15, color: Color(0xFFF5A623)),
                                const SizedBox(width: 2),
                                Text(
                                  '${avg.toStringAsFixed(1)} · $count '
                                  '${count == 1 ? "review" : "reviews"} · ',
                                  style: TextStyle(
                                      fontSize: 12.5,
                                      color: AppColors.subtle(context)),
                                ),
                              ],
                              Text(
                                '${listings.length} '
                                '${listings.length == 1 ? "listing" : "listings"}',
                                style: TextStyle(
                                    fontSize: 12.5,
                                    color: AppColors.subtle(context)),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    FilledButton(
                      onPressed: () => openSellerChat(context,
                          username: username, name: name),
                      child: const Text('Message'),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: listings.isEmpty
                    ? Center(
                        child: Text('Nothing for sale right now.',
                            style: TextStyle(
                                color: AppColors.subtle(context), fontSize: 14)),
                      )
                    : GridView.builder(
                        padding: const EdgeInsets.all(12),
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
                          serverName:
                              _serverName(listings[i].communityId),
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => ListingScreen(
                                  listingId: listings[i].id),
                            ),
                          ),
                        ),
                      ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// The category chooser: grouped, searchable, and taller than a dropdown.
///
/// A dropdown was fine for nineteen categories and is not fine for forty —
/// the one you want is never the one on screen, and there is no way to type
/// at it. Search matches anywhere in the name, so "phone" finds
/// "Phones & Tablets" and "camp" finds "Camping & Outdoors".
class _CategorySheet extends StatefulWidget {
  final String selected;
  const _CategorySheet({required this.selected});

  @override
  State<_CategorySheet> createState() => _CategorySheetState();
}

class _CategorySheetState extends State<_CategorySheet> {
  final TextEditingController _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final q = _search.text.trim().toLowerCase();
    final sections = q.isEmpty
        ? marketplaceCategorySections()
        : [
            (
              'Matches',
              kMarketplaceCategories
                  .where((c) => c.toLowerCase().contains(q))
                  .toList()
            )
          ];
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).viewInsets.bottom),
        child: SizedBox(
          height: MediaQuery.of(context).size.height * 0.75,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: TextField(
                  controller: _search,
                  autofocus: false,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    hintText: 'Search categories',
                    prefixIcon: const Icon(Icons.search),
                    isDense: true,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(24),
                      borderSide: BorderSide.none,
                    ),
                    filled: true,
                  ),
                ),
              ),
              Expanded(
                child: sections.every((s) => s.$2.isEmpty)
                    ? Center(
                        child: Text('Nothing matches "${_search.text.trim()}"',
                            style: TextStyle(color: AppColors.subtle(context))),
                      )
                    : ListView(
                        padding: const EdgeInsets.only(bottom: 16),
                        children: [
                          for (final (heading, items) in sections) ...[
                            if (items.isNotEmpty)
                              Padding(
                                padding:
                                    const EdgeInsets.fromLTRB(16, 12, 16, 4),
                                child: Text(
                                  heading.toUpperCase(),
                                  style: TextStyle(
                                    fontSize: 11.5,
                                    fontWeight: FontWeight.w700,
                                    letterSpacing: 0.8,
                                    color: AppColors.subtle(context),
                                  ),
                                ),
                              ),
                            for (final c in items)
                              ListTile(
                                dense: true,
                                title: Text(c),
                                trailing: c == widget.selected
                                    ? const Icon(Icons.check, size: 20)
                                    : null,
                                onTap: () => Navigator.of(context).pop(c),
                              ),
                          ],
                        ],
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}


/// One fact about a listing, as a small labelled pill.
class _ListingFact extends StatelessWidget {
  final IconData icon;
  final String label;
  const _ListingFact({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    final subtle = AppColors.subtle(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: subtle),
          const SizedBox(width: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 220),
            child: Text(label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12.5)),
          ),
        ],
      ),
    );
  }
}
