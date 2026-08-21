import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

import '../models/platform_role.dart';
import '../models/user.dart';
import '../state/account_service.dart';
import '../state/platform_moderation.dart';
import '../state/moderation_queue.dart';
import '../utils/date_formatter.dart';
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

enum _Tab { reports, sanctions, log, team, users }

class _AdminScreenState extends State<AdminScreen> {
  _Tab _tab = _Tab.reports;
  List<ModerationReport>? _reports;
  List<SanctionEntry>? _sanctions;
  List<RoleEntry>? _team;
  List<ModerationLogEntry>? _log;
  AuditChainStatus? _chain;
  (int, List<AdminUser>)? _users;
  bool _busy = false;

  /// One box per tab that has one. Kept apart on purpose: a query typed to
  /// find an account in the roster means nothing in the audit trail, and
  /// carrying it across would make a tab look empty for a reason nobody
  /// could see.
  final _userQuery = TextEditingController();
  final _logQuery = TextEditingController();

  @override
  void dispose() {
    _userQuery.dispose();
    _logQuery.dispose();
    super.dispose();
  }

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
    // Every moderator may read the trail, including their own entries — a
    // record only the owner can see is not one the team is held to.
    final log = await store.auditLog();
    // Asked every time the console loads, beside the trail itself. Detection
    // that waits for somebody to run a query is detection nobody runs; this
    // puts the answer in front of the one person who would care.
    final chain = await store.verifyAuditLog();
    if (!mounted) return;
    setState(() {
      _reports = reports;
      _sanctions = sanctions;
      _team = team;
      _users = users;
      _log = log;
      _chain = chain;
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
          _summaryStrip(context),
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
                const ButtonSegment(
                  value: _Tab.log,
                  label: Text('History'),
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
          else if (_tab == _Tab.log)
            ..._logList(context)
          else if (_tab == _Tab.team)
            ..._teamList(context)
          else
            ..._userList(context),
        ],
      ),
    );
  }

  /// What is waiting, in one line, above the tabs.
  ///
  /// THE OLDEST WAIT IS THE POINT. A count says how much there is; only the
  /// wait says whether the queue is being kept up with, which is the question
  /// somebody opening this screen is actually asking — and it was the one
  /// thing the console could not answer, since a report's age was never drawn
  /// anywhere.
  ///
  /// Nothing loaded yet draws nothing, rather than a row of zeroes that would
  /// read as an empty queue.
  Widget _summaryStrip(BuildContext context) {
    final reports = _reports;
    final sanctions = _sanctions;
    if (reports == null || sanctions == null) return const SizedBox.shrink();
    final s = ModerationSummary.of(
      reports: reports,
      sanctions: sanctions,
      now: DateTime.now().toUtc(),
    );
    final subtle = AppColors.subtle(context);
    final wait = s.oldestWait;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 6),
      child: Wrap(
        spacing: 14,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (s.isClear)
            Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.check_circle_outline, size: 15, color: subtle),
              const SizedBox(width: 5),
              Text('Queue clear',
                  style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: subtle)),
            ])
          else ...[
            _summaryBit(context, Icons.flag_outlined,
                '${s.openReports} open on ${s.reportedAccounts} '
                '${s.reportedAccounts == 1 ? 'account' : 'accounts'}'),
            if (wait != null)
              _summaryBit(context, Icons.schedule,
                  'oldest ${shortWait(wait)}',
                  // A day is the point at which a queue has stopped being
                  // worked rather than merely being busy.
                  alarm: wait.inDays >= 1),
          ],
          if (s.activeSanctions > 0)
            _summaryBit(context, Icons.gavel,
                '${s.activeSanctions} sanctioned'),
        ],
      ),
    );
  }

  Widget _summaryBit(BuildContext context, IconData icon, String text,
      {bool alarm = false}) {
    final color =
        alarm ? Theme.of(context).colorScheme.error : AppColors.subtle(context);
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, size: 15, color: color),
      const SizedBox(width: 5),
      Text(text,
          style: TextStyle(
              fontSize: 12.5, fontWeight: FontWeight.w600, color: color)),
    ]);
  }

  /// A plain filter box. Filters what is ALREADY loaded — there is no
  /// server-side search behind either list, and a box that silently searched
  /// one page while looking like it searched everything would be worse than
  /// none, so both say what they cover.
  Widget _searchBox(
      BuildContext context, TextEditingController c, String hint) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: TextField(
        controller: c,
        onChanged: (_) => setState(() {}),
        decoration: InputDecoration(
          isDense: true,
          hintText: hint,
          prefixIcon: const Icon(Icons.search, size: 20),
          suffixIcon: c.text.isEmpty
              ? null
              : IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  tooltip: 'Clear',
                  onPressed: () => setState(c.clear),
                ),
          border: const OutlineInputBorder(),
        ),
      ),
    );
  }

  /// The audit trail — who did what, and when.
  ///
  /// Read-only by design: an audit trail with an edit button is not one. It
  /// shows the ACTOR as prominently as the target, which is the whole point
  /// — the sanctions tab already says who is sanctioned; only this says who
  /// sanctioned them, and under what authority at the time.
  List<Widget> _logList(BuildContext context) {
    final log = _log;
    if (log == null) {
      return const [
        Padding(
          padding: EdgeInsets.all(40),
          child: Center(child: CircularProgressIndicator()),
        ),
      ];
    }
    final banner = _chainBanner(context);
    if (log.isEmpty) {
      return [
        banner,
        Padding(
          padding: const EdgeInsets.all(36),
          child: Center(
            child: Text(
              'No moderation actions yet. Every sanction, takedown and role '
              'change is recorded here, with who made it.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.subtle(context)),
            ),
          ),
        ),
      ];
    }
    final shown = [
      for (final e in log)
        if (auditEntryMatches(e, _logQuery.text)) e
    ];
    return [
      banner,
      _searchBox(context, _logQuery, 'Search by account, action or reason'),
      if (shown.isEmpty)
        _empty(Icons.search_off, 'No entry matches that'),
      for (final e in shown)
        ListTile(
          leading: Icon(_logIcon(e.action)),
          title: Text(
            e.action.isEmpty ? 'Action' : e.action,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          subtitle: Text([
            if (e.targetPhone.isNotEmpty) 'on ${e.targetPhone}',
            if (e.actorPhone.isNotEmpty)
              'by ${e.actorPhone}'
                  '${e.actorRole.isEmpty ? '' : ' (${e.actorRole})'}',
            if (e.reason.isNotEmpty) e.reason,
            if (e.until != null)
              'until ${DateFormatter.chatListLabel(e.until!)}',
          ].join(' · ')),
          trailing: Text(
            DateFormatter.postAge(e.createdAt),
            style: TextStyle(fontSize: 11.5, color: AppColors.subtle(context)),
          ),
        ),
    ];
  }

  /// Whether the trail still adds up, said above the trail itself.
  ///
  /// Three answers, and the third is the one worth keeping apart from the
  /// others: verified, broken, and **could not be checked**. A project that
  /// has not run `docs/audit_log_immutable.sql`, or whose deployed
  /// `moderation-queue` predates the `verify` action, has no verifier — and a
  /// check that could not run must never be drawn as a pass. It is grey and
  /// says so, rather than showing a tick.
  ///
  /// The entry COUNT is on the good answer deliberately. A chain over an
  /// emptied table verifies perfectly; the number is what makes "verified"
  /// mean something rather than being a tick over nothing.
  Widget _chainBanner(BuildContext context) {
    final chain = _chain;
    final scheme = Theme.of(context).colorScheme;
    final subtle = AppColors.subtle(context);

    late final IconData icon;
    late final Color tint;
    late final String title;
    late final String detail;

    if (chain == null || !chain.checked) {
      icon = Icons.help_outline;
      tint = subtle;
      title = 'Tamper check unavailable';
      detail = 'Actions are still recorded. This server has not been set up '
          'to verify the trail, so nothing here confirms it is intact.';
    } else if (chain.ok) {
      // Ink, not green. A passing check is the ordinary state of this screen
      // and does not need a colour of its own; the error case is where the
      // loud one belongs. Same rule the rest of the app follows.
      icon = Icons.verified_outlined;
      tint = AppColors.accentOn(context);
      title = 'Trail verified';
      detail = '${chain.entries} '
          '${chain.entries == 1 ? 'entry' : 'entries'}, each linked to the one '
          'before it. Entries cannot be edited or removed.';
    } else {
      icon = Icons.gpp_bad_outlined;
      tint = scheme.error;
      title = 'Trail does not verify';
      detail = chain.brokenId > 0
          ? 'Entry #${chain.brokenId}: ${chain.detail}. Everything recorded '
              'after it is affected.'
          : '${chain.detail}. Everything recorded after it is affected.';
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(color: tint.withValues(alpha: 0.4)),
          color: tint.withValues(alpha: 0.06),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 20, color: tint),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style:
                          TextStyle(fontWeight: FontWeight.w600, color: tint)),
                  const SizedBox(height: 2),
                  Text(detail,
                      style: TextStyle(fontSize: 12.5, color: subtle)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// The action string comes from the server and an older client must not
  /// hide one it has not heard of — an unknown action still gets a row, just
  /// a neutral glyph.
  IconData _logIcon(String action) => switch (action) {
        'ban' => Icons.block,
        'suspend' => Icons.pause_circle_outline,
        'timeout' => Icons.timer_outlined,
        'shadow' => Icons.visibility_off_outlined,
        'takedown' => Icons.delete_outline,
        'lift' || 'unban' => Icons.lock_open,
        'role' => Icons.shield_outlined,
        _ => Icons.history,
      };

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
                        ? 'You can time out, suspend, ban and shadow ban '
                            'accounts, or bar one from a single part of the '
                            'app.'
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
    // Ordered by `groupReports`, which is where the rule lives and is
    // tested: unactioned piles first, then most-reported, then longest
    // waiting. Age was the signal this list never had.
    final grouped = groupReports(reports, sanctions: _sanctions ?? const []);
    return [
      for (final g in grouped) _accountCard(context, g),
      for (final r in looseReports(reports))
        InfoSection(children: [
          InfoTile(
            leading: const Icon(Icons.flag_outlined),
            title: r.reason.isEmpty ? 'Report' : r.reason,
            subtitle: [
              if (r.context.isNotEmpty) r.context,
              if (r.detail.isNotEmpty) r.detail,
              'No account attached',
              'waiting ${shortWait(DateTime.now().toUtc().difference(r.createdAt))}',
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
  Widget _accountCard(BuildContext context, ReportGroup g) {
    final phone = g.phone;
    final handle = g.handle;
    final reports = g.reports;
    final standing = g.standing;
    final waited = DateTime.now().toUtc().difference(g.oldest);
    return InfoSection(children: [
      InfoTile(
        leading: Icon(
            reports.length > 1 ? Icons.flag : Icons.flag_outlined,
            color: reports.length > 2 ? Colors.redAccent : null),
        title: [
          if (handle.isNotEmpty) '@$handle' else AccountService.maskPhone(phone),
          if (reports.length > 1) '${reports.length} reports',
          // How long the OLDEST has waited, which is what a count alone
          // loses: one report sitting for a week is worse than three that
          // arrived this morning.
          'waiting ${shortWait(waited)}',
        ].join(' · '),
        subtitle: [
          if (g.reasons.isNotEmpty) g.reasons.join(', '),
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
                // ASKS FIRST when it is more than one. Dismissing is how a
                // report leaves the queue for good, and clearing four in a
                // single tap next to an Act button is the mis-tap that
                // loses the one report that was real.
                if (reports.length > 1) {
                  final ok = await showAppConfirmDialog(
                    context,
                    icon: Icons.flag_outlined,
                    title: 'Dismiss ${reports.length} reports?',
                    message: 'They leave the queue and nobody sees them '
                        'again. The account itself is not changed.',
                    confirmLabel: 'Dismiss all',
                    destructive: true,
                  );
                  if (!ok) return;
                }
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
              // Not the clock the others fall back to: a shadow ban has no
              // end, and an hourglass beside one reads as temporary.
              SanctionKind.shadow => Icons.visibility_off_outlined,
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
    // A ban is the one sanction that can also have barred the email behind
    // the account, so it is the one lift that has a second half to offer.
    final emailToo = entry.sanction.kind == SanctionKind.ban &&
        roleCanAdministerPlatform(PlatformModeration.instance.role);
    var giveEmailBack = true;
    final ok = emailToo
        ? await _confirmLiftWithEmail(entry, (v) => giveEmailBack = v)
        : await showAppConfirmDialog(
            context,
            icon: Icons.lock_open,
            title: 'Lift this sanction?',
            message:
                '${AccountService.maskPhone(entry.phone)} regains full access '
                'to the app.',
            confirmLabel: 'Lift',
          );
    if (!ok) return;
    final done = await PlatformModeration.instance.lift(entry.phone);
    // Only after the sanction itself came off: giving an address back while
    // the ban stands would leave the pair inconsistent in the direction that
    // helps the banned account.
    final email = (done && emailToo && giveEmailBack)
        ? await PlatformModeration.instance
            .setAccountEmailBanned(entry.phone, false)
        : null;
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(done
            ? 'Sanction lifted${_emailTail(email, barred: false)}'
            : 'The server refused that — check your role.')));
    await _load();
  }

  /// The lift dialog for a ban: the same question, plus the email behind it.
  /// Default ON — a lift means the account gets its access back, and leaving
  /// the address barred would quietly keep them from attaching it again.
  Future<bool> _confirmLiftWithEmail(
      SanctionEntry entry, ValueChanged<bool> onChanged) async {
    var give = true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          icon: const Icon(Icons.lock_open),
          title: const Text('Lift this sanction?'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('${AccountService.maskPhone(entry.phone)} regains full '
                  'access to the app.'),
              const SizedBox(height: 8),
              CheckboxListTile(
                value: give,
                onChanged: (v) => setDialogState(() {
                  give = v ?? false;
                  onChanged(give);
                }),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: const Text('Give back the email behind it'),
                subtitle: const Text(
                    'Lets that address be attached to an account again.'),
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('Lift')),
          ],
        ),
      ),
    );
    return ok == true;
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
        InfoTile(
          leading: const Icon(Icons.alternate_email),
          title: 'Ban an email',
          subtitle: 'Stop an address from being attached to any account',
          onTap: () => _banEmail(context),
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
    final shown = [
      for (final u in list)
        if (adminUserMatches(u, _userQuery.text)) u
    ];
    return [
      _searchBox(context, _userQuery, 'Search this page by name or @handle'),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        child: Text(
          [
            '$total ${total == 1 ? 'account' : 'accounts'}',
            // Says what the box actually covers. There is no server-side
            // search behind this list — a box that looked like it searched
            // every account while only filtering one page would be worse
            // than no box at all.
            if (_userQuery.text.trim().isNotEmpty)
              '${shown.length} of ${list.length} loaded match'
            else
              '$numberless name-only in this page',
          ].join(' · '),
          style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: AppColors.subtle(context)),
        ),
      ),
      if (shown.isEmpty)
        _empty(Icons.search_off, 'Nobody on this page matches that'),
      for (final u in shown)
        ListTile(
          onTap: () => _showUser(context, u),
          leading: Stack(
            clipBehavior: Clip.none,
            children: [
              CircleAvatar(
                radius: 18,
                child: Text(u.username.isEmpty
                    ? '?'
                    : u.username[0].toUpperCase()),
              ),
              // A green dot when the account is online now (last seen within
              // the presence window), like the presence dot everywhere else.
              if (u.online)
                Positioned(
                  right: -1,
                  bottom: -1,
                  child: Container(
                    width: 12,
                    height: 12,
                    decoration: BoxDecoration(
                      color: const Color(0xFF31A24C),
                      shape: BoxShape.circle,
                      border: Border.all(
                          color: Theme.of(context).scaffoldBackgroundColor,
                          width: 2),
                    ),
                  ),
                ),
            ],
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
            _presenceLine(u),
            if (u.numberless) 'name-only',
            if (u.hidden) 'deactivated',
          ].join(' · ')),
          trailing: Tooltip(
            message: 'Act on account',
            // manual, not the default long-press: this list is dense enough
            // that the popup landed on top of the row below it, hiding that
            // row's own text under an opaque box. The label still reaches a
            // screen reader through Tooltip's own semantics; it just never
            // shows as an on-screen popup here.
            triggerMode: TooltipTriggerMode.manual,
            child: IconButton(
              icon: const Icon(Icons.gavel, size: 20),
              onPressed: () =>
                  _actOn(context, phone: '', handle: u.username),
            ),
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

  /// The one-line presence summary under a name: online now, last seen a while
  /// ago, or never (a name-only account has no session to report from).
  String _presenceLine(AdminUser u) {
    if (u.online) return 'Online now';
    if (u.lastSeen != null) {
      return 'Last seen ${DateFormatter.postAge(u.lastSeen!)}';
    }
    return u.numberless ? 'Never signed in here' : 'Not seen recently';
  }

  /// A fuller card about one account — everything the directory can honestly
  /// answer, no phone number (the roster never carries one).
  void _showUser(BuildContext context, AdminUser u) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Stack(
                    clipBehavior: Clip.none,
                    children: [
                      CircleAvatar(
                        radius: 24,
                        child: Text(u.username.isEmpty
                            ? '?'
                            : u.username[0].toUpperCase()),
                      ),
                      if (u.online)
                        Positioned(
                          right: -1,
                          bottom: -1,
                          child: Container(
                            width: 14,
                            height: 14,
                            decoration: BoxDecoration(
                              color: const Color(0xFF31A24C),
                              shape: BoxShape.circle,
                              border: Border.all(
                                  color: Theme.of(context)
                                      .scaffoldBackgroundColor,
                                  width: 2),
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(u.label,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.w700)),
                            ),
                            if (u.verified) ...[
                              const SizedBox(width: 4),
                              const Icon(Icons.verified,
                                  size: 16, color: Color(0xFF3897F0)),
                            ],
                          ],
                        ),
                        Text('@${u.username}',
                            style:
                                TextStyle(color: AppColors.subtle(context))),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              _infoRow(context, Icons.circle,
                  _presenceLine(u), online: u.online),
              if (u.lastSeen != null)
                _infoRow(context, Icons.schedule,
                    'Last seen ${DateFormatter.callLabel(u.lastSeen!)}'),
              if (u.joined != null)
                _infoRow(context, Icons.event,
                    'Directory updated ${DateFormatter.callLabel(u.joined!)}'),
              _infoRow(
                  context,
                  u.verified ? Icons.verified : Icons.gpp_maybe_outlined,
                  u.verified ? 'ID verified' : 'Not ID verified'),
              _infoRow(
                  context,
                  u.numberless ? Icons.person_outline : Icons.phone,
                  u.numberless
                      ? 'Name-only account (no phone, no session)'
                      : 'Registered with a phone number'),
              if (u.hidden)
                _infoRow(context, Icons.visibility_off_outlined,
                    'Deactivated (hidden from the directory)'),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: () {
                    Navigator.of(context).pop();
                    _actOn(context, phone: '', handle: u.username);
                  },
                  icon: const Icon(Icons.gavel, size: 18),
                  label: const Text('Act on this account'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _infoRow(BuildContext context, IconData icon, String text,
      {bool online = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Icon(icon,
              size: 17,
              color: online
                  ? const Color(0xFF31A24C)
                  : AppColors.subtle(context)),
          const SizedBox(width: 12),
          Expanded(child: Text(text, style: const TextStyle(fontSize: 14))),
        ],
      ),
    );
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

  Future<void> _banEmail(BuildContext context) async {
    final email = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Ban an email'),
        content: TextField(
          controller: email,
          autofocus: true,
          keyboardType: TextInputType.emailAddress,
          decoration: const InputDecoration(labelText: 'email@example.com'),
          onSubmitted: (_) => Navigator.pop(dialogContext, true),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Ban')),
        ],
      ),
    );
    if (ok != true) return;
    final raw = email.text.trim();
    if (raw.isEmpty) return;
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(this.context);
    final done =
        await PlatformModeration.instance.setEmailBanned(raw, true);
    messenger.showSnackBar(SnackBar(
        content: Text(done
            ? '$raw is banned from signing up.'
            : 'The server refused that — check you\'re an owner/admin and '
                'that docs/banned_signups.sql is run.')));
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

/// What became of the email behind an account, appended to whatever the
/// sanction itself said. ONE copy for both the ban and the lift, because two
/// hand-written versions of the same three outcomes would drift — and the
/// middle outcome is the one worth getting right: "no email attached" is a
/// fact about that account, while "couldn't" is a fact about this project.
String _emailTail(EmailBanOutcome? outcome, {required bool barred}) =>
    switch (outcome) {
      null => '',
      EmailBanOutcome.done => barred
          ? ', and the email behind it is barred too.'
          : ', and the email behind it is free again.',
      EmailBanOutcome.noEmail =>
        '. No email to ${barred ? 'bar' : 'give back'} — that account has '
            'none attached.',
      EmailBanOutcome.unavailable =>
        '. The email couldn\'t be ${barred ? 'barred' : 'given back'} — '
            'check docs/email_account_bans.sql has been run.',
    };

/// Pick an account, a sanction, a length, and a reason.
class _SanctionSheet extends StatefulWidget {
  final String phone;
  final String handle;
  const _SanctionSheet({required this.phone, required this.handle});

  @override
  State<_SanctionSheet> createState() => _SanctionSheetState();
}

/// Whether a sanction hits the whole account or just one part of the app.
enum _Scope { account, area }

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

  _Scope _scope = _Scope.account;
  BanArea _area = BanArea.marketplace;

  /// Whether a ban also bars the email behind the account. Offered only with
  /// a ban, and default OFF: barring an address reaches beyond the account in
  /// front of the moderator — an inbox can be somebody's way back into an
  /// account they still legitimately hold — so it is a decision to make, not
  /// one to inherit from a checkbox that was already ticked.
  bool _alsoEmail = false;

  /// Areas this account is barred from right now, so a moderator can see what
  /// is already in force and give one back — the alternative is guessing.
  Set<BanArea>? _current;
  bool _loadingAreas = false;

  /// The label for "no end date". An area ban, like a full ban, is indefinite
  /// unless a duration is given.
  static const _permanent = 'Permanent';

  /// Neither of these has a clock: a ban lasts until an admin lifts it, and a
  /// shadow ban that lapsed would announce itself to the person it hides.
  bool get _timeless =>
      _kind == SanctionKind.ban || _kind == SanctionKind.shadow;

  String get _digits => _phone.text.replaceAll(RegExp(r'\D'), '');

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
    // A prefix search answers with handles and no numbers — the directory
    // only names a number for an exact handle, so that a two-letter query
    // cannot be walked into everybody's. Picking one is what asks.
    final resolved = pick.phone.isNotEmpty
        ? pick
        : await AccountService.instance.resolvePerson(pick.username);
    if (!mounted) return;
    if (resolved == null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Couldn\'t look up @${pick.username} just now.')));
      return;
    }
    setState(() {
      _phone.text = resolved.phone.replaceAll(RegExp(r'\D'), '');
      _found = '@${resolved.username}';
    });
    if (_scope == _Scope.area) _loadAreas();
  }

  /// Reads which areas the account is already barred from. Best-effort: an
  /// unanswered lookup leaves the list unknown rather than claiming none.
  Future<void> _loadAreas() async {
    final digits = _digits;
    if (digits.isEmpty) {
      setState(() => _current = null);
      return;
    }
    setState(() => _loadingAreas = true);
    final areas = await PlatformModeration.instance.areaBansFor(digits);
    if (!mounted) return;
    setState(() {
      _current = areas;
      _loadingAreas = false;
    });
  }

  Future<void> _submitArea({required bool lift}) async {
    final digits = _digits;
    if (digits.isEmpty) return;
    setState(() => _sending = true);
    final store = PlatformModeration.instance;
    final ok = lift
        ? await store.liftArea(digits, _area, reason: _reason.text.trim())
        : await store.banFromArea(digits, _area,
            reason: _reason.text.trim(),
            minutes:
                _duration == _permanent ? 0 : (sanctionDurations[_duration] ?? 0));
    if (!mounted) return;
    setState(() => _sending = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(ok
            ? '${lift ? 'Gave back' : 'Barred from'} '
                '${banAreaLabel(_area)}: ${AccountService.maskPhone(digits)}'
            : 'The server refused that. An area ban needs an admin, and you '
                'must outrank them.')));
    // Stay open: barring somebody from one area is usually followed by
    // another, and the list above has to show what just changed.
    if (ok) _loadAreas();
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
      // A ban and a shadow ban are indefinite; the others need a clock.
      minutes: _timeless ? 0 : (sanctionDurations[_duration] ?? 60),
    );
    // Only once the ban itself is in force. Barring the address behind an
    // account the server just refused to ban would be a sanction nobody
    // applied, on a list nothing in the console lists.
    final email = (ok && _alsoEmail && _kind == SanctionKind.ban)
        ? await store.setAccountEmailBanned(digits, true,
            reason: _reason.text.trim())
        : null;
    if (!mounted) return;
    setState(() => _sending = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(ok
            ? '${sanctionKindLabel(_kind)}: '
                '${AccountService.maskPhone(digits)}'
                '${_emailTail(email, barred: true)}'
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
        SanctionKind.shadow,
        SanctionKind.ban,
      ])
        if (roleCanApply(role, k)) k
    ];
    // An area ban is admin+ on the server, and so is barring the email behind
    // an account — so a moderator is never offered either, rather than being
    // offered something the server would only refuse.
    final canAdmin = roleCanAdministerPlatform(role);
    final area = _scope == _Scope.area;
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
                area
                    ? 'Takes away one part of the app and leaves the rest — a '
                        'marketplace scammer keeps their conversations.'
                    : 'Removes access to the app. It does not touch '
                        'conversations — those are encrypted and have no '
                        'server copy.',
                style:
                    TextStyle(fontSize: 12.5, color: AppColors.subtle(context))),
            if (canAdmin) ...[
              const SizedBox(height: 12),
              SegmentedButton<_Scope>(
                segments: const [
                  ButtonSegment(
                      value: _Scope.account, label: Text('Whole account')),
                  ButtonSegment(value: _Scope.area, label: Text('One area')),
                ],
                selected: {_scope},
                onSelectionChanged: (s) {
                  setState(() => _scope = s.first);
                  if (_scope == _Scope.area && _current == null) _loadAreas();
                },
              ),
            ],
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
            if (area) ...[
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final a in BanArea.values)
                    ChoiceChip(
                      label: Text(banAreaLabel(a)),
                      selected: _area == a,
                      onSelected: (_) => setState(() => _area = a),
                    ),
                ],
              ),
              const SizedBox(height: 10),
              _AreaBansLine(
                loading: _loadingAreas,
                current: _current,
                onRefresh: _digits.isEmpty ? null : _loadAreas,
              ),
            ] else
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final k in kinds)
                    ChoiceChip(
                      label: Text(sanctionKindLabel(k)),
                      selected: _kind == k,
                      onSelected: (_) => setState(() => _kind = k),
                    ),
                ],
              ),
            if (area || !_timeless) ...[
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  // An area ban may be indefinite; an account timeout or
                  // suspension always has an end.
                  for (final d in [
                    if (area) _permanent,
                    ...sanctionDurations.keys,
                  ])
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
                child: Text(
                    _kind == SanctionKind.shadow
                        // Said plainly, because it is the one sanction whose
                        // whole point is that the person is not told.
                        ? 'The account keeps working and is never told. Its '
                            'public posts, listings and forum threads stay '
                            'visible to them and to nobody else. It does not '
                            'expire — one that lapsed would announce itself.'
                        : 'A ban is permanent until an admin lifts it.',
                    style: TextStyle(
                        fontSize: 12.5, color: AppColors.subtle(context))),
              ),
            // A ban lands on the account's CODE, and a code costs nothing to
            // re-mint — so an account that signed up with an email and no
            // phone number can be banned and back the same afternoon on the
            // same inbox. This is the half that makes the ban stick.
            if (!area && _kind == SanctionKind.ban && canAdmin)
              CheckboxListTile(
                value: _alsoEmail,
                onChanged: (v) => setState(() => _alsoEmail = v ?? false),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: const Text('Also bar the email behind this account'),
                subtitle: Text(
                    'Stops that address signing up again. Does nothing for an '
                    'account that never attached one.',
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
            if (area) ...[
              FilledButton(
                onPressed: _sending ? null : () => _submitArea(lift: false),
                style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(48)),
                child: Text(_sending
                    ? 'Applying…'
                    : 'Bar from ${banAreaLabel(_area)}'),
              ),
              const SizedBox(height: 8),
              OutlinedButton(
                // Only offered for an area they are actually barred from —
                // a lift button for a ban that isn't there does nothing and
                // reads as though it did.
                onPressed: (_sending || !(_current?.contains(_area) ?? false))
                    ? null
                    : () => _submitArea(lift: true),
                style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(44)),
                child: Text('Give back ${banAreaLabel(_area)}'),
              ),
            ] else
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

