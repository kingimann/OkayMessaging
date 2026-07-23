import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/community.dart';
import '../state/community_store.dart';
import '../widgets/info_section.dart';

Color _hex(String s) => Color(int.parse(s.replaceFirst('#', 'ff'), radix: 16));

const _palette = [
  '#7A5CFF', '#12B76A', '#F1C40F', '#EF5DA8', '#009DE2',
  '#F97052', '#8B5CF6', '#0F1419',
];

/// Owner/admin controls for a community: rename, recolor, invite link, delete.
class CommunitySettingsScreen extends StatelessWidget {
  final String communityId;
  const CommunitySettingsScreen({super.key, required this.communityId});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: CommunityStore.instance,
      builder: (context, _) {
        final community = CommunityStore.instance.byId(communityId);
        if (community == null) {
          return const Scaffold(body: Center(child: Text('Not found')));
        }
        return Scaffold(
          appBar: AppBar(title: const Text('Server settings')),
          body: ListView(
            children: [
              const SizedBox(height: 8),
              Center(
                child: CircleAvatar(
                  radius: 40,
                  backgroundColor: _hex(community.color),
                  child: Text(community.name[0].toUpperCase(),
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 32,
                          fontWeight: FontWeight.w800)),
                ),
              ),
              const SizedBox(height: 16),
              InfoSection(children: [
                InfoTile(
                  leading: const Icon(Icons.drive_file_rename_outline),
                  title: 'Server name',
                  subtitle: community.name,
                  onTap: () => _rename(context, community),
                ),
                InfoTile(
                  leading: const Icon(Icons.notes_outlined),
                  title: 'Description',
                  subtitle: community.description.isEmpty
                      ? 'Add a description'
                      : community.description,
                  onTap: () => _editDescription(context, community),
                ),
              ]),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 12, 24, 6),
                child: Text('COLOR',
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.6,
                        color: Colors.grey.shade500)),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Wrap(
                  spacing: 14,
                  runSpacing: 14,
                  children: [
                    for (final c in _palette)
                      GestureDetector(
                        onTap: () => CommunityStore.instance
                            .setCommunityColor(communityId, c),
                        child: Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            color: _hex(c),
                            shape: BoxShape.circle,
                            border: community.color == c
                                ? Border.all(
                                    color: Theme.of(context).colorScheme.primary,
                                    width: 3)
                                : null,
                          ),
                          child: community.color == c
                              ? const Icon(Icons.check, color: Colors.white)
                              : null,
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              InfoSection(children: [
                InfoTile(
                  leading: const Icon(Icons.link),
                  title: 'Invite link',
                  subtitle: CommunityStore.inviteLink(community),
                  trailing: const Icon(Icons.copy, size: 20),
                  onTap: () {
                    Clipboard.setData(ClipboardData(
                        text: CommunityStore.inviteLink(community)));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Invite link copied')),
                    );
                  },
                ),
              ]),
              InfoSection(children: [
                InfoTile(
                  leading: const Icon(Icons.delete_outline, color: Colors.red),
                  title: 'Delete server',
                  titleColor: Colors.red,
                  onTap: () => _confirmDelete(context, community),
                ),
              ]),
              const SizedBox(height: 24),
            ],
          ),
        );
      },
    );
  }

  Future<void> _rename(BuildContext context, Community community) async {
    final controller = TextEditingController(text: community.name);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename server'),
        content: TextField(controller: controller, autofocus: true),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, controller.text.trim()),
              child: const Text('Save')),
        ],
      ),
    );
    if (name != null && name.isNotEmpty) {
      CommunityStore.instance.renameCommunity(communityId, name);
    }
  }

  Future<void> _editDescription(
      BuildContext context, Community community) async {
    final controller = TextEditingController(text: community.description);
    final desc = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Server description'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 3,
          maxLength: 140,
          decoration: const InputDecoration(
              hintText: 'What is this server about?'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, controller.text.trim()),
              child: const Text('Save')),
        ],
      ),
    );
    if (desc != null) {
      CommunityStore.instance.setCommunityDescription(communityId, desc);
    }
  }

  Future<void> _confirmDelete(BuildContext context, Community community) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete "${community.name}"?'),
        content: const Text(
            'This permanently removes the server and all its channels for you.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child:
                  const Text('Delete', style: TextStyle(color: Colors.red))),
        ],
      ),
    );
    if (ok == true && context.mounted) {
      CommunityStore.instance.deleteCommunity(communityId);
      Navigator.of(context).popUntil((r) => r.isFirst);
    }
  }
}
