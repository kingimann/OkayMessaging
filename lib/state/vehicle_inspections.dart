import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/inspection.dart';
import '../util/inspection_backup.dart';
import 'push_service.dart';

/// The vehicles this account inspects and the records it has kept.
///
/// **On the device and nowhere else** — no table, no column, no backup blob,
/// and a test holds it there. An inspection names a driver, a plate, a time
/// and a place, which together is a record of where somebody was and what
/// they were driving; there is nothing a server could do with that which
/// this device cannot do alone, and plenty it should not.
///
/// **It is a tool, not a compliance system, and every surface says so.** It
/// does not track hours of service, it is not an electronic logging device,
/// and it does not certify a vehicle as fit to drive. What it does is keep
/// the walk-around somebody actually did, with the defects they found, and
/// hand it back as a report they can send on.
///
/// Account-scoped, wired into `account_wipe.dart` like [SavedForms].
class VehicleInspections extends ChangeNotifier {
  VehicleInspections._();
  static final VehicleInspections instance = VehicleInspections._();

  static const _vehiclesKey = 'vehicles_v1';
  static const _inspectionsKey = 'vehicle_inspections_v1';
  static const _operatorKey = 'vehicle_inspection_operator_v1';
  static const _reminderKey = 'vehicle_inspection_reminder_v1';

  /// Bounds, and the reason each is where it is.
  ///
  /// Everything here lives in one SharedPreferences string, so a record that
  /// carried a dozen full-size photos would grow that blob without limit.
  /// Four photos is enough to show a defect from two angles twice over, and
  /// [maxInspections] is high enough that a daily check runs for months.
  /// **The oldest record is dropped at the cap**, which is why every screen
  /// that shows one offers Export: this is a working log, not an archive.
  static const int maxVehicles = 40;
  static const int maxInspections = 200;
  static const int maxPhotos = 4;

  /// A defect photo has to be readable — a cracked hose at thumbnail size
  /// records nothing — but it is not going on a wire, so it does not need
  /// the chat budget either.
  static const int photoBudget = 90000;

  final List<Vehicle> _vehicles = [];
  final List<Inspection> _inspections = [];
  SharedPreferences? _prefs;
  String _operatorName = '';
  int? _reminderMinutes;

  /// How many days of reminders are queued at once.
  ///
  /// [PushService.localNotifyAt] schedules ONE notification at a fixed
  /// instant — the channel takes seconds, not a repeat rule — so a daily
  /// reminder is a short queue that every launch re-arms. Seven means a week
  /// of not opening the app still gets a nudge, and it is nowhere near iOS's
  /// 64-pending cap. **If the app is never opened again the chain does run
  /// out**, which is stated rather than hidden: a reminder to open the app
  /// that depends on the app being opened is honest about its own limit.
  static const int reminderDays = 7;

  /// When the daily reminder fires, as minutes since midnight — null when it
  /// is off, which is the default.
  int? get reminderMinutes => _reminderMinutes;

  Future<void> setReminder(int? minutesSinceMidnight, {DateTime? now}) async {
    _reminderMinutes = minutesSinceMidnight;
    notifyListeners();
    final prefs = _prefs ??= await SharedPreferences.getInstance();
    if (minutesSinceMidnight == null) {
      await prefs.remove(_reminderKey);
    } else {
      await prefs.setInt(_reminderKey, minutesSinceMidnight);
    }
    await scheduleReminders(now: now);
  }

