import 'package:flutter/material.dart';

import '../payments/iap_entitlement.dart';
import '../payments/apple_iap.dart';
import '../payments/store_prices.dart';
import '../widgets/store_price_label.dart';
import '../payments/store_purchases.dart';
import '../state/ai_assistant.dart';
import '../state/ai_pass_store.dart';
import '../state/storage_store.dart';
import '../models/chat.dart';
import '../models/community.dart';
import '../models/user.dart';
import '../state/chat_store.dart';
import '../state/community_store.dart';
import '../state/community_sub_store.dart';
import '../state/creator_sub_store.dart';
import '../theme/app_theme.dart';
import '../widgets/subscribe_sheet.dart';
import '../widgets/user_avatar.dart';
import '../widgets/pass_billing_note.dart';
import 'package:intl/intl.dart';
import 'cloud_sync_screen.dart';
import 'home_screen.dart' show HomeNavBar;
import 'okay_pro_screen.dart';

/// Everything the app sells, in one place.
///
/// These were scattered by accident of when each was built: tips under
/// Settings, storage on its own screen, the AI pass behind the assistant's
/// overflow menu, creator subscriptions on a profile and paid memberships on
/// an invite card. Somebody wanting to pay for something had to already know
/// where it lived.
///
/// Two of them cannot live here and the page says so rather than pretending:
/// a creator subscription is bought from the creator (there is no catalogue of
/// people to pick from) and a server membership from that server's invite.
/// Listing them with a dead button would be worse than explaining where they
/// are.
class StoreScreen extends StatefulWidget {
  const StoreScreen({super.key});

  @override
  State<StoreScreen> createState() => _StoreScreenState();
}

/// A plain calendar day — these are renewal dates, not timestamps.
String _day(DateTime d) => DateFormat.yMMMd().format(d);

/// The creators this device can honestly offer a subscription to.
///
/// **There is no global directory of creators, and that is not an oversight.**
/// `subscribable` and the tier list ride the SEALED PROFILE SHARE — they
/// reach this device only from somebody it has actually exchanged messages
/// with — and the username directory carries no such field. So the catalogue
/// is exactly "creators you know", which the Store says in those words
/// rather than implying it is everyone.
///
/// Pure, so a test hands it chats rather than standing up a store.
List<AppUser> subscribableCreatorsIn(Iterable<Chat> chats) {
  final seen = <String>{};
  final out = <AppUser>[];
  for (final chat in chats) {
    final u = chat.contact;
    if (u.isGroup || !u.subscribable) continue;
    if (u.subscriptionTiers.isEmpty) continue;
    final key = u.username.trim().toLowerCase();
    if (key.isEmpty || !seen.add(key)) continue;
    out.add(u);
  }
  out.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  return out;
}

/// The paid servers a membership can be bought for from here — the ones this
/// device is in.
///
/// A paid server can never appear in the public Discover directory
/// (`Community.listed` and `paid` are exclusive, because a listed server's
/// join secret is world-readable and a paid one's must not be), so there is
/// no wider catalogue to draw on. What this offers is renewing a pass for a
/// server you already hold an invite to.
List<Community> paidServersIn(Iterable<Community> all) {
  final out = [
    for (final c in all)
      if (c.paid && c.priceCents > 0) c
  ];
  out.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  return out;
}

class _StoreScreenState extends State<StoreScreen> {
  bool _busy = false;

  /// The App Store country these prices came from ('USA', 'CAN'), or '' when
  /// unreadable.
  ///
  /// Shown because the currency on this screen is Apple's answer for THIS
  /// storefront, and a bare "\$9.99" cannot say which Apple that was. In
  /// production there is only one — the buyer's — and the line reads as a
  /// plain fact.
  ///
  /// **In TestFlight this always says USA and it is Apple's bug, not ours.**
  /// A TestFlight build reports the US storefront whatever country the
  /// account is in, and prices from the US store to match, while the
  /// purchase sheet bills the real account in its own currency — so a
  /// Canadian tester gets \$9.99 here and CA\$12.99 in the sheet. Confirmed
  /// on three separate devices, which is the tell: no per-account
  /// misconfiguration reaches all of them. Store products spells it out;
  /// see developer.apple.com/forums/thread/794932.
  String _storefront = '';

  @override
  void initState() {
    super.initState();
    // The prices shown here are the store's own, so ask for them on open —
    // the launch answer can be stale after a change in App Store Connect.
    StorePrices.instance.load();
    AppleIap.storefront().then((c) {
      if (mounted && c.isNotEmpty) setState(() => _storefront = c);
    });
  }

