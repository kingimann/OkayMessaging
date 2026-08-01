import 'package:flutter/material.dart';

import '../mesh/nearby_share.dart';
import '../mesh/nearby_transfer.dart';

/// Asks before anything lands on this phone.
///
/// The part of AirDrop that matters most: a file arriving unannounced is a
/// stranger putting something on your device. An offer says who it is from
/// and what it is, and nothing moves until somebody says yes.
///
/// ONE AT A TIME, deliberately. A queue of dialogs is how people say yes to
/// the thing they meant to say no to.
class NearbyOfferHost extends StatefulWidget {
  const NearbyOfferHost({super.key, required this.child});

  final Widget child;

  @override
  State<NearbyOfferHost> createState() => _NearbyOfferHostState();
}

class _NearbyOfferHostState extends State<NearbyOfferHost> {
  String? _asking;

  @override
  void initState() {
    super.initState();
    NearbyShare.instance.addListener(_check);
  }

  @override
  void dispose() {
    NearbyShare.instance.removeListener(_check);
    super.dispose();
  }

  void _check() {
    final pending = NearbyShare.instance.pendingIncoming;
    if (pending == null || _asking == pending.id || !mounted) return;
    _asking = pending.id;
    // Asked after the current frame, because this can be called from the
    // middle of one — and ensureVisualUpdate because there may not BE a next
    // frame. Nothing in this subtree rebuilds when an offer arrives, so
    // without it the callback waits for somebody to touch the screen and the
    // question never gets asked.
    WidgetsBinding.instance.addPostFrameCallback((_) => _ask(pending));
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  Future<void> _ask(NearbyTransfer offer) async {
    if (!mounted) return;
    final accepted = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.wifi_tethering),
        title: Text('${offer.peerName} wants to send you a photo'),
        content: Text(
          'Over Bluetooth, straight from their phone to yours. Nothing is '
          'downloaded until you accept.',
          style: TextStyle(color: Theme.of(ctx).colorScheme.onSurfaceVariant),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('No thanks')),
          FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Accept')),
        ],
      ),
    );
    if (accepted == true) {
      await NearbyShare.instance.accept(offer.id);
    } else {
      await NearbyShare.instance.decline(offer.id);
    }
    _asking = null;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
