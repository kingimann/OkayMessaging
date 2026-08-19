import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../models/inspection.dart';
import 'inspection_report.dart';

/// An inspection as a PDF, for filing, printing or handing over.
///
/// **Built in-process with a pure-Dart library and no native plugin**, so it
/// adds no iOS pod — the one class of dependency this project's own notes say
/// to be most careful with, since nothing here can compile an archive. The
/// bytes go to the existing share sheet, which is where "Save to Files"
/// lives.
///
/// It says exactly what [InspectionReport] says, in the same order and with
/// the same refusals — it states what was found and never passes judgement on
/// whether the vehicle may be driven. (A test scans this file for the words
/// that would break that, so do not quote them here even to explain the
/// rule; the guard errs on the safe side by design.) The disclaimer and the
/// checklist note ride the footer of every page.
class InspectionPdf {
  InspectionPdf._();

  /// The app's own Roboto, so the PDF can spell people's names.
  ///
  /// `package:pdf`'s built-in Helvetica is **ASCII only** — it warns as much
  /// on every build — so a driver called Bérubé, a place called Trois-
  /// Rivières or a note with any accent in it comes out mangled in the one
  /// document somebody hands over. Roboto is already an asset of this app
  /// (`pubspec.yaml`), so this costs no new bundle weight.
  ///
  /// Cached, because both entry points build documents and reading the font
  /// twice per export is wasted work. Falls back to the built-in font if the
  /// asset cannot be read: a PDF with awkward glyphs beats no PDF at all.
  static pw.ThemeData? _cachedTheme;

  static Future<pw.ThemeData?> _theme() async {
    if (_cachedTheme != null) return _cachedTheme;
    try {
      final base = pw.Font.ttf(
          await rootBundle.load('assets/fonts/Roboto-Regular.ttf'));
      final bold = pw.Font.ttf(
          await rootBundle.load('assets/fonts/Roboto-Medium.ttf'));
      return _cachedTheme = pw.ThemeData.withFont(base: base, bold: bold);
    } catch (_) {
      return null;
    }
  }

  static const _ink = PdfColor.fromInt(0xFF111111);
  static const _muted = PdfColor.fromInt(0xFF666666);
  static const _bad = PdfColor.fromInt(0xFFB00020);
  static const _rule = PdfColor.fromInt(0xFFE0E0E0);

  static Uint8List? _bytesOf(String dataUri) {
    if (!dataUri.startsWith('data:image/')) return null;
    final comma = dataUri.indexOf(',');
    if (comma < 0) return null;
    try {
      return base64Decode(dataUri.substring(comma + 1));
    } catch (_) {
      return null;
    }
  }

