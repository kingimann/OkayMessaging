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
import '../widgets/empty_state.dart';
import '../widgets/verified_gate.dart';

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
  /// The item to send, as a data URI. Null asks for one when the screen
  /// opens — which is the ordinary way in from a share button.
  final String? dataUri;

  const NearbyShareScreen({super.key, this.dataUri});

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
          dataUri: given, fileName: 'Photo', kind: 'image', bytes: 0);
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) => _pickPhoto());
    }
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
    // in is covered.
    return VerifiedGate(
      title: 'Send nearby',
      reason: 'This offers files to strangers in the room, straight from your '
          'phone to theirs. Verifying your ID means the name they see is one '
          'somebody stood behind.',
      // Ours to waive, and the one gate with no server in it at all — this is
      // two phones and a radio.
      ownerMayPass: true,
      child: _guarded(context),
    );
  }

  Widget _guarded(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Send to someone nearby'),
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
            return const EmptyState(
              icon: Icons.bluetooth_disabled,
              title: 'Bluetooth is off',
              caption: 'Turn on "Message people nearby" in Privacy & security '
                  'to send to people around you with no internet.',
            );
          }
          final people = NearbyPeople.instance.people;
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            children: [
              _itemCard(context),
              const SizedBox(height: 18),
              Text('PEOPLE NEARBY',
                  style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.8,
                      color: AppColors.subtle(context))),
              const SizedBox(height: 4),
              if (people.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 24),
                  child: Text(
                    'Nobody yet. They need the app open, Bluetooth on, and '
                    'to have made themselves findable — the same three things '
                    'you do.',
                    style: TextStyle(
                        fontSize: 13.5,
                        height: 1.4,
                        color: AppColors.subtle(context)),
                  ),
                )
              else
                for (final person in people)
                  _PersonRow(
                    person: person,
                    enabled: _item != null,
                    onSend: () => _send(person),
                  ),
              const SizedBox(height: 20),
              for (final t in NearbyShare.instance.transfers)
                _TransferRow(transfer: t),
            ],
          );
        },
      ),
    );
  }

  Widget _itemCard(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final item = _item;
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
              : item.kind == 'image'
                  ? Image.network(item.dataUri,
                      fit: BoxFit.cover, width: double.infinity)
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

class _PersonRow extends StatelessWidget {
  final NearbyPerson person;
  final bool enabled;
  final VoidCallback onSend;
  const _PersonRow(
      {required this.person, required this.enabled, required this.onSend});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: CircleAvatar(
        backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: Text(
            person.name.isEmpty ? '?' : person.name[0].toUpperCase(),
            style: const TextStyle(fontWeight: FontWeight.w700)),
      ),
      title: Text(person.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w600)),
      // Worth saying which way it will go: one is about a second and one is
      // half a minute of standing still, and that changes what somebody does
      // next.
      // The difference is not cosmetic: one of these can take a video and
      // the other cannot.
      subtitle: Text(NearbyFast.instance.hasPeer(person.digits)
          ? 'Nearby · quick link, files and video'
          : 'Nearby · Bluetooth only, photos and small files'),
      trailing: FilledButton(
        onPressed: enabled ? onSend : null,
        child: const Text('Send'),
      ),
    );
  }
}

/// One transfer, with how far along it is.
class _TransferRow extends StatelessWidget {
  final NearbyTransfer transfer;
  const _TransferRow({required this.transfer});

  @override
  Widget build(BuildContext context) {
    final subtitle = switch (transfer.state) {
      TransferState.offered => 'Waiting for ${transfer.peerName} to accept',
      TransferState.incoming => 'Waiting for you',
      TransferState.sending =>
        'Sending — ${(transfer.progress * 100).round()}%',
      TransferState.receiving =>
        'Receiving — ${(transfer.progress * 100).round()}%',
      TransferState.done => 'Sent',
      TransferState.declined => '${transfer.peerName} said no',
      TransferState.cancelled => 'Stopped',
      TransferState.failed => 'Did not finish',
    };
    final moving = transfer.state == TransferState.sending ||
        transfer.state == TransferState.receiving;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${transfer.fileName} · ${transfer.peerName}',
              style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 2),
          Row(
            children: [
              Expanded(
                child: Text(subtitle,
                    style: TextStyle(
                        fontSize: 12.5, color: AppColors.subtle(context))),
              ),
              if (moving)
                TextButton(
                  onPressed: () => NearbyShare.instance.cancel(transfer.id),
                  style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 8)),
                  child: const Text('Stop'),
                ),
            ],
          ),
          if (moving) ...[
            const SizedBox(height: 6),
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
