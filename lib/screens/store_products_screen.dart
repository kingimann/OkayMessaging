import 'package:flutter/material.dart';

import '../payments/apple_iap.dart';
import '../payments/purchase_outcome.dart';
import '../payments/store_prices.dart';
import '../payments/store_purchases.dart';
import '../theme/app_theme.dart';

/// What the App Store actually offers, product by product.
///
/// Nothing outside a real device can answer this: App Store Connect has no
/// public API, and StoreKit only speaks to a signed-in device. So the app
/// asks on the owner's behalf and shows the answer next to the price the code
/// assumes — which is how a product created under a slightly different id, or
/// still sitting in "Missing Metadata", becomes visible instead of just
/// failing at the purchase sheet.
class StoreProductsScreen extends StatefulWidget {
  const StoreProductsScreen({super.key});

  @override
  State<StoreProductsScreen> createState() => _StoreProductsScreenState();
}

class _StoreProductsScreenState extends State<StoreProductsScreen> {
  StoreQueryResult? _result;
  bool _busy = false;

  /// The store country whose prices this device is quoted ('USA', 'CAN'), or
  /// '' when unreadable. The single fact that answers "why am I charged in
  /// US dollars" — it is the country on the account signed into the App
  /// Store, and nothing in this app or in App Store Connect changes it.
  String _storefront = '';

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    setState(() => _busy = true);
    final r = await StorePurchases.instance.checkAll();
    final country = await AppleIap.storefront();
    // The freshest answer the app will get today — let every price label in
    // the app correct itself from it too.
    StorePrices.instance.absorb(r.onSale,
        reachable: r.storeReachable, currencies: r.currencies);
    if (mounted) {
      setState(() {
        _result = r;
        _storefront = country;
        _busy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final subtle = AppColors.subtle(context);
    final r = _result;
    final catalogue = StorePurchases.catalogue();
    // Each family once, in catalogue order.
    final groups = <String>{for (final p in catalogue) p.group}.toList();
    final onSale = r?.onSale.length ?? 0;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Store products'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Ask the store again',
            onPressed: _busy ? null : _check,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          if (_busy && r == null)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 40),
              child: Center(child: CircularProgressIndicator()),
            )
          else ...[
            Text(
              r == null
                  ? ''
                  : '$onSale of ${catalogue.length} products are on sale here.',
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            Text(
              r != null && !r.storeReachable
                  ? 'There is no App Store to ask from here — this answers '
                      'only on an iPhone signed in to the App Store.'
                  : 'A price is what the store will really charge. "Not '
                      'offered" means the store has never heard of that exact '
                      'product id.',
              style: TextStyle(fontSize: 13.5, height: 1.4, color: subtle),
            ),
            if (r != null && r.storeReachable) ...[
              const SizedBox(height: 14),
              _StorefrontCard(
                  country: _storefront, currencies: r.currencies.values),
            ],
            const SizedBox(height: 18),
            for (final group in groups) ...[
              Text(group.toUpperCase(),
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.6,
                      color: subtle)),
              const SizedBox(height: 6),
              for (final p in catalogue.where((e) => e.group == group))
                _ProductRow(
                  label: p.label,
                  id: p.id,
                  // The store's own price when it knows the product; what the
                  // app assumes when it doesn't, so the two can be compared.
                  storePrice: r?.onSale[p.id],
                  // Apple's OWN name for this id. The app's label is its own
                  // invention, so the two can drift — and until both are on
                  // screen there is no way to tell which App Store Connect
                  // row a price change was actually applied to.
                  storeName: r?.titles[p.id],
                  expected: p.cents == 0 ? '' : StorePrices.usd(p.cents),
                ),
              const SizedBox(height: 16),
            ],
            if (r != null) ...[
              const Divider(),
              const SizedBox(height: 8),
              Text(StorePurchases.tipsCheckVerdict(r),
                  style: TextStyle(fontSize: 13.5, height: 1.45, color: subtle)),
            ],
          ],
        ],
      ),
    );
  }
}

