import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../relay/relay_config.dart';
import '../util/build_info.dart';

/// Ships crash and error reports to the `crash_reports` table so they can be
/// read from the Supabase dashboard (or by whoever is debugging) instead of
/// guessing from "the app crashes".
///
/// What's sent: the error text, a trimmed stack trace, app version, platform
/// and a timestamp — never message content, contacts, or the phone number.
/// Reports are rate-limited (at most [maxPerSession] per run, deduplicated
/// by error text) and sending is fire-and-forget: the reporter must never
/// take the app down or slow it while it's already in trouble.
///
/// Honest limit: this catches *Dart* errors. A native crash — a plugin
/// dying during startup registration, an OS watchdog kill — never reaches
/// Dart, so it can't be reported from inside the app. For those, TestFlight's
/// own crash logs remain the source of truth.
class CrashReporter {
  CrashReporter._();
  static final CrashReporter instance = CrashReporter._();

  static const table = 'crash_reports';
  static const maxPerSession = 10;

  final Set<String> _sent = {};
  bool _installed = false;

  /// Test hook: replaces the HTTP post; receives the row that would be sent.
  @visibleForTesting
  static void Function(Map<String, dynamic> row)? debugSendOverride;

  /// Installs the global hooks. Call once, as early as possible.
  void install() {
    if (_installed) return;
    _installed = true;
    final previousFlutterError = FlutterError.onError;
    FlutterError.onError = (details) {
      report(details.exception, details.stack, context: 'flutter');
      (previousFlutterError ?? FlutterError.dumpErrorToConsole)(details);
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      report(error, stack, context: 'uncaught');
      debugPrint('uncaught: $error');
      return true; // handled — never let it take the app down
    };
  }

  /// Queues one report. Safe to call from anywhere, including catch blocks
  /// for errors that were handled but shouldn't be happening.
  void report(Object error, StackTrace? stack, {String context = ''}) {
    try {
      final text = error.toString();
      // In-session dedup + cap, so an error loop can't flood the table.
      if (_sent.length >= maxPerSession || !_sent.add(text)) return;
      final row = buildReport(
        error: text,
        stack: stack?.toString() ?? '',
        context: context,
        // The CI build stamp identifies the exact build; no plugin needed.
        version: kBuildStamp,
      );
      final debug = debugSendOverride;
      if (debug != null) {
        debug(row);
        return;
      }
      if (!RelayConfig.isEnabled) return;
      http
          .post(
            Uri.parse('${RelayConfig.supabaseUrl}/rest/v1/$table'),
            headers: {
              'apikey': RelayConfig.supabaseAnonKey,
              'Authorization': 'Bearer ${RelayConfig.supabaseAnonKey}',
              'Content-Type': 'application/json',
            },
            body: jsonEncode(row),
          )
          .timeout(const Duration(seconds: 10))
          .catchError((_) => http.Response('', 0));
    } catch (_) {
      // The crash reporter itself must never throw.
    }
  }

  /// The row that goes to the server. Pure, so the shape is unit-tested.
  static Map<String, dynamic> buildReport({
    required String error,
    required String stack,
    required String context,
    required String version,
  }) {
    return {
      'error': error.length > 1000 ? error.substring(0, 1000) : error,
      // The top of the stack identifies the crash; the rest is bulk.
      'stack': stack.length > 4000 ? stack.substring(0, 4000) : stack,
      'context': context,
      'app_version': version,
      'platform': kIsWeb ? 'web' : defaultTargetPlatform.name,
      'mode': kReleaseMode ? 'release' : 'debug',
    };
  }

  @visibleForTesting
  void resetForTest() {
    _sent.clear();
  }
}
