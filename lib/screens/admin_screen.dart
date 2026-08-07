import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

import '../models/platform_role.dart';
import '../models/user.dart';
import '../state/account_service.dart';
import '../state/platform_moderation.dart';
import '../widgets/app_dialogs.dart';
import '../widgets/info_section.dart';

/// The moderation console.
///
/// Only reachable when the server says this account holds a platform role, and
/// every button here is a request the server re-authorises before it acts —
/// the console can ask for a ban it isn't allowed to make and be told no.
class AdminScreen extends StatefulWidget {
  const AdminScreen({super.key});

  @override
  State<AdminScreen> createState() => _AdminScreenState();
}

enum _Tab { reports, sanctions, team, users }

class _AdminScreenState extends State<AdminScreen> {
  _Tab _tab = _Tab.reports;
  List<ModerationReport>? _reports;
  List<SanctionEntry>? _sanctions;
  List<RoleEntry>? _team;
  (int, List<AdminUser>)? _users;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _busy = true);
    final store = PlatformModeration.instance;
    final reports = await store.reports();
    final sanctions = await store.sanctions();
    // The team list and the whole-directory roster are the owner/admin's
    // alone — the server refuses everyone else, so nobody else pays for the
    // round trip.
    final team = store.isOwner ? await store.teamRoles() : null;
    final users = store.canAdminister ? await store.allUsers() : null;
    if (!mounted) return;
    setState(() {
      _reports = reports;
      _sanctions = sanctions;
      _team = team;
      _users = users;
      _busy = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final store = PlatformModeration.instance;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Moderation'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: _busy ? null : _load,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _actOn(context, phone: '', handle: ''),
        icon: const Icon(Icons.gavel),
        label: const Text('Act on account'),
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 96),
        children: [
          _roleBanner(context, store.role),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
            child: SegmentedButton<_Tab>(
              segments: [
                ButtonSegment(
                  value: _Tab.reports,
                  label: Text('Reports'
                      '${_reports == null || _reports!.isEmpty ? '' : ' (${_reports!.length})'}'),
                ),
                ButtonSegment(
                  value: _Tab.sanctions,
                  label: Text('Sanctions'
                      '${_sanctions == null || _sanctions!.isEmpty ? '' : ' (${_sanctions!.length})'}'),
                ),
                if (store.isOwner)
                  const ButtonSegment(
                    value: _Tab.team,
                    label: Text('Team'),
                  ),
                if (store.canAdminister)
                  ButtonSegment(
                    value: _Tab.users,
                    label: Text('Users'
                        '${_users == null ? '' : ' (${_users!.$1})'}'),
                  ),
              ],
              selected: {_tab},
              onSelectionChanged: (s) => setState(() => _tab = s.first),
            ),
          ),
          if (_busy && _reports == null)
            const Padding(
              padding: EdgeInsets.all(40),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_tab == _Tab.reports)
            ..._reportList(context)
          else if (_tab == _Tab.sanctions)
            ..._sanctionList(context)
          else if (_tab == _Tab.team)
            ..._teamList(context)
          else
            ..._userList(context),
        ],
      ),
    );
  }

  Widget _roleBanner(BuildContext context, PlatformRole role) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: scheme.primary.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            Icon(Icons.shield_outlined, color: scheme.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Signed in as ${platformRoleName(role)}',
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 3),
                  Text(
                    roleCanAdministerPlatform(role)
                        ? 'You can time out, suspend, and ban accounts.'
                        : 'You can time out accounts. Bans and suspensions '
                            'need an admin.',
                    style: TextStyle(
                        fontSize: 12.5, color: AppColors.subtle(context)),
                  ),
                  const SizedBox(height: 6),
                  // The limit that matters most, said up front rather than
                  // discovered when someone asks for a message to be removed.
                  Text(
                    'Sanctions control access to the app — the directory, '
                    'push, payments. Messages are end-to-end encrypted and '
                    'have no server copy, so nobody here can read or delete '
                    'them.',
                    style: TextStyle(
                        fontSize: 12, color: AppColors.subtle(context)),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Reports grouped by the account they point at: five reports about one
  /// person are one decision, not five rows to rediscover the pattern in.
  /// Reports with no account attached stay single — there is nothing to
  /// group them by and nobody to act on.
  List<Widget> _reportList(BuildContext context) {
    final reports = _reports ?? const <ModerationReport>[];
    if (reports.isEmpty) {
      return [_empty(Icons.flag_outlined, 'No open reports')];
    }
    final byPhone = <String, List<ModerationReport>>{};
    final loose = <ModerationReport>[];
    for (final r in reports) {
      if (r.targetPhone.isEmpty) {
        loose.add(r);
      } else {
        byPhone.putIfAbsent(r.targetPhone, () => []).add(r);
      }
    }
    // Most-reported first: the pile the queue exists to surface.
    final grouped = byPhone.entries.toList()
      ..sort((a, b) => b.value.length.compareTo(a.value.length));
    return [
      for (final e in grouped) _accountCard(context, e.key, e.value),
      for (final r in loose)
        InfoSection(children: [
          InfoTile(
            leading: const Icon(Icons.flag_outlined),
            title: r.reason.isEmpty ? 'Report' : r.reason,
            subtitle: [
              if (r.context.isNotEmpty) r.context,
              if (r.detail.isNotEmpty) r.detail,
              'No account attached',
            ].join(' · '),
            trailing: TextButton(
              onPressed: () async {
                await PlatformModeration.instance.markHandled(r.id);
                await _load();
              },
              child: const Text('Dismiss'),
            ),
          ),
        ]),
    ];
  }

  /// One reported account: how many reports, what they say, whether a
  /// sanction already stands — the whole picture before the gavel.
  Widget _accountCard(
      BuildContext context, String phone, List<ModerationReport> reports) {
    final handle = reports
        .map((r) => r.targetHandle)
        .firstWhere((h) => h.isNotEmpty, orElse: () => '');
    final reasons = {
      for (final r in reports)
        if (r.reason.isNotEmpty) r.reason
    };
    final standing = _sanctions
        ?.where((s) => s.phone == phone)
        .firstOrNull;
    return InfoSection(children: [
      InfoTile(
        leading: Icon(
            reports.length > 1 ? Icons.flag : Icons.flag_outlined,
            color: reports.length > 2 ? Colors.redAccent : null),
        title: [
          if (handle.isNotEmpty) '@$handle' else AccountService.maskPhone(phone),
          if (reports.length > 1) '${reports.length} reports',
        ].join(' · '),
        subtitle: [
          if (reasons.isNotEmpty) reasons.join(', '),
          // A sanction already standing is the first thing to know — the
          // next report on a banned account usually needs no second ban.
          if (standing != null)
            'Already ${sanctionKindLabel(standing.sanction.kind).toLowerCase()}',
        ].join(' · '),
        onTap: () => _accountSheet(context, phone, handle, reports),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 8, 8),
        child: Row(
          children: [
            Expanded(
              child: Text(
                handle.isEmpty
                    ? 'Tap for the reports'
                    : '${AccountService.maskPhone(phone)} · tap for the '
                        'reports',
                style: TextStyle(
                    fontSize: 12.5, color: AppColors.subtle(context)),
              ),
            ),
            TextButton(
              onPressed: () =>
                  _actOn(context, phone: phone, handle: handle),
              child: const Text('Act'),
            ),
            TextButton(
              onPressed: () async {
                for (final r in reports) {
                  await PlatformModeration.instance.markHandled(r.id);
                }
                await _load();
              },
              child: Text(
                  reports.length > 1 ? 'Dismiss all' : 'Dismiss'),
            ),
          ],
        ),
      ),
    ]);
  }

  /// The account's reports in full, each dismissible on its own — for the
  /// pile where one report is real and four are a brigade.
  Future<void> _accountSheet(BuildContext context, String phone,
      String handle, List<ModerationReport> reports) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(
                handle.isEmpty
                    ? AccountService.maskPhone(phone)
                    : '@$handle · ${AccountService.maskPhone(phone)}',
                style: const TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w700),
              ),
            ),
            for (final r in reports)
              ListTile(
                leading: const Icon(Icons.flag_outlined, size: 20),
                title: Text(r.reason.isEmpty ? 'Report' : r.reason),
                subtitle: Text([
                  if (r.context.isNotEmpty) r.context,
                  if (r.detail.isNotEmpty) r.detail,
                ].join(' · ')),
                trailing: TextButton(
                  onPressed: () async {
                    await PlatformModeration.instance.markHandled(r.id);
                    if (sheetContext.mounted) {
                      Navigator.of(sheetContext).pop();
                    }
                    await _load();
                  },
                  child: const Text('Dismiss'),
                ),
              ),
          ],
        ),
      ),
    );
  }

  List<Widget> _sanctionList(BuildContext context) {
    final sanctions = _sanctions ?? const <SanctionEntry>[];
    if (sanctions.isEmpty) {
      return [_empty(Icons.verified_user_outlined, 'Nobody is sanctioned')];
    }
    final now = DateTime.now().toUtc();
    return [
      for (final e in sanctions)
        InfoSection(children: [
          InfoTile(
            leading: Icon(switch (e.sanction.kind) {
              SanctionKind.ban => Icons.block,
              SanctionKind.suspend => Icons.pause_circle_outline,
              _ => Icons.timer_outlined,
            }),
            title: '${sanctionKindLabel(e.sanction.kind)} · '
                '${AccountService.maskPhone(e.phone)}',
            subtitle: [
              if (e.sanction.reason.isNotEmpty) e.sanction.reason,
              e.sanction.until == null
                  ? 'Permanent'
                  : '${sanctionRemaining(e.sanction.until, now)} left',
            ].join(' · '),
            trailing: TextButton(
              onPressed: () => _lift(e),
              child: const Text('Lift'),
            ),
          ),
        ]),
    ];
  }

  Widget _empty(IconData icon, String text) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 48, horizontal: 32),
        child: Column(
          children: [
            Icon(icon, size: 46, color: Colors.grey.shade400),
            const SizedBox(height: 12),
            Text(text,
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.subtle(context))),
          ],
        ),
      );

  Future<void> _lift(SanctionEntry entry) async {
    final ok = await showAppConfirmDialog(
      context,
      icon: Icons.lock_open,
      title: 'Lift this sanction?',
      message: '${AccountService.maskPhone(entry.phone)} regains full access '
          'to the app.',
      confirmLabel: 'Lift',
    );
    if (!ok) return;
    final done = await PlatformModeration.instance.lift(entry.phone);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(done
            ? 'Sanction lifted'
            : 'The server refused that — check your role.')));
    await _load();
  }

  Future<void> _actOn(BuildContext context,
      {required String phone, required String handle}) async {
    final applied = await showModalBottomSheet<bool>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => _SanctionSheet(phone: phone, handle: handle),
    );
    if (applied == true) await _load();
  }

  /// The owner's team page: who holds which role, a demote/promote menu on
  /// each, and a way to grant a role by number. Every change is a server
  /// round trip the server re-authorises; this screen just asks.
  List<Widget> _teamList(BuildContext context) {
    final team = _team;
    return [
      InfoSection(children: [
        InfoTile(
          leading: const Icon(Icons.person_add_alt_outlined),
          title: 'Grant a role',
          subtitle:
              'Make someone a moderator or an admin, by number or @username',
          onTap: () => _grantRole(context),
        ),
      ]),
      if (team == null)
        Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'Couldn\'t load the team. Deploy the roles-set function '
            '(docs/edge_functions_paste/roles-set.ts) and refresh.',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.subtle(context)),
          ),
        )
      else ...[
        for (final entry in team)
          ListTile(
            leading: Icon(switch (entry.role) {
              PlatformRole.owner => Icons.workspace_premium_outlined,
              PlatformRole.admin => Icons.shield_outlined,
              _ => Icons.local_police_outlined,
            }),
            title: Text(entry.label),
            subtitle: Text(
                '${platformRoleName(entry.role)} · ${entry.phone}'),
            trailing: entry.role == PlatformRole.owner
                ? null
                : PopupMenuButton<PlatformRole>(
                    onSelected: (r) => _applyRole(entry.phone, r),
                    itemBuilder: (_) => [
                      if (entry.role != PlatformRole.admin)
                        const PopupMenuItem(
                            value: PlatformRole.admin,
                            child: Text('Make admin')),
                      if (entry.role != PlatformRole.moderator)
                        const PopupMenuItem(
                            value: PlatformRole.moderator,
                            child: Text('Make moderator')),
                      const PopupMenuItem(
                          value: PlatformRole.member,
                          child: Text('Remove role')),
                    ],
                  ),
          ),
        if (team.isEmpty)
          Padding(
            padding: const EdgeInsets.all(24),
            child: Text('No roles granted yet.',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.subtle(context))),
          ),
      ],
    ];
  }

  List<Widget> _userList(BuildContext context) {
    final users = _users;
    if (users == null) {
      return [
        Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'Couldn\'t load the roster. Run docs/admin_users.sql and refresh.',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.subtle(context)),
          ),
        ),
      ];
    }
    final (total, list) = users;
    final numberless = list.where((u) => u.numberless).length;
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
        child: Text(
          '$total ${total == 1 ? 'account' : 'accounts'} · '
          '$numberless name-only in this page',
          style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: AppColors.subtle(context)),
        ),
      ),
      for (final u in list)
        ListTile(
          leading: CircleAvatar(
            radius: 18,
            child: Text(u.username.isEmpty
                ? '?'
                : u.username[0].toUpperCase()),
          ),
          title: Row(
            children: [
              Flexible(
                child: Text(u.label,
                    maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
              if (u.verified) ...[
                const SizedBox(width: 4),
                const Icon(Icons.verified, size: 15, color: Color(0xFF3897F0)),
              ],
            ],
          ),
          subtitle: Text([
            '@${u.username}',
            if (u.numberless) 'name-only',
            if (u.hidden) 'deactivated',
          ].join(' · ')),
          trailing: IconButton(
            icon: const Icon(Icons.gavel, size: 20),
            tooltip: 'Act on account',
            onPressed: () =>
                _actOn(context, phone: '', handle: u.username),
          ),
        ),
      if (list.isEmpty)
        Padding(
          padding: const EdgeInsets.all(24),
          child: Text('No accounts yet.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.subtle(context))),
        ),
    ];
  }

  Future<void> _applyRole(String phone, PlatformRole role) async {
    final messenger = ScaffoldMessenger.of(context);
    final ok = await PlatformModeration.instance.setRole(phone, role);
    messenger.showSnackBar(SnackBar(
        content: Text(ok
            ? (role == PlatformRole.member
                ? 'Role removed.'
                : 'Now ${platformRoleName(role)}.')
            : 'The server refused that change.')));
    if (ok) _load();
  }

  Future<void> _grantRole(BuildContext context) async {
    final who = TextEditingController();
    var role = PlatformRole.moderator;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: const Text('Grant a role'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: who,
                decoration: const InputDecoration(
                    labelText: 'Phone number or @username'),
              ),
              const SizedBox(height: 12),
              SegmentedButton<PlatformRole>(
                segments: const [
                  ButtonSegment(
                      value: PlatformRole.moderator,
                      label: Text('Moderator')),
                  ButtonSegment(
                      value: PlatformRole.admin, label: Text('Admin')),
                ],
                selected: {role},
                onSelectionChanged: (s) =>
                    setDialogState(() => role = s.first),
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('Grant')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    // Anything with a letter in it is a handle — a phone number never has
    // one, and a username always does (digits-only handles don't exist:
    // they would be indistinguishable from numbers everywhere).
    final raw = who.text.trim();
    if (RegExp(r'[A-Za-z]').hasMatch(raw)) {
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(this.context);
      final done =
          await PlatformModeration.instance.setRoleByHandle(raw, role);
      messenger.showSnackBar(SnackBar(
          content: Text(done
              ? 'Now ${platformRoleName(role)}.'
              : 'The server refused that — check the username, and that '
                  'the current roles-set function is deployed.')));
      if (done) _load();
    } else {
      await _applyRole(raw, role);
    }
  }
}

/// Pick an account, a sanction, a length, and a reason.
class _SanctionSheet extends StatefulWidget {
  final String phone;
  final String handle;
  const _SanctionSheet({required this.phone, required this.handle});

  @override
  State<_SanctionSheet> createState() => _SanctionSheetState();
}

class _SanctionSheetState extends State<_SanctionSheet> {
  late final TextEditingController _phone =
      TextEditingController(text: widget.phone);
  final _reason = TextEditingController();
  final _handle = TextEditingController();
  SanctionKind _kind = SanctionKind.timeout;
  String _duration = '1 hour';
  bool _sending = false;
  bool _searching = false;
  String? _found; // '@handle' the number field was filled from

  @override
  void dispose() {
    _phone.dispose();
    _reason.dispose();
    _handle.dispose();
    super.dispose();
  }

  /// Resolves an @username to its account through the directory, because a
  /// report or a feed shows moderators a handle, and asking them to find the
  /// number themselves is asking them to give up.
  Future<void> _lookup() async {
    final q = AccountService.normalizeUsername(_handle.text);
    if (q.length < 2 || _searching) return;
    setState(() => _searching = true);
    final matches = await AccountService.instance.searchByUsername(q);
    if (!mounted) return;
    setState(() => _searching = false);
    if (matches.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Nobody found for @$q.')));
      return;
    }
    final pick = matches.length == 1
        ? matches.first
        : await showModalBottomSheet<AppUser>(
            context: context,
            showDragHandle: true,
            builder: (sheet) => SafeArea(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final u in matches)
                    ListTile(
                      title: Text(u.name),
                      subtitle: Text('@${u.username}'),
                      onTap: () => Navigator.of(sheet).pop(u),
                    ),
                ],
              ),
            ),
          );
    if (pick == null || !mounted) return;
    setState(() {
      _phone.text = pick.phone.replaceAll(RegExp(r'\D'), '');
      _found = '@${pick.username}';
    });
  }

  Future<void> _submit() async {
    final digits = _phone.text.replaceAll(RegExp(r'\D'), '');
    if (digits.isEmpty) return;
    setState(() => _sending = true);
    final store = PlatformModeration.instance;
    final ok = await store.apply(
      targetPhone: digits,
      kind: _kind,
      reason: _reason.text.trim(),
      // A ban is permanent; the others need a clock.
      minutes: _kind == SanctionKind.ban
          ? 0
          : (sanctionDurations[_duration] ?? 60),
    );
    if (!mounted) return;
    setState(() => _sending = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(ok
            ? '${sanctionKindLabel(_kind)}: '
                '${AccountService.maskPhone(digits)}'
            : 'The server refused that. You may not outrank them, or a ban '
                'needs an admin.')));
    if (ok) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final role = PlatformModeration.instance.role;
    final kinds = [
      for (final k in [
        SanctionKind.timeout,
        SanctionKind.suspend,
        SanctionKind.ban,
      ])
        if (roleCanApply(role, k)) k
    ];
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
            left: 20,
            right: 20,
            bottom: MediaQuery.of(context).viewInsets.bottom + 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Act on an account',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text(
                'Removes access to the app. It does not touch conversations — '
                'those are encrypted and have no server copy.',
                style:
                    TextStyle(fontSize: 12.5, color: AppColors.subtle(context))),
            const SizedBox(height: 14),
            TextField(
              controller: _phone,
              keyboardType: TextInputType.phone,
              decoration: InputDecoration(
                labelText: 'Phone number or account code',
                helperText: _found ??
                    (widget.handle.isEmpty ? null : '@${widget.handle}'),
                border: const OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _handle,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _lookup(),
              decoration: InputDecoration(
                labelText: 'Or find by @username',
                border: const OutlineInputBorder(),
                isDense: true,
                suffixIcon: _searching
                    ? const Padding(
                        padding: EdgeInsets.all(10),
                        child: SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2)),
                      )
                    : IconButton(
                        icon: const Icon(Icons.search),
                        tooltip: 'Find the account',
                        onPressed: _lookup,
                      ),
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              children: [
                for (final k in kinds)
                  ChoiceChip(
                    label: Text(sanctionKindLabel(k)),
                    selected: _kind == k,
                    onSelected: (_) => setState(() => _kind = k),
                  ),
              ],
            ),
            if (_kind != SanctionKind.ban) ...[
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final d in sanctionDurations.keys)
                    ChoiceChip(
                      label: Text(d),
                      selected: _duration == d,
                      onSelected: (_) => setState(() => _duration = d),
                    ),
                ],
              ),
            ] else
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text('A ban is permanent until an admin lifts it.',
                    style: TextStyle(
                        fontSize: 12.5, color: AppColors.subtle(context))),
              ),
            const SizedBox(height: 12),
            TextField(
              controller: _reason,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Reason',
                hintText: 'Shown to the account and kept in the log',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _sending ? null : _submit,
              style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                  backgroundColor: _kind == SanctionKind.ban
                      ? Theme.of(context).colorScheme.error
                      : null),
              child: Text(_sending
                  ? 'Applying…'
                  : 'Apply ${sanctionKindLabel(_kind).toLowerCase()}'),
            ),
          ],
        ),
      ),
    );
  }
}
