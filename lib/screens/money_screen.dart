import 'package:flutter/material.dart';

import '../screens/home_screen.dart' show HomeNavBar;
import 'earnings_screen.dart';
import 'get_paid_screen.dart';
import 'wallet_screen.dart';

/// Everything about money, in one place: the **Wallet**, how people can
/// **Get paid**, and what has been **Earned**.
///
/// These were three separate Settings rows sitting next to each other, and the
/// Wallet already carried two doors into Get paid — which is what a screen
/// does when it is really a tab of something. Nothing was deleted: each of the
/// three is still its own screen and still reachable on its own (the wallet is
/// pushed from a marketplace purchase, Get paid from the "they can't receive
/// money yet" sheet), they just also render as tabs here with `embedded: true`.
///
/// **The gate is on the WALLET TAB, not on this screen**, and that is the
/// whole reason this could be combined at all. The Settings comment that used
/// to sit beside "Get paid" said it: the Wallet needs a phone number to load,
/// the Lightning rail needs no account of any kind, and "putting the only door
/// inside the one room they cannot enter would have hidden that from exactly
/// the people it is for." Wrapping this screen in a [PhoneGate] would have
/// recreated that fault, so the wallet keeps its own three gates
/// ([ParentalGate]/[PhoneGate]/[VerifiedGate], now with `scaffold: false`) and
/// a name-only account still lands on a screen whose other two tabs work.
///
/// Earnings is ungated for the same reason: it counts sparks and sold listings
/// off this device, and only the "payments received" line needs the wallet —
/// which it already omits, saying so, when the wallet cannot answer.
class MoneyScreen extends StatefulWidget {
  /// Which tab opens first: 0 Wallet, 1 Get paid, 2 Earnings.
  final int initialTab;

  const MoneyScreen({super.key, this.initialTab = 0});

  @override
  State<MoneyScreen> createState() => _MoneyScreenState();
}

class _MoneyScreenState extends State<MoneyScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;

  /// The wallet's app-bar actions live on the wallet's own state, so this
  /// reaches them through a key rather than duplicating them here — two copies
  /// of Transactions / Payment controls / Check payments setup is how one of
  /// them ends up wired to something else.
  final _wallet = GlobalKey<WalletScreenActions>();

  @override
  void initState() {
    super.initState();
    _tabs = TabController(
        length: 3, vsync: this, initialIndex: widget.initialTab.clamp(0, 2))
      // The bar's actions belong to the Wallet alone, so they have to be
      // rebuilt as the tab changes rather than drawn once.
      ..addListener(() => setState(() {}));
    // The key is not attached until the wallet tab has been built once, so on
    // the very first frame `currentState` is null and the bar would draw with
    // no actions and never be asked again. One rebuild after that first frame
    // is what puts them there.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Money'),
        actions:
            _tabs.index == 0 ? (_wallet.currentState?.actions(context) ?? const []) : const [],
        bottom: TabBar(
          controller: _tabs,
          tabs: const [
            Tab(text: 'Wallet'),
            Tab(text: 'Get paid'),
            Tab(text: 'Earnings'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [
          WalletScreen(
            key: _wallet,
            embedded: true,
            onOtherWays: () => _tabs.animateTo(1),
          ),
          // `cashReady: false` is what the Settings row always passed: the
          // wallet's own status load is what knows better, and it is one tab
          // away rather than behind this screen.
          const GetPaidScreen(cashReady: false, embedded: true),
          const EarningsScreen(embedded: true),
        ],
      ),
      extendBody: true,
      bottomNavigationBar: const HomeNavBar(),
    );
  }
}
