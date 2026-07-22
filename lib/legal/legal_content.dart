// In-app legal copy. Kept as structured data so the exact same text can be
// published at a public URL (App Store requires a Privacy Policy URL) and
// shown natively. This is a plain-language template describing how the app
// actually works — it is NOT legal advice; have a lawyer review before launch.

class LegalSection {
  final String title;
  final String body;
  const LegalSection(this.title, this.body);
}

const String legalLastUpdated = 'Last updated: 2026';

/// Privacy Policy — reflects the no-storage architecture: messages ride
/// Supabase Realtime Broadcast (memory only) and live only on your devices.
const List<LegalSection> privacyPolicy = [
  LegalSection(
    'The short version',
    'Okay Messaging is built to know as little about you as possible. Your '
        'messages, calls, and media are never stored on our servers. They are '
        'end-to-end encrypted, relayed live between devices, and kept only in '
        'each device’s local storage — so they disappear when you '
        'delete the app.',
  ),
  LegalSection(
    'What we do NOT store',
    '• Message content — text, photos, voice notes, files, polls, '
        'payment notes.\n'
        '• Calls — audio and video are peer-to-peer (WebRTC) and '
        'never recorded.\n'
        '• Media — files are sent device-to-device; the bytes never '
        'touch a server.\n'
        '• Card numbers — payments are handled by Stripe; we never '
        'see or store them.\n\n'
        'Messages are delivered over Supabase Realtime Broadcast, which passes '
        'them through memory only — there is no messages database, and we '
        'do not use Realtime Postgres for message content.',
  ),
  LegalSection(
    'What we DO store',
    '• A username directory: your verified phone number mapped to the '
        'username you choose, so usernames are unique and reachable.\n'
        '• Payment metadata: for money you send/receive we keep the '
        'transaction id, amount, fee, and status (never card data) to show '
        'receipts and payout status. The money itself is held by Stripe, not '
        'us.\n'
        '• Minimal operational logs needed to run and secure the service, '
        'kept only as long as necessary and never containing message content.',
  ),
  LegalSection(
    'End-to-end encryption',
    'Messages and call setup are encrypted on your device with keys only your '
        'devices hold (AES-256-GCM with an ECDH key exchange). The relay '
        'forwards ciphertext it cannot read.',
  ),
  LegalSection(
    'Service providers',
    '• Supabase — realtime message relay and the username directory '
        '(project hosted in Canada, ca-central-1).\n'
        '• Stripe — processes payments and holds/pays out funds under '
        'its own agreements; handles identity verification (KYC) for people who '
        'receive money.\n'
        '• Twilio — sends the one-time SMS code that verifies your '
        'number.',
  ),
  LegalSection(
    'Data retention',
    'Message content: not stored, nothing to retain. Username directory and '
        'payment metadata: kept until you delete your account, then removed. '
        'Operational logs: kept for a short period, then rotated out.',
  ),
  LegalSection(
    'Your rights',
    'Under PIPEDA (Canada) and, where applicable, the GDPR (EU) you can '
        'request access to, correction of, or deletion of the limited data we '
        'hold about you, and withdraw consent. Because we don’t store your '
        'messages, there is no message history for us to hand over or delete.',
  ),
  LegalSection(
    'Safety',
    'You can block and report other users from their profile. Reports are '
        'confidential and help us keep the community safe.',
  ),
  LegalSection(
    'Children',
    'Okay Messaging is not directed to children under 13 (or the minimum age '
        'in your region), and we do not knowingly collect their information.',
  ),
  LegalSection(
    'Contact',
    'Questions about privacy? Reach us at privacy@okay.chat.',
  ),
];

/// Terms of Service.
const List<LegalSection> termsOfService = [
  LegalSection(
    'Acceptance',
    'By using Okay Messaging you agree to these Terms. If you don’t '
        'agree, please don’t use the app.',
  ),
  LegalSection(
    'The service',
    'Okay Messaging is a private, local-first messenger. You are responsible '
        'for the content you send and for keeping your device secure. Because '
        'messages are stored only on devices, keep your own backups if you '
        'want to preserve them.',
  ),
  LegalSection(
    'Payments',
    'In-chat payments are processed by Stripe. When you send or receive money '
        'you agree to the Stripe Connected Account Agreement and Stripe’s '
        'terms. Okay Messaging is not a bank or money-services business, does '
        'not hold your funds, and never takes custody of the money — funds '
        'move from the sender’s card through Stripe to the recipient’s '
        'Stripe account and are paid out to their bank by Stripe. We charge a '
        'small application fee per transaction, shown before you pay. You are '
        'responsible for any taxes on money you receive.',
  ),
  LegalSection(
    'Acceptable use',
    'Don’t use Okay Messaging to break the law, harass others, send spam, '
        'infringe rights, or transmit malware. We may limit or end access that '
        'violates these Terms. Use the in-app block and report tools if someone '
        'is abusing the service.',
  ),
  LegalSection(
    'No warranty',
    'The app is provided “as is” without warranties of any kind. '
        'Message delivery depends on both devices being online at the same '
        'time; we don’t guarantee delivery, since nothing is stored to '
        'retry later.',
  ),
  LegalSection(
    'Limitation of liability',
    'To the extent permitted by law, Okay Messaging is not liable for '
        'indirect or consequential damages arising from your use of the app.',
  ),
  LegalSection(
    'Changes',
    'We may update these Terms; continued use after an update means you accept '
        'the new Terms.',
  ),
  LegalSection(
    'Governing law',
    'These Terms are governed by the laws of Canada and your province of '
        'residence.',
  ),
  LegalSection(
    'Contact',
    'Questions about these Terms? Reach us at legal@okay.chat.',
  ),
];
