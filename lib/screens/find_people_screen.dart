import 'dart:async';

import 'package:flutter/material.dart';

import '../models/chat.dart';
import '../models/user.dart';
import '../state/account_service.dart';
import '../state/call_service.dart' show CallService;
import '../state/chat_store.dart';
import '../widgets/user_avatar.dart';
import '../widgets/verified_badge.dart';
import 'chat_screen.dart';

/// Find other people on OkayMessenger by their @username and start a chat or
/// call with them. Backed by the server directory (the `usernames` table);
/// results are empty unless you're signed in with a verified account.
class FindPeopleScreen extends StatefulWidget {
  const FindPeopleScreen({super.key});

  @override
  State<FindPeopleScreen> createState() => _FindPeopleScreenState();
}

class _FindPeopleScreenState extends State<FindPeopleScreen> {
  final _controller = TextEditingController();
  Timer? _debounce;
  int _seq = 0;
  bool _searching = false;
  List<AppUser> _results = const [];
  String _query = '';

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String text) {
    _debounce?.cancel();
    final q = text.trim();
    setState(() => _query = q);
    if (q.length < 2) {
      setState(() {
        _results = const [];
        _searching = false;
      });
      return;
    }
    setState(() => _searching = true);
    _debounce = Timer(const Duration(milliseconds: 300), () async {
      final seq = ++_seq;
      final found = await AccountService.instance.searchByUsername(q);
      if (!mounted || seq != _seq) return;
      setState(() {
        _searching = false;
        _results = found;
      });
    });
  }

  void _message(AppUser user) {
    final store = ChatStore.instance;
    final existing = store.chatWithContact(user.id);
    final Chat chat;
    if (existing != null) {
      if (existing.isArchived) store.setArchived(existing.id, false);
      chat = existing;
    } else {
      chat = Chat(id: 'chat_${user.id}', contact: user, messages: const []);
      store.upsert(chat);
    }
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => ChatScreen(chat: chat)),
    );
  }

  void _call(AppUser user, {required bool video}) {
    CallService.instance.startOutgoing(user, video: video);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Find people'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(62),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
            child: TextField(
              controller: _controller,
              autofocus: true,
              textInputAction: TextInputAction.search,
              onChanged: _onChanged,
              decoration: InputDecoration(
                hintText: 'Search by username',
                prefixIcon: const Icon(Icons.alternate_email),
                suffixIcon: _controller.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close),
                        tooltip: 'Clear',
                        onPressed: () {
                          _controller.clear();
                          _onChanged('');
                        },
                      ),
                filled: true,
                fillColor: Theme.of(context).colorScheme.surface,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                  borderSide: BorderSide.none,
                ),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
              ),
            ),
          ),
        ),
      ),
      body: _body(),
    );
  }

  Widget _body() {
    if (_searching) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_query.length < 2) {
      return _hint(
        Icons.alternate_email,
        'Find people by username',
        'Type at least two characters of a username to find people on '
            'OkayMessenger.',
      );
    }
    if (_results.isEmpty) {
      return _hint(
        Icons.person_search_outlined,
        'No one found',
        'No one on OkayMessenger matches "$_query". Check the spelling or try '
            'a different username.',
      );
    }
    return ListView.builder(
      itemCount: _results.length,
      itemBuilder: (context, i) {
        final user = _results[i];
        return ListTile(
          leading: UserAvatar(user: user, radius: 24),
          title: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(user.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600)),
              ),
              if (user.verified) ...[
                const SizedBox(width: 4),
                const VerifiedBadge(size: 15),
              ],
            ],
          ),
          subtitle: user.username.isEmpty ? null : Text('@${user.username}'),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                icon: const Icon(Icons.call),
                tooltip: 'Voice call',
                onPressed: () => _call(user, video: false),
              ),
              IconButton(
                icon: const Icon(Icons.videocam),
                tooltip: 'Video call',
                onPressed: () => _call(user, video: true),
              ),
            ],
          ),
          onTap: () => _message(user),
        );
      },
    );
  }

  Widget _hint(IconData icon, String title, String body) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 52, color: Colors.grey.shade400),
            const SizedBox(height: 16),
            Text(title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontSize: 17, fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            Text(body,
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey.shade600, fontSize: 14)),
          ],
        ),
      ),
    );
  }
}
