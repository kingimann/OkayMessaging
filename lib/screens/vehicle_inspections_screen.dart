import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../models/inspection.dart';
import '../models/signature_ink.dart';
import '../state/vehicle_inspections.dart';
import '../theme/app_theme.dart';
import '../util/backup_export.dart';
import '../util/file_moderation.dart';
import '../util/geocoding.dart';
import '../util/geolocation.dart';
import '../util/inspection_backup.dart';
import '../util/inspection_pdf.dart';
import '../util/media_saver.dart';
import '../util/inspection_report.dart';
import '../util/photo_prep.dart';
import '../widgets/app_dialogs.dart';
import '../widgets/info_section.dart';
import '../widgets/signature_pad.dart';
import 'home_screen.dart';

/// The vehicles this account inspects.
///
/// **A tool, not a compliance system**, and the screen says so rather than
/// leaving somebody to assume otherwise: it keeps the walk-around that was
/// actually done and hands it back as a report. It does not track hours of
/// service, it is not an electronic logging device, and it certifies
/// nothing. Shipping something that merely LOOKED compliant would put the
/// people using it in front of a fine, which is the one outcome worth
/// designing against.
class VehicleInspectionsScreen extends StatelessWidget {
  const VehicleInspectionsScreen({super.key, this.fromSidebar = false});

  /// Carried like every other sidebar destination; the leading is a normal
  /// back arrow either way (the 2026-08-09 navigation decision).
  final bool fromSidebar;

