import '../models/inspection.dart';

/// An inspection, written out as a report somebody can send on.
///
/// **Pure, and the only place the wording lives.** Every surface that hands
/// a record to somebody else — the share sheet, the exported file — reads
/// from here, so there is one description of what an inspection says rather
/// than three that drift.
///
/// **It claims nothing it cannot know.** There is no "passed", no
/// "roadworthy" and no certification anywhere in it: the report states who
/// inspected what, when, which items came back as a defect, and which were
/// never checked. Whether the vehicle may be driven is a judgement made by
/// the person who signed it, and a report that quietly answered it for them
/// would be the most dangerous sentence this tool could print.
class InspectionReport {
  InspectionReport._();

  static String _two(int v) => v.toString().padLeft(2, '0');

  /// `2026-08-19 07:42` — sortable, unambiguous, and the same in every
  /// locale, which matters more on a maintenance record than looking local.
  static String stamp(DateTime at) =>
      '${at.year}-${_two(at.month)}-${_two(at.day)} '
      '${_two(at.hour)}:${_two(at.minute)}';

  /// When it was started and when it was finished, on one line.
  ///
  /// Both, when the record knows both — the time an inspection was carried
  /// out is part of what it records, and a walk-around that took a minute
  /// reads very differently from one that took fifteen. A record that only
  /// knows when it was filed says just that, rather than inventing a start.
  static String times(Inspection i) {
    final started = i.startedAt;
    if (started == null || !started.isBefore(i.at)) return stamp(i.at);
    return '${stamp(started)} to ${_two(i.at.hour)}:${_two(i.at.minute)}';
  }

  /// How old the record is, in words, for somebody being shown it.
  ///
  /// **The plain fact, not a verdict.** Whether an inspection is still good
  /// enough is a rule this app does not know and must not guess at — what it
  /// can say without inventing anything is when the walk-around happened and
  /// how long ago that was.
  static String age(DateTime at, DateTime now) {
    final d = now.difference(at);
    if (d.isNegative) return 'just now';
    if (d.inMinutes < 1) return 'just now';
    if (d.inMinutes < 60) {
      return '${d.inMinutes} ${d.inMinutes == 1 ? 'minute' : 'minutes'} ago';
    }
    if (d.inHours < 24) {
      return '${d.inHours} ${d.inHours == 1 ? 'hour' : 'hours'} ago';
    }
    return '${d.inDays} ${d.inDays == 1 ? 'day' : 'days'} ago';
  }

  /// A filename that sorts by date and never collides across vehicles.
  static String fileName(Vehicle vehicle, Inspection i,
      {String extension = 'html'}) {
    final safe = vehicle.name
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    final d = '${i.at.year}${_two(i.at.month)}${_two(i.at.day)}'
        '-${_two(i.at.hour)}${_two(i.at.minute)}';
    return '${safe.isEmpty ? 'vehicle' : safe}-$d-${i.kind.wire}.$extension';
  }

  /// A filename for a vehicle's whole log.
  static String logFileName(Vehicle vehicle, {String extension = 'pdf'}) {
    final safe = vehicle.name
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    return '${safe.isEmpty ? 'vehicle' : safe}-inspection-log.$extension';
  }

  /// The plain-text form, for pasting into a message.
  static String text(Vehicle vehicle, Inspection i) {
    final out = StringBuffer()
      ..writeln('${i.kind.label} inspection')
      ..writeln(times(i))
      ..writeln()
      ..writeln('Vehicle: ${vehicle.name}');
    if (i.operator.trim().isNotEmpty) {
      out.writeln('Operator: ${i.operator.trim()}');
    }
    if (vehicle.plate.trim().isNotEmpty) {
      out.writeln('Plate: ${vehicle.plate.trim()}');
    }
    if (i.coupledUnit.trim().isNotEmpty) {
      out.writeln('Pulling: ${i.coupledUnit.trim()}');
    }
    if (i.driver.trim().isNotEmpty) out.writeln('Driver: ${i.driver.trim()}');
    if (i.odometer.trim().isNotEmpty) {
      out.writeln('Odometer: ${i.odometer.trim()}');
    }
    if (i.location.trim().isNotEmpty) {
      out.writeln('Location: ${i.location.trim()}');
    }
    out
      ..writeln()
      ..writeln(i.summary)
      ..writeln()
      ..writeln(i.declaration);

    final defects = i.defects;
    if (defects.isNotEmpty) {
      out
        ..writeln()
        ..writeln('DEFECTS');
      for (final id in defects) {
        final note = (i.notes[id] ?? '').trim();
        final sev = i.severityFor(id);
        out.writeln('- ${checkItemName(id)}'
            '${sev == null ? '' : ' [${sev.label.toUpperCase()}]'}'
            '${note.isEmpty ? '' : ': $note'}');
      }
      if (i.majorDefects.isNotEmpty) {
        out
          ..writeln()
          ..writeln(DefectSeverity.major.consequence);
      }
    }

    // The items nobody looked at are listed, not merely counted. A report
    // that says "4 not checked" without saying which four cannot be acted
    // on by whoever reads it next.
    final skipped = [
      for (final item in itemsFor(i.schedule))
        if (i.resultFor(item.id) == CheckResult.unchecked) item.name
    ];
    if (skipped.isNotEmpty) {
      out
        ..writeln()
        ..writeln('NOT CHECKED');
      for (final name in skipped) {
        out.writeln('- $name');
      }
    }

    if (i.remarks.trim().isNotEmpty) {
      out
        ..writeln()
        ..writeln('REMARKS')
        ..writeln(i.remarks.trim());
    }
    if (i.photos.isNotEmpty) {
      out
        ..writeln()
        ..writeln('${i.photos.length} '
            '${i.photos.length == 1 ? 'photo' : 'photos'} attached '
            '(in the exported report)');
    }
    out
      ..writeln()
      ..writeln(noteFor(i))
      ..writeln(disclaimer);
    return out.toString();
  }

