// Writes web/privacy.html and web/terms.html from lib/legal/legal_content.dart.
//
// The App Store requires a reachable Privacy Policy URL before a build can be
// submitted, and App Review reads it against what the app actually says. So
// the hosted copy is GENERATED from the same constants the in-app screens
// render — there is no second copy of the text to fall out of date, and a
// test fails if these files stop matching their source.
//
//   dart tool/build_legal_pages.dart
//
// THE URL TO GIVE APPLE is the `pages` Edge Function's — `/pages/privacy`
// and `/pages/terms` on the Supabase project. It names the app's own host and
// nothing else, which is the point: a link submitted to App Store Connect is
// published, and it should not advertise where the source lives. That is also
// why the app already takes every public URL off this function.
//
// The two files under web/ are the same pages shipped with the web build. They
// are there for a custom domain later; they are NOT the submission URL, since
// that build is served from a code host.
//
// HONEST LIMIT: this renders the version BUILT INTO the app
// (`legalVersion`). The owner can publish a newer one from inside the app
// (LegalStore / the legal-set function), and that override lives in the
// database, not here — so after publishing, re-run this and push, or the URL
// and the app disagree. Serving the live row from the `pages` Edge Function
// would close that gap and is the follow-up.

import 'dart:io';

import 'package:okay_messaging/legal/legal_content.dart';

/// The document titles, matching what the in-app screens are called.
const String _privacyTitle = 'Privacy Policy';
const String _termsTitle = 'Terms of Service';

String _escape(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;');

/// A section body is plain text with newlines and bullet lines. Paragraphs
/// split on a blank line; a run of lines starting '•' becomes a real list, so
/// it reads as one on a phone instead of a wrapped blob.
String _body(String raw) {
  final out = StringBuffer();
  for (final block in _escape(raw).split('\n\n')) {
    final lines = block.split('\n');
    if (lines.every((l) => l.trimLeft().startsWith('•'))) {
      out.writeln('    <ul>');
      for (final l in lines) {
        out.writeln('      <li>${l.trimLeft().substring(1).trim()}</li>');
      }
      out.writeln('    </ul>');
    } else {
      out.writeln('    <p>${lines.join('<br>')}</p>');
    }
  }
  return out.toString().trimRight();
}

String _page(String title, List<LegalSection> sections) {
  final body = StringBuffer();
  for (final s in sections) {
    body.writeln('    <h2>${_escape(s.title)}</h2>');
    body.writeln(_body(s.body));
  }
  return '''<!DOCTYPE html>
<!--
  GENERATED — do not edit by hand.
  Source: lib/legal/legal_content.dart · regenerate: dart tool/build_legal_pages.dart
-->
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>$title · OkayMessenger</title>
<style>
  :root { color-scheme: light dark; --fg: #1a1c1e; --dim: #5f6368; --bg: #ffffff; --rule: #e3e5e8; }
  @media (prefers-color-scheme: dark) {
    :root { --fg: #e8eaed; --dim: #9aa0a6; --bg: #121417; --rule: #2a2d31; }
  }
  html, body { margin: 0; background: var(--bg); }
  body {
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
    color: var(--fg); padding: 28px 20px 64px; box-sizing: border-box;
    -webkit-text-size-adjust: 100%;
  }
  main { max-width: 640px; margin: 0 auto; }
  h1 { font-size: 24px; margin: 0 0 4px; font-weight: 700; letter-spacing: -0.2px; }
  .meta { font-size: 13px; color: var(--dim); margin: 0 0 28px; }
  h2 {
    font-size: 17px; font-weight: 600; margin: 32px 0 8px;
    padding-top: 20px; border-top: 1px solid var(--rule);
  }
  h2:first-of-type { border-top: 0; padding-top: 0; margin-top: 0; }
  p { font-size: 15px; line-height: 1.6; margin: 0 0 12px; }
  ul { margin: 0 0 12px; padding-left: 20px; }
  li { font-size: 15px; line-height: 1.6; margin-bottom: 6px; }
  footer { margin-top: 40px; font-size: 13px; color: var(--dim); }
  a { color: inherit; }
</style>
</head>
<body>
<main>
  <h1>$title</h1>
  <p class="meta">OkayMessenger · $legalLastUpdated · version $legalVersion</p>
${body.toString().trimRight()}
  <footer>The same text is shown inside the app, under Settings &rarr; About.</footer>
</main>
</body>
</html>
''';
}

/// The same two pages as a TypeScript module the `pages` Edge Function
/// serves. That function is the app's canonical public host — every URL the
/// app names comes off it precisely so nothing has to point at a code host —
/// and it is the copy to give the App Store when the repository should not be
/// findable from a submitted URL.
String _tsModule() => '''
// GENERATED — do not edit by hand.
// Source: lib/legal/legal_content.dart · regenerate: dart tool/build_legal_pages.dart
//
// The legal documents as standalone pages, served by the `pages` function so
// the App Store's required Privacy Policy URL points at the app's own host
// rather than at wherever the source happens to live.

export const PRIVACY_HTML = ${_tsLiteral(_page(_privacyTitle, privacyPolicy))};

export const TERMS_HTML = ${_tsLiteral(_page(_termsTitle, termsOfService))};
''';

/// A TS template literal, with the three characters that can escape one
/// neutralised. The documents contain none of them today; generated code
/// should not depend on that staying true.
String _tsLiteral(String s) =>
    '`${s.replaceAllMapped(RegExp(r'[`\\]|\$\{'), (m) => '\\${m[0]}')}`';

/// The Terms as PLAIN TEXT, for App Store Connect's custom License Agreement
/// field — which takes pasted text, not a URL.
///
/// Apple refused a submission (2026-08-18) because it "offers auto-renewable
/// subscriptions but does not include a functional link to the Terms of Use
/// (EULA) in the app's metadata". The in-app disclosure already carried
/// everything guideline 3.1.2 asks for; what was missing was on the App Store
/// Connect side, where the choice is Apple's standard EULA or a custom one.
/// This app has its own Terms that every user already accepts in-app
/// (LegalConsent), so the custom one is the honest answer — two different
/// agreements for one app is worse than either.
///
/// Generated from the same constants for the same reason the two HTML pages
/// are: a hand-pasted copy is a second version to fall out of date, and this
/// one has a VERSION COUNTER that re-prompts every user when it moves.
String _plainText() {
  final out = StringBuffer()
    ..writeln('OkayMessenger — $_termsTitle')
    ..writeln('$legalLastUpdated · version $legalVersion')
    ..writeln();
  for (final s in termsOfService) {
    out
      ..writeln(s.title.toUpperCase())
      ..writeln()
      ..writeln(s.body.trim())
      ..writeln();
  }
  return '${out.toString().trimRight()}\n';
}

void main() {
  File('web/privacy.html').writeAsStringSync(_page(_privacyTitle, privacyPolicy));
  File('web/terms.html').writeAsStringSync(_page(_termsTitle, termsOfService));
  File('supabase/functions/_shared/legal_pages.ts').writeAsStringSync(_tsModule());
  File('docs/app_store_eula.txt').writeAsStringSync(_plainText());
  stdout.writeln('wrote web/privacy.html, web/terms.html, '
      'supabase/functions/_shared/legal_pages.ts and docs/app_store_eula.txt '
      '(version $legalVersion)');
}
