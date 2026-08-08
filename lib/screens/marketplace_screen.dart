import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import '../state/feed_drafts.dart';
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
import 'home_screen.dart' show AppBottomNavBar, HomeScreen;
import '../state/parental_controls.dart';
import '../widgets/parental_gate.dart';
import '../widgets/pull_to_refresh.dart';
import '../widgets/user_avatar.dart';
import '../state/community_store.dart';
import '../state/creator_sub_store.dart';
import '../state/feed_store.dart';
import '../state/follow_store.dart';
import '../state/public_feed_store.dart';
import '../state/market_media.dart';
import '../payments/payment_service.dart';
import '../util/geocoding.dart';
import 'explore_map_screen.dart';
import '../util/file_moderation.dart';
import '../util/photo_prep.dart';
import '../widgets/app_dialogs.dart';
import '../widgets/chat_photo.dart';
import '../widgets/listing_video.dart';
import '../widgets/sanction_notice.dart';
import '../widgets/subscribe_sheet.dart';
import '../widgets/verified_badge.dart';
import 'chat_screen.dart';
import 'feed_screen.dart' show showPersonSheet, feedSpans;
import 'forward_screen.dart';
import 'my_listings_screen.dart';
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
  // 2026-08-05: more of the things people were filing under 'Other'.
  'Kitchen & Dining',
  'Home Decor',
  'Fitness & Gym',
  'Trading Cards & Comics',
  'Handmade',
  'Garden & Plants',
  'Health & Wellness',
  'Luggage & Travel',
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
    'Kitchen & Dining',
    'Home Decor',
    'Garden & Plants',
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
    'Fitness & Gym',
    'Camping & Outdoors',
    'Games & Toys',
    'Trading Cards & Comics',
    'Musical Instruments',
    'Books',
    'Movies & Music',
    'Art & Collectibles',
    'Antiques',
    'Crafts & Hobbies',
    'Handmade',
    'Tickets',
  ],
  'Everything else': [
    'Baby & Kids',
    'Pet Supplies',
    'Food & Drink',
    'Health & Wellness',
    'Luggage & Travel',
    'Office & Business',
    'Property & Rentals',
    'Services',
    'Wanted',
    'Free stuff',
    'Other',
  ],
};

/// A glyph for the browse strip. A best-effort map — anything unlisted gets a
/// neutral tag, because a wrong icon is worse than a plain one.
IconData marketplaceCategoryIcon(String category) {
  switch (category) {
    case 'Electronics':
    case 'Phones & Tablets':
      return Icons.smartphone_outlined;
    case 'Computers':
      return Icons.laptop_outlined;
    case 'TV & Audio':
      return Icons.speaker_outlined;
    case 'Cameras & Photo':
      return Icons.camera_alt_outlined;
    case 'Video Games & Consoles':
      return Icons.sports_esports_outlined;
    case 'Appliances':
    case 'Kitchen & Dining':
      return Icons.kitchen_outlined;
    case 'Furniture':
    case 'Home Decor':
      return Icons.chair_outlined;
    case 'Home & Garden':
    case 'Garden & Plants':
      return Icons.yard_outlined;
    case 'Tools & Home Improvement':
    case 'Building Materials':
      return Icons.handyman_outlined;
    case 'Clothing':
    case 'Shoes':
      return Icons.checkroom_outlined;
    case 'Jewelry & Accessories':
    case 'Watches':
      return Icons.diamond_outlined;
    case 'Beauty & Health':
    case 'Health & Wellness':
      return Icons.spa_outlined;
    case 'Baby & Kids':
      return Icons.child_friendly_outlined;
    case 'Vehicles':
      return Icons.directions_car_outlined;
    case 'Auto Parts':
      return Icons.settings_outlined;
    case 'Motorcycles':
      return Icons.two_wheeler_outlined;
    case 'Bikes':
      return Icons.pedal_bike_outlined;
    case 'Boats & Watercraft':
      return Icons.sailing_outlined;
    case 'Sports':
    case 'Fitness & Gym':
    case 'Camping & Outdoors':
      return Icons.sports_soccer_outlined;
    case 'Games & Toys':
      return Icons.toys_outlined;
    case 'Trading Cards & Comics':
      return Icons.style_outlined;
    case 'Musical Instruments':
      return Icons.music_note_outlined;
    case 'Pet Supplies':
      return Icons.pets_outlined;
    case 'Books':
    case 'Movies & Music':
      return Icons.menu_book_outlined;
    case 'Art & Collectibles':
    case 'Antiques':
    case 'Crafts & Hobbies':
    case 'Handmade':
      return Icons.palette_outlined;
    case 'Tickets':
      return Icons.confirmation_number_outlined;
    case 'Luggage & Travel':
    case 'Bags & Luggage':
      return Icons.luggage_outlined;
    case 'Office & Business':
      return Icons.work_outline;
    case 'Farm & Garden Equipment':
      return Icons.agriculture_outlined;
    case 'Food & Drink':
      return Icons.restaurant_outlined;
    case 'Property & Rentals':
      return Icons.home_outlined;
    case 'Services':
      return Icons.build_outlined;
    case 'Free stuff':
      return Icons.redeem_outlined;
    case 'Wanted':
      return Icons.search_outlined;
    default:
      return Icons.sell_outlined;
  }
}

/// One category-specific field on the sell form. [choices] empty means a
/// free-text box; non-empty draws a chip picker. [suffix] is a unit shown
/// after a number ('mi', 'sq ft'). Pure data — the field's answer is stored
/// in [FeedPost.listingAttributes] under [label].
class CategoryField {
  final String label;
  final List<String> choices;
  final bool numeric;
  final String suffix;
  const CategoryField(this.label,
      {this.choices = const [], this.numeric = false, this.suffix = ''});
}

/// What extra questions each category asks. A category not named here asks
/// none — the sell form is generic for most things and gets specific only
/// where a whole class of listing needs it (a flat has bedrooms, a car has
/// mileage). Keys ARE the attribute labels stored on the listing, so
/// renaming one orphans old answers; add, don't rename.
const Map<String, List<CategoryField>> kCategoryFields = {
  'Property & Rentals': [
    CategoryField('Listing type', choices: [
      'For rent',
      'For sale',
      'Short stay',
      'Commercial lease',
      'Room / flatshare',
      'Land',
    ]),
    CategoryField('Property type', choices: [
      'Apartment',
      'House',
      'Condo',
      'Townhouse',
      'Studio',
      'Office',
      'Retail',
      'Warehouse',
      'Land',
    ]),
    CategoryField('Bedrooms', numeric: true),
    CategoryField('Bathrooms', numeric: true),
    CategoryField('Size', numeric: true, suffix: 'sq ft'),
    CategoryField('Rent period', choices: [
      'per month',
      'per week',
      'per night',
      'per year',
    ]),
    CategoryField('Furnished', choices: ['Furnished', 'Unfurnished', 'Part']),
    CategoryField('Parking', choices: ['Yes', 'No', 'Street', 'Garage']),
    CategoryField('Available from'),
  ],
  'Vehicles': [
    CategoryField('Make'),
    CategoryField('Model'),
    CategoryField('Year', numeric: true),
    CategoryField('Mileage', numeric: true, suffix: 'mi'),
    CategoryField('Transmission', choices: ['Automatic', 'Manual']),
    CategoryField('Fuel',
        choices: ['Petrol', 'Diesel', 'Hybrid', 'Electric', 'Other']),
    CategoryField('Body', choices: [
      'Sedan',
      'SUV',
      'Hatchback',
      'Truck',
      'Van',
      'Coupe',
      'Convertible',
    ]),
    CategoryField('Colour'),
  ],
  'Motorcycles': [
    CategoryField('Make'),
    CategoryField('Year', numeric: true),
    CategoryField('Mileage', numeric: true, suffix: 'mi'),
    CategoryField('Engine', numeric: true, suffix: 'cc'),
  ],
  'Services': [
    CategoryField('Service type'),
    CategoryField('Rate', choices: ['per hour', 'per job', 'per day', 'fixed']),
    CategoryField('Availability'),
    CategoryField('Serves', choices: ['On site', 'Remote', 'Both']),
  ],
  // 2026-08-05: structured fields for the busiest categories, so the details
  // that used to be crammed into the description are their own answers — richer
  // listings and, at the buyer's end, a filterable spec table.
  'Electronics': [
    CategoryField('Brand'),
    CategoryField('Model'),
  ],
  'Phones & Tablets': [
    CategoryField('Brand'),
    CategoryField('Model'),
    CategoryField('Storage',
        choices: ['16GB', '32GB', '64GB', '128GB', '256GB', '512GB', '1TB']),
    CategoryField('Network',
        choices: ['Unlocked', 'Locked', 'eSIM only']),
    CategoryField('Colour'),
  ],
  'Computers': [
    CategoryField('Brand'),
    CategoryField('Type', choices: [
      'Laptop',
      'Desktop',
      'All-in-one',
      'Tablet',
      'Parts',
    ]),
    CategoryField('RAM',
        choices: ['4GB', '8GB', '16GB', '32GB', '64GB']),
    CategoryField('Storage'),
  ],
  'TV & Audio': [
    CategoryField('Brand'),
    CategoryField('Type', choices: [
      'TV',
      'Speaker',
      'Soundbar',
      'Headphones',
      'Amplifier',
      'Turntable',
      'Other',
    ]),
    CategoryField('Screen size', numeric: true, suffix: 'in'),
  ],
  'Cameras & Photo': [
    CategoryField('Brand'),
    CategoryField('Type', choices: [
      'DSLR',
      'Mirrorless',
      'Point & shoot',
      'Film',
      'Action',
      'Lens',
      'Accessory',
    ]),
  ],
  'Video Games & Consoles': [
    CategoryField('Platform', choices: [
      'PlayStation',
      'Xbox',
      'Nintendo Switch',
      'PC',
      'Retro',
      'Other',
    ]),
    CategoryField('Type', choices: ['Game', 'Console', 'Accessory']),
  ],
  'Clothing': [
    CategoryField('Size', choices: [
      'XS',
      'S',
      'M',
      'L',
      'XL',
      'XXL',
      'One size',
    ]),
    CategoryField('For', choices: [
      'Women',
      'Men',
      'Unisex',
      'Girls',
      'Boys',
    ]),
    CategoryField('Colour'),
    CategoryField('Brand'),
  ],
  'Shoes': [
    CategoryField('Size', numeric: true),
    CategoryField('For', choices: ['Women', 'Men', 'Unisex', 'Kids']),
    CategoryField('Brand'),
    CategoryField('Colour'),
  ],
  'Furniture': [
    CategoryField('Type', choices: [
      'Sofa',
      'Chair',
      'Table',
      'Bed',
      'Dresser',
      'Desk',
      'Shelving',
      'Other',
    ]),
    CategoryField('Material'),
    CategoryField('Colour'),
  ],
  'Appliances': [
    CategoryField('Brand'),
    CategoryField('Type', choices: [
      'Fridge',
      'Washer',
      'Dryer',
      'Dishwasher',
      'Oven',
      'Microwave',
      'Small appliance',
      'Other',
    ]),
  ],
  'Bikes': [
    CategoryField('Type', choices: [
      'Road',
      'Mountain',
      'Hybrid',
      'Electric',
      'Kids',
      'BMX',
      'Other',
    ]),
    CategoryField('Frame size'),
    CategoryField('Wheel size', suffix: 'in'),
  ],
  'Books': [
    CategoryField('Format',
        choices: ['Paperback', 'Hardcover', 'Audiobook', 'eBook']),
    CategoryField('Genre'),
  ],
  'Jewelry & Accessories': [
    CategoryField('Type', choices: [
      'Ring',
      'Necklace',
      'Bracelet',
      'Earrings',
      'Watch',
      'Other',
    ]),
    CategoryField('Material'),
  ],
  'Watches': [
    CategoryField('Brand'),
    CategoryField('Movement',
        choices: ['Automatic', 'Quartz', 'Mechanical', 'Smart']),
  ],
  'Musical Instruments': [
    CategoryField('Type', choices: [
      'Guitar',
      'Keyboard',
      'Drums',
      'Wind',
      'String',
      'DJ / Studio',
      'Other',
    ]),
    CategoryField('Brand'),
  ],
  'Sports': [
    CategoryField('Sport'),
    CategoryField('For', choices: ['Adult', 'Youth', 'Kids']),
  ],
  'Baby & Kids': [
    CategoryField('Age group', choices: [
      'Newborn',
      '0–2 yrs',
      '3–5 yrs',
      '6–8 yrs',
      '9–12 yrs',
    ]),
    CategoryField('Type'),
  ],
  'Pet Supplies': [
    CategoryField('Pet', choices: [
      'Dog',
      'Cat',
      'Bird',
      'Fish',
      'Small pet',
      'Reptile',
      'Other',
    ]),
  ],
  // 2026-08-07: subcategories for the broad catch-all categories, so picking
  // one drills down instead of dumping everything under a single label — the
  // "expand each category" step. Each renders as a chip picker and rides on the
  // listing's attributes like every other per-category field.
  'Home & Garden': [
    CategoryField('Type', choices: [
      'Decor',
      'Lighting',
      'Rugs',
      'Bedding',
      'Storage',
      'Garden',
      'Outdoor',
      'Other',
    ]),
  ],
  'Tools & Home Improvement': [
    CategoryField('Type', choices: [
      'Power tools',
      'Hand tools',
      'Ladders',
      'Plumbing',
      'Electrical',
      'Paint',
      'Hardware',
      'Other',
    ]),
  ],
  'Beauty & Health': [
    CategoryField('Type', choices: [
      'Skincare',
      'Makeup',
      'Haircare',
      'Fragrance',
      'Grooming',
      'Wellness',
      'Other',
    ]),
  ],
  'Games & Toys': [
    CategoryField('Type', choices: [
      'Board games',
      'Puzzles',
      'Building sets',
      'Action figures',
      'Dolls',
      'Outdoor toys',
      'Educational',
      'Other',
    ]),
  ],
  'Kitchen & Dining': [
    CategoryField('Type', choices: [
      'Cookware',
      'Bakeware',
      'Appliances',
      'Dinnerware',
      'Cutlery',
      'Storage',
      'Other',
    ]),
  ],
  'Home Decor': [
    CategoryField('Type', choices: [
      'Wall art',
      'Mirrors',
      'Vases',
      'Candles',
      'Clocks',
      'Plants',
      'Cushions',
      'Other',
    ]),
  ],
  'Fitness & Gym': [
    CategoryField('Type', choices: [
      'Weights',
      'Cardio machine',
      'Yoga',
      'Bench / rack',
      'Accessories',
      'Apparel',
      'Other',
    ]),
  ],
  'Camping & Outdoors': [
    CategoryField('Type', choices: [
      'Tents',
      'Sleeping bags',
      'Backpacks',
      'Cooking',
      'Hiking',
      'Fishing',
      'Climbing',
      'Other',
    ]),
  ],
  'Art & Collectibles': [
    CategoryField('Type', choices: [
      'Painting',
      'Print',
      'Sculpture',
      'Coins',
      'Stamps',
      'Memorabilia',
      'Other',
    ]),
  ],
  'Bags & Luggage': [
    CategoryField('Type', choices: [
      'Handbag',
      'Backpack',
      'Suitcase',
      'Duffel',
      'Wallet',
      'Briefcase',
      'Other',
    ]),
  ],
  'Office & Business': [
    CategoryField('Type', choices: [
      'Desks',
      'Chairs',
      'Printers',
      'Supplies',
      'Storage',
      'Equipment',
      'Other',
    ]),
  ],
  'Auto Parts': [
    CategoryField('Type', choices: [
      'Wheels & tyres',
      'Engine',
      'Interior',
      'Exterior',
      'Electronics',
      'Lighting',
      'Other',
    ]),
  ],
  'Garden & Plants': [
    CategoryField('Type', choices: [
      'Plants',
      'Seeds',
      'Pots',
      'Tools',
      'Soil & compost',
      'Furniture',
      'Other',
    ]),
  ],
  'Trading Cards & Comics': [
    CategoryField('Type', choices: [
      'Trading cards',
      'Comics',
      'Graphic novels',
      'Sealed / packs',
      'Accessories',
      'Other',
    ]),
  ],
  'Health & Wellness': [
    CategoryField('Type', choices: [
      'Supplements',
      'Equipment',
      'Personal care',
      'Mobility aids',
      'Other',
    ]),
  ],
};

