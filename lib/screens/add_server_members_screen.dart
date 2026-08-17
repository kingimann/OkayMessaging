import 'dart:convert';

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../models/community.dart';
import '../models/message.dart';
import '../models/user.dart';
import '../relay/relay_config.dart';
import '../relay/relay_service.dart';
import '../state/chat_store.dart';
import '../state/community_store.dart';
import '../theme/app_theme.dart';
import '../widgets/user_avatar.dart';
import 'create_group_screen.dart';

/// Lets a server admin/owner ADD contacts to a server directly — the
/// WhatsApp-group "add people" that the invite-and-wait flow can't do. Picked
/// contacts are put on the roster now (every member's copy converges) and each
/// is sent the server invite flagged so their device joins on receipt.
class AddServerMembersScreen extends StatefulWidget {
  final Community community;
  const AddServerMembersScreen({super.key, required this.community});

  @override
  State<AddServerMembersScreen> createState() => _AddServerMembersScreenState();
}

class _AddServerMembersScreenState extends State<AddServerMembersScreen> {
  final _selected = <AppUser>{};

  /// Real, reachable contacts who are not already in this server.
  List<AppUser> _candidates() {
    final store = CommunityStore.instance;
    final community = store.byId(widget.community.id) ?? widget.community;
    final present = community.members.map((m) => m.id).toSet();
    String digits(String p) => p.replaceAll(RegExp(r'\D'), '');
    return groupCandidates().where((c) {
      final d = digits(c.phone);
      if (d.isEmpty) return false; // no number → no inbox to add them through
      return !present.contains(CommunityStore.wireId(d));
    }).toList();
  }

  void _toggle(AppUser user) {
    setState(() {
      if (!_selected.remove(user)) _selected.add(user);
    });
  }

  void _add() {
    final store = CommunityStore.instance;
    final me = AppState.profile.value;
    final myDigits = me.phone.replaceAll(RegExp(r'\D'), '');
    final newMembers = [
      for (final c in _selected)
        Member(
          id: CommunityStore.wireId(c.phone.replaceAll(RegExp(r'\D'), '')),
          name: c.name.isEmpty ? 'Member' : c.name,
        ),
    ];
    // Roster + structure broadcast, and the invite snapshot to hand each one.
    final snapshot = store.addMembersByAdmin(
      widget.community.id,
      newMembers,
      myDigits: myDigits,
      myName: me.name,
    );
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    if (snapshot == null) {
      messenger.showSnackBar(const SnackBar(
          content: Text('Only an admin can add members here.')));
      return;
    }
    final invite = jsonEncode(snapshot);
    final chats = ChatStore.instance;
    final now = DateTime.now();
    for (final c in _selected) {
      // The text rides the wire, so it is written from the RECIPIENT's side:
      // "Added you to X" is right on their screen. That same sentence read
      // backwards in the ADDER's own chat list ("it says she added me"), so
      // the copy kept locally is worded from the adder's side instead.
      final theirName = c.name.trim().isEmpty ? 'them' : c.name.trim();
      final wire = Message(
        id: 'inv_${c.phone}_${now.microsecondsSinceEpoch}_${c.id.hashCode}',
        text: 'Added you to "${widget.community.name}"',
        time: now,
        isMe: true,
        status: MessageStatus.sent,
        serverInvite: invite,
      );
      // Keep a record in the admin's own 1:1 with them, worded from the adder's
      // side. Resolve the chat by CONTACT (id or phone), not a constructed
      // 'chat_<phone>' id — that guess missed the real chat, so the local copy
      // was skipped and only the recipient-worded wire text was ever seen.
      final existing = chats.chatWithContact(c.id) ?? chats.chatWithContact(c.phone);
      if (existing != null) {
        chats.addMessage(
            existing.id,
            wire.copyWith(
                text: 'You added $theirName to "${widget.community.name}"'));
      }
      // Deliver the invite over the relay so their device receives it and
      // auto-joins. send() does NOT store locally, so the adder never sees the
      // recipient-worded "Added you to" text from this.
      if (RelayConfig.isEnabled) {
        RelayService.instance.send(c.phone, wire);
      }
    }
    navigator.pop();
    messenger.showSnackBar(SnackBar(
        content: Text(_selected.length == 1
            ? 'Added ${_selected.first.name}'
            : 'Added ${_selected.length} people')));
  }

  @override
  Widget build(BuildContext context) {
    final contacts = _candidates();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Add members'),
        actions: [
          TextButton(
            onPressed: _selected.isEmpty ? null : _add,
            child: Text(_selected.isEmpty ? 'Add' : 'Add (${_selected.length})'),
          ),
        ],
      ),
      body: contacts.isEmpty
          ? _EmptyContacts(alreadyIn: widget.community.members.length > 1)
          : ListView(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Text(
                    'People you add join right away and can see the server. '
                    'They can leave anytime.',
                    style: TextStyle(
                        fontSize: 13, color: AppColors.subtle(context)),
                  ),
                ),
                for (final c in contacts)
                  CheckboxListTile(
                    value: _selected.contains(c),
                    onChanged: (_) => _toggle(c),
                    secondary: UserAvatar(user: c, radius: 22),
                    title: Text(c.name,
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: Text(c.bio,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    activeColor: AppColors.accentOn(context),
                    controlAffinity: ListTileControlAffinity.trailing,
                  ),
              ],
            ),
    );
  }
}

class _EmptyContacts extends StatelessWidget {
  final bool alreadyIn;
  const _EmptyContacts({required this.alreadyIn});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.person_add_alt_1_outlined,
                size: 46, color: Colors.grey.shade400),
            const SizedBox(height: 12),
            const Text('No one to add',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            Text(
              alreadyIn
                  ? 'Everyone you chat with is already in this server. Use '
                      'Invite to reach someone new.'
                  : 'Start a chat with someone first — everyone you talk to '
                      'shows up here as someone you can add.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13.5, color: AppColors.subtle(context)),
            ),
          ],
        ),
      ),
    );
  }
}
