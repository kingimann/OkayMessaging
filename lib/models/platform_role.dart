/// App-wide roles and sanctions — the moderation layer above servers.
///
/// A server's [MemberRole] governs one room. These govern the whole app: the
/// directory everyone is found through, the relay, push, and payments.
///
/// **What a platform sanction can and cannot do.** It removes an account from
/// the shared infrastructure — discovery, push, payments, claiming a username.
/// It does *not* reach into anybody's conversations, because message bodies are
/// end-to-end encrypted and no server copy exists to read or delete. There is
/// no way to add one without breaking the promise the app is built on, so the
/// UI says this plainly rather than implying a power nobody has.
///
/// Roles live in a service-role-only table and are granted by SQL, not by the
/// app: a role the app could grant itself would be worth nothing. Every check
/// here is a *client-side mirror* of a server-side decision, for showing the
/// right screen — never the thing that makes a sanction real.
library;

/// Where an account stands app-wide, in descending order of privilege.
///
///  * **owner**     — runs the app. Grants roles; can act on anyone.
///  * **admin**     — bans, suspends, times out, lifts.
///  * **moderator** — times out and lifts time-outs. No bans.
///  * **member**    — everyone else.
enum PlatformRole { owner, admin, moderator, member }

PlatformRole platformRoleFrom(String? raw) => switch (raw) {
      'owner' => PlatformRole.owner,
      'admin' => PlatformRole.admin,
      'moderator' => PlatformRole.moderator,
      _ => PlatformRole.member,
    };

String platformRoleName(PlatformRole r) => switch (r) {
      PlatformRole.owner => 'Owner',
      PlatformRole.admin => 'Admin',
      PlatformRole.moderator => 'Moderator',
      PlatformRole.member => 'Member',
    };

/// Rank for privilege comparisons — higher outranks lower.
int platformRoleRank(PlatformRole r) => switch (r) {
      PlatformRole.owner => 3,
      PlatformRole.admin => 2,
      PlatformRole.moderator => 1,
      PlatformRole.member => 0,
    };

/// Whether [r] gets the moderation console at all.
bool roleCanModeratePlatform(PlatformRole r) =>
    platformRoleRank(r) >= platformRoleRank(PlatformRole.moderator);

/// Whether [r] may ban and suspend, not merely time out.
bool roleCanAdministerPlatform(PlatformRole r) =>
    platformRoleRank(r) >= platformRoleRank(PlatformRole.admin);

/// Whether [r] may grant or revoke roles. Owner only, and even then the app
/// only *shows* it — granting is a SQL operation against a table no client can
/// write.
bool roleCanGrantRoles(PlatformRole r) => r == PlatformRole.owner;

/// What has been done to an account.
enum SanctionKind {
  /// Nothing.
  none,

  /// Temporarily can't send, post, or list. Still findable, still reads.
  timeout,

  /// Locked out for a while, and hidden from the directory.
  suspend,

  /// Locked out for good, and hidden from the directory.
  ban,

  /// Carries on exactly as before — posts, sees its own posts in place — but
  /// nobody else sees any of its public content. Never expires: a shadow ban
  /// that lapses announces itself, which is the one thing it must not do.
  shadow,
}

/// The parts of the app an account can be barred from one at a time, so a
/// marketplace scammer loses the marketplace and keeps their conversations.
enum BanArea { marketplace, servers, forum, feed }

String banAreaName(BanArea a) => switch (a) {
      BanArea.marketplace => 'marketplace',
      BanArea.servers => 'servers',
      BanArea.forum => 'forum',
      BanArea.feed => 'feed',
    };

String banAreaLabel(BanArea a) => switch (a) {
      BanArea.marketplace => 'Marketplace',
      BanArea.servers => 'Servers',
      BanArea.forum => 'Forum',
      BanArea.feed => 'Newsfeed',
    };

BanArea? banAreaFromName(String s) => switch (s) {
      'marketplace' => BanArea.marketplace,
      'servers' => BanArea.servers,
      'forum' => BanArea.forum,
      'feed' => BanArea.feed,
      _ => null,
    };

SanctionKind sanctionKindFrom(String? raw) => switch (raw) {
      'timeout' => SanctionKind.timeout,
      'suspend' => SanctionKind.suspend,
      'ban' => SanctionKind.ban,
      _ => SanctionKind.none,
    };

String sanctionKindName(SanctionKind k) => switch (k) {
      SanctionKind.timeout => 'timeout',
      SanctionKind.suspend => 'suspend',
      SanctionKind.ban => 'ban',
      SanctionKind.shadow => 'shadow',
      SanctionKind.none => 'none',
    };

String sanctionKindLabel(SanctionKind k) => switch (k) {
      SanctionKind.timeout => 'Timed out',
      SanctionKind.suspend => 'Suspended',
      SanctionKind.ban => 'Banned',
      SanctionKind.shadow => 'Shadow banned',
      SanctionKind.none => 'No sanction',
    };