/// The extra fields for [category], or empty. Trims so a stray space never
/// misses the map.
List<CategoryField> categoryFieldsFor(String category) =>
    kCategoryFields[category.trim()] ?? const [];

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
  priceHigh('Price: high to low'),
  reduced('Price drops first');

  const ListingSort(this.label);
  final String label;
}

/// Whether [l]'s asking price is a drop from a higher "was" price that still
/// stands — the deal a bargain-hunter sorts for. Pure.
bool listingReduced(FeedPost l) => l.prevPriceCents > (l.priceCents ?? 0);

/// [listings] in [sort] order, with sold items sunk to the end whatever the
/// order — visible, but never ahead of something that can still be bought.
/// Pure, so the tie-breaking is testable: equal prices keep their newest-
/// first order instead of shuffling on every rebuild.
List<FeedPost> sortListings(List<FeedPost> listings, ListingSort sort) {
  final list = List<FeedPost>.of(listings)
    ..sort((a, b) => b.time.compareTo(a.time));
  if (sort == ListingSort.priceLow || sort == ListingSort.priceHigh) {
    // Stable merge sort via mergeSort semantics: List.sort is not stable, so
    // sort by price on an already newest-first list using a comparator that
    // never returns 0 ties away — compare price, then time.
    list.sort((a, b) {
      final pa = a.priceCents ?? 0, pb = b.priceCents ?? 0;
      final byPrice =
          sort == ListingSort.priceLow ? pa.compareTo(pb) : pb.compareTo(pa);
      return byPrice != 0 ? byPrice : b.time.compareTo(a.time);
    });
  } else if (sort == ListingSort.reduced) {
    // Reduced ones float up (newest drop first); everything else keeps the
    // newest-first order behind them. The comparator ties back to time so it
    // stays stable rather than reshuffling equal rows on each rebuild.
    list.sort((a, b) {
      final ra = listingReduced(a), rb = listingReduced(b);
      if (ra != rb) return ra ? -1 : 1;
      return b.time.compareTo(a.time);
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

/// Whether [l] matches a typed search. Pure so a test can pin what counts.
///
/// The obvious fields — title + description, brand, pickup area — plus the two
/// that used to be invisible to search and made it feel broken: the CATEGORY
/// ("electronics", "furniture") and the structured per-category ATTRIBUTES
/// (model, storage, size…). A buyer who types "iphone" or "128gb" is naming
/// what the listing IS, and those live in the category/attributes, not always
/// in the prose.
bool listingMatchesQuery(FeedPost l, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return true;
  if (l.text.toLowerCase().contains(q) ||
      l.listingBrand.toLowerCase().contains(q) ||
      l.listingPlace.toLowerCase().contains(q) ||
      l.listingCategory.toLowerCase().contains(q)) {
    return true;
  }
  for (final v in l.listingAttributes.values) {
    if (v.toLowerCase().contains(q)) return true;
  }
  return false;
}

/// Whether [l]'s price sits inside a chosen range. Free counts as \$0, so
/// "under \$25" includes it. Pure.
bool listingInPriceRange(FeedPost l, {int? minCents, int? maxCents}) {
  final p = l.priceCents ?? 0;
  if (minCents != null && p < minCents) return false;
  if (maxCents != null && p > maxCents) return false;
  return true;
}

/// Whether a listing's place reads as being in the buyer's [area]. No GPS —
/// both are free text ("Toronto", "Toronto, ON", "downtown Toronto"), so this
/// is word-overlap: any shared token of two or more letters counts. Pure, so
/// the "Near you" filter is testable without a map.
bool listingNearArea(FeedPost l, String area) {
  final place = l.listingPlace.trim().toLowerCase();
  final home = area.trim().toLowerCase();
  if (place.isEmpty || home.isEmpty) return false;
  if (place.contains(home) || home.contains(place)) return true;
  final placeWords = place.split(RegExp(r'[^a-z0-9]+')).where((w) => w.length > 1);
  final homeWords =
      area.trim().toLowerCase().split(RegExp(r'[^a-z0-9]+')).where((w) => w.length > 1).toSet();
  return placeWords.any(homeWords.contains);
}

/// Title words → the category they usually mean. Most specific families
/// first, because the first hit wins ("bike" is Bikes before it is Sports).
/// Public so a test can hold every right-hand side to a real category.
const List<(String, List<String>)> kCategoryHints = [
  ('Bikes', ['bike', 'bicycle', 'ebike']),
  ('Phones & Tablets', ['iphone', 'phone', 'ipad', 'tablet', 'galaxy']),
  ('Computers', ['laptop', 'macbook', 'computer', 'monitor', 'keyboard']),
  ('TV & Audio', ['tv', 'speaker', 'headphones', 'soundbar', 'earbuds']),
  ('Cameras & Photo', ['camera', 'lens', 'gopro', 'tripod']),
  ('Video Games & Consoles', ['playstation', 'ps5', 'xbox', 'nintendo', 'console']),
  ('Musical Instruments', ['guitar', 'piano', 'violin', 'drums', 'amp']),
  ('Furniture', ['couch', 'sofa', 'table', 'desk', 'chair', 'dresser', 'bookshelf']),
  ('Appliances', ['fridge', 'freezer', 'washer', 'dryer', 'dishwasher', 'microwave', 'blender']),
  ('Motorcycles', ['motorcycle', 'scooter', 'moped']),
  ('Vehicles', ['car', 'truck', 'sedan', 'suv', 'van']),
  ('Baby & Kids', ['stroller', 'crib', 'bassinet']),
  ('Games & Toys', ['lego', 'toy', 'puzzle']),
  ('Books', ['book', 'novel', 'textbook']),
  ('Shoes', ['sneakers', 'boots', 'heels', 'sandals']),
  ('Clothing', ['jacket', 'coat', 'dress', 'jeans', 'hoodie', 'sweater']),
  ('Watches', ['watch', 'smartwatch']),
  ('Pet Supplies', ['aquarium', 'leash', 'litter']),
  ('Camping & Outdoors', ['tent', 'camping', 'cooler', 'hammock']),
  ('Tools & Home Improvement', ['drill', 'saw', 'ladder', 'toolbox', 'wrench']),
  ('Sports', ['skates', 'skis', 'snowboard', 'treadmill', 'dumbbells', 'kayak']),
];

/// A category guessed from the title's words — offered as a tappable hint
/// beside the picker, never applied by itself. Whole words only, so
/// "carpet" never reads as a car. Null when the words say nothing, which
/// is the answer most titles get. Pure, and not a model: a word table.
String? suggestCategory(String title) {
  final words = title
      .toLowerCase()
      .split(RegExp(r'[^a-z0-9]+'))
      .where((w) => w.isNotEmpty)
      .toSet();
  if (words.isEmpty) return null;
  for (final (category, keys) in kCategoryHints) {
    if (keys.any(words.contains)) return category;
  }
  return null;
}

/// The sell form's text fields as one draft blob, and back. Photos and
/// video are deliberately not kept: they are re-picked in seconds, and
/// base64 bytes would blow the drafts store's cap for nothing — the loss a
/// draft exists to prevent is the typed kind. Pure both ways; a garbage
/// blob decodes to null rather than a half-filled form.
String encodeSellDraft({
  required String title,
  required String description,
  required String price,
  required String wasPrice,
  required String brand,
  required String category,
  required String condition,
  required String delivery,
  required String quantity,
  required bool offers,
  required String place,
  required String communityId,
  Map<String, String> attributes = const {},
}) =>
    jsonEncode({
      'title': title,
      'description': description,
      'price': price,
      'was': wasPrice,
      'brand': brand,
      'category': category,
      'condition': condition,
      'delivery': delivery,
      'quantity': quantity,
      'offers': offers,
      'place': place,
      'community': communityId,
      if (attributes.isNotEmpty) 'attributes': attributes,
    });

Map<String, dynamic>? decodeSellDraft(String raw) {
  if (raw.trim().isEmpty) return null;
  try {
    final data = jsonDecode(raw);
    return data is Map<String, dynamic> ? data : null;
  } catch (_) {
    return null;
  }
}

/// The pickup area of this seller's most recent listing that named one —
/// what the place field starts as on a NEW listing, because where you
/// hand things over rarely changes between sales. Prefilled, editable,
/// clearable; never invented. Pure.
String lastOwnListingPlace(List<FeedPost> all, String myUsername) {
  final mine = [
    for (final l in all)
      if (l.isListing &&
          (l.authorUsername == 'you' ||
              (myUsername.isNotEmpty && l.authorUsername == myUsername)) &&
          l.listingPlace.trim().isNotEmpty)
        l
  ]..sort((a, b) => b.time.compareTo(a.time));
  return mine.firstOrNull?.listingPlace.trim() ?? '';
}

/// Move the photo at [index] to the front of [photos] so it becomes the
/// cover, keeping the order of the rest. Returns a new list — the input is
/// never mutated. An out-of-range or already-first index is a no-op copy.
/// Pure, so the "tap to set cover" behaviour is testable without a widget.
List<String> photosWithCover(List<String> photos, int index) {
  if (index <= 0 || index >= photos.length) return List<String>.of(photos);
  final next = List<String>.of(photos);
  next.insert(0, next.removeAt(index));
  return next;
}

/// The going rate for [category]: the median asking price across unsold,
/// non-free listings in it — or null with fewer than three to read,
/// because a "typical" of two is a coin toss dressed as a statistic.
/// [excludeId] keeps a listing's own price out of its own benchmark. Pure.
int? typicalPriceCents(List<FeedPost> all, String category,
    {String excludeId = ''}) {
  if (category.isEmpty) return null;
  final prices = [
    for (final l in all)
      if (l.isListing &&
          !l.listingSold &&
          l.id != excludeId &&
          l.listingCategory == category &&
          (l.priceCents ?? 0) > 0)
        l.priceCents!
  ]..sort();
  if (prices.length < 3) return null;
  final mid = prices.length ~/ 2;
  return prices.length.isOdd
      ? prices[mid]
      : (prices[mid - 1] + prices[mid]) ~/ 2;
}

/// Whether [l] asks well under the going rate — at or below 70% of the
/// category median. Arithmetic over listings this device can already see,
/// never a judgement about the item: free and sold listings never qualify,
/// and neither does anything in a category too thin to have a rate. Pure.
bool isBelowTypical(FeedPost l, List<FeedPost> all) {
  final price = l.priceCents ?? 0;
  if (price <= 0 || l.listingSold) return false;
  final typical =
      typicalPriceCents(all, l.listingCategory, excludeId: l.id);
  return typical != null && price * 10 <= typical * 7;
}

/// What the seller's drafted thank-you says when they name who bought a
/// listing. Drafted into the composer, never sent by itself — the seller
/// reads it before it leaves, like every other message. Pure.
String soldThanksDraft(FeedPost listing, {String? saleCode}) =>
    'Just marked "${listing.text.split('\n').first}" as sold to you — '
    'thanks! If you have a minute, you can rate the sale on the listing.'
    // The code rides the E2E chat and nowhere else; typed with the buyer's
    // review it marks it a confirmed purchase.
    '${saleCode == null ? '' : '\nYour sale code is $saleCode — type it '
        'with your review and it shows as a confirmed purchase.'}';

/// Marking sold optionally asks who bought it. A picked buyer gets their
/// chat opened with [soldThanksDraft] in the composer — which is also the
/// rating handshake: the buyer follows the sentence back to the listing,
/// where the review UI already lives. Dismissing the sheet changes
/// nothing; "Just mark sold" skips the naming.
Future<void> markListingSold(BuildContext context, FeedPost listing) async {
  final contacts = ChatStore.instance.reachableContacts();
  if (contacts.isEmpty) {
    FeedStore.instance.setListingSold(listing.id, true);
    return;
  }
  // (kind, buyer): 'skip' marks without naming, 'buyer' names one, and a
  // dismissed sheet returns null — backing out must change nothing.
  final choice = await showModalBottomSheet<(String, AppUser?)>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 4, 20, 4),
            child: Text('Who bought it?',
                style: TextStyle(fontSize: 16.5, fontWeight: FontWeight.w700)),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text(
              'Naming the buyer opens their chat with a thank-you typed '
              'for you — send it and they can rate the sale.',
              style: TextStyle(
                  fontSize: 12.5, color: AppColors.subtle(sheetContext)),
            ),
          ),
          for (final u in contacts)
            ListTile(
              leading: UserAvatar(user: u, radius: 20),
              title: Text(u.name, maxLines: 1, overflow: TextOverflow.ellipsis),
              onTap: () => Navigator.pop(sheetContext, ('buyer', u)),
            ),
          ListTile(
            leading: const Icon(Icons.check_circle_outline),
            title: const Text('Just mark sold'),
            onTap: () => Navigator.pop(sheetContext, ('skip', null)),
          ),
        ],
      ),
    ),
  );
  if (choice == null) return;
  FeedStore.instance.setListingSold(listing.id, true);
  final buyer = choice.$2;
  if (buyer == null || !context.mounted) return;
  // A named buyer gets a sale code with the thank-you: their review can
  // then wear the confirmed-purchase chip. "Just mark sold" mints none —
  // there is nobody to hand it to. The code is BOUND to this buyer's handle,
  // so only they (reviewing under it) can earn the chip — a code that leaks or
  // is handed to a friend confirms nobody.
  final saleCode =
      FeedStore.instance.mintSaleCode(listing.id, buyerHandle: buyer.username);
  final store = ChatStore.instance;
  final existing = store.chatWithContact(buyer.id);
  final Chat chat;
  if (existing != null) {
    if (existing.isArchived) store.setArchived(existing.id, false);
    chat = existing;
  } else {
    // Born marketplace: this conversation exists because of the sale, so it
    // files under the Marketplace section rather than among friends. An
    // existing chat above is left where it is for the same reason reversed.
    chat = Chat(
        id: 'chat_${buyer.id}',
        contact: buyer,
        messages: const [],
        marketplace: true);
    store.upsert(chat);
  }
  store.setDraft(chat.id, soldThanksDraft(listing, saleCode: saleCode));
  await Navigator.of(context).push(
    MaterialPageRoute(builder: (_) => ChatScreen(chat: chat)),
  );
}

