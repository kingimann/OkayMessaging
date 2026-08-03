import 'package:flutter/material.dart';


import '../mesh/mesh_service.dart';
import '../mesh/nearby_fast.dart';
import '../mesh/nearby_people.dart';
import '../mesh/nearby_pick.dart';
import '../mesh/nearby_share.dart';
import '../mesh/nearby_transfer.dart';
import '../theme/app_theme.dart';
import '../util/file_moderation.dart';
import '../util/photo_prep.dart';
import '../widgets/chat_photo.dart';
import '../widgets/verified_gate.dart';
import 'privacy_settings_screen.dart';

/// Send a photo, a video or a file to somebody standing next to you.
///
/// Pick a person, they are asked, and it goes straight from this phone to
/// theirs — no internet and no server in between. Nothing arrives on
/// anybody's phone without them saying yes to it first.
///
/// WHAT FITS DEPENDS ON THE WAY IT WOULD GO. Two phones with a fast link
/// between them can hand over a short video; Bluetooth LE on its own moves a
/// few kilobytes a second, so the ceiling there is a photo. The screen says
/// which each person is on rather than letting somebody pick a video and
/// find out thirty seconds later.
class NearbyShareScreen extends StatefulWidget {
  /// The item to send, as a data URI — set when the screen is opened from a
  /// share button that already has one. Null just opens empty: picking is a
  /// tap away and the room is worth seeing first.
  final String? dataUri;

  /// What [dataUri] actually is: 'image', 'video' or 'file'. It was assumed
  /// to be an image, so a video arriving from a share button was drawn
  /// through an image decoder and called "Photo".
  final String kind;

  /// What to call it. Defaults per [kind] rather than to "Photo" for
  /// everything.
  final String? fileName;

  const NearbyShareScreen({
    super.key,
    this.dataUri,
    this.kind = 'image',
    this.fileName,
  });

  @override
  State<NearbyShareScreen> createState() => _NearbyShareScreenState();
}

class _NearbyShareScreenState extends State<NearbyShareScreen> {
  PickedItem? _item;
  bool _picking = false;

  @override
  void initState() {
    super.initState();
    final given = widget.dataUri;
    if (given != null) {
      _item = PickedItem(
        dataUri: given,
        fileName: widget.fileName ??
            switch (widget.kind) {
              'video' => 'Video',
              'image' => 'Photo',
              _ => 'File',
            },
        kind: widget.kind,
        // base64 carries 3 bytes in every 4 characters; near enough to put a
        // size on the card, which is all this is for.
        bytes: given.length ~/ 4 * 3,
      );
    }
    // Opening this screen no longer throws the system photo picker in your
    // face. It used to, on the theory that you came here to send something —
    // but the first thing most people want is to know whether the person
    // beside them has even appeared yet, and that was a full-screen modal to
    // dismiss before you could look.
  }

  /// The biggest thing anybody in the room could take right now.
  ///
  /// Whoever has the fast link decides: offering a video when the only person
  /// nearby is on Bluetooth alone would be offering something that cannot be
  /// sent.
  int get _limit {
    var fast = false;
    for (final person in NearbyPeople.instance.people) {
      if (NearbyFast.instance.hasPeer(person.digits)) fast = true;
    }
    return TransferChunks.fileLimitFor(fast);
  }

