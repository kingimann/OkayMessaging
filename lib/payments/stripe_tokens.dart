import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'payment_service.dart';

/// Turns bank details and government ID numbers into Stripe tokens, on the
/// device.
///
/// WHY IT IS DONE HERE AND NOT ON THE SERVER. An account number and a SIN are
/// the two most sensitive things this whole flow touches. Stripe accepts both
/// directly from a client with the publishable key — that is what the key is
/// for — and answers with a short-lived token that names them without being
/// them. Sending the raw numbers to an Edge Function instead would put them in
/// one more place, in one more log, for no benefit. So they go straight to
/// Stripe, and the server only ever sees `btok_…` and `piitok_…`.
///
/// This is the same rule the rest of the app follows: the server holds what it
/// must and nothing else.
class StripeTokens {
  StripeTokens._();

  /// Injected in tests, which must never reach Stripe.
  @visibleForTesting
  static Future<Map<String, dynamic>> Function(
      String path, Map<String, String> form)? debugPost;

  /// Test hook for the key, since a test binary carries no --dart-define.
  @visibleForTesting
  static String? debugPublishableKey;

  static String get _key =>
      debugPublishableKey ?? PaymentService.publishableKey;

  /// A token standing in for a bank account.
  ///
  /// [routingNumber] is digits only — for Canada the five transit digits
  /// followed by the three institution digits, which is what Stripe expects and
  /// not how a cheque prints them.
  static Future<String> bankAccount({
    required String country,
    required String currency,
    required String accountHolderName,
    required String routingNumber,
    required String accountNumber,
  }) async {
    final body = await _post('tokens', {
      'bank_account[country]': country,
      'bank_account[currency]': currency,
      'bank_account[account_holder_name]': accountHolderName,
      'bank_account[account_holder_type]': 'individual',
      'bank_account[routing_number]': routingNumber,
      'bank_account[account_number]': accountNumber,
    });
    return _idOf(body, 'btok_', 'bank account');
  }

  /// Injected in tests: uploading a file is a different request shape from
  /// posting a form, so it gets its own hook.
  @visibleForTesting
  static Future<Map<String, dynamic>> Function(
      String purpose, Uint8List bytes, String filename)? debugUpload;

  /// Uploads a photo of an identity document to Stripe and returns its file id.
  ///
  /// Stripe's file endpoint accepts a publishable key over Bearer auth — proven
  /// against the live API, not assumed — so the photo of somebody's driving
  /// licence goes from the camera to Stripe and nowhere else. This app's server
  /// receives the `file_…` id and never the image.
  static Future<String> identityDocument(Uint8List bytes,
      {String filename = 'document.jpg'}) async {
    final key = _key;
    if (key.isEmpty) {
      throw StripeTokenException(
          'This build has no Stripe key, so nothing can be sent to Stripe.');
    }
    final hook = debugUpload;
    final Map<String, dynamic> body;
    if (hook != null) {
      body = await hook('identity_document', bytes, filename);
    } else {
      final request = http.MultipartRequest(
          'POST', Uri.parse('https://files.stripe.com/v1/files'))
        ..headers['Authorization'] = 'Bearer \$key'
        ..fields['purpose'] = 'identity_document'
        ..files.add(http.MultipartFile.fromBytes('file', bytes,
            filename: filename));
      final response = await http.Response.fromStream(
          await request.send().timeout(const Duration(seconds: 40)));
      final decoded = jsonDecode(response.body);
      if (decoded is! Map) {
        throw StripeTokenException('Stripe answered with something unexpected.');
      }
      body = decoded.cast<String, dynamic>();
    }
    return _idOf(body, 'file_', 'document');
  }

  /// A token standing in for a government ID number.
  static Future<String> idNumber(String number) async {
    final body = await _post('tokens', {'pii[id_number]': number});
    return _idOf(body, 'piitok_', 'ID number');
  }

  static String _idOf(Map<String, dynamic> body, String prefix, String what) {
    final id = body['id'] as String?;
    if (id == null || !id.startsWith(prefix)) {
      final error = (body['error'] as Map?)?['message'];
      throw StripeTokenException(
          error == null ? 'Stripe didn\'t accept those $what details.' : '$error');
    }
    return id;
  }

  static Future<Map<String, dynamic>> _post(
      String path, Map<String, String> fields) async {
    final key = _key;
    if (key.isEmpty) {
      throw StripeTokenException(
          'This build has no Stripe key, so nothing can be sent to Stripe.');
    }
    final form = {'key': key, ...fields};
    final hook = debugPost;
    if (hook != null) return hook(path, form);
    final r = await http
        .post(Uri.parse('https://api.stripe.com/v1/$path'),
            headers: {'Content-Type': 'application/x-www-form-urlencoded'},
            body: form.entries
                .map((e) =>
                    '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}')
                .join('&'))
        .timeout(const Duration(seconds: 25));
    final decoded = jsonDecode(r.body);
    if (decoded is! Map) {
      throw StripeTokenException('Stripe answered with something unexpected.');
    }
    return decoded.cast<String, dynamic>();
  }
}

class StripeTokenException implements Exception {
  final String reason;
  StripeTokenException(this.reason);
  @override
  String toString() => reason;
}