/// The unsold listings [s] matches — the browse screen's own three filters
/// (words, category, price) re-run against a kept search. Pure, so a test
/// can pin that a saved search and a typed one agree about what matches.
List<FeedPost> savedSearchMatches(SavedSearch s, List<FeedPost> all) => [
      for (final l in all)
        if (!l.listingSold &&
            listingMatchesQuery(l, s.query) &&
            (s.category.isEmpty || l.listingCategory == s.category) &&
            listingInPriceRange(l, minCents: s.minCents, maxCents: s.maxCents))
          l
    ];

/// How many of [s]'s matches arrived after it was last looked at — the
/// number on the badge. Pure.
int savedSearchNewCount(SavedSearch s, List<FeedPost> all) => [
      for (final l in savedSearchMatches(s, all))
        if (l.time.isAfter(s.lastSeenAt)) l
    ].length;

/// The listing's seller as this device knows them — the business contact
/// whose handle matches the author, or null. Local knowledge only: the
/// storefront rides the sealed profile share, not the directory, so it can
/// only show for a seller this device has actually talked to. Honest
/// absence otherwise — never inferred from the listing itself.
AppUser? knownBusinessSeller(FeedPost listing) {
  final u = listing.authorUsername.trim().toLowerCase();
  if (u.isEmpty || u == 'you') return null;
  for (final chat in ChatStore.instance.allChats) {
    final c = chat.contact;
    if (!c.isGroup && c.isBusiness && c.username.toLowerCase() == u) {
      return c;
    }
  }
  return null;
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
    // Born marketplace — see ChatStore.marketplaceChats. Only at creation:
    // a friend you already talk to doesn't move sections because you asked
    // about their couch.
    chat = Chat(
        id: 'chat_${seller.id}',
        contact: seller,
        messages: const [],
        marketplace: true);
    store.upsert(chat);
  }
  if (opener.isNotEmpty && store.draftFor(chat.id).isEmpty) {
    store.setDraft(chat.id, opener);
  }
  await Navigator.of(context).push(
    MaterialPageRoute(builder: (_) => ChatScreen(chat: chat)),
  );
}

/// Resolves a listing's seller to an [AppUser] (with a phone to pay), the same
/// way [openSellerChat] does: a contact first, then the directory. Null when
/// the seller can't be reached — you can message but not pay them.
Future<AppUser?> _resolveSeller(String username) async {
  for (final c in ChatStore.instance.chats) {
    if (!c.contact.isGroup &&
        c.contact.username.toLowerCase() == username.toLowerCase()) {
      return c.contact;
    }
  }
  final resolve = debugResolveSellerOverride;
  if (resolve != null) return resolve(username);
  final matches = await AccountService.instance.searchByUsername(username);
  for (final u in matches) {
    if (u.username.toLowerCase() == username.toLowerCase()) return u;
  }
  return null;
}

/// Buy a listing: pay the seller its price, from the wallet balance or by card.
/// Opens the pay sheet once the seller is resolved to someone payable.
Future<void> buyListing(BuildContext context, FeedPost listing) async {
  final price = listing.priceCents ?? 0;
  if (price <= 0) {
    // A free listing has nothing to charge — message the seller instead.
    await messageSeller(context, listing);
    return;
  }
  final seller = await _resolveSeller(listing.authorName);
  if (!context.mounted) return;
  if (seller == null || seller.phone.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Couldn\'t reach the seller to pay them — '
            'message them to arrange it.')));
    return;
  }
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => _PayForListingSheet(listing: listing, seller: seller),
  );
}

/// The marketplace checkout sheet: the price, the wallet balance, and the two
/// ways to pay — straight from the balance, or by card.
class _PayForListingSheet extends StatefulWidget {
  final FeedPost listing;
  final AppUser seller;
  const _PayForListingSheet({required this.listing, required this.seller});

  @override
  State<_PayForListingSheet> createState() => _PayForListingSheetState();
}

class _PayForListingSheetState extends State<_PayForListingSheet> {
  bool _busy = false;
  WalletStatus? _wallet;

  @override
  void initState() {
    super.initState();
    PaymentService.instance.status().then((s) {
      if (mounted) setState(() => _wallet = s);
    }).catchError((_) {});
  }

  int get _price => widget.listing.priceCents ?? 0;
  String get _title => widget.listing.text.split('\n').first;

