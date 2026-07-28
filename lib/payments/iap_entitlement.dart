import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../relay/relay_config.dart';
import 'apple_iap.dart';

/// What the server says an account is entitled to.
@immutable
class Entitlement {
  final bool active;
  final int gb;
  final DateTime? expiresAt;
  final String productId;

  const Entitlement({
    this.active = false,
    this.gb = 0,
    this.expiresAt,
    this.productId = '',
  });

  static const none = Entitlement();

  factory Entitlement.fromJson(Map<String, dynamic> j) {
    final raw = j['expiresAt'];
    return Entitlement(
      active: j['active'] == true,
      gb: (j['gb'] as num?)?.toInt() ?? 0,
      expiresAt: raw is String ? DateTime.tryParse(raw)?.toLocal() : null,
      productId: j['productId'] as String? ?? '',
    );
  }
}

/// The bridge between StoreKit and the server's record of who has paid.
///
/// An auto-renewable subscription charges every month whether or not the app
/// is ever opened, so the device cannot be the source of truth: a local
/// "+30 days" would drift the moment Apple renewed, cancelled, or refunded
/// something. Instead Apple's signed transactions go to `iap-validate`, Apple's
/// renewal notifications go to `iap-notify`, and this asks `iap-status` what
/// the answer currently is.
///
/// Every purchase StoreKit delivers — including restores and the renewals it
/// replays on launch — is forwarded automatically via [AppleIap.onTransaction],
/// so a subscription that renewed while the app was closed still lands.
class IapEntitlement {
  IapEntitlement._();
  static final IapEntitlement instance = IapEntitlement._();

  /// The last answer from the server, for screens to read synchronously.
  final ValueNotifier<Entitlement> current =
      ValueNotifier<Entitlement>(Entitlement.none);

  bool _wired = false;

  /// Starts forwarding StoreKit transactions to the validator. Safe to call
  /// more than once.
  void start() {
    if (_wired) return;
    _wired = true;
    AppleIap.onTransaction = (jws) => validate(jws);
  }

  SupabaseClient? get _client {
    if (!RelayConfig.isEnabled) return null;
    try {
      return Supabase.instance.client;
    } catch (_) {
      return null; // Supabase not initialised (tests, web preview).
    }
  }

  /// Hands one signed transaction to the server and adopts the entitlement it
  /// reports back. Returns null when the call couldn't be made.
  Future<Entitlement?> validate(String jws) =>
      _invoke('iap-validate', {'jws': jws});

  /// Re-reads the entitlement without any purchase — called on launch and
  /// whenever the storage screen opens, so a renewal or cancellation that
  /// happened elsewhere shows up.
  Future<Entitlement?> refresh() => _invoke('iap-status', const {});

  Future<Entitlement?> _invoke(String name, Map<String, dynamic> body) async {
    final client = _client;
    if (client == null) return null;
    try {
      final res = await client.functions.invoke(name, body: body);
      if (res.status >= 400) return null;
      final data = res.data;
      if (data is! Map) return null;
      final entitlement =
          Entitlement.fromJson(Map<String, dynamic>.from(data));
      current.value = entitlement;
      return entitlement;
    } catch (_) {
      // Offline, or the functions aren't deployed yet. The caller falls back
      // to whatever was last known; nothing here should ever throw into a UI.
      return null;
    }
  }

  @visibleForTesting
  void resetForTest() {
    current.value = Entitlement.none;
    _wired = false;
    AppleIap.onTransaction = null;
  }
}
