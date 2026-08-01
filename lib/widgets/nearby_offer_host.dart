import 'dart:async';

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
  Widget build(BuildContext context) => Stack(
        children: [
          widget.child,
          // Accepting used to be the last thing that happened on screen. A
          // photo landed in a second so nobody noticed; a video is a minute
          // of nothing, on a phone somebody is holding still because they
          // were told to. The same pill the call banner uses, in the same
          // place, for the same reason.
          const NearbyTransferBanner(),
        ],
      );
}

/// What is moving right now, and a way to stop it.
///
/// Wherever you happen to be — the transfer list lives on the screen you
/// would have SENT from, which is precisely the screen a receiver is not on.
class NearbyTransferBanner extends StatefulWidget {
  const NearbyTransferBanner({super.key});

  /// The line under the file name. Pure, so what it says can be checked
  /// without a radio.
  static String statusLine(NearbyTransfer t) => switch (t.state) {
        TransferState.sending => 'Sending ${(t.progress * 100).round()}%',
        TransferState.receiving => 'Receiving ${(t.progress * 100).round()}%',
        TransferState.done => 'Done',
        TransferState.declined => 'Declined',
        TransferState.cancelled => 'Stopped',
        TransferState.failed => 'Didn\'t finish',
        TransferState.offered => 'Waiting',
        TransferState.incoming => 'Waiting for you',
      };

  @override
  State<NearbyTransferBanner> createState() => _NearbyTransferBannerState();
}

class _NearbyTransferBannerState extends State<NearbyTransferBanner> {
  /// How long a finished transfer stays up before it clears itself. Long
  /// enough to read, short enough not to become furniture.
  static const Duration linger = Duration(seconds: 4);

  Timer? _clear;

  @override
  void initState() {
    super.initState();
    NearbyShare.instance.addListener(_onChange);
  }

  @override
  void dispose() {
    _clear?.cancel();
    NearbyShare.instance.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (!mounted) return;
    final shown = _shown;
    if (shown != null && shown.isFinished && _clear == null) {
      _clear = Timer(linger, () {
        _clear = null;
        NearbyShare.instance.clearFinished();
      });
    }
  }

  /// The one worth showing: something moving, or the last thing to finish.
  /// An offer waiting to be answered is not here — that is the dialog's job.
  NearbyTransfer? get _shown {
    NearbyTransfer? finished;
    for (final t in NearbyShare.instance.transfers) {
      if (t.isMoving) return t;
      if (t.isFinished) finished = t;
    }
    return finished;
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: NearbyShare.instance,
      builder: (context, _) {
        final t = _shown;
        if (t == null) return const SizedBox.shrink();
        final scheme = Theme.of(context).colorScheme;
        final moving = t.isMoving;
        return Positioned(
          top: MediaQuery.of(context).padding.top + 6,
          left: 12,
          right: 12,
          child: Material(
            color: scheme.inverseSurface,
            borderRadius: BorderRadius.circular(20),
            elevation: 8,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 8, 6, 8),
              child: Row(
                children: [
                  Icon(
                      switch (t.kind) {
                        'image' => Icons.image_outlined,
                        'video' => Icons.movie_outlined,
                        _ => Icons.insert_drive_file_outlined,
                      },
                      size: 18,
                      color: scheme.onInverseSurface),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          '${t.fileName} · ${NearbyTransferBanner.statusLine(t)}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: scheme.onInverseSurface,
                              fontSize: 13.5,
                              fontWeight: FontWeight.w600),
                        ),
                        if (moving) ...[
                          const SizedBox(height: 5),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(3),
                            child: LinearProgressIndicator(
                              value: t.progress,
                              minHeight: 4,
                              backgroundColor:
                                  scheme.onInverseSurface.withValues(alpha: 0.25),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (moving)
                    TextButton(
                      onPressed: () => NearbyShare.instance.cancel(t.id),
                      style: TextButton.styleFrom(
                          foregroundColor: scheme.onInverseSurface),
                      child: const Text('Stop'),
                    )
                  else
                    const SizedBox(width: 8),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

}