/// Whether [actor] may hand out [kind]. Moderators time out; bans and
/// suspensions need an admin. Nobody "applies" none — lifting is its own verb.
bool roleCanApply(PlatformRole actor, SanctionKind kind) => switch (kind) {
      SanctionKind.none => false,
      SanctionKind.timeout => roleCanModeratePlatform(actor),
      SanctionKind.suspend => roleCanAdministerPlatform(actor),
      SanctionKind.ban => roleCanAdministerPlatform(actor),
      // Quieter than a ban, not milder — and the one sanction the target is
      // never told about, so it is not a moderator's to hand out.
      SanctionKind.shadow => roleCanAdministerPlatform(actor),
    };

/// Whether [actor] may sanction someone holding [target]. Strictly outranking
/// only: an admin cannot ban another admin, and nobody touches the owner.
/// This is what stops a moderation team from turning on itself.
bool canActOnRole(PlatformRole actor, PlatformRole target) =>
    roleCanModeratePlatform(actor) &&
    platformRoleRank(actor) > platformRoleRank(target);

/// How long a sanction can run. Permanent is a ban and only a ban.
const sanctionDurations = <String, int>{
  '10 minutes': 10,
  '1 hour': 60,
  '24 hours': 1440,
  '7 days': 10080,
  '30 days': 43200,
};

/// A sanction on one account, as the server reported it.
class AccountSanction {
  final SanctionKind kind;
  final String reason;

  /// When it lapses; null means permanent.
  final DateTime? until;

  /// Who applied it — a phone, shown to admins in the audit list.
  final String actorPhone;
  final DateTime createdAt;

  const AccountSanction({
    required this.kind,
    this.reason = '',
    this.until,
    this.actorPhone = '',
    required this.createdAt,
  });

  /// Whether this is still in force at [now]. An expired sanction is history,
  /// not a punishment: the app must not keep enforcing one whose clock ran out
  /// just because nobody has swept the row yet.
  bool isActiveAt(DateTime now) {
    if (kind == SanctionKind.none) return false;
    final end = until;
    return end == null || end.isAfter(now);
  }

  /// Whether the account is shut out of the app entirely (as opposed to merely
  /// silenced). Only while active.
  bool blocksAccessAt(DateTime now) =>
      isActiveAt(now) &&
      (kind == SanctionKind.ban || kind == SanctionKind.suspend);

  /// Whether the account may not send, post, or list right now.
  bool blocksSendingAt(DateTime now) => isActiveAt(now);

  /// Whether the account is kept out of username search and contact sync.
  /// Mirrors the row-level rule the database enforces for real.
  bool hidesFromDirectoryAt(DateTime now) => blocksAccessAt(now);

  Map<String, dynamic> toJson() => {
        'kind': sanctionKindName(kind),
        'reason': reason,
        'until': until?.toIso8601String(),
        'actorPhone': actorPhone,
        'createdAt': createdAt.toIso8601String(),
      };

  factory AccountSanction.fromJson(Map<String, dynamic> j) => AccountSanction(
        kind: sanctionKindFrom(j['kind'] as String?),
        reason: j['reason'] as String? ?? '',
        until: DateTime.tryParse(j['until'] as String? ?? '')?.toUtc(),
        actorPhone: j['actorPhone'] as String? ?? '',
        createdAt:
            DateTime.tryParse(j['createdAt'] as String? ?? '')?.toUtc() ??
                DateTime.utc(2024),
      );
}

/// How long until [until], in words: "3 days", "2 hours", "8 minutes". Pure.
/// Returns '' for a permanent sanction and 'moments' for anything under a
/// minute, because "0 minutes" reads as over when it isn't.
///
/// Rounds **up**, and promotes as it goes (60 minutes becomes an hour). A
/// sanction that lifts a little sooner than promised is a much better error
/// than one that outlasts what someone was told — and truncating turns
/// "2 days 23 hours" into "2 days", which is exactly that mistake.
String sanctionRemaining(DateTime? until, DateTime now) {
  if (until == null) return '';
  final left = until.difference(now);
  if (left.inSeconds <= 0) return '';
  if (left.inSeconds < 60) return 'moments';
  final minutes = (left.inSeconds / 60).ceil();
  if (minutes < 60) return '$minutes ${minutes == 1 ? 'minute' : 'minutes'}';
  final hours = (minutes / 60).ceil();
  if (hours < 24) return '$hours ${hours == 1 ? 'hour' : 'hours'}';
  final days = (hours / 24).ceil();
  return '$days ${days == 1 ? 'day' : 'days'}';
}

/// What a report is about. Free-form detail travels alongside.
const reportReasons = <String>[
  'Spam',
  'Harassment',
  'Scam or fraud',
  'Impersonation',
  'Illegal content',
  'Something else',
];
