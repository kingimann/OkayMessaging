import 'package:flutter/material.dart';

import '../mesh/mesh_service.dart';
import '../mesh/nearby_fast.dart';
import '../mesh/nearby_people.dart';
import '../mesh/nearby_share.dart';
import '../mesh/nearby_transfer.dart';
import '../theme/app_theme.dart';
import '../util/file_moderation.dart';
import '../util/photo_prep.dart';
import '../widgets/empty_state.dart';

/// Send a photo to somebody standing next to you.
///
/// Pick a person, they are asked, and it goes over Bluetooth with no internet
/// and no server in between. Nothing arrives on anybody's phone without them
/// saying yes to it first.
class NearbyShareScreen extends StatefulWidget {
  /// The photo to send, as a data URI. Null asks for one when the screen
  /// opens — which is the ordinary way in from a share button.
  final String? dataUri;

  const NearbyShareScreen({super.key, this.dataUri});

  @override
  State<NearbyShareScreen> createState() => _NearbyShareScreenState();
}

class _NearbyShareScreenState extends State<NearbyShareScreen> {
  String? _photo;
  bool _picking = false;

  @override
  void initState() {
    super.initState();
    _photo = widget.dataUri;
    if (_photo == null) WidgetsBinding.instance.addPostFrameCallback((_) => _pick());
  }

  Future<void> _pick() async {
    if (_picking) return;
    setState(() => _picking = true);
    String? picked;
    try {
      picked = await PhotoPrep.pickPhoto();
    } on FileRejected catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.reason)));
      }
    }
    if (!mounted) return;
    setState(() {
      _picking = false;
      if (picked != null) _photo = picked;
    });
  }

  Future<void> _send(NearbyPerson person) async {
    final photo = _photo;
    if (photo == null) return;
    final transfer = await NearbyShare.instance
        .offer(person, photo, fileName: 'Photo');
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(transfer == null
          ? 'That photo is too big to send over Bluetooth.'
          : 'Asked ${person.name} — waiting for them to accept.'),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Send to someone nearby'),
        actions: [
          if (_photo != null)
            IconButton(
              tooltip: 'Pick another photo',
              icon: const Icon(Icons.photo_library_outlined),
              onPressed: _pick,
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
              _photoCard(context),
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
                    enabled: _photo != null,
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

  Widget _photoCard(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
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
          : _photo == null
              ? TextButton.icon(
                  onPressed: _pick,
                  icon: const Icon(Icons.add_photo_alternate_outlined),
                  label: const Text('Choose a photo'),
                )
              : Image.network(_photo!, fit: BoxFit.cover, width: double.infinity),
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
      subtitle: Text(NearbyFast.instance.hasPeer(person.digits)
          ? 'Nearby · quick'
          : 'Nearby · over Bluetooth'),
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
          Text(subtitle,
              style:
                  TextStyle(fontSize: 12.5, color: AppColors.subtle(context))),
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
