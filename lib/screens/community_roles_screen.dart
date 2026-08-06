import 'package:flutter/material.dart';

import '../models/community.dart';
import '../state/community_store.dart';
import '../widgets/app_dialogs.dart';

Color _hex(String s) => Color(int.parse(s.replaceFirst('#', 'ff'), radix: 16));

/// The palette a role can wear — bright, distinct hues that read on both a
/// light and a dark member list.
const roleColorPalette = [
  '#E0533D', '#E8892B', '#F1C40F', '#12B76A', '#009DE2',
  '#7A5CFF', '#EF5DA8', '#0F9B8E', '#8B5CF6', '#5C7079',
];

/// A one-line description of what a role's tier grants, said in plain terms
/// rather than by the enum name.
String roleTierBlurb(MemberRole tier) => switch (tier) {
      MemberRole.admin =>
        'Grants admin — server settings, channels, roles, members',
      MemberRole.moderator =>
        'Grants moderator — delete & pin, mute, kick and ban',
      _ => 'Cosmetic — a coloured badge, no extra powers',
    };

/// Where a server owner or admin builds the roles they hand out: named,
/// coloured labels that badge a member and can lift what they're allowed to
/// do. A role's colour and name show beside the member everywhere; its tier
/// composes with the built-in owner/admin/moderator/member ladder, so a
/// moderator-tier role really can moderate.
class CommunityRolesScreen extends StatelessWidget {
  final String communityId;
  const CommunityRolesScreen({super.key, required this.communityId});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: CommunityStore.instance,
      builder: (context, _) {
        final store = CommunityStore.instance;
        final community = store.byId(communityId);
        if (community == null) {
          return const Scaffold(body: Center(child: Text('Not found')));
        }
        final canManage = store.canManageServer(communityId);
        final roles = community.roles;
        return Scaffold(
          appBar: AppBar(
            title: const Text('Roles'),
            actions: [
              if (canManage)
                IconButton(
                  icon: const Icon(Icons.add),
                  tooltip: 'New role',
                  onPressed: () => _editRole(context, communityId, null),
                ),
            ],
          ),
          body: ListView(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                child: Text(
                  'A role is a coloured label you hand to members. Give it a '
                  'permission tier to let it grant moderator or admin powers, '
                  'or leave it cosmetic — just a badge. Assign roles from the '
                  'member list.',
                  style: TextStyle(
                      fontSize: 13.5,
                      height: 1.4,
                      color: Theme.of(context).colorScheme.onSurfaceVariant),
                ),
              ),
              if (roles.isEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 40, 20, 20),
                  child: Column(
                    children: [
                      Icon(Icons.workspace_premium_outlined,
                          size: 48, color: Colors.grey.shade400),
                      const SizedBox(height: 12),
                      const Text('No roles yet',
                          style: TextStyle(
                              fontSize: 16, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 6),
                      Text(
                        canManage
                            ? 'Tap + to create your first one.'
                            : 'The server\'s admins haven\'t made any.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
              for (final role in roles)
                ListTile(
                  leading: Container(
                    width: 26,
                    height: 26,
                    decoration: BoxDecoration(
                      color: _hex(role.color),
                      shape: BoxShape.circle,
                    ),
                  ),
                  title: Text(role.name,
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: Text(roleTierBlurb(role.tier),
                      maxLines: 2, overflow: TextOverflow.ellipsis),
                  trailing: canManage
                      ? PopupMenuButton<String>(
                          tooltip: 'Manage role',
                          onSelected: (a) {
                            if (a == 'edit') {
                              _editRole(context, communityId, role);
                            } else if (a == 'delete') {
                              _deleteRole(context, communityId, role);
                            }
                          },
                          itemBuilder: (_) => const [
                            PopupMenuItem(value: 'edit', child: Text('Edit')),
                            PopupMenuItem(
                                value: 'delete', child: Text('Delete')),
                          ],
                        )
                      : null,
                  onTap: canManage
                      ? () => _editRole(context, communityId, role)
                      : null,
                ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _deleteRole(
      BuildContext context, String communityId, CustomRole role) async {
    final sure = await showAppConfirmDialog(
      context,
      icon: Icons.delete_outline,
      title: 'Delete "${role.name}"?',
      message: 'Members wearing it lose the badge and any powers it granted. '
          'This can\'t be undone.',
      confirmLabel: 'Delete',
      destructive: true,
    );
    if (sure) CommunityStore.instance.deleteRole(communityId, role.id);
  }

  void _editRole(
      BuildContext context, String communityId, CustomRole? existing) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) =>
          _RoleEditor(communityId: communityId, existing: existing),
    );
  }
}

class _RoleEditor extends StatefulWidget {
  final String communityId;
  final CustomRole? existing;
  const _RoleEditor({required this.communityId, this.existing});

  @override
  State<_RoleEditor> createState() => _RoleEditorState();
}

class _RoleEditorState extends State<_RoleEditor> {
  late final TextEditingController _name =
      TextEditingController(text: widget.existing?.name ?? '');
  late String _color = widget.existing?.color ?? roleColorPalette.first;
  late MemberRole _tier = widget.existing?.tier ?? MemberRole.member;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _save() {
    final name = _name.text.trim();
    if (name.isEmpty) return;
    final store = CommunityStore.instance;
    if (widget.existing == null) {
      store.addRole(widget.communityId, name, color: _color, tier: _tier);
    } else {
      store.updateRole(widget.communityId, widget.existing!.id,
          name: name, color: _color, tier: _tier);
    }
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.fromLTRB(
          20, 4, 20, 20 + MediaQuery.of(context).viewInsets.bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(widget.existing == null ? 'New role' : 'Edit role',
              style:
                  const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          const SizedBox(height: 16),
          TextField(
            controller: _name,
            autofocus: true,
            textCapitalization: TextCapitalization.words,
            maxLength: 24,
            decoration: const InputDecoration(
              labelText: 'Role name',
              hintText: 'e.g. Helper, VIP, Team',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: Text('Colour',
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: scheme.onSurfaceVariant)),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final c in roleColorPalette)
                GestureDetector(
                  onTap: () => setState(() => _color = c),
                  child: Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      color: _hex(c),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: _color == c ? scheme.onSurface : Colors.transparent,
                        width: 2.5,
                      ),
                    ),
                    child: _color == c
                        ? const Icon(Icons.check, color: Colors.white, size: 18)
                        : null,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 18),
          Align(
            alignment: Alignment.centerLeft,
            child: Text('Permissions',
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: scheme.onSurfaceVariant)),
          ),
          const SizedBox(height: 8),
          for (final tier in customRoleTiers)
            ListTile(
              contentPadding: EdgeInsets.zero,
              onTap: () => setState(() => _tier = tier),
              leading: Icon(_tier == tier
                  ? Icons.radio_button_checked
                  : Icons.radio_button_off),
              title: Text(roleName(tier),
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Text(roleTierBlurb(tier)),
            ),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: _save,
            child: Text(widget.existing == null ? 'Create role' : 'Save'),
          ),
        ],
      ),
    );
  }
}
