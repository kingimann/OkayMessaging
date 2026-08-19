/// What a check item came back as.
///
/// [unchecked] is a real, distinct answer and not a synonym for "fine": an
/// item nobody looked at must never read as one that passed, which is the
/// whole reason an inspection record is worth keeping at all.
enum CheckResult { unchecked, ok, defect, na }

extension CheckResultLabel on CheckResult {
  String get label => switch (this) {
        CheckResult.unchecked => 'Not checked',
        CheckResult.ok => 'OK',
        CheckResult.defect => 'Defect',
        CheckResult.na => 'N/A',
      };

  String get wire => switch (this) {
        CheckResult.unchecked => '',
        CheckResult.ok => 'ok',
        CheckResult.defect => 'defect',
        CheckResult.na => 'na',
      };

  static CheckResult fromWire(String raw) => switch (raw) {
        'ok' => CheckResult.ok,
        'defect' => CheckResult.defect,
        'na' => CheckResult.na,
        _ => CheckResult.unchecked,
      };
}

/// Pre-trip or post-trip. Two, not more: a walk-around before you drive and
/// one after you stop is the whole of what this tool claims to be.
enum InspectionKind { pre, post }

extension InspectionKindLabel on InspectionKind {
  String get label =>
      this == InspectionKind.pre ? 'Pre-trip' : 'Post-trip';
  String get wire => this == InspectionKind.pre ? 'pre' : 'post';
  static InspectionKind fromWire(String raw) =>
      raw == 'post' ? InspectionKind.post : InspectionKind.pre;
}

/// One line on the standard walk-around list.
class CheckItem {
  final String id;
  final String name;
  const CheckItem(this.id, this.name);
}

/// A group of them, as somebody actually walks the vehicle.
class CheckSection {
  final String title;
  final List<CheckItem> items;
  const CheckSection(this.title, this.items);
}

/// The standard walk-around list.
///
/// **Ids are permanent.** A stored inspection keeps only `id -> result`, so
/// renaming an item's text is free and changing its id silently orphans
/// every record that used it. Add to the end of a section; never re-letter.
///
/// It is deliberately ONE list rather than a per-vehicle template: a
/// template editor is a second product, and an item that does not apply to
/// a given vehicle is exactly what [CheckResult.na] is for.
const List<CheckSection> kInspectionChecklist = [
  CheckSection('Under the hood', [
    CheckItem('hood_oil', 'Engine oil level'),
    CheckItem('hood_coolant', 'Coolant level'),
    CheckItem('hood_belts', 'Belts and hoses'),
    CheckItem('hood_battery', 'Battery and cables'),
    CheckItem('hood_leaks', 'Leaks under the vehicle'),
  ]),
  CheckSection('Exterior', [
    CheckItem('ext_body', 'Body and frame damage'),
    CheckItem('ext_doors', 'Doors and latches'),
    CheckItem('ext_glass', 'Windshield and glass'),
    CheckItem('ext_wipers', 'Wipers and washers'),
    CheckItem('ext_mirrors', 'Mirrors and mountings'),
    CheckItem('ext_fuel', 'Fuel system and cap'),
    CheckItem('ext_exhaust', 'Exhaust system'),
  ]),
  CheckSection('Tyres and wheels', [
    CheckItem('whl_tread', 'Tyre condition and tread'),
    CheckItem('whl_pressure', 'Tyre pressure'),
    CheckItem('whl_rims', 'Wheels, rims and fasteners'),
    CheckItem('whl_flaps', 'Mud flaps and guards'),
    CheckItem('whl_spare', 'Spare wheel and jack'),
  ]),
  CheckSection('Lights and signals', [
    CheckItem('lgt_head', 'Headlights, high and low'),
    CheckItem('lgt_brake', 'Brake lights'),
    CheckItem('lgt_turn', 'Turn signals and hazards'),
    CheckItem('lgt_marker', 'Marker and clearance lights'),
    CheckItem('lgt_reverse', 'Reversing lights'),
    CheckItem('lgt_reflect', 'Reflectors'),
  ]),
  CheckSection('Brakes and steering', [
    CheckItem('brk_service', 'Service brake'),
    CheckItem('brk_park', 'Parking brake'),
    CheckItem('brk_air', 'Air system and warning device'),
    CheckItem('brk_lines', 'Brake lines and hoses'),
    CheckItem('brk_steer', 'Steering play and linkage'),
    CheckItem('brk_susp', 'Suspension and springs'),
  ]),
  CheckSection('Cab and controls', [
    CheckItem('cab_gauges', 'Gauges and warning lights'),
    CheckItem('cab_horn', 'Horn'),
    CheckItem('cab_heater', 'Heater and defroster'),
    CheckItem('cab_belts', 'Seat belts'),
    CheckItem('cab_seat', 'Seat and mountings'),
    CheckItem('cab_docs', 'Documents and permits on board'),
  ]),
  CheckSection('Emergency equipment', [
    CheckItem('emg_fire', 'Fire extinguisher'),
    CheckItem('emg_triangles', 'Warning triangles or flares'),
    CheckItem('emg_aid', 'First aid kit'),
    CheckItem('emg_fuses', 'Spare fuses'),
  ]),
  CheckSection('Coupling and load', [
    CheckItem('cpl_devices', 'Coupling devices'),
    CheckItem('cpl_trailer', 'Trailer connections and lines'),
    CheckItem('cpl_cargo', 'Cargo securement'),
    CheckItem('cpl_doors', 'Cargo doors and tailgate'),
  ]),
];

/// Every item on the list, flattened, in walk order.
List<CheckItem> get allCheckItems =>
    [for (final s in kInspectionChecklist) ...s.items];