  Future<void> _edit(BuildContext context, {Vehicle? existing}) async {
    final store = VehicleInspections.instance;
    final name = TextEditingController(text: existing?.name ?? '');
    final plate = TextEditingController(text: existing?.plate ?? '');
    final notes = TextEditingController(text: existing?.notes ?? '');
    var type = existing?.type ?? VehicleType.other;
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheet) => Padding(
        padding: EdgeInsets.fromLTRB(
            16, 16, 16, MediaQuery.of(sheetContext).viewInsets.bottom + 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(existing == null ? 'Add a vehicle' : 'Edit vehicle',
                style: const TextStyle(
                    fontSize: 18, fontWeight: FontWeight.w700)),
            const SizedBox(height: 12),
            TextField(
              controller: name,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                  labelText: 'Unit name or number',
                  hintText: 'Truck 12'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: plate,
              textCapitalization: TextCapitalization.characters,
              decoration: const InputDecoration(labelText: 'Plate (optional)'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: notes,
              maxLines: 2,
              decoration: const InputDecoration(
                  labelText: 'Notes (optional)',
                  hintText: 'Make, model, anything worth remembering'),
            ),
            const SizedBox(height: 14),
            Align(
              alignment: Alignment.centerLeft,
              child: Text('WHAT IT IS',
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.6,
                      color: AppColors.subtle(sheetContext))),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              children: [
                for (final t in VehicleType.values)
                  ChoiceChip(
                    label: Text(t.label),
                    selected: type == t,
                    onSelected: (_) => setSheet(() => type = t),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              // Said where the choice is made, so nobody has to discover it
              // when the checklist turns out to be a different length.
              type.schedule == InspectionSchedule.schedule1
                  ? 'Walk-arounds use the Schedule 1 systems for trucks, '
                      'tractors and trailers.'
                  : 'Walk-arounds use the standard list.',
              style: TextStyle(
                  fontSize: 12, color: AppColors.subtle(sheetContext)),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () => Navigator.of(sheetContext).pop(true),
              child: Text(existing == null ? 'Add vehicle' : 'Save'),
            ),
          ],
        ),
      ),
      ),
    );
    if (saved != true) return;
    if (name.text.trim().isEmpty) return;
    final id = store.saveVehicle(
        id: existing?.id,
        name: name.text,
        plate: plate.text,
        notes: notes.text,
        type: type);
    if (id.isEmpty && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text(
              'That is as many vehicles as this device keeps '
              '(${VehicleInspections.maxVehicles}).')));
    }
  }

  Future<void> _editOperator(BuildContext context) async {
    final store = VehicleInspections.instance;
    final controller = TextEditingController(text: store.operatorName);
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => Padding(
        padding: EdgeInsets.fromLTRB(
            16, 16, 16, MediaQuery.of(sheetContext).viewInsets.bottom + 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('Operator',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            const Text(
              'The carrier or operator new records are filed under. Typed '
              'once — it is the same on every walk-around, and it is what '
              'somebody being shown a record asks for by name.',
              style: TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Operator name'),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () => Navigator.of(sheetContext).pop(true),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    if (saved != true) return;
    await store.setOperatorName(controller.text);
  }

  static String _clock(int minutes) =>
      '${(minutes ~/ 60).toString().padLeft(2, '0')}:'
      '${(minutes % 60).toString().padLeft(2, '0')}';

  Future<void> _editReminder(BuildContext context) async {
    final store = VehicleInspections.instance;
    final current = store.reminderMinutes;
    final picked = await showTimePicker(
      context: context,
      initialTime: current == null
          ? const TimeOfDay(hour: 6, minute: 0)
          : TimeOfDay(hour: current ~/ 60, minute: current % 60),
      helpText: 'Remind me to do the walk-around',
    );
    if (picked == null) return;
    await store.setReminder(picked.hour * 60 + picked.minute);
  }

  /// The whole log as a file the owner keeps.
  ///
  /// The confirm is the DISCLOSURE, not a formality: this file carries every
  /// record — names, plates, places, times and the photos — and it is not
  /// encrypted. Somebody about to drop it in a cloud drive should be told
  /// that before they do, rather than after.
  Future<void> _backup(BuildContext context) async {
    final store = VehicleInspections.instance;
    final ok = await showAppConfirmDialog(
      context,
      icon: Icons.save_alt,
      title: 'Back up to a file',
      message: '${store.vehicles.length} '
          '${store.vehicles.length == 1 ? 'vehicle' : 'vehicles'} and '
          '${store.inspections.length} '
          '${store.inspections.length == 1 ? 'inspection' : 'inspections'}, '
          'as one file you keep.\n\n'
          'It is NOT encrypted — it holds the names, plates, places and '
          'photos from every record. Put it somewhere you would be happy to '
          'put the paperwork.',
      confirmLabel: 'Save the file',
    );
    if (!ok || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    String? result;
    try {
      result = await exportBackupFile(
          InspectionBackup.fileName(DateTime.now()),
          Uint8List.fromList(utf8.encode(store.exportBackup())));
    } catch (_) {
      result = null;
    }
    messenger.showSnackBar(
        SnackBar(content: Text(result ?? 'Could not save the backup.')));
  }

  Future<void> _restore(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final bytes = await InspectionBackup.pickFile();
    if (bytes == null) return;
    InspectionBackup? backup;
    try {
      backup = InspectionBackup.decode(utf8.decode(bytes));
    } catch (_) {
      backup = null;
    }
    if (backup == null) {
      // The likeliest wrong file is a completely unrelated document, so the
      // message names what was expected rather than blaming the format.
      messenger.showSnackBar(const SnackBar(
          content: Text('That file is not an inspection backup.')));
      return;
    }
    if (!context.mounted) return;
    final ok = await showAppConfirmDialog(
      context,
      icon: Icons.restore,
      title: 'Restore from a file',
      message: 'The file holds ${backup.vehicles.length} '
          '${backup.vehicles.length == 1 ? 'vehicle' : 'vehicles'} and '
          '${backup.inspections.length} '
          '${backup.inspections.length == 1 ? 'inspection' : 'inspections'}.'
          '\n\nOnly the ones this phone does not already have are added. '
          'Nothing already here is changed or removed.',
      confirmLabel: 'Restore',
    );
    if (!ok) return;
    final added = VehicleInspections.instance.restoreBackup(backup);
    messenger.showSnackBar(SnackBar(
      content: Text(added.vehicles == 0 && added.inspections == 0
          // Said plainly rather than reporting a success that added nothing.
          ? 'Everything in that file was already on this phone.'
          : 'Added ${added.vehicles} '
              '${added.vehicles == 1 ? 'vehicle' : 'vehicles'} and '
              '${added.inspections} '
              '${added.inspections == 1 ? 'inspection' : 'inspections'}.'),
    ));
  }

  Future<void> _delete(BuildContext context, Vehicle vehicle) async {
    final store = VehicleInspections.instance;
    final records = store.forVehicle(vehicle.id).length;
    final ok = await showAppConfirmDialog(
      context,
      icon: Icons.delete_outline,
      title: 'Remove ${vehicle.name}?',
      message: records == 0
          ? 'The vehicle is removed from this device.'
          : 'The vehicle and its $records '
              '${records == 1 ? 'inspection' : 'inspections'} are removed '
              'from this device. Export anything you need to keep first.',
      confirmLabel: 'Remove',
      destructive: true,
    );
    if (!ok || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final gone = store.removeVehicle(vehicle.id);
    if (gone == null) return;
    messenger.showSnackBar(SnackBar(
      content: Text('Removed ${gone.$1.name}'),
      action: SnackBarAction(
        label: 'Undo',
        onPressed: () => store.restoreVehicle(gone.$1, gone.$2),
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final store = VehicleInspections.instance;
    return Scaffold(
      extendBody: true,
      appBar: AppBar(
        title: const Text('Inspections'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: 'Add a vehicle',
            onPressed: () => _edit(context),
          ),
          PopupMenuButton<String>(
            tooltip: 'More',
            onSelected: (choice) =>
                choice == 'backup' ? _backup(context) : _restore(context),
            itemBuilder: (_) => const [
              PopupMenuItem(
                  value: 'backup', child: Text('Back up to a file')),
              PopupMenuItem(
                  value: 'restore', child: Text('Restore from a file')),
            ],
          ),
        ],
      ),
      bottomNavigationBar: const HomeNavBar(),
      body: ListenableBuilder(
        listenable: store,
        builder: (context, _) {
          final vehicles = store.vehicles;
          return ListView(
            padding:
                EdgeInsets.only(bottom: HomeNavBar.clearance(context), top: 6),
            children: [
              if (vehicles.isEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(28, 60, 28, 24),
                  child: Column(
                    children: [
                      Icon(Icons.local_shipping_outlined,
                          size: 44, color: AppColors.subtle(context)),
                      const SizedBox(height: 14),
                      const Text('No vehicles yet',
                          style: TextStyle(
                              fontSize: 17, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 6),
                      Text(
                        'Add a vehicle, then record a pre-trip or post-trip '
                        'walk-around against it.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: AppColors.subtle(context)),
                      ),
                      const SizedBox(height: 18),
                      FilledButton.icon(
                        onPressed: () => _edit(context),
                        icon: const Icon(Icons.add),
                        label: const Text('Add a vehicle'),
                      ),
                    ],
                  ),
                ),
              if (store.notInspectedSince(DateTime.now()).isNotEmpty) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(28, 12, 28, 6),
                  child: Text('NOT INSPECTED IN THE LAST 24 HOURS',
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.6,
                          color: AppColors.subtle(context))),
                ),
                InfoSection(children: [
                  for (final (v, since)
                      in store.notInspectedSince(DateTime.now()))
                    InfoTile(
                      leading: const Icon(Icons.schedule),
                      title: v.name,
                      subtitle: since == null
                          ? 'Nothing recorded yet'
                          : 'Last inspected ${InspectionReport.age(
                              DateTime.now().subtract(since), DateTime.now())}',
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(
                              builder: (_) => VehicleScreen(vehicleId: v.id))),
                    ),
                ]),
                Padding(
                  padding: const EdgeInsets.fromLTRB(28, 2, 28, 4),
                  child: Text(
                    // The app counting hours, never a ruling on a record.
                    'What the log says, not a ruling on whether any '
                    'inspection is still good enough.',
                    style: TextStyle(
                        fontSize: 12, color: AppColors.subtle(context)),
                  ),
                ),
              ],
              if (store.withOpenDefects().isNotEmpty) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(28, 12, 28, 6),
                  child: Text('OUTSTANDING',
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.6,
                          color: Colors.red.shade600)),
                ),
                InfoSection(children: [
                  for (final (v, open) in store.withOpenDefects())
                    InfoTile(
                      leading: Icon(Icons.report_problem_outlined,
                          color: Colors.red.shade600),
                      title: v.name,
                      subtitle: open.map(checkItemName).join(', '),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(
                              builder: (_) => VehicleScreen(vehicleId: v.id))),
                    ),
                ]),
              ],
              InfoSection(children: [
                InfoTile(
                  leading: const Icon(Icons.business_outlined),
                  title: 'Operator',
                  subtitle: store.operatorName.isEmpty
                      ? 'Not set — the name records are filed under'
                      : store.operatorName,
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _editOperator(context),
                ),
                InfoTile(
                  leading: const Icon(Icons.alarm),
                  title: 'Daily reminder',
                  subtitle: store.reminderMinutes == null
                      ? 'Off'
                      : 'Every day at '
                          '${_clock(store.reminderMinutes!)} · on this device',
                  // A time picker has no "off", so turning it off is a
                  // visible action rather than a hidden gesture — and it is
                  // one tap either way.
                  trailing: store.reminderMinutes == null
                      ? const Icon(Icons.chevron_right)
                      : TextButton(
                          onPressed: () => store.setReminder(null),
                          child: const Text('Turn off'),
                        ),
                  onTap: () => _editReminder(context),
                ),
              ]),
              for (final v in vehicles)
                InfoSection(children: [
                  InfoTile(
                    leading: const Icon(Icons.local_shipping_outlined),
                    title: v.name,
                    subtitle: _vehicleSubtitle(store, v),
                    // Edit was unreachable until now: a vehicle could be
                    // created and never corrected, so a typo'd plate — or
                    // worse, the wrong TYPE, which decides the whole
                    // checklist — was permanent.
                    trailing: PopupMenuButton<String>(
                      tooltip: v.name,
                      onSelected: (choice) => choice == 'edit'
                          ? _edit(context, existing: v)
                          : _delete(context, v),
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: 'edit', child: Text('Edit')),
                        PopupMenuItem(value: 'remove', child: Text('Remove')),
                      ],
                    ),
                    onTap: () => Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => VehicleScreen(vehicleId: v.id))),
                  ),
                ]),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 18, 24, 8),
                child: Text(
                  // The two sentences that must not be trimmed, and a test
                  // pins them: what this keeps, and what it is not.
                  'Records are kept on this device only. Export anything you '
                  'need to keep.\n\n'
                  '${InspectionReport.disclaimer}',
                  style:
                      TextStyle(fontSize: 12, color: AppColors.subtle(context)),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  static String _vehicleSubtitle(VehicleInspections store, Vehicle v) {
    final last = store.lastFor(v.id);
    final plate = [
      if (v.type != VehicleType.other) v.type.label,
      if (v.subtitle.isNotEmpty) v.subtitle,
    ].join(' · ');
    if (last == null) {
      return plate.isEmpty ? 'No inspections yet' : '$plate · no inspections yet';
    }
    final line = '${last.kind.label} ${InspectionReport.stamp(last.at)} · '
        '${last.summary}';
    return plate.isEmpty ? line : '$plate · $line';
  }
}

