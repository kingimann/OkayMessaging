import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

/// One manageable OS permission.
class _PermItem {
  final Permission permission;
  final IconData icon;
  final String title;
  final String why;
  const _PermItem(this.permission, this.icon, this.title, this.why);
}

/// A settings screen that shows the status of every OS permission the app can
/// use and lets the user grant it or jump to system settings. The app never
/// assumes a permission is granted — each feature requests at point of use, and
/// this screen makes the state visible and manageable.
class PermissionsScreen extends StatefulWidget {
  const PermissionsScreen({super.key});

  @override
  State<PermissionsScreen> createState() => _PermissionsScreenState();
}

class _PermissionsScreenState extends State<PermissionsScreen>
    with WidgetsBindingObserver {
  static const _items = [
    _PermItem(Permission.camera, Icons.videocam_outlined, 'Camera',
        'For video calls and taking photos to send.'),
    _PermItem(Permission.microphone, Icons.mic_none, 'Microphone',
        'For voice and video calls and voice messages.'),
    _PermItem(Permission.locationWhenInUse, Icons.location_on_outlined,
        'Location', 'To show you on the map, share places and get directions.'),
    _PermItem(Permission.photos, Icons.photo_library_outlined, 'Photos',
        'To send pictures and set your profile photo.'),
    _PermItem(Permission.contacts, Icons.contacts_outlined, 'Contacts',
        'To find which of your contacts already use OkayMessenger.'),
    _PermItem(Permission.notification, Icons.notifications_none,
        'Notifications', 'To alert you about new messages and calls.'),
  ];

  final Map<Permission, PermissionStatus> _status = {};
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
    // Re-read statuses when returning from the system Settings app.
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    if (kIsWeb) {
      setState(() => _loading = false);
      return;
    }
    for (final item in _items) {
      try {
        _status[item.permission] = await item.permission.status;
      } catch (_) {
        // Some permissions aren't available on every platform.
      }
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _handle(_PermItem item) async {
    final current = _status[item.permission] ?? PermissionStatus.denied;
    if (current.isPermanentlyDenied || current.isRestricted) {
      await openAppSettings();
      return;
    }
    try {
      final result = await item.permission.request();
      if (mounted) setState(() => _status[item.permission] = result);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Permissions')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : kIsWeb
              ? _webNote()
              : ListView(
                  children: [
                    const Padding(
                      padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
                      child: Text(
                        'OkayMessenger only asks for a permission when you use a '
                        'feature that needs it. Review and change them here any '
                        'time.',
                        style: TextStyle(fontSize: 13.5, color: Colors.grey),
                      ),
                    ),
                    for (final item in _items) _tile(item),
                    const SizedBox(height: 16),
                  ],
                ),
    );
  }

  Widget _tile(_PermItem item) {
    final status = _status[item.permission] ?? PermissionStatus.denied;
    final (label, color) = _statusLabel(status);
    final granted = status.isGranted || status.isLimited;
    return ListTile(
      leading: Icon(item.icon),
      title: Text(item.title,
          style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text(item.why),
      isThreeLine: true,
      trailing: granted
          ? Chip(
              label: Text(label),
              backgroundColor: color.withValues(alpha: 0.12),
              labelStyle: TextStyle(color: color, fontWeight: FontWeight.w600),
              side: BorderSide.none,
              visualDensity: VisualDensity.compact,
            )
          : OutlinedButton(
              onPressed: () => _handle(item),
              child: Text(
                  status.isPermanentlyDenied || status.isRestricted
                      ? 'Settings'
                      : 'Allow'),
            ),
    );
  }

  (String, Color) _statusLabel(PermissionStatus s) {
    if (s.isGranted) return ('Allowed', Colors.green);
    if (s.isLimited) return ('Limited', Colors.orange);
    if (s.isPermanentlyDenied) return ('Denied', Colors.red);
    if (s.isRestricted) return ('Restricted', Colors.red);
    return ('Not set', Colors.grey);
  }

  Widget _webNote() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.public, size: 52, color: Colors.grey.shade400),
            const SizedBox(height: 16),
            const Text('Managed by your browser',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            Text(
              'On the web, camera, microphone and location permissions are '
              'granted through your browser when you first use each feature.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey.shade600, fontSize: 14),
            ),
          ],
        ),
      ),
    );
  }
}