  /// The sentence that must not be edited out, and a test pins it. Somebody
  /// reading this report at the roadside has to know what it is not.
  /// What list this was recorded against, said rather than left to be
  /// assumed. A record that named a jurisdiction's own schedule without
  /// being that schedule would be the single most misleading line the app
  /// could print, so it names what it actually is.
  /// What list a RECORD was walked against — read from the record, so a
  /// vehicle retyped next year cannot change what an old report claims.
  ///
  /// A record naming a jurisdiction's own schedule without following it
  /// would be the single most misleading line the app could print, which is
  /// why [InspectionSchedule] carries only the schedules whose item lists
  /// were actually read from the source.
  static String noteFor(Inspection i) => i.schedule.provenance;

  /// The general list's wording, for the surfaces that talk about the tool
  /// rather than about one record.
  static const String checklistNote =
      "Recorded against OkayMessenger's standard walk-around list.";

  /// The sentence that must not be edited out, and a test pins it. Somebody
  /// reading this report at the roadside has to know what it is not.
  static const String disclaimer =
      'This is a record of an inspection somebody carried out. '
      'It is not a certificate, and it does not record hours of service.';

  static String _esc(String raw) => raw
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;');

  /// The signature's strokes as an inline SVG path, drawn in the same 0..1
  /// space signature_ink.dart stores them in — so the exported mark is the mark
  /// that was drawn rather than a screenshot of it at one phone's size.
  static String _signatureSvg(String encoded) {
    final ink = SignatureInkPath.pathsFor(encoded);
    if (ink.isEmpty) return '';
    final paths = ink
        .map((d) => '<path d="$d" fill="none" stroke="#111" '
            'stroke-width="1.6" stroke-linecap="round" '
            'stroke-linejoin="round"/>')
        .join();
    return '<svg viewBox="0 0 400 140" width="400" height="140" '
        'role="img" aria-label="Signature">$paths</svg>';
  }