/// One vehicle: what is outstanding on it, and everything recorded against
/// it so far.
class VehicleScreen extends StatefulWidget {
  const VehicleScreen({super.key, required this.vehicleId});

  final String vehicleId;

  @override
  State<VehicleScreen> createState() => _VehicleScreenState();
}

class _VehicleScreenState extends State<VehicleScreen> {
  final _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  String get vehicleId => widget.vehicleId;

  Future<void> _start(BuildContext context, InspectionKind kind) async {
    await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => InspectionScreen(vehicleId: vehicleId, kind: kind)));
  }

  @override
  Widget build(BuildContext context) {
    final store = VehicleInspections.instance;
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final vehicle = store.vehicleById(vehicleId);
        if (vehicle == null) {
          return Scaffold(
            appBar: AppBar(),
            body: const Center(child: Text('This vehicle was removed.')),
          );
        }
        final records = store.forVehicle(vehicleId);
        final shown = [
          for (final r in records)
            if (inspectionMatches(r, _query)) r
        ];
        final outstanding = store.outstandingDefects(vehicleId);
        return Scaffold(
          appBar: AppBar(title: Text(vehicle.name)),
          body: ListView(
            padding: const EdgeInsets.only(bottom: 28, top: 6),
            children: [
              if (vehicle.plate.trim().isNotEmpty ||
                  vehicle.notes.trim().isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(28, 4, 28, 8),
                  child: Text(
                    [
                      if (vehicle.plate.trim().isNotEmpty)
                        vehicle.plate.trim(),
                      if (vehicle.notes.trim().isNotEmpty) vehicle.notes.trim(),
                    ].join(' · '),
                    style: TextStyle(color: AppColors.subtle(context)),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: () => _start(context, InspectionKind.pre),
                        icon: const Icon(Icons.play_circle_outline),
                        label: const Text('Pre-trip'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => _start(context, InspectionKind.post),
                        icon: const Icon(Icons.stop_circle_outlined),
                        label: const Text('Post-trip'),
                      ),
                    ),
                  ],
                ),
              ),
              if (records.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                        minimumSize: const Size.fromHeight(46)),
                    onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute(
                            builder: (_) => InspectionShowScreen(
                                inspectionId: records.first.id))),
                    icon: const Icon(Icons.co_present_outlined),
                    label: const Text('Show the last inspection'),
                  ),
                ),
              if (records.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                  child: TextButton.icon(
                    onPressed: () async {
                      final messenger = ScaffoldMessenger.of(context);
                      String? result;
                      try {
                        result = await exportBackupFile(
                            InspectionReport.logFileName(vehicle),
                            await InspectionPdf.buildHistory(
                                vehicle, records));
                      } catch (_) {
                        result = null;
                      }
                      messenger.showSnackBar(SnackBar(
                          content:
                              Text(result ?? 'Could not export the log.')));
                    },
                    icon: const Icon(Icons.picture_as_pdf_outlined, size: 18),
                    label: Text('Export the whole log '
                        '(${records.length} '
                        '${records.length == 1 ? 'record' : 'records'})'),
                  ),
                ),
              if (outstanding.isNotEmpty) ...[
                const _Heading('DEFECTS ON THE LAST INSPECTION'),
                InfoSection(children: [
                  for (final id in outstanding)
                    InfoTile(
                      leading: Icon(Icons.report_problem_outlined,
                          color: Colors.red.shade600),
                      title: checkItemName(id),
                      subtitle: (records.first.notes[id] ?? '').trim().isEmpty
                          ? 'Tap to sign it off'
                          : records.first.notes[id]!.trim(),
                      onTap: () => InspectionRecordScreen.signOff(
                          context, records.first, id),
                    ),
                ]),
                Padding(
                  padding: const EdgeInsets.fromLTRB(28, 2, 28, 8),
                  child: Text(
                    // Said rather than implied: this list is the last
                    // inspection's defects, not a repair tracker. Carrying a
                    // defect forward would claim to know it was never fixed.
                    'Still outstanding on the most recent inspection. Sign '
                    'one off once the work is done, or record a new '
                    'inspection.',
                    style: TextStyle(
                        fontSize: 12, color: AppColors.subtle(context)),
                  ),
                ),
              ],
              if (store.recurringDefects(vehicleId).isNotEmpty) ...[
                const _Heading('KEEPS COMING BACK'),
                InfoSection(children: [
                  for (final (id, n) in store.recurringDefects(vehicleId))
                    InfoTile(
                      leading: const Icon(Icons.repeat),
                      title: checkItemName(id),
                      subtitle: 'Flagged on $n of the last '
                          '${records.length < VehicleInspections.recurringWindow ? records.length : VehicleInspections.recurringWindow} '
                          'inspections',
                    ),
                ]),
                Padding(
                  padding: const EdgeInsets.fromLTRB(28, 2, 28, 4),
                  child: Text(
                    // A pattern in the log, not a diagnosis.
                    'A pattern worth a mechanic looking at. It says nothing '
                    'about why.',
                    style: TextStyle(
                        fontSize: 12, color: AppColors.subtle(context)),
                  ),
                ),
              ],
              const _Heading('HISTORY'),
              // Offered only once there is enough of a log to hunt through —
              // a search box over two records is chrome.
              if (records.length >= 5)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: TextField(
                    controller: _search,
                    onChanged: (v) => setState(() => _query = v),
                    decoration: InputDecoration(
                      isDense: true,
                      prefixIcon: const Icon(Icons.search, size: 20),
                      hintText: 'Search this log',
                      suffixIcon: _query.isEmpty
                          ? null
                          : IconButton(
                              icon: const Icon(Icons.close, size: 18),
                              tooltip: 'Clear',
                              onPressed: () => setState(() {
                                _search.clear();
                                _query = '';
                              }),
                            ),
                    ),
                  ),
                ),
              if (records.isEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(28, 8, 28, 8),
                  child: Text('Nothing recorded yet.',
                      style: TextStyle(color: AppColors.subtle(context))),
                )
              else if (shown.isEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(28, 8, 28, 8),
                  child: Text('Nothing in this log matches "$_query".',
                      style: TextStyle(color: AppColors.subtle(context))),
                ),
              for (final r in shown)
                InfoSection(children: [
                  InfoTile(
                    leading: Icon(
                      r.defectCount > 0
                          ? Icons.report_problem_outlined
                          : Icons.check_circle_outline,
                      color: r.defectCount > 0 ? Colors.red.shade600 : null,
                    ),
                    title: '${r.kind.label} · ${InspectionReport.stamp(r.at)}',
                    subtitle: r.summary,
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) =>
                            InspectionRecordScreen(inspectionId: r.id))),
                  ),
                ]),
            ],
          ),
        );
      },
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(28, 18, 28, 6),
        child: Text(text,
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.6,
                color: AppColors.subtle(context))),
      );
}

