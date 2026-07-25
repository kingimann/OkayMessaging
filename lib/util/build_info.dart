/// The build stamp injected by CI (short commit + date), so anyone can check
/// exactly which version their browser is running — stale service-worker
/// caches are invisible otherwise.
const String kBuildStamp =
    String.fromEnvironment('BUILD_STAMP', defaultValue: 'dev build');
