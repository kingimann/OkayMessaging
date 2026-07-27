import 'package:flutter/material.dart';

import '../app_state.dart';
import '../models/chat.dart';
import '../models/user.dart';
import '../relay/relay_config.dart';
import '../relay/relay_service.dart';
import '../state/chat_store.dart';
import '../theme/app_theme.dart';
import '../widgets/info_section.dart';
import '../widgets/user_avatar.dart';
import 'create_group_screen.dart';

/// Editing a group: its name, description, colour and who's in it. Saving
/// writes to the local store and pushes the change to the other members, so
/// everyone's copy converges without a group ever existing on a server.
class EditGroupScreen extends StatefulWidget {
  final String chatId;

  const EditGroupScreen({super.key, required this.chatId});

  @override
  State<EditGroupScreen> createState() => _EditGroupScreenState();
}

class _EditGroupScreenState extends State<EditGroupScreen> {
  static const _colors = [
    '#4DB6AC',
    '#E57373',
    '#64B5F6',
    '#BA68C8',
    '#FFB74D',
    '#81C784',
    '#7A5CFF',
  ];

  late final TextEditingController _name;
  late final TextEditingController _about;
  late String _color;
  late List<AppUser> _members;

  /// Members added in this edit, so they can be told about the group even
  /// though they aren't in the roster their device knows about yet.
  final _added = <AppUser>[];

  @override
  void initState() {
    super.initState();
    final chat = ChatStore.instance.chatById(widget.chatId);
    _name = TextEditingController(text: chat?.contact.name ?? '');
    _about = TextEditingController(text: chat?.contact.about ?? '');
    _color = chat?.contact.avatarColor ?? _colors.first;
    _members = [...?chat?.members];
  }

  @override
  void dispose() {
    _name.dispose();
    _about.dispose();
    super.dispose();
  }

  /// You can't remove yourself here — that's what "Exit group" is for.
  bool _isMe(AppUser u) =>
      u.id == AppState.profile.value.id || u.id == 'me' || u.id == 'self';

  Future<void> _addMembers() async {
    final picked = await showModalBottomSheet<List<AppUser>>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _AddMembersSheet(existing: _members),
    );
    if (picked == null || picked.isEmpty) return;
    setState(() {
      _members = [..._members, ...picked];
      _added.addAll(picked);
    });
  }

  void _remove(AppUser user) {
    setState(() {
      _members = _members.where((m) => m.id != user.id).toList();
      _added.removeWhere((m) => m.id == user.id);
    });
  }

  void _save() {
    final name = _name.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Give the group a name')),
      );
      return;
    }
    final store = ChatStore.instance;
    store.updateGroup(
      widget.chatId,
      name: name,
      about: _about.text.trim(),
      avatarColor: _color,
      members: _members,
    );
    final chat = store.chatById(widget.chatId);
    if (chat != null && RelayConfig.isEnabled) {
      // Members removed in this edit are deliberately not told: there is no
      // one to tell, since they're already off the roster we broadcast.
      RelayService.instance.sendGroupUpdate(
        chat,
        extraRecipients: _added.map((u) => u.phone).toList(),
      );
    }
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final preview = AppUser(
      id: widget.chatId,
      name: _name.text.trim().isEmpty ? 'Group' : _name.text.trim(),
      avatarColor: _color,
      isGroup: true,
    );
    return Scaffold(
      appBar: AppBar(
        title: const Text('Edit group'),
        actions: [
          TextButton(onPressed: _save, child: const Text('Save')),
        ],
      ),
      body: ListView(
        children: [
          const SizedBox(height: 18),
          Center(child: UserAvatar(user: preview, radius: 44)),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Wrap(
              alignment: WrapAlignment.center,
              spacing: 12,
              runSpacing: 12,
              children: [
                for (final hex in _colors)
                  GestureDetector(
                    onTap: () => setState(() => _color = hex),
                    child: Container(
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(
                        color: _swatch(hex),
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: _color == hex
                              ? AppColors.tealGreenDark
                              : Colors.transparent,
                          width: 3,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: TextField(
              controller: _name,
              textCapitalization: TextCapitalization.words,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                labelText: 'Group name',
                border: OutlineInputBorder(),
              ),
            ),
          ),
          const SizedBox(height: 14),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: TextField(
              controller: _about,
              maxLines: 3,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Description',
                alignLabelWithHint: true,
                border: OutlineInputBorder(),
              ),
            ),
          ),
          const SizedBox(height: 22),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 16, 8),
            child: Text('${_members.length} members',
                style: const TextStyle(
                    fontWeight: FontWeight.w700, color: Colors.grey)),
          ),
          InfoSection(
            children: [
              InfoTile(
                leading: const Icon(Icons.person_add_alt,
                    color: AppColors.tealGreenDark),
                title: 'Add participants',
                onTap: _addMembers,
              ),
              for (final m in _members)
                ListTile(
                  leading: UserAvatar(user: m, radius: 21),
                  title: Text(_isMe(m) ? 'You' : m.name,
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: m.phone.isEmpty
                      ? null
                      : Text(m.phone,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                  trailing: _isMe(m)
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.remove_circle_outline,
                              color: Colors.red),
                          tooltip: 'Remove',
                          onPressed: () => _remove(m),
                        ),
                ),
            ],
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  static Color _swatch(String hex) {
    try {
      return Color(int.parse(hex.replaceFirst('#', 'ff'), radix: 16));
    } catch (_) {
      return AppColors.tealGreenDark;
    }
  }
}

/// Picks additional participants from the people you already chat with.
class _AddMembersSheet extends StatefulWidget {
  final List<AppUser> existing;
  const _AddMembersSheet({required this.existing});

  @override
  State<_AddMembersSheet> createState() => _AddMembersSheetState();
}

class _AddMembersSheetState extends State<_AddMembersSheet> {
  final _picked = <AppUser>{};

  @override
  Widget build(BuildContext context) {
    final candidates = groupCandidates(exclude: widget.existing);
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            title: const Text('Add participants',
                style: TextStyle(fontWeight: FontWeight.w700)),
            trailing: TextButton(
              onPressed: _picked.isEmpty
                  ? null
                  : () => Navigator.of(context).pop(_picked.toList()),
              child: const Text('Add'),
            ),
          ),
          const Divider(height: 1),
          if (candidates.isEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(24, 28, 24, 36),
              child: Text(
                'Everyone you chat with is already in this group.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey),
              ),
            )
          else
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final c in candidates)
                    CheckboxListTile(
                      value: _picked.contains(c),
                      onChanged: (_) => setState(() {
                        if (!_picked.remove(c)) _picked.add(c);
                      }),
                      secondary: UserAvatar(user: c, radius: 21),
                      title: Text(c.name,
                          style: const TextStyle(fontWeight: FontWeight.w600)),
                      activeColor: AppColors.tealGreenDark,
                      controlAffinity: ListTileControlAffinity.trailing,
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Convenience for opening the editor for [chat].
Future<void> openGroupEditor(BuildContext context, Chat chat) =>
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => EditGroupScreen(chatId: chat.id),
    ));