/// Carrying out a walk-around.
class InspectionScreen extends StatefulWidget {
  const InspectionScreen({
    super.key,
    required this.vehicleId,
    required this.kind,
  });

  final String vehicleId;
  final InspectionKind kind;

  @override
  State<InspectionScreen> createState() => _InspectionScreenState();
}

class _InspectionScreenState extends State<InspectionScreen> {
  final Map<String, CheckResult> _results = {};
  final Map<String, String> _notes = {};
  final List<String> _photos = [];
  final Map<String, String> _itemPhotos = {};
  String _signature = '';

  /// When the walk-around began — the moment this screen opened, not the
  /// moment Save was tapped.
  final DateTime _startedAt = DateTime.now();
  final Map<String, DefectSeverity> _severities = {};

  /// What the previous walk-around left outstanding — shown at the top so
  /// somebody knows what to look at, and deliberately not pre-marked.
  late final List<String> _carriedOver =
      VehicleInspections.instance.outstandingDefects(widget.vehicleId);

  /// The list this walk-around is carried out against, read from the vehicle
  /// ONCE and then stamped onto the record, so retyping the vehicle later
  /// cannot re-point a filed inspection at a different list.
  late final InspectionSchedule _schedule =
      (VehicleInspections.instance.vehicleById(widget.vehicleId)?.type ??
              VehicleType.other)
          .schedule;

  final _odometer = TextEditingController();
  late final _driver = TextEditingController(
      text: VehicleInspections.instance.lastDriverFor(widget.vehicleId));
  final _coupled = TextEditingController();
  final _location = TextEditingController();
  final _remarks = TextEditingController();

  @override
  void dispose() {
    _odometer.dispose();
    _driver.dispose();
    _location.dispose();
    _coupled.dispose();
    _remarks.dispose();
    super.dispose();
  }

  CheckResult _resultFor(String id) => _results[id] ?? CheckResult.unchecked;

  void _set(String id, CheckResult r) {
    setState(() {
      // Tapping the answer already chosen takes it back to unchecked, so a
      // mis-tap can be undone without a fourth control — and, more
      // importantly, so "not checked" stays reachable rather than becoming
      // something you can only have by never touching the row.
      if (_resultFor(id) == r) {
        _results.remove(id);
      } else {
        _results[id] = r;
      }
      if (_resultFor(id) == CheckResult.defect) {
        // A defect starts MINOR rather than unstated: an unmarked severity
        // on a brake fault is the wrong direction to be silent in, and one
        // tap changes it.
        _severities.putIfAbsent(id, () => DefectSeverity.minor);
      } else {
        _notes.remove(id);
        _itemPhotos.remove(id);
        _severities.remove(id);
      }
    });
  }

