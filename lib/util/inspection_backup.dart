import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';

import '../models/inspection.dart';

/// The whole inspection log as one file, and back again.
///
/// **This is what stops a maintenance log dying with a phone.** Everything
/// the tool keeps lives in one SharedPreferences string on one device, and
/// the store drops the oldest record at its cap — so without a way OUT,
/// "kept on this device only" also means "lost with this device". A file the
/// owner holds is the honest answer to that: it needs no server, no account
/// and no subscription, and it keeps the promise the rest of the feature
/// makes.
///
/// **The file is NOT encrypted, and every surface that offers it says so.**
/// It carries driver names, plates, places, times and the photos — more in
/// one file than any single report — so somebody putting it in a cloud drive
/// deserves to know that before they do, not after.
class InspectionBackup {
  const InspectionBackup({
    required this.vehicles,
    required this.inspections,
    this.operatorName = '',
  });

  final List<Vehicle> vehicles;
  final List<Inspection> inspections;
  final String operatorName;

  /// Bumped only if the shape stops being readable by an older build. The
  /// fields themselves are additive, so a file from a newer app decodes on
  /// an older one minus whatever it has not heard of.
  static const int version = 1;

  static const String _magic = 'okay.inspections';

  String encode() => jsonEncode({
        'kind': _magic,
        'version': version,
        if (operatorName.isNotEmpty) 'operator': operatorName,
        'vehicles': [for (final v in vehicles) v.toJson()],
        'inspections': [for (final i in inspections) i.toJson()],
      });

  /// Reads a file back, or null when it is not one of ours.
  ///
  /// Null rather than a throw, and checked by its own marker rather than by
  /// hoping: this parses a file somebody picked out of a cloud drive, so the
  /// likeliest input after a real backup is a completely unrelated document.
  /// Saying "that is not an inspection backup" beats a stack trace or, far
  /// worse, half-importing something.
  static InspectionBackup? decode(String raw) {
    try {
      final j = jsonDecode(raw);
      if (j is! Map || j['kind'] != _magic) return null;
      return InspectionBackup(
        operatorName: j['operator'] as String? ?? '',
        vehicles: [
          for (final v in (j['vehicles'] as List?) ?? const [])
            if (v is Map) Vehicle.fromJson(Map<String, dynamic>.from(v))
        ],
        inspections: [
          for (final i in (j['inspections'] as List?) ?? const [])
            if (i is Map) Inspection.fromJson(Map<String, dynamic>.from(i))
        ],
      );
    } catch (_) {
      return null;
    }
  }

  /// A filename somebody can find again in a year.
  static String fileName(DateTime at) {
    String two(int v) => v.toString().padLeft(2, '0');
    return 'okay-inspections-${at.year}${two(at.month)}${two(at.day)}.json';
  }

  /// Test hook: stands in for the file picker.
  @visibleForTesting
  static Future<Uint8List?> Function()? debugPickOverride;

  /// Opens the picker for a backup file. Its own picker rather than
  /// [NearbyPick]'s, whose moderation exists to decide what may be handed to
  /// a stranger in the room — a different question from "is this my own
  /// backup".
  static Future<Uint8List?> pickFile() async {
    final hook = debugPickOverride;
    if (hook != null) return hook();
    try {
      final picked = await FilePicker.pickFiles(withData: true);
      return picked?.files.singleOrNull?.bytes;
    } catch (_) {
      return null;
    }
  }
}
