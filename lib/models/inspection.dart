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

/// Every item on the standard walk-around, flattened, in walk order.
List<CheckItem> get allCheckItems =>
    [for (final s in kInspectionChecklist) ...s.items];

/// Every item on a given schedule, flattened, in walk order.
List<CheckItem> itemsFor(InspectionSchedule schedule) =>
    [for (final s in schedule.checklist) ...s.items];

/// The name of an item id, for a record whose item this build still knows.
/// An id from a newer build reads as itself rather than disappearing — an
/// inspection is a record, and dropping a line from it silently is worse
/// than showing a name nobody chose.
String checkItemName(String id) {
  for (final s in [...kInspectionChecklist, ...kSchedule1Checklist]) {
    for (final i in s.items) {
      if (i.id == id) return i.name;
    }
  }
  return id;
}


/// What kind of vehicle this is, because the list you walk depends on it.
///
/// Ontario runs daily inspections under **O. Reg. 199/07**, which points a
/// different SCHEDULE at each class of vehicle. Only the classes this app can
/// serve honestly are offered — see [InspectionSchedule].
enum VehicleType { truck, tractor, trailer, other }

extension VehicleTypeLabel on VehicleType {
  String get label => switch (this) {
        VehicleType.truck => 'Truck',
        VehicleType.tractor => 'Tractor',
        VehicleType.trailer => 'Trailer',
        VehicleType.other => 'Other',
      };

  String get wire => switch (this) {
        VehicleType.truck => 'truck',
        VehicleType.tractor => 'tractor',
        VehicleType.trailer => 'trailer',
        VehicleType.other => 'other',
      };

  static VehicleType fromWire(String raw) => switch (raw) {
        'truck' => VehicleType.truck,
        'tractor' => VehicleType.tractor,
        'trailer' => VehicleType.trailer,
        _ => VehicleType.other,
      };

  InspectionSchedule get schedule => switch (this) {
        VehicleType.truck ||
        VehicleType.tractor ||
        VehicleType.trailer =>
          InspectionSchedule.schedule1,
        VehicleType.other => InspectionSchedule.general,
      };
}

/// Which list a walk-around was carried out against.
///
/// **Recorded on the inspection, not read from the vehicle.** A vehicle's
/// type can be corrected next year, and a record must go on saying which
/// list it was actually walked against — the same reason the operator name
/// is stamped rather than looked up.
///
/// **Schedules 2, 3 and 5 are deliberately absent.** O. Reg. 199/07 puts
/// buses under Schedule 2, motor coaches under Schedule 3 and school
/// purposes buses under Schedule 5, and their item lists have not been read
/// from the regulation here. Offering a "Schedule 2" built from memory would
/// be the single most misleading thing this app could do — a record naming a
/// statutory schedule it does not actually follow. Add them from the source
/// or leave them out.
enum InspectionSchedule { schedule1, general }

extension InspectionScheduleInfo on InspectionSchedule {
  String get wire =>
      this == InspectionSchedule.schedule1 ? 'schedule1' : 'general';

  static InspectionSchedule fromWire(String raw) =>
      raw == 'schedule1' ? InspectionSchedule.schedule1 : InspectionSchedule.general;

  String get name => switch (this) {
        InspectionSchedule.schedule1 => 'Schedule 1',
        InspectionSchedule.general => 'Standard walk-around',
      };

  /// Said on every record and every report, so nobody has to guess what the
  /// list was.
  String get provenance => switch (this) {
        InspectionSchedule.schedule1 =>
          'Recorded against the Schedule 1 systems for trucks, tractors and '
              'trailers (Ontario O. Reg. 199/07).',
        InspectionSchedule.general =>
          "Recorded against OkayMessenger's standard walk-around list.",
      };

  List<CheckSection> get checklist => switch (this) {
        InspectionSchedule.schedule1 => kSchedule1Checklist,
        InspectionSchedule.general => kInspectionChecklist,
      };
}