  Future<void> _noteFor(String id) async {
    final controller = TextEditingController(text: _notes[id] ?? '');
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => Padding(
        padding: EdgeInsets.fromLTRB(
            16, 16, 16, MediaQuery.of(sheetContext).viewInsets.bottom + 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(checkItemName(id),
                style: const TextStyle(
                    fontSize: 17, fontWeight: FontWeight.w700)),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              maxLines: 3,
              decoration: const InputDecoration(
                  labelText: 'What is wrong with it?',
                  hintText: 'Nearside front tyre below tread'),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () => Navigator.of(sheetContext).pop(true),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    if (saved != true) return;
    setState(() {
      final text = controller.text.trim();
      if (text.isEmpty) {
        _notes.remove(id);
      } else {
        _notes[id] = text;
      }
    });
  }

  int get _photoCount => _photos.length + _itemPhotos.length;

  /// The picture OF a defect, filed against the item rather than thrown on
  /// the general pile — so the report can say which crack this is.
  Future<void> _photoFor(String itemId) async {
    final messenger = ScaffoldMessenger.of(context);
    if (_itemPhotos[itemId] == null &&
        _photoCount >= VehicleInspections.maxPhotos) {
      messenger.showSnackBar(const SnackBar(
          content: Text('${VehicleInspections.maxPhotos} photos is the most '
              'one inspection keeps.')));
      return;
    }
    try {
      final uri = await PhotoPrep.pickPhoto(
          maxBase64: VehicleInspections.photoBudget);
      if (uri == null) return;
      setState(() => _itemPhotos[itemId] = uri);
    } on FileRejected catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.reason)));
    }
  }

  /// Fills the location from where the phone is, as a TOWN rather than an
  /// address.
  ///
  /// [reverseGeocodeCity] reads only the admin-hierarchy tags, never a street
  /// or a shop — the same rule the weather screen follows. An inspection
  /// record is kept and shown to people, so "Mississauga, Ontario" is the
  /// useful answer and a pinpoint doorway is not. It is a suggestion either
  /// way: the field stays editable, and somebody in a yard will type the
  /// yard's name.
  Future<void> _useMyLocation() async {
    final messenger = ScaffoldMessenger.of(context);
    final at = await getCurrentLatLng();
    if (at == null) {
      messenger.showSnackBar(const SnackBar(
          content: Text('Location is off, or this device cannot answer.')));
      return;
    }
    final city = await reverseGeocodeCity(at.lat, at.lng);
    if (city == null || city.isEmpty) {
      messenger.showSnackBar(const SnackBar(
          content: Text('Could not name that place. Type it instead.')));
      return;
    }
    if (!mounted) return;
    setState(() => _location.text = city);
  }

  Future<void> _addPhoto() async {
    final messenger = ScaffoldMessenger.of(context);
    if (_photoCount >= VehicleInspections.maxPhotos) {
      messenger.showSnackBar(const SnackBar(
          content: Text('${VehicleInspections.maxPhotos} photos is the most '
              'one inspection keeps.')));
      return;
    }
    try {
      final uri = await PhotoPrep.pickPhoto(
          maxBase64: VehicleInspections.photoBudget);
      if (uri == null) return;
      setState(() => _photos.add(uri));
    } on FileRejected catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.reason)));
    }
  }

  void _save() {
    final store = VehicleInspections.instance;
    final now = DateTime.now();
    final why = Inspection(
      id: '',
      vehicleId: widget.vehicleId,
      kind: widget.kind,
      at: now,
      odometer: _odometer.text,
      location: _location.text,
    ).incomplete;
    if (why != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(why)));
      return;
    }
    store.saveInspection(Inspection(
      id: 'insp_${now.microsecondsSinceEpoch}',
      vehicleId: widget.vehicleId,
      kind: widget.kind,
      at: now,
      startedAt: _startedAt,
      odometer: _odometer.text.trim(),
      driver: _driver.text.trim(),
      location: _location.text.trim(),
      // Stamped from the store NOW and kept on the record afterwards: an
      // operator name changed next year must not rewrite what this says.
      operator: store.operatorName,
      coupledUnit: _coupled.text.trim(),
      results: Map.of(_results),
      notes: Map.of(_notes),
      photos: List.of(_photos),
      itemPhotos: Map.of(_itemPhotos),

      severities: Map.of(_severities),
      schedule: _schedule,
      signature: _signature,
      remarks: _remarks.text.trim(),
    ));
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final vehicle = VehicleInspections.instance.vehicleById(widget.vehicleId);
    final schedule = _schedule;
    final items = itemsFor(schedule);
    final defects = [
      for (final i in items)
        if (_resultFor(i.id) == CheckResult.defect) i.id
    ];
    final unchecked =
        items.where((i) => _resultFor(i.id) == CheckResult.unchecked).length;
    final majors = defects
        .where((id) => _severities[id] == DefectSeverity.major)
        .length;
    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.kind.label} · ${vehicle?.name ?? 'Vehicle'}'),
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          if (_carriedOver.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(AppRadius.md),
                  color: Colors.red.withValues(alpha: 0.10),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Still open from the last inspection',
                      style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: Colors.red.shade700),
                    ),
                    const SizedBox(height: 2),
                    Text(_carriedOver.map(checkItemName).join(', ')),
                    const SizedBox(height: 4),
                    Text(
                      // Named, never PRE-MARKED. Pre-flagging them would
                      // turn a walk-around into a form somebody confirms,
                      // which is the one thing an inspection must not be.
                      'Nothing is filled in for you — check them yourself.',
                      style: TextStyle(
                          fontSize: 12, color: AppColors.subtle(context)),
                    ),
                  ],
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Column(
              children: [
                TextField(
                  controller: _driver,
                  textCapitalization: TextCapitalization.words,
                  decoration:
                      const InputDecoration(labelText: 'Driver (optional)'),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _odometer,
                  // The keyboard is numeric, but the value is stored as
                  // TEXT and never parsed — a reading with a leading zero,
                  // a comma or a unit has to survive exactly as typed.
                  keyboardType: TextInputType.text,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    labelText: 'Odometer',
                    // Warned about, never refused: a reading that went
                    // backwards is usually a typo and occasionally a
                    // replaced instrument, and only the driver knows which.
                    helperText: odometerProblem(
                        VehicleInspections.instance.lastOdometerFor(
                            widget.vehicleId),
                        _odometer.text),
                    helperStyle: TextStyle(color: Colors.red.shade600),
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _location,
                  decoration: const InputDecoration(labelText: 'Location'),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _coupled,
                  textCapitalization: TextCapitalization.characters,
                  decoration: const InputDecoration(
                    labelText: 'Trailer or second unit (optional)',
                    // Says what it records and what it does not, where the
                    // choice is made rather than in a doc comment.
                    helperText: 'Records what was attached. A trailer needs '
                        'its own walk-around.',
                    helperMaxLines: 2,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          'The odometer and the location are required.',
                          style: TextStyle(
                              fontSize: 12, color: AppColors.subtle(context)),
                        ),
                      ),
                      TextButton.icon(
                        onPressed: _useMyLocation,
                        icon: const Icon(Icons.my_location, size: 18),
                        label: const Text('Use my location'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          for (final section in schedule.checklist) ...[
            _Heading(section.title.toUpperCase()),
            InfoSection(children: [
              for (final item in section.items)
                _CheckRow(
                  item: item,
                  result: _resultFor(item.id),
                  note: _notes[item.id] ?? '',
                  photo: _itemPhotos[item.id] ?? '',
                  severity: _severities[item.id],
                  onSeverity: (v) =>
                      setState(() => _severities[item.id] = v),
                  onPick: (r) => _set(item.id, r),
                  onNote: () => _noteFor(item.id),
                  onPhoto: () => _photoFor(item.id),
                ),
            ]),
          ],
          const _Heading('PHOTOS'),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (_photos.isNotEmpty)
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (var i = 0; i < _photos.length; i++)
                        Stack(
                          children: [
                            ClipRRect(
                              borderRadius:
                                  BorderRadius.circular(AppRadius.sm),
                              child: Image.memory(
                                _photoBytes(_photos[i]),
                                width: 92,
                                height: 92,
                                fit: BoxFit.cover,
                              ),
                            ),
                            Positioned(
                              right: 0,
                              top: 0,
                              child: IconButton(
                                icon: const Icon(Icons.cancel, size: 20),
                                tooltip: 'Remove photo',
                                onPressed: () =>
                                    setState(() => _photos.removeAt(i)),
                              ),
                            ),
                          ],
                        ),
                    ],
                  ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: _addPhoto,
                  icon: const Icon(Icons.add_a_photo_outlined),
                  label: const Text('Add a photo'),
                ),
              ],
            ),
          ),
          const _Heading('REMARKS'),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
            child: TextField(
              controller: _remarks,
              maxLines: 3,
              decoration: const InputDecoration(
                  hintText: 'Anything else worth recording'),
            ),
          ),
          const _Heading('SIGNED BY THE DRIVER'),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
            child: SignaturePad(
              value: _signature,
              onChanged: (v) => _signature = v,
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 20, 16, 6),
            child: Text(
              defects.isEmpty
                  ? 'No defects recorded'
                  : '${defects.length} '
                      '${defects.length == 1 ? 'defect' : 'defects'} recorded'
                      '${majors == 0 ? '' : ' · $majors major'}',
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
          if (unchecked > 0)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
              child: Text(
                // Saved anyway, and said plainly. Refusing to file a partial
                // walk-around would only mean the record of what WAS looked
                // at is lost too.
                '$unchecked ${unchecked == 1 ? 'item is' : 'items are'} not '
                'checked. The record will say so.',
                style:
                    TextStyle(fontSize: 12.5, color: AppColors.subtle(context)),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
            child: FilledButton(
              onPressed: _save,
              child: const Text('Save inspection'),
            ),
          ),
        ],
      ),
    );
  }

}

/// The bytes behind a prepared `data:` URI. Empty on anything malformed —
/// a photo that will not decode must not take the record's screen down.
Uint8List _photoBytes(String dataUri) {
  final comma = dataUri.indexOf(',');
  if (comma < 0) return Uint8List(0);
  try {
    return base64Decode(dataUri.substring(comma + 1));
  } catch (_) {
    return Uint8List(0);
  }
}

