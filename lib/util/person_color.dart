/// The colour a person's avatar falls back to, derived from their own
/// identity.
///
/// **Extracted so it has no cycle to cross.** It lived on `Session`, and
/// `chat_store.dart` cannot import that — `session.dart` imports
/// `relay_service.dart`, which imports the chat store. Every place that had
/// to derive a colour without reaching `Session` therefore reached for a
/// CONSTANT instead, and that is the "everybody is one person" bug: a shared
/// violet made every stranger the same colour as each other, which reads as
/// broken rendering rather than as a missing avatar. Five instances of it
/// have been fixed; this is where the sixth stops being possible.
///
/// [Session.colorForPhone] delegates here, so there is one palette and one
/// hash rather than two that drift.
String personColorFor(String key) {
  const palette = [
    '#E57373', '#64B5F6', '#BA68C8', '#4DB6AC',
    '#FFB74D', '#A1887F', '#4DD0E1', '#81C784',
  ];
  var hash = 0;
  for (final unit in key.codeUnits) {
    hash = (hash + unit) & 0x7fffffff;
  }
  return palette[hash % palette.length];
}
