import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../models/inspection.dart';
import '../models/signature_ink.dart';
import '../state/vehicle_inspections.dart';
import '../theme/app_theme.dart';
import '../util/backup_export.dart';
import '../util/file_moderation.dart';
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
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () => Navigator.of(sheetContext).pop(true),
              child: Text(existing == null ? 'Add vehicle' : 'Save'),
            ),
          ],
        ),
      ),
    );
    if (saved != true) return;
    if (name.text.trim().isEmpty) return;
    final id = store.saveVehicle(
        id: existing?.id,
        name: name.text,
        plate: plate.text,
        notes: notes.text);
    if (id.isEmpty && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text(
              'That is as many vehicles as this device keeps '
              '(${VehicleInspections.maxVehicles}).')));
    }
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
              for (final v in vehicles)
                InfoSection(children: [
                  InfoTile(
                    leading: const Icon(Icons.local_shipping_outlined),
                    title: v.name,
                    subtitle: _vehicleSubtitle(store, v),
                    trailing: const Icon(Icons.chevron_right),
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
              if (vehicles.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Wrap(
                    spacing: 8,
                    children: [
                      for (final v in vehicles)
                        TextButton.icon(
                          onPressed: () => _delete(context, v),
                          icon: const Icon(Icons.delete_outline, size: 18),
                          label: Text('Remove ${v.name}'),
                        ),
                    ],
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
    final plate = v.subtitle;
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
class VehicleScreen extends StatelessWidget {
  const VehicleScreen({super.key, required this.vehicleId});

  final String vehicleId;

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
              if (outstanding.isNotEmpty) ...[
                const _Heading('DEFECTS ON THE LAST INSPECTION'),
                InfoSection(children: [
                  for (final id in outstanding)
                    InfoTile(
                      leading: Icon(Icons.report_problem_outlined,
                          color: Colors.red.shade600),
                      title: checkItemName(id),
                      subtitle: (records.first.notes[id] ?? '').trim().isEmpty
                          ? null
                          : records.first.notes[id]!.trim(),
                    ),
                ]),
                Padding(
                  padding: const EdgeInsets.fromLTRB(28, 2, 28, 8),
                  child: Text(
                    // Said rather than implied: this list is the last
                    // inspection's defects, not a repair tracker. Carrying a
                    // defect forward would claim to know it was never fixed.
                    'What the most recent inspection found. Record a new '
                    'inspection once the work is done.',
                    style: TextStyle(
                        fontSize: 12, color: AppColors.subtle(context)),
                  ),
                ),
              ],
              const _Heading('HISTORY'),
              if (records.isEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(28, 8, 28, 8),
                  child: Text('Nothing recorded yet.',
                      style: TextStyle(color: AppColors.subtle(context))),
                ),
              for (final r in records)
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
    this.existing,
  });

  final String vehicleId;
  final InspectionKind kind;
  final Inspection? existing;

  @override
  State<InspectionScreen> createState() => _InspectionScreenState();
}

class _InspectionScreenState extends State<InspectionScreen> {
  late final Map<String, CheckResult> _results = {
    ...?widget.existing?.results,
  };
  late final Map<String, String> _notes = {...?widget.existing?.notes};
  late final List<String> _photos = [...?widget.existing?.photos];
  late String _signature = widget.existing?.signature ?? '';

  late final _odometer =
      TextEditingController(text: widget.existing?.odometer ?? '');
  late final _driver =
      TextEditingController(text: widget.existing?.driver ?? '');
  late final _location =
      TextEditingController(text: widget.existing?.location ?? '');
  late final _remarks =
      TextEditingController(text: widget.existing?.remarks ?? '');

  @override
  void dispose() {
    _odometer.dispose();
    _driver.dispose();
    _location.dispose();
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
      if (_resultFor(id) != CheckResult.defect) _notes.remove(id);
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

  Future<void> _addPhoto() async {
    final messenger = ScaffoldMessenger.of(context);
    if (_photos.length >= VehicleInspections.maxPhotos) {
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
    store.saveInspection(Inspection(
      id: widget.existing?.id ?? 'insp_${now.microsecondsSinceEpoch}',
      vehicleId: widget.vehicleId,
      kind: widget.kind,
      at: widget.existing?.at ?? now,
      odometer: _odometer.text.trim(),
      driver: _driver.text.trim(),
      location: _location.text.trim(),
      results: Map.of(_results),
      notes: Map.of(_notes),
      photos: List.of(_photos),
      signature: _signature,
      remarks: _remarks.text.trim(),
    ));
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final vehicle = VehicleInspections.instance.vehicleById(widget.vehicleId);
    final defects = [
      for (final i in allCheckItems)
        if (_resultFor(i.id) == CheckResult.defect) i.id
    ];
    final unchecked = allCheckItems
        .where((i) => _resultFor(i.id) == CheckResult.unchecked)
        .length;
    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.kind.label} · ${vehicle?.name ?? 'Vehicle'}'),
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
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
                  decoration:
                      const InputDecoration(labelText: 'Odometer (optional)'),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _location,
                  decoration:
                      const InputDecoration(labelText: 'Location (optional)'),
                ),
              ],
            ),
          ),
          for (final section in kInspectionChecklist) ...[
            _Heading(section.title.toUpperCase()),
            InfoSection(children: [
              for (final item in section.items)
                _CheckRow(
                  item: item,
                  result: _resultFor(item.id),
                  note: _notes[item.id] ?? '',
                  onPick: (r) => _set(item.id, r),
                  onNote: () => _noteFor(item.id),
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
                      '${defects.length == 1 ? 'defect' : 'defects'} recorded',
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
    required this.onPick,
    required this.onNote,
  });

  final CheckItem item;
  final CheckResult result;
  final String note;
  final ValueChanged<CheckResult> onPick;
  final VoidCallback onNote;

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
          if (result == CheckResult.defect)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: onNote,
                icon: const Icon(Icons.edit_note, size: 18),
                label: Text(note.isEmpty ? 'Add a note' : note),
              ),
            ),
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

  Future<void> _export(
      BuildContext context, Vehicle vehicle, Inspection i) async {
    final messenger = ScaffoldMessenger.of(context);
    final bytes = Uint8List.fromList(
        utf8.encode(InspectionReport.html(vehicle, i)));
    final result = await exportBackupFile(
        InspectionReport.fileName(vehicle, i), bytes);
    messenger.showSnackBar(SnackBar(
        content: Text(result ?? 'Could not export the report.')));
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
                icon: const Icon(Icons.ios_share),
                tooltip: 'Export report',
                onPressed: () => _export(context, vehicle, i),
              ),
              IconButton(
                icon: const Icon(Icons.edit_outlined),
                tooltip: 'Edit',
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => InspectionScreen(
                        vehicleId: i.vehicleId,
                        kind: i.kind,
                        existing: i))),
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
              for (final section in kInspectionChecklist) ...[
                _Heading(section.title.toUpperCase()),
                InfoSection(children: [
                  for (final item in section.items)
                    InfoTile(
                      title: item.name,
                      subtitle: (i.notes[item.id] ?? '').trim().isEmpty
                          ? null
                          : i.notes[item.id]!.trim(),
                      trailing: Text(
                        i.resultFor(item.id).label,
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
                        ClipRRect(
                          borderRadius: BorderRadius.circular(AppRadius.sm),
                          child: Image.memory(
                              _photoBytes(p),
                              width: 92,
                              height: 92,
                              fit: BoxFit.cover),
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