  /// The currency StoreKit quoted these prices in, when it quoted just one.
  String get _currency => StorePrices.instance.quotedCurrency;

  /// 'USA' → 'US', 'CAN' → 'Canadian'. Anything unmapped keeps Apple's own
  /// code rather than being guessed at into a country name.
  String get _storeName => switch (_storefront) {
        'USA' => 'US',
        'CAN' => 'Canadian',
        'GBR' => 'UK',
        'AUS' => 'Australian',
        _ => _storefront,
      };

  Future<void> _buyAiPass() async {
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    final result = await AiPassStore.instance.subscribe();
    if (!mounted) return;
    setState(() => _busy = false);
    messenger.showSnackBar(SnackBar(
        content: Text(result.ok
            ? 'Okay AI Pro is active. Enjoy.'
            : result.message)));
  }

  Future<void> _restore() async {
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await StorePurchases.instance.restorePurchases();
      final e = await IapEntitlement.instance.refresh();
      if (e != null) {
        StorageStore.instance.applyServerEntitlement(
            active: e.active, gb: e.gb, expiresAt: e.expiresAt);
      }
      if (!mounted) return;
      messenger.showSnackBar(const SnackBar(
          content: Text('Checked your Apple ID for past purchases.')));
    } catch (_) {
      if (!mounted) return;
      messenger.showSnackBar(
          const SnackBar(content: Text('Couldn\'t reach the App Store.')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final subtle = AppColors.subtle(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Store')),
      body: ListenableBuilder(
        listenable: Listenable.merge([
          StorePrices.instance,
          AiPassStore.instance,
          StorageStore.instance,
        ]),
        builder: (context, _) {
          // Pull to ask the store again. Apple's own product metadata can lag
          // a price change in App Store Connect, and when it does there is
          // nothing in the app that can correct it — so the honest thing is a
          // way to re-ask on demand rather than waiting out a cache nobody
          // can see.
          return RefreshIndicator(
            onRefresh: _refreshPrices,
            child: _body(context, subtle),
          );
        },
      ),
      // Opened from the sidebar, so it was a dead end with only a back
      // arrow. Nothing is selected — this is not a tab.
      // Floats over the content like it does on home, rather than sitting in
      // a slot the list stops above (the owner's call). Each list below pads
      // itself by HomeNavBar.clearance so nothing ends underneath it.
      extendBody: true,
      bottomNavigationBar: const HomeNavBar(),
    );
  }

  /// Re-asks the store, then SAYS what happened.
  ///
  /// A bare pull-to-refresh is invisible when nothing changes — the spinner
  /// turns, the same figures come back, and there is no way to tell whether
  /// the app looked or not. That is useless for the one question this exists
  /// to answer: "I raised the price in App Store Connect, has it landed?"
  /// So the three outcomes are named, including the two that are not
  /// success.
  Future<void> _refreshPrices() async {
    Map<String, String?> snapshot() => {
          for (final id in StorePrices.allIds())
            id: StorePrices.instance.priceFor(id)
        };
    final before = snapshot();
    await StorePrices.instance.load();
    if (!mounted) return;
    final after = snapshot();
    final changed =
        after.entries.where((e) => before[e.key] != e.value).length;
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(SnackBar(
      content: Text(changed > 0
          ? (changed == 1 ? '1 price updated' : '$changed prices updated')
          : StorePrices.instance.answered
              // Apple answered and its answer has not moved. Worth saying
              // outright: its product metadata can lag a price change in App
              // Store Connect by hours, and nothing here can hurry it.
              ? 'The App Store still reports the same prices.'
              : 'The App Store did not answer.'),
    ));
  }

  /// Picks a creator, then opens the tier sheet that actually charges.
  ///
  /// Two of the four things this app sells used to be reachable ONLY from a
  /// creator's profile or a server's invite card — surfaces somebody has to
  /// already be on. That is what "the creator and server ones are not really
  /// visible" meant, and it is also how App Review came to report it could
  /// not find the in-app purchases.
  Future<void> _pickCreator() async {
    final creators = subscribableCreatorsIn(ChatStore.instance.allChats);
    if (creators.isEmpty) return;
    final picked = await showModalBottomSheet<AppUser>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 4, 20, 10),
              child: Text('Subscribe to a creator',
                  style:
                      TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            ),
            for (final c in creators)
              ListTile(
                leading: UserAvatar(user: c, radius: 20),
                title: Text(c.name),
                subtitle: Text('@${c.username}'),
                trailing: CreatorSubStore.instance.active(c.username)
                    ? const Icon(Icons.check_circle,
                        size: 18, color: Color(0xFF12B76A))
                    : null,
                onTap: () => Navigator.of(sheetContext).pop(c),
              ),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;
    await showSubscribeSheet(
      context,
      handle: picked.username,
      name: picked.name,
      tiers: picked.subscriptionTiers,
    );
  }

  /// Picks a paid server, then buys or renews its 30-day pass.
  ///
  /// Deliberately does NOT join anything — the invite card's version does,
  /// because there the purchase is how you get in. Here you are already a
  /// member and the pass is what lapses, so joining would be a step that has
  /// already happened.
  Future<void> _pickServer() async {
    final servers = paidServersIn(CommunityStore.instance.communities);
    if (servers.isEmpty) return;
    final picked = await showModalBottomSheet<Community>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 4, 20, 10),
              child: Text('Paid server membership',
                  style:
                      TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            ),
            for (final c in servers)
              ListTile(
                leading: const Icon(Icons.groups_outlined),
                title: Text(c.name),
                subtitle: Text(CommunitySubStore.instance.active(c.id)
                    ? 'Active until '
                        '${_day(CommunitySubStore.instance.activeUntil(c.id)!)}'
                    : '${StorePrices.instance.money(c.priceCents, productId: StorePurchases.communitySubProductId(tierForCents(c.priceCents)))}'
                        ' for 30 days'),
                onTap: () => Navigator.of(sheetContext).pop(c),
              ),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    final result = await CommunitySubStore.instance
        .subscribe(picked.id, tierForCents(picked.priceCents));
    if (!mounted) return;
    setState(() => _busy = false);
    messenger.showSnackBar(SnackBar(
        content: Text(result.ok
            ? '${picked.name} — 30 days added.'
            : 'That didn\'t go through — nothing was charged.')));
  }

