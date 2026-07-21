import 'package:flutter/material.dart';

import '../app_state.dart';
import '../state/session.dart';
import '../widgets/user_avatar.dart';

/// Lets the current user edit their display name and about text.
class EditProfileScreen extends StatefulWidget {
  const EditProfileScreen({super.key});

  @override
  State<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends State<EditProfileScreen> {
  late final TextEditingController _name;
  late final TextEditingController _about;

  @override
  void initState() {
    super.initState();
    final p = AppState.profile.value;
    _name = TextEditingController(text: p.name);
    _about = TextEditingController(text: p.about);
  }

  @override
  void dispose() {
    _name.dispose();
    _about.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    if (Session.instance.isSignedIn) {
      // Persist to the on-device identity so edits survive a reload.
      await Session.instance
          .updateProfile(name: _name.text, about: _about.text);
    } else {
      AppState.updateProfile(name: _name.text, about: _about.text);
    }
    navigator.pop();
    messenger.showSnackBar(
      const SnackBar(content: Text('Profile updated')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Edit profile'),
        actions: [
          IconButton(icon: const Icon(Icons.check), onPressed: _save),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Center(
            child: UserAvatar(user: AppState.profile.value, radius: 48),
          ),
          const SizedBox(height: 24),
          TextField(
            controller: _name,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(
              labelText: 'Name',
              prefixIcon: Icon(Icons.person_outline),
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _about,
            maxLines: 3,
            decoration: const InputDecoration(
              labelText: 'About',
              prefixIcon: Icon(Icons.info_outline),
              border: OutlineInputBorder(),
            ),
          ),
          if (AppState.profile.value.phone.isNotEmpty) ...[
            const SizedBox(height: 16),
            TextField(
              enabled: false,
              controller:
                  TextEditingController(text: AppState.profile.value.phone),
              decoration: const InputDecoration(
                labelText: 'Phone number',
                helperText: 'Your login number — stays on this device',
                prefixIcon: Icon(Icons.phone_outlined),
                border: OutlineInputBorder(),
              ),
            ),
          ],
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: _save,
            icon: const Icon(Icons.save),
            label: const Text('Save'),
          ),
        ],
      ),
    );
  }
}
