import 'dart:convert';

/// One subscription tier a creator offers — a name, a monthly price (one of
/// [AppUser.subscriptionTiersCents]) and a free-text perks line. Every tier
/// unlocks the same subscribers-only posts; higher tiers are more support and
/// whatever extra the creator promises in [perks].
class SubscriptionTier {
  final String name;
  final int cents;
  final String perks;
  const SubscriptionTier(
      {required this.name, required this.cents, this.perks = ''});

  Map<String, dynamic> toJson() => {
        'name': name,
        'cents': cents,
        if (perks.isNotEmpty) 'perks': perks,
      };

  factory SubscriptionTier.fromJson(Map<String, dynamic> j) => SubscriptionTier(
        name: (j['name'] as String? ?? '').trim(),
        cents: (j['cents'] as num?)?.toInt() ?? 0,
        perks: (j['perks'] as String? ?? '').trim(),
      );

  /// Encode a list of tiers to the string [AppUser.subscriptionTiersJson]
  /// stores. Empty in, empty string out.
  static String encode(List<SubscriptionTier> tiers) =>
      tiers.isEmpty ? '' : jsonEncode([for (final t in tiers) t.toJson()]);
}

/// Represents a person in the app (a contact or the current user).
class AppUser {
  final String id;
  final String name;
  final String avatarColor; // hex string used to build a placeholder avatar
  final String about;

  /// The placeholder [about] USED to default to, back when it was a
  /// WhatsApp-style status line rather than a bio (removed 2026-08-15).
  ///
  /// No longer a default — a new account simply has no bio — but every
  /// account created before then still carries this exact string, on the
  /// wire and on other people's devices. So it stays, and anything asking
  /// "does this profile have a bio" still has to read it as a no: it is a
  /// sentence the APP wrote, not a fact about the person.
  static const String legacyAbout = 'Hey there! I am using OkayMessenger.';

  final String phone;

  /// A public handle (without the leading '@'), e.g. "ada".
  final String username;
  final bool isOnline;

  /// True for group conversations rather than a single person.
  final bool isGroup;

  /// Whether this account carries a verified (blue check) badge.
  final bool verified;

  /// The account's Okay Score — a running activity tally, à la Snapchat.
  /// For contacts this is the last value they broadcast.
  final int score;

  /// An optional emoji shown on the avatar instead of the initials.
  final String emoji;

  /// An illustrated avatar's seed. When set, the avatar draws a generated
  /// Multiavatar character (offline, deterministic from this string) instead
  /// of a colour + initials/emoji. This is the "pick an avatar" choice.
  final String avatarSeed;

  /// Optional pronouns shown under the name (e.g. "she/her").
  final String pronouns;

  /// An optional link the user adds to their profile (website / social).
  final String link;

  /// A face the person BUILT — the Snapchat-shaped avatar. Stored as the
  /// selection (which nose, which hair, which colours), not the drawing; see
  /// [AvatarFace]. Empty means they never made one, which is most people.
  ///
  /// Wins over every other avatar when set, because it is the most
  /// deliberate: a colour is assigned, a generated character is picked from a
  /// grid, but this one was assembled feature by feature.
  final String avatarFace;

  /// An optional second avatar color: set, the avatar fills with a
  /// gradient from [avatarColor] to this instead of a flat circle.
  final String avatarColor2;

  /// The profile header's banner color ('' = the default look).
  final String bannerColor;

  /// An optional free-text location ("Toronto", "on the road"). Shown on
  /// the profile; never parsed, never a coordinate.
  final String location;

  /// Whether this account presents itself as a business. Purely a
  /// self-declaration — it changes how the profile reads (storefront badge,
  /// category, hours), not what the account can do, and it is NOT the blue
  /// check: verification stays the identity claim, this is a presentation
  /// choice.
  final bool isBusiness;

  /// What kind of business, from [businessCategories] ('' when unset).
  final String businessCategory;

  /// Free-text opening hours ("Mon–Fri 9–5"). Never parsed — text in, text
  /// out, like [location].
  final String businessHours;

  /// Whether this account offers a paid subscription — a monthly pass that
  /// unlocks the "subscribers only" posts they publish to the public feed.
  /// A self-declaration like [isBusiness]: turning it on IS the decision to
  /// announce it, so it rides the profile share ungated and applies at the
  /// receiver as sent.
  final bool subscribable;