  /// Re-arms the queue: cancels what was pending and books the next
  /// [reminderDays] occurrences. Safe to call on every launch — the ids are
  /// fixed, so a request replaces its predecessor rather than stacking.
  Future<void> scheduleReminders({DateTime? now}) async {
    final push = PushService.instance;
    for (var d = 0; d < reminderDays; d++) {
      await push.cancelLocalNotify('inspection_reminder_$d');
    }
    final minutes = _reminderMinutes;
    if (minutes == null) return;
    final at = now ?? DateTime.now();
    var first = DateTime(at.year, at.month, at.day, minutes ~/ 60, minutes % 60);
    if (!first.isAfter(at)) first = first.add(const Duration(days: 1));
    for (var d = 0; d < reminderDays; d++) {
      await push.localNotifyAt(
        id: 'inspection_reminder_$d',
        title: 'Daily inspection',
        // Neutral on purpose: this is booked days ahead, so it cannot know
        // whether the walk-around has since been done, and a notification
        // that asserts something untrue is worse than one that asks.
        body: 'Time for the walk-around.',
        at: first.add(Duration(days: d)),
      );
    }
  }

  /// The carrier or operator every new record is filed under — typed once
  /// rather than on every walk-around, because it is the one field that is
  /// the same every single time and the one somebody is asked for by
  /// name when they are showing the record to anybody.
  String get operatorName => _operatorName;

  Future<void> setOperatorName(String value) async {
    _operatorName = value.trim();
    notifyListeners();
    final prefs = _prefs ??= await SharedPreferences.getInstance();
    await prefs.setString(_operatorKey, _operatorName);
  }

  List<Vehicle> get vehicles => List.unmodifiable(_vehicles);

  /// Newest first, which is the only order a log is ever read in.
  List<Inspection> get inspections => List.unmodifiable(_inspections);

  Vehicle? vehicleById(String id) {
    for (final v in _vehicles) {
      if (v.id == id) return v;
    }
    return null;
  }

  Inspection? inspectionById(String id) {
    for (final i in _inspections) {
      if (i.id == id) return i;
    }
    return null;
  }

  List<Inspection> forVehicle(String vehicleId) =>
      [for (final i in _inspections) if (i.vehicleId == vehicleId) i];

  Inspection? lastFor(String vehicleId) {
    for (final i in _inspections) {
      if (i.vehicleId == vehicleId) return i;
    }
    return null;
  }

  /// Every defect still on the books for a vehicle: the ones recorded on its
  /// most recent inspection that nobody has signed off.
  ///
  /// Older inspections are deliberately not carried forward — a defect that
  /// was there last week and is not there today was either fixed or missed,
  /// and nothing here can tell which, so claiming it is still outstanding
  /// would be inventing a fact. What CAN be known is what somebody said they
  /// put right, which is what [markFixed] records and what this now honours.
  List<String> outstandingDefects(String vehicleId) =>
      lastFor(vehicleId)?.openDefects ?? const [];

  /// Every vehicle with something still outstanding, worst first. The whole
  /// yard on one screen, which is the question somebody with more than one
  /// vehicle actually has.
  List<(Vehicle, List<String>)> withOpenDefects() {
    final out = <(Vehicle, List<String>)>[];
    for (final v in _vehicles) {
      final open = outstandingDefects(v.id);
      if (open.isNotEmpty) out.add((v, open));
    }
    // A vehicle with a major defect outstanding comes first whatever the
    // counts say: one major defect means it must not be driven, and ten
    // minor ones do not.
    out.sort((a, b) {
      final am = lastFor(a.$1.id)?.openMajorDefects.length ?? 0;
      final bm = lastFor(b.$1.id)?.openMajorDefects.length ?? 0;
      if (am != bm) return bm.compareTo(am);
      return b.$2.length.compareTo(a.$2.length);
    });
    return out;
  }

  /// How long a daily inspection counts as current, for the "not inspected
  /// since" list.
  ///
  /// **This is the app counting hours, never a ruling on a record.** It says
  /// what is in the log — "nothing recorded in the last 24 hours" — and not
  /// whether any particular inspection is still good enough for anybody,
  /// which is a question about the law and not about the data. The same
  /// reason the record itself carries an age and deliberately no "valid
  /// until" line.
  static const Duration dueWindow = Duration(hours: 24);

