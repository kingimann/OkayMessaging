import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/platform_role.dart';
import '../relay/relay_config.dart';

/// One open report, as a moderator sees it.
class ModerationReport {
  final int id;
  final String targetPhone;
  final String targetHandle;
  final String reporterPhone;
  final String reason;
  final String detail;
  final String context;
  final DateTime createdAt;

  const ModerationReport({
    required this.id,
    this.targetPhone = '',
    this.targetHandle = '',
    this.reporterPhone = '',
    this.reason = '',
    this.detail = '',
    this.context = '',
    required this.createdAt,
  });

  factory ModerationReport.fromJson(Map<String, dynamic> j) =>
      ModerationReport(
        id: (j['id'] as num?)?.toInt() ?? 0,
        targetPhone: j['targetPhone'] as String? ?? '',
        targetHandle: j['targetHandle'] as String? ?? '',
        reporterPhone: j['reporterPhone'] as String? ?? '',
        reason: j['reason'] as String? ?? '',
        detail: j['detail'] as String? ?? '',
        context: j['context'] as String? ?? '',
        createdAt:
            DateTime.tryParse(j['createdAt'] as String? ?? '')?.toUtc() ??
                DateTime.utc(2024),
      );
}

/// One holder of a platform role — the owner's team list row.
class RoleEntry {
  final String phone;
  final PlatformRole role;
  final String username;
  final String name;
  const RoleEntry({
    required this.phone,
    required this.role,
    this.username = '',
    this.name = '',
  });

  /// The most human label available.
  String get label => name.isNotEmpty
      ? name
      : username.isNotEmpty
          ? '@$username'
          : phone;
}

/// A sanction plus who it is on — the admin console's row.
class SanctionEntry {
  final String phone;
  final AccountSanction sanction;
  const SanctionEntry({required this.phone, required this.sanction});
}

/// App-wide roles and sanctions, as the server reports them.
///
/// Nothing here grants anything. The role and every sanction come from tables
/// no client can write, and the Edge Function re-checks the caller's role
/// before it acts — so this store decides which screens to draw, never who is
/// allowed to do what. Treat every field as a mirror.
class PlatformModeration extends ChangeNotifier {
  PlatformModeration._();
  static final PlatformModeration instance = PlatformModeration._();

  PlatformRole _role = PlatformRole.member;
  AccountSanction? _sanction;
  bool _loaded = false;

  /// The signed-in account's app-wide role. [PlatformRole.member] until the
  /// server says otherwise, so a device that can't reach the server never
  /// shows moderation tools.
  PlatformRole get role => _role;

  /// The sanction on this account, or null. Expiry is respected: a lapsed
  /// sanction is history, not a punishment.
  AccountSanction? get sanction {
    final s = _sanction;
    if (s == null) return null;
    return s.isActiveAt(DateTime.now().toUtc()) ? s : null;
  }

  /// Whether the status has been fetched at least once. Screens that lock
  /// people out wait for this rather than acting on a default.
  bool get loaded => _loaded;

  bool get canModerate => roleCanModeratePlatform(_role);
  bool get canAdminister => roleCanAdministerPlatform(_role);

  /// Whether this account runs the app.
  ///
  /// Worth exactly as much as [role] is — it comes from a table no client can
  /// write, read through a function that re-checks the caller's JWT. False on
  /// any device that can't reach the server, which is the safe way round.
  ///
  /// Used to waive the ID check on the app's *own* policy gates. It cannot
  /// waive a requirement that belongs to somebody else: sending money needs a
  /// verified legal name to put on the Stripe intent, and no role here
  /// conjures one. See [VerifiedGate].
  bool get isOwner => _role == PlatformRole.owner;

  /// Whether this account is shut out of the app right now.
  bool get isLockedOut =>
      sanction?.blocksAccessAt(DateTime.now().toUtc()) ?? false;

  /// Whether this account may not send, post, or list right now.
  bool get isSilenced =>
      sanction?.blocksSendingAt(DateTime.now().toUtc()) ?? false;