  Future<void> _pay({required bool fromWallet}) async {
    if (_busy) return;
    setState(() => _busy = true);
    final svc = PaymentService.instance;
    final messenger = ScaffoldMessenger.of(context);
    final nav = Navigator.of(context);
    try {
      final ok = fromWallet
          ? await svc.payFromWallet(
              toPhone: widget.seller.phone,
              amountCents: _price,
              note: _title)
          : await svc.sendMoney(
              toPhone: widget.seller.phone,
              amountCents: _price,
              note: _title);
      if (!mounted) return;
      setState(() => _busy = false);
      if (ok) {
        nav.pop();
        messenger.showSnackBar(SnackBar(
            content: Text('Paid ${formatListingPrice(_price)} to '
                '${widget.seller.name}.')));
      }
    } on PaymentException catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      messenger.showSnackBar(SnackBar(content: Text(_payError(e.code))));
    } catch (_) {
      if (!mounted) return;
      setState(() => _busy = false);
      messenger.showSnackBar(const SnackBar(
          content: Text('That payment didn\'t go through — try again.')));
    }
  }

  String _payError(String code) => switch (code) {
        'parental_locked' => 'Payments are turned off by parental controls.',
        'step_up_required' =>
          'This payment needs extra verification — send it from a chat '
              'with the seller.',
        'identity_required' =>
          'Verify your identity in the wallet before paying.',
        'not_enabled' =>
          'Paying from your wallet balance isn\'t switched on yet — pay '
              'another way.',
        'insufficient_balance' =>
          'Not enough in your wallet — top up, or pay another way.',
        _ => 'That payment didn\'t go through ($code).',
      };

  @override
  Widget build(BuildContext context) {
    final balance = _wallet?.availableCents ?? 0;
    final enough = balance >= _price;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
            20, 4, 20, 20 + MediaQuery.of(context).viewInsets.bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Buy ${_title.isEmpty ? 'this item' : _title}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 18, fontWeight: FontWeight.w800)),
            const SizedBox(height: 4),
            Text('${formatListingPrice(_price)} · to ${widget.seller.name}',
                style: TextStyle(color: AppColors.subtle(context))),
            const SizedBox(height: 18),
            FilledButton.icon(
              onPressed: (_busy || !enough) ? null : () => _pay(fromWallet: true),
              icon: const Icon(Icons.account_balance_wallet_outlined),
              style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(50)),
              label: Text(_wallet == null
                  ? 'Pay from wallet'
                  : enough
                      ? 'Pay ${formatListingPrice(_price)} from wallet '
                          '(${_wallet!.money(balance)})'
                      : 'Wallet balance too low (${_wallet!.money(balance)})'),
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: _busy ? null : () => _pay(fromWallet: false),
              icon: const Icon(Icons.credit_card),
              style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(50)),
              label: const Text('Pay another way'),
            ),
            if (_busy)
              const Padding(
                padding: EdgeInsets.only(top: 16),
                child: Center(child: CircularProgressIndicator()),
              ),
            const SizedBox(height: 8),
            Text(
              'You\'re paying the seller directly. Agree on handover in chat '
              'before you pay for anything you can\'t collect.',
              style:
                  TextStyle(fontSize: 11.5, color: AppColors.subtle(context)),
            ),
          ],
        ),
      ),
    );
  }
}