  /// Every vehicle with nothing recorded inside [dueWindow], oldest first,
  /// paired with how long it has been — null when there is nothing at all.
  List<(Vehicle, Duration?)> notInspectedSince(DateTime now) {
    final out = <(Vehicle, Duration?)>[];
    for (final v in _vehicles) {
      final last = lastFor(v.id);
      if (last == null) {
        out.add((v, null));
        continue;
      }
      final since = now.difference(last.at);
      if (since >= dueWindow) out.add((v, since));
    }
    // Never-inspected first, then longest wait — the order somebody would
    // work down.
    out.sort((a, b) {
      if ((a.$2 == null) != (b.$2 == null)) return a.$2 == null ? -1 : 1;
      if (a.$2 == null) return 0;
      return b.$2!.compareTo(a.$2!);
    });
    return out;
  }

  /// Who did the last walk-around on this vehicle, so a daily task does not
  /// ask for the same name every morning. A suggestion the field starts
  /// with, never a claim about who is driving today — it stays editable and
  /// whatever is in the box at save time is what the record says.
  String lastDriverFor(String vehicleId) {
    for (final i in _inspections) {
      if (i.vehicleId != vehicleId) continue;
      if (i.driver.trim().isNotEmpty) return i.driver.trim();
    }
    return '';
  }

  /// How many of the recent inspections an item has to have been flagged on
  /// before it reads as a pattern rather than a bad morning.
  static const int recurringWindow = 10;
  static const int recurringThreshold = 3;

  /// Items flagged as a defect on [recurringThreshold] or more of the last
  /// [recurringWindow] inspections, worst first.
  ///
  /// **A pattern in the log, not a diagnosis.** Something that keeps being
  /// written down is worth a mechanic's attention, and that is the whole
  /// claim — it says nothing about why, and a defect signed off each time
  /// still counts, because a fault that returns after three repairs is
  /// exactly the one worth noticing.
  List<(String, int)> recurringDefects(String vehicleId) {
    final recent = forVehicle(vehicleId).take(recurringWindow);
    final tally = <String, int>{};
    for (final i in recent) {
      for (final id in i.defects) {
        tally[id] = (tally[id] ?? 0) + 1;
      }
    }
    final out = [
      for (final e in tally.entries)
        if (e.value >= recurringThreshold) (e.key, e.value)
    ]..sort((a, b) => b.$2.compareTo(a.$2));
    return out;
  }

  /// The odometer on the most recent inspection of [vehicleId], for the
  /// reading-went-backwards check. Empty when there is nothing to compare to.
  String lastOdometerFor(String vehicleId, {String? exceptId}) {
    for (final i in _inspections) {
      if (i.vehicleId != vehicleId) continue;
      if (exceptId != null && i.id == exceptId) continue;
      if (i.odometer.trim().isNotEmpty) return i.odometer.trim();
    }
    return '';
  }

  /// Signs a defect off as put right, ON the inspection that found it.
  ///
  /// An annotation, never an edit: what was found stays exactly as found and
  /// the signed declaration above it is untouched. Passing null for [fix]
  /// takes the sign-off back off, for the case where it was the wrong item.
  void markFixed(String inspectionId, String itemId, DefectFix? fix) {
    final idx = _inspections.indexWhere((e) => e.id == inspectionId);
    if (idx < 0) return;
    final i = _inspections[idx];
    // Only a real defect can be signed off. Anything else would put a fix on
    // a line that never said anything was wrong.
    if (i.resultFor(itemId) != CheckResult.defect) return;
    final fixes = Map<String, DefectFix>.of(i.fixes);
    if (fix == null) {
      fixes.remove(itemId);
    } else {
      fixes[itemId] = fix;
    }
    _inspections[idx] = i.copyWith(fixes: fixes);
    notifyListeners();
    _saveInspections();
  }