  /// Test hook: stands in for the whole server round trip.
  @visibleForTesting
  static Future<(PlatformRole, AccountSanction?)> Function()?
      debugStatusOverride;

  /// Test hook: records attempted actions instead of calling the function.
  @visibleForTesting
  static Future<bool> Function(
    String targetPhone,
    String action,
    String reason,
    int minutes,
  )? debugActOverride;

  /// Test hook: the moderation queue.
  @visibleForTesting
  static Future<List<ModerationReport>> Function()? debugReportsOverride;

  /// Test hook: records filed reports.
  @visibleForTesting
  static Future<bool> Function(Map<String, dynamic> row)? debugFileOverride;

  SupabaseClient? get _client {
    if (!RelayConfig.isEnabled) return null;
    try {
      return Supabase.instance.client;
    } catch (_) {
      return null; // Supabase not initialised (tests, web preview).
    }
  }

  /// Re-reads this account's role and sanction. Called at startup and after
  /// signing in.
  Future<void> refresh() async {
    final override = debugStatusOverride;
    if (override != null) {
      final (role, sanction) = await override();
      _role = role;
      _sanction = sanction;
      _loaded = true;
      notifyListeners();
      return;
    }
    final result = await _invoke('moderation-status', const {});
    if (result == null) return;
    _role = platformRoleFrom(result['role'] as String?);
    final raw = result['sanction'];
    _sanction = raw is Map
        ? AccountSanction.fromJson(Map<String, dynamic>.from(raw))
        : null;
    _loaded = true;
    notifyListeners();
  }

  /// Applies a sanction. [minutes] is ignored for a ban, which is permanent.
  /// Returns false when the server refused — which it will if this device's
  /// idea of its own role is wrong.
  Future<bool> apply({
    required String targetPhone,
    required SanctionKind kind,
    String reason = '',
    int minutes = 0,
  }) =>
      _act(targetPhone, sanctionKindName(kind), reason, minutes);

  /// Lifts whatever sanction is on an account.
  Future<bool> lift(String targetPhone, {String reason = ''}) =>
      _act(targetPhone, 'lift', reason, 0);

  Future<bool> _act(
      String targetPhone, String action, String reason, int minutes) async {
    final digits = targetPhone.replaceAll(RegExp(r'\D'), '');
    if (digits.isEmpty) return false;
    final override = debugActOverride;
    if (override != null) {
      return override(digits, action, reason, minutes);
    }
    final result = await _invoke('moderation-act', {
      'targetPhone': digits,
      'action': action,
      'reason': reason,
      if (minutes > 0) 'minutes': minutes,
    });
    return result?['ok'] == true;
  }

  /// Open reports, newest first. Empty when the caller isn't a moderator —
  /// the server decides that, not this device.
  Future<List<ModerationReport>> reports() async {
    final override = debugReportsOverride;
    if (override != null) return override();
    final result = await _invoke('moderation-queue', const {'what': 'reports'});
    final rows = result?['reports'];
    if (rows is! List) return const [];
    return [
      for (final row in rows)
        if (row is Map)
          ModerationReport.fromJson(Map<String, dynamic>.from(row))
    ];
  }

  /// Live sanctions, for the console's list.
  Future<List<SanctionEntry>> sanctions() async {
    final result =
        await _invoke('moderation-queue', const {'what': 'sanctions'});
    final rows = result?['sanctions'];
    if (rows is! List) return const [];
    final now = DateTime.now().toUtc();
    final out = <SanctionEntry>[];
    for (final row in rows) {
      if (row is! Map) continue;
      final map = Map<String, dynamic>.from(row);
      final sanction = AccountSanction.fromJson(map);
      // A lapsed row is not a live sanction, whether or not it's been swept.
      if (!sanction.isActiveAt(now)) continue;
      out.add(SanctionEntry(
          phone: map['phone'] as String? ?? '', sanction: sanction));
    }
    return out;
  }

