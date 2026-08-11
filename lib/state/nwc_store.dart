import 'package:flutter/foundation.dart';

import '../payments/lightning.dart';
import '../payments/nwc.dart';
import '../payments/nwc_client.dart';
import 'secure_store.dart';

/// The user's connected Lightning wallet, and the one place a spark actually
/// gets paid from.
///
/// **Why connecting a wallet is worth the trouble.** Without one, a spark
/// hands an invoice to whatever wallet the phone has and the app never learns
/// what happened — the honest limit `lightning.dart` states, and the reason
/// sparks have no confirmed state. With one, the wallet answers: a preimage,
/// or a named refusal. Same rails, same custody (none), but the app can stop
/// guessing.
///
/// The connection string is a SPENDING key, so it lives in [SecureStore] —
/// the keychain — never in plain app preferences, which ride device backups.
/// It is account-scoped for the same reason chats are: it is one person's
/// wallet.
///
/// Plain preference storage is deliberately never used here, and a test
/// asserts the file does not reach for it.
class NwcStore extends ChangeNotifier {
  NwcStore._();
  static final NwcStore instance = NwcStore._();

  static const String _key = 'nwc_connection';

  NwcConnection? _connection;

  /// The connected wallet, or null. Callers should prefer [isConnected] —
  /// this exposes the secret and is here for the payment path only.
  NwcConnection? get connection => _connection;

  bool get isConnected => _connection != null;

  /// The relay host, for a "connected via …" line. Never the secret.
  String get relayHost => _connection?.relay.host ?? '';

  /// Loads a previously connected wallet. Safe to call repeatedly.
  Future<void> load() async {
    final raw = await SecureStore.instance.read(_key);
    if (raw == null || raw.isEmpty) return;
    final parsed = NwcConnection.parse(raw);
    // A string that no longer parses is dropped rather than kept: it can only
    // fail later, at the moment somebody is trying to send money.
    if (parsed == null) {
      await SecureStore.instance.delete(_key);
      return;
    }
    _connection = parsed;
    notifyListeners();
  }

  /// Validates and stores a pasted connection string. Returns the reason it
  /// was refused, or null on success.
  ///
  /// It does NOT try a payment to prove the wallet works — that would mean
  /// spending someone's money to test a text field.
  Future<String?> connect(String raw) async {
    final parsed = NwcConnection.parse(raw);
    if (parsed == null) {
      return 'That doesn\'t look like a wallet connection. Copy the '
          '"Nostr Wallet Connect" string from your wallet — it starts with '
          'nostr+walletconnect://';
    }
    await SecureStore.instance.write(_key, raw.trim());
    _connection = parsed;
    notifyListeners();
    return null;
  }

  /// Forgets the wallet. The secret leaves the keychain here, which is the
  /// only way a user can revoke this app's access from this side; revoking it
  /// in the WALLET is what stops it for good, and the UI says so.
  Future<void> disconnect() async {
    await SecureStore.instance.delete(_key);
    _connection = null;
    notifyListeners();
  }

  /// Pays [invoice] through the connected wallet.
  ///
  /// Returns a failure rather than throwing when nothing is connected, so the
  /// spark path has one shape of answer to handle.
  Future<NwcResult> pay(String invoice, {int? amountMsats}) async {
    final c = _connection;
    if (c == null) {
      return const NwcResult.failed('No wallet is connected');
    }
    if (!Lightning.isInvoice(invoice)) {
      return const NwcResult.failed('That is not a Lightning invoice');
    }
    final request = c.payInvoiceRequest(
      invoice,
      amountMsats: amountMsats,
      createdAt: DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000,
    );
    return NwcClient.send(c, request);
  }

  @visibleForTesting
  void debugSet(NwcConnection? c) {
    _connection = c;
    notifyListeners();
  }

  @visibleForTesting
  void resetForTest() {
    _connection = null;
  }
}