  Future<void> load() async {
    final prefs = _prefs ??= await SharedPreferences.getInstance();
    _vehicles.clear();
    _inspections.clear();
    _operatorName = prefs.getString(_operatorKey) ?? '';
    _reminderMinutes = prefs.getInt(_reminderKey);
    try {
      final raw = prefs.getString(_vehiclesKey);
      if (raw != null && raw.isNotEmpty) {
        final list = jsonDecode(raw);
        if (list is List) {
          for (final e in list) {
            if (e is Map) {
              _vehicles.add(Vehicle.fromJson(Map<String, dynamic>.from(e)));
            }
          }
        }
      }
    } catch (_) {
      // A corrupt blob is an empty list, not a crash on launch.
    }
    try {
      final raw = prefs.getString(_inspectionsKey);
      if (raw != null && raw.isNotEmpty) {
        final list = jsonDecode(raw);
        if (list is List) {
          for (final e in list) {
            if (e is Map) {
              _inspections
                  .add(Inspection.fromJson(Map<String, dynamic>.from(e)));
            }
          }
        }
      }
    } catch (_) {
      // As above.
    }
    _sort();
    notifyListeners();
  }

  void _sort() => _inspections.sort((a, b) => b.at.compareTo(a.at));

  Future<void> _saveVehicles() async {
    final prefs = _prefs ??= await SharedPreferences.getInstance();
    await prefs.setString(
        _vehiclesKey, jsonEncode([for (final v in _vehicles) v.toJson()]));
  }

  Future<void> _saveInspections() async {
    final prefs = _prefs ??= await SharedPreferences.getInstance();
    await prefs.setString(_inspectionsKey,
        jsonEncode([for (final i in _inspections) i.toJson()]));
  }

  /// Adds a vehicle, or replaces the one with [id]. Returns the id.
  String saveVehicle({
    String? id,
    required String name,
    String plate = '',
    String notes = '',
    VehicleType type = VehicleType.other,
    DateTime? now,
  }) {
    final at = now ?? DateTime.now();
    final vid = id ?? 'veh_${at.microsecondsSinceEpoch}';
    final v = Vehicle(
        id: vid,
        name: name.trim(),
        plate: plate.trim(),
        notes: notes.trim(),
        type: type);
    final i = _vehicles.indexWhere((e) => e.id == vid);
    if (i >= 0) {
      _vehicles[i] = v;
    } else {
      if (_vehicles.length >= maxVehicles) return '';
      _vehicles.add(v);
    }
    notifyListeners();
    _saveVehicles();
    return vid;
  }

  /// Removes a vehicle AND its inspections, and hands both back so the
  /// caller can offer an undo — a maintenance record is expensive to lose
  /// and impossible to retype.
  (Vehicle, List<Inspection>)? removeVehicle(String id) {
    final i = _vehicles.indexWhere((e) => e.id == id);
    if (i < 0) return null;
    final vehicle = _vehicles.removeAt(i);
    final gone = <Inspection>[];
    _inspections.removeWhere((e) {
      if (e.vehicleId != id) return false;
      gone.add(e);
      return true;
    });
    notifyListeners();
    _saveVehicles();
    _saveInspections();
    return (vehicle, gone);
  }

  void restoreVehicle(Vehicle vehicle, List<Inspection> records) {
    if (!_vehicles.any((v) => v.id == vehicle.id)) _vehicles.add(vehicle);
    for (final r in records) {
      if (!_inspections.any((i) => i.id == r.id)) _inspections.add(r);
    }
    _sort();
    notifyListeners();
    _saveVehicles();
    _saveInspections();
  }