class _CheckRow extends StatelessWidget {
  const _CheckRow({
    required this.item,
    required this.result,
    required this.note,
    required this.photo,
    required this.severity,
    required this.onSeverity,
    required this.onPick,
    required this.onNote,
    required this.onPhoto,
  });

  final CheckItem item;
  final CheckResult result;
  final String note;
  final String photo;
  final DefectSeverity? severity;
  final ValueChanged<DefectSeverity> onSeverity;
  final ValueChanged<CheckResult> onPick;
  final VoidCallback onNote;
  final VoidCallback onPhoto;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(item.name, style: const TextStyle(fontSize: 15)),
              ),
              for (final r in const [
                CheckResult.ok,
                CheckResult.defect,
                CheckResult.na
              ])
                _Pip(
                  label: r == CheckResult.ok
                      ? 'OK'
                      : r == CheckResult.defect
                          ? 'Defect'
                          : 'N/A',
                  selected: result == r,
                  danger: r == CheckResult.defect,
                  onTap: () => onPick(r),
                ),
            ],
          ),
          if (result == CheckResult.defect) ...[
            Row(
              children: [
                for (final v in DefectSeverity.values)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: _Pip(
                      label: v.label,
                      selected: severity == v,
                      danger: v == DefectSeverity.major,
                      onTap: () => onSeverity(v),
                    ),
                  ),
                Expanded(
                  child: Text(
                    (severity ?? DefectSeverity.minor).consequence,
                    style: TextStyle(
                        fontSize: 11, color: AppColors.subtle(context)),
                  ),
                ),
              ],
            ),
            Row(
              children: [
                Flexible(
                  child: TextButton.icon(
                    onPressed: onNote,
                    icon: const Icon(Icons.edit_note, size: 18),
                    label: Text(note.isEmpty ? 'Add a note' : note,
                        overflow: TextOverflow.ellipsis),
                  ),
                ),
                if (photo.isEmpty)
                  TextButton.icon(
                    onPressed: onPhoto,
                    icon: const Icon(Icons.add_a_photo_outlined, size: 18),
                    label: const Text('Photo'),
                  )
                else
                  GestureDetector(
                    onTap: onPhoto,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(AppRadius.sm),
                      child: Image.memory(_photoBytes(photo),
                          width: 34, height: 34, fit: BoxFit.cover),
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _Pip extends StatelessWidget {
  const _Pip({
    required this.label,
    required this.selected,
    required this.onTap,
    this.danger = false,
  });

  final String label;
  final bool selected;
  final bool danger;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final accent =
        danger ? Colors.red.shade600 : AppColors.accentOn(context);
    // The label takes the PIP's own background once it is filled, never the
    // app accent — the rule "a bubble's contents take the bubble's colours",
    // which this codebase has now paid for four times.
    final fg = selected
        ? (danger ? Colors.white : AppColors.onAccent(context))
        : AppColors.subtle(context);
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Material(
        color: selected ? accent : Colors.transparent,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(AppRadius.sm),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppRadius.sm),
              border: Border.all(
                  color: selected
                      ? Colors.transparent
                      : AppColors.subtle(context).withValues(alpha: 0.4)),
            ),
            child: Text(label,
                style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: fg)),
          ),
        ),
      ),
    );
  }
}

/// A filed inspection, read only — and the one place it can be exported.
class InspectionRecordScreen extends StatelessWidget {
  const InspectionRecordScreen({super.key, required this.inspectionId});

  final String inspectionId;