  /// The creator's own Lightning Address (`name@domain`, LUD-16) — where a
  /// Lightning spark goes. Empty means they do not take them.
  ///
  /// Not a secret and not a payment credential: it is publishable by design,
  /// the bitcoin equivalent of printing a tip jar's address. It rides the
  /// profile share UNGATED like [isBusiness], because entering one IS the
  /// decision to be tippable.
  final String lightningAddress;

  /// Which price tier they charge, an index into [subscriptionTiersCents].
  /// Meaningless when [subscribable] is false.
  final int subscriptionTier;

  /// A short free-text pitch shown on the subscribe sheet ("Behind-the-scenes
  /// and early drops"). Never parsed. Legacy: the single-tier pitch, still
  /// carried so an older build's one price keeps working.
  final String subscriptionPitch;

  /// The creator's subscription TIERS, as a JSON array string — each entry a
  /// name, a price (one of [subscriptionTiersCents]) and a free-text perks
  /// line. Kept as a string so it rides the profile share and persists like
  /// every other scalar field rather than needing bespoke plumbing. Read
  /// through [subscriptionTiers], which falls back to the legacy single tier.
  final String subscriptionTiersJson;

  /// When this account was created, as its own device recorded it.
  ///
  /// Rides the profile share like every other public fact about a person,
  /// and is therefore only known for somebody this device has heard from —
  /// the username directory carries no such column, so a stranger's profile
  /// shows nothing here rather than a guess. The same honesty rule
  /// [knownBusinessSeller] follows.
  ///
  /// Null on an account that predates the field. "Joined — we don't know"
  /// is a fact; a made-up date on somebody's profile is not.
  final DateTime? joinedAt;

  /// Whether a REAL phone number sits behind this account (a name-only
  /// account has an account code instead, and answers for nothing).
  ///
  /// Carried explicitly rather than derived from [phone], because a
  /// contact known only by handle has no number on this device to test —
  /// and deriving "unverified" from "I don't have their number" would
  /// label most of the directory wrongly.
  final bool phoneVerified;

  /// Whether they have confirmed an email address. There is no server
  /// column mapping an account to an email (a verified address lives only
  /// inside the encrypted backup), so this flag IS the only way another
  /// device can ever know — which is exactly why it rides the sealed
  /// profile share and never the public directory.
  final bool emailVerified;

  const AppUser({
    required this.id,
    required this.name,
    required this.avatarColor,
    this.about = '',
    this.phone = '',
    this.username = '',
    this.isOnline = false,
    this.isGroup = false,
    this.verified = false,
    this.score = 0,
    this.emoji = '',
    this.avatarSeed = '',
    this.avatarFace = '',
    this.pronouns = '',
    this.link = '',
    this.avatarColor2 = '',
    this.bannerColor = '',
    this.location = '',
    this.isBusiness = false,
    this.businessCategory = '',
    this.businessHours = '',
    this.subscribable = false,
    this.subscriptionTier = 0,
    this.subscriptionPitch = '',
    this.subscriptionTiersJson = '',
    this.lightningAddress = '',
    this.joinedAt,
    this.phoneVerified = false,
    this.emailVerified = false,
  });

  /// The monthly price tiers a creator can charge, in cents. A fixed ladder
  /// (not free text) because each tier maps to a pre-registered In-App
  /// Purchase product — Apple bills digital subscriptions and only known
  /// SKUs exist. Index into this list is [subscriptionTier].
  static const List<int> subscriptionTiersCents = [299, 499, 999, 1999];

  /// The creator's tiers, newest model first, with a fall-back to the legacy
  /// single tier so an account set up before tiers existed still offers its
  /// one price. Empty when the account offers no subscription.
  List<SubscriptionTier> get subscriptionTiers {
    if (!subscribable) return const [];
    if (subscriptionTiersJson.isNotEmpty) {
      try {
        final list = jsonDecode(subscriptionTiersJson) as List;
        final tiers = [
          for (final t in list)
            SubscriptionTier.fromJson((t as Map).cast<String, dynamic>())
        ]..removeWhere((t) => t.cents <= 0);
        if (tiers.isNotEmpty) return tiers;
      } catch (_) {}
    }
    // Legacy single tier.
    final i = subscriptionTier;
    final cents = (i >= 0 && i < subscriptionTiersCents.length)
        ? subscriptionTiersCents[i]
        : subscriptionTiersCents.first;
    return [SubscriptionTier(name: 'Subscriber', cents: cents, perks: subscriptionPitch)];
  }