/// What an account is already barred from, above the Apply button.
///
/// Three states, and they are not the same thing: not looked up yet, looked
/// up and barred from nothing, and a lookup that could not be answered. The
/// last one must not read as "barred from nothing" — that is how somebody
/// double-bans an account, or lifts one that was never there.
class _AreaBansLine extends StatelessWidget {
  final bool loading;
  final Set<BanArea>? current;
  final VoidCallback? onRefresh;
  const _AreaBansLine({
    required this.loading,
    required this.current,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    final subtle = AppColors.subtle(context);
    if (loading) {
      return Text('Checking what they are barred from…',
          style: TextStyle(fontSize: 12.5, color: subtle));
    }
    final now = current;
    if (now == null) {
      return Row(
        children: [
          Expanded(
            child: Text('Enter a number to see what is already in force.',
                style: TextStyle(fontSize: 12.5, color: subtle)),
          ),
          if (onRefresh != null)
            TextButton(onPressed: onRefresh, child: const Text('Check')),
        ],
      );
    }
    return Row(
      children: [
        Expanded(
          child: Text(
            now.isEmpty
                ? 'Not barred from anything.'
                : 'Barred from ${[for (final a in now) banAreaLabel(a)].join(', ')}.',
            style: TextStyle(
                fontSize: 12.5,
                color: now.isEmpty ? subtle : Theme.of(context).colorScheme.error,
                fontWeight: now.isEmpty ? null : FontWeight.w600),
          ),
        ),
        if (onRefresh != null)
          IconButton(
            icon: const Icon(Icons.refresh, size: 18),
            tooltip: 'Check again',
            onPressed: onRefresh,
          ),
      ],
    );
  }
}