  /// Public and static so the roadside view shares it rather than carrying
  /// a second copy of the same three lines.
  ///
  /// Two formats, and the choice is real rather than decorative: the PDF is
  /// what gets printed, filed and handed over, and the HTML is what opens in
  /// any browser with the photos already inside it. Both go to the share
  /// sheet, which is where "Save to Files" lives — no new plugin, and
  /// nothing uploaded anywhere.
  static Future<void> export(
      BuildContext context, Vehicle vehicle, Inspection i) async {
    final messenger = ScaffoldMessenger.of(context);
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.picture_as_pdf_outlined),
              title: const Text('PDF'),
              subtitle: const Text('Print it, file it, or save it to Files'),
              onTap: () => Navigator.of(sheetContext).pop('pdf'),
            ),
            ListTile(
              leading: const Icon(Icons.code),
              title: const Text('Web page'),
              subtitle: const Text('Opens in any browser, photos included'),
              onTap: () => Navigator.of(sheetContext).pop('html'),
            ),
          ],
        ),
      ),
    );
    if (choice == null) return;
    String? result;
    try {
      if (choice == 'pdf') {
        result = await exportBackupFile(
            InspectionReport.fileName(vehicle, i, extension: 'pdf'),
            await InspectionPdf.build(vehicle, i));
      } else {
        result = await exportBackupFile(
            InspectionReport.fileName(vehicle, i),
            Uint8List.fromList(utf8.encode(InspectionReport.html(vehicle, i))));
      }
    } catch (_) {
      result = null;
    }
    messenger.showSnackBar(SnackBar(
        content: Text(result ?? 'Could not export the report.')));
  }

  static String? _recordSubtitle(Inspection i, String itemId) {
    final note = (i.notes[itemId] ?? '').trim();
    final fix = i.fixes[itemId];
    if (fix == null) return note.isEmpty ? null : note;
    final signed = [
      'Fixed ${InspectionReport.stamp(fix.at)}',
      if (fix.by.trim().isNotEmpty) 'by ${fix.by.trim()}',
    ].join(' ');
    return note.isEmpty
        ? signed
        : '$note\n$signed${fix.note.trim().isEmpty ? '' : ' — ${fix.note.trim()}'}';
  }

  /// Signs a defect off as put right, or takes the sign-off back off.
  static Future<void> signOff(
      BuildContext context, Inspection i, String itemId) async {
    final store = VehicleInspections.instance;
    final existing = i.fixes[itemId];
    final by = TextEditingController(text: existing?.by ?? i.driver);
    final note = TextEditingController(text: existing?.note ?? '');
    final action = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => Padding(
        padding: EdgeInsets.fromLTRB(
            16, 16, 16, MediaQuery.of(sheetContext).viewInsets.bottom + 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(checkItemName(itemId),
                style:
                    const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            const Text(
              // Said before the button, not after: this writes onto a record
              // somebody already signed.
              'This is added to the inspection that found it. What was found '
              'and what was signed do not change.',
              style: TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: by,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Fixed by'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: note,
              maxLines: 2,
              decoration: const InputDecoration(
                  labelText: 'What was done',
                  hintText: 'Replaced the hose'),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () => Navigator.of(sheetContext).pop('fix'),
              child: Text(existing == null ? 'Mark fixed' : 'Update'),
            ),
            if (existing != null)
              TextButton(
                onPressed: () => Navigator.of(sheetContext).pop('clear'),
                child: const Text('Not fixed after all'),
              ),
          ],
        ),
      ),
    );
    if (action == null) return;
    store.markFixed(
      i.id,
      itemId,
      action == 'clear'
          ? null
          : DefectFix(
              at: existing?.at ?? DateTime.now(),
              by: by.text.trim(),
              note: note.text.trim()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final store = VehicleInspections.instance;
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final i = store.inspectionById(inspectionId);
        final vehicle = i == null ? null : store.vehicleById(i.vehicleId);
        if (i == null || vehicle == null) {
          return Scaffold(
            appBar: AppBar(),
            body: const Center(child: Text('This record was removed.')),
          );
        }
        return Scaffold(
          appBar: AppBar(
            title: Text(i.kind.label),
            actions: [
              IconButton(
                icon: const Icon(Icons.co_present_outlined),
                tooltip: 'Show this record',
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) =>
                        InspectionShowScreen(inspectionId: i.id))),
              ),
              IconButton(
                icon: const Icon(Icons.ios_share),
                tooltip: 'Export report',
                onPressed: () => export(context, vehicle, i),
              ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.only(bottom: 28, top: 4),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(28, 8, 28, 0),
                child: Text(
                  '${vehicle.name} · ${InspectionReport.stamp(i.at)}\n'
                  '${i.summary}',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              for (final section in i.schedule.checklist) ...[
                _Heading(section.title.toUpperCase()),
                InfoSection(children: [
                  for (final item in section.items)
                    InfoTile(
                      leading: i.itemPhotos[item.id] == null
                          ? null
                          : GestureDetector(
                              onTap: () => Navigator.of(context).push(
                                  MaterialPageRoute(
                                      builder: (_) => InspectionPhotoScreen(
                                          dataUri: i.itemPhotos[item.id]!,
                                          caption: item.name))),
                              child: ClipRRect(
                                borderRadius:
                                    BorderRadius.circular(AppRadius.sm),
                                child: Image.memory(
                                    _photoBytes(i.itemPhotos[item.id]!),
                                    width: 40,
                                    height: 40,
                                    fit: BoxFit.cover),
                              ),
                            ),
                      title: item.name,
                      subtitle: _recordSubtitle(i, item.id),
                      // Only a defect can be signed off, so only a defect is
                      // tappable — a row that opens a sheet saying "nothing
                      // is wrong with this" would be a control with no job.
                      onTap: i.resultFor(item.id) == CheckResult.defect
                          ? () => signOff(context, i, item.id)
                          : null,
                      trailing: Text(
                        i.resultFor(item.id) == CheckResult.defect &&
                                i.severityFor(item.id) != null
                            ? '${i.severityFor(item.id)!.label} defect'
                            : i.resultFor(item.id).label,
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: i.resultFor(item.id) == CheckResult.defect
                              ? Colors.red.shade600
                              : AppColors.subtle(context),
                        ),
                      ),
                    ),
                ]),
              ],
              if (i.remarks.trim().isNotEmpty) ...[
                const _Heading('REMARKS'),
                Padding(
                  padding: const EdgeInsets.fromLTRB(28, 0, 28, 0),
                  child: Text(i.remarks.trim()),
                ),
              ],
              if (i.photos.isNotEmpty) ...[
                const _Heading('PHOTOS'),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final p in i.photos)
                        GestureDetector(
                          onTap: () => Navigator.of(context).push(
                              MaterialPageRoute(
                                  builder: (_) =>
                                      InspectionPhotoScreen(dataUri: p))),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(AppRadius.sm),
                            child: Image.memory(_photoBytes(p),
                                width: 92, height: 92, fit: BoxFit.cover),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
              if (!SignatureInk.decode(i.signature).isEmpty) ...[
                const _Heading('SIGNED BY THE DRIVER'),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
                  child: SizedBox(
                    height: 110,
                    child: CustomPaint(
                      painter: SignaturePainter(
                          ink: SignatureInk.decode(i.signature),
                          colour: AppColors.accentOn(context)),
                      child: const SizedBox.expand(),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(28, 4, 28, 0),
                  child: Text('A drawn mark, not proof of who drew it.',
                      style: TextStyle(
                          fontSize: 12, color: AppColors.subtle(context))),
                ),
              ],
              Padding(
                padding: const EdgeInsets.fromLTRB(28, 22, 28, 0),
                child: Text(InspectionReport.disclaimer,
                    style: TextStyle(
                        fontSize: 12, color: AppColors.subtle(context))),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// The record, held up for somebody to read.
///
/// This is the screen for the moment the tool exists for: an officer at the
/// roadside asking to see the walk-around. So it is built for being READ BY
/// SOMEBODY ELSE, at arm's length, in bad light, on a phone that may have no
/// signal — big type, the facts first, no navigation to get lost in, and
/// nothing on it that has to be fetched.
///
/// **It states facts and makes no ruling.** When the inspection was done and
/// how long ago, who signed it and what they declared, and every defect they
/// listed. Whether that satisfies any particular jurisdiction's rule is a
/// question this app cannot answer and does not pretend to — the disclaimer
/// stays on the screen for exactly that reason.
class InspectionShowScreen extends StatelessWidget {
  const InspectionShowScreen({super.key, required this.inspectionId, this.now});

  final String inspectionId;

  /// Injectable so a test does not have to move the clock.
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    final store = VehicleInspections.instance;
    final i = store.inspectionById(inspectionId);
    final vehicle = i == null ? null : store.vehicleById(i.vehicleId);
    if (i == null || vehicle == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: Text('This record was removed.')),
      );
    }
    final at = now ?? DateTime.now();
    final subtle = AppColors.subtle(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Inspection record'),
        actions: [
          IconButton(
            icon: const Icon(Icons.ios_share),
            tooltip: 'Export report',
            onPressed: () =>
                InspectionRecordScreen.export(context, vehicle, i),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
        children: [
          Text('${i.kind.label} inspection',
              style: const TextStyle(
                  fontSize: 26, fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          Text('${InspectionReport.stamp(i.at)}  ·  '
              '${InspectionReport.age(i.at, at)}',
              style: TextStyle(fontSize: 16, color: subtle)),
          const SizedBox(height: 20),
          _Fact('Vehicle', vehicle.name),
          if (vehicle.plate.trim().isNotEmpty)
            _Fact('Plate', vehicle.plate.trim()),
          if (i.operator.trim().isNotEmpty) _Fact('Operator', i.operator.trim()),
          if (i.coupledUnit.trim().isNotEmpty)
            _Fact('Pulling', i.coupledUnit.trim()),
          if (i.driver.trim().isNotEmpty) _Fact('Driver', i.driver.trim()),
          if (i.odometer.trim().isNotEmpty)
            _Fact('Odometer', i.odometer.trim()),
          if (i.location.trim().isNotEmpty)
            _Fact('Location', i.location.trim()),
          const SizedBox(height: 18),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppRadius.md),
              color: (i.defectCount > 0 ? Colors.red : Colors.green)
                  .withValues(alpha: 0.10),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  i.defectCount == 0
                      ? 'No defects recorded'
                      : '${i.defectCount} '
                          '${i.defectCount == 1 ? 'defect' : 'defects'} '
                          'recorded',
                  style: const TextStyle(
                      fontSize: 19, fontWeight: FontWeight.w800),
                ),
                if (i.openMajorDefects.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  // The sharpest thing this record can say, so it says it
                  // first — and it quotes the rule rather than ruling.
                  Text(
                    '${i.openMajorDefects.length} major, outstanding. '
                    '${DefectSeverity.major.consequence}',
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w700),
                  ),
                ],
                if (i.fixedCount > 0) ...[
                  const SizedBox(height: 4),
                  Text(
                    i.openDefects.isEmpty
                        ? 'All signed off as fixed'
                        : '${i.fixedCount} signed off, '
                            '${i.openDefects.length} still outstanding',
                    style: const TextStyle(fontSize: 15),
                  ),
                ],
                if (i.uncheckedCount > 0) ...[
                  const SizedBox(height: 4),
                  // Never hidden on this of all screens: the one place
                  // somebody might be tempted to leave it off is the one
                  // place leaving it off would be a lie by omission.
                  Text(
                    '${i.uncheckedCount} of ${itemsFor(i.schedule).length} '
                    'items were not checked',
                    style: const TextStyle(fontSize: 15),
                  ),
                ],
              ],
            ),
          ),
          if (i.defects.isNotEmpty) ...[
            const SizedBox(height: 18),
            Text('DEFECTS',
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.6,
                    color: subtle)),
            const SizedBox(height: 6),
            for (final id in i.defects)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (i.itemPhotos[id] != null) ...[
                      GestureDetector(
                        onTap: () => Navigator.of(context).push(
                            MaterialPageRoute(
                                builder: (_) => InspectionPhotoScreen(
                                    dataUri: i.itemPhotos[id]!,
                                    caption: checkItemName(id)))),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(AppRadius.sm),
                          child: Image.memory(_photoBytes(i.itemPhotos[id]!),
                              width: 54, height: 54, fit: BoxFit.cover),
                        ),
                      ),
                      const SizedBox(width: 10),
                    ],
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                              '${i.severityFor(id) == null ? '' : '${i.severityFor(id)!.label} · '}'
                              '${checkItemName(id)}',
                              style: TextStyle(
                                  fontSize: 17,
                                  fontWeight: FontWeight.w600,
                                  // Struck through once signed off: the
                                  // defect is still ON the record — it was
                                  // really found — and the line says it was
                                  // dealt with rather than hiding it.
                                  decoration: i.fixes[id] == null
                                      ? null
                                      : TextDecoration.lineThrough)),
                          if ((i.notes[id] ?? '').trim().isNotEmpty)
                            Text(i.notes[id]!.trim(),
                                style: TextStyle(fontSize: 15, color: subtle)),
                          if (i.fixes[id] case final fix?)
                            Text(
                              [
                                'Fixed ${InspectionReport.stamp(fix.at)}',
                                if (fix.by.trim().isNotEmpty)
                                  'by ${fix.by.trim()}',
                                if (fix.note.trim().isNotEmpty)
                                  '— ${fix.note.trim()}',
                              ].join(' '),
                              style: TextStyle(fontSize: 14, color: subtle),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
          ],
          if (i.remarks.trim().isNotEmpty) ...[
            const SizedBox(height: 14),
            Text('REMARKS',
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.6,
                    color: subtle)),
            const SizedBox(height: 4),
            Text(i.remarks.trim(), style: const TextStyle(fontSize: 16)),
          ],
          const SizedBox(height: 20),
          Text(i.declaration,
              style: const TextStyle(fontSize: 16, height: 1.4)),
          if (!SignatureInk.decode(i.signature).isEmpty) ...[
            const SizedBox(height: 6),
            SizedBox(
              height: 100,
              child: CustomPaint(
                painter: SignaturePainter(
                    ink: SignatureInk.decode(i.signature),
                    colour: AppColors.accentOn(context)),
                child: const SizedBox.expand(),
              ),
            ),
            Text('A drawn mark, not proof of who drew it.',
                style: TextStyle(fontSize: 12, color: subtle)),
          ] else ...[
            const SizedBox(height: 6),
            Text('Not signed.',
                style: TextStyle(fontSize: 15, color: subtle)),
          ],
          const SizedBox(height: 24),
          Text(
            '${InspectionReport.noteFor(i)}\n\n'
            '${InspectionReport.disclaimer}',
            style: TextStyle(fontSize: 12, color: subtle),
          ),
          const SizedBox(height: 12),
          // A full list of every item, for anybody who wants to read past the
          // summary. Under the headline rather than above it: the person
          // being shown this is looking for the defects and the date, not
          // forty rows of OK.
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: const Text('Every item'),
            children: [
              for (final section in i.schedule.checklist)
                for (final item in section.items)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(
                      children: [
                        Expanded(child: Text(item.name)),
                        Text(i.resultFor(item.id).label,
                            style: TextStyle(
                                fontWeight: FontWeight.w600,
                                color: i.resultFor(item.id) ==
                                        CheckResult.defect
                                    ? Colors.red.shade600
                                    : subtle)),
                      ],
                    ),
                  ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Fact extends StatelessWidget {
  const _Fact(this.label, this.value);
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 96,
              child: Text(label,
                  style: TextStyle(
                      fontSize: 15, color: AppColors.subtle(context))),
            ),
            Expanded(
              child: Text(value,
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w600)),
            ),
          ],
        ),
      );
}

