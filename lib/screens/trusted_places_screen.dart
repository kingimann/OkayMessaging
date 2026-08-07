import 'package:flutter/material.dart';

import '../state/chat_store.dart';
import '../state/payment_security_store.dart';
import '../state/session.dart';
import '../theme/app_theme.dart';
import '../util/geolocation.dart';
import '../widgets/app_dialogs.dart';

/// Manages the money-send protection: the switch that turns it on, the places
/// that count as trusted, and a view of the contacts you've trusted.
///
/// The promise, said plainly on the screen: sending money from anywhere that
/// ISN'T a trusted place asks for your PIN first, so a phone in the wrong
/// hands can't empty the wallet by walking out the door. Trusted contacts are
/// exempt — a send to them never asks.
class TrustedPlacesScreen extends StatefulWidget {
  const TrustedPlacesScreen({super.key});

  @override
  State<TrustedPlacesScreen> createState() => _TrustedPlacesScreenState();
}

class _TrustedPlacesScreenState extends State<TrustedPlacesScreen> {
  final _store = PaymentSecurityStore.instance;
  bool _busy = false;

  /// The check texts a code to the account's number, so a numberless account
  /// has nothing to text — the warning below says so.
  bool get _canText => !Session.instance.isNumberless;

  void _say(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(m)));
  }

  Future<void> _addHere() async {
    setState(() => _busy = true);
    try {
      final loc = await getCurrentLatLng();
      if (!mounted) return;
      if (loc == null) {
        _say('Couldn\'t read your location. Turn on location access and try '
            'again.');
        return;
      }
      final name = await showAppTextPrompt(
        context,
        icon: Icons.place_outlined,
        title: 'Name this place',
        hint: 'Home, Office…',
        confirmLabel: 'Add',
      );
      if (name == null || !mounted) return;
      _store.addPlace(TrustedPlace(
        name: name.trim().isEmpty ? 'Trusted place' : name.trim(),
        lat: loc.lat,
        lng: loc.lng,
      ));
      _say('Added this place.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _contactName(String digits) {
    final chat = ChatStore.instance.chatWithContact(digits);
    final name = chat?.contact.name.trim() ?? '';
    return name.isNotEmpty ? name : digits;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Payment security')),
      body: AnimatedBuilder(
        animation: _store,
        builder: (context, _) {
          final on = _store.enabled.value;
          return ListView(
            children: [
              SwitchListTile(
                secondary: const Icon(Icons.pin_drop_outlined),
                title: const Text('Verify sends outside trusted places'),
                subtitle: const Text(
                    'Text a code to your phone before sending money when '
                    'you\'re not at a trusted place'),
                value: on,
                onChanged: _busy ? null : (v) => _store.setEnabled(v),
              ),
              if (on && !_canText)
                const Padding(
                  padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
                  child: Text(
                    'Heads up: this account has no phone number, so there\'s '
                    'nowhere to text a code. (Wallet needs a number anyway.)',
                    style: TextStyle(color: Colors.orange),
                  ),
                ),
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 6),
                child: Text('TRUSTED PLACES',
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.6,
                        color: AppColors.subtle(context))),
              ),
              if (_store.places.isEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 6, 20, 6),
                  child: Text(
                      'No trusted places yet. Add the ones you send money from '
                      '— home, work — so you\'re only asked to verify elsewhere.',
                      style: TextStyle(color: AppColors.subtle(context))),
                ),
              for (final p in _store.places)
                ListTile(
                  leading: const Icon(Icons.home_outlined),
                  title: Text(p.name),
                  subtitle: Text(
                      '${p.lat.toStringAsFixed(4)}, ${p.lng.toStringAsFixed(4)} '
                      '· within ${p.radiusMeters.round()} m'),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline),
                    tooltip: 'Remove',
                    onPressed: () => _store.removePlace(p.key),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 6, 16, 8),
                child: OutlinedButton.icon(
                  onPressed: _busy ? null : _addHere,
                  icon: _busy
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.add_location_alt_outlined),
                  label: const Text('Add my current location'),
                ),
              ),
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 6),
                child: Text('TRUSTED CONTACTS',
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.6,
                        color: AppColors.subtle(context))),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 6, 20, 6),
                child: Text(
                    _store.trustedContacts.isEmpty
                        ? 'Sends to a trusted contact never ask for the PIN. '
                            'Mark someone trusted from their contact info.'
                        : 'Sends to these contacts never ask for the PIN.',
                    style: TextStyle(color: AppColors.subtle(context))),
              ),
              for (final d in _store.trustedContacts)
                ListTile(
                  leading: const Icon(Icons.person_outline),
                  title: Text(_contactName(d)),
                  trailing: IconButton(
                    icon: const Icon(Icons.remove_circle_outline),
                    tooltip: 'Stop trusting',
                    onPressed: () => _store.setTrustedContact(d, false),
                  ),
                ),
              const SizedBox(height: 24),
            ],
          );
        },
      ),
    );
  }
}
