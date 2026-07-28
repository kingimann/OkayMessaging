import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../relay/relay_config.dart';

/// Where an account stands with the ID check behind the blue check.
enum IdentityStatus {
  /// Never started one.
  none,

  /// Stripe is still working through the documents.
  processing,

  /// Stripe needs something else — a clearer photo, a different document.
  requiresInput,

  /// Passed. This is the only status that earns the badge.
  verified,

  /// Abandoned or cancelled.
  canceled,
}

IdentityStatus _statusFrom(String? raw) => switch (raw) {
      'verified' => IdentityStatus.verified,
      'processing' => IdentityStatus.processing,
      'requires_input' => IdentityStatus.requiresInput,
      'canceled' => IdentityStatus.canceled,
      _ => IdentityStatus.none,
    };

/// Drives the government-ID check that earns the blue check.
///
/// The badge used to be a free local toggle, which made it a decoration rather
/// than a claim about who someone is. It now comes from the server and only
/// the server: the device asks what Stripe concluded and displays that. A
/// badge a device could grant itself would be worth nothing, so nothing here
/// ever *sets* verified — it only reads it.
///
/// No document ever reaches this app. The check happens in Stripe's hosted
/// flow; the app opens a URL and later asks how it went.
class IdentityVerification extends ChangeNotifier {
  IdentityVerification._();
  static final IdentityVerification instance = IdentityVerification._();

  IdentityStatus _status = IdentityStatus.none;
  IdentityStatus get status => _status;

  bool get isVerified => _status == IdentityStatus.verified;

  /// True while Stripe is still deciding — worth telling the user rather than
  /// showing "not verified" at someone who just finished the flow.
  bool get isPending => _status == IdentityStatus.processing;

  SupabaseClient? get _client {
    if (!RelayConfig.isEnabled) return null;
    try {
      return Supabase.instance.client;
    } catch (_) {
      return null; // Supabase not initialised (tests, web preview).
    }
  }

  /// Re-reads the verdict. Called at startup and when returning from Stripe.
  Future<IdentityStatus> refresh() async {
    final result = await _invoke('identity-status', const {});
    if (result == null) return _status;
    _apply(_statusFrom(result['status'] as String?));
    return _status;
  }

  /// Starts a check and returns the URL to send the user to, or null when a
  /// session couldn't be created. Returns an empty string when the account is
  /// already verified, so the caller can say so instead of charging for
  /// another check.
  Future<String?> start() async {
    final result = await _invoke('identity-start', const {});
    if (result == null) return null;
    if (result['alreadyVerified'] == true) {
      _apply(IdentityStatus.verified);
      return '';
    }
    final url = result['url'];
    if (url is! String || url.isEmpty) return null;
    // The session exists but nothing is decided yet.
    _apply(IdentityStatus.processing);
    return url;
  }

  void _apply(IdentityStatus next) {
    if (_status == next) return;
    _status = next;
    notifyListeners();
  }

  Future<Map<String, dynamic>?> _invoke(
      String name, Map<String, dynamic> body) async {
    final client = _client;
    if (client == null) return null;
    try {
      final res = await client.functions.invoke(name, body: body);
      if (res.status >= 400) return null;
      final data = res.data;
      if (data is! Map) return null;
      return Map<String, dynamic>.from(data);
    } catch (_) {
      // Offline, or the functions aren't deployed. Never throw into a UI.
      return null;
    }
  }

  @visibleForTesting
  void resetForTest() {
    _status = IdentityStatus.none;
    notifyListeners();
  }

  @visibleForTesting
  void debugSetStatus(IdentityStatus status) => _apply(status);
}