  Future<void> _run(Future<PickedItem?> Function() choose) async {
    if (_picking) return;
    setState(() => _picking = true);
    PickedItem? picked;
    try {
      picked = await choose();
    } on FileRejected catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.reason)));
      }
    }
    if (!mounted) return;
    setState(() {
      _picking = false;
      if (picked != null) _item = picked;
    });
  }

  /// A photo, shrunk to fit — so it goes over Bluetooth alone if it has to.
  Future<void> _pickPhoto() => _run(() async {
        final uri = await PhotoPrep.pickPhoto();
        if (uri == null) return null;
        return PickedItem(
            dataUri: uri,
            fileName: 'Photo',
            kind: 'image',
            bytes: uri.length ~/ 4 * 3);
      });

  /// Anything at all, as it is.
  Future<void> _pickFile() => _run(() => NearbyPick.pick(limit: _limit));

  /// Whether what is chosen can actually cross to [person] on the link they
  /// happen to be on.
  ///
  /// The same comparison [NearbyShare.offer] makes, asked *before* the tap
  /// instead of reported after it. Two people in the room can be on different
  /// links — one on the fast one, one on Bluetooth alone — so "it fits" is a
  /// question about a person, not about the file, and a Send button that can
  /// only fail should not be tappable.
  bool _fitsFor(NearbyPerson person) {
    final item = _item;
    if (item == null) return false;
    return item.dataUri.length <=
        TransferChunks.limitFor(NearbyFast.instance.hasPeer(person.digits));
  }

  void _clearItem() => setState(() => _item = null);

  void _openPrivacy() => Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const PrivacySettingsScreen()));

  Future<void> _send(NearbyPerson person) async {
    final item = _item;
    if (item == null) return;
    final transfer = await NearbyShare.instance.offer(
      person,
      item.dataUri,
      fileName: item.fileName,
      kind: item.kind,
      bytes: item.bytes,
    );
    if (!mounted) return;
    final fast = NearbyFast.instance.hasPeer(person.digits);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(transfer == null
          ? (fast
              ? 'That file is too big to hand over.'
              : 'Too big for Bluetooth. A photo will go; anything larger '
                  'needs both phones on the same fast link.')
          : 'Asked ${person.name} — waiting for them to accept.'),
    ));
  }

  /// "4.2 MB". Pure enough to read at a glance, which is the whole job.
  static String sizeLabel(int bytes) {
    if (bytes <= 0) return '';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).round()} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    // Wrapped here rather than at the button that opens this, so every way
    // in is covered. No phone gate anymore: this is two phones and a radio,
    // nothing here needs a session, and numberless accounts pass the
    // verified gate too — for them it was a door with no key.
    return VerifiedGate(
        title: 'Okay Drop',
        reason: 'This offers files to strangers in the room, straight from '
            'your phone to theirs. Verifying your ID means the name they see '
            'is one somebody stood behind.',
        // Ours to waive, and the one gate with no server in it at all — this
        // is two phones and a radio.
        ownerMayPass: true,
        numberlessMayPass: true,
        child: _guarded(context));
  }

  Widget _guarded(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Okay Drop'),
        actions: [
          IconButton(
            tooltip: 'Pick a photo',
            icon: const Icon(Icons.photo_library_outlined),
            onPressed: _pickPhoto,
          ),
          IconButton(
            tooltip: 'Pick a file or video',
            icon: const Icon(Icons.attach_file),
            onPressed: _pickFile,
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: Listenable.merge([
          NearbyPeople.instance,
          MeshService.instance,
          NearbyShare.instance,
          NearbyFast.instance,
        ]),
        builder: (context, _) {
          final mesh = MeshService.instance;
          if (!mesh.enabled) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(28, 0, 28, 40),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.bluetooth_disabled,
                        size: 52, color: AppColors.subtle(context)),
                    const SizedBox(height: 16),
                    const Text('Bluetooth is off',
                        style: TextStyle(
                            fontSize: 18, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 8),
                    Text(
                      'Turn on "Message people nearby" to send to people '
                      'around you with no internet.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          fontSize: 13.5,
                          height: 1.4,
                          color: AppColors.subtle(context)),
                    ),
                    const SizedBox(height: 18),
                    // The setting used to be named and not offered, which
                    // leaves somebody hunting through Settings for a screen
                    // this one could simply open.
                    FilledButton(
                      onPressed: _openPrivacy,
                      child: const Text('Open Privacy & security'),
                    ),
                  ],
                ),
              ),
            );
          }
          final people = NearbyPeople.instance.people;
          final transfers = NearbyShare.instance.transfers;
          return RefreshIndicator(
            onRefresh: _rescan,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              children: [
              _itemCard(context),
              const SizedBox(height: 18),
              _sectionLabel(context, 'PEOPLE NEARBY'),
              const SizedBox(height: 4),
              if (people.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Column(
                    children: [
                      // The AirDrop feel: the screen is visibly LOOKING, not
                      // sitting there empty. Pull down restarts the radios.
                      const _ScanningPulse(),
                      const SizedBox(height: 14),
                      Text(
                        'Looking around…\nThey need the app open, Bluetooth '
                        'on, and to have made themselves findable — the same '
                        'three things you do.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            fontSize: 13.5,
                            height: 1.4,
                            color: AppColors.subtle(context)),
                      ),
                      const SizedBox(height: 12),
                      // Including you: "findable" is off by default, so the
                      // most likely reason the room looks empty to them is
                      // the setting on this phone.
                      OutlinedButton.icon(
                        onPressed: _openPrivacy,
                        icon: const Icon(Icons.visibility_outlined, size: 18),
                        label: const Text('Check who can see me'),
                      ),
                    ],
                  ),
                )
              else
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Wrap(
                    spacing: 14,
                    runSpacing: 16,
                    children: [
                      for (final person in people)
                        _PersonBubble(
                          person: person,
                          hasItem: _item != null,
                          fits: _fitsFor(person),
                          onSend: () => _send(person),
                        ),
                    ],
                  ),
                ),
              if (transfers.isNotEmpty) ...[
                const SizedBox(height: 22),
                _sectionLabel(context, 'TRANSFERS'),
                const SizedBox(height: 8),
                for (final t in transfers) _TransferRow(transfer: t),
              ],
              ],
            ),
          );
        },
      ),
    );
  }

  /// Pull-to-refresh: restart the radios. Discovery genuinely wedges —
  /// Bluetooth scans go quiet, the fast link loses its browser — and a
  /// stop/start is the honest reset for both, which is exactly what a person
  /// pulling the list down is asking for.
  Future<void> _rescan() async {
    final mesh = MeshService.instance;
    if (!mesh.enabled) return;
    await mesh.stop();
    await mesh.start();
  }

  static Widget _sectionLabel(BuildContext context, String text) => Text(
        text,
        style: TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.8,
            color: AppColors.subtle(context)),
      );

  Widget _itemCard(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final item = _item;
    if (item != null) {
      // What is about to be sent, with a way out of it. Swapping the file was
      // possible from the app bar; unchoosing it was not, so a mis-picked
      // 12 MB video could only be replaced, never put down.
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _itemPreview(context, item, scheme),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: Text(
                  sizeLabel(item.bytes).isEmpty
                      ? item.fileName
                      : '${item.fileName} · ${sizeLabel(item.bytes)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 12.5, color: AppColors.subtle(context)),
                ),
              ),
              TextButton(
                onPressed: _clearItem,
                style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 8)),
                child: const Text('Remove'),
              ),
            ],
          ),
        ],
      );
    }
    return _itemPreview(context, item, scheme);
  }

  Widget _itemPreview(
      BuildContext context, PickedItem? item, ColorScheme scheme) {
    return Container(
      height: 160,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(16),
      ),
      clipBehavior: Clip.antiAlias,
      child: _picking
          ? const CircularProgressIndicator()
          : item == null
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextButton.icon(
                      onPressed: _pickPhoto,
                      icon: const Icon(Icons.add_photo_alternate_outlined),
                      label: const Text('Choose a photo'),
                    ),
                    TextButton.icon(
                      onPressed: _pickFile,
                      icon: const Icon(Icons.attach_file),
                      label: const Text('Choose a file or video'),
                    ),
                  ],
                )
              // ChatPhoto, not Image.network: what is held here is a `data:`
              // URI, and NetworkImage hands that to an HttpClient that has no
              // idea what to do with the scheme. The preview of a photo you
              // had just chosen came up blank on a phone for that reason.
              : item.kind == 'image'
                  ? ChatPhoto(
                      url: item.dataUri,
                      fit: BoxFit.cover,
                      width: double.infinity,
                      errorBuilder: (context) => Icon(Icons.broken_image_outlined,
                          size: 38, color: AppColors.subtle(context)),
                    )
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                            item.kind == 'video'
                                ? Icons.movie_outlined
                                : Icons.insert_drive_file_outlined,
                            size: 38,
                            color: AppColors.subtle(context)),
                        const SizedBox(height: 8),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 24),
                          child: Text(item.fileName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                  fontWeight: FontWeight.w600)),
                        ),
                        if (sizeLabel(item.bytes).isNotEmpty)
                          Text(sizeLabel(item.bytes),
                              style: TextStyle(
                                  fontSize: 12.5,
                                  color: AppColors.subtle(context))),
                      ],
                    ),
    );
  }
}