/// A Facebook-style marketplace: a GLOBAL board of for-sale listings.
///
/// A listing is published to a world-readable table (docs/public_market.sql) so
/// ANY account — including a brand-new one in no servers — sees the whole
/// marketplace, the way Facebook Marketplace or Craigslist work. It is plaintext
/// by the same rule as the public feed and forum: a listing is an advertisement,
/// its audience is everyone, so there is no key to seal it under. What stays
/// protected is the SELLER'S PHONE — the global row never carries it, and a
/// buyer reaches a seller by username (how the app already resolves one).
/// Listings are marketplace-only: they are NEVER sealed to a server feed —
/// every account finds them through the global marketplace.
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

  /// Free stuff only. Its own flag rather than a max of $0, because the
  /// price boxes read a typed 0 as "no bound" (blank means free there).
  bool _freeOnly = false;

  /// Ways to narrow — or filter OUT — what's shown. Conditions is a set so a
  /// buyer can keep "New" and "Like new" and drop the rest; delivery keeps
  /// only listings offering a way to get the thing; hide-sold clears the
  /// crossed-out ones a browser has scrolled past a hundred times.
  final Set<String> _conditions = {};
  String _delivery = '';
  bool _hideSold = false;

  /// "Near you": keep only listings whose place reads as the buyer's own area
  /// (their profile location). Text-matched, since listings carry no coords.
  bool _nearMe = false;
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

  /// Whether what is on screen is a search worth keeping — words, a
  /// category, or a price bound. Your-listings, Saved and sort are views,
  /// not searches; "new matches for 'sort by price'" means nothing.
  bool get _saveableSearch =>
      _query.trim().isNotEmpty ||
      _category.isNotEmpty ||
      _minCents != null ||
      _maxCents != null;

  void _saveCurrentSearch() {
    final saved = FeedStore.instance.addSavedSearch(
      query: _query,
      category: _category,
      minCents: _minCents,
      maxCents: _maxCents,
    );
    if (saved == null || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Search saved — new matches get a count on it.')));
  }

  /// Re-applies a kept search and restarts its badge from now.
  void _applySavedSearch(SavedSearch s) {
    FeedStore.instance.touchSavedSearch(s.id);
    setState(() {
      _search.text = s.query;
      _query = s.query;
      _searching = s.query.isNotEmpty;
      _category = s.category;
      _minPrice.text =
          s.minCents == null ? '' : SavedSearch.dollars(s.minCents!);
      _maxPrice.text =
          s.maxCents == null ? '' : SavedSearch.dollars(s.maxCents!);
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
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      FilterChip(
                        avatar: const Icon(Icons.redeem_outlined, size: 15),
                        label: const Text('Free only'),
                        visualDensity: VisualDensity.compact,
                        selected: _freeOnly,
                        onSelected: (v) {
                          setState(() => _freeOnly = v);
                          setSheet(() {});
                        },
                      ),
                      FilterChip(
                        avatar: const Icon(Icons.visibility_off_outlined,
                            size: 15),
                        label: const Text('Hide sold'),
                        visualDensity: VisualDensity.compact,
                        selected: _hideSold,
                        onSelected: (v) {
                          setState(() => _hideSold = v);
                          setSheet(() {});
                        },
                      ),
                      FilterChip(
                        avatar: const Icon(Icons.near_me_outlined, size: 15),
                        label: const Text('Near you'),
                        visualDensity: VisualDensity.compact,
                        selected: _nearMe,
                        onSelected: (v) {
                          setState(() => _nearMe = v);
                          setSheet(() {});
                        },
                      ),
                    ],
                  ),
                ),
                if (_nearMe && AppState.profile.value.location.trim().isEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: Text(
                        'Add your location in Edit profile to find listings '
                        'near you.',
                        style: TextStyle(
                            fontSize: 11.5, color: AppColors.subtle(context))),
                  )
                else if (_nearMe)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: Text('Near ${AppState.profile.value.location}',
                        style: TextStyle(
                            fontSize: 11.5, color: AppColors.subtle(context))),
                  ),
                const SizedBox(height: 4),
                const Divider(height: 1),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Text('CONDITION',
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.6,
                          color: AppColors.subtle(context))),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final c in kListingConditions)
                        FilterChip(
                          label: Text(c),
                          visualDensity: VisualDensity.compact,
                          selected: _conditions.contains(c),
                          onSelected: (on) {
                            setState(() {
                              if (on) {
                                _conditions.add(c);
                              } else {
                                _conditions.remove(c);
                              }
                            });
                            setSheet(() {});
                          },
                        ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Text('DELIVERY',
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.6,
                          color: AppColors.subtle(context))),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final (value, label) in kListingDeliveryOptions)
                        ChoiceChip(
                          label: Text(label),
                          visualDensity: VisualDensity.compact,
                          selected: _delivery == value,
                          onSelected: (_) {
                            setState(() =>
                                _delivery = _delivery == value ? '' : value);
                            setSheet(() {});
                          },
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
    // No server required any more: a listing goes to the global marketplace, so
    // anyone with the app can find it whether or not you share any servers.
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
        _freeOnly ||
        _conditions.isNotEmpty ||
        _delivery.isNotEmpty ||
        _hideSold ||
        _nearMe ||
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
          // The wishlist. Saving is local, so it's offered on the browse-only
          // path too. The badge counts saved items whose price just dropped —
          // the reason to look now rather than later.
          Builder(builder: (context) {
            final drops = FeedStore.instance.savedPriceDrops().length;
            return IconButton(
              icon: Badge(
                isLabelVisible: drops > 0,
                label: Text('$drops'),
                child: const Icon(Icons.bookmark_border),
              ),
              tooltip: 'Saved',
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => const SavedListingsScreen())),
            );
          }),
          // The seller hub. Withheld browse-only for the Sell button's
          // reason: a numberless account has nothing there to manage.
          if (!browseOnly)
            IconButton(
              icon: const Icon(Icons.inventory_2_outlined),
              tooltip: 'Your listings',
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => const MyListingsScreen())),
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
      // The app's bottom navigation, so the marketplace is a first-class tab
      // like the newsfeed — tapping a destination jumps back into the home
      // shell. The non-personalized ad banner rides above it (this surface is
      // already world-facing commerce; zero height until an ad really loads).
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const AdBannerSlot(),
          ListenableBuilder(
            listenable: AppBottomNavBar.badgeListenable,
            builder: (context, _) => AppBottomNavBar(
              index: -1,
              missedCalls: AppBottomNavBar.missedCallsNow,
              activityCount: AppBottomNavBar.activityCountNow,
              onSelect: (i) => HomeScreen.goToTab(context, i),
            ),
          ),
        ],
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
          if (_freeOnly) {
            listings = [
              for (final l in listings)
                if ((l.priceCents ?? 0) == 0) l
            ];
          }
          if (_conditions.isNotEmpty) {
            listings = [
              for (final l in listings)
                if (_conditions.contains(l.listingCondition)) l
            ];
          }
          if (_delivery.isNotEmpty) {
            listings = [
              for (final l in listings)
                if (l.listingDelivery == _delivery) l
            ];
          }
          if (_hideSold) {
            listings = [
              for (final l in listings)
                if (!l.listingSold) l
            ];
          }
          if (_nearMe) {
            final area = AppState.profile.value.location;
            listings = [
              for (final l in listings)
                if (listingNearArea(l, area)) l
            ];
          }
          // Sorted, with sold sunk to the end rather than hidden — a buyer
          // mid-conversation can still find one.
          listings = sortListings(listings, _sort);
          // Price drops on SAVED listings — the one change a saver is
          // waiting for. Tapping applies the Saved filter, where the
          // struck-through old price is already drawn.
          final drops = FeedStore.instance.savedPriceDrops();
          final recents = FeedStore.instance.recentlyViewed();
          final browsing = !hasFilter && q.isEmpty;
          // The categories that actually have something in them, most-stocked
          // first — a browse strip that never opens on an empty aisle.
          final catCounts = <String, int>{};
          for (final l in FeedStore.instance.listings()) {
            if (l.listingCategory.isNotEmpty) {
              catCounts[l.listingCategory] =
                  (catCounts[l.listingCategory] ?? 0) + 1;
            }
          }
          final browseCats = catCounts.keys.toList()
            ..sort((a, b) => catCounts[b]!.compareTo(catCounts[a]!));
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (browsing && browseCats.length >= 2) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
                  child: Text('Browse',
                      style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                          color: AppColors.subtle(context))),
                ),
                SizedBox(
                  height: 38,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    children: [
                      for (final c in browseCats)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: ActionChip(
                            avatar: Icon(marketplaceCategoryIcon(c), size: 16),
                            label: Text('$c · ${catCounts[c]}'),
                            visualDensity: VisualDensity.compact,
                            onPressed: () =>
                                setState(() => _category = c),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
              if (browsing && drops.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                  child: Material(
                    color: Theme.of(context)
                        .colorScheme
                        .primaryContainer
                        .withValues(alpha: 0.55),
                    borderRadius: BorderRadius.circular(12),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () => setState(() => _savedOnly = true),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 10),
                        child: Row(
                          children: [
                            const Icon(Icons.trending_down, size: 18),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                drops.length == 1
                                    ? 'Price drop on a listing you saved'
                                    : 'Price drops on ${drops.length} '
                                        'listings you saved',
                                style: const TextStyle(
                                    fontSize: 13.5,
                                    fontWeight: FontWeight.w600),
                              ),
                            ),
                            const Icon(Icons.chevron_right, size: 18),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              // What you looked at, one tap back to it. Only while
              // browsing clean — a filter means you are looking for
              // something, not for where you have been.
              if (browsing && recents.length >= 2) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
                  child: Text('Recently viewed',
                      style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                          color: AppColors.subtle(context))),
                ),
                SizedBox(
                  height: 150,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    children: [
                      for (final l in recents)
                        Padding(
                          padding: const EdgeInsets.only(right: 10),
                          child: _MiniListingCard(listing: l),
                        ),
                    ],
                  ),
                ),
              ],
              // Kept searches, one tap back into each — with a count of
              // what arrived since the last look. Browsing clean only,
              // like the shelves above: mid-search they would be noise.
              if (browsing &&
                  FeedStore.instance.savedSearches.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                  child: Wrap(
                    spacing: 6,
                    children: [
                      for (final s in FeedStore.instance.savedSearches)
                        Builder(builder: (context) {
                          final fresh = savedSearchNewCount(
                              s, FeedStore.instance.listings());
                          return InputChip(
                            avatar: Icon(
                                fresh > 0
                                    ? Icons.notifications_active_outlined
                                    : Icons.saved_search,
                                size: 15),
                            label: Text(
                                fresh > 0 ? '${s.label} · $fresh new' : s.label,
                                style: TextStyle(
                                    fontWeight: fresh > 0
                                        ? FontWeight.w700
                                        : FontWeight.w400)),
                            visualDensity: VisualDensity.compact,
                            onPressed: () => _applySavedSearch(s),
                            onDeleted: () =>
                                FeedStore.instance.removeSavedSearch(s.id),
                          );
                        }),
                    ],
                  ),
                ),
              // Active filters only. When nothing is filtered, nothing is
              // here — the grid starts at the top. (Plus the save chip
              // whenever what is on screen is a search worth keeping.)
              if (hasFilter || _saveableSearch)
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
                      if (_freeOnly)
                        InputChip(
                          avatar: const Icon(Icons.redeem_outlined, size: 15),
                          label: const Text('Free'),
                          visualDensity: VisualDensity.compact,
                          onDeleted: () =>
                              setState(() => _freeOnly = false),
                        ),
                      if (_category.isNotEmpty)
                        InputChip(
                          label: Text(_category),
                          visualDensity: VisualDensity.compact,
                          onDeleted: () =>
                              setState(() => _category = ''),
                        ),
                      for (final c in _conditions)
                        InputChip(
                          avatar: const Icon(Icons.grade_outlined, size: 15),
                          label: Text(c),
                          visualDensity: VisualDensity.compact,
                          onDeleted: () =>
                              setState(() => _conditions.remove(c)),
                        ),
                      if (_delivery.isNotEmpty)
                        InputChip(
                          avatar:
                              const Icon(Icons.local_shipping_outlined, size: 15),
                          label: Text(listingDeliveryLabel(_delivery)),
                          visualDensity: VisualDensity.compact,
                          onDeleted: () => setState(() => _delivery = ''),
                        ),
                      if (_hideSold)
                        InputChip(
                          avatar: const Icon(Icons.visibility_off_outlined,
                              size: 15),
                          label: const Text('Hide sold'),
                          visualDensity: VisualDensity.compact,
                          onDeleted: () => setState(() => _hideSold = false),
                        ),
                      if (_nearMe)
                        InputChip(
                          avatar: const Icon(Icons.near_me_outlined, size: 15),
                          label: const Text('Near you'),
                          visualDensity: VisualDensity.compact,
                          onDeleted: () => setState(() => _nearMe = false),
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
                      if (_saveableSearch)
                        ActionChip(
                          avatar:
                              const Icon(Icons.bookmark_add_outlined, size: 15),
                          label: const Text('Save search'),
                          visualDensity: VisualDensity.compact,
                          onPressed: _saveCurrentSearch,
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

/// The wishlist as its own screen — everything you bookmarked, in one grid,
/// instead of a filter buried behind the funnel. Price-dropped saves float to
/// the top under a banner, because a drop is the reason to reopen this at all;
/// sold ones stay but sink, dimmed by the card itself.
class SavedListingsScreen extends StatelessWidget {
  const SavedListingsScreen({super.key});

  String _serverName(String id) {
    for (final c in CommunityStore.instance.communities) {
      if (c.id == id) return c.name;
    }
    return '';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Saved')),
      body: ListenableBuilder(
        listenable: FeedStore.instance,
        builder: (context, _) {
          final saved = FeedStore.instance.savedListings();
          // Reduced-and-still-for-sale first, then the rest newest-first, then
          // sold at the very back — the order a saver scans.
          saved.sort((a, b) {
            int rank(FeedPost p) {
              if (p.listingSold) return 2;
              return listingReduced(p) ? 0 : 1;
            }

            final byRank = rank(a).compareTo(rank(b));
            return byRank != 0 ? byRank : b.time.compareTo(a.time);
          });
          final drops = FeedStore.instance.savedPriceDrops();
          if (saved.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 40),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.bookmark_border,
                        size: 52, color: Colors.grey.shade400),
                    const SizedBox(height: 14),
                    const Text('Nothing saved yet',
                        style: TextStyle(
                            fontSize: 17, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 8),
                    Text(
                      'Tap the bookmark on a listing to keep it here. You\'ll '
                      'see it if the price drops.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          color: AppColors.subtle(context), fontSize: 14),
                    ),
                  ],
                ),
              ),
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (drops.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
                  child: Material(
                    color: Theme.of(context)
                        .colorScheme
                        .primaryContainer
                        .withValues(alpha: 0.55),
                    borderRadius: BorderRadius.circular(12),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 10),
                      child: Row(
                        children: [
                          const Icon(Icons.trending_down, size: 18),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              drops.length == 1
                                  ? 'Price drop on 1 saved listing'
                                  : 'Price drops on ${drops.length} saved '
                                      'listings',
                              style: const TextStyle(
                                  fontSize: 13.5, fontWeight: FontWeight.w600),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              Expanded(
                child: GridView.builder(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
                  gridDelegate:
                      const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    mainAxisSpacing: 10,
                    crossAxisSpacing: 10,
                    childAspectRatio: 0.72,
                  ),
                  itemCount: saved.length,
                  itemBuilder: (context, i) => _ListingCard(
                    listing: saved[i],
                    serverName: _serverName(saved[i].communityId),
                    onTap: () => Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) =>
                            ListingScreen(listingId: saved[i].id))),
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
                  const Positioned(left: 8, top: 8, child: _SoldBadge())
                else if (listing.listingReserved)
                  const Positioned(left: 8, top: 8, child: _ReservedBadge()),
                // Condition as a real badge, not buried in the subtitle line —
                // it's the second thing a buyer scans after the price. Hidden
                // on a sold tile, where nothing on it is for sale anymore.
                if (!listing.listingSold &&
                    listing.listingCondition.isNotEmpty)
                  Positioned(
                    left: 8,
                    bottom: 8,
                    child: _ConditionBadge(listing.listingCondition),
                  ),
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
              ]
              // An ask well under the category's median — arithmetic over
              // what this device can see, not a judgement about the item.
              // Never beside the strikethrough: one price story per card.
              else if (isBelowTypical(
                  listing, FeedStore.instance.listings())) ...[
                const SizedBox(width: 6),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(
                    color: const Color(0xFF00BA7C).withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(5),
                  ),
                  child: const Text('below typical',
                      style: TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF00875A))),
                ),
              ],
            ],
          ),
          Text(title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13.5)),
          // Place — what a buyer scans for after the price (condition now
          // rides as a badge on the photo). Falls back to the server name
          // when a listing carries no place.
          Builder(builder: (context) {
            final subtle = AppColors.subtle(context);
            final bits = [
              if (listing.listingPlace.isEmpty && serverName.isNotEmpty)
                serverName,
            ];
            final hasPlace = listing.listingPlace.isNotEmpty;
            if (!hasPlace && bits.isEmpty) return const SizedBox.shrink();
            return Row(
              children: [
                if (hasPlace) ...[
                  Icon(Icons.place_outlined, size: 11.5, color: subtle),
                  const SizedBox(width: 2),
                  Flexible(
                    child: Text(listing.listingPlace,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 11.5, color: subtle)),
                  ),
                  if (bits.isNotEmpty)
                    Text(' · ', style: TextStyle(fontSize: 11.5, color: subtle)),
                ],
                if (bits.isNotEmpty)
                  Flexible(
                    child: Text(bits.join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 11.5, color: subtle)),
                  ),
              ],
            );
          }),
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

  /// The listing's category attributes as (label, value) rows in the order
  /// the category's field spec lists them — so a property always reads
  /// type, then beds, then baths, not whatever order a map happened to
  /// hash into. Any attribute not in the spec (an older field, a category
  /// change) is appended after, so nothing an old listing carries is lost.
  List<(String, String)> _orderedAttributes(FeedPost listing) {
    final attrs = listing.listingAttributes;
    if (attrs.isEmpty) return const [];
    final rows = <(String, String)>[];
    final seen = <String>{};
    for (final f in categoryFieldsFor(listing.listingCategory)) {
      final v = attrs[f.label];
      if (v != null && v.trim().isNotEmpty) {
        rows.add((
          f.label,
          f.suffix.isEmpty ? v : '$v ${f.suffix}',
        ));
        seen.add(f.label);
      }
    }
    for (final e in attrs.entries) {
      if (!seen.contains(e.key) && e.value.trim().isNotEmpty) {
        rows.add((e.key, e.value));
      }
    }
    return rows;
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
        // After the frame, not during it: noteViewed notifies listeners,
        // and this very builder is one of them. Repeat frames no-op — the
        // id is already at the front of the shelf. recordPostView rides
        // along: a listing is a post, so an open here is the same
        // once-per-member view tally the feeds keep, and it is what the
        // seller hub's "viewers" number honestly is.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          FeedStore.instance.noteViewed(listing.id);
          FeedStore.instance.recordPostView(listing.id);
        });
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
                          onPressed: () => listing.listingSold
                              ? FeedStore.instance
                                  .setListingSold(listing.id, false)
                              : markListingSold(context, listing),
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
                      // Bump: only once the listing has sat 48 hours, so
                      // the button can't be a spam lever.
                      if (FeedStore.instance.canBumpListing(listing.id)) ...[
                        const SizedBox(width: 10),
                        Tooltip(
                          message: 'Bump to the top',
                          child: OutlinedButton(
                            onPressed: () {
                              FeedStore.instance.bumpListing(listing.id);
                              ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                      content: Text(
                                          'Bumped — back at the top of the '
                                          'marketplace.')));
                            },
                            style: OutlinedButton.styleFrom(
                                minimumSize: const Size(52, 48),
                                padding: EdgeInsets.zero),
                            child: const Icon(Icons.trending_up, size: 20),
                          ),
                        ),
                      ],
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
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Buy is the primary action on a priced, unsold item —
                      // pay the seller from your wallet or by card. Message and
                      // Offer sit below it.
                      if ((listing.priceCents ?? 0) > 0 &&
                          !listing.listingSold) ...[
                        FilledButton.icon(
                          onPressed: () => buyListing(context, listing),
                          icon: const Icon(Icons.shopping_bag_outlined,
                              size: 18),
                          label: Text(
                              'Buy · ${formatListingPrice(listing.priceCents!)}'),
                          style: FilledButton.styleFrom(
                              minimumSize: const Size.fromHeight(48)),
                        ),
                        const SizedBox(height: 8),
                      ],
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: () => messageSeller(context, listing),
                              icon: const Icon(Icons.chat_bubble_outline,
                                  size: 18),
                              label: Text('Message ${listing.authorName}'),
                              style: OutlinedButton.styleFrom(
                                  minimumSize: const Size.fromHeight(48)),
                            ),
                          ),
                          // Only when the seller said offers are welcome, and
                          // never on something already sold.
                          if (listing.listingOffers &&
                              !listing.listingSold) ...[
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
                  reserved: listing.listingReserved,
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
                        // Buyer-facing social proof: how many have looked. Was
                        // a seller-only number until now. Omitted at zero so a
                        // just-posted listing doesn't advertise its own quiet.
                        if (listing.views > 0)
                          '${listing.views} '
                              '${listing.views == 1 ? "view" : "views"}',
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
                    // The category-specific spec — bedrooms, mileage, rent
                    // period — as a two-column table, in the order the sell
                    // form asked. Only the fields that were answered.
                    if (_orderedAttributes(listing).isNotEmpty) ...[
                      const SizedBox(height: 14),
                      _AttributeTable(rows: _orderedAttributes(listing)),
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
                                if (!mine &&
                                    knownBusinessSeller(listing) !=
                                        null) ...[
                                  const SizedBox(width: 4),
                                  Icon(Icons.storefront_outlined,
                                      size: 14,
                                      color: AppColors.subtle(context)),
                                ],
                              ],
                            ),
                            // What this device can honestly vouch for: the
                            // ID check rides the listing as authorVerified,
                            // and a phone number is only ever on a listing
                            // when the account signed in with one. Email
                            // is deliberately absent — nothing the listing
                            // carries proves it, and a chip that guesses
                            // is worse than no chip.
                            if (!mine &&
                                (listing.authorVerified ||
                                    listing.authorPhone.isNotEmpty))
                              Padding(
                                padding: const EdgeInsets.only(top: 2),
                                child: Wrap(
                                  spacing: 6,
                                  children: [
                                    if (listing.authorVerified)
                                      const _SellerChip(label: 'ID verified'),
                                    if (listing.authorPhone.isNotEmpty)
                                      const _SellerChip(
                                          label: 'Phone verified'),
                                  ],
                                ),
                              ),
                            Builder(builder: (context) {
                              final (avg, count) = FeedStore.instance
                                  .sellerRating(listing.authorUsername);
                              if (count == 0) {
                                // A known business seller's category says
                                // more than a bare handle.
                                final biz =
                                    mine ? null : knownBusinessSeller(listing);
                                final category =
                                    biz?.businessCategory.trim() ?? '';
                                return !mine &&
                                        listing.authorUsername.isNotEmpty &&
                                        listing.authorUsername != 'you'
                                    ? Text(
                                        category.isEmpty
                                            ? '@${listing.authorUsername}'
                                            : '$category · '
                                                '@${listing.authorUsername}',
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

/// A business contact's shop, for their profile surfaces — as a BUTTON,
/// not an inline shelf: the strip squeezed between profile lines read as
/// clutter, and a profile is about the person first. The button says how
/// much is stocked and opens [SellerShopScreen]; it draws NOTHING when
/// the shop is empty, because an empty shelf would advertise an absence.
/// The listings are only what this device has already seen, matched by
/// handle — the same local honesty as [knownBusinessSeller].
class SellerShopButton extends StatelessWidget {
  final String username;
  final String sellerName;
  const SellerShopButton(
      {super.key, required this.username, this.sellerName = ''});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: FeedStore.instance,
      builder: (context, _) {
        final goods = FeedStore.instance.listingsBySeller(username);
        if (goods.isEmpty) return const SizedBox.shrink();
        final mine = username.trim().toLowerCase() ==
            AppState.profile.value.username.trim().toLowerCase();
        final accent = Theme.of(context).colorScheme.primary;
        return Padding(
          padding: const EdgeInsets.only(top: 10),
          child: OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              padding:
                  const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
              side: BorderSide(color: accent.withValues(alpha: 0.45)),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(22)),
            ),
            icon: const Icon(Icons.storefront_outlined, size: 18),
            label: Text(
                '${mine ? 'Your shop' : 'View shop'} · ${goods.length} '
                '${goods.length == 1 ? 'item' : 'items'}'),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => SellerShopScreen(
                    username: username, sellerName: sellerName))),
          ),
        );
      },
    );
  }
}

