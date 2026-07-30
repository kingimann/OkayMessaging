import 'package:flutter/material.dart';

import '../models/community.dart';
import '../state/community_store.dart';
import 'communities.dart';
import 'community_settings_screen.dart';

Color _hex(String s) => Color(int.parse(s.replaceFirst('#', 'ff'), radix: 16));

/// Full creation form for a server: identity (name, icon, color,
/// description) plus the privacy and permission choices, so a server is
/// born with the shape its owner wants instead of existing wide-open until
/// someone finds the settings screen.
class CreateServerScreen extends StatefulWidget {
  const CreateServerScreen({super.key});

  @override
  State<CreateServerScreen> createState() => _CreateServerScreenState();
}

class _CreateServerScreenState extends State<CreateServerScreen> {
  final _name = TextEditingController();
  final _description = TextEditingController();
  String _icon = '';
  String _color = serverPalette.first;
  String _invitePolicy = invitePolicyEveryone;
  bool _membersCanMessage = true;
  bool _membersCanCreateChannels = true;
  bool _membersCanPost = true;
  int _slowMode = 0;

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    super.dispose();
  }

  void _create() {
    final name = _name.text.trim();
    if (name.isEmpty) return;
    final community = CommunityStore.instance.createCommunity(
      name,
      color: _color,
      icon: _icon,
      description: _description.text,
      invitePolicy: _invitePolicy,
      membersCanMessage: _membersCanMessage,
      membersCanCreateChannels: _membersCanCreateChannels,
      membersCanPost: _membersCanPost,
      slowModeSeconds: _slowMode,
    );
    Navigator.of(context).pushReplacement(MaterialPageRoute(
        builder: (_) => CommunityScreen(communityId: community.id)));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final canCreate = _name.text.trim().isNotEmpty;
    return Scaffold(
      appBar: AppBar(title: const Text('Create a server')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          Center(
            child: CircleAvatar(
              radius: 36,
              backgroundColor: _hex(_color),
              child: Text(
                _icon.isNotEmpty
                    ? _icon
                    : (_name.text.trim().isEmpty
                        ? '?'
                        : _name.text.trim()[0].toUpperCase()),
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 28,
                    fontWeight:
                        _icon.isNotEmpty ? FontWeight.w400 : FontWeight.w800),
              ),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _name,
            autofocus: true,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(
              labelText: 'Server name',
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _description,
            textCapitalization: TextCapitalization.sentences,
            maxLines: 2,
            decoration: const InputDecoration(
              labelText: 'Description (optional)',
              hintText: 'What is this server about?',
              border: OutlineInputBorder(),
            ),
          ),
          _sectionLabel('ICON'),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _iconChoice(
                selected: _icon.isEmpty,
                onTap: () => setState(() => _icon = ''),
                child: Text(
                    _name.text.trim().isEmpty
                        ? 'A'
                        : _name.text.trim()[0].toUpperCase(),
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.w800)),
              ),
              for (final e in serverEmojis)
                _iconChoice(
                  selected: _icon == e,
                  onTap: () => setState(() => _icon = e),
                  child: Text(e, style: const TextStyle(fontSize: 20)),
                ),
            ],
          ),
          _sectionLabel('COLOR'),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              for (final c in serverPalette)
                GestureDetector(
                  onTap: () => setState(() => _color = c),
                  child: Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: _hex(c),
                      shape: BoxShape.circle,
                      border: _color == c
                          ? Border.all(color: scheme.primary, width: 3)
                          : null,
                    ),
                    child: _color == c
                        ? const Icon(Icons.check,
                            color: Colors.white, size: 20)
                        : null,
                  ),
                ),
            ],
          ),
          _sectionLabel('PRIVACY'),
          _card(children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Text('Who can invite people',
                  style: TextStyle(fontWeight: FontWeight.w600)),
            ),
            for (final (policy, label, detail) in const [
              (invitePolicyEveryone, 'Everyone', 'Any member can share the '
                  'invite'),
              (invitePolicyModerators, 'Moderators',
                  'Moderators, admins, and the owner'),
              (invitePolicyAdmins, 'Admins only',
                  'Only admins and the owner'),
            ])
              RadioListTile<String>(
                value: policy,
                // ignore: deprecated_member_use
                groupValue: _invitePolicy,
                // ignore: deprecated_member_use
                onChanged: (v) =>
                    setState(() => _invitePolicy = v ?? _invitePolicy),
                title: Text(label),
                subtitle: Text(detail),
                dense: true,
              ),
          ]),
          const SizedBox(height: 12),
          _card(children: [
            SwitchListTile(
              value: _membersCanMessage,
              onChanged: (v) => setState(() => _membersCanMessage = v),
              title: const Text('Members can send messages'),
              subtitle: const Text(
                  'Off makes the server broadcast-only: everyone reads, '
                  'moderators speak'),
            ),
            SwitchListTile(
              value: _membersCanCreateChannels,
              onChanged: (v) =>
                  setState(() => _membersCanCreateChannels = v),
              title: const Text('Members can create channels'),
            ),
            SwitchListTile(
              value: _membersCanPost,
              onChanged: (v) => setState(() => _membersCanPost = v),
              title: const Text('Members can create forum posts'),
            ),
          ]),
          _sectionLabel('SLOW MODE'),
          Wrap(
            spacing: 8,
            children: [
              for (final s in slowModeChoices)
                ChoiceChip(
                  label: Text(s == 0 ? 'Off' : slowModeLabel(s)),
                  selected: _slowMode == s,
                  onSelected: (_) => setState(() => _slowMode = s),
                ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
                'Limits how often members can send messages. '
                'Moderators are exempt.',
                style:
                    TextStyle(fontSize: 12, color: Colors.grey.shade600)),
          ),
          const SizedBox(height: 20),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(
              children: [
                Icon(Icons.lock_outline,
                    size: 20, color: Colors.grey.shade600),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Everything in a server is end-to-end encrypted with its '
                    'own key, shared only through invites. People who join '
                    'later never receive earlier messages.',
                    style: TextStyle(
                        color: Colors.grey.shade600, fontSize: 12.5),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: canCreate ? _create : null,
            style:
                FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
            child: const Text('Create server'),
          ),
        ],
      ),
    );
  }

  Widget _sectionLabel(String text) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 20, 4, 8),
        child: Text(text,
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.6,
                color: Colors.grey.shade500)),
      );

  // A Material, not a decorated Container: the tiles inside paint their ink
  // on the nearest Material, which a plain decoration would sit on top of.
  Widget _card({required List<Widget> children}) => Material(
        color: Theme.of(context)
            .colorScheme
            .surfaceContainerHighest
            .withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(14),
        clipBehavior: Clip.antiAlias,
        child:
            Column(mainAxisSize: MainAxisSize.min, children: children),
      );

  Widget _iconChoice(
      {required bool selected,
      required VoidCallback onTap,
      required Widget child}) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Container(
        width: 42,
        height: 42,
        decoration: BoxDecoration(
          color: selected
              ? scheme.primary.withValues(alpha: 0.15)
              : Colors.grey.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(12),
          border:
              selected ? Border.all(color: scheme.primary, width: 2) : null,
        ),
        alignment: Alignment.center,
        child: child,
      ),
    );
  }
}
