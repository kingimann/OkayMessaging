// In-app legal copy. Kept as structured data so the exact same text can be
// published at a public URL (App Store requires a Privacy Policy URL) and
// shown natively. This is a plain-language template describing how the app
// actually works — it is NOT legal advice; have a lawyer review before launch.

class LegalSection {
  final String title;
  final String body;
  const LegalSection(this.title, this.body);

  Map<String, dynamic> toJson() => {'title': title, 'body': body};

  factory LegalSection.fromJson(Map<String, dynamic> j) =>
      LegalSection(j['title'] as String? ?? '', j['body'] as String? ?? '');
}

const String legalLastUpdated = 'Last updated: August 2026';

/// Bump this whenever the Terms of Service or Privacy Policy meaningfully
/// change. Everyone — new and existing users — is asked to agree to any
/// version newer than the one they accepted.
///
/// v2 — added paid Cloud storage (encrypted backup), the offline message
/// queue, and on-device file-upload moderation.
/// v3 — cloud storage is now tiered and chat-only (servers are communal/free),
/// videos can't be uploaded, and a fair-use egress limit applies.
/// v4 — digital purchases (storage subscription, developer tips) bill through
/// the App Store; Stripe is now only for peer-to-peer transfers.
/// v5 — storage is sold by the gigabyte (choose your amount, 100 GB max)
/// instead of named tiers.
/// v6 — the Terms said messages were never held for a recipient who was
/// offline, which stopped being true when store-and-forward shipped. The
/// Privacy Policy had always described the queue correctly; this is the
/// Terms catching up, so the two documents say the same thing. A promise
/// about what happens to somebody's message is exactly the kind of change
/// this counter exists for.
/// v7 — the Terms said cloud storage "does not auto-renew silently — you
/// confirm each renewal", which described the consumable it USED to be;
/// storage is a real Apple auto-renewing subscription (the only one of the
/// six App Store purchases that renews at all) and has been since it moved
/// to `consumable: false`. The in-app disclosure was right the whole time,
/// so this is the Terms catching up — and how somebody gets charged is
/// exactly what this counter exists for. Also names the other four
/// purchases, which the Terms had never mentioned.
const int legalVersion = 8;