/// Everything a seller has up, full-size — the browse grid's own cards,
/// scoped to one handle.
class SellerShopScreen extends StatelessWidget {
  final String username;
  final String sellerName;
  const SellerShopScreen(
      {super.key, required this.username, this.sellerName = ''});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
          title: Text(
              sellerName.trim().isEmpty ? 'Shop' : '$sellerName\'s shop')),
      body: ListenableBuilder(
        listenable: FeedStore.instance,
        builder: (context, _) {
          final goods = FeedStore.instance.listingsBySeller(username);
          if (goods.isEmpty) {
            return Center(
              child: Text('Nothing for sale right now.',
                  style: TextStyle(color: AppColors.subtle(context))),
            );
          }
          return GridView.builder(
            padding: const EdgeInsets.all(12),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
              childAspectRatio: 0.72,
            ),
            itemCount: goods.length,
            itemBuilder: (context, i) => _ListingCard(
              listing: goods[i],
              serverName: '',
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => ListingScreen(listingId: goods[i].id))),
            ),
          );
        },
      ),
    );
  }
}

/// A quiet verification chip on the seller line: what the listing itself
/// proves, said in two words.
class _SellerChip extends StatelessWidget {
  final String label;
  const _SellerChip({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: const Color(0xFF12B76A).withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.check, size: 11, color: Color(0xFF12B76A)),
          const SizedBox(width: 3),
          Text(label,
              style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF12B76A))),
        ],
      ),
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
                    // The reviewer typed the sale code the seller handed
                    // over at the sale — this one really bought it.
                    if (r.confirmedPurchase)
                      const Padding(
                        padding: EdgeInsets.only(top: 3),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.verified_outlined,
                                size: 13, color: Color(0xFF12B76A)),
                            SizedBox(width: 4),
                            Text('Confirmed purchase',
                                style: TextStyle(
                                    fontSize: 11.5,
                                    fontWeight: FontWeight.w600,
                                    color: Color(0xFF12B76A))),
                          ],
                        ),
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
  final TextEditingController _code = TextEditingController();

  @override
  void dispose() {
    _text.dispose();
    _code.dispose();
    super.dispose();
  }

  /// Whether this listing minted a sale code at all — no code, no field:
  /// offering a box nothing could ever match would read as a broken form.
  bool get _codeExists {
    final l = FeedStore.instance.postById(widget.listingId);
    return l != null && l.saleCodeHash.isNotEmpty;
  }

  bool get _codeMatches {
    final u = AppState.profile.value.username;
    return FeedStore.instance.saleCodeMatches(widget.listingId, _code.text,
        buyerHandle: u.isEmpty ? 'you' : u);
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
            if (_codeExists) ...[
              const SizedBox(height: 4),
              TextField(
                controller: _code,
                keyboardType: TextInputType.number,
                maxLength: 6,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  hintText: 'Sale code (optional)',
                  helperText: _code.text.trim().isEmpty
                      ? 'The seller sent it with the sale — it marks '
                          'yours a confirmed purchase.'
                      : (_codeMatches
                          ? '✓ Confirmed purchase'
                          : 'That code doesn\'t match this listing.'),
                ),
              ),
            ],
            const SizedBox(height: 4),
            FilledButton(
              // No stars, no review — the rating is the one required part.
              onPressed: _rating == 0
                  ? null
                  : () {
                      FeedStore.instance.addReview(widget.listingId,
                          rating: _rating,
                          text: _text.text,
                          saleCode: _code.text);
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
  final bool reserved;
  final String title;
  const _ListingGallery(
      {required this.photos,
      required this.sold,
      this.reserved = false,
      required this.title});

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
          const Positioned(left: 14, top: 14, child: _SoldBadge(large: true))
        else if (widget.reserved)
          const Positioned(
              left: 14, top: 14, child: _ReservedBadge(large: true)),
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

/// A small translucent condition pill for the corner of a listing photo.
/// "New" and "Like new" carry a green tint — the conditions a buyer hunts
/// for — while the rest stay neutral, so the colour means something.
class _ConditionBadge extends StatelessWidget {
  final String condition;
  const _ConditionBadge(this.condition);

  @override
  Widget build(BuildContext context) {
    final c = condition.toLowerCase();
    final fresh = c == 'new' || c == 'like new';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: (fresh ? const Color(0xFF00875A) : Colors.black)
            .withValues(alpha: fresh ? 0.86 : 0.6),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(condition,
          style: const TextStyle(
              color: Colors.white,
              fontSize: 10.5,
              fontWeight: FontWeight.w700)),
    );
  }
}

/// The amber RESERVED tag — an item on hold for a buyer but still in the
/// shop, so it reads as distinct from a finished SOLD sale.
class _ReservedBadge extends StatelessWidget {
  final bool large;
  const _ReservedBadge({this.large = false});

  @override
  Widget build(BuildContext context) => Container(
        padding: EdgeInsets.symmetric(
            horizontal: large ? 10 : 8, vertical: large ? 4 : 3),
        decoration: BoxDecoration(
          color: const Color(0xFFB25E00).withValues(alpha: 0.92),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text('RESERVED',
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

  /// Whether the category was actually picked (sheet, edit, draft, or the
  /// hint) rather than left on the default — the hint only offers itself
  /// while nobody has decided, because second-guessing a choice is nagging.
  late bool _categoryChosen = widget.existing != null;
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

  /// The category-specific answers, keyed by field label — one controller
  /// per free-text/number field, and [_attrChoices] for the chip pickers.
  /// Prefilled from an existing listing. Built lazily as fields render, so
  /// a category with no extra fields costs nothing.
  final Map<String, TextEditingController> _attrText = {};
  late final Map<String, String> _attrChoices = {
    ...?widget.existing?.listingAttributes,
  };

  TextEditingController _attrController(String label) =>
      _attrText.putIfAbsent(
          label,
          () => TextEditingController(
              text: widget.existing?.listingAttributes[label] ?? ''));

  /// The current answers as one map — text fields and chip picks together.
  Map<String, String> _collectAttributes() => {
        for (final f in categoryFieldsFor(_category))
          if (f.choices.isEmpty)
            f.label: _attrText[f.label]?.text ?? ''
          else
            f.label: _attrChoices[f.label] ?? '',
      };

  /// "It was \$X" — only offered while CREATING. On an edit the field
  /// would fight the automatic price-drop history updateListing keeps.
  final TextEditingController _wasPrice = TextEditingController();
  /// Up to [kMaxListingPhotos], cover first. Prefilled from the existing
  /// listing and its photo parts when editing.
  late final List<String> _photos = widget.existing == null
      ? []
      : FeedStore.instance.listingPhotos(widget.existing!.id);
  // A new listing has no server — the marketplace is global-only. An existing
  // listing keeps whatever id it had (harmless; it's never sealed to a server).
  late String _communityId = widget.existing?.communityId ?? '';

  /// The listing's current video: a bucket path when editing one that has a
  /// video, and freshly picked bytes waiting to upload on Post.
  late String _videoPath = widget.existing?.listingVideo ?? '';
  Uint8List? _videoBytes;
  bool _uploadingVideo = false;
  String? _error;

  /// True while the AI spam screen is running, so the Post button waits.
  bool _screening = false;

  @override
  void initState() {
    super.initState();
    if (widget.existing != null) return;
    // Where you hand things over rarely changes between sales.
    _place = lastOwnListingPlace(
        FeedStore.instance.listings(), AppState.profile.value.username);
    // A draft left behind comes back — the typed kind of loss is the one
    // a draft exists to prevent. It overrides the place prefill: what was
    // explicitly on the form beats what was inferred.
    final draft = decodeSellDraft(FeedDrafts.instance.read(FeedDrafts.sellKey));
    if (draft == null) return;
    _title.text = draft['title'] as String? ?? '';
    _description.text = draft['description'] as String? ?? '';
    _price.text = draft['price'] as String? ?? '';
    _wasPrice.text = draft['was'] as String? ?? '';
    _brand.text = draft['brand'] as String? ?? '';
    _quantity.text = draft['quantity'] as String? ?? '';
    final category = draft['category'] as String? ?? '';
    if (kMarketplaceCategories.contains(category)) {
      _category = category;
      _categoryChosen = true;
    }
    _condition = draft['condition'] as String? ?? '';
    _delivery = draft['delivery'] as String? ?? '';
    _offers = draft['offers'] == true;
    _place = draft['place'] as String? ?? _place;
    final attrs = draft['attributes'];
    if (attrs is Map) {
      for (final e in attrs.entries) {
        _attrChoices['${e.key}'] = '${e.value}';
      }
    }
    final community = draft['community'] as String? ?? '';
    if (CommunityStore.instance.communities.any((c) => c.id == community)) {
      _communityId = community;
    }
  }

  /// The form's text fields, kept. Called on the keep-draft path only.
  void _saveDraft() => FeedDrafts.instance.write(
        FeedDrafts.sellKey,
        encodeSellDraft(
          title: _title.text,
          description: _description.text,
          price: _price.text,
          wasPrice: _wasPrice.text,
          brand: _brand.text,
          category: _category,
          condition: _condition,
          delivery: _delivery,
          quantity: _quantity.text,
          offers: _offers,
          place: _place,
          communityId: _communityId,
          attributes: _collectAttributes(),
        ),
      );

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
      // The real cap, read from the file itself where it can be: refused
      // at pick time, not after an upload.
      final seconds = MarketMedia.videoDurationSeconds(bytes);
      if (seconds != null && seconds > MarketMedia.maxVideoSeconds) {
        setState(() => _error =
            'Videos can be up to ${MarketMedia.maxVideoSeconds} seconds — '
            'this one runs ${seconds.round()}s. Trim it and try again.');
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
    if (chosen != null && mounted) {
      setState(() {
        _category = chosen;
        _categoryChosen = true;
      });
    }
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
    for (final c in _attrText.values) {
      c.dispose();
    }
    _quantity.dispose();
    _description.dispose();
    super.dispose();
  }

  /// Promote the photo at [index] to the cover slot (front of the list).
  void _setCover(int index) {
    final next = photosWithCover(_photos, index);
    _photos
      ..clear()
      ..addAll(next);
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
        // Roomier than it was: a clearer gap above each heading so the form
        // reads as distinct, breathable sections rather than one dense column.
        padding: const EdgeInsets.only(top: 30, bottom: 10),
        child: Text(
          text.toUpperCase(),
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.8,
            color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.75),
          ),
        ),
      );

  /// The extra fields for the current category — a header plus one row per
  /// field, a chip picker for a choice list and a text/number box
  /// otherwise. Empty for a category that asks none.
  List<Widget> _categoryFieldWidgets(BuildContext context) {
    final fields = categoryFieldsFor(_category);
    if (fields.isEmpty) return const [];
    return [
      _section('$_category details'),
      for (final f in fields)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: f.choices.isEmpty
              ? TextField(
                  controller: _attrController(f.label),
                  keyboardType: f.numeric
                      ? const TextInputType.numberWithOptions(decimal: true)
                      : TextInputType.text,
                  textCapitalization: f.numeric
                      ? TextCapitalization.none
                      : TextCapitalization.sentences,
                  decoration: InputDecoration(
                      labelText: f.label,
                      suffixText: f.suffix.isEmpty ? null : f.suffix),
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6, left: 2),
                      child: Text(f.label,
                          style: TextStyle(
                              fontSize: 12.5,
                              color: AppColors.subtle(context))),
                    ),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final c in f.choices)
                          ChoiceChip(
                            label: Text(c),
                            selected: _attrChoices[f.label] == c,
                            onSelected: (on) => setState(() {
                              // Re-tapping the chosen chip clears it — an
                              // optional field the seller can leave blank.
                              if (on) {
                                _attrChoices[f.label] = c;
                              } else {
                                _attrChoices.remove(f.label);
                              }
                            }),
                          ),
                      ],
                    ),
                  ],
                ),
        ),
    ];
  }

  Future<void> _post() async {
    final title = _title.text.trim();
    if (title.isEmpty) {
      setState(() => _error = 'Give it a title.');
      return;
    }
    // The server's word filter guards its marketplace like its feed and its
    // channels — a rule that applies to posts but not price tags isn't one.
    // Told first: no point completing a listing the words already sink.
    final hit = CommunityStore.instance
        .filterHit(_communityId, '$title\n${_description.text}');
    if (hit != null) {
      setState(() =>
          _error = '"$hit" is blocked by this server\'s word filter.');
      return;
    }
    // A listing is a photo, a name and a description, or it is not a
    // listing — a grid tile with no picture sells nothing, and a title
    // with no sentences under it is a guess. (Edits included: an old bare
    // listing gets completed on its next edit rather than staying bare.)
    if (_photos.isEmpty) {
      setState(() => _error = 'Add at least one photo.');
      return;
    }
    if (_description.text.trim().isEmpty) {
      setState(() =>
          _error = 'Describe it — a sentence or two is enough.');
      return;
    }
    if (widget.existing == null) {
      final wait = FeedStore.instance.postCooldownLeft();
      if (wait > Duration.zero) {
        setState(() => _error =
            'Slow down — you can post again in ${wait.inSeconds}s.');
        return;
      }
    }
    final cents = parseListingPrice(_price.text);
    if (cents == null) {
      setState(() => _error = 'That price doesn\'t look like a number.');
      return;
    }
    // No server needed: an empty _communityId lists to the global marketplace
    // only. If you are in a server it also rides that server's feed.
    // AI speed bump: the SAME hosted screener the public feed uses, run on the
    // listing's words before it goes up, so a spammy listing is caught at the
    // one moment its text is legible — on this device, at post time (the sealed
    // copy on the server can never be read). It FAILS OPEN (offline, not
    // deployed, a slow model) and, like the feed, is a speed bump not a gate —
    // real enforcement is still reports and takedowns.
    setState(() {
      _error = null;
      _screening = true;
    });
    final blocked = await PublicFeedStore.instance
        .screen('$title\n${_description.text}');
    if (!mounted) return;
    setState(() => _screening = false);
    if (blocked != null) {
      setState(() => _error = blocked.contains('public feed')
          ? 'That listing looks like spam or breaks the marketplace rules.'
          : blocked);
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
        attributes: _collectAttributes(),
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
        attributes: _collectAttributes(),
        prevPriceCents: parseListingPrice(_wasPrice.text) ?? 0,
      );
      // Posted — the draft's job is done, and the brake stamps.
      FeedDrafts.instance.clear(FeedDrafts.sellKey);
      FeedStore.instance.noteAuthored();
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

  /// The video slot. FREE to the seller — the owner's call (2026-08-04):
  /// listing media never bills the person selling. What keeps that
  /// affordable is the pair of caps (30 seconds, 12 MB), not a paywall.
  Widget _videoTile(BuildContext context) {
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
    return OutlinedButton.icon(
      onPressed: _pickVideo,
      icon: const Icon(Icons.videocam_outlined, size: 18),
      label: const Text('Add a video (up to 30 seconds)'),
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
      // An untouched form may still be a RESTORED draft the person came
      // back to look at — leaving keeps it, same as it was.
      Navigator.of(context).pop();
      return;
    }
    // A new listing is kept, not defended: the typed fields survive as a
    // draft unless the person says throw them away. Photos and video are
    // not in the draft (re-picked in seconds; the bytes would not fit).
    if (widget.existing == null) {
      final choice = await showModalBottomSheet<String>(
        context: context,
        showDragHandle: true,
        builder: (sheetContext) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.save_outlined),
                title: const Text('Keep as draft'),
                subtitle: const Text(
                    'What you typed comes back next time — photos don\'t'),
                onTap: () => Navigator.pop(sheetContext, 'keep'),
              ),
              ListTile(
                leading: Icon(Icons.delete_outline,
                    color: Colors.red.shade400),
                title: Text('Discard',
                    style: TextStyle(color: Colors.red.shade400)),
                onTap: () => Navigator.pop(sheetContext, 'discard'),
              ),
            ],
          ),
        ),
      );
      if (!mounted || choice == null) return;
      if (choice == 'keep') {
        _saveDraft();
      } else {
        FeedDrafts.instance.clear(FeedDrafts.sellKey);
      }
      Navigator.of(context).pop();
      return;
    }
    final discard = await showAppConfirmDialog(
      context,
      icon: Icons.delete_outline,
      title: 'Discard changes?',
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
                onPressed:
                    (value.text.trim().isEmpty || _screening) ? null : _post,
                style: FilledButton.styleFrom(shape: const StadiumBorder()),
                child: _screening
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : Text(widget.existing == null ? 'Post' : 'Save'),
              ),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(18, 10, 18, 44),
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
          _section('Photos'),
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
                        // Tapping a photo that isn't the cover promotes it —
                        // the one interaction the "Cover" badge implied but
                        // nothing offered, so a better shot no longer means
                        // deleting the lot and re-adding in order.
                        GestureDetector(
                          onTap: i == 0
                              ? null
                              : () => setState(
                                  () => _setCover(i)),
                          child: ClipRRect(
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
          if (_photos.length > 1)
            Padding(
              padding: const EdgeInsets.only(top: 8, left: 2),
              child: Text('Tap a photo to make it the cover.',
                  style: TextStyle(
                      fontSize: 12, color: AppColors.subtle(context))),
            ),
          _section('What it is'),
          TextField(
            controller: _title,
            textCapitalization: TextCapitalization.sentences,
            // The title carries the listing, so it reads a size up.
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
            decoration: const InputDecoration(hintText: 'What are you selling?'),
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
          // A guess from the title's words — a word table, not a model —
          // offered while nobody has picked, applied only by the tap.
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: _title,
            builder: (context, value, _) {
              final s = _categoryChosen ? null : suggestCategory(value.text);
              if (s == null || s == _category) return const SizedBox.shrink();
              return Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: ActionChip(
                    avatar: const Icon(Icons.category_outlined, size: 15),
                    label: Text('Looks like $s'),
                    visualDensity: VisualDensity.compact,
                    onPressed: () => setState(() {
                      _category = s;
                      _categoryChosen = true;
                    }),
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _price,
            keyboardType:
                const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
                hintText: 'Free',
                labelText: 'Price',
                prefixText: '\$ ',
                // The going rate, when the category has one to read —
                // a fact about visible listings, never advice.
                helperText: () {
                  final typical = typicalPriceCents(
                      FeedStore.instance.listings(), _category,
                      excludeId: widget.existing?.id ?? '');
                  return typical == null
                      ? null
                      : '$_category listings here ask about '
                          '${formatListingPrice(typical)}';
                }()),
          ),
          // The category-specific questions — bedrooms and rent period for
          // a property, mileage and year for a car. Rebuilt when the
          // category changes, so switching from Furniture to Vehicles swaps
          // the whole set. Absent for categories that ask none.
          ..._categoryFieldWidgets(context),
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
          // Who will see this. A listing goes to the GLOBAL marketplace only —
          // never a server feed — so anyone on Okay can find it.
          Row(
            children: [
              Icon(Icons.public, size: 16, color: AppColors.subtle(context)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Anyone on Okay can find this in the marketplace.',
                  style: TextStyle(
                      fontSize: 12.5, color: AppColors.subtle(context)),
                ),
              ),
            ],
          ),
          // The details, laid out in the open rather than folded behind a
          // button — roomier and easier to fill. Everything here posts fine
          // left blank.
          const SizedBox(height: 6),
          ...[
            _section('More details'),
            TextField(
              controller: _brand,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                  labelText: 'Brand (optional)',
                  hintText: 'Apple, IKEA, Trek…'),
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
            if (widget.existing == null) ...[
              const SizedBox(height: 14),
              // What it USED to cost — drawn struck-through on the card,
              // and only while it is higher than the ask.
              TextField(
                controller: _wasPrice,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(
                    labelText: 'Was (optional)', prefixText: '\$ '),
              ),
            ],
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
            const SizedBox(height: 14),
            Align(
              alignment: Alignment.centerLeft,
              child: Text('Handoff',
                  style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      color: AppColors.subtle(context))),
            ),
            const SizedBox(height: 6),
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
            // Where it is. A NAME, never coordinates: this rides the relay
            // to everyone in the server, and "Bloor & Bathurst" is what a
            // buyer needs while a lat/lng to five decimals is somebody's
            // front door.
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
            const SizedBox(height: 14),
            _videoTile(context),
          ],
        ],
      ),
    );
  }
}

