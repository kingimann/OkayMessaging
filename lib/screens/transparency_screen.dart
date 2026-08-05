import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// The user-facing half of docs/lawful_requests.md: what the server can
/// see, what it can never see, and what that means if somebody with legal
/// power asks. Plain words, no reassurance the architecture can't back —
/// the whole point of the page is that it stays true under subpoena.
class TransparencyScreen extends StatelessWidget {
  const TransparencyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    Widget heading(String text) => Padding(
          padding: const EdgeInsets.fromLTRB(0, 22, 0, 6),
          child: Text(text.toUpperCase(),
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.6,
                  color: AppColors.subtle(context))),
        );
    Widget body(String text) => Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(text,
              style: const TextStyle(fontSize: 14.5, height: 1.45)),
        );
    return Scaffold(
      appBar: AppBar(title: const Text('What the server can see')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
        children: [
          body('This page is the honest version, written to stay true even '
              'if a government asks us for data. It says what our server '
              'holds, what it can never hold, and what that means for you.'),
          heading('What is never on the server'),
          body('Your messages. Every message — one-to-one, group, and '
              'server chat — is encrypted on your phone before it leaves, '
              'and only the phones in the conversation hold the keys. The '
              'same is true of calls, photos and voice notes sent in chat, '
              'form answers, your chat list, your contacts, and your notes. '
              'We cannot read any of it, so nobody can make us hand it '
              'over. There is no "trust us" in that sentence — the server '
              'only ever stores sealed envelopes it cannot open.'),
          heading('What the server does hold'),
          body('Your phone number, username, and display name — the '
              'directory that lets people find you. Your email, if you '
              'added one. The public newsfeed in full, because it is '
              'public: posts, likes, poll votes, and follows are real '
              'records on the server. Payment history and your verified '
              'legal name, if you use the wallet or the blue check — '
              'Stripe holds the ID documents. And delivery metadata: when '
              'a message waits for an offline phone, the server briefly '
              'holds a sealed envelope labeled with who it is for and '
              'when — deleted on delivery, and swept after 14 days at the '
              'latest. Between up-to-date phones the envelope no longer '
              'says who it is FROM either; older apps, and the first '
              'messages between two people, still name the sender for '
              'routing.'),
          heading('If the law asks'),
          body('A legal order could get everything in the list above: who '
              'you are, who you message and when (within that 14-day '
              'window), who you follow, what you posted publicly, and what '
              'you paid whom. It could not get what any message says — we '
              'do not have the keys, and an order cannot conjure them. A '
              'court could also order us to start recording delivery '
              'metadata going forward. We tell you this here because a '
              'privacy page that only lists the good news is advertising, '
              'not information.'),
          heading('One thing you control'),
          body('Cloud backups protected only by your phone number\'s '
              'default key are weaker than backups protected by a '
              'passphrase you chose. If your backup matters, set a '
              'passphrase — then it is ciphertext to us like everything '
              'else. Chats are never in the backup either way.'),
          heading('Third parties'),
          body('Stripe (payments and identity checks), Apple (push '
              'notifications and purchases — notification titles carry '
              'sender names), our hosting provider (connection logs and IP '
              'addresses), and the call relay (IP addresses during calls) '
              'each hold their own records, under their own policies.'),
          const SizedBox(height: 8),
          Text(
            'This page changes when the architecture changes — it is kept '
            'in step with the technical documentation, and a test fails '
            'when the two drift.',
            style:
                TextStyle(fontSize: 12.5, color: AppColors.subtle(context)),
          ),
        ],
      ),
    );
  }
}
