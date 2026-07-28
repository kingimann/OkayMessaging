import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

/// The outcome of inspecting a file before it's allowed out of the device.
class ModerationVerdict {
  /// True when the file may be sent/uploaded.
  final bool allowed;

  /// A human-readable reason when [allowed] is false, else null.
  final String? reason;

  /// What the bytes actually are — 'jpeg', 'png', 'pdf', 'executable', … —
  /// determined from the content, not the file name.
  final String kind;

  const ModerationVerdict.ok(this.kind)
      : allowed = true,
        reason = null;
  const ModerationVerdict.blocked(this.reason, this.kind) : allowed = false;
}

/// Raised by the pickers when a chosen file fails moderation, so the UI can
/// tell the user why instead of failing silently.
class FileRejected implements Exception {
  final String reason;
  FileRejected(this.reason);
  @override
  String toString() => reason;
}

/// Client-side upload moderation.
///
/// Nothing leaves this device unless it passes here. Because everything the
/// server ever sees is ciphertext, the server cannot moderate — so the check
/// is enforced on the way out, deterministically and with no AI:
///
///  * the bytes are sniffed for what they *actually* are (magic numbers), so a
///    renamed executable can't pose as a photo;
///  * only a small allowlist of media types may ride the photo path — nothing
///    else gets uploaded;
///  * dangerous types (executables, scripts) are refused on every path;
///  * a size cap keeps a single file from blowing the budget;
///  * a SHA-256 blocklist lets known-bad content be refused outright.
class FileModeration {
  FileModeration._();

  /// Hard ceiling for any single file leaving the device (25 MB).
  static const int maxFileBytes = 25 * 1024 * 1024;

  /// Image types allowed through the photo path.
  static const Set<String> allowedImageKinds = {
    'jpeg',
    'png',
    'gif',
    'webp',
    'bmp',
    'heic',
  };

  /// Non-image types that are still safe to send as a document.
  static const Set<String> allowedDocKinds = {
    'pdf',
    'text',
    'zip', // ordinary archives; the executables inside would be blocked on open
  };

  /// SHA-256 hashes (lowercase hex) of content that must never be uploaded.
  /// Empty by default; a deployment (or a report-driven update) can add to it.
  static final Set<String> _blockedHashes = <String>{};

  /// Adds a hash to the blocklist. Content matching it is refused everywhere.
  static void blockHash(String sha256Hex) =>
      _blockedHashes.add(sha256Hex.toLowerCase());

  static bool get hasBlocklist => _blockedHashes.isNotEmpty;

  /// The lowercase-hex SHA-256 of [bytes].
  static String hashOf(Uint8List bytes) =>
      sha256.convert(bytes).toString();

  /// Identifies [bytes] by their leading magic numbers. Returns a short kind
  /// string; 'unknown' when nothing matches.
  static String sniff(Uint8List b) {
    int at(int i) => i < b.length ? b[i] : -1;
    bool starts(List<int> sig) {
      if (b.length < sig.length) return false;
      for (var i = 0; i < sig.length; i++) {
        if (b[i] != sig[i]) return false;
      }
      return true;
    }

    // Images.
    if (starts([0xFF, 0xD8, 0xFF])) return 'jpeg';
    if (starts([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) return 'png';
    if (starts([0x47, 0x49, 0x46, 0x38])) return 'gif'; // GIF8
    if (starts([0x42, 0x4D])) return 'bmp';
    if (starts([0x52, 0x49, 0x46, 0x46]) && // RIFF
        at(8) == 0x57 &&
        at(9) == 0x45 &&
        at(10) == 0x42 &&
        at(11) == 0x50) {
      return 'webp'; // ...WEBP
    }
    // HEIC/HEIF: 'ftyp' box at offset 4, brand heic/heix/mif1/hevc.
    if (at(4) == 0x66 && at(5) == 0x74 && at(6) == 0x79 && at(7) == 0x70) {
      final brand = String.fromCharCodes(
          [at(8), at(9), at(10), at(11)].where((c) => c >= 0));
      if (brand.startsWith('hei') ||
          brand.startsWith('mif') ||
          brand.startsWith('hev')) {
        return 'heic';
      }
    }

    // Documents.
    if (starts([0x25, 0x50, 0x44, 0x46])) return 'pdf'; // %PDF

    // Dangerous executables and scripts — refused everywhere.
    if (starts([0x4D, 0x5A])) return 'executable'; // MZ (Windows PE)
    if (starts([0x7F, 0x45, 0x4C, 0x46])) return 'executable'; // ELF
    if (starts([0xFE, 0xED, 0xFA, 0xCE]) ||
        starts([0xFE, 0xED, 0xFA, 0xCF]) ||
        starts([0xCA, 0xFE, 0xBA, 0xBE]) ||
        starts([0xCF, 0xFA, 0xED, 0xFE])) {
      return 'executable'; // Mach-O / universal binary
    }
    if (starts([0x23, 0x21])) return 'script'; // #! shebang

    // ZIP (also .docx/.xlsx/.apk/.jar containers).
    if (starts([0x50, 0x4B, 0x03, 0x04]) ||
        starts([0x50, 0x4B, 0x05, 0x06])) {
      return 'zip';
    }

    // Mostly-printable? Call it text.
    if (b.isNotEmpty) {
      final sample = b.length < 512 ? b : b.sublist(0, 512);
      final printable = sample
          .where((c) => c == 9 || c == 10 || c == 13 || (c >= 32 && c < 127))
          .length;
      if (printable / sample.length > 0.85) return 'text';
    }
    return 'unknown';
  }

  /// Inspects a file destined for the **photo** path: only real images pass.
  static ModerationVerdict inspectImage(Uint8List bytes) {
    if (bytes.isEmpty) {
      return const ModerationVerdict.blocked('That file is empty.', 'unknown');
    }
    if (bytes.length > maxFileBytes) {
      return ModerationVerdict.blocked(
          'That image is too large (max ${_mb(maxFileBytes)}).', 'oversize');
    }
    if (_blockedHashes.contains(hashOf(bytes))) {
      return const ModerationVerdict.blocked(
          'That file isn’t allowed.', 'blocked');
    }
    final kind = sniff(bytes);
    if (!allowedImageKinds.contains(kind)) {
      return ModerationVerdict.blocked(
          'Only image files can be sent here.', kind);
    }
    return ModerationVerdict.ok(kind);
  }

  /// Inspects a file destined for the **document** path: images and safe
  /// documents pass; executables, scripts, and unknown binaries are refused.
  static ModerationVerdict inspectFile(Uint8List bytes) {
    if (bytes.isEmpty) {
      return const ModerationVerdict.blocked('That file is empty.', 'unknown');
    }
    if (bytes.length > maxFileBytes) {
      return ModerationVerdict.blocked(
          'That file is too large (max ${_mb(maxFileBytes)}).', 'oversize');
    }
    if (_blockedHashes.contains(hashOf(bytes))) {
      return const ModerationVerdict.blocked(
          'That file isn’t allowed.', 'blocked');
    }
    final kind = sniff(bytes);
    if (kind == 'executable' || kind == 'script') {
      return const ModerationVerdict.blocked(
          'Executable files can’t be sent.', 'executable');
    }
    if (allowedImageKinds.contains(kind) || allowedDocKinds.contains(kind)) {
      return ModerationVerdict.ok(kind);
    }
    return ModerationVerdict.blocked(
        'That file type isn’t allowed.', kind);
  }

  static String _mb(int bytes) => '${(bytes / (1024 * 1024)).round()} MB';

  @visibleForTesting
  static void resetForTest() => _blockedHashes.clear();
}