/// The name of an item id, for a record whose item this build still knows.
/// An id from a newer build reads as itself rather than disappearing — an
/// inspection is a record, and dropping a line from it silently is worse
/// than showing a name nobody chose.
String checkItemName(String id) {
  for (final s in kInspectionChecklist) {
    for (final i in s.items) {
      if (i.id == id) return i.name;
    }
  }
  return id;
}

/// A vehicle this account inspects.
///
/// Free text throughout, and the odometer in particular is a STRING that is
/// never parsed — the same rule a form's number question follows, and for
/// the same reason: a reading somebody types with a leading zero, a comma or
/// a unit stops being what they wrote the moment it goes through a parser.
class Vehicle {
  final String id;
  final String name;
  final String plate;
  final String notes;

  const Vehicle({
    required this.id,
    required this.name,
    this.plate = '',
    this.notes = '',
  });

  Vehicle copyWith({String? name, String? plate, String? notes}) => Vehicle(
        id: id,
        name: name ?? this.name,
        plate: plate ?? this.plate,
        notes: notes ?? this.notes,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        if (plate.isNotEmpty) 'plate': plate,
        if (notes.isNotEmpty) 'notes': notes,
      };

  factory Vehicle.fromJson(Map<String, dynamic> j) => Vehicle(
        id: j['id'] as String? ?? '',
        name: j['name'] as String? ?? '',
        plate: j['plate'] as String? ?? '',
        notes: j['notes'] as String? ?? '',
      );

  /// What the row says under the name.
  String get subtitle => plate.trim().isEmpty ? '' : plate.trim();
}

/// One walk-around, on one vehicle, on one day.
class Inspection {
  final String id;
  final String vehicleId;
  final InspectionKind kind;
  final DateTime at;

  /// Text, never parsed — see [Vehicle].
  final String odometer;
  final String driver;
  final String location;

  /// item id -> result. An id absent from the map is [CheckResult.unchecked],
  /// so an inspection that only recorded what was actually looked at costs
  /// nothing to store.
  final Map<String, CheckResult> results;

  /// item id -> what was wrong. Only ever written for a defect.
  final Map<String, String> notes;

  /// Prepared `data:` URIs, capped by [VehicleInspections.maxPhotos].
  final List<String> photos;

  /// Encoded [SignatureInk] — a drawn mark, not proof of who drew it.
  final String signature;

  final String remarks;

  const Inspection({
    required this.id,
    required this.vehicleId,
    required this.kind,
    required this.at,
    this.odometer = '',
    this.driver = '',
    this.location = '',
    this.results = const {},
    this.notes = const {},
    this.photos = const [],
    this.signature = '',
    this.remarks = '',
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'vehicleId': vehicleId,
        'kind': kind.wire,
        'at': at.toIso8601String(),
        if (odometer.isNotEmpty) 'odometer': odometer,
        if (driver.isNotEmpty) 'driver': driver,
        if (location.isNotEmpty) 'location': location,
        if (results.isNotEmpty)
          'results': {
            for (final e in results.entries)
              if (e.value != CheckResult.unchecked) e.key: e.value.wire
          },
        if (notes.isNotEmpty) 'notes': notes,
        if (photos.isNotEmpty) 'photos': photos,
        if (signature.isNotEmpty) 'signature': signature,
        if (remarks.isNotEmpty) 'remarks': remarks,
      };

  factory Inspection.fromJson(Map<String, dynamic> j) => Inspection(
        id: j['id'] as String? ?? '',
        vehicleId: j['vehicleId'] as String? ?? '',
        kind: InspectionKindLabel.fromWire(j['kind'] as String? ?? 'pre'),
        at: DateTime.tryParse(j['at'] as String? ?? '') ?? DateTime(2026),
        odometer: j['odometer'] as String? ?? '',
        driver: j['driver'] as String? ?? '',
        location: j['location'] as String? ?? '',
        results: {
          for (final e in ((j['results'] as Map?) ?? const {}).entries)
            '${e.key}': CheckResultLabel.fromWire('${e.value}')
        },
        notes: {
          for (final e in ((j['notes'] as Map?) ?? const {}).entries)
            '${e.key}': '${e.value}'
        },
        photos: [
          for (final p in (j['photos'] as List?) ?? const []) '$p',
        ],
        signature: j['signature'] as String? ?? '',
        remarks: j['remarks'] as String? ?? '',
      );

  CheckResult resultFor(String itemId) =>
      results[itemId] ?? CheckResult.unchecked;

  /// The ids that came back as a defect, in walk order — the order somebody
  /// inspected in, not the order a hash map happens to hold.
  List<String> get defects => [
        for (final i in allCheckItems)
          if (resultFor(i.id) == CheckResult.defect) i.id
      ];

  int get defectCount => defects.length;

  /// Items on THIS build's list that nobody answered. Counted against the
  /// standard list rather than the stored map, or an inspection where
  /// somebody stopped half way would report a clean sheet.
  int get uncheckedCount {
    var n = 0;
    for (final i in allCheckItems) {
      if (resultFor(i.id) == CheckResult.unchecked) n++;
    }
    return n;
  }

  bool get isComplete => uncheckedCount == 0;

  /// One line for a list row. Deliberately reports what was found and what
  /// was skipped, and claims nothing about whether the vehicle may be
  /// driven — that is a judgement for the person who signed it.
  String get summary {
    final parts = <String>[
      defectCount == 0
          ? 'No defects recorded'
          : '$defectCount ${defectCount == 1 ? 'defect' : 'defects'}',
    ];
    if (uncheckedCount > 0) parts.add('$uncheckedCount not checked');
    return parts.join(' · ');
  }
}
