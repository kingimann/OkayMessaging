import 'dart:async';

import 'package:flutter/material.dart';

import '../models/chat.dart';
import '../models/message.dart';
import '../relay/relay_service.dart';
import '../state/chat_store.dart';
import '../state/poke_sender.dart';
import '../util/haptics.dart';
import 'user_avatar.dart';

/// An app-wide banner that drops in whenever a poke lands — in ANY chat, from
/// wherever you are in the app — with a one-tap "Poke back". A poke's whole
/// point is a quick back-and-forth, and until now the poked person had to hunt
/// the conversation down to answer. It auto-dismisses, and never appears for
/// the chat you're already looking at (the poke chip is right there).
class PokeBackBanner extends StatefulWidget {
  const PokeBackBanner({super.key});

  @override
  State<PokeBackBanner> createState() => _PokeBackBannerState();
}

class _PokeBackBannerState extends State<PokeBackBanner> {
  final _store = ChatStore.instance;
  Chat? _shown;
  String? _handledPokeId;
  Timer? _dismiss;

  @override
  void initState() {
    super.initState();
    // Start from the poke already sitting on screen, if any, so a poke that
    // arrived before this session doesn't pop a banner on launch.
    _handledPokeId = _latestIncomingPoke()?.$2.id;
    _store.addListener(_onChange);
  }

  @override
  void dispose() {
    _store.removeListener(_onChange);
    _dismiss?.cancel();
    super.dispose();
  }

  /// The newest incoming poke across all chats, as (chat, message). A poke
  /// arrives as a chat's last message, so that is all we need to look at.
  (Chat, Message)? _latestIncomingPoke() {
    Chat? bestChat;
    Message? best;
    for (final chat in _store.allChats) {
      final m = chat.lastMessage;
      if (m == null || !m.isPoke || m.isMe) continue;
      if (best == null || m.time.isAfter(best.time)) {
        best = m;
        bestChat = chat;
      }
    }
    return (bestChat == null || best == null) ? null : (bestChat, best);
  }

  void _onChange() {
    final latest = _latestIncomingPoke();
    if (latest == null) return;
    final (chat, msg) = latest;
    if (msg.id == _handledPokeId) return; // already reacted to this one
    _handledPokeId = msg.id;

    // Not while you're inside that very chat — its own poke chip already
    // offers the tap-back, and a banner over it would be a double.
    final digits = RelayService.digits(chat.contact.phone);
    if (!chat.contact.isGroup &&
        digits.isNotEmpty &&
        digits == RelayService.instance.openChatDigits) {
      return;
    }

    setState(() => _shown = chat);
    _dismiss?.cancel();
    _dismiss = Timer(const Duration(seconds: 6), () {
      if (mounted) setState(() => _shown = null);
    });
  }

  void _hide() {
    _dismiss?.cancel();
    setState(() => _shown = null);
  }

  void _pokeBack() {
    final chat = _shown;
    if (chat == null) return;
    pokeChat(chat.id);
    Haptics.press();
    _hide();
  }

  @override
  Widget build(BuildContext context) {
    final chat = _shown;
    if (chat == null) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: Align(
        alignment: Alignment.topCenter,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 0),
          child: Material(
            elevation: 6,
            borderRadius: BorderRadius.circular(16),
            color: scheme.surfaceContainerHighest,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
              child: Row(
                children: [
                  UserAvatar(user: chat.contact, radius: 18),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '👉 ${chat.contact.name} poked you',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                  const SizedBox(width: 6),
                  FilledButton(
                    onPressed: _pokeBack,
                    style: FilledButton.styleFrom(
                        visualDensity: VisualDensity.compact),
                    child: const Text('Poke back'),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 20),
                    tooltip: 'Dismiss',
                    onPressed: _hide,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