/// One person as an AirDrop-style bubble: their avatar IS the send button.
/// The transport still gets said — which way it would go is the difference
/// between one second and half a minute, and between "a video fits" and "it
/// cannot" — just under the name instead of across a whole row.
class _PersonBubble extends StatelessWidget {
  final NearbyPerson person;

  /// Whether anything is chosen yet.
  final bool hasItem;

  /// Whether what is chosen fits *this* person's link.
  final bool fits;

  final VoidCallback onSend;
  const _PersonBubble({
    required this.person,
    required this.hasItem,
    required this.fits,
    required this.onSend,
  });

  Color get _color {
    var hex = person.avatarColor.replaceFirst('#', '');
    if (hex.length == 6) hex = 'FF$hex';
    return Color(int.tryParse(hex, radix: 16) ?? 0xFF9E9E9E);
  }

  @override
  Widget build(BuildContext context) {
    final fast = NearbyFast.instance.hasPeer(person.digits);
    final tooBig = hasItem && !fits;
    final sendable = hasItem && fits;
    final scheme = Theme.of(context).colorScheme;
    final label = tooBig
        ? (fast ? 'Too big' : 'Too big for Bluetooth')
        : fast
            ? 'Fast link'
            : 'Bluetooth';
    return SizedBox(
      width: 86,
      child: Column(
        children: [
          Stack(
            clipBehavior: Clip.none,
            children: [
              Material(
                color: Colors.transparent,
                shape: const CircleBorder(),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: sendable ? onSend : null,
                  child: Opacity(
                    opacity: tooBig ? 0.4 : 1,
                    child: CircleAvatar(
                      radius: 30,
                      backgroundColor: _color,
                      child: sendable
                          ? const Icon(Icons.arrow_upward_rounded,
                              color: Colors.white, size: 28)
                          : Text(
                              person.name.isEmpty
                                  ? '?'
                                  : person.name[0].toUpperCase(),
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 22,
                                  fontWeight: FontWeight.w700)),
                    ),
                  ),
                ),
              ),
              // The fast link earns its bolt: it is what makes a video
              // possible at all.
              if (fast)
                Positioned(
                  right: -3,
                  bottom: -3,
                  child: Container(
                    padding: const EdgeInsets.all(3),
                    decoration: BoxDecoration(
                      color: scheme.surface,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(Icons.bolt,
                        size: 14, color: scheme.primary),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(person.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style:
                  const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
          Text(label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 10.5,
                  color: tooBig ? scheme.error : AppColors.subtle(context))),
        ],
      ),
    );
  }
}

/// Two soft rings breathing around a Bluetooth mark — the screen saying "I
/// am looking" instead of sitting empty.
class _ScanningPulse extends StatefulWidget {
  const _ScanningPulse();

  @override
  State<_ScanningPulse> createState() => _ScanningPulseState();
}

class _ScanningPulseState extends State<_ScanningPulse>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(seconds: 2))
        ..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    return SizedBox(
      width: 110,
      height: 110,
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) => Stack(
          alignment: Alignment.center,
          children: [
            for (final phase in [0.0, 0.5])
              _ring(((_c.value + phase) % 1.0), color),
            CircleAvatar(
              radius: 26,
              backgroundColor: color.withValues(alpha: 0.12),
              child:
                  Icon(Icons.bluetooth_searching, color: color, size: 26),
            ),
          ],
        ),
      ),
    );
  }

  Widget _ring(double t, Color color) => Container(
        width: 54 + t * 56,
        height: 54 + t * 56,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
              color: color.withValues(alpha: (1 - t) * 0.35), width: 2),
        ),
      );
}