  /// Marks a report dealt with so it leaves the queue.
  Future<bool> markHandled(int id) async {
    final result =
        await _invoke('moderation-queue', {'what': 'handle', 'id': id});
    return result?['ok'] == true;
  }

  /// Removes one public post, as a moderation action. The server enforces
  /// everything that matters — moderator rank, and outranking the author —
  /// this only decides whether to draw the menu item.
  Future<bool> takedownPublicPost(String postId, {String reason = ''}) async {
    if (postId.isEmpty) return false;
    final override = debugActOverride;
    if (override != null) return override(postId, 'takedown', reason, 0);
    final result = await _invoke('moderation-act', {
      'action': 'takedown',
      'postId': postId,
      'reason': reason,
    });
    return result?['ok'] == true;
  }

  /// One row of the team list: who holds a role, by digits and (when the
  /// directory knows them) handle and name.
  /// The whole team, owner's eyes only — the server refuses everyone else.
  Future<List<RoleEntry>?> teamRoles() async {
    final result = await _invoke('roles-set', const {'what': 'list'});
    final rows = result?['roles'];
    if (rows is! List) return null;
    return [
      for (final row in rows)
        if (row is Map)
          RoleEntry(
            phone: row['phone'] as String? ?? '',
            role: platformRoleFrom(row['role'] as String?),
            username: row['username'] as String? ?? '',
            name: row['name'] as String? ?? '',
          )
    ];
  }

  /// Grants (or, with [PlatformRole.member], revokes) a role. Owner only —
  /// enforced server-side; 'owner' itself can never be assigned from the
  /// app, and the server refuses changes to the owner's own row.
  Future<bool> setRole(String targetPhone, PlatformRole role) async {
    final digits = targetPhone.replaceAll(RegExp(r'\D'), '');
    if (digits.isEmpty || role == PlatformRole.owner) return false;
    final result = await _invoke('roles-set', {
      'what': 'set',
      'targetPhone': digits,
      'role': role.name,
    });
    return result?['ok'] == true;
  }

  /// Files a report. This is what the app's Report buttons now do — a report
  /// used to hide something locally and go nowhere, because there was no
  /// central moderator to send it to.
  ///
  /// Never carries message content: what was said stays on the devices that
  /// hold it, and the server couldn't read it anyway.
  Future<bool> report({
    required String reason,
    String targetPhone = '',
    String targetHandle = '',
    String detail = '',
    String context = '',
    String reporterPhone = '',
  }) async {
    final row = {
      'target_phone': targetPhone.replaceAll(RegExp(r'\D'), ''),
      'target_handle': targetHandle,
      'reporter_phone': reporterPhone.replaceAll(RegExp(r'\D'), ''),
      'reason': reason,
      'detail': detail.length > 1000 ? detail.substring(0, 1000) : detail,
      'context': context,
    };
    final override = debugFileOverride;
    if (override != null) return override(row);
    final client = _client;
    if (client == null) return false;
    try {
      await client.from('moderation_reports').insert(row);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<Map<String, dynamic>?> _invoke(
      String name, Map<String, dynamic> body) async {
    final client = _client;
    if (client == null) return null;
    try {
      final res = await client.functions.invoke(name, body: body);
      if (res.status >= 400) return null;
      final data = res.data;
      if (data is! Map) return null;
      return Map<String, dynamic>.from(data);
    } catch (_) {
      // Offline, or the functions aren't deployed. Never throw into a UI.
      return null;
    }
  }

  @visibleForTesting
  void debugSet({PlatformRole? role, AccountSanction? sanction, bool? loaded}) {
    if (role != null) _role = role;
    _sanction = sanction;
    if (loaded != null) _loaded = loaded;
    notifyListeners();
  }

  @visibleForTesting
  void resetForTest() {
    _role = PlatformRole.member;
    _sanction = null;
    _loaded = false;
    debugStatusOverride = null;
    debugActOverride = null;
    debugReportsOverride = null;
    debugFileOverride = null;
    notifyListeners();
  }
}