/// One seller, whole: who they are, how they've been rated, everything they
/// have for sale that this device can see. Where the trust question — "who
/// am I buying from?" — gets its one-screen answer.
/// A seller's marketplace profile — the Facebook-Marketplace shape: who they
/// are and how far they can be trusted, then everything they have for sale.
///
/// Opened from the seller row on any listing. It gathers a seller's whole shop
/// (active AND sold), their rating across every listing, their verification
/// standing, and the actions that make sense on a stranger — message them,
/// follow them, subscribe if they offer it. The rich identity (storefront,
/// place, bio) resolves ONLY from a seller this device actually knows — a
/// contact or yourself — because the directory carries none of it; a stranger
/// shows what their listings can vouch for and no more, the same honesty rule
/// [knownBusinessSeller] follows.
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

  /// The full [AppUser] behind a handle, when this device holds one — yourself
  /// or a contact. Null for a stranger (the directory has no profile fields).
  AppUser? _sellerUser() {
    if (username.isEmpty || username == 'you') return null;
    final me = AppState.profile.value;
    if (me.username.toLowerCase() == username.toLowerCase()) return me;
    for (final c in ChatStore.instance.allChats) {
      if (!c.contact.isGroup &&
          c.contact.username.toLowerCase() == username.toLowerCase()) {
        return c.contact;
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(name)),
      body: ListenableBuilder(
        listenable: Listenable.merge([
          FeedStore.instance,
          FollowStore.instance,
          CreatorSubStore.instance,
        ]),
        builder: (context, _) {
          final all = [
            for (final l in FeedStore.instance.listings())
              if (l.authorUsername.toLowerCase() == username.toLowerCase()) l
          ]..sort((a, b) => b.time.compareTo(a.time));
          final active = all.where((l) => !l.listingSold).toList();
          final sold = all.where((l) => l.listingSold).toList();
          final (avg, count) = FeedStore.instance.sellerRating(username);
          final seller = _sellerUser();
          final me = AppState.profile.value;
          final isMe = username.isNotEmpty &&
              me.username.toLowerCase() == username.toLowerCase();
          final verified = seller?.verified ?? all.any((l) => l.authorVerified);
          final phoneVerified = all.any((l) => l.authorPhone.isNotEmpty);
          final since = all.isEmpty
              ? null
              : all
                  .map((l) => l.time.year)
                  .reduce((a, b) => a < b ? a : b);

          return ListView(
            padding: EdgeInsets.zero,
            children: [
              // --- Identity -------------------------------------------------
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    seller != null
                        ? UserAvatar(user: seller, radius: 32)
                        : CircleAvatar(
                            radius: 32,
                            child: Text(name.isEmpty ? '?' : name[0].toUpperCase(),
                                style: const TextStyle(fontSize: 24)),
                          ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Flexible(
                                child: Text(name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                        fontSize: 20,
                                        fontWeight: FontWeight.w800)),
                              ),
                              if (verified) ...[
                                const SizedBox(width: 5),
                                const VerifiedBadge(size: 18),
                              ],
                            ],
                          ),
                          if (username.isNotEmpty && username != 'you')
                            Text('@$username',
                                style: TextStyle(
                                    fontSize: 13.5,
                                    color: AppColors.subtle(context))),
                          if (seller?.isBusiness == true) ...[
                            const SizedBox(height: 4),
                            Row(
                              children: [
                                Icon(Icons.storefront_outlined,
                                    size: 15,
                                    color: Theme.of(context).colorScheme.primary),
                                const SizedBox(width: 4),
                                Flexible(
                                  child: Text(
                                    seller!.businessCategory.isEmpty
                                        ? 'Business'
                                        : seller.businessCategory,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                        fontSize: 12.5,
                                        fontWeight: FontWeight.w600,
                                        color: Theme.of(context)
                                            .colorScheme
                                            .primary),
                                  ),
                                ),
                              ],
                            ),
                          ],
                          if ((seller?.location ?? '').isNotEmpty) ...[
                            const SizedBox(height: 2),
                            Row(
                              children: [
                                Icon(Icons.place_outlined,
                                    size: 14, color: AppColors.subtle(context)),
                                const SizedBox(width: 3),
                                Flexible(
                                  child: Text(seller!.location,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                          fontSize: 12.5,
                                          color: AppColors.subtle(context))),
                                ),
                              ],
                            ),
                          ],
                          if (since != null) ...[
                            const SizedBox(height: 2),
                            Text('Selling since $since',
                                style: TextStyle(
                                    fontSize: 12,
                                    color: AppColors.subtle(context))),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              if ((seller?.about ?? '').isNotEmpty &&
                  seller!.about != 'Hey there! I am using OkayMessenger.')
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 2, 16, 4),
                  child: Text(seller.about,
                      style: const TextStyle(fontSize: 13.5, height: 1.35)),
                ),
              // --- Reputation band -----------------------------------------
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
                child: Row(
                  children: [
                    _SellerStat(
                      value: count > 0 ? avg.toStringAsFixed(1) : '—',
                      label: count == 0
                          ? 'No ratings'
                          : '$count ${count == 1 ? "review" : "reviews"}',
                      icon: Icons.star_rounded,
                      iconColor: const Color(0xFFF5A623),
                    ),
                    _SellerStat(
                        value: '${active.length}', label: 'For sale'),
                    _SellerStat(value: '${sold.length}', label: 'Sold'),
                  ],
                ),
              ),
              // --- Verification chips --------------------------------------
              if (verified || phoneVerified || seller?.isBusiness == true)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      if (verified) const _SellerChip(label: 'ID verified'),
                      if (phoneVerified)
                        const _SellerChip(label: 'Phone verified'),
                      if (seller?.isBusiness == true)
                        const _SellerChip(label: 'Business'),
                    ],
                  ),
                ),
              // --- Actions --------------------------------------------------
              if (!isMe)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 6),
                  child: Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: () => openSellerChat(context,
                              username: username, name: name),
                          icon: const Icon(Icons.chat_bubble_outline, size: 18),
                          label: const Text('Message'),
                        ),
                      ),
                      if (username.isNotEmpty && username != 'you') ...[
                        const SizedBox(width: 8),
                        _FollowButton(username: username),
                      ],
                    ],
                  ),
                ),
              if (!isMe && seller != null && seller.subscribable)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
                  child: SizedBox(
                    width: double.infinity,
                    child: CreatorSubStore.instance.active(username)
                        ? OutlinedButton.icon(
                            onPressed: null,
                            icon: const Icon(Icons.check, size: 16),
                            label: const Text('Subscribed'),
                          )
                        : FilledButton.tonalIcon(
                            onPressed: () => showSubscribeSheet(
                              context,
                              handle: username,
                              name: name,
                              tiers: seller.subscriptionTiers,
                            ),
                            icon:
                                const Icon(Icons.workspace_premium, size: 18),
                            label: Text(
                                'Subscribe · \$${(seller.subscriptionCents / 100).toStringAsFixed(2)}/mo'),
                          ),
                  ),
                ),
              const Divider(height: 20),
              // --- For sale -------------------------------------------------
              if (active.isNotEmpty) ...[
                _SellerSectionHeader(
                    label: 'For sale', count: active.length),
                _sellerGrid(context, active),
              ],
              // --- Sold -----------------------------------------------------
              if (sold.isNotEmpty) ...[
                _SellerSectionHeader(label: 'Sold', count: sold.length),
                _sellerGrid(context, sold),
              ],
              if (all.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(32),
                  child: Center(
                    child: Text('Nothing for sale right now.',
                        style: TextStyle(
                            color: AppColors.subtle(context), fontSize: 14)),
                  ),
                ),
              // --- Reviews --------------------------------------------------
              _SellerReviews(listings: all),
              const SizedBox(height: 24),
            ],
          );
        },
      ),
    );
  }

  Widget _sellerGrid(BuildContext context, List<FeedPost> listings) {
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
        childAspectRatio: 0.72,
      ),
      itemCount: listings.length,
      itemBuilder: (context, i) => _ListingCard(
        listing: listings[i],
        serverName: _serverName(listings[i].communityId),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(
              builder: (_) => ListingScreen(listingId: listings[i].id)),
        ),
      ),
    );
  }
}