  /// The headline price — the CHEAPEST tier, so a card can read "from $X ·
  /// 30 days" (never "/mo": a creator sub is a 30-day pass a reader renews
  /// by hand, not an Apple auto-renewing subscription — see
  /// StorePurchases.creatorSubProductId). Zero when the account offers no
  /// subscription.
  int get subscriptionCents {
    final tiers = subscriptionTiers;
    if (tiers.isEmpty) return 0;
    return tiers.map((t) => t.cents).reduce((a, b) => a < b ? a : b);
  }

  /// The categories the edit screen offers. A fixed list rather than free
  /// text so the label under a name is a word, not a pitch.
  static const List<String> businessCategories = [
    'Retail',
    'Food & drink',
    'Services',
    'Beauty & wellness',
    'Art & crafts',
    'Tech',
    'Education',
    'Events',
    'Travel',
    'Other',
  ];

  /// The handle with a leading '@', or empty when none is set.
  String get handle => username.isEmpty ? '' : '@$username';

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'avatarColor': avatarColor,
        'about': about,
        'phone': phone,
        'username': username,
        'isOnline': isOnline,
        'isGroup': isGroup,
        'verified': verified,
        'score': score,
        'emoji': emoji,
        'avatarSeed': avatarSeed,
        if (avatarFace.isNotEmpty) 'avatarFace': avatarFace,
        'pronouns': pronouns,
        'link': link,
        'avatarColor2': avatarColor2,
        'bannerColor': bannerColor,
        'location': location,
        'isBusiness': isBusiness,
        'businessCategory': businessCategory,
        'businessHours': businessHours,
        'subscribable': subscribable,
        'subscriptionTier': subscriptionTier,
        'subscriptionPitch': subscriptionPitch,
        'subscriptionTiersJson': subscriptionTiersJson,
        'lightningAddress': lightningAddress,
        if (joinedAt != null) 'joinedAt': joinedAt!.toIso8601String(),
        if (phoneVerified) 'phoneVerified': true,
        if (emailVerified) 'emailVerified': true,
      };

  factory AppUser.fromJson(Map<String, dynamic> json) => AppUser(
        id: json['id'] as String,
        name: json['name'] as String,
        avatarColor: json['avatarColor'] as String,
        about: json['about'] as String? ?? '',
        phone: json['phone'] as String? ?? '',
        username: json['username'] as String? ?? '',
        isOnline: json['isOnline'] as bool? ?? false,
        isGroup: json['isGroup'] as bool? ?? false,
        verified: json['verified'] as bool? ?? false,
        score: (json['score'] as num?)?.toInt() ?? 0,
        emoji: json['emoji'] as String? ?? '',
        avatarSeed: json['avatarSeed'] as String? ?? '',
        avatarFace: json['avatarFace'] as String? ?? '',
        pronouns: json['pronouns'] as String? ?? '',
        link: json['link'] as String? ?? '',
        avatarColor2: json['avatarColor2'] as String? ?? '',
        bannerColor: json['bannerColor'] as String? ?? '',
        location: json['location'] as String? ?? '',
        isBusiness: json['isBusiness'] as bool? ?? false,
        businessCategory: json['businessCategory'] as String? ?? '',
        businessHours: json['businessHours'] as String? ?? '',
        subscribable: json['subscribable'] as bool? ?? false,
        subscriptionTier: (json['subscriptionTier'] as num?)?.toInt() ?? 0,
        subscriptionPitch: json['subscriptionPitch'] as String? ?? '',
        subscriptionTiersJson: json['subscriptionTiersJson'] as String? ?? '',
        lightningAddress: json['lightningAddress'] as String? ?? '',
        joinedAt: json['joinedAt'] == null
            ? null
            : DateTime.tryParse(json['joinedAt'] as String),
        phoneVerified: json['phoneVerified'] as bool? ?? false,
        emailVerified: json['emailVerified'] as bool? ?? false,
      );

  /// Initials used for the placeholder avatar (e.g. "John Doe" -> "JD").
  String get initials {
    final parts = name.trim().split(RegExp(r'\s+'));
    if (parts.isEmpty || parts.first.isEmpty) return '?';
    if (parts.length == 1) return parts.first[0].toUpperCase();
    return (parts.first[0] + parts.last[0]).toUpperCase();
  }
}