/// Names the store this device is buying from, and the currency it quotes.
///
/// This exists because "I'm being charged US dollars and I don't live in the
/// US" has exactly one cause and it is invisible from inside the app: the
/// currency follows the STOREFRONT — the country on the Apple ID signed into
/// the App Store — not the device's region, not its network, and not the
/// prices set in App Store Connect. Printing the storefront turns an
/// unanswerable complaint into a fact somebody can check.
///
/// The TestFlight trap, which cost a whole debugging round: a sandbox build
/// reads its PRICES from this storefront but runs the purchase sheet against
/// the **Sandbox Account** (Settings → App Store → Sandbox Account), and the
/// two can be different countries. A US storefront with a Canadian sandbox
/// account shows "\$9.99 USD" on the card and CA\$12.99 in the sheet — two
/// correct numbers from two different accounts, which reads exactly like a
/// pricing bug and is not one. Real buyers never see it: their storefront
/// and their purchase account are the same.
class _StorefrontCard extends StatelessWidget {
  final String country;
  final Iterable<String> currencies;
  const _StorefrontCard({required this.country, required this.currencies});

  @override
  Widget build(BuildContext context) {
    final subtle = AppColors.subtle(context);
    // One quoted currency is the normal case; more than one would mean the
    // store answered inconsistently, which is worth seeing rather than hiding.
    final quoted = currencies.map((c) => c.toUpperCase()).toSet().toList()
      ..sort();
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            country.isEmpty
                ? 'Store region: could not be read'
                : 'Store region: $country'
                    '${quoted.isEmpty ? '' : ' · quoting ${quoted.join(', ')}'}',
            style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          Text(
            'The currency comes from the country on the Apple ID signed in to '
            'the App Store — not this device\'s region, and not the prices in '
            'App Store Connect. To be charged in a different currency, that '
            'account\'s country has to change (Apple requires a zero balance '
            'and a local payment method).',
            style: TextStyle(fontSize: 13, height: 1.4, color: subtle),
          ),
          const SizedBox(height: 10),
          Text(
            'In TestFlight the purchase sheet uses your Sandbox Account '
            '(Settings → App Store → Sandbox Account), which can be a '
            'different country from the storefront above. When it is, the '
            'sheet quotes a different currency than these prices — both '
            'numbers are right, they are just two accounts. Real buyers only '
            'ever have one.',
            style: TextStyle(fontSize: 13, height: 1.4, color: subtle),
          ),
        ],
      ),
    );
  }
}

class _ProductRow extends StatelessWidget {
  final String label;
  final String id;
  final String? storePrice;

  /// What App Store Connect calls this product, when the store answered.
  final String? storeName;
  final String expected;
  const _ProductRow({
    required this.label,
    required this.id,
    required this.storePrice,
    required this.storeName,
    required this.expected,
  });

  /// True when Apple's name for the product is not the app's label. Not an
  /// error — the two are set in different places and never had to match — but
  /// it is the thing to know before editing a price, because the row to edit
  /// is the one named on the RIGHT.
  bool get _nameDiffers =>
      storeName != null &&
      storeName!.trim().isNotEmpty &&
      storeName!.trim().toLowerCase() != label.trim().toLowerCase();

  @override
  Widget build(BuildContext context) {
    final subtle = AppColors.subtle(context);
    final found = storePrice != null;
    // A store price that differs from the one the code assumes is worth
    // seeing: it is what the buyer is actually charged.
    final differs = found && expected.isNotEmpty && storePrice != expected;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(found ? Icons.check_circle : Icons.cancel_outlined,
              size: 18,
              color: found
                  ? Colors.green
                  : Theme.of(context).colorScheme.error),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                Text(id,
                    style: TextStyle(fontSize: 11.5, color: subtle)),
                if (_nameDiffers)
                  Text('App Store Connect calls this "${storeName!.trim()}"',
                      style: TextStyle(fontSize: 11.5, color: subtle)),
                if (differs)
                  Text('App expects $expected',
                      style: TextStyle(fontSize: 11.5, color: subtle)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(
            storePrice ?? 'Not offered',
            style: TextStyle(
              fontWeight: FontWeight.w700,
              color: found ? null : Theme.of(context).colorScheme.error,
            ),
          ),
        ],
      ),
    );
  }
}