  /// Why [productId] cannot be bought right now, or null when it can.
  ///
  /// Three genuinely different situations that all used to render as the same
  /// dead button: still asking, asked and got no answer, and asked and the
  /// store does not sell this. Only the last is a fault to act on, and it is
  /// the one that needs the product id said out loud.
  String? _blockedNote(String productId) {
    final prices = StorePrices.instance;
    if (prices.awaitingStore) return 'Checking with the App Store…';
    if (prices.pricesUnknown) {
      return 'The App Store did not answer. Pull down to try again.';
    }
    if (productId.isNotEmpty && prices.isUnavailable(productId)) {
      // The id is printed because it is exactly what somebody needs to check
      // in App Store Connect, and it is compiled into every copy of the app
      // — the same reasoning the ad-unit check prints its own.
      return 'The App Store is not offering this on this device. Product: '
          '$productId';
    }
    return null;
  }

  Widget _body(BuildContext context, Color subtle) {
    final ai = AiPassStore.instance;
    final storage = StorageStore.instance;
    return ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: EdgeInsets.fromLTRB(
                16, 12, 16, HomeNavBar.clearance(context)),
            children: [
              Text('Chats, calls, servers and the forum are free.',
                  style: TextStyle(fontSize: 13.5, height: 1.45, color: subtle)),
              // Every card dead is a different fault from any one of them
              // being dead, and it is the one that reads as "this app has no
              // in-app purchases" to whoever is looking for them.
              if (StorePrices.instance.nothingOnSale) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Theme.of(context)
                        .colorScheme
                        .errorContainer
                        .withValues(alpha: 0.55),
                    borderRadius: BorderRadius.circular(AppRadius.md),
                  ),
                  child: Text(
                    'The App Store is not offering any purchases on this '
                    'device right now, so nothing below can be bought. Pull '
                    'down to ask again.',
                    style: TextStyle(
                        fontSize: 12.5,
                        height: 1.4,
                        color: Theme.of(context).colorScheme.onErrorContainer),
                  ),
                ),
              ],
              if (_storefront.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  // The currency code is named HERE, in a sentence, and never
                  // beside a figure. Apple's sheet prints a bare '$' and so
                  // must the price labels, or they stop looking like the same
                  // number — but the US and Canadian stores BOTH print '$',
                  // so without this line "$9.99" cannot say whose dollars it
                  // is, which is exactly how a correct price reads as a bug.
                  //
                  // It deliberately no longer promises this IS the charge.
                  // TestFlight always reports USA and prices from the US
                  // store (Apple's own bug) while billing the tester's real
                  // account, so a line claiming these figures are what gets
                  // charged was one the app could not keep. Naming the
                  // storefront is a fact; naming the charge is Apple's job,
                  // and it does it in the sheet.
                  'Prices from the $_storeName App Store'
                  '${_currency.isEmpty ? '' : ' in $_currency'}'
                  '. The purchase sheet always confirms the final amount.',
                  style:
                      TextStyle(fontSize: 12.5, height: 1.4, color: subtle),
                ),
              ],
              const SizedBox(height: 20),

              _StoreCard(
                icon: Icons.auto_awesome,
                title: 'Okay AI Pro',
                blurb: 'Unlimited messages for 30 days. '
                    '${AiAssistant.freePerDay} a day without it.',
                // Never a made-up amount, and never a dash where a
                // spinner belongs: StorePriceLabel owns that whole decision.
                // `cents: 0` because this product has no fallback figure at
                // all — the store's price or nothing, everywhere.
                priceProductId: StorePurchases.aiPassProductId,
                // Says plainly that this is a one-time charge that expires,
                // not an auto-renewing subscription — the button below reads
                // "Get Okay AI Pro" / "Extend by 30 days", which alone reads
                // exactly like a subscription's language.
                extra: const PassBillingNote(),
                active: ai.active,
                activeNote: ai.activeUntil == null
                    ? null
                    : 'Active until ${_day(ai.activeUntil!)}',
                actionLabel: ai.active ? 'Extend by 30 days' : 'Get Okay AI Pro',
                // Nothing to buy while the store says it has never heard of
                // the product — and nothing to buy while we are still asking,
                // since a sheet cannot open on a product that has not loaded.
                onTap: (_busy ||
                        StorePrices.instance
                            .isUnavailable(StorePurchases.aiPassProductId) ||
                        StorePrices.instance.awaitingStore)
                    ? null
                    : _buyAiPass,
                blockedNote: _blockedNote(StorePurchases.aiPassProductId),
              ),

              _StoreCard(
                icon: Icons.cloud_outlined,
                title: 'Cloud storage',
                blurb: 'Encrypted backup, under a key only you hold. '
                    'Monthly, by the gigabyte.',
                priceProductId: '',
                active: storage.isPaid,
                activeNote: storage.isPaid
                    ? '${storage.selectedGb} GB'
                        '${storage.activeUntil == null ? '' : ' · renews '
                            '${_day(storage.activeUntil!)}'}'
                    : null,
                actionLabel: storage.isPaid ? 'Manage plan' : 'See plans',
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const CloudSyncScreen()),
                ),
              ),

              _StoreCard(
                icon: Icons.favorite_outline,
                title: 'Support the developer',
                blurb: 'A one-off tip. Buys nothing, unlocks nothing.',
                priceProductId: '',
                actionLabel: 'Leave a tip',
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const OkayProScreen()),
                ),
              ),

              const SizedBox(height: 8),
              Text('BOUGHT SOMEWHERE ELSE',
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.6,
                      color: subtle)),
              const SizedBox(height: 8),
              // Not buttons. Both are bought from a particular person or
              // server, so a button here would have nothing to act on.
              // Both of these used to be TEXT — "bought on a creator's
              // profile", "bought from the server's invite" — because there
              // is no global directory of either to pick from. True, and it
              // left two of the four things this app sells reachable only
              // from a surface somebody had to already be on. There IS a
              // catalogue this device can honestly offer: creators it knows
              // advertise subscriptions, and paid servers it is in. So the
              // card carries a real button when there is something to pick
              // and keeps the sentence when there is not.
              Builder(builder: (context) {
                final creators =
                    subscribableCreatorsIn(ChatStore.instance.allChats);
                return _StoreCard(
                  icon: Icons.workspace_premium_outlined,
                  title: 'Creator subscriptions',
                  blurb: creators.isEmpty
                      ? 'Bought on a creator\'s profile. One pass each.'
                      : 'One pass each, 30 days at a time. '
                          '${creators.length} '
                          '${creators.length == 1 ? 'creator you know offers' : 'creators you know offer'}'
                          ' them.',
                  priceProductId: '',
                  extra: const PassBillingNote(),
                  actionLabel: 'Choose a creator',
                  onTap: (_busy || creators.isEmpty) ? null : _pickCreator,
                  blockedNote: creators.isEmpty
                      ? 'Nobody you have messaged offers subscriptions yet. A '
                          'creator\'s profile is where theirs is bought.'
                      : null,
                );
              }),
              Builder(builder: (context) {
                final servers =
                    paidServersIn(CommunityStore.instance.communities);
                return _StoreCard(
                  icon: Icons.groups_outlined,
                  title: 'Paid server membership',
                  blurb: servers.isEmpty
                      ? 'Bought from the server\'s invite.'
                      : '30 days at a time. ${servers.length} paid '
                          '${servers.length == 1 ? 'server' : 'servers'} here.',
                  priceProductId: '',
                  extra: const PassBillingNote(),
                  actionLabel: 'Choose a server',
                  onTap: (_busy || servers.isEmpty) ? null : _pickServer,
                  blockedNote: servers.isEmpty
                      ? 'You are not in a paid server. A membership is bought '
                          'from that server\'s invite.'
                      : null,
                );
              }),

              const SizedBox(height: 18),
              Center(
                child: TextButton.icon(
                  onPressed: _busy ? null : _restore,
                  icon: const Icon(Icons.restore, size: 18),
                  label: const Text('Restore purchases'),
                ),
              ),
              const SizedBox(height: 4),
              // NOT one sentence for the whole page — everything here bills
              // through the App Store, but only cloud storage auto-renews.
              // The single line this used to be ("Cancel in Settings →
              // Subscriptions") was correct for storage and WRONG for
              // everything else on the page: an AI Pro pass, a tip, a
              // creator subscription and a paid server membership are all
              // one-time charges, and none of them ever appears in
              // Settings → Subscriptions to be cancelled — a buyer following
              // that instruction for any of them would find nothing there.
              Center(
                child: Text(
                  'Cloud storage renews automatically each month until you '
                  'cancel it in Settings → your name → Subscriptions. '
                  'Everything else here — Okay AI Pro, tips, creator '
                  'subscriptions, paid server memberships — is a one-time '
                  'App Store charge that does not renew on its own.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, height: 1.4, color: subtle),
                ),
              ),
            ],
    );
  }
}

