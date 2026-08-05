import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../app_state.dart';
import '../data/mock_data.dart';
import '../models/chat.dart';
import '../models/user.dart';
import '../relay/relay_config.dart';
import '../relay/relay_service.dart';
import '../state/chat_store.dart';
import '../state/score_store.dart';
import '../theme/app_theme.dart';
import '../widgets/user_avatar.dart';
import 'chat_screen.dart';

/// The people who can be put in a group: everyone you already have a real
/// conversation with. Sample contacts join the list outside release builds so
/// the flow stays usable in development.
List<AppUser> groupCandidates({Iterable<AppUser> exclude = const []}) {
  final excluded = exclude.map((u) => u.id).toSet();
  final seen = <String>{};
  final out = <AppUser>[];
  for (final u in [
    ...ChatStore.instance.reachableContacts(),
    if (!kReleaseMode) ...MockData.contacts(),
  ]) {
    if (excluded.contains(u.id) || !seen.add(u.id)) continue;
    out.add(u);
  }
  return out;
}

/// Two-step group creation: pick participants, then name the group. The group
/// conversation is created and stored locally.
class CreateGroupScreen extends StatefulWidget {
  const CreateGroupScreen({super.key});

  @override
  State<CreateGroupScreen> createState() => _CreateGroupScreenState();
}

class _CreateGroupScreenState extends State<CreateGroupScreen> {
  final _selected = <AppUser>{};
  final _nameController = TextEditingController();
  bool _naming = false;

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  void _toggle(AppUser user) {
    setState(() {
      if (!_selected.remove(user)) _selected.add(user);
    });
  }

  void _create() {
    final name = _nameController.text.trim();
    if (name.isEmpty) return;
    final store = ChatStore.instance;
    final me = AppState.profile.value;
    final members = [me, ..._selected];
    final id = 'group_${DateTime.now().microsecondsSinceEpoch}';
    final group = AppUser(
      id: id,
      name: name,
      avatarColor: '#4DB6AC',
      about: 'Group • ${members.length} members',
      isGroup: true,
    );
    final chat = Chat(
      id: id,
      contact: group,
      messages: const [],
      members: members,
    );
    store.upsert(chat);
    ScoreStore.instance.recordFlag('made_group');
    // Tell the other members' devices about the group right away, so it shows
    // up for them before anyone has typed anything.
    if (RelayConfig.isEnabled) RelayService.instance.sendGroupUpdate(chat);
    // Return to the chat list, then open the new group (so back goes to
    // the list, not through the group-creation flow).
    final navigator = Navigator.of(context);
    navigator.popUntil((route) => route.isFirst);
    navigator.push(
      MaterialPageRoute(builder: (_) => ChatScreen(chat: chat)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final contacts = groupCandidates();
    return Scaffold(
      appBar: AppBar(
        title: Text(_naming ? 'New group' : 'Add participants'),
        actions: [
          if (!_naming)
            TextButton(
              onPressed: _selected.isEmpty
                  ? null
                  : () => setState(() => _naming = true),
              child: const Text('Next'),
            ),
        ],
      ),
      body: _naming ? _buildNaming() : _buildPicker(contacts),
    );
  }

  Widget _buildPicker(List<AppUser> contacts) {
    return Column(
      children: [
        if (_selected.isNotEmpty)
          SizedBox(
            height: 92,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              children: [
                for (final u in _selected)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    child: Column(
                      children: [
                        Stack(
                          children: [
                            UserAvatar(user: u, radius: 26),
                            Positioned(
                              right: 0,
                              bottom: 0,
                              child: GestureDetector(
                                onTap: () => _toggle(u),
                                child: const CircleAvatar(
                                  radius: 9,
                                  backgroundColor: Colors.black54,
                                  child: Icon(Icons.close,
                                      size: 12, color: Colors.white),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        SizedBox(
                          width: 56,
                          child: Text(
                            u.name.split(' ').first,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        const Divider(height: 1),
        Expanded(
          child: contacts.isEmpty
              ? const _NoContactsYet()
              : ListView(
                  children: [
                    for (final c in contacts)
                      CheckboxListTile(
                        value: _selected.contains(c),
                        onChanged: (_) => _toggle(c),
                        secondary: UserAvatar(user: c, radius: 22),
                        title: Text(c.name,
                            style: const TextStyle(fontWeight: FontWeight.w600)),
                        subtitle: Text(c.about,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        activeColor: AppColors.accentOn(context),
                        controlAffinity: ListTileControlAffinity.trailing,
                      ),
                  ],
                ),
        ),
      ],
    );
  }

  Widget _buildNaming() {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Row(
          children: [
            CircleAvatar(
              radius: 30,
              backgroundColor: AppColors.accentOn(context),
              child: Icon(Icons.group, color: AppColors.onAccent(context)),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: TextField(
                controller: _nameController,
                autofocus: true,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(
                  hintText: 'Group name',
                  border: OutlineInputBorder(),
                ),
                onSubmitted: (_) => _create(),
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        Text(
          'Participants: ${_selected.length + 1}',
          style: const TextStyle(fontWeight: FontWeight.w600, color: Colors.grey),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final u in _selected)
              Chip(
                avatar: UserAvatar(user: u, radius: 12),
                label: Text(u.name.split(' ').first),
              ),
          ],
        ),
        const SizedBox(height: 24),
        FilledButton.icon(
          onPressed: _create,
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.accentOn(context),
            foregroundColor: AppColors.onAccent(context),
          ),
          icon: const Icon(Icons.check),
          label: const Text('Create group'),
        ),
      ],
    );
  }
}

/// Shown when there is nobody to add yet — a group can only contain people you
/// already have a conversation with.
class _NoContactsYet extends StatelessWidget {
  const _NoContactsYet();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.group_outlined, size: 46, color: Colors.grey.shade400),
            const SizedBox(height: 12),
            const Text(
              'No one to add yet',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            Text(
              'Start a chat with someone first — everyone you talk to shows up '
              'here as a participant you can add.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13.5, color: AppColors.subtle(context)),
            ),
          ],
        ),
      ),
    );
  }
}