/// How bad a defect is, in the terms the regulation itself uses.
///
/// This is the distinction the first version of this tool missed entirely,
/// and it is the heart of the scheme: a **minor** defect is recorded and
/// reported to the operator; a **major** defect means the vehicle must not
/// be driven until it is repaired. The app RECORDS which one the driver
/// marked — it does not decide, and it never clears anybody to drive.
enum DefectSeverity { minor, major }

extension DefectSeverityLabel on DefectSeverity {
  String get label =>
      this == DefectSeverity.major ? 'Major' : 'Minor';

  String get wire => this == DefectSeverity.major ? 'major' : 'minor';

  static DefectSeverity fromWire(String raw) =>
      raw == 'major' ? DefectSeverity.major : DefectSeverity.minor;

  /// What the regulation says follows, quoted as the rule rather than as
  /// this app's ruling.
  String get consequence => this == DefectSeverity.major
      ? 'A major defect means the vehicle must not be driven until it is '
          'repaired.'
      : 'A minor defect is recorded and reported to the operator.';
}

/// **Schedule 1 — daily inspection of trucks, tractors and trailers.**
///
/// The 22 systems and components in the order the Ministry of
/// Transportation publishes them. The conditional wording — "if equipped",
/// "if present", "qualified driver only" — is part of the item name rather
/// than a rule this app enforces: whether a trailer has cargo on it is the
/// driver's call, and [CheckResult.na] is how they say so.
///
/// **This is the list of SYSTEMS, not the full table of every named defect
/// under each.** The regulation enumerates specific minor and major defects
/// per system; what is captured here is which system, how bad
/// ([DefectSeverity]), and what the driver wrote. Stated so nobody mistakes
/// this for a reproduction of the statutory table.
const List<CheckSection> kSchedule1Checklist = [
  CheckSection('Schedule 1', [
    CheckItem('s1_airbrake', 'Air brake system (if equipped)'),
    CheckItem('s1_cab', 'Cab'),
    CheckItem('s1_cargo', 'Cargo securement (if present)'),
    CheckItem('s1_coupling', 'Coupling devices (if equipped)'),
    CheckItem('s1_dg', 'Dangerous goods (qualified driver only)'),
    CheckItem('s1_controls', 'Driver controls'),
    CheckItem('s1_seat', 'Driver seat'),
    CheckItem('s1_ebrake', 'Electric brake system'),
    CheckItem('s1_emergency', 'Emergency equipment and safety devices'),
    CheckItem('s1_exhaust', 'Exhaust system'),
    CheckItem('s1_frame', 'Frame and cargo body'),
    CheckItem('s1_fuel', 'Fuel system'),
    CheckItem('s1_glass', 'Glass and mirrors'),
    CheckItem('s1_heater', 'Heater/defroster'),
    CheckItem('s1_horn', 'Horn'),
    CheckItem('s1_hbrake', 'Hydraulic brake system'),
    CheckItem('s1_lamps', 'Lamps and reflectors'),
    CheckItem('s1_steering', 'Steering'),
    CheckItem('s1_suspension', 'Suspension system'),
    CheckItem('s1_tires', 'Tires'),
    CheckItem('s1_wheels', 'Wheels, hubs and fasteners'),
    CheckItem('s1_wipers', 'Windshield wiper/washer'),
  ]),
];

/// A defect signed off as put right.
///
/// **Recorded ON the inspection that found it**, not as a separate log. That
/// is how a repair certification works on paper and it is the only shape
/// that answers the question anybody actually asks — "was the thing you
/// found on Tuesday dealt with?" A separate table would leave the Tuesday
/// record still saying, forever, that the vehicle had a defect.
///
/// It is an ANNOTATION, never an edit: what was found stays exactly as it
/// was found, and the signed declaration above it is untouched.
class DefectFix {
  final DateTime at;

  /// Who says so. Free text — this is a note, not an authorisation.
  final String by;
  final String note;

  const DefectFix({required this.at, this.by = '', this.note = ''});

  Map<String, dynamic> toJson() => {
        'at': at.toIso8601String(),
        if (by.isNotEmpty) 'by': by,
        if (note.isNotEmpty) 'note': note,
      };