  /// Files an inspection, or replaces the one with the same id.
  ///
  /// Photos are capped here rather than only in the UI, so a caller added
  /// later cannot grow the stored blob past what the cap promises.
  void saveInspection(Inspection inspection) {
    final trimmed = inspection.photoCount > maxPhotos
        ? Inspection(
            id: inspection.id,
            vehicleId: inspection.vehicleId,
            kind: inspection.kind,
            at: inspection.at,
            startedAt: inspection.startedAt,
            odometer: inspection.odometer,
            driver: inspection.driver,
            location: inspection.location,
            operator: inspection.operator,
            coupledUnit: inspection.coupledUnit,
            results: inspection.results,
            notes: inspection.notes,
            // The per-defect photos are the evidence; the general ones are
            // context. So the cap eats the general pool first.
            photos: inspection.photos
                .take((maxPhotos - inspection.itemPhotos.length)
                    .clamp(0, maxPhotos))
                .toList(),
            itemPhotos: inspection.itemPhotos,
            fixes: inspection.fixes,
            severities: inspection.severities,
            schedule: inspection.schedule,
            signature: inspection.signature,
            remarks: inspection.remarks,
          )
        : inspection;
    final i = _inspections.indexWhere((e) => e.id == trimmed.id);
    if (i >= 0) {
      _inspections[i] = trimmed;
    } else {
      _inspections.add(trimmed);
    }
    _sort();
    // Oldest out at the cap — see [maxInspections].
    if (_inspections.length > maxInspections) {
      _inspections.removeRange(maxInspections, _inspections.length);
    }
    notifyListeners();
    _saveInspections();
  }

  Inspection? removeInspection(String id) {
    final i = _inspections.indexWhere((e) => e.id == id);
    if (i < 0) return null;
    final gone = _inspections.removeAt(i);
    notifyListeners();
    _saveInspections();
    return gone;
  }

  void restoreInspection(Inspection inspection) {
    if (_inspections.any((i) => i.id == inspection.id)) return;
    _inspections.add(inspection);
    _sort();
    notifyListeners();
    _saveInspections();
  }

  /// The whole log as a file's worth of text.
  String exportBackup() => InspectionBackup(
        vehicles: _vehicles,
        inspections: _inspections,
        operatorName: _operatorName,
      ).encode();

  /// Puts a backup back, and **only ever ADDS**.
  ///
  /// A record already here is left exactly as it is — never overwritten by
  /// its copy in the file. Two reasons: a filed inspection is immutable, so
  /// same id means the same record and there is nothing to gain; and a
  /// restore onto a phone that has been used since must not quietly undo
  /// what happened in between. On a fresh phone every id is new, which is
  /// the case this exists for, and merging is then indistinguishable from
  /// replacing.
  ///
  /// Returns what actually landed, so the screen can say so rather than
  /// claiming success over a file that added nothing.
  ({int vehicles, int inspections}) restoreBackup(InspectionBackup backup) {
    var addedVehicles = 0;
    var addedInspections = 0;
    for (final v in backup.vehicles) {
      if (v.id.isEmpty || _vehicles.any((e) => e.id == v.id)) continue;
      if (_vehicles.length >= maxVehicles) break;
      _vehicles.add(v);
      addedVehicles++;
    }
    for (final i in backup.inspections) {
      if (i.id.isEmpty || _inspections.any((e) => e.id == i.id)) continue;
      _inspections.add(i);
      addedInspections++;
    }
    // The operator is filled in only where there is nothing to overwrite —
    // it is a setting on THIS device, and a file should not rename the
    // carrier somebody is filing under today.
    if (_operatorName.isEmpty && backup.operatorName.isNotEmpty) {
      _operatorName = backup.operatorName;
      _prefs?.setString(_operatorKey, _operatorName);
    }
    _sort();
    // The cap still holds, and it still drops the OLDEST — a restore of a
    // long history onto a full phone keeps the recent end, which is the end
    // anybody is asked about.
    if (_inspections.length > maxInspections) {
      _inspections.removeRange(maxInspections, _inspections.length);
    }
    notifyListeners();
    _saveVehicles();
    _saveInspections();
    return (vehicles: addedVehicles, inspections: addedInspections);
  }

  /// Account switch / wipe. Drops the cached prefs handle with the lists,
  /// the same as [SavedForms.reset] — a stale handle is what makes the next
  /// `load()` read the previous account's blob straight back in.
  void reset() {
    _vehicles.clear();
    _inspections.clear();
    _operatorName = '';
    _reminderMinutes = null;
    _prefs = null;
    notifyListeners();
  }
}
