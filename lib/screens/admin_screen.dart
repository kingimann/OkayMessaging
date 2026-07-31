import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

import '../models/platform_role.dart';
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

enum _Tab { reports, sanctions }

class _AdminScreenState extends State<AdminScreen> {
  _Tab _tab = _Tab.reports;
  List<ModerationReport>? _reports;
  List<SanctionEntry>? _sanctions;
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
    if (!mounted) return;
    setState(() {
      _reports = reports;
      _sanctions = sanctions;
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
          else
            ..._sanctionList(context),
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

  List<Widget> _reportList(BuildContext context) {
    final reports = _reports ?? const <ModerationReport>[];
    if (reports.isEmpty) {
      return [_empty(Icons.flag_outlined, 'No open reports')];
    }
    return [
      for (final r in reports)
        InfoSection(children: [
          InfoTile(
            leading: const Icon(Icons.flag_outlined),
            title: r.reason.isEmpty ? 'Report' : r.reason,
            subtitle: [
              if (r.targetHandle.isNotEmpty) '@${r.targetHandle}',
              if (r.context.isNotEmpty) r.context,
              if (r.detail.isNotEmpty) r.detail,
            ].join(' · '),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 8, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    r.targetPhone.isEmpty
                        ? 'No account attached'
                        : AccountService.maskPhone(r.targetPhone),
                    style: TextStyle(
                        fontSize: 12.5, color: AppColors.subtle(context)),
                  ),
                ),
                if (r.targetPhone.isNotEmpty)
                  TextButton(
                    onPressed: () => _actOn(context,
                        phone: r.targetPhone, handle: r.targetHandle),
                    child: const Text('Act'),
                  ),
                TextButton(
                  onPressed: () async {
                    await PlatformModeration.instance.markHandled(r.id);
                    await _load();
                  },
                  child: const Text('Dismiss'),
                ),
              ],
            ),
          ),
        ]),
    ];
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
  SanctionKind _kind = SanctionKind.timeout;
  String _duration = '1 hour';
  bool _sending = false;

  @override
  void dispose() {
    _phone.dispose();
    _reason.dispose();
    super.dispose();
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
                labelText: 'Phone number',
                helperText: widget.handle.isEmpty ? null : '@${widget.handle}',
                border: const OutlineInputBorder(),
                isDense: true,
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
