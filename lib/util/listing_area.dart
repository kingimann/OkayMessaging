/// Where a marketplace listing says it is, split into the parts a buyer
/// actually filters by: a city, and a state or province.
///
/// **Parsed from the free text the listing already carries, not from new
/// columns.** `FeedPost.listingPlace` is one string, written by the place
/// picker on the sell form, and a global listing is a row in a world-readable
/// table — so structured city/region fields would mean a wire change, a
/// migration, and a filter that could only ever see listings posted after it
/// shipped. Parsing means the filter works on every listing that already
/// exists, including the back catalogue.
///
/// **Positional from the RIGHT**, which is how an address is written
/// everywhere the app is sold: the last part is the broadest. So
/// `123 Main St, Toronto, Ontario, Canada` and `Toronto, Ontario, Canada`
/// both give Toronto / Ontario, and a street that happens to be in front is
/// simply not the city.
///
/// The one genuinely ambiguous case is TWO parts, and the rule is chosen
/// rather than guessed: `Toronto, Ontario` reads as city + region, because
/// the app's own producer of these strings — [localityLabel] in
/// `geocoding.dart` — emits `city, state` and falls back to `city, country`
/// only where OSM carries no state for that coordinate. Where it really was a
/// country, the region list shows "Canada", which is still a filter that
/// works rather than one that lies.
class ListingArea {
  const ListingArea({this.city = '', this.region = '', this.country = ''});

  /// The town, as written.
  final String city;

  /// The state or province.
  final String region;

  /// Only ever set when the place named three or more parts — with two there
  /// is no way to tell a province from a country, and inventing one would be
  /// worse than leaving it blank.
  final String country;

  bool get isEmpty => city.isEmpty && region.isEmpty && country.isEmpty;

  static ListingArea parse(String place) {
    final parts = [
      for (final p in place.split(',')) p.trim(),
    ]..removeWhere((p) => p.isEmpty);
    if (parts.isEmpty) return const ListingArea();
    if (parts.length == 1) return ListingArea(city: parts.first);
    if (parts.length == 2) {
      return ListingArea(city: parts[0], region: parts[1]);
    }
    return ListingArea(
      city: parts[parts.length - 3],
      region: parts[parts.length - 2],
      country: parts[parts.length - 1],
    );
  }

  /// Whether this listing sits in [city] / [region]. An empty argument means
  /// "don't care", so both empty matches everything — which is what an
  /// untouched filter has to do.
  static bool matches(String place, {String city = '', String region = ''}) {
    if (city.isEmpty && region.isEmpty) return true;
    final a = parse(place);
    bool same(String x, String y) => x.toLowerCase() == y.toLowerCase();
    if (city.isNotEmpty && !same(a.city, city)) return false;
    if (region.isNotEmpty && !same(a.region, region)) return false;
    return true;
  }

  /// Every distinct city across [places], sorted, for the filter's own list.
  ///
  /// Built from the listings THEMSELVES rather than a shipped table of
  /// provinces: a fixed list would offer places with nothing in them and miss
  /// anywhere the table forgot, and this app is not sold in one country
  /// forever. Case-insensitively deduped, keeping the first spelling seen, so
  /// "toronto" and "Toronto" are one row rather than two.
  static List<String> cities(Iterable<String> places, {String region = ''}) =>
      _distinct(places, region: region, pick: (a) => a.city);

  /// Every distinct state/province across [places], sorted.
  static List<String> regions(Iterable<String> places) =>
      _distinct(places, pick: (a) => a.region);

  static List<String> _distinct(
    Iterable<String> places, {
    required String Function(ListingArea) pick,
    String region = '',
  }) {
    final seen = <String, String>{};
    for (final p in places) {
      final a = parse(p);
      if (region.isNotEmpty && a.region.toLowerCase() != region.toLowerCase()) {
        continue;
      }
      final v = pick(a);
      if (v.isEmpty) continue;
      seen.putIfAbsent(v.toLowerCase(), () => v);
    }
    final out = seen.values.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return out;
  }
}