  static pw.Widget _fact(String label, String value) => pw.Padding(
        padding: const pw.EdgeInsets.only(bottom: 3),
        child: pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.SizedBox(
              width: 90,
              child: pw.Text(label,
                  style: const pw.TextStyle(fontSize: 9, color: _muted)),
            ),
            pw.Expanded(
              child: pw.Text(value,
                  style: pw.TextStyle(
                      fontSize: 10, fontWeight: pw.FontWeight.bold)),
            ),
          ],
        ),
      );

  static pw.Widget _heading(String text) => pw.Padding(
        padding: const pw.EdgeInsets.only(top: 14, bottom: 4),
        child: pw.Text(text.toUpperCase(),
            style: pw.TextStyle(
                fontSize: 8,
                letterSpacing: 0.8,
                color: _muted,
                fontWeight: pw.FontWeight.bold)),
      );

  /// The signature, drawn from the stored strokes rather than screenshotted,
  /// so it comes out crisp at print size.
  ///
  /// The PDF canvas has its origin at the BOTTOM left with y going up, while
  /// the ink is stored top-down in 0..1 — so y is flipped here. Getting that
  /// wrong prints somebody's name upside down, which is the sort of thing
  /// that looks like a forgery rather than a bug.
  static pw.Widget _signature(String encoded) => pw.SizedBox(
        width: 260,
        height: 90,
        child: pw.CustomPaint(
          painter: (canvas, size) {
            canvas
              ..setStrokeColor(_ink)
              ..setLineWidth(1.1)
              ..setLineCap(PdfLineCap.round)
              ..setLineJoin(PdfLineJoin.round);
            for (final d in _strokes(encoded)) {
              if (d.isEmpty) continue;
              canvas.moveTo(d.first.$1 * size.x, size.y - d.first.$2 * size.y);
              if (d.length == 1) {
                canvas.lineTo(
                    d.first.$1 * size.x + 0.4, size.y - d.first.$2 * size.y);
              } else {
                for (final p in d.skip(1)) {
                  canvas.lineTo(p.$1 * size.x, size.y - p.$2 * size.y);
                }
              }
              canvas.strokePath();
            }
          },
        ),
      );

  static List<List<(double, double)>> _strokes(String encoded) {
    final out = <List<(double, double)>>[];
    for (final strokeText in encoded.split(';')) {
      final points = <(double, double)>[];
      for (final pointText in strokeText.split(' ')) {
        if (pointText.isEmpty) continue;
        final parts = pointText.split(',');
        if (parts.length != 2) continue;
        final x = double.tryParse(parts[0]);
        final y = double.tryParse(parts[1]);
        if (x == null || y == null) continue;
        points.add((x.clamp(0.0, 1.0), y.clamp(0.0, 1.0)));
      }
      if (points.isNotEmpty) out.add(points);
    }
    return out;
  }

  /// A vehicle's whole log as one document — what somebody hands over when
  /// they are asked for the records rather than for one walk-around.
  ///
  /// A SUMMARY per inspection plus every defect, deliberately not the full
  /// item table for each: fifty records at twenty-two rows apiece is a
  /// document nobody reads, and the questions a log is asked are when it was
  /// inspected, by whom, and what was found.
  static Future<Uint8List> buildHistory(
      Vehicle vehicle, List<Inspection> records) async {
    final doc = pw.Document(theme: await _theme());
    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.letter,
        margin: const pw.EdgeInsets.fromLTRB(40, 40, 40, 40),
        footer: (ctx) => pw.Container(
          alignment: pw.Alignment.centerLeft,
          margin: const pw.EdgeInsets.only(top: 12),
          padding: const pw.EdgeInsets.only(top: 6),
          decoration: const pw.BoxDecoration(
              border: pw.Border(top: pw.BorderSide(color: _rule))),
          child: pw.Text(
            '${InspectionReport.disclaimer}   '
            'Page ${ctx.pageNumber} of ${ctx.pagesCount}',
            style: const pw.TextStyle(fontSize: 7, color: _muted),
          ),
        ),
        build: (ctx) => [
          pw.Text('Inspection log',
              style: pw.TextStyle(fontSize: 20, fontWeight: pw.FontWeight.bold)),
          pw.Text(
            [
              vehicle.name,
              if (vehicle.plate.trim().isNotEmpty) vehicle.plate.trim(),
              if (vehicle.type != VehicleType.other) vehicle.type.label,
              '${records.length} '
                  '${records.length == 1 ? 'record' : 'records'}',
            ].join(' · '),
            style: const pw.TextStyle(fontSize: 10, color: _muted),
          ),
          pw.SizedBox(height: 14),
          if (records.isEmpty)
            pw.Text('No inspections recorded.',
                style: const pw.TextStyle(fontSize: 10, color: _muted))
          else
            pw.Table(
              border: const pw.TableBorder(
                  horizontalInside: pw.BorderSide(color: _rule)),
              columnWidths: const {
                0: pw.FlexColumnWidth(2.4),
                1: pw.FlexColumnWidth(1.2),
                2: pw.FlexColumnWidth(1.6),
                3: pw.FlexColumnWidth(1.4),
                4: pw.FlexColumnWidth(3),
              },
              children: [
                pw.TableRow(children: [
                  for (final h in const [
                    'When',
                    'Type',
                    'Driver',
                    'Odometer',
                    'Result'
                  ])
                    pw.Padding(
                      padding: const pw.EdgeInsets.symmetric(vertical: 4),
                      child: pw.Text(h,
                          style: pw.TextStyle(
                              fontSize: 8,
                              color: _muted,
                              fontWeight: pw.FontWeight.bold)),
                    ),
                ]),
                for (final i in records)
                  pw.TableRow(children: [
                    for (final cell in [
                      InspectionReport.stamp(i.at),
                      i.kind.label,
                      i.driver.trim(),
                      i.odometer.trim(),
                      i.summary,
                    ])
                      pw.Padding(
                        padding: const pw.EdgeInsets.symmetric(vertical: 4),
                        child: pw.Text(cell,
                            style: pw.TextStyle(
                                fontSize: 8.5,
                                color: i.openMajorDefects.isEmpty
                                    ? _ink
                                    : _bad)),
                      ),
                  ]),
              ],
            ),
          for (final i in records)
            if (i.defects.isNotEmpty) ...[
              _heading('${InspectionReport.stamp(i.at)} · ${i.kind.label}'),
              for (final id in i.defects)
                pw.Bullet(
                  text: [
                    if (i.severityFor(id) != null)
                      '[${i.severityFor(id)!.label.toUpperCase()}]',
                    checkItemName(id),
                    if ((i.notes[id] ?? '').trim().isNotEmpty)
                      '— ${i.notes[id]!.trim()}',
                    if (i.fixes[id] case final fix?)
                      '(fixed ${InspectionReport.stamp(fix.at)}'
                          '${fix.by.trim().isEmpty ? '' : ' by ${fix.by.trim()}'})',
                  ].join(' '),
                  style: pw.TextStyle(
                      fontSize: 9,
                      color: i.fixes[id] == null ? _bad : _ink),
                ),
            ],
        ],
      ),
    );
    return doc.save();
  }

  static Future<Uint8List> build(Vehicle vehicle, Inspection i) async {
    final doc = pw.Document(theme: await _theme());
    final open = i.openDefects;

    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.letter,
        margin: const pw.EdgeInsets.fromLTRB(40, 40, 40, 40),
        footer: (ctx) => pw.Container(
          alignment: pw.Alignment.centerLeft,
          margin: const pw.EdgeInsets.only(top: 12),
          padding: const pw.EdgeInsets.only(top: 6),
          decoration: const pw.BoxDecoration(
              border: pw.Border(top: pw.BorderSide(color: _rule))),
          child: pw.Text(
            '${InspectionReport.noteFor(i)} '
            '${InspectionReport.disclaimer}   '
            'Page ${ctx.pageNumber} of ${ctx.pagesCount}',
            style: const pw.TextStyle(fontSize: 7, color: _muted),
          ),
        ),
        build: (ctx) => [
          pw.Text('${i.kind.label} inspection',
              style: pw.TextStyle(
                  fontSize: 20, fontWeight: pw.FontWeight.bold)),
          pw.Text('${i.schedule.name} · ${InspectionReport.times(i)}',
              style: const pw.TextStyle(fontSize: 10, color: _muted)),
          pw.SizedBox(height: 14),
          _fact('Unit', vehicle.name),
          if (vehicle.plate.trim().isNotEmpty)
            _fact('Plate', vehicle.plate.trim()),
          if (i.operator.trim().isNotEmpty) _fact('Operator', i.operator.trim()),
          if (i.driver.trim().isNotEmpty) _fact('Driver', i.driver.trim()),
          if (i.odometer.trim().isNotEmpty)
            _fact('Odometer', i.odometer.trim()),
          if (i.location.trim().isNotEmpty)
            _fact('Location', i.location.trim()),
          _fact('Result', i.summary),
          if (open.isNotEmpty) ...[
            _heading('Defects outstanding'),
            for (final id in open)
              pw.Bullet(
                text: (i.severityFor(id) == null
                        ? ''
                        : '[${i.severityFor(id)!.label.toUpperCase()}] ') +
                    checkItemName(id) +
                    ((i.notes[id] ?? '').trim().isEmpty
                        ? ''
                        : ' — ${i.notes[id]!.trim()}'),
                style: const pw.TextStyle(fontSize: 10, color: _bad),
              ),
          ],
          if (i.fixedCount > 0) ...[
            _heading('Defects signed off'),
            for (final id in i.defects)
              if (i.fixes[id] != null)
                pw.Bullet(
                  text: '${checkItemName(id)} — fixed '
                      '${InspectionReport.stamp(i.fixes[id]!.at)}'
                      '${i.fixes[id]!.by.trim().isEmpty ? '' : ' by ${i.fixes[id]!.by.trim()}'}'
                      '${i.fixes[id]!.note.trim().isEmpty ? '' : ': ${i.fixes[id]!.note.trim()}'}',
                  style: const pw.TextStyle(fontSize: 10),
                ),
          ],
          for (final section in i.schedule.checklist) ...[
            _heading(section.title),
            pw.Table(
              border: const pw.TableBorder(
                  horizontalInside: pw.BorderSide(color: _rule)),
              columnWidths: const {
                0: pw.FlexColumnWidth(4),
                1: pw.FlexColumnWidth(1),
              },
              children: [
                for (final item in section.items)
                  pw.TableRow(children: [
                    pw.Padding(
                      padding: const pw.EdgeInsets.symmetric(vertical: 3),
                      child: pw.Text(
                        item.name +
                            ((i.notes[item.id] ?? '').trim().isEmpty
                                ? ''
                                : '\n${i.notes[item.id]!.trim()}'),
                        style: const pw.TextStyle(fontSize: 9),
                      ),
                    ),
                    pw.Padding(
                      padding: const pw.EdgeInsets.symmetric(vertical: 3),
                      child: pw.Text(
                        i.resultFor(item.id).label,
                        style: pw.TextStyle(
                            fontSize: 9,
                            fontWeight: pw.FontWeight.bold,
                            color: i.resultFor(item.id) == CheckResult.defect
                                ? _bad
                                : _muted),
                      ),
                    ),
                  ]),
              ],
            ),
          ],
          if (i.remarks.trim().isNotEmpty) ...[
            _heading('Remarks'),
            pw.Text(i.remarks.trim(), style: const pw.TextStyle(fontSize: 10)),
          ],
          if (i.photoCount > 0) ...[
            _heading('Photos'),
            pw.Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final entry in i.itemPhotos.entries)
                  if (_bytesOf(entry.value) case final bytes?)
                    pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.start,
                      children: [
                        pw.Image(pw.MemoryImage(bytes),
                            width: 150, height: 150, fit: pw.BoxFit.cover),
                        pw.SizedBox(
                          width: 150,
                          child: pw.Text(checkItemName(entry.key),
                              style: const pw.TextStyle(
                                  fontSize: 7, color: _muted)),
                        ),
                      ],
                    ),
                for (final p in i.photos)
                  if (_bytesOf(p) case final bytes?)
                    pw.Image(pw.MemoryImage(bytes),
                        width: 150, height: 150, fit: pw.BoxFit.cover),
              ],
            ),
          ],
          _heading('Signed by the driver'),
          pw.Text(i.declaration, style: const pw.TextStyle(fontSize: 10)),
          if (_strokes(i.signature).isNotEmpty) ...[
            _signature(i.signature),
            pw.Text('A drawn mark, not proof of who drew it.',
                style: const pw.TextStyle(fontSize: 7, color: _muted)),
          ] else
            pw.Text('Not signed.',
                style: const pw.TextStyle(fontSize: 9, color: _muted)),
        ],
      ),
    );
    return doc.save();
  }
}