  factory DefectFix.fromJson(Map<String, dynamic> j) => DefectFix(
        at: DateTime.tryParse(j['at'] as String? ?? '') ?? DateTime(2026),
        by: j['by'] as String? ?? '',
        note: j['note'] as String? ?? '',
      );
}

/// Whether a new odometer reading contradicts the one before it.
///
/// **Compared, never stored as a number.** The reading itself stays the text
/// somebody typed — a leading zero, a comma or a unit has to survive — so
/// this parses only the digits, only to compare, and only to WARN. Anything
/// that will not parse returns null: "that is not a number" is not a
/// sentence worth showing somebody looking at what they just wrote.
String? odometerProblem(String previous, String current) {
  final a = int.tryParse(previous.replaceAll(RegExp(r'[^0-9]'), ''));
  final b = int.tryParse(current.replaceAll(RegExp(r'[^0-9]'), ''));
  if (a == null || b == null) return null;
  if (b < a) return 'Lower than the last reading ($previous).';
  return null;
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

  /// What it is, which is what decides the list somebody walks.
  ///
  /// A vehicle saved before this existed decodes as [VehicleType.other] —
  /// the standard walk-around, which is exactly the list it was inspected
  /// against, so nothing already recorded changes meaning.
  final VehicleType type;

  const Vehicle({
    required this.id,
    required this.name,
    this.plate = '',
    this.notes = '',
    this.type = VehicleType.other,
  });

  Vehicle copyWith(
          {String? name, String? plate, String? notes, VehicleType? type}) =>
      Vehicle(
        id: id,
        name: name ?? this.name,
        plate: plate ?? this.plate,
        notes: notes ?? this.notes,
        type: type ?? this.type,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        if (plate.isNotEmpty) 'plate': plate,
        if (notes.isNotEmpty) 'notes': notes,
        if (type != VehicleType.other) 'type': type.wire,
      };

  factory Vehicle.fromJson(Map<String, dynamic> j) => Vehicle(
        id: j['id'] as String? ?? '',
        name: j['name'] as String? ?? '',
        plate: j['plate'] as String? ?? '',
        notes: j['notes'] as String? ?? '',
        type: VehicleTypeLabel.fromWire(j['type'] as String? ?? ''),
      );

  /// What the row says under the name.
  String get subtitle => plate.trim().isEmpty ? '' : plate.trim();
}

/// One walk-around, on one vehicle, on one day.
class Inspection {
  final String id;
  final String vehicleId;
  final InspectionKind kind;

  /// When it was COMPLETED — the moment the record was filed.
  final DateTime at;

  /// When the walk-around was STARTED, if this record knows.
  ///
  /// Null on a record made before the field existed, and that is a real
  /// answer rather than a default: back-filling it from [at] would invent a
  /// start time for an inspection nobody timed, on the one document where an
  /// invented time is the worst thing to put.
  final DateTime? startedAt;

  /// Text, never parsed — see [Vehicle].
  final String odometer;
  final String driver;
  final String location;

  /// The carrier or operator this was filed under.
  ///
  /// Stamped onto the RECORD at save time rather than read live from the
  /// store: an operator name that changed last month must not silently
  /// rewrite what an inspection from before it says.
  final String operator;

  /// item id -> result. An id absent from the map is [CheckResult.unchecked],
  /// so an inspection that only recorded what was actually looked at costs
  /// nothing to store.
  final Map<String, CheckResult> results;

  /// item id -> what was wrong. Only ever written for a defect.
  final Map<String, String> notes;

  /// Prepared `data:` URIs not tied to any one item — the general shots.
  final List<String> photos;

  /// item id -> one prepared `data:` URI: the picture OF that defect.
  ///
  /// One per item on purpose. A second angle on the same crack is worth far
  /// less than a photo of the next defect, and everything here lives in one
  /// SharedPreferences string.
  final Map<String, String> itemPhotos;

  /// item id -> the sign-off. Only ever written for an item that came back
  /// as a defect.
  final Map<String, DefectFix> fixes;