  /// A self-contained HTML report: no stylesheet, no script, no remote
  /// image. Photos ride as the `data:` URIs they are already stored as and
  /// the signature as inline SVG, so the file opens — and prints — anywhere,
  /// offline, with nothing to fetch and nobody told it was opened.
  static String html(Vehicle vehicle, Inspection i) {
    final out = StringBuffer()
      ..write('<!doctype html><html lang="en"><head><meta charset="utf-8">')
      ..write('<meta name="viewport" content="width=device-width,'
          'initial-scale=1">')
      ..write('<title>${_esc(vehicle.name)} — ${_esc(i.kind.label)} '
          '${_esc(stamp(i.at))}</title>')
      ..write('<style>body{font:15px/1.5 -apple-system,BlinkMacSystemFont,'
          '"Segoe UI",Roboto,sans-serif;margin:24px;color:#111;max-width:'
          '760px}h1{font-size:22px;margin:0 0 4px}h2{font-size:15px;'
          'text-transform:uppercase;letter-spacing:.06em;color:#555;'
          'margin:28px 0 8px}table{border-collapse:collapse;width:100%}'
          'td,th{text-align:left;padding:6px 8px;border-bottom:1px solid '
          '#e5e5e5;vertical-align:top}.defect{color:#b00020;font-weight:600}'
          '.na,.unchecked{color:#777}img{max-width:100%;border:1px solid '
          '#e5e5e5;border-radius:6px;margin:6px 0}'
          '.note{font-size:13px;color:#555}'
          '.foot{margin-top:32px;font-size:12px;color:#666;border-top:'
          '1px solid #e5e5e5;padding-top:12px}</style></head><body>')
      ..write('<h1>${_esc(i.kind.label)} inspection</h1>')
      ..write('<div class="note">${_esc(times(i))}</div>')
      ..write('<h2>Vehicle</h2><table>')
      ..write('<tr><th>Unit</th><td>${_esc(vehicle.name)}</td></tr>');
    if (i.operator.trim().isNotEmpty) {
      out.write('<tr><th>Operator</th><td>${_esc(i.operator.trim())}'
          '</td></tr>');
    }
    if (vehicle.plate.trim().isNotEmpty) {
      out.write('<tr><th>Plate</th><td>${_esc(vehicle.plate.trim())}'
          '</td></tr>');
    }
    if (i.coupledUnit.trim().isNotEmpty) {
      out.write('<tr><th>Pulling</th><td>${_esc(i.coupledUnit.trim())}'
          '</td></tr>');
    }
    if (i.driver.trim().isNotEmpty) {
      out.write('<tr><th>Driver</th><td>${_esc(i.driver.trim())}</td></tr>');
    }
    if (i.odometer.trim().isNotEmpty) {
      out.write('<tr><th>Odometer</th><td>${_esc(i.odometer.trim())}'
          '</td></tr>');
    }
    if (i.location.trim().isNotEmpty) {
      out.write('<tr><th>Location</th><td>${_esc(i.location.trim())}'
          '</td></tr>');
    }
    out
      ..write('<tr><th>Result</th><td>${_esc(i.summary)}</td></tr>')
      ..write('</table>');

    for (final section in i.schedule.checklist) {
      out.write('<h2>${_esc(section.title)}</h2><table>');
      for (final item in section.items) {
        final r = i.resultFor(item.id);
        final cls = switch (r) {
          CheckResult.defect => 'defect',
          CheckResult.na => 'na',
          CheckResult.unchecked => 'unchecked',
          CheckResult.ok => '',
        };
        final note = (i.notes[item.id] ?? '').trim();
        final sev = i.severityFor(item.id);
        out.write('<tr><td>${_esc(item.name)}'
            '${note.isEmpty ? '' : '<div class="note">${_esc(note)}</div>'}'
            '</td><td class="$cls">${_esc(r.label)}'
            '${sev == null ? '' : ' · ${_esc(sev.label)}'}</td></tr>');
      }
      out.write('</table>');
    }

    if (i.remarks.trim().isNotEmpty) {
      out.write('<h2>Remarks</h2><div>${_esc(i.remarks.trim())}</div>');
    }
    if (i.photos.isNotEmpty) {
      out.write('<h2>Photos</h2>');
      for (final p in i.photos) {
        // Only ever a data: URI — these are prepared on this device by
        // PhotoPrep. Anything else would make the report fetch something
        // when it was opened, which is exactly what self-contained means.
        if (!p.startsWith('data:image/')) continue;
        out.write('<img src="${_esc(p)}" alt="Defect photo">');
      }
    }
    final svg = _signatureSvg(i.signature);
    if (svg.isNotEmpty) {
      out
        ..write('<h2>Signed</h2>')
        ..write('<div>${_esc(i.declaration)}</div>')
        ..write(svg)
        ..write('<div class="note">A drawn mark, not proof of who drew it.'
            '</div>');
    }
    out
      ..write('<div class="foot">${_esc(noteFor(i))}<br>'
          '${_esc(disclaimer)}</div>')
      ..write('</body></html>');
    return out.toString();
  }
}

/// Turns an encoded signature into SVG path data.
///
/// Lives here rather than on `SignatureInk` because it is about EXPORTING a
/// mark, not storing one, and `signature_ink.dart` deliberately knows
/// nothing about how anybody draws it.
class SignatureInkPath {
  SignatureInkPath._();

  /// One `d` attribute per stroke, scaled to a 400x140 box. A one-point
  /// stroke — a tap, the dot on an i — becomes a tiny line rather than being
  /// dropped, because an SVG path of a single moveTo paints nothing.
  static List<String> pathsFor(String encoded, {double w = 400, double h = 140}) {
    final out = <String>[];
    for (final strokeText in encoded.split(';')) {
      final points = <(double, double)>[];
      for (final pointText in strokeText.split(' ')) {
        if (pointText.isEmpty) continue;
        final parts = pointText.split(',');
        if (parts.length != 2) continue;
        final x = double.tryParse(parts[0]);
        final y = double.tryParse(parts[1]);
        if (x == null || y == null) continue;
        points.add((x.clamp(0.0, 1.0) * w, y.clamp(0.0, 1.0) * h));
      }
      if (points.isEmpty) continue;
      final d = StringBuffer('M ${points.first.$1.toStringAsFixed(1)} '
          '${points.first.$2.toStringAsFixed(1)}');
      if (points.length == 1) {
        d.write(' l 0.1 0');
      } else {
        for (final p in points.skip(1)) {
          d.write(' L ${p.$1.toStringAsFixed(1)} ${p.$2.toStringAsFixed(1)}');
        }
      }
      out.add(d.toString());
    }
    return out;
  }
}