/// One inspection photo, big.
///
/// Its own small screen rather than the chat viewer: `ImageViewScreen` takes
/// a [Message], and fabricating one for a defect photo would mean carrying a
/// chat's like/react/forward machinery into a maintenance record where none
/// of it means anything.
///
/// Saving is offered because a defect photo is EVIDENCE, and unlike a chat
/// photo there is no view-once or forward-protection question to ask: it is
/// the user's own picture of their own vehicle.
class InspectionPhotoScreen extends StatelessWidget {
  const InspectionPhotoScreen({
    super.key,
    required this.dataUri,
    this.caption = '',
  });

  final String dataUri;
  final String caption;

  Future<void> _save(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final bytes = _photoBytes(dataUri);
    if (bytes.isEmpty) return;
    final r = await MediaSaver.saveImage(bytes, name: 'inspection');
    messenger.showSnackBar(
        SnackBar(content: Text(MediaSaver.message(r, video: false))));
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _photoBytes(dataUri);
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(caption, style: const TextStyle(fontSize: 15)),
        actions: [
          IconButton(
            icon: const Icon(Icons.save_alt),
            tooltip: 'Save to Photos',
            onPressed: bytes.isEmpty ? null : () => _save(context),
          ),
        ],
      ),
      body: Center(
        child: bytes.isEmpty
            ? const Text('This photo could not be read.',
                style: TextStyle(color: Colors.white70))
            : InteractiveViewer(
                minScale: 1,
                maxScale: 5,
                child: Image.memory(bytes, fit: BoxFit.contain),
              ),
      ),
    );
  }
}
