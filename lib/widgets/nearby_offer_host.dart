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
        icon: Icon(switch (offer.kind) {
          'image' => Icons.image_outlined,
          'video' => Icons.movie_outlined,
          _ => Icons.insert_drive_file_outlined,
        }),
        title: Text('${offer.peerName} wants to send you ${_a(offer.kind)}'),
        content: Text(
          // What it is and how big, because "a file" is not enough to decide
          // on and a 40 MB video is a different question from a photo.
          '${offer.fileName}${_size(offer.bytes)}\n\n'
          'Straight from their phone to yours, with no server in between. '
          'Nothing arrives until you accept.',
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

  static String _a(String kind) => switch (kind) {
        'image' => 'a photo',
        'video' => 'a video',
        _ => 'a file',
      };

  /// " · 4.2 MB", or nothing when the sender did not say.
  static String _size(int bytes) {
    if (bytes <= 0) return '';
    if (bytes < 1024) return ' · $bytes B';
    if (bytes < 1024 * 1024) return ' · ${(bytes / 1024).round()} KB';
    return ' · ${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