/// Privacy Policy.
///
/// **Version 8 (2026-08-22) is the honest rewrite of a promise that stopped
/// being true.** Versions 1-7 described a no-storage architecture: messages
/// relayed through memory and living only on your devices. Message history
/// is now kept on the server so it follows an account to a new phone, and it
/// is readable by us. Nothing in this file may go on implying otherwise —
/// the whole point of a version bump is that everybody is asked to agree to
/// what is actually happening.
const List<LegalSection> privacyPolicy = [
  LegalSection(
    'The short version',
    'Your messages are stored on our servers so your conversations follow '
        'you to a new phone instead of disappearing with the old one. They '
        'are encrypted while travelling between devices and encrypted on our '
        'disks, but we hold those disk keys — which means we can read stored '
        'messages, and will where the law requires it or where somebody '
        'reports one. Your calls are different: audio and video go directly '
        'between devices and are never recorded.',
  ),
  LegalSection(
    'What we do NOT store',
    '• Calls — audio and video go directly between devices (WebRTC) '
        'and are never recorded or routed through us.\n'
        '• Anything sent over Okay Drop — those files cross Bluetooth or '
        'a direct Wi-Fi link between two phones in the same room and never '
        'touch a server at all.\n'
        '• Card numbers — payments are handled by Stripe; we never '
        'see or store them.\n'
        '• Your device passcode, app lock PIN, chat passwords or backup '
        'passphrase — none of these ever leaves your phone, and we cannot '
        'reset any of them for you.',
  ),
  LegalSection(
    'What we DO store',
    '• A username directory: your verified phone number mapped to the '
        'username you choose, so usernames are unique and reachable.\n'
        '• Payment metadata: for money you send/receive we keep the '
        'transaction id, amount, fee, and status (never card data) to show '
        'receipts and payout status. The money itself is held by Stripe, not '
        'us.\n'
        '• Communal data: your servers, feed posts and follows sync for '
        'everyone in a server, encrypted as ciphertext we cannot read. This is '
        'shared infrastructure — it is not part of anyone’s personal '
        'storage and costs nothing.\n'
        '• Your messages: text, and the photos, voice notes and other '
        'attachments that ride with them, kept so your history is there on '
        'any phone you sign in on. They sit on encrypted disks, but we hold '
        'those keys, so we can read them. Deleting a message for everyone '
        'marks it deleted; taking a message back within the undo window '
        'removes it outright.\n'
        '• Encrypted chat backup (only if you choose it): a separate '
        'ciphertext blob of your history, encrypted on your device with a '
        'passphrase we never receive and cannot reset.\n'
        '• Offline message queue: when a recipient is offline the message is '
        'briefly held so it can be delivered when they reconnect, then '
        'deleted on delivery or swept within 14 days.\n'
        '• Minimal operational logs needed to run and secure the service, '
        'kept only as long as necessary and never containing message content.',
  ),
  LegalSection(
    'Cloud storage (optional)',
    'Cloud storage backs up your chat history — and only your chats — as '
        'encrypted ciphertext we cannot read. It is offered in tiers: a free '
        'allowance and paid monthly plans for more space. Your servers, posts '
        'and follows are communal and never count against this storage. You '
        'can see how much space you use, change or cancel your plan, and '
        'restore your chats on a new device with your key, all in Settings → '
        'Cloud storage. If a paid plan lapses you drop to the free tier; your '
        'last backup stays available to restore.',
  ),
  LegalSection(
    'Encryption, and its limits',
    'Messages and call setup are encrypted on your device before they travel '
        '(AES-256-GCM with an ECDH key exchange), so nobody between you and '
        'the person you are talking to can read them in transit. Call audio '
        'and video stay end-to-end encrypted the whole way and are never '
        'recorded.\n\n'
        'Stored messages are a different thing and we will not blur the two: '
        'your history is held on encrypted disks whose keys we hold, so we '
        'can read it. That is what lets your conversations appear on a new '
        'phone and lets us act on a reported message. If you want a copy only '
        'you can open, the encrypted chat backup uses a passphrase we never '
        'receive.',
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
        'confidential and help us keep the community safe. Files you attach are '
        'checked on your device before they are sent: only real image files may '
        'be sent as photos, videos cannot be uploaded, executables and scripts '
        'are refused, and known prohibited content is blocked. This check runs '
        'locally — we do not see the file — and applies before anything leaves '
        'your device.',
  ),
  LegalSection(
    'Children',
    'OkayMessenger is not directed to children under 13 (or the minimum age '
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
    'By using OkayMessenger you agree to these Terms. If you don’t '
        'agree, please don’t use the app.',
  ),
  LegalSection(
    'The service',
    'OkayMessenger is a private, local-first messenger. You are responsible '
        'for the content you send and for keeping your device secure. Because '
        'messages are stored only on devices, keep your own backups if you '
        'want to preserve them.',
  ),
  LegalSection(
    'Payments',
    'Peer-to-peer payments — money you send to or receive from another person '
        'in a chat — are processed by Stripe, and only these use Stripe. When '
        'you send or receive money you agree to the Stripe Connected Account '
        'Agreement and Stripe’s terms. OkayMessenger is not a bank or '
        'money-services business, does not hold your funds, and never takes '
        'custody of the money — funds move from the sender’s card through '
        'Stripe to the recipient’s Stripe account and are paid out to their '
        'bank by Stripe. We charge a small application fee per transaction, '
        'shown before you pay. You are responsible for any taxes on money you '
        'receive. Digital purchases are billed by the App Store instead, not '
        'Stripe: cloud storage, Okay AI Pro, a subscription to a creator, '
        'membership of a paid server, and tips to the developer. Of those, '
        'ONLY cloud storage renews by itself — see below. The other four are '
        'a one-time charge that unlocks something for 30 days and then simply '
        'stops; nothing renews unless you buy again.',
  ),
  LegalSection(
    'Cloud storage subscription',
    'Cloud storage backs up your chats. You get a free allowance, and can buy '
        'more space monthly — choose the amount you want, up to a maximum of '
        '100 GB. There is no unlimited option. Paid storage is billed through '
        'your App Store account (Apple) at the price shown before you buy — not '
        'through Stripe. It is an auto-renewing subscription: it renews every '
        'month at the price shown, charged to your Apple ID at confirmation of '
        'purchase, until you cancel. To stop it, turn off auto-renew at least '
        '24 hours before the period ends in your device Settings → your name → '
        'Subscriptions, which is also where you cancel — cancelling inside '
        'the app drops the plan in the app only. Your servers '
        'and posts are communal and never count against your storage. '
        'Fair use: downloads (egress) are limited to roughly three times your '
        'stored amount per month; sustained excess may be throttled. You can '
        'view usage and change or cancel your plan anytime in Settings → Cloud '
        'storage; cancelling drops you to the free tier and is not refundable '
        'for the current period. Fees and limits may change on notice.',
  ),
  LegalSection(
    'Acceptable use',
    'Don’t use OkayMessenger to break the law, harass others, send spam, '
        'infringe rights, or transmit malware. Files you attach are moderated '
        'on your device before sending: only genuine image files may be sent as '
        'photos, videos cannot be uploaded, executables and scripts are '
        'refused, oversized files are blocked, and known prohibited content is '
        'refused outright. Attempting '
        'to bypass these checks, or uploading unlawful content, is a violation '
        'of these Terms. We may limit or end access that violates these Terms. '
        'Use the in-app block and report tools if someone is abusing the '
        'service.',
  ),
  LegalSection(
    'No warranty',
    'The app is provided “as is” without warranties of any kind. '
        'If a recipient is offline the message is held briefly so it can be '
        'delivered when they reconnect, and is deleted on delivery or swept '
        'within 14 days, so we don’t guarantee delivery of anything older '
        'than that. Your message history is kept on our servers so it '
        'follows you between devices; we don’t guarantee it against loss, '
        'and the encrypted chat backup is there for a copy only you can '
        'open.',
  ),
  LegalSection(
    'Limitation of liability',
    'To the extent permitted by law, OkayMessenger is not liable for '
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