/// One transfer, with how far along it is.
class _TransferRow extends StatelessWidget {
  final NearbyTransfer transfer;
  const _TransferRow({required this.transfer});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final subtitle = switch (transfer.state) {
      TransferState.offered => 'Waiting for ${transfer.peerName} to accept',
      TransferState.incoming => 'Waiting for you',
      TransferState.sending =>
        'Sending — ${(transfer.progress * 100).round()}%',
      TransferState.receiving =>
        'Receiving — ${(transfer.progress * 100).round()}%',
      TransferState.done => 'Done',
      TransferState.declined => '${transfer.peerName} said no',
      TransferState.cancelled => 'Stopped',
      TransferState.failed => NearbyShare.instance.canRetry(transfer.id)
          ? 'Didn\'t finish'
          : 'Didn\'t finish — ask them to send again',
    };
    final moving = transfer.state == TransferState.sending ||
        transfer.state == TransferState.receiving;
    final failed = transfer.state == TransferState.failed;
    final done = transfer.state == TransferState.done;
    final statusColor = failed
        ? scheme.error
        : done
            ? Colors.green
            : AppColors.subtle(context);
    final kindIcon = switch (transfer.kind) {
      'image' => Icons.photo_outlined,
      'video' => Icons.videocam_outlined,
      _ => Icons.insert_drive_file_outlined,
    };
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: scheme.primary.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                    done ? Icons.check_rounded : kindIcon,
                    size: 21,
                    color: done ? Colors.green : scheme.primary),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${transfer.fileName} · ${transfer.peerName}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    Text(subtitle,
                        style:
                            TextStyle(fontSize: 12.5, color: statusColor)),
                  ],
                ),
              ),
              if (moving)
                TextButton(
                  onPressed: () => NearbyShare.instance.cancel(transfer.id),
                  style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 8)),
                  child: const Text('Stop'),
                ),
              // The radio dropped it: the bytes are still held, so trying
              // again costs one tap rather than re-picking the file.
              if (failed && NearbyShare.instance.canRetry(transfer.id))
                TextButton(
                  onPressed: () => NearbyShare.instance.retry(transfer.id),
                  style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 8)),
                  child: const Text('Send again'),
                ),
            ],
          ),
          if (moving) ...[
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                  value: transfer.progress, minHeight: 5),
            ),
          ],
        ],
      ),
    );
  }
}