  /// item id -> how bad. Absent means a defect recorded before the app knew
  /// the difference, which reads as "not stated" rather than as minor —
  /// guessing downwards on somebody's brake defect is the wrong direction to
  /// be wrong in.
  final Map<String, DefectSeverity> severities;

  /// Which list this walk-around was carried out against.
  final InspectionSchedule schedule;

  /// Encoded [SignatureInk] — a drawn mark, not proof of who drew it.
  final String signature;

  final String remarks;

  const Inspection({
    required this.id,
    required this.vehicleId,
    required this.kind,
    required this.at,
    this.startedAt,
    this.odometer = '',
    this.driver = '',
    this.location = '',
    this.operator = '',
    this.results = const {},
    this.notes = const {},
    this.photos = const [],
    this.itemPhotos = const {},
    this.fixes = const {},
    this.severities = const {},
    this.schedule = InspectionSchedule.general,
    this.signature = '',
    this.remarks = '',
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'vehicleId': vehicleId,
        'kind': kind.wire,
        'at': at.toIso8601String(),
        if (startedAt != null) 'startedAt': startedAt!.toIso8601String(),
        if (startedAt != null) 'startedAt': startedAt!.toIso8601String(),
        if (odometer.isNotEmpty) 'odometer': odometer,
        if (driver.isNotEmpty) 'driver': driver,
        if (location.isNotEmpty) 'location': location,
        if (operator.isNotEmpty) 'operator': operator,
        if (results.isNotEmpty)
          'results': {
            for (final e in results.entries)
              if (e.value != CheckResult.unchecked) e.key: e.value.wire
          },
        if (notes.isNotEmpty) 'notes': notes,
        if (photos.isNotEmpty) 'photos': photos,
        if (itemPhotos.isNotEmpty) 'itemPhotos': itemPhotos,
        if (fixes.isNotEmpty)
          'fixes': {for (final e in fixes.entries) e.key: e.value.toJson()},
        if (severities.isNotEmpty)
          'severities': {
            for (final e in severities.entries) e.key: e.value.wire
          },
        if (schedule != InspectionSchedule.general) 'schedule': schedule.wire,
        if (signature.isNotEmpty) 'signature': signature,
        if (remarks.isNotEmpty) 'remarks': remarks,
      };

  factory Inspection.fromJson(Map<String, dynamic> j) => Inspection(
        id: j['id'] as String? ?? '',
        vehicleId: j['vehicleId'] as String? ?? '',
        kind: InspectionKindLabel.fromWire(j['kind'] as String? ?? 'pre'),
        at: DateTime.tryParse(j['at'] as String? ?? '') ?? DateTime(2026),
        startedAt: DateTime.tryParse(j['startedAt'] as String? ?? ''),
        odometer: j['odometer'] as String? ?? '',
        driver: j['driver'] as String? ?? '',
        location: j['location'] as String? ?? '',
        operator: j['operator'] as String? ?? '',
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
        itemPhotos: {
          for (final e in ((j['itemPhotos'] as Map?) ?? const {}).entries)
            '${e.key}': '${e.value}'
        },
        fixes: {
          for (final e in ((j['fixes'] as Map?) ?? const {}).entries)
            if (e.value is Map)
              '${e.key}':
                  DefectFix.fromJson(Map<String, dynamic>.from(e.value as Map))
        },
        severities: {
          for (final e in ((j['severities'] as Map?) ?? const {}).entries)
            '${e.key}': DefectSeverityLabel.fromWire('${e.value}')
        },
        schedule:
            InspectionScheduleInfo.fromWire(j['schedule'] as String? ?? ''),
        signature: j['signature'] as String? ?? '',
        remarks: j['remarks'] as String? ?? '',
      );

  /// The ONE field an annotation may touch.
  ///
  /// **A filed inspection is not editable** (the owner's call, 2026-08-19),
  /// and this is where that is enforced rather than merely intended: there
  /// is no parameter here for what was found, when, by whom, how bad it was
  /// or what they signed, so no amount of UI can rewrite any of it. A defect
  /// signed off as put right is an ADDITION to the record, which is why
  /// [fixes] is the exception.
  Inspection copyWith({Map<String, DefectFix>? fixes}) => Inspection(
        id: id,
        vehicleId: vehicleId,
        kind: kind,
        at: at,
        startedAt: startedAt,
        odometer: odometer,
        driver: driver,
        location: location,
        operator: operator,
        results: results,
        notes: notes,
        photos: photos,
        itemPhotos: itemPhotos,
        fixes: fixes ?? this.fixes,
        severities: severities,
        schedule: schedule,
        signature: signature,
        remarks: remarks,
      );

  /// Why this record cannot be filed yet, or null when it can.
  ///
  /// The odometer and the location are REQUIRED (the owner's call,
  /// 2026-08-19): a walk-around that does not say where it happened or what
  /// the vehicle had run is a record of very little, and the two are the
  /// fields somebody being shown it asks about after the date. Everything
  /// else stays optional — including the check items themselves, since
  /// refusing a partial walk-around would only lose the record of what WAS
  /// looked at.
  String? get incomplete {
    if (odometer.trim().isEmpty) return 'Enter the odometer reading.';
    if (location.trim().isEmpty) return 'Enter where the inspection happened.';
    return null;
  }

  CheckResult resultFor(String itemId) =>
      results[itemId] ?? CheckResult.unchecked;

  /// The ids that came back as a defect, in walk order — the order somebody
  /// inspected in, not the order a hash map happens to hold.
  List<String> get defects => [
        for (final i in itemsFor(schedule))
          if (resultFor(i.id) == CheckResult.defect) i.id
      ];

  DefectSeverity? severityFor(String itemId) => severities[itemId];

  /// The ones that mean the vehicle must not be driven until repaired.
  List<String> get majorDefects => [
        for (final id in defects)
          if (severities[id] == DefectSeverity.major) id
      ];

  /// Major defects nobody has signed off — the sharpest question the record
  /// can answer, and the one worth putting at the top of a screen.
  List<String> get openMajorDefects =>
      [for (final id in majorDefects) if (fixes[id] == null) id];

  int get defectCount => defects.length;

  /// The defects still outstanding — found, and not signed off.
  List<String> get openDefects =>
      [for (final id in defects) if (fixes[id] == null) id];

  int get fixedCount => defects.length - openDefects.length;

  /// Every photo this record holds, general and per-defect, against the cap.
  int get photoCount => photos.length + itemPhotos.length;

  /// Items on THIS build's list that nobody answered. Counted against the
  /// standard list rather than the stored map, or an inspection where
  /// somebody stopped half way would report a clean sheet.
  int get uncheckedCount {
    var n = 0;
    for (final i in itemsFor(schedule)) {
      if (resultFor(i.id) == CheckResult.unchecked) n++;
    }
    return n;
  }

  bool get isComplete => uncheckedCount == 0;

  /// The line above the signature, and the only sentence on the record
  /// written in the driver's voice. It states what was FOUND, never whether
  /// the vehicle may be driven — that judgement belongs to the person
  /// signing, and a form that made it for them would be putting words in
  /// their mouth about the one thing that matters.
  String get declaration {
    if (defectCount == 0) {
      return 'I carried out this inspection and found no defects.';
    }
    final major = majorDefects.length;
    return 'I carried out this inspection and found the '
        '$defectCount ${defectCount == 1 ? 'defect' : 'defects'} listed'
        '${major == 0 ? '' : ', $major of them major'}.';
  }

  /// One line for a list row. Deliberately reports what was found and what
  /// was skipped, and claims nothing about whether the vehicle may be
  /// driven — that is a judgement for the person who signed it.
  String get summary {
    final parts = <String>[
      defectCount == 0
          ? 'No defects recorded'
          : '$defectCount ${defectCount == 1 ? 'defect' : 'defects'}'
              '${majorDefects.isEmpty ? '' : ' (${majorDefects.length} major)'}',
    ];
    if (fixedCount > 0) parts.add('$fixedCount fixed');
    if (uncheckedCount > 0) parts.add('$uncheckedCount not checked');
    return parts.join(' · ');
  }
}
