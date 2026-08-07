import '../models/message.dart';
import '../relay/relay_config.dart';
import '../relay/relay_service.dart';
import 'chat_store.dart';
import 'score_store.dart';

/// Sends a poke to [chatId] — the ONE place a poke is minted, so the chat's own
/// poke button and the app-wide "Poke back" banner send exactly the same thing:
/// a real, wordless "👉 Poke" message that rides the mailbox (offline reach),
/// push (a pocket buzz) and the chat list count.
///
/// Respects the per-chat cooldown, because a poke that can be spammed is a
/// harassment button. Returns 0 on success, or the number of seconds still to
/// wait when the cooldown declined it.
int pokeChat(String chatId, {String? threadRootId}) {
  final store = ChatStore.instance;
  final left = store.pokeCooldownLeft(chatId);
  if (left > Duration.zero) return left.inSeconds + 1;

  final chat = store.chatById(chatId);
  if (chat == null) return 0;

  store.notePoked(chatId);
  ScoreStore.instance.recordFlag('poked');

  final now = DateTime.now();
  var message = Message(
    id: 'local_${now.microsecondsSinceEpoch}',
    text: '👉 Poke',
    time: now,
    isMe: true,
    status: MessageStatus.sent,
    isPoke: true,
  );
  // The same funnels the chat's own send path applies, so a poke behaves
  // identically whichever button sent it.
  if (store.isProtected(chatId)) message = message.copyWith(protected: true);
  if (chat.marketplace) message = message.copyWith(marketplace: true);
  if (threadRootId != null) {
    message = message.copyWith(threadRootId: threadRootId);
  }

  store.addMessage(chatId, message);

  if (RelayConfig.isEnabled) {
    final contact = chat.contact;
    if (contact.isGroup) {
      RelayService.instance.sendToGroup(chat, message);
    } else if (contact.phone.isNotEmpty && contact.id == contact.phone) {
      // A real peer (not a demo chat or note-to-self).
      RelayService.instance.send(contact.phone, message);
    }
  }
  return 0;
}
