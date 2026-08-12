import 'package:flutter/material.dart';

import '../app_state.dart';
import '../models/chat.dart';
import '../state/chat_store.dart';
import '../state/contacts_store.dart';
import '../state/session.dart';
import '../theme/app_theme.dart';
import '../widgets/app_dialogs.dart';
import '../widgets/empty_state.dart';
import '../widgets/invite_prompt.dart';
import '../widgets/user_avatar.dart';
import 'chat_screen.dart';

/// The saved-contacts address book: a place to keep people whether or not you
/// have ever chatted. Add a contact by name + number/username, keep a note,
/// and message them in one tap. Local to the device, like the rest of the app.
class ContactsScreen extends StatefulWidget {
  const ContactsScreen({super.key, this.fromSidebar = false});

  /// True when opened from the sidebar — shows a ☰ that reopens the sidebar
  /// instead of a back arrow.
  final bool fromSidebar;

  @override
  State<ContactsScreen> createState() => _ContactsScreenState();
}

class _ContactsScreenState extends State<ContactsScreen> {
  final _search = TextEditingController();
  bool _searching = false;

  @override
  void initState() {
    super.initState();
    ContactsStore.instance.load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  /// Message a saved contact — opens their chat, creating it (and running the
  /// unknown-number invite gate) the first time, exactly like People does.
  Future<void> _message(SavedContact c) async {
    if (!c.canMessage) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Add a phone number or username to message them.')));
      return;
    }
    final store = ChatStore.instance;
    final key = c.addressKey;
    if (store.isOwnNumber(key, myPhone: Session.instance.user.value?.phone)) {
      final self = store.noteToSelfChat(myAvatarColor: AppState.profile.value.avatarColor);
      if (!mounted) return;
      Navigator.of(context)
          .push(MaterialPageRoute(builder: (_) => ChatScreen(chat: self)));
      return;
    }
    var chat = store.chatWithContact(key);
    if (chat == null) {
      // A phone we've never reached gets the invite gate; a username-only
      // contact resolves through the directory, so it goes straight through.
      if (c.phone.isNotEmpty) {
        if (!await allowChatWithNumber(context, key)) return;
        if (!mounted) return;
      }
      chat = Chat(id: 'chat_$key', contact: c.toUser(), messages: const []);
      store.upsert(chat);
    }
    if (!mounted) return;
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => ChatScreen(chat: chat!)));
  }

  /// The add/edit form — name, number, username, note. Name is the only
  /// required field; a contact can be a name you jot down before you have
  /// anything else.
  Future<void> _edit([SavedContact? existing]) async {
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => _ContactEditor(existing: existing),
    );
    if (saved == true && mounted) setState(() {});
  }

  /// The row's actions: message, edit, or delete.
  Future<void> _openActions(SavedContact c) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 10),
              child: Row(
                children: [
                  UserAvatar(user: c.toUser(), radius: 22),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(c.name,
                            style: const TextStyle(
                                fontSize: 16, fontWeight: FontWeight.w700)),
                        if (c.subtitle.isNotEmpty)
                          Text(c.subtitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(color: AppColors.subtle(context))),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            ListTile(
              leading: const Icon(Icons.chat_bubble_outline),
              title: const Text('Message'),
              enabled: c.canMessage,
              onTap: () => Navigator.of(sheetContext).pop('message'),
            ),
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('Edit contact'),
              onTap: () => Navigator.of(sheetContext).pop('edit'),
            ),
            ListTile(
              leading: Icon(Icons.delete_outline,
                  color: Theme.of(context).colorScheme.error),
              title: Text('Delete',
                  style: TextStyle(color: Theme.of(context).colorScheme.error)),
              onTap: () => Navigator.of(sheetContext).pop('delete'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case 'message':
        await _message(c);
      case 'edit':
        await _edit(c);
      case 'delete':
        final ok = await showAppConfirmDialog(
          context,
          icon: Icons.delete_outline,
          title: 'Delete contact?',
          message: '${c.name} is removed from your saved contacts. Your chats '
              'with them are not affected.',
          confirmLabel: 'Delete',
          destructive: true,
        );
        if (ok) await ContactsStore.instance.delete(c.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: _searching
            ? TextField(
                controller: _search,
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: 'Search contacts',
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  filled: false,
                ),
                onChanged: (_) => setState(() {}),
              )
            : const Text('Contacts'),
        actions: [
          IconButton(
            icon: Icon(_searching ? Icons.close : Icons.search),
            tooltip: _searching ? 'Stop searching' : 'Search contacts',
            onPressed: () => setState(() {
              _searching = !_searching;
              if (!_searching) _search.clear();
            }),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(),
        icon: const Icon(Icons.person_add_alt_1),
        label: const Text('Add contact'),
      ),
      body: ListenableBuilder(
        listenable: ContactsStore.instance,
        builder: (context, _) {
          final contacts = ContactsStore.instance.search(_search.text);
          if (contacts.isEmpty) {
            return _search.text.trim().isNotEmpty
                ? const EmptyState(
                    icon: Icons.search_off,
                    title: 'No matches',
                    caption: 'No saved contact matches that.',
                  )
                : EmptyState(
                    icon: Icons.contacts_outlined,
                    title: 'No saved contacts yet',
                    caption: 'Keep the people you know here — add a name with '
                        'their number or username, and message them anytime.',
                    actionLabel: 'Add contact',
                    onAction: () => _edit(),
                  );
          }
          return ListView.separated(
            padding: const EdgeInsets.only(bottom: 96),
            itemCount: contacts.length,
            separatorBuilder: (_, __) =>
                const Divider(height: 1, indent: 72),
            itemBuilder: (context, i) {
              final c = contacts[i];
              return ListTile(
                leading: UserAvatar(user: c.toUser(), radius: 22),
                title: Text(c.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                subtitle: c.subtitle.isEmpty
                    ? null
                    : Text(c.subtitle,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                trailing: c.canMessage
                    ? IconButton(
                        icon: const Icon(Icons.chat_bubble_outline),
                        tooltip: 'Message',
                        onPressed: () => _message(c),
                      )
                    : null,
                onTap: () => _openActions(c),
              );
            },
          );
        },
      ),
    );
  }
}

/// The add/edit form, popped with `true` when a contact was saved.
class _ContactEditor extends StatefulWidget {
  const _ContactEditor({this.existing});
  final SavedContact? existing;

  @override
  State<_ContactEditor> createState() => _ContactEditorState();
}

class _ContactEditorState extends State<_ContactEditor> {
  late final TextEditingController _name;
  late final TextEditingController _phone;
  late final TextEditingController _username;
  late final TextEditingController _note;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _name = TextEditingController(text: e?.name ?? '');
    _phone = TextEditingController(text: e?.phone ?? '');
    _username = TextEditingController(text: e?.username ?? '');
    _note = TextEditingController(text: e?.note ?? '');
  }

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _username.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    if (_name.text.trim().isEmpty) {
      messenger.showSnackBar(
          const SnackBar(content: Text('A contact needs a name.')));
      return;
    }
    await ContactsStore.instance.save(
      id: widget.existing?.id,
      name: _name.text,
      phone: _phone.text,
      username: _username.text,
      note: _note.text,
    );
    navigator.pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final editing = widget.existing != null;
    return Padding(
      padding: EdgeInsets.fromLTRB(
          20, 0, 20, MediaQuery.of(context).viewInsets.bottom + 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: Text(editing ? 'Edit contact' : 'New contact',
                style:
                    const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _name,
            autofocus: !editing,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(
              labelText: 'Name',
              prefixIcon: Icon(Icons.person_outline),
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _phone,
            keyboardType: TextInputType.phone,
            decoration: const InputDecoration(
              labelText: 'Phone number (optional)',
              hintText: '+1 555 0199',
              prefixIcon: Icon(Icons.phone_outlined),
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _username,
            decoration: const InputDecoration(
              labelText: 'Username (optional)',
              hintText: 'alex',
              prefixIcon: Icon(Icons.alternate_email),
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _note,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'Note (optional)',
              hintText: 'How you know them',
              prefixIcon: Icon(Icons.sticky_note_2_outlined),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _save,
            child: Text(editing ? 'Save' : 'Add contact'),
          ),
        ],
      ),
    );
  }
}