/// One purchasable thing.
class _StoreCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String blurb;

  /// The store product this card sells, or empty when the card only opens
  /// another screen (storage has a ladder; a tip has four amounts). The price
  /// itself is never passed in as a string — [StorePriceLabel] reads it from
  /// the store so a caller cannot hand this a figure of its own.
  final String priceProductId;
  final bool active;
  final String? activeNote;
  final String actionLabel;
  final VoidCallback? onTap;

  /// An optional line below the blurb — used for the billing disclosure a
  /// 30-day pass owes and a plain tip does not.
  final Widget? extra;

  /// Why the button is dead, when it is.
  ///
  /// A greyed "Get Okay AI Pro" beside the word "Unavailable" tells nobody
  /// anything — not the person who wanted to buy it, and not a reviewer
  /// looking for the in-app purchases. Saying which product the App Store
  /// would not sell is the difference between a screen that looks broken and
  /// one somebody can act on.
  final String? blockedNote;

  const _StoreCard({
    required this.icon,
    required this.title,
    required this.blurb,
    required this.priceProductId,
    required this.actionLabel,
    required this.onTap,
    this.active = false,
    this.activeNote,
    this.extra,
    this.blockedNote,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final subtle = AppColors.subtle(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: active
            ? Border.all(color: const Color(0xFF12B76A), width: 1.5)
            : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 22, color: scheme.primary),
              const SizedBox(width: 10),
              Expanded(
                child: Text(title,
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w700)),
              ),
              if (priceProductId.isNotEmpty)
                StorePriceLabel(
                  cents: 0,
                  productId: priceProductId,
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w700),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text(blurb,
              style: TextStyle(fontSize: 13.5, height: 1.4, color: subtle)),
          if (extra != null) ...[
            const SizedBox(height: 6),
            extra!,
          ],
          if (active && activeNote != null) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                const Icon(Icons.check_circle,
                    size: 16, color: Color(0xFF12B76A)),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(activeNote!,
                      style: const TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF12B76A))),
                ),
              ],
            ),
          ],
          if (onTap == null && blockedNote != null) ...[
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline, size: 15, color: subtle),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(blockedNote!,
                      style:
                          TextStyle(fontSize: 12, height: 1.35, color: subtle)),
                ),
              ],
            ),
          ],
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: onTap,
              child: Text(actionLabel),
            ),
          ),
        ],
      ),
    );
  }
}

/// Something purchasable that is NOT bought here, and where it is instead.