/// One number in the seller's trust band — the rating, the count for sale, the
/// count sold.
class _SellerStat extends StatelessWidget {
  final String value;
  final String label;
  final IconData? icon;
  final Color? iconColor;
  const _SellerStat(
      {required this.value, required this.label, this.icon, this.iconColor});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null && value != '—') ...[
                Icon(icon, size: 17, color: iconColor),
                const SizedBox(width: 2),
              ],
              Text(value,
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w800)),
            ],
          ),
          const SizedBox(height: 1),
          Text(label,
              style:
                  TextStyle(fontSize: 11.5, color: AppColors.subtle(context))),
        ],
      ),
    );
  }
}

/// A section title with a count, above the For-sale and Sold grids.
class _SellerSectionHeader extends StatelessWidget {
  final String label;
  final int count;
  const _SellerSectionHeader({required this.label, required this.count});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 2),
        child: Text('$label · $count',
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
      );
}

/// The follow/following pill on a seller profile, mirroring the social one.
class _FollowButton extends StatelessWidget {
  final String username;
  const _FollowButton({required this.username});

  @override
  Widget build(BuildContext context) {
    final following = FollowStore.instance.isFollowing(username);
    final style = OutlinedButton.styleFrom(
      visualDensity: VisualDensity.compact,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      minimumSize: const Size(0, 40),
    );
    void toggle() => FollowStore.instance.toggle(username);
    return following
        ? OutlinedButton(
            style: style, onPressed: toggle, child: const Text('Following'))
        : FilledButton(
            style: FilledButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              minimumSize: const Size(0, 40),
            ),
            onPressed: toggle,
            child: const Text('Follow'));
  }
}

/// A seller's recent reviews, gathered across every listing they've posted —
/// the "how were they to deal with" section, drawn only when there are any.
class _SellerReviews extends StatelessWidget {
  final List<FeedPost> listings;
  const _SellerReviews({required this.listings});

  @override
  Widget build(BuildContext context) {
    final reviews = <FeedPost>[
      for (final l in listings) ...FeedStore.instance.reviewsFor(l.id)
    ]..sort((a, b) => b.time.compareTo(a.time));
    if (reviews.isEmpty) return const SizedBox.shrink();
    final shown = reviews.take(6).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(height: 20),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 4, 16, 4),
          child: Text('Reviews',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
        ),
        for (final r in shown)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(r.authorName.isEmpty ? 'Someone' : r.authorName,
                        style: const TextStyle(
                            fontSize: 13.5, fontWeight: FontWeight.w700)),
                    const SizedBox(width: 6),
                    _Stars(rating: r.rating, size: 14),
                    if (r.confirmedPurchase) ...[
                      const SizedBox(width: 6),
                      const Icon(Icons.verified_user,
                          size: 13, color: Color(0xFF2E7D32)),
                    ],
                  ],
                ),
                if (r.text.trim().isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(r.text.trim(),
                      style: const TextStyle(fontSize: 13, height: 1.3)),
                ],
              ],
            ),
          ),
      ],
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
/// The category spec as a quiet two-column table: label left, value right,
/// a hairline between rows. The place a buyer's eye goes for the numbers.
class _AttributeTable extends StatelessWidget {
  final List<(String, String)> rows;
  const _AttributeTable({required this.rows});

  @override
  Widget build(BuildContext context) {
    final subtle = AppColors.subtle(context);
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest
            .withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(12),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
      child: Column(
        children: [
          for (var i = 0; i < rows.length; i++) ...[
            if (i > 0)
              Divider(height: 1, color: subtle.withValues(alpha: 0.15)),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 9),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 120,
                    child: Text(rows[i].$1,
                        style: TextStyle(fontSize: 13.5, color: subtle)),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(rows[i].$2,
                        style: const TextStyle(
                            fontSize: 13.5, fontWeight: FontWeight.w600)),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

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
