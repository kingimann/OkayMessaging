import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

/// A settings screen that explains the permissions OkayMessenger uses and lets
/// the user manage them. The app never assumes a permission is granted — each
/// feature requests it at the point of use (calls → camera/mic, maps →
/// location, sending a photo → photos). Location has a live status here; the
/// rest are managed in the system Settings via the button below.
class PermissionsScreen extends StatefulWidget {
  const PermissionsScreen({super.key});

  @override
  State<PermissionsScreen> createState() => _PermissionsScreenState();
}

class _PermissionsScreenState extends State<PermissionsScreen>
    with WidgetsBindingObserver {
  LocationPermission? _location;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    try {
      _location = await Geolocator.checkPermission();
    } catch (_) {
      _location = null;
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _handleLocation() async {
    final current = _location ?? LocationPermission.denied;
    try {
      if (current == LocationPermission.deniedForever) {
        await Geolocator.openAppSettings();
      } else {
        final result = await Geolocator.requestPermission();
        if (mounted) setState(() => _location = result);
      }
    } catch (_) {}
  }

  Future<void> _openSettings() async {
    try {
      await Geolocator.openAppSettings();
    } catch (_) {}
  }

  bool get _locationGranted =>
      _location == LocationPermission.always ||
      _location == LocationPermission.whileInUse;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Permissions')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: Text(
                    'OkayMessenger only asks for a permission when you use a '
                    'feature that needs it. You can review and change them any '
                    'time in Settings.',
                    style: TextStyle(fontSize: 13.5, color: Colors.grey),
                  ),
                ),
                // Location has a live status and in-app request.
                ListTile(
                  leading: const Icon(Icons.location_on_outlined),
                  title: const Text('Location',
                      style: TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: const Text(
                      'To show you on the map, share places and get directions.'),
                  isThreeLine: true,
                  trailing: kIsWeb
                      ? null
                      : _locationGranted
                          ? Chip(
                              label: const Text('Allowed'),
                              backgroundColor:
                                  Colors.green.withValues(alpha: 0.12),
                              labelStyle: const TextStyle(
                                  color: Colors.green,
                                  fontWeight: FontWeight.w600),
                              side: BorderSide.none,
                              visualDensity: VisualDensity.compact,
                            )
                          : OutlinedButton(
                              onPressed: _handleLocation,
                              child: Text(
                                  _location == LocationPermission.deniedForever
                                      ? 'Settings'
                                      : 'Allow'),
                            ),
                ),
                // The rest are requested at point of use; managed in Settings.
                for (final p in const [
                  (Icons.videocam_outlined, 'Camera',
                      'For video calls and taking photos to send.'),
                  (Icons.mic_none, 'Microphone',
                      'For voice and video calls and voice messages.'),
                  (Icons.photo_library_outlined, 'Photos',
                      'To send pictures and set your profile photo.'),
                  (Icons.notifications_none, 'Notifications',
                      'To alert you about new messages and calls.'),
                ])
                  ListTile(
                    leading: Icon(p.$1),
                    title: Text(p.$2,
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: Text(p.$3),
                    isThreeLine: true,
                    trailing: Text('On use',
                        style: TextStyle(
                            color: Colors.grey.shade500, fontSize: 12.5)),
                  ),
                if (!kIsWeb)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: OutlinedButton.icon(
                      onPressed: _openSettings,
                      icon: const Icon(Icons.settings_outlined),
                      label: const Text('Open iOS Settings'),
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size.fromHeight(48),
                      ),
                    ),
                  )
                else
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      'On the web, camera, microphone and location are granted '
                      'through your browser when you first use each feature.',
                      style:
                          TextStyle(color: Colors.grey.shade600, fontSize: 13),
                    ),
                  ),
              ],
            ),
    );
  }
}
